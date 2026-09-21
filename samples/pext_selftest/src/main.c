/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * pext_selftest -- the differential test that pins MBP's four instructions to the C
 * reference in fpga/pynq-z2/sw/pext.h.
 *
 * ONE SOURCE, THREE BUILDS, and the whole point is that all three print the same bytes:
 *
 *   MB_PEXT_HW=1, spike_riscv64   the real encodings, executed by the patched TACIT spike
 *                                 (patches/0006-spike-mbp-pext-insns.patch)
 *   MB_PEXT_HW=0, spike_riscv64   the software model, same compiler, same target
 *   MB_PEXT_HW=0, host cc         the software model, a different compiler on a different
 *                                 ISA -- an independent reading of the reference
 *
 * scripts/11_pext_selftest.sh builds and diffs all three.
 *
 * WHY THE BINARY ALSO CHECKS ITSELF.  Every case is computed twice inside the same
 * program: once through mb_pext_*() (the instruction, when MB_PEXT_HW=1) and once
 * through mb_pext_*_sw() (the reference, always compiled in). A mismatch prints the
 * exact operands and bumps a counter, so a wrong Spike implementation names itself
 * rather than showing up as a diff of two 200-line logs.
 *
 * WHAT THE CASES COVER, deliberately
 *   DOT8   full range (all lanes -128 x -128 = +131072, and -128 x +127 = -130048),
 *          mixed signs, single-lane, zero.
 *   MAX8   -128 vs +127 in both operand orders, and the ReLU form with rs2 = x0, which
 *          is a DIFFERENT ENCODING from max8(x, 0) and so is tested separately.
 *   QMUL   the rounding boundary. p = +2^30 and p = -2^30 are exact half-LSB ties:
 *          round-half-up gives +1 and 0, round-half-away-from-zero gives +1 and -1,
 *          round-half-to-even gives 0 and 0. Only half-up produces the pair the
 *          reference produces, so these two cases alone separate the three rules.
 *          Also both int32 extremes, where the product needs all 62 bits.
 *   CLIP8  -129/-128 and +127/+128, plus int64 extremes, i.e. saturation at both ends.
 */

#include <stdint.h>

#ifdef __ZEPHYR__
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/arch/cpu.h>
#include <tacit/tacit.h>
#define OUT printk
#else
#include <stdio.h>
#define OUT printf
#endif

#include "pext.h"

/* Printing one line per case costs roughly 300k instructions per line on spike's HTIF
 * console -- two orders of magnitude more than the case itself -- so a full-verbosity
 * run is an 80 M instruction, 40 MB trace. PEXT_VERBOSE=0 keeps every case and every
 * comparison and drops only the per-case line, which is what a *traced* run wants.
 * MISMATCH lines are never suppressed: a failure has to be visible at any verbosity. */
#ifndef PEXT_VERBOSE
#define PEXT_VERBOSE 1
#endif

static unsigned mismatches;
static unsigned cases;

/* 64-bit values are printed as two 32-bit halves: printk's %llx is optional in Zephyr
 * and the host's is not, and this file has to print byte-identically under both. */
static void show(const char *op, int64_t a, int64_t b, int64_t got, int64_t want)
{
	cases++;
#if PEXT_VERBOSE
	OUT("%s a=%08x%08x b=%08x%08x r=%08x%08x\n", op,
	    (unsigned int)(uint32_t)((uint64_t)a >> 32), (unsigned int)(uint32_t)(uint64_t)a,
	    (unsigned int)(uint32_t)((uint64_t)b >> 32), (unsigned int)(uint32_t)(uint64_t)b,
	    (unsigned int)(uint32_t)((uint64_t)got >> 32), (unsigned int)(uint32_t)(uint64_t)got);
#endif
	if (got != want) {
		mismatches++;
		OUT("MISMATCH %s a=%08x%08x b=%08x%08x got=%08x%08x want=%08x%08x\n", op,
		    (unsigned int)(uint32_t)((uint64_t)a >> 32), (unsigned int)(uint32_t)(uint64_t)a,
		    (unsigned int)(uint32_t)((uint64_t)b >> 32), (unsigned int)(uint32_t)(uint64_t)b,
		    (unsigned int)(uint32_t)((uint64_t)got >> 32), (unsigned int)(uint32_t)(uint64_t)got,
		    (unsigned int)(uint32_t)((uint64_t)want >> 32), (unsigned int)(uint32_t)(uint64_t)want);
	}
}

/* Pack eight signed bytes little-endian, the way an `ld` of eight int8s lands. */
static int64_t pack8(int b0, int b1, int b2, int b3, int b4, int b5, int b6, int b7)
{
	uint64_t v = 0;
	const int bs[8] = { b0, b1, b2, b3, b4, b5, b6, b7 };
	int i;

	for (i = 0; i < 8; i++) {
		v |= (uint64_t)(uint8_t)(int8_t)bs[i] << (8 * i);
	}
	return (int64_t)v;
}

/* A fixed LCG, so "pseudo-random" means the same bits on every build and every host. */
static uint64_t lcg_state = 0x123456789abcdefULL;

static uint64_t lcg(void)
{
	lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL;
	return lcg_state;
}

static void test_dot8(void)
{
	int64_t a, b;
	int i;

	/* Zero. */
	a = 0; b = 0;
	show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));

	/* All lanes -1 x -1 = +8. */
	a = -1; b = -1;
	show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));

	/* Full negative range in both operands: 8 * (-128 * -128) = +131072. */
	a = pack8(-128, -128, -128, -128, -128, -128, -128, -128);
	b = a;
	show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));

	/* Largest magnitude negative: 8 * (-128 * 127) = -130048. */
	b = pack8(127, 127, 127, 127, 127, 127, 127, 127);
	show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));

	/* Both maximal positive: 8 * 127 * 127 = +129032. */
	a = b;
	show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));

	/* One lane only, in the top byte -- catches a shift that loses the sign. */
	a = pack8(0, 0, 0, 0, 0, 0, 0, -128);
	b = pack8(0, 0, 0, 0, 0, 0, 0, 127);
	show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));

	/* Alternating signs -- catches lane-order and sign-extension errors that
	 * happen to cancel on uniform inputs. */
	a = pack8(-128, 127, -1, 1, -64, 64, -3, 3);
	b = pack8(127, -128, 1, -1, 64, -64, 3, -3);
	show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));

	for (i = 0; i < 12; i++) {
		a = (int64_t)lcg();
		b = (int64_t)lcg();
		show("DOT8 ", a, b, mb_pext_dot8(a, b), mb_pext_dot8_sw(a, b));
	}
}

static void test_max8(void)
{
	int64_t a, b;
	int i;

	a = pack8(-128, 127, -128, 127, 0, -1, 1, -128);
	b = pack8(127, -128, -128, 127, 0, 1, -1, 127);
	show("MAX8 ", a, b, mb_pext_max8(a, b), mb_pext_max8_sw(a, b));
	show("MAX8 ", b, a, mb_pext_max8(b, a), mb_pext_max8_sw(b, a));

	/* Every lane strictly negative: ReLU must flatten all eight to zero. */
	a = pack8(-1, -2, -3, -128, -127, -64, -100, -7);
	show("RELU8", a, 0, mb_pext_relu8(a), mb_pext_max8_sw(a, 0));

	/* Every lane non-negative: ReLU must be the identity. */
	a = pack8(0, 1, 2, 127, 126, 64, 100, 7);
	show("RELU8", a, 0, mb_pext_relu8(a), mb_pext_max8_sw(a, 0));

	/* max8(x, 0) with a real zero register, next to the x0 form above: the two
	 * encodings differ (rs2 = some register holding 0, vs rs2 = x0) and both must
	 * give the same answer. */
	a = pack8(-128, 127, -1, 1, 0, -128, 127, -5);
	show("MAX8 ", a, 0, mb_pext_max8(a, 0), mb_pext_max8_sw(a, 0));
	show("RELU8", a, 0, mb_pext_relu8(a), mb_pext_max8_sw(a, 0));

	for (i = 0; i < 12; i++) {
		a = (int64_t)lcg();
		b = (int64_t)lcg();
		show("MAX8 ", a, b, mb_pext_max8(a, b), mb_pext_max8_sw(a, b));
		show("RELU8", a, 0, mb_pext_relu8(a), mb_pext_max8_sw(a, 0));
	}
}

static void qmul_case(int32_t acc, int32_t mult)
{
	int64_t a = (int64_t)acc, m = (int64_t)mult;

	show("QMUL ", a, m, mb_pext_qmul(a, m), mb_pext_qmul_sw(a, m));
}

static void test_qmul(void)
{
	int i;

	/* The rounding boundary. 32768 * 32768 = 2^30 exactly, which is a half-LSB tie
	 * after the >> 31. See the header comment: these two lines are what separate
	 * round-half-up from half-away-from-zero and from half-to-even. */
	qmul_case(32768, 32768);        /* p = +2^30  -> half-up +1 */
	qmul_case(-32768, 32768);       /* p = -2^30  -> half-up  0 */
	qmul_case(98304, 32768);        /* p = +3*2^30 -> half-up +2 */
	qmul_case(-98304, 32768);       /* p = -3*2^30 -> half-up -1 */
	qmul_case(32768, -32768);
	qmul_case(-32768, -32768);

	/* One ULP either side of the tie, so a rounding constant that is off by one
	 * cannot hide. */
	qmul_case(32767, 32768);
	qmul_case(32769, 32768);
	qmul_case(-32767, 32768);
	qmul_case(-32769, 32768);

	/* Trivia and extremes. */
	qmul_case(0, 0);
	qmul_case(0, INT32_MIN);
	qmul_case(-1, 1);
	qmul_case(1, -1);
	qmul_case(INT32_MIN, INT32_MIN);   /* product = 2^62, the widest case */
	qmul_case(INT32_MIN, INT32_MAX);
	qmul_case(INT32_MAX, INT32_MAX);
	qmul_case(INT32_MAX, INT32_MIN);
	qmul_case(INT32_MIN, 1);
	qmul_case(INT32_MAX, 1);

	/* A realistic quantised multiplier (0.5 in Q0.31) against assorted accumulators. */
	for (i = -4; i <= 4; i++) {
		qmul_case(i * 1000003, 1073741824);
	}

	/* The two lcg() calls are sequenced into named variables on purpose. As
	 * arguments to one call their evaluation order is unspecified, and riscv64-gcc
	 * and x86-64-gcc pick opposite orders -- which swapped a and b in the printed
	 * line (not in the result: the product is commutative) and made the host
	 * reference and the Spike run disagree on paper for no real reason. */
	for (i = 0; i < 12; i++) {
		int32_t qa = (int32_t)(uint32_t)lcg();
		int32_t qm = (int32_t)(uint32_t)lcg();

		qmul_case(qa, qm);
	}
}

static void clip8_case(int64_t q)
{
	show("CLIP8", q, 0, mb_pext_clip8(q), mb_pext_clip8_sw(q));
}

static void test_clip8(void)
{
	int i;

	clip8_case(0);
	clip8_case(127);
	clip8_case(128);          /* saturates to +127 */
	clip8_case(129);
	clip8_case(-128);
	clip8_case(-129);         /* saturates to -128 */
	clip8_case(-130);
	clip8_case(1);
	clip8_case(-1);
	clip8_case(255);
	clip8_case(256);
	clip8_case(-256);
	clip8_case(INT32_MAX);
	clip8_case(INT32_MIN);
	clip8_case(INT64_MAX);
	clip8_case(INT64_MIN);
	clip8_case((int64_t)1 << 31);
	clip8_case(-((int64_t)1 << 31));

	for (i = 0; i < 8; i++) {
		clip8_case((int64_t)lcg());
	}
}

/* The composed output stage: QMUL, a scalar rounding shift, then CLIP8 -- checked
 * against mb_pext_requant_sw(), the single expression the spec says it must equal.
 * This is where a round-half-away-from-zero QMUL would show up as a 1-LSB error on
 * about half of all negative outputs. */
static void test_requant(void)
{
	static const int32_t mults[] = { 1073741824, 1518500250, 2147483647, 1000000000 };
	static const uint32_t shifts[] = { 0, 1, 7, 15, 31 };
	unsigned mi, si;
	int k;

	for (mi = 0; mi < sizeof(mults) / sizeof(mults[0]); mi++) {
		for (si = 0; si < sizeof(shifts) / sizeof(shifts[0]); si++) {
			for (k = -3; k <= 3; k++) {
				int64_t acc = (int64_t)k * 987654321;
				uint32_t s = shifts[si];
				int64_t p = mb_pext_qmul(acc, (int64_t)mults[mi]);
				int64_t q = s ? ((p + MB_PEXT_ROUND(s)) >> s) : p;
				int64_t got = mb_pext_clip8(q);
				int64_t want = mb_pext_requant_sw(acc, mults[mi], s);

				show("RQ   ", acc, (int64_t)mults[mi] + ((int64_t)s << 32),
				     got, want);
			}
		}
	}
}

/* ------------------------------------------------------------------ *
 * The counted kernel.
 *
 * One int8 dot-product layer with a requantised output stage -- the shape §2 of
 * PEXT_SPEC.md argues from. Built with MB_PEXT_HW=1 it is DOT8/QMUL/CLIP8/MAX8;
 * built with MB_PEXT_HW=0 it is the scalar model. Same source, same compiler, same
 * spike: the minstret delta between the two builds is the instruction-count saving,
 * measured rather than projected.
 * ------------------------------------------------------------------ */
#define KERN_OUT   16
#define KERN_K     32         /* int8 taps per output, a multiple of 8 */
#define KERN_PASS  50

static int8_t kern_w[KERN_OUT][KERN_K] __attribute__((aligned(8)));
static int8_t kern_x[KERN_K] __attribute__((aligned(8)));
static int8_t kern_y[KERN_OUT];

static void kern_init(void)
{
	int o, k;

	for (k = 0; k < KERN_K; k++) {
		kern_x[k] = (int8_t)(lcg() >> 33);
	}
	for (o = 0; o < KERN_OUT; o++) {
		for (k = 0; k < KERN_K; k++) {
			kern_w[o][k] = (int8_t)(lcg() >> 33);
		}
	}
}

static uint32_t kern_run(void)
{
	const int64_t mult = 1518500250;
	const uint32_t shift = 9;
	const int64_t round = MB_PEXT_ROUND(shift);
	uint32_t sum = 0;
	int pass, o, k;

	for (pass = 0; pass < KERN_PASS; pass++) {
		for (o = 0; o < KERN_OUT; o++) {
			int64_t acc = 0;

			for (k = 0; k < KERN_K; k += 8) {
				acc += mb_pext_dot8(MB_PEXT_LD8(&kern_x[k]),
						    MB_PEXT_LD8(&kern_w[o][k]));
			}
			acc = mb_pext_qmul(acc, mult);
			acc = (acc + round) >> shift;
			kern_y[o] = (int8_t)mb_pext_clip8(acc);
		}
		/* ReLU the eight-byte groups of the output, x0 form. */
		for (o = 0; o < KERN_OUT; o += 8) {
			MB_PEXT_ST8(&kern_y[o], mb_pext_relu8(MB_PEXT_LD8(&kern_y[o])));
		}
		for (o = 0; o < KERN_OUT; o++) {
			sum = sum * 31u + (uint32_t)(uint8_t)kern_y[o];
		}
	}
	return sum;
}

#if defined(__ZEPHYR__) && defined(__riscv)
static inline uint64_t rd_minstret(void)
{
	uint64_t v;

	__asm__ volatile("csrr %0, minstret" : "=r"(v));
	return v;
}
#endif

int main(void)
{
	uint32_t checksum;
#if defined(__ZEPHYR__) && defined(__riscv)
	uint64_t i0, i1, probe0, probe1;
#endif

#ifdef __ZEPHYR__
	LTraceEncoderType *encoder = l_trace_encoder_get(arch_curr_cpu()->id);

	l_trace_encoder_configure_target(encoder, TARGET_PRINT);
	l_trace_encoder_start(encoder);
#endif

	OUT("PEXT_SELFTEST start hw=%d verbose=%d\n", (int)MB_PEXT_HW, (int)PEXT_VERBOSE);
	MB_PEXT_ASSERT_BIG_HART();

	test_dot8();
	test_max8();
	test_qmul();
	test_clip8();
	test_requant();

	kern_init();

#if defined(__ZEPHYR__) && defined(__riscv)
	/* Probe minstret before leaning on it: if the counter were stuck the delta
	 * below would read 0 and the instruction count would be a silent lie. */
	probe0 = rd_minstret();
	__asm__ volatile("nop; nop; nop; nop");
	probe1 = rd_minstret();

	i0 = rd_minstret();
	checksum = kern_run();
	i1 = rd_minstret();

	OUT("PEXT_SELFTEST kernel checksum=%08x\n", (unsigned int)checksum);
	OUT("PEXT_SELFTEST_INSTRET probe=%u kernel=%u%09u total=%u%09u\n",
	    (unsigned int)(probe1 - probe0),
	    (unsigned int)((i1 - i0) / 1000000000ULL),
	    (unsigned int)((i1 - i0) % 1000000000ULL),
	    (unsigned int)(i1 / 1000000000ULL),
	    (unsigned int)(i1 % 1000000000ULL));
#else
	checksum = kern_run();
	OUT("PEXT_SELFTEST kernel checksum=%08x\n", (unsigned int)checksum);
#endif

	OUT("PEXT_SELFTEST done cases=%u mismatches=%u\n", cases, mismatches);
	OUT("PEXT_SELFTEST %s\n", mismatches ? "FAIL" : "PASS");

#ifdef __ZEPHYR__
	l_trace_encoder_stop(encoder);
	/* Let the trace buffer drain before the host is told to exit. */
	for (int i = 0; i < 10; i++) {
		__asm__("nop");
	}
	sys_reboot(SYS_REBOOT_COLD);
#endif
	return mismatches ? 1 : 0;
}
