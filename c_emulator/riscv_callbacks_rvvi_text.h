#pragma once

#include "riscv_callbacks_if.h"
#include "sail.h"

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>

class rvvi_text_callbacks : public callbacks_if {
public:
  explicit rvvi_text_callbacks(FILE *output);

  // Emit the RVVI-Text header (VERSION, VENDOR, PARAMS).
  // Must be called after model initialization so that zxlen/zflen/zvlen are set.
  void emit_header(hart::Model &model);

  // callbacks_if overrides
  void pre_step_callback(hart::Model &model, bool is_waiting) override;
  void post_step_callback(hart::Model &model, bool is_waiting) override;
  void fetch_callback(hart::Model &model, sbits opcode) override;
  void xreg_full_write_callback(hart::Model &model, const_sail_string abi_name, sbits reg, sbits value) override;
  void freg_write_callback(hart::Model &model, unsigned reg, sbits value) override;
  void vreg_write_callback(hart::Model &model, unsigned reg, lbits value) override;
  void csr_full_write_callback(hart::Model &model, const_sail_string csr_name, unsigned reg, sbits value) override;
  void trap_callback(hart::Model &model, bool is_interrupt, fbits cause) override;

private:
  void reset_step_state();
  void emit_line();
  static unsigned privilege_to_rvvi_mode(int priv_enum);

  FILE *m_output;

  // Per-step buffered state
  bool m_has_fetch = false;
  bool m_is_waiting = false;
  uint64_t m_pc = 0;
  uint64_t m_opcode = 0;
  int m_opcode_len = 0; // 16 or 32 bits (from opcode.len)
  bool m_is_trap = false;
  unsigned m_privilege = 0; // RVVI MODE: 0x0=U, 0x1=S, 0x3=M

  // Buffered state changes with bit widths from callback parameters.
  struct RegChange {
    uint64_t value;
    int len; // bit width from sbits.len
  };
  std::map<unsigned, RegChange> m_xreg_changes; // GPR index -> {value, xlen}
  std::map<unsigned, RegChange> m_freg_changes; // FPR index -> {value, flen}
  std::map<unsigned, RegChange> m_csr_changes;  // CSR addr  -> {value, xlen}

  struct VregChange {
    std::string hex_value; // pre-formatted hex (no 0x prefix)
    int len;               // bit width from lbits.len
  };
  std::map<unsigned, VregChange> m_vreg_changes; // VReg index -> {hex, vlen}

  // Cached model params — only used for the PARAMS header line and PC formatting.
  int64_t m_xlen = 64;
  int64_t m_flen = 0;
  int64_t m_vlen = 0;
};
