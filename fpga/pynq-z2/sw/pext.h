/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * MBP -- the small packed-SIMD integer extension for the BIG Rocket hart of
 * the PYNQ-Z1 big.LITTLE SoC.  Three instructions in the RISC-V custom-0
 * opcode space.  See fpga/pynq-z2/docs/PEXT_SPEC.md for the specification,
 * the workload evidence behind it, and the heterogeneity contract.
 *
 *   MBP.DOT8   rd, rs1, rs2   rd = sum_{i=0..7} sext(rs1.b[i]) * sext(rs2.b[i])
 *   MBP.MAX8   rd, rs1, rs2   rd.b[i] = max_signed(rs1.b[i], rs2.b[i])
 *   MBP.RQS    rd, rs1, rs2   rd = sat_int8(rshift_round(q31_round_mul(
 *                                            rs1[31:0], rs2[31:0]), rs2[37:32]))
 *
 * Encoding: R-type, opcode = 0x0B (custom-0), funct7 = 0x00,
 *           funct3 = 0 (DOT8) / 1 (MAX8) / 2 (RQS).
 *
 *   31      25 24   20 19   15 14 12 11    7 6         0
 *  +----------+-------+-------+-----+-------+-----------+
 *  | funct7=0 |  rs2  |  rs1  |  f3 |  rd   | 0001011   |
 *  +----------+-------+-------+-----+-------+-----------+
 *
 * WHY .insn AND NOT MNEMONICS.  No assembler knows these yet, so every op is
 * emitted with GAS's `.insn r` directive.  That works on the stock Zephyr SDK
 * (verified with riscv64-zephyr-elf-gcc 14.3.0, -march=rv64imac_zicsr_zifencei
 * -mabi=lp64 -mcmodel=medany) and produces exactly one 4-byte instruction per
 * intrinsic, with the register allocator free to pick rd/rs1/rs2.  objdump
 * prints them as `.insn 4, 0x........` -- decode them by hand against the
 * table above.
 *
 * WHY THIS WILL TRAP ON HART 1.  Only the big hart implements these.  Running
 * one of them on the LITTLE hart raises an illegal-instruction exception,
 * which Zephyr reports as "Illegal instruction" and then halts.  Anything
 * built with MB_PEXT_HW=1 MUST be pinned to CPU 0 with k_thread_cpu_pin();
 * MB_PEXT_ASSERT_BIG_HART() is provided for that.  Build the same source with
 * MB_PEXT_HW=0 to get the bit-identical software model, which runs anywhere
 * (the LITTLE hart, spike, or the build host) -- that is the scalar-fallback
 * path and the reference the RTL must match.
 */

#ifndef MB_PEXT_H_
#define MB_PEXT_H_

#include <stdint.h>

/* ------------------------------------------------------------------ *
 * Build-time selection.  MB_PEXT_HW=1 emits the real encodings;
 * MB_PEXT_HW=0 (the default when nothing says otherwise) substitutes the
 * software model.  Both are bit-identical by construction -- that is the
 * property the spec's semantics section pins down and the RTL must hold.
 * ------------------------------------------------------------------ */
#ifndef MB_PEXT_HW
#  if defined(CONFIG_MB_PEXT) && CONFIG_MB_PEXT
#    define MB_PEXT_HW 1
#  else
#    define MB_PEXT_HW 0
#  endif
#endif

#define MB_PEXT_OPCODE   0x0b   /* custom-0 */
#define MB_PEXT_FUNCT7   0x00
#define MB_PEXT_F3_DOT8  0
#define MB_PEXT_F3_MAX8  1
#define MB_PEXT_F3_QMUL  2
#define MB_PEXT_F3_CLIP8 3

/* ------------------------------------------------------------------ *
 * Software model.  Also the specification: if the RTL and this disagree,
 * the RTL is wrong.
 * ------------------------------------------------------------------ */

/* MBP.DOT8 -- signed 8-way int8 dot product, exact, no saturation.
 * |result| <= 8 * 128 * 128 = 131072, so it always fits in 18 bits and the
 * 64-bit destination can never overflow.  NOT accumulating: the caller adds
 * it into its own accumulator with a plain `add`.  That is deliberate --
 * see PEXT_SPEC.md section 3.1 on the register-file read-port budget. */
static inline int64_t mb_pext_dot8_sw(int64_t a, int64_t b)
{
	int64_t s = 0;
	int i;

	for (i = 0; i < 8; i++) {
		int32_t x = (int8_t)((uint64_t)a >> (8 * i));
		int32_t y = (int8_t)((uint64_t)b >> (8 * i));

		s += (int64_t)x * (int64_t)y;
	}
	return s;
}

/* MBP.MAX8 -- eight independent signed byte maxima.  ReLU is
 * mb_pext_max8(x, 0): the assembler picks x0 for the zero operand, so it
 * costs no register and no `li`. */
static inline int64_t mb_pext_max8_sw(int64_t a, int64_t b)
{
	uint64_t r = 0;
	int i;

	for (i = 0; i < 8; i++) {
		int8_t x = (int8_t)((uint64_t)a >> (8 * i));
		int8_t y = (int8_t)((uint64_t)b >> (8 * i));

		r |= (uint64_t)(uint8_t)(x > y ? x : y) << (8 * i);
	}
	return (int64_t)r;
}

/* MBP.QMUL and MBP.CLIP8 -- the quantised output stage, in two hardware ops with a
 * scalar rounding shift between them.
 *
 * This replaced a single fused MBP.RQS. The fused form measured 30 logic levels
 * (11.245 ns) against an ALU-cone budget of 11.12 ns at 35 MHz and does not fit at any
 * plausible clock -- see PEXT_FEASIBILITY.md 1.4 and the DECISION block in PEXT_SPEC.md.
 * The split puts in hardware what is cheap in silicon and expensive in software, and
 * leaves the variable rounding shift to the barrel shifter the core already has:
 *
 *   MBP.QMUL   p = (a*m + 2^30) >> 31          8 levels, 3.213 ns
 *   (scalar)   q = (p + round) >> s            addi/add + sra; `round` is loop-invariant
 *   MBP.CLIP8  rd = sext64(clamp(q,-128,127))  2 levels, 0.766 ns
 *
 * BOTH ROUNDINGS REMAIN ROUND-HALF-UP (add-then-arithmetic-shift), NOT
 * round-half-away-from-zero and NOT round-half-to-even. That is what the ModelBlaster
 * reference expression does -- `prod = (prod + (1LL<<30)) >> 31` and
 * `scaled = (scaled + round) >> output_shift` on signed C types -- and matching it exactly
 * is the difference between a bit-exact kernel and one that is 1 LSB out on roughly half
 * of all negative outputs. The scalar half is now the caller's responsibility: use
 * MB_PEXT_ROUND(s) for the constant and an arithmetic (signed) shift.
 *
 * The saturation bound is fixed at the int8 range because every conv2d_s8 and linear_s8
 * record ModelBlaster emits carries activation_min = -128 and activation_max = +127. A
 * narrower clamp (fused ReLU, activation_min = 0) is expressed by following CLIP8 with
 * MBP.MAX8 against x0. */

/* p = (a*m + 2^30) >> 31, where a = rs1[31:0] int32 accumulator, m = rs2[31:0] Q0.31. */
static inline int64_t mb_pext_qmul_sw(int64_t acc, int64_t mult)
{
	int32_t a = (int32_t)acc;
	int32_t m = (int32_t)mult;

	return ((int64_t)a * (int64_t)m + ((int64_t)1 << 30)) >> 31;
}

/* rd = sext64(clamp(rs1, -128, +127)). rs2 is ignored (encode x0). */
static inline int64_t mb_pext_clip8_sw(int64_t q)
{
	if (q < -128) {
		q = -128;
	}
	if (q > 127) {
		q = 127;
	}
	return q;
}

/* The rounding constant for a shift of s, hoisted out of the inner loop by the caller.
 * s == 0 means no shift and no rounding. */
#define MB_PEXT_ROUND(s)   ((s) ? ((int64_t)1 << ((s) - 1)) : (int64_t)0)

/* The whole output stage, for reference and for hosts without the extension. Kernels
 * should inline the three steps and hoist MB_PEXT_ROUND(s); this exists so a test can
 * check the composition against one expression. */
static inline int64_t mb_pext_requant_sw(int64_t acc, int32_t mult, uint32_t s)
{
	int64_t p = mb_pext_qmul_sw(acc, (int64_t)mult);
	int64_t q = s ? ((p + MB_PEXT_ROUND(s)) >> s) : p;

	return mb_pext_clip8_sw(q);
}

/* ------------------------------------------------------------------ *
 * The instructions.
 * ------------------------------------------------------------------ */

#if MB_PEXT_HW

static inline int64_t mb_pext_dot8(int64_t a, int64_t b)
{
	int64_t r;

	__asm__(".insn r 0x0b, 0, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
	return r;
}

static inline int64_t mb_pext_max8(int64_t a, int64_t b)
{
	int64_t r;

	__asm__(".insn r 0x0b, 1, 0, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
	return r;
}

static inline int64_t mb_pext_qmul(int64_t acc, int64_t mult)
{
	int64_t r;

	__asm__(".insn r 0x0b, 2, 0, %0, %1, %2" : "=r"(r) : "r"(acc), "r"(mult));
	return r;
}

/* rs2 is ignored; x0 named in the template so GCC never materialises a zero. */
static inline int64_t mb_pext_clip8(int64_t q)
{
	int64_t r;

	__asm__(".insn r 0x0b, 3, 0, %0, %1, x0" : "=r"(r) : "r"(q));
	return r;
}

/* ReLU form: rs2 = x0.  Written out rather than calling mb_pext_max8(x, 0)
 * because an "r" constraint on a literal 0 makes GCC materialise it with an
 * extra `li` in some contexts; naming x0 in the template never does. */
static inline int64_t mb_pext_relu8(int64_t a)
{
	int64_t r;

	__asm__(".insn r 0x0b, 1, 0, %0, %1, x0" : "=r"(r) : "r"(a));
	return r;
}

#else  /* software model */

static inline int64_t mb_pext_dot8(int64_t a, int64_t b)
{
	return mb_pext_dot8_sw(a, b);
}
static inline int64_t mb_pext_max8(int64_t a, int64_t b)
{
	return mb_pext_max8_sw(a, b);
}
static inline int64_t mb_pext_qmul(int64_t acc, int64_t mult)
{
	return mb_pext_qmul_sw(acc, mult);
}
static inline int64_t mb_pext_clip8(int64_t q)
{
	return mb_pext_clip8_sw(q);
}
static inline int64_t mb_pext_relu8(int64_t a)
{
	return mb_pext_max8_sw(a, 0);
}

#endif /* MB_PEXT_HW */

/* ------------------------------------------------------------------ *
 * Helpers a kernel actually needs.
 * ------------------------------------------------------------------ */

/* Pack the requantise parameters into RQS's rs2.  Hoist this out of the loop:
 * output_multiplier and output_shift are per-layer (or per output channel for
 * the _pc variants), never per output element. */
#define MB_PEXT_RQS_PARAM(mult, shift)                                        \
	((int64_t)((uint64_t)((uint32_t)(int32_t)(mult)) |                    \
		   ((uint64_t)((shift) & 0x3f) << 32)))

/* Load/store the 8-byte operands.  THE POINTER TYPE IS LOAD-BEARING.  int8_t*
 * carries alignment 1, so GCC cannot prove an 8-byte access through it is
 * aligned and expands it into a byte-assembly sequence instead of one `ld`.
 * Rocket takes a misaligned-address exception rather than emulating, so the
 * kernel must also *guarantee* the alignment, not merely assert it -- see
 * PEXT_SPEC.md section 6 on the NHWC layout and the IC % 8 != 0 patch path. */
typedef int64_t mb_pext_i64a __attribute__((may_alias, aligned(8)));

#define MB_PEXT_LD8(p)     (*(const mb_pext_i64a *)(const void *)(p))
#define MB_PEXT_ST8(p, v)  (*(mb_pext_i64a *)(void *)(p) = (int64_t)(v))
#define MB_PEXT_ALIGNED8(p) ((((uintptr_t)(p)) & 7u) == 0u)

/* Which hart am I on?  The MBP instructions exist only on hart 0.  Read the
 * hardware's own answer (the mhartid CSR), not a Zephyr variable -- that is
 * the same rule samples/smp_hart_proof uses to establish the CPU-to-hart map
 * in the first place. */
static inline unsigned long mb_pext_mhartid(void)
{
	unsigned long id;

	__asm__ volatile("csrr %0, mhartid" : "=r"(id));
	return id;
}

#define MB_PEXT_BIG_HART 0

static inline int mb_pext_available(void)
{
#if MB_PEXT_HW
	return mb_pext_mhartid() == MB_PEXT_BIG_HART;
#else
	return 0;
#endif
}

/* Put this at the top of every kernel compiled with MB_PEXT_HW=1.  It turns
 * "the scheduler placed this dispatch on the wrong hart" from an
 * illegal-instruction halt into a message that names the cause.  It is a
 * belt-and-braces check: the real guarantee is k_thread_cpu_pin(tid, 0) at
 * thread creation, per PEXT_SPEC.md section 7. */
#if defined(__ZEPHYR__)
#include <zephyr/sys/printk.h>
#define MB_PEXT_ASSERT_BIG_HART()                                             \
	do {                                                                  \
		if (MB_PEXT_HW && !mb_pext_available()) {                     \
			printk("MBP: kernel built for hart %d is running on "  \
			       "hart %lu -- it will take an illegal-"          \
			       "instruction trap\n",                          \
			       MB_PEXT_BIG_HART, mb_pext_mhartid());          \
		}                                                             \
	} while (0)
#else
#define MB_PEXT_ASSERT_BIG_HART() do { } while (0)
#endif

#endif /* MB_PEXT_H_ */
