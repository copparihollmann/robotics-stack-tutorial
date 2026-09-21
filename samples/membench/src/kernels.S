/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * membench inner loops, hand-written so that what executes is exactly what is intended.
 *
 * WHY ASSEMBLY.  Every published memory-bandwidth number is really a number about a loop,
 * and a C loop with a `volatile` accumulator is only as trustworthy as the disassembly
 * nobody looked at.  These three loops are short enough to read, and scripts/25 dumps them
 * out of the built ELF into inner_loops.txt so the number in the table can be traced to
 * the instruction stream that produced it.
 *
 * THE ISSUE-RATE CEILING IS PART OF THE MEASUREMENT.  Rocket is single-issue and in-order:
 * one instruction retires per cycle at best.  mb_read moves 256 bytes with 34 instructions
 * (32 x ld + addi + bltu), so its L1-resident ceiling is 256/34 = 7.53 B/cycle -- 94% of
 * the 8 B/cycle the 64-bit datapath can carry, and 301 MB/s at 40 MHz.  A loop that also
 * summed the loaded values would need 32 more adds and would cap at 3.8 B/cycle, which
 * would be a measurement of the ALU, not of the cache.  The unrolling is what buys the
 * other 3.7 B/cycle.
 *
 * rv64imac only: no f, no d, no v.  Nothing here touches a floating-point register.
 */

	.section .text.membench, "ax", @progbits

/* 8 loads = one 64-byte cache line, into 8 distinct registers so that no two loads in
 * flight name the same destination. */
	.macro	MB_LD8 off
	ld	t0, \off+0(a0)
	ld	t1, \off+8(a0)
	ld	t2, \off+16(a0)
	ld	t3, \off+24(a0)
	ld	t4, \off+32(a0)
	ld	t5, \off+40(a0)
	ld	t6, \off+48(a0)
	ld	a3, \off+56(a0)
	.endm

/* 8 stores = one 64-byte cache line, all of it, from one source register. Writing every
 * byte of the line does NOT save the fill: Rocket's L1D is write-back with allocate and
 * has no full-line-store optimisation, so a write miss costs a line fill now and a
 * writeback later -- which is the whole reason read and write are reported separately. */
	.macro	MB_SD8 off
	sd	a4, \off+0(a0)
	sd	a4, \off+8(a0)
	sd	a4, \off+16(a0)
	sd	a4, \off+24(a0)
	sd	a4, \off+32(a0)
	sd	a4, \off+40(a0)
	sd	a4, \off+48(a0)
	sd	a4, \off+56(a0)
	.endm

/* -------------------------------------------------------------------------------------
 * uint64_t mb_read(const void *base, uint64_t bytes)
 *
 *   base  must be 64-byte aligned, bytes a non-zero multiple of 256.
 *   Returns the last value loaded, so the caller can consume it and the loop cannot be
 *   argued away -- though nothing in this file passes through a compiler anyway.
 *
 *   34 instructions per 256 bytes = 4 cache lines.
 * ----------------------------------------------------------------------------------- */
	.balign	64
	.globl	mb_read
	.type	mb_read, @function
mb_read:
	add	a2, a0, a1		/* a2 = end */
	li	t0, 0
1:
	MB_LD8	0
	MB_LD8	64
	MB_LD8	128
	MB_LD8	192
	addi	a0, a0, 256
	bltu	a0, a2, 1b
	mv	a0, t0
	ret
	.size	mb_read, .-mb_read

/* -------------------------------------------------------------------------------------
 * void mb_write(void *base, uint64_t bytes, uint64_t val)
 *
 *   Same shape, same constraints: 34 instructions per 256 bytes.
 * ----------------------------------------------------------------------------------- */
	.balign	64
	.globl	mb_write
	.type	mb_write, @function
mb_write:
	add	a3, a0, a1		/* a3 = end */
	mv	a4, a2			/* a4 = the value stored */
1:
	MB_SD8	0
	MB_SD8	64
	MB_SD8	128
	MB_SD8	192
	addi	a0, a0, 256
	bltu	a0, a3, 1b
	ret
	.size	mb_write, .-mb_write

/* -------------------------------------------------------------------------------------
 * void *mb_chase(void *p, uint64_t steps)
 *
 *   Load-to-use latency.  Each load's address IS the previous load's result, so the chain
 *   is strictly serial and nothing -- not a prefetcher, not a stride predictor, not an
 *   out-of-order window this core does not have -- can overlap two of them.
 *
 *   Unrolled 8x on purpose.  A one-load loop body would also carry an addi and a bnez,
 *   and on a single-issue core that puts a 3-cycle floor under the reported latency:
 *   an L1 hit would read as 3 cycles instead of 2.  At 8 loads per iteration the loop
 *   overhead is 2/8 = 0.25 cycles per step, which the caller subtracts nothing for and
 *   which is stated in the output.
 *
 *   steps must be a non-zero multiple of 8.
 * ----------------------------------------------------------------------------------- */
	.balign	64
	.globl	mb_chase
	.type	mb_chase, @function
mb_chase:
	srli	a1, a1, 3
	beqz	a1, 2f
1:
	ld	a0, 0(a0)
	ld	a0, 0(a0)
	ld	a0, 0(a0)
	ld	a0, 0(a0)
	ld	a0, 0(a0)
	ld	a0, 0(a0)
	ld	a0, 0(a0)
	ld	a0, 0(a0)
	addi	a1, a1, -1
	bnez	a1, 1b
2:
	ret
	.size	mb_chase, .-mb_chase
