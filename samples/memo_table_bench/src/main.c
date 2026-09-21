/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Lab B31 -- what a memo table costs at a DECODER's dispatch size.
 *
 * ROCC_DECOUPLED.md s8.15.16.  Every per-element rate this programme composes with was measured on
 * an ENCODER dispatch -- 172,332 elements for GELU, 217,800 for softmax -- and carried into a
 * decoder whose dispatches are 48 and 1,152.  A memo kernel's cost is a fill plus a per-element
 * rate, and at 172 k the fill is invisible while at 48 it is nearly all of it.  This measures both
 * kernels at both ends, on the same silicon, in one run:
 *
 *   CONTROL   at the encoder's own dispatch size each kernel must reproduce the rate Lab B26
 *             measured through ModelBlaster (GELU 19.24, softmax 39.975 cycles/element).  If it
 *             does not, this bench is measuring something else and no small-n number from it may
 *             be used.  Reproducing a known answer before interpreting an unknown one.
 *   DECODER   48 elements (self-attention softmax, H*seq at seq = 6), 1,320 (cross-attention,
 *             H*T), 1,152 (the MLP's SiLU/GELU activation, FF).
 *
 * The two kernels are NOT the same shape and the difference is the point:
 *   * int_gelu_s8 marks the bytes that occur and evaluates only those, so its "fill" is
 *     data-dependent -- D(n) distinct values, not 256.  The bench reports D so the model can be
 *     checked rather than assumed.
 *   * kernel_softmax_s8 (memo2) fills all 256 entries eagerly on every call, before it looks at
 *     the data.  That is a true fixed per-dispatch cost, and it is the one a cache would remove.
 *
 * Inputs are drawn from the encoder's own activation statistics (a byte range that is spread, not
 * uniform over all 256), because D(n) is a property of the data and not of the kernel.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <string.h>
/* the curated kernel #includes int_nonlin.c, so this one translation unit has the memo2 softmax,
 * int_gelu_s8 and every nl_* helper they share -- and no duplicate definitions to link against. */
#include "pext_nl_softmax_s8_pext_int_memo2.c"
/* The operators a decoder's residue is priced with that NOBODY has measured at a decoder's
 * dispatch size (ROCC_DECOUPLED.md 8.15.17): each of these is used 165x below the size Lab B26
 * measured it at, and the two that HAVE been re-measured moved +71 % and -59 %.  int_nonlin.c
 * carries an include guard so these can share one translation unit with the softmax above. */
#include "pext_nl_layernorm_s8_pext_int_rsqrt.c"
#include "pext_nl_add_pc_s8_pext_int_block.c"
#include "pext_nl_rope_s8_pext_int_rot.c"
#include "pext_nl_mul_s8_pext_int_mul.c"

#define NMAX 262144
static int8_t in_buf[NMAX];
static int8_t out_buf[NMAX];
static int8_t in2_buf[NMAX];              /* the second operand of add / mul */

/* Moonshine Tiny: D = 288, FF = 1,152, H = 8, HD = 36, partial rotary 32 of 36, encoder T = 165. */
#define MD 288
#define MH 8
#define MHD 36
#define MR 32
static float gamma_t[MD], beta_t[MD];
static int64_t amul_t[MD], bmul_t[MD];
static float cos_t[165 * (MR / 2)], sin_t[165 * (MR / 2)];

/* Which operator groups to run.  A build-time list, not a console protocol: one ELF still walks
 * every size at run time, and every line names its own n, so a line cannot be attributed to the
 * wrong size (ROCC_DECOUPLED.md 8.15.17). */
#ifndef MEMO_OPS_GELU
#define MEMO_OPS_GELU 1
#endif
#ifndef MEMO_OPS_SOFTMAX
#define MEMO_OPS_SOFTMAX 1
#endif
#ifndef MEMO_OPS_RESIDUE
#define MEMO_OPS_RESIDUE 1
#endif

static inline uint64_t cyc(void) { uint64_t c; __asm__ volatile("csrr %0, mcycle" : "=r"(c)); return c; }

/* distinct byte values present in in_buf[0..n) -- D(n), the thing int_gelu_s8's cost turns on */
static int distinct(const int8_t *p, int n)
{
	static uint8_t seen[256];
	int i, d = 0;

	memset(seen, 0, sizeof seen);
	for (i = 0; i < n; i++) seen[(uint8_t)((int)p[i] + 128)] = 1;
	for (i = 0; i < 256; i++) d += seen[i];
	return d;
}

/* A kernel that clips everything to one rail, or writes nothing, times beautifully and measures
 * nothing.  Every residue row carries the distinct output values and a checksum so a degenerate
 * run is visible in the record instead of being read as a rate. */
static int out_ok(const int8_t *p, int n, long *sum)
{
	long s = 0;
	int i;

	for (i = 0; i < n; i++) s += p[i];
	*sum = s;
	return distinct(p, n);
}

/* one timed call, repeated so a 48-element dispatch is not measured against timer noise */
#define TIME(dst, reps, expr) do {                                              \
		uint64_t t0_ = cyc();                                           \
		for (int r_ = 0; r_ < (reps); r_++) { expr; }                   \
		(dst) = (cyc() - t0_) / (reps);                                 \
	} while (0)

int main(void)
{
	uint32_t lcg = 12345u;
	const float si = 0.021946745594655436f, so = 0.021260866029994694f;

	/* the encoder's activation shape: most bytes small, a tail that reaches the rails */
	for (int i = 0; i < NMAX; i++) {
		lcg = lcg * 1103515245u + 12345u;
		int v = (int)((lcg >> 16) & 0xff) - 128;
		in_buf[i] = (int8_t)(v / 2);            /* spread but not full-range, as activations are */
	}
	printk("MEMO_START\n");

#if MEMO_OPS_GELU
	/* ---- GELU: the curated pext_int_lut path, at four dispatch sizes ------------------ */
	static const int gn[] = { 48, 1152, 1320, 8192, 172332 };
	for (unsigned i = 0; i < ARRAY_SIZE(gn); i++) {
		int n = gn[i], reps = n > 16384 ? 2 : (n > 1024 ? 50 : 400);
		uint64_t c;

		TIME(c, reps, int_gelu_s8(in_buf, out_buf, n, si, so, -128, 127));
		printk("MEMO_GELU n=%d distinct=%d cycles=%llu per_el=%llu.%02llu reps=%d\n",
		       n, distinct(in_buf, n), (unsigned long long)c,
		       (unsigned long long)(c / n), (unsigned long long)((c * 100 / n) % 100), reps);
	}

#endif /* MEMO_OPS_GELU */

#if MEMO_OPS_SOFTMAX
	/* ---- softmax memo2, as a decoder and as an encoder dispatch ----------------------- */
	static const struct { const char *what; int M, K; } sm[] = {
		{ "self  H=8 seq=6",    8,    6 },       /* 48 */
		{ "cross H=8 T=165",    8,  165 },       /* 1,320 */
		{ "encoder 1320x165", 1320, 165 },       /* 217,800: the control */
	};
	for (unsigned i = 0; i < ARRAY_SIZE(sm); i++) {
		int M = sm[i].M, K = sm[i].K, n = M * K;
		int reps = n > 16384 ? 2 : (n > 1024 ? 50 : 400);
		uint64_t c;

		TIME(c, reps, kernel_softmax_s8(in_buf, out_buf, M, K, si, so));
		printk("MEMO_SMX2 what=\"%s\" M=%d K=%d n=%d cycles=%llu per_el=%llu.%02llu reps=%d\n",
		       sm[i].what, M, K, n, (unsigned long long)c,
		       (unsigned long long)(c / n), (unsigned long long)((c * 100 / n) % 100), reps);
	}

	/* ---- the fill on its own: the same call with K = 1 and M = 1 ---------------------- */
	/* One element cannot amortise anything, so this is the fill plus one element's work --
	 * the number a cache would remove, measured rather than fitted. */
	{
		uint64_t c;

		TIME(c, 400, kernel_softmax_s8(in_buf, out_buf, 1, 1, si, so));
		printk("MEMO_SMX2_FILL M=1 K=1 cycles=%llu\n", (unsigned long long)c);
		TIME(c, 400, int_gelu_s8(in_buf, out_buf, 32, si, so, -128, 127));
		printk("MEMO_GELU_MIN n=32 distinct=%d cycles=%llu\n", distinct(in_buf, 32),
		       (unsigned long long)c);
	}
#endif /* MEMO_OPS_SOFTMAX */

#if MEMO_OPS_RESIDUE
	/* ---- the four residue operators, each at THREE sizes ------------------------------
	 * Three, not two, and the reason is in this bench's own GELU numbers: fitting
	 * c(n) = F/n + a to the two ends (48 and 172,332) predicts 33.9 c/el at n = 1,152 against
	 * the 54.70 measured -- wrong by 38 % at exactly the size a decoder uses, because F is not
	 * fixed (the fill is D(n) x 410 with D a property of the data) and a is not fixed either
	 * (9.1 c/el in L1, 21.3 out of it).  So: the decoder's own size, ten times it, and the
	 * ENCODER's own size, which doubles as this operator's known-answer control against Lab
	 * B26's committed rate. */
	for (int i = 0; i < MD; i++) {
		gamma_t[i] = 1.0f + (float)(i % 7) * 0.01f;
		beta_t[i] = (float)((i % 5) - 2) * 0.001f;
		amul_t[i] = (int64_t)(1 << 24) * 3 / 4;     /* Q8.24 per-channel, as ModelBlaster emits */
		bmul_t[i] = (int64_t)(1 << 24) / 2;
	}
	for (int i = 0; i < 165 * (MR / 2); i++) {
		/* a real rotary table: |cos|,|sin| <= 1, varying per position */
		int j = i % (MR / 2);
		cos_t[i] = 1.0f - (float)((i * 7 + j) % 100) / 200.0f;
		sin_t[i] = (float)((i * 13 + j) % 100) / 200.0f - 0.25f;
	}
	memcpy(in2_buf, in_buf + 64, sizeof in2_buf - 64);

	/* layernorm: M rows of K = D.  A decoder dispatches ONE row. */
	static const int ln_M[] = { 1, 10, 165 };
	for (unsigned i = 0; i < ARRAY_SIZE(ln_M); i++) {
		int M = ln_M[i], n = M * MD, reps = n > 16384 ? 3 : (n > 1024 ? 50 : 400);
		uint64_t c;
		long osum;
		int od;

		TIME(c, reps, kernel_layernorm_s8(in_buf, gamma_t, beta_t, out_buf, M, MD,
						  si, so, 1e-5f, -128, 127));
		od = out_ok(out_buf, n, &osum);
		printk("MEMO_OP op=layernorm_s8 kernel=pext_int_rsqrt M=%d K=%d n=%d cycles=%llu "
		       "per_el=%llu.%02llu reps=%d out_distinct=%d out_sum=%ld\n", M, MD, n, (unsigned long long)c,
		       (unsigned long long)(c / n), (unsigned long long)((c * 100 / n) % 100), reps, od, osum);
	}

	/* the residual add, per-channel: C = D */
	static const int ad_n[] = { 288, 2880, 47520 };
	for (unsigned i = 0; i < ARRAY_SIZE(ad_n); i++) {
		int n = ad_n[i], reps = n > 16384 ? 3 : (n > 1024 ? 50 : 400);
		uint64_t c;
		long osum;
		int od;

		TIME(c, reps, kernel_add_pc_s8(in_buf, in2_buf, amul_t, bmul_t, out_buf, n, MD));
		od = out_ok(out_buf, n, &osum);
		printk("MEMO_OP op=add_pc_s8 kernel=pext_int_block M=%d K=%d n=%d cycles=%llu "
		       "per_el=%llu.%02llu reps=%d out_distinct=%d out_sum=%ld\n", n / MD, MD, n, (unsigned long long)c,
		       (unsigned long long)(c / n), (unsigned long long)((c * 100 / n) % 100), reps, od, osum);
	}

	/* RoPE: T positions of H heads of HD dims, 32 of 36 rotary.  A decoder dispatches T = 1. */
	static const int ro_T[] = { 1, 10, 165 };
	for (unsigned i = 0; i < ARRAY_SIZE(ro_T); i++) {
		int T = ro_T[i], n = T * MH * MHD, reps = n > 16384 ? 3 : (n > 1024 ? 50 : 400);
		uint64_t c;
		long osum;
		int od;

		TIME(c, reps, kernel_rope_s8(in_buf, cos_t, sin_t, out_buf, T, MH, MHD, MR,
					     si, so, -128, 127));
		od = out_ok(out_buf, n, &osum);
		printk("MEMO_OP op=rope_s8 kernel=pext_int_rot M=%d K=%d n=%d cycles=%llu "
		       "per_el=%llu.%02llu reps=%d out_distinct=%d out_sum=%ld\n", T, MH * MHD, n, (unsigned long long)c,
		       (unsigned long long)(c / n), (unsigned long long)((c * 100 / n) % 100), reps, od, osum);
	}

	/* the MLP gate multiply: FF elements per layer per token */
	static const int mu_n[] = { 1152, 11520, 190080 };
	for (unsigned i = 0; i < ARRAY_SIZE(mu_n); i++) {
		int n = mu_n[i], reps = n > 16384 ? 3 : (n > 1024 ? 50 : 400);
		uint64_t c;
		long osum;
		int od;

		TIME(c, reps, kernel_mul_s8(in_buf, in2_buf, out_buf, n, si, si, so, -128, 127));
		od = out_ok(out_buf, n, &osum);
		printk("MEMO_OP op=mul_s8 kernel=pext_int_mul M=1 K=%d n=%d cycles=%llu "
		       "per_el=%llu.%02llu reps=%d out_distinct=%d out_sum=%ld\n", n, n, (unsigned long long)c,
		       (unsigned long long)(c / n), (unsigned long long)((c * 100 / n) % 100), reps, od, osum);
	}
#endif /* MEMO_OPS_RESIDUE */
	printk("MEMO_DONE\n");
	return 0;
}
