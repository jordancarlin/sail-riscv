/*=======================================================================================*/
/*  This Sail RISC-V architecture model, comprising all files and                        */
/*  directories except where otherwise noted is subject the BSD                          */
/*  two-clause license in the LICENSE file.                                              */
/*                                                                                       */
/*  SPDX-License-Identifier: BSD-2-Clause                                                */
/*=======================================================================================*/

/* Machine-mode and supervisor-mode functionality. */

function effectivePrivilege(t : AccessType(ext_access_type), m : Mstatus, priv : Privilege) -> Privilege =
  if   t != InstructionFetch() & m[MPRV] == 0b1
  then privLevel_of_bits(m[MPP])
  else priv

/* CSR access control */

function csrAccess(csr : csreg) -> csrRW = csr[11..10]
function csrPriv(csr : csreg) -> priv_level = csr[9..8]

// Check that the CSR access is made with sufficient privilege.
function check_CSR_priv(csr : csreg, p : Privilege) -> bool =
  privLevel_to_bits(p) >=_u csrPriv(csr)

// Check that the CSR access isn't a write and read-only.
function check_CSR_access(csr : csreg, isWrite : bool) -> bool =
  not(isWrite & (csrAccess(csr) == 0b11))

function check_CSR(csr : csreg, p : Privilege, isWrite : bool) -> bool =
    check_CSR_priv(csr, p)
  & check_CSR_access(csr, isWrite)
  & is_CSR_accessible(csr, p, isWrite)

/* Exception delegation: given an exception and the privilege at which
 * it occurred, returns the privilege at which it should be handled.
 */
function exception_delegatee(e : ExceptionType, p : Privilege) -> Privilege = {
  let idx   = num_of_ExceptionType(e);
  let super = bit_to_bool(medeleg.bits[idx]);
  let deleg = if currentlyEnabled(Ext_S) & super then Supervisor else Machine;
  /* We cannot transition to a less-privileged mode. */
  if   privLevel_to_bits(deleg) <_u privLevel_to_bits(p)
  then p else deleg
}

/* Interrupts are prioritized in privilege order, and for each
 * privilege, in the order: external, software, timers.
 */
function findPendingInterrupt(ip : xlenbits) -> option(InterruptType) = {
  let ip = Mk_Minterrupts(ip);
  if      ip[MEI] == 0b1 then Some(I_M_External)
  else if ip[MSI] == 0b1 then Some(I_M_Software)
  else if ip[MTI] == 0b1 then Some(I_M_Timer)
  else if ip[SEI] == 0b1 then Some(I_S_External)
  else if ip[SSI] == 0b1 then Some(I_S_Software)
  else if ip[STI] == 0b1 then Some(I_S_Timer)
  else                        None()
}

/* Given the current privilege level, return the pending set
 * of interrupts for the highest privilege that has any pending.
 *
 * We don't use the lowered views of {xie,xip} here, since the spec
 * allows for example the M_Timer to be delegated to the S-mode.
 *
 * This is used when the hart is in the Active state.
 */
function getPendingSet(priv : Privilege) -> option((xlenbits, Privilege)) = {
  // mideleg can only be non-zero if we support Supervisor mode.
  assert(currentlyEnabled(Ext_S) | mideleg.bits == zeros());

  let pending_m = mip.bits & mie.bits & ~(mideleg.bits);
  let pending_s = mip.bits & mie.bits & mideleg.bits;

  let mIE = (priv == Machine    & mstatus[MIE] == 0b1) | priv == Supervisor | priv == User;
  let sIE = (priv == Supervisor & mstatus[SIE] == 0b1) | priv == User;

  if      mIE & (pending_m != zeros()) then Some((pending_m, Machine))
  else if sIE & (pending_s != zeros()) then Some((pending_s, Supervisor))
  else None()
}

/* Check if a locally enabled interrupt is pending.
 *
 * This does not examine the global enable bits (MIE and SIE in
 * mstatus) and their delegation in mideleg. It does honor the
 * local interrupt enables in mie.
 *
 * This is used when the hart is in the Waiting state, caused by
 * instructions such as WFI and WRS.{NTO,STO}.
 *
 * The relevant detail in the privileged spec is:
 * https://riscv.github.io/riscv-isa-manual/snapshot/privileged/#wfi
 *
 * "The operation of WFI must be unaffected by the global interrupt
 * bits in mstatus (MIE and SIE) and the delegation register mideleg
 * (i.e., the hart must resume if a locally enabled interrupt becomes
 * pending, even if it has been delegated to a less-privileged mode),
 * but should honor the individual interrupt enables (e.g, MTIE)
 * (i.e., implementations should avoid resuming the hart if the
 * interrupt is pending but not individually enabled)."
 */
function shouldWakeForInterrupt() -> bool = {
  (mip.bits & mie.bits) != zeros()
}

/* Examine the current interrupt state and return an interrupt to be *
 * handled (if any), and the privilege it should be handled at.
 */
function dispatchInterrupt(priv : Privilege) -> option((InterruptType, Privilege)) = {
  match getPendingSet(priv) {
    None()       => None(),
    Some(ip, p)  => match findPendingInterrupt(ip) {
                      None()  => None(),
                      Some(i) => Some((i, p)),
                    }
  }
}

/* types of privilege transitions */

union ctl_result = {
  CTL_TRAP : sync_exception,
  CTL_SRET : unit,
  CTL_MRET : unit,
}

/* trap value */

function tval(excinfo : option(xlenbits)) -> xlenbits = {
  match (excinfo) {
    Some(e) => e,
    None()  => zeros()
  }
}

function track_trap(p : Privilege) -> unit = {
  long_csr_write_callback("mstatus", "mstatush", mstatus.bits);
  match (p) {
    Machine => {
      csr_write_callback("mcause", mcause.bits);
      csr_write_callback("mtval", mtval);
      csr_write_callback("mepc", mepc);
    },
    Supervisor => {
      csr_write_callback("scause", scause.bits);
      csr_write_callback("stval", stval);
      csr_write_callback("sepc", sepc);
    },
    User => internal_error(__FILE__, __LINE__, "Invalid privilege level"),
  };
}

/* handle exceptional ctl flow by updating nextPC and operating privilege */
function trap_handler(del_priv : Privilege, intr : bool, c : exc_code, pc : xlenbits, info : option(xlenbits), ext : option(ext_exception))
                     -> xlenbits = {
  trap_callback();
  if   get_config_print_platform()
  then print_platform("handling " ^ (if intr then "int#" else "exc#")
                      ^ BitStr(c) ^ " at priv " ^ to_str(del_priv)
                      ^ " with tval " ^ BitStr(tval(info)));

  match (del_priv) {
    Machine => {
       mcause[IsInterrupt] = bool_to_bits(intr);
       mcause[Cause]       = zero_extend(c);

       mstatus[MPIE] = mstatus[MIE];
       mstatus[MIE]  = 0b0;
       mstatus[MPP]  = privLevel_to_bits(cur_privilege);
       mtval         = tval(info);
       mepc          = pc;

       cur_privilege = del_priv;

       handle_trap_extension(del_priv, pc, ext);

       track_trap(del_priv);

       prepare_trap_vector(del_priv, mcause)
    },
    Supervisor => {
       assert (currentlyEnabled(Ext_S), "no supervisor mode present for delegation");

       scause[IsInterrupt] = bool_to_bits(intr);
       scause[Cause]       = zero_extend(c);

       mstatus[SPIE] = mstatus[SIE];
       mstatus[SIE]  = 0b0;
       mstatus[SPP]  = match cur_privilege {
                           User => 0b0,
                           Supervisor => 0b1,
                           Machine => internal_error(__FILE__, __LINE__, "invalid privilege for s-mode trap")
                         };
       stval           = tval(info);
       sepc            = pc;

       cur_privilege   = del_priv;

       handle_trap_extension(del_priv, pc, ext);

       track_trap(del_priv);

       prepare_trap_vector(del_priv, scause)
    },
    User => internal_error(__FILE__, __LINE__, "Invalid privilege level"),
  };
}

function exception_handler(cur_priv : Privilege, ctl : ctl_result,
                           pc: xlenbits) -> xlenbits = {
  match (cur_priv, ctl) {
    (_, CTL_TRAP(e)) => {
      let del_priv = exception_delegatee(e.trap, cur_priv);
      if   get_config_print_platform()
      then print_platform("trapping from " ^ to_str(cur_priv) ^ " to " ^ to_str(del_priv)
                          ^ " to handle " ^ to_str(e.trap));
      trap_handler(del_priv, false, exceptionType_to_bits(e.trap), pc, e.excinfo, e.ext)
    },
    (_, CTL_MRET())  => {
      let prev_priv   = cur_privilege;
      mstatus[MIE]  = mstatus[MPIE];
      mstatus[MPIE] = 0b1;
      cur_privilege   = privLevel_of_bits(mstatus[MPP]);
      mstatus[MPP]  = privLevel_to_bits(if currentlyEnabled(Ext_U) then User else Machine);
      if   cur_privilege != Machine
      then mstatus[MPRV] = 0b0;

      long_csr_write_callback("mstatus", "mstatush", mstatus.bits);

      if   get_config_print_platform()
      then print_platform("ret-ing from " ^ to_str(prev_priv) ^ " to " ^ to_str(cur_privilege));

      prepare_xret_target(Machine)
    },
    (_, CTL_SRET())  => {
      let prev_priv   = cur_privilege;
      mstatus[SIE]  = mstatus[SPIE];
      mstatus[SPIE] = 0b1;
      cur_privilege   = if mstatus[SPP] == 0b1 then Supervisor else User;
      mstatus[SPP]  = 0b0;
      if   cur_privilege != Machine
      then mstatus[MPRV] = 0b0;

      long_csr_write_callback("mstatus", "mstatush", mstatus.bits);

      if   get_config_print_platform()
      then print_platform("ret-ing from " ^ to_str(prev_priv)
                          ^ " to " ^ to_str(cur_privilege));

      prepare_xret_target(Supervisor)
    },
  }
}

function handle_mem_exception(Virtaddr(addr) : virtaddr, e : ExceptionType) -> unit = {
  let t : sync_exception = struct { trap    = e,
                                    excinfo = Some(addr),
                                    ext     = None() } in
  set_next_pc(exception_handler(cur_privilege, CTL_TRAP(t), PC))
}

function handle_exception(e: ExceptionType) -> unit = {
  let t : sync_exception = struct { trap    = e,
                                    excinfo = None(),
                                    ext     = None() } in
  set_next_pc(exception_handler(cur_privilege, CTL_TRAP(t), PC))
}

function handle_interrupt(i : InterruptType, del_priv : Privilege) -> unit =
  set_next_pc(trap_handler(del_priv, true, interruptType_to_bits(i), PC, None(), None()))

// Reset misa to enable the maximal set of supported extensions.
function reset_misa() -> unit = {
  misa[A]   = bool_to_bits(hartSupports(Ext_A));   /* atomics */
  misa[C]   = bool_to_bits(hartSupports(Ext_C));   /* RVC */
  misa[B]   = bool_to_bits(hartSupports(Ext_B));   /* Bit-manipulation */
  misa[I]   = 0b1;                                 /* base integer ISA */
  misa[M]   = bool_to_bits(hartSupports(Ext_M));   /* integer multiply/divide */
  misa[U]   = bool_to_bits(hartSupports(Ext_U));   /* user-mode */
  misa[S]   = bool_to_bits(hartSupports(Ext_S));   /* supervisor-mode */
  misa[V]   = bool_to_bits(hartSupports(Ext_V));   /* vector extension */

  if   hartSupports(Ext_F) & hartSupports(Ext_Zfinx)
  then internal_error(__FILE__, __LINE__, "F and Zfinx cannot both be enabled!");

  /* We currently support both F and D */
  misa[F]   = bool_to_bits(hartSupports(Ext_F));      /* single-precision */
  misa[D]   = if   flen >= 64
              then bool_to_bits(hartSupports(Ext_D))  /* double-precision */
              else 0b0;
  csr_write_callback("misa", misa.bits);
}

// This function is called on reset, so it should only perform the reset actions
// described in the "Reset" section of the privileged architecture specification.
function reset_sys() -> unit = {

  // "Upon reset, a hart's privilege mode is set to M."
  cur_privilege = Machine;

  // "The mstatus fields MIE and MPRV are reset to 0."
  mstatus[MIE] = 0b0;
  mstatus[MPRV] = 0b0;

  // "If little-endian memory accesses are supported, the mstatus/mstatush field
  // MBE is reset to 0."
  // TODO: The handling of mstatush is a bit awkward currently, but the model
  // currently only supports little endian so MBE is always 0.
  // See https://github.com/riscv/sail-riscv/issues/639
  // mstatus[MBE] = 0b0;

  long_csr_write_callback("mstatus", "mstatush", mstatus.bits);

  // "The misa register is reset to enable the maximal set of supported extensions"
  reset_misa();

  // "For implementations with the "A" standard extension, there is no valid load reservation."
  cancel_reservation();

  // "The pc is set to an implementation-defined reset vector."
  // This is outside the scope of this function.

  // "The mcause register is set to a value indicating the cause of the reset."
  // "The mcause values after reset have implementation-specific interpretation,
  // but the value 0 should be returned on implementations that do not
  // distinguish different reset conditions."
  mcause.bits = zeros();
  csr_write_callback("mcause", mcause.bits);

  // "Writable PMP registers’ A and L fields are set to 0, unless the platform
  // mandates a different reset value for some PMP registers’ A and L fields."
  reset_pmp();

  // "The [s,u]seed bits must have a defined reset value. The system must
  // not allow them to be in an undefined state after a reset."
  mseccfg[SSEED] = bool_to_bits(config extensions.Zkr.sseed_reset_value : bool);
  mseccfg[USEED] = bool_to_bits(config extensions.Zkr.useed_reset_value : bool);

  // TODO: Probably need to remove these vector resets too but it needs
  // refactoring anyway. See https://github.com/riscv/sail-riscv/issues/566 etc.
  // If they are kept then callbacks need to be added.

  /* initialize vector csrs */
  vstart           = zeros();
  vl               = zeros();
  vcsr[vxrm]       = 0b00;
  vcsr[vxsat]      = 0b0;
  vtype[vill]      = 0b1;
  vtype[reserved]  = zeros();
  vtype[vma]       = 0b0;
  vtype[vta]       = 0b0;
  vtype[vsew]      = 0b000;
  vtype[vlmul]     = 0b000;
}

/* memory access exceptions, defined here for use by the platform model. */

type MemoryOpResult('a : Type) = result('a, ExceptionType)

val MemoryOpResult_add_meta : forall ('t : Type). (MemoryOpResult('t), mem_meta) -> MemoryOpResult(('t, mem_meta))
function MemoryOpResult_add_meta(r, m) = match r {
  Ok(v)  => Ok(v, m),
  Err(e) => Err(e)
}

val MemoryOpResult_drop_meta : forall ('t : Type). MemoryOpResult(('t, mem_meta)) -> MemoryOpResult('t)
function MemoryOpResult_drop_meta(r) = match r {
  Ok(v, m)  => Ok(v),
  Err(e) => Err(e)
}
