/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * A private M-mode trap entry, installed for the length of four instructions.
 *
 * WHY NOT USE ZEPHYR'S FATAL PATH.  An illegal-instruction exception on hart 1 is the
 * EXPECTED result here -- it is the heterogeneity mechanism, not a bug -- and it has to
 * happen four times in a row on a thread that then goes on to report what it saw. Zephyr's
 * own handler routes a CPU exception to z_fatal_error(), and the only sanctioned recovery
 * from there is aborting the thread, which loses mcause/mepc/mtval and cannot resume to
 * try the next encoding. So the probe installs its own mtvec, executes one instruction,
 * and returns to the instruction after it.
 *
 * WHAT MAKES THAT SAFE, and each of these is load-bearing:
 *
 *   * The caller holds irq_lock() across the whole window, so mstatus.MIE is clear and no
 *     timer tick, IPI or UART interrupt can arrive while Zephyr's mtvec is displaced.
 *     Nothing else on this hart can trap: the window is four .insn words and the loads
 *     and stores around them touch only memory the thread already owns.
 *   * The caller saves and restores BOTH mtvec and mscratch. Zephyr's RISC-V port owns
 *     both; borrowing them without putting them back is the failure that would show up
 *     later, somewhere else, as an unexplained crash.
 *   * This handler clobbers NOTHING. It gets its scratch pointer by swapping t0 into
 *     mscratch -- the standard M-mode trick -- saves t1 into the record it was handed, and
 *     unwinds both before mret.
 *   * mepc += 4, not += 2. Every MBP encoding is a 4-byte .insn word; there is no
 *     compressed form and the assembler cannot produce one.
 *
 * Record layout -- MUST match struct mbp_trap_rec in main.c:
 *   0  saved t1      8  mcause     16  mepc     24  mtval     32  count
 */

	.section .text, "ax"
	.globl	mbp_probe_trap_entry
	/* .align 4 is 2^4 = 16 bytes on RISC-V. mtvec needs 4-byte alignment with the
	 * bottom two bits clear (direct mode); 16 satisfies it with room to spare. */
	.align	4
mbp_probe_trap_entry:
	csrrw	t0, mscratch, t0	/* t0 <- &rec ; mscratch <- caller's t0 */
	sd	t1, 0(t0)		/* rec.scratch = caller's t1 */
	csrr	t1, mcause
	sd	t1, 8(t0)
	csrr	t1, mepc
	sd	t1, 16(t0)
	csrr	t1, mtval
	sd	t1, 24(t0)
	ld	t1, 32(t0)
	addi	t1, t1, 1
	sd	t1, 32(t0)		/* rec.count++ */
	csrr	t1, mepc
	addi	t1, t1, 4		/* resume AFTER the trapping instruction */
	csrw	mepc, t1
	ld	t1, 0(t0)		/* restore caller's t1 */
	csrrw	t0, mscratch, t0	/* restore caller's t0 ; mscratch <- &rec */
	mret
