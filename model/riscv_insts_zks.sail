/*=======================================================================================*/
/*  This Sail RISC-V architecture model, comprising all files and                        */
/*  directories except where otherwise noted is subject the BSD                          */
/*  two-clause license in the LICENSE file.                                              */
/*                                                                                       */
/*  SPDX-License-Identifier: BSD-2-Clause                                                */
/*=======================================================================================*/

/*
 * Scalar Cryptography Extension - Scalar SM3 instructions
 * ----------------------------------------------------------------------
 */

function clause currentlyEnabled(Ext_Zksh) = hartSupports(Ext_Zksh)

union clause instruction = SM3P0 : (regidx, regidx)
union clause instruction = SM3P1 : (regidx, regidx)

mapping clause encdec = SM3P0 (rs1, rd)
  <-> 0b00 @ 0b01000 @ 0b01000 @ encdec_reg(rs1) @ 0b001 @ encdec_reg(rd) @ 0b0010011
  when currentlyEnabled(Ext_Zksh)

mapping clause encdec = SM3P1 (rs1, rd)
  <-> 0b00 @ 0b01000 @ 0b01001 @ encdec_reg(rs1) @ 0b001 @ encdec_reg(rd) @ 0b0010011
  when currentlyEnabled(Ext_Zksh)

mapping clause assembly = SM3P0 (rs1, rd) <->
  "sm3p0" ^ spc() ^ reg_name(rd) ^ sep() ^ reg_name(rs1)

mapping clause assembly = SM3P1 (rs1, rd) <->
  "sm3p1" ^ spc() ^ reg_name(rd) ^ sep() ^ reg_name(rs1)

function clause execute (SM3P0(rs1, rd)) = {
  let r1     : bits(32) = X(rs1)[31..0];
  let result : bits(32) =  r1 ^ (r1 <<< 9) ^ (r1 <<< 17);
  X(rd) = sign_extend(result);
  RETIRE_SUCCESS
}

function clause execute (SM3P1(rs1, rd)) = {
  let r1     : bits(32) = X(rs1)[31..0];
  let result : bits(32) =  r1 ^ (r1 <<< 15) ^ (r1 <<< 23);
  X(rd) = sign_extend(result);
  RETIRE_SUCCESS
}

/*
 * Scalar Cryptography Extension - Scalar SM4 instructions
 * ----------------------------------------------------------------------
 */

function clause currentlyEnabled(Ext_Zksed) = hartSupports(Ext_Zksed)

union clause instruction = SM4ED : (bits(2), regidx, regidx, regidx)
union clause instruction = SM4KS : (bits(2), regidx, regidx, regidx)

mapping clause encdec = SM4ED (bs, rs2, rs1, rd)
  <-> bs @ 0b11000 @ encdec_reg(rs2) @ encdec_reg(rs1) @ 0b000 @ encdec_reg(rd) @ 0b0110011
  when currentlyEnabled(Ext_Zksed)

mapping clause encdec = SM4KS (bs, rs2, rs1, rd)
  <-> bs @ 0b11010 @ encdec_reg(rs2) @ encdec_reg(rs1) @ 0b000 @ encdec_reg(rd) @ 0b0110011
  when currentlyEnabled(Ext_Zksed)

mapping clause assembly = SM4ED (bs, rs2, rs1, rd) <->
    "sm4ed" ^ spc() ^ reg_name(rd) ^ sep() ^ reg_name(rs1) ^ sep() ^ reg_name(rs2) ^ sep() ^ hex_bits_2(bs)

mapping clause assembly = SM4KS (bs, rs2, rs1, rd) <->
    "sm4ks" ^ spc() ^ reg_name(rd) ^ sep() ^ reg_name(rs1) ^ sep() ^ reg_name(rs2) ^ sep() ^ hex_bits_2(bs)

function clause execute (SM4ED (bs, rs2, rs1, rd)) = {
  let shamt : bits(5)  = bs @ 0b000; /* shamt = bs*8 */
  let sb_in : bits(8)  = (X(rs2)[31..0] >> shamt)[7..0];
  let x     : bits(32) = 0x000000 @ sm4_sbox(sb_in);
  let y     : bits(32) = x ^ (x               <<  8) ^ ( x               <<  2) ^
                             (x               << 18) ^ ((x & 0x0000003F) << 26) ^
                             ((x & 0x000000C0) << 10);
  let z     : bits(32) = (y <<< shamt);
  let result : bits(32) = z ^ X(rs1)[31..0];
  X(rd)                = sign_extend(result);
  RETIRE_SUCCESS
}

function clause execute (SM4KS (bs, rs2, rs1, rd)) = {
  let shamt : bits(5)  = (bs @ 0b000); /* shamt = bs*8 */
  let sb_in : bits(8)  = (X(rs2)[31..0] >> shamt)[7..0];
  let x     : bits(32) = 0x000000 @ sm4_sbox(sb_in);
  let y     : bits(32) = x ^ ((x & 0x00000007) << 29) ^ ((x & 0x000000FE) <<  7) ^
                             ((x & 0x00000001) << 23) ^ ((x & 0x000000F8) << 13) ;
  let z     : bits(32) = (y <<< shamt);
  let result : bits(32) = z ^ X(rs1)[31..0];
  X(rd) = sign_extend(result);
  RETIRE_SUCCESS
}
