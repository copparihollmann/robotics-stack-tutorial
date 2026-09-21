/* SPDX-License-Identifier: Apache-2.0
 *
 * What a speech front end costs on this SoC, measured rather than reasoned about.
 *
 * Three questions, in order:
 *
 *   1. WHAT DOES ONE MULTIPLY COST?  Rocket's integer multiplier is iterative and
 *      non-pipelined, and the two harts do not have the same one (hart 0 mulUnroll=8,
 *      hart 1 at the WithNSmallCores default).  Every cost model in
 *      SPEECH_ON_ROCKET.md rests on this number, so it is measured directly: a
 *      dependent chain of one op, long enough that the loop overhead is a rounding
 *      error, with the chain carried through the result so nothing can be hoisted.
 *
 *   2. WHAT DOES ONE FRAME COST?  Per stage, so the answer says WHERE the time goes
 *      and not merely how much.  25 ms window, 10 ms hop, 512-point real FFT, 40 mel.
 *
 *   3. IS IT STILL RIGHT?  audio_fe_selftest() on the same silicon, because a
 *      front end that is fast and wrong is worse than one that is slow.
 *
 * Built three times from one source -- float, int, pext -- see the CMakeLists.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <string.h>
#include "audio_fe.h"
#ifndef FE_ARITH_FLOAT
#include "pext.h"
#endif

#define REPS        16       /* frames per timed window */
#define CHAIN       4096     /* ops in the arithmetic microbenchmark */
#define CHAIN_REPS  8

static struct fe_scratch scratch;
static int16_t pcm[FE_FRAME_LEN];
static int16_t mel[FE_NMEL];
static int16_t mfcc[FE_NDCT];

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/* ------------------------------------------------------------------ *
 * 1. the arithmetic microbenchmark
 *
 * Each kernel is a DEPENDENT chain: op i consumes op i-1's result, so what is
 * measured is the operation's LATENCY and not what a wider machine could
 * overlap.  That is the right number here, because an FFT butterfly is itself a
 * dependent chain of exactly these operations.
 *
 * TWO THINGS DEFEAT THE COMPILER, AND BOTH ARE LOAD-BEARING.  The first version
 * of this benchmark reported 0.00 cycles for `add` and for `mul`, which is not a
 * fast machine but a folded loop: with a loop-invariant operand, GCC rewrites
 * CHAIN iterations of `a += b` as `a + CHAIN*b` and CHAIN iterations of `a *= b`
 * as a power, and the timed region becomes empty.  So:
 *
 *   - `__asm__("" : "+r"(b))` tells GCC the operand changes.  It emits no
 *     instruction, costs no cycle, and makes every fold illegal.
 *   - the body is unrolled 8x, so the loop's own `addi`/`bne` amortise to
 *     0.25 instructions per measured operation instead of 2.
 * ------------------------------------------------------------------ */
static volatile int64_t sink;

#ifndef FE_ARITH_FLOAT
#define CHAIN_BENCH(name, expr)                                               \
	static uint64_t bench_##name(void)                                    \
	{                                                                     \
		uint64_t best = ~0ULL;                                        \
		int r;                                                        \
									      \
		for (r = 0; r < CHAIN_REPS; r++) {                            \
			int64_t a = 0x0123456789abcdefLL ^ r;                 \
			int64_t b = 0x000000007f3d21c4LL;                     \
			unsigned int key = irq_lock();                        \
			uint64_t t0 = rdcycle();                              \
			int i;                                                \
									      \
			for (i = 0; i < CHAIN / 8; i++) {                     \
				__asm__("" : "+r"(b));                        \
				a = (expr); a = (expr); a = (expr); a = (expr);\
				a = (expr); a = (expr); a = (expr); a = (expr);\
			}                                                     \
			{                                                     \
				uint64_t d = rdcycle() - t0;                  \
									      \
				irq_unlock(key);                              \
				sink = a;                                     \
				if (d < best) {                               \
					best = d;                             \
				}                                             \
			}                                                     \
		}                                                             \
		return best;                                                  \
	}

CHAIN_BENCH(nop,  a ^ 0)              /* the loop itself: the floor to subtract */
CHAIN_BENCH(add,  a + b)
CHAIN_BENCH(mul,  a * b)
CHAIN_BENCH(mulw, (int64_t)((int32_t)a * (int32_t)b))
/* A 64-bit multiply by a SMALL operand -- what fe_melbank does, and the case
 * Rocket's mulEarlyOut is supposed to shorten. */
CHAIN_BENCH(mul_small, a * (b & 0x7fff))
/* The scalar form of MBP.QMUL, i.e. what the FE_ARITH=int front end executes. */
CHAIN_BENCH(qmul_sw, mb_pext_qmul_sw(a, b))
#if MB_PEXT_HW
CHAIN_BENCH(qmul_hw, mb_pext_qmul(a, b))
CHAIN_BENCH(dot8_hw, mb_pext_dot8(a, b))
CHAIN_BENCH(max8_hw, mb_pext_max8(a, b))
#endif

static void arith_bench(void)
{
	printk("FE_ARITH_BENCH chain=%d reps=%d unroll=8 unit=cycles_per_op_x100\n",
	       CHAIN, CHAIN_REPS);
#define REPORT(n)                                                             \
	do {                                                                  \
		uint64_t c = bench_##n();                                     \
									      \
		printk("  %-10s %6llu   (%llu cycles for %d ops)\n", #n,       \
		       (unsigned long long)(c * 100u / CHAIN),                 \
		       (unsigned long long)c, CHAIN);                          \
	} while (0)
	REPORT(nop);
	REPORT(add);
	REPORT(mul);
	REPORT(mulw);
	REPORT(mul_small);
	REPORT(qmul_sw);
#if MB_PEXT_HW
	REPORT(qmul_hw);
	REPORT(dot8_hw);
	REPORT(max8_hw);
#endif
#undef REPORT
}
#endif /* !FE_ARITH_FLOAT */

/* ------------------------------------------------------------------ *
 * 2. the per-stage frame cost
 * ------------------------------------------------------------------ */
#define TIME_STAGE(label, call)                                               \
	do {                                                                  \
		uint64_t best = ~0ULL;                                        \
		int r, q;                                                     \
									      \
		for (q = 0; q < 3; q++) {                                     \
			unsigned int key = irq_lock();                        \
			uint64_t t0 = rdcycle();                              \
									      \
			for (r = 0; r < REPS; r++) {                          \
				call;                                         \
			}                                                     \
			{                                                     \
				uint64_t d = rdcycle() - t0;                  \
									      \
				irq_unlock(key);                              \
				if (d < best) {                               \
					best = d;                             \
				}                                             \
			}                                                     \
		}                                                             \
		printk("  %-12s %10llu cycles/frame\n", label,                \
		       (unsigned long long)(best / REPS));                    \
		total += best / REPS;                                         \
	} while (0)

static void frame_bench(void)
{
	uint64_t total = 0, whole = ~0ULL;
	int r, q;

	printk("FE_FRAME_BENCH arith=%s nfft=%d frame=%d hop=%d nmel=%d ndct=%d reps=%d\n",
	       FE_ARITH_NAME, FE_NFFT, FE_FRAME_LEN, FE_HOP_LEN, FE_NMEL, FE_NDCT, REPS);

	TIME_STAGE("window", fe_window(pcm, &scratch));
	TIME_STAGE("cfft256", fe_cfft256(&scratch));
	TIME_STAGE("split_real", fe_split_real(&scratch));
	TIME_STAGE("power", fe_power(&scratch));
	TIME_STAGE("melbank", fe_melbank(&scratch, mel));
	TIME_STAGE("dct", fe_dct(mel, mfcc));

	/* The stages timed back to back are not the same thing as the chain timed as a
	 * chain: each stage above ran REPS times over an already-warm working set.  This
	 * is the number that decides the duty cycle. */
	for (q = 0; q < 3; q++) {
		unsigned int key = irq_lock();
		uint64_t t0 = rdcycle();

		for (r = 0; r < REPS; r++) {
			fe_logmel_frame(pcm, &scratch, mel);
			fe_dct(mel, mfcc);
		}
		{
			uint64_t d = rdcycle() - t0;

			irq_unlock(key);
			if (d < whole) {
				whole = d;
			}
		}
	}
	printk("FE_FRAME arith=%s stages_sum=%llu whole=%llu cycles\n",
	       FE_ARITH_NAME, (unsigned long long)total,
	       (unsigned long long)(whole / REPS));

	/* Frames per second of audio = rate / hop, rounded: 15993.859/160 = 99.96 and
	 * 15993.859/320 = 49.98.  Both round to the integer the runner divides by, and
	 * the 0.04 % is far below the run-to-run spread. */
	{
		unsigned int fps = (FE_SAMPLE_RATE_MILLIHZ / FE_HOP_LEN + 500) / 1000;

		printk("FE_RTF arith=%s cycles_per_frame=%llu frames_per_s=%u "
		       "cycles_per_s_of_audio=%llu clock_hz=%d\n",
		       FE_ARITH_NAME, (unsigned long long)(whole / REPS), fps,
		       (unsigned long long)(whole / REPS) * fps,
		       CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * 1000);
	}
}

/* A deterministic, speech-shaped test frame: three harmonics plus a noise floor at
 * roughly this microphone's measured -61 dBFS.  Generated by an integer recurrence so
 * the FE_ARITH=int build pulls in no libm of its own. */
static void make_frame(void)
{
	uint32_t lcg = 12345;
	int n;

	for (n = 0; n < FE_FRAME_LEN; n++) {
		/* 437 / 874 / 1311 Hz, the bench-fan family MICROPHONE.md found. */
		static const int32_t k[3] = {3000, 900, 300};
		int32_t v = 0;
		int h;

		for (h = 0; h < 3; h++) {
			/* sin(2*pi*437*(h+1)*n/15993.859) from a 64-entry table */
			static const int16_t s64[64] = {
				0, 3212, 6393, 9512, 12539, 15446, 18204, 20787,
				23170, 25330, 27245, 28898, 30273, 31357, 32138, 32610,
				32767, 32610, 32138, 31357, 30273, 28898, 27245, 25330,
				23170, 20787, 18204, 15446, 12539, 9512, 6393, 3212,
				0, -3212, -6393, -9512, -12539, -15446, -18204, -20787,
				-23170, -25330, -27245, -28898, -30273, -31357, -32138, -32610,
				-32767, -32610, -32138, -31357, -30273, -28898, -27245, -25330,
				-23170, -20787, -18204, -15446, -12539, -9512, -6393, -3212
			};
			/* 437*(h+1)/15993.859 * 64 ~= 1.749*(h+1) phase steps per sample,
			 * kept in Q8 so the phase does not drift. */
			uint32_t ph = ((uint32_t)n * 448u * (h + 1)) >> 8;

			v += (k[h] * s64[ph & 63]) >> 15;
		}
		lcg = lcg * 1103515245u + 12345u;
		v += (int32_t)((lcg >> 16) & 0x3f) - 32;
		pcm[n] = (int16_t)v;
	}
}

int main(void)
{
	int fails;

#if MB_PEXT_HW
	/* The MBP encodings exist on hart 0 only. Zephyr starts main() on CPU 0 and
	 * nothing here sleeps, but say it anyway -- the failure mode is a halt. */
	k_thread_cpu_pin(k_current_get(), 0);
	MB_PEXT_ASSERT_BIG_HART();
#endif
#ifdef FE_ARITH_FLOAT
	printk("AUDIO_FE_BENCH start arith=%s mb_pext_hw=0 hart=0 clock=%d\n",
	       FE_ARITH_NAME, CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
#else
	printk("AUDIO_FE_BENCH start arith=%s mb_pext_hw=%d hart=%lu clock=%d\n",
	       FE_ARITH_NAME, (int)MB_PEXT_HW, mb_pext_mhartid(),
	       CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
#endif

	make_frame();
	fails = audio_fe_selftest();

	/* Print the feature vector itself.  The three builds must agree to within the
	 * divergence SPEECH_ON_ROCKET.md quotes, and the runner diffs them -- a front end
	 * that got faster by computing something else is the failure this catches. */
	fe_logmel_frame(pcm, &scratch, mel);
	fe_dct(mel, mfcc);
	printk("FE_LOGMEL");
	for (int i = 0; i < FE_NMEL; i++) {
		printk(" %d", mel[i]);
	}
	printk("\n");
	printk("FE_MFCC");
	for (int i = 0; i < FE_NDCT; i++) {
		printk(" %d", mfcc[i]);
	}
	printk("\n");

#ifndef FE_ARITH_FLOAT
	arith_bench();
#else
	printk("FE_ARITH_BENCH skipped (float build: the chain ops are integer)\n");
#endif
	frame_bench();

	printk("AUDIO_FE_BENCH done arith=%s fails=%d\n", FE_ARITH_NAME, fails);
	return 0;
}
