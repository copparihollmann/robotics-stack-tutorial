/* SPDX-License-Identifier: Apache-2.0
 *
 * Two-hart bare-metal startup for samples/pext_rtl_selftest.
 *
 * The Chipyard bootrom (testchipip/bootrom.S) mrets EVERY hart to the address in the
 * BOOTADDR_REG SCR -- DRAM_BASE -- with a0 = mhartid and a1 = the DTB.  So both harts
 * arrive here, and the negative test (MBP on hart 1 must trap) needs that: there is no
 * other way to get an instruction executed on the LITTLE hart from a bare-metal image.
 *
 * ORDER MATTERS in three places:
 *   1. mtvec is set BEFORE anything can fault, including on hart 1, whose whole job is
 *      to take a trap.
 *   2. Only hart 0 clears .bss.  Hart 1 spins on `bss_ready`, which lives in .data (NOT
 *      .bss) precisely so that clearing .bss cannot un-set it.
 *   3. The bootrom leaves MSIP enabled in mie and MIE set in mstatus.  Both are cleared
 *      here, so the only thing that can reach trap_entry afterwards is a synchronous
 *      exception -- which is what makes "mcause == 2" a meaningful assertion.
 */

#define STACK_SIZE_LOG2 13      /* 8 KiB per hart */

  .section .text.init, "ax", @progbits
  .globl _start
_start:
  csrr  t0, mhartid

  /* trap vector first: hart 1 is about to take an illegal-instruction exception on
     purpose, and a hart with mtvec = 0 would fetch from 0 and never come back. */
  la    t1, trap_entry
  csrw  mtvec, t1

  /* no interrupts: the bootrom armed MSIP to release us and we are released. */
  csrw  mie, zero
  li    t1, 8
  csrc  mstatus, t1
  csrw  mip, zero

.option push
.option norelax
  la    gp, __global_pointer$
.option pop

  /* sp = _stack_top - mhartid * 8 KiB */
  la    sp, _stack_top
  slli  t1, t0, STACK_SIZE_LOG2
  sub   sp, sp, t1

  bnez  t0, wait_for_bss

  /* hart 0: clear .bss, then release the others */
  la    t1, _bss_start
  la    t2, _bss_end
1:
  bgeu  t1, t2, 2f
  sd    zero, 0(t1)
  addi  t1, t1, 8
  j     1b
2:
  fence w, w
  la    t1, bss_ready
  li    t2, 1
  sd    t2, 0(t1)
  j     enter_c

wait_for_bss:
  la    t1, bss_ready
1:
  ld    t2, 0(t1)
  beqz  t2, 1b
  fence r, r

enter_c:
  csrr  a0, mhartid
  call  hart_main
  /* hart_main does not return for hart 0 (it exits through HTIF); park anyone else. */
park:
  wfi
  j     park

/* --------------------------------------------------------------------------------
 * Trap handler.  Records cause/epc/tval per hart and RETIRES the faulting instruction
 * by advancing mepc past it, so the negative test can take four traps in a row and
 * still reach its report.  Every MBP encoding is 4 bytes -- they are R-type in
 * custom-0 and there is no compressed form -- so the skip is a fixed +4.  A trap from
 * anything else lands here too; it is recorded with its real mcause and the C side
 * fails the test rather than the simulation hanging.
 * -------------------------------------------------------------------------------- */
  .section .text, "ax", @progbits
  .align 6
  .globl trap_entry
trap_entry:
  addi  sp, sp, -48
  sd    t0, 0(sp)
  sd    t1, 8(sp)
  sd    t2, 16(sp)
  sd    t3, 24(sp)
  sd    t4, 32(sp)

  csrr  t0, mhartid
  slli  t0, t0, 3                 /* 8 bytes per hart */

  csrr  t1, mcause
  la    t3, mbp_trap_cause
  add   t4, t3, t0
  sd    t1, 0(t4)

  csrr  t1, mepc
  la    t3, mbp_trap_epc
  add   t4, t3, t0
  sd    t1, 0(t4)

  csrr  t2, mtval
  la    t3, mbp_trap_tval
  add   t4, t3, t0
  sd    t2, 0(t4)

  la    t3, mbp_trap_count
  add   t4, t3, t0
  ld    t2, 0(t4)
  addi  t2, t2, 1
  sd    t2, 0(t4)

  addi  t1, t1, 4
  csrw  mepc, t1

  ld    t0, 0(sp)
  ld    t1, 8(sp)
  ld    t2, 16(sp)
  ld    t3, 24(sp)
  ld    t4, 32(sp)
  addi  sp, sp, 48
  mret

/* Lives in .data, not .bss: hart 1 polls it while hart 0 is still clearing .bss. */
  .section .data, "aw", @progbits
  .align 3
  .globl bss_ready
bss_ready:
  .dword 0
