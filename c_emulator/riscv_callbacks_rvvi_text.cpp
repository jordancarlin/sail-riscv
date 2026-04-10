#include "riscv_callbacks_rvvi_text.h"
#include "sail_riscv_model.h"
#include <cassert>
#include <cinttypes>
#include <cstring>
#include <vector>

rvvi_text_callbacks::rvvi_text_callbacks(FILE *output) : m_output(output) {
}

// Map Sail zPrivilege enum to RVVI MODE encoding.
// Sail enum order: zUser=0, zVirtualUser=1, zSupervisor=2, zVirtualSupervisor=3, zMachine=4
// RVVI MODE: U=0x0, S=0x1, M=0x3
unsigned rvvi_text_callbacks::privilege_to_rvvi_mode(int priv_enum) {
  switch (priv_enum) {
  case 0: // zUser
    return 0x0;
  case 1: // zVirtualUser
    return 0x0;
  case 2: // zSupervisor
    return 0x1;
  case 3: // zVirtualSupervisor
    return 0x1;
  case 4: // zMachine
    return 0x3;
  default:
    assert(false && "Unknown privilege level");
    return 0x3;
  }
}

void rvvi_text_callbacks::emit_header(hart::Model &model) {
  m_xlen = model.zxlen;
  m_flen = model.zflen;
  m_vlen = model.zvlen;

  fprintf(m_output, "VERSION 0 4\n");
  fprintf(m_output, "VENDOR \"sail_riscv\" 0 10\n");
  fprintf(
    m_output,
    "PARAMS 7 ILEN 32 XLEN %" PRId64 " FLEN %" PRId64 " VLEN %" PRId64 " NHART 1 RETIRE 1 TIMESCALE ns\n",
    m_xlen,
    m_flen,
    m_vlen
  );
}

void rvvi_text_callbacks::reset_step_state() {
  m_has_fetch = false;
  m_is_waiting = false;
  m_pc = 0;
  m_opcode = 0;
  m_opcode_len = 0;
  m_is_trap = false;
  m_privilege = 0;
  m_xreg_changes.clear();
  m_freg_changes.clear();
  m_vreg_changes.clear();
  m_csr_changes.clear();
}

void rvvi_text_callbacks::pre_step_callback(hart::Model &model, bool is_waiting) {
  reset_step_state();
  m_is_waiting = is_waiting;
  // Capture privilege mode — no privilege callback exists in the interface.
  m_privilege = privilege_to_rvvi_mode(static_cast<int>(model.zcur_privilege));
}

void rvvi_text_callbacks::fetch_callback(hart::Model &model, sbits opcode) {
  // PC is not passed as a parameter to fetch_callback — read from model state.
  m_pc = model.zPC.bits;
  m_opcode = opcode.bits;
  m_opcode_len = opcode.len;
  m_has_fetch = true;
}

void rvvi_text_callbacks::xreg_full_write_callback(hart::Model &, const_sail_string, sbits reg, sbits value) {
  // Filter out x0 writes — x0 is hardwired to zero.
  if (reg.bits == 0) {
    return;
  }
  m_xreg_changes[static_cast<unsigned>(reg.bits)] = {value.bits, value.len};
}

void rvvi_text_callbacks::freg_write_callback(hart::Model &, unsigned reg, sbits value) {
  m_freg_changes[reg] = {value.bits, value.len};
}

void rvvi_text_callbacks::vreg_write_callback(hart::Model &, unsigned reg, lbits value) {
  // lbits can exceed 64 bits, so format to hex string.
  // Determine required hex digits for zero-padding.
  int hex_digits = value.len / 4;
  // gmp_snprintf with %ZX formats the GMP integer as hex.
  // We need a buffer large enough for the padded value.
  std::vector<char> buf(hex_digits + 16);
  gmp_snprintf(buf.data(), buf.size(), "%0*ZX", hex_digits, *value.bits);
  m_vreg_changes[reg] = {std::string(buf.data()), value.len};
}

void rvvi_text_callbacks::csr_full_write_callback(hart::Model &, const_sail_string, unsigned reg, sbits value) {
  m_csr_changes[reg] = {value.bits, value.len};
}

void rvvi_text_callbacks::trap_callback(hart::Model &, bool, fbits) {
  m_is_trap = true;
}

void rvvi_text_callbacks::post_step_callback(hart::Model &, bool is_waiting) {
  if (is_waiting || !m_has_fetch) {
    return;
  }
  emit_line();
}

void rvvi_text_callbacks::emit_line() {
  // RET/TRAP <pc> <instBin> [state changes...] MODE <priv>
  int pc_hex_digits = static_cast<int>(m_xlen / 4);
  int inst_hex_digits = m_opcode_len / 4;

  fprintf(
    m_output,
    "%s 0x%0*" PRIX64 " 0x%0*" PRIX64,
    m_is_trap ? "TRAP" : "RET",
    pc_hex_digits,
    m_pc,
    inst_hex_digits,
    m_opcode
  );

  // GPR changes
  for (const auto &[idx, change] : m_xreg_changes) {
    int hex_digits = change.len / 4;
    fprintf(m_output, " X %u 0x%0*" PRIX64, idx, hex_digits, change.value);
  }

  // FPR changes
  for (const auto &[idx, change] : m_freg_changes) {
    int hex_digits = change.len / 4;
    fprintf(m_output, " F %u 0x%0*" PRIX64, idx, hex_digits, change.value);
  }

  // Vector register changes
  for (const auto &[idx, change] : m_vreg_changes) {
    fprintf(m_output, " V %u 0x%s", idx, change.hex_value.c_str());
  }

  // CSR changes
  for (const auto &[addr, change] : m_csr_changes) {
    int hex_digits = change.len / 4;
    fprintf(m_output, " C 0x%03X 0x%0*" PRIX64, addr, hex_digits, change.value);
  }

  // Privilege mode
  fprintf(m_output, " MODE 0x%X\n", m_privilege);
}
