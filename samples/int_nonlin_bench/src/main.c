/* SPDX-License-Identifier: Apache-2.0
 *
 * What softmax and layer norm cost on this core, as ModelBlaster writes them and as
 * integer fixed point writes them, measured side by side on the same silicon.
 *
 * Lab B19 measures the reference kernels inside real transformer blocks. This isolates
 * the two that matter and puts the integer replacement (fpga/pynq-z2/sw/int_nonlin.c)
 * next to them, because the question SPEECH_ON_ROCKET.md section 7 has to answer is not
 * "how slow is float" but "does this need float at all" -- and if it does not, the
 * answer to the float-tainted kernels is a few hundred lines of C rather than a
 * floating-point unit.
 *
 * The float halves below are transcriptions of reference_kernels.py's own expressions:
 * two expf per element for softmax, double with a sqrt for layer norm. They are not a
 * strawman -- they are the code the generated kernels.c contains.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <math.h>
#include <string.h>
#include "int_nonlin.h"

#define KMAX  512
#define ROWS  4

/* GELU is measured on its own buffer because the thing being measured is how the cost
 * behaves with n: it is a pointwise int8 map with a 256-value domain, so a kernel that
 * evaluates the transcendental once per element and one that evaluates it at most 256
 * times per dispatch converge only when n is small.  A transformer's FFN activation is
 * seq*d_ff -- 57,600 elements per layer on Squeezeformer-XS, 131,072 on the ffn_block
 * Lab B19 measured -- so the large-n column is the one that matters and the small-n
 * column is the honest caveat beside it. */
#define GMAX  131072

static int8_t in_buf[ROWS * KMAX];
static int8_t out_i[ROWS * KMAX];
static int8_t out_f[ROWS * KMAX];
static int8_t g_in[GMAX];
static int8_t g_ref[GMAX];
static int8_t g_lut[GMAX];
static int8_t g_int[GMAX];
/* matmul_s8's requantise tail: int32 accumulators in, int8 out.  RMAX is sized to the
 * attention score matrix of one Squeezeformer-XS layer (4 heads x 100 x 100). */
#define RMAX  40000
static int32_t r_acc[RMAX];
static int8_t r_ref[RMAX];
static int8_t r_int[RMAX];

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/* reference_kernels.py SOFTMAX_S8, transcribed. */
static void ref_softmax(const int8_t *in, int8_t *out, int M, int K, float s)
{
	for (int r = 0; r < M; r++) {
		const int8_t *x = in + (size_t)r * K;
		int8_t *y = out + (size_t)r * K;
		int mx = -128;
		float sum = 0.0f;

		for (int i = 0; i < K; i++) {
			if (x[i] > mx) {
				mx = x[i];
			}
		}
		for (int i = 0; i < K; i++) {
			sum += expf((float)(x[i] - mx) * s);
		}
		for (int i = 0; i < K; i++) {
			float p = expf((float)(x[i] - mx) * s) / sum;
			int v = (int)roundf(p * 255.0f) - 128;

			y[i] = (int8_t)(v > 127 ? 127 : (v < -128 ? -128 : v));
		}
	}
}

/* reference_kernels.py LAYERNORM_S8, transcribed: double, sqrt, round. */
static void ref_layernorm(const int8_t *in, int8_t *out, int M, int K, double os)
{
	for (int r = 0; r < M; r++) {
		const int8_t *x = in + (size_t)r * K;
		int8_t *y = out + (size_t)r * K;
		double mu = 0.0, va = 0.0, inv;

		for (int i = 0; i < K; i++) {
			mu += x[i];
		}
		mu /= K;
		for (int i = 0; i < K; i++) {
			va += (x[i] - mu) * (x[i] - mu);
		}
		va /= K;
		inv = 1.0 / sqrt(va + 1e-12);
		for (int i = 0; i < K; i++) {
			int v = (int)round((x[i] - mu) * inv / os);

			y[i] = (int8_t)(v > 127 ? 127 : (v < -128 ? -128 : v));
		}
	}
}

/* reference_kernels.py GELU_S8, transcribed: one erff per element. */
static void ref_gelu(const int8_t *in, int8_t *out, int n, float si, float so,
		     int amin, int amax)
{
	const float kInvSqrt2 = 0.70710678118f;

	for (int i = 0; i < n; i++) {
		float f = (float)in[i] * si;
		float y = 0.5f * f * (1.0f + erff(f * kInvSqrt2));
		int32_t v = (int32_t)roundf(y / so);

		if (v < amin) {
			v = amin;
		}
		if (v > amax) {
			v = amax;
		}
		out[i] = (int8_t)v;
	}
}

/* The SAME reference expression, evaluated at most 256 times instead of n times.  This
 * is the population argument on its own, with the float arithmetic left exactly where
 * it was -- so it is BIT-EXACT against ref_gelu by construction, and the difference
 * between this column and the float one is entirely "stop recomputing a 256-entry
 * function".  kernels/rvv/rvv_gelu_s8_rvv_memo_lut_gather.c is the same idea for a
 * vector unit; here the gather is a scalar byte load and the point is the erff count. */
static void memo_gelu(const int8_t *in, int8_t *out, int n, float si, float so,
		      int amin, int amax)
{
	const float kInvSqrt2 = 0.70710678118f;
	int8_t tbl[256];
	uint8_t seen[256];

	for (int i = 0; i < 256; i++) {
		seen[i] = 0;
	}
	for (int i = 0; i < n; i++) {
		seen[(uint8_t)((int)in[i] + 128)] = 1;
	}
	for (int v = 0; v < 256; v++) {
		if (!seen[v]) {
			continue;
		}
		{
			float f = (float)(v - 128) * si;
			float y = 0.5f * f * (1.0f + erff(f * kInvSqrt2));
			int32_t q = (int32_t)roundf(y / so);

			if (q < amin) {
				q = amin;
			}
			if (q > amax) {
				q = amax;
			}
			tbl[v] = (int8_t)q;
		}
	}
	for (int i = 0; i < n; i++) {
		out[i] = tbl[(uint8_t)((int)in[i] + 128)];
	}
}

/* One window instead of three.  The 131,072-element float GELU costs 12 s per pass and
 * three passes of it would dominate the lab's runtime for no information: the spread
 * across windows on every smaller n is under 0.1%. */
/* reference_kernels.py MATMUL_S8's requantise tail, transcribed verbatim. */
static void ref_matmul_requant(const int32_t *acc, int8_t *out, int n, float total,
			       int amin, int amax)
{
	for (int i = 0; i < n; i++) {
		int32_t v = (int32_t)roundf((float)acc[i] * total);

		if (v < amin) {
			v = amin;
		}
		if (v > amax) {
			v = amax;
		}
		out[i] = (int8_t)v;
	}
}

#define TIME1(best, call)                                                     \
	do {                                                                  \
		unsigned int key = irq_lock();                                \
		uint64_t t0 = rdcycle();                                      \
									      \
		call;                                                         \
		best = rdcycle() - t0;                                        \
		irq_unlock(key);                                              \
	} while (0)

#define TIME(best, reps, call)                                                \
	do {                                                                  \
		best = ~0ULL;                                                 \
		for (int q = 0; q < 3; q++) {                                 \
			unsigned int key = irq_lock();                        \
			uint64_t t0 = rdcycle();                              \
									      \
			for (int rr = 0; rr < (reps); rr++) {                 \
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
	} while (0)

int main(void)
{
	uint32_t lcg = 1;
	int fails;

	printk("INT_NONLIN start clock=%d\n", CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
	fails = int_nonlin_selftest();

	for (int i = 0; i < ROWS * KMAX; i++) {
		lcg = lcg * 1103515245u + 12345u;
		in_buf[i] = (int8_t)((lcg >> 16) & 0xff);
	}

	printk("%-10s %6s %14s %14s %10s %12s %12s %10s\n", "op", "K",
	       "float cyc", "int cyc", "speedup", "float c/el", "int c/el", "max_err");
	for (int ki = 0; ki < 5; ki++) {
		const int K = (int[]){8, 32, 128, 256, 512}[ki];
		const int reps = (K <= 32) ? 40 : (K <= 128 ? 10 : 4);
		const float s_in = 0.03f;
		uint64_t bf, bi;
		int err, n = ROWS * K;

		/* the integer path takes the scale folded into (mult, shift); computing it
		 * is once per dispatch and is the only float in the integer path's setup --
		 * a real kernel takes it straight out of the IR as an integer. */
		double c = (double)s_in * 1.4426950408889634;
		int sh = 0;

		while (c < 0.5 && sh < 40) {
			c *= 2; sh++;
		}
		int32_t mult = (int32_t)(c * 2147483648.0);

		TIME(bf, reps, ref_softmax(in_buf, out_f, ROWS, K, s_in));
		TIME(bi, reps, int_softmax_s8(in_buf, out_i, ROWS, K, mult, sh));
		err = 0;
		for (int i = 0; i < n; i++) {
			int d = out_i[i] - out_f[i];

			d = d < 0 ? -d : d;
			if (d > err) {
				err = d;
			}
		}
		printk("%-10s %6d %14llu %14llu %8llu.%02llux %12llu %12llu %10d\n",
		       "softmax", K, (unsigned long long)(bf / reps),
		       (unsigned long long)(bi / reps),
		       (unsigned long long)(bf / bi),
		       (unsigned long long)((bf * 100 / bi) % 100),
		       (unsigned long long)(bf / reps / n),
		       (unsigned long long)(bi / reps / n), err);
	}
	for (int ki = 0; ki < 5; ki++) {
		const int K = (int[]){8, 32, 128, 256, 512}[ki];
		const int reps = (K <= 32) ? 40 : (K <= 128 ? 10 : 4);
		const double os = 0.05;
		uint64_t bf, bi;
		int err, n = ROWS * K;
		double invq = 1.0 / os / 256.0;
		int sh = 0;

		while (invq >= 1.0 && sh > -40) {
			invq /= 2; sh--;
		}
		while (invq < 0.5 && sh < 40) {
			invq *= 2; sh++;
		}
		int32_t mult = (int32_t)(invq * 2147483648.0);

		if (sh < 0) {
			continue;
		}
		TIME(bf, reps, ref_layernorm(in_buf, out_f, ROWS, K, os));
		TIME(bi, reps, int_layernorm_s8(in_buf, out_i, ROWS, K, NULL, NULL, mult, sh));
		err = 0;
		for (int i = 0; i < n; i++) {
			int d = out_i[i] - out_f[i];

			d = d < 0 ? -d : d;
			if (d > err) {
				err = d;
			}
		}
		printk("%-10s %6d %14llu %14llu %8llu.%02llux %12llu %12llu %10d\n",
		       "layernorm", K, (unsigned long long)(bf / reps),
		       (unsigned long long)(bi / reps),
		       (unsigned long long)(bf / bi),
		       (unsigned long long)((bf * 100 / bi) % 100),
		       (unsigned long long)(bf / reps / n),
		       (unsigned long long)(bi / reps / n), err);
	}
	/* ---- GELU ---------------------------------------------------------------
	 * Three columns, and the two mechanisms they separate are the point:
	 *   float  -- reference_kernels.py's own expression, one erff per element
	 *   memoLUT-- the SAME float expression, evaluated once per DISTINCT input byte
	 *   integer-- int_nonlin.c's int_gelu_s8: no float instruction anywhere
	 * memoLUT is bit-exact against float by construction.  integer is not, and its
	 * difference is reported rather than assumed. */
	for (int i = 0; i < GMAX; i++) {
		lcg = lcg * 1103515245u + 12345u;
		g_in[i] = (int8_t)((lcg >> 16) & 0xff);
	}
	printk("%-10s %6s %14s %14s %14s %10s %10s %8s %8s\n", "op", "n",
	       "float cyc", "memoLUT cyc", "int cyc", "f/memo", "f/int",
	       "memo_err", "int_err");
	for (int ni = 0; ni < 6; ni++) {
		const int n = (int[]){64, 256, 2048, 8192, 16384, 131072}[ni];
		/* Lab B19's OWN ffn_block quant parameters, read out of
		 * out/rocket_xformer_cost/ffn_block/ir/graph.json, so the n = 131,072 row
		 * is directly comparable with its measured 405,346,681 cycles for exactly
		 * this dispatch -- an independent cross-check of this bench rather than a
		 * second opinion about a different problem.  The scale matters: picolibc's
		 * erff takes a rational polynomial below |x| = 0.84 and an expf above it,
		 * so the FLOAT cost of this operator moves by 2x with the quantisation
		 * scale while the table cost does not move at all. */
		const float si = 0.021946745594655436f, so = 0.021260866029994694f;
		uint64_t bf, bm, bi;
		int em = 0, ei = 0;

		if (n >= 65536) {
			TIME1(bf, ref_gelu(g_in, g_ref, n, si, so, -128, 127));
			TIME1(bm, memo_gelu(g_in, g_lut, n, si, so, -128, 127));
			TIME1(bi, int_gelu_s8(g_in, g_int, n, si, so, -128, 127));
		} else {
			TIME(bf, 1, ref_gelu(g_in, g_ref, n, si, so, -128, 127));
			TIME(bm, 1, memo_gelu(g_in, g_lut, n, si, so, -128, 127));
			TIME(bi, 1, int_gelu_s8(g_in, g_int, n, si, so, -128, 127));
		}
		for (int i = 0; i < n; i++) {
			int d = g_lut[i] - g_ref[i];

			d = d < 0 ? -d : d;
			if (d > em) {
				em = d;
			}
			d = g_int[i] - g_ref[i];
			d = d < 0 ? -d : d;
			if (d > ei) {
				ei = d;
			}
		}
		printk("%-10s %6d %14llu %14llu %14llu %8llu.%02llux %8llu.%02llux %8d %8d\n",
		       "gelu", n, (unsigned long long)bf, (unsigned long long)bm,
		       (unsigned long long)bi,
		       (unsigned long long)(bf / bm),
		       (unsigned long long)((bf * 100 / bm) % 100),
		       (unsigned long long)(bf / bi),
		       (unsigned long long)((bf * 100 / bi) % 100), em, ei);
		printk("GELU_PER_EL n=%d float=%llu memo=%llu int=%llu memo_err=%d int_err=%d\n",
		       n, (unsigned long long)(bf / n), (unsigned long long)(bm / n),
		       (unsigned long long)(bi / n), em, ei);
	}

	/* The same operator at a DIFFERENT quantisation scale, to show that the float
	 * cost is a property of the input distribution and the table cost is not. */
	{
		const int n = 16384;
		uint64_t bf, bi;

		TIME(bf, 1, ref_gelu(g_in, g_ref, n, 0.0781f, 0.05f, -128, 127));
		TIME(bi, 1, int_gelu_s8(g_in, g_int, n, 0.0781f, 0.05f, -128, 127));
		printk("GELU_SCALE n=%d scale_in=0.0781 float=%llu int=%llu\n", n,
		       (unsigned long long)(bf / n), (unsigned long long)(bi / n));
	}

	/* ---- matmul_s8's requantise tail --------------------------------------
	 * kernel_matmul_s8 reduces in int32 and then spends one
	 * (int32_t)roundf((float)acc * total) per OUTPUT element.  For attention that
	 * population is heads*T*T per layer, which is the largest in an encoder, and the
	 * reduction it sits on is already integer -- so this is a float tail on an
	 * integer op rather than a float op. */
	{
		static const float tots[3] = {0.000244140625f, 0.03f, 1.0f};

		for (int ti = 0; ti < 3; ti++) {
			const float total = tots[ti];
			uint64_t bf, bi;
			int err = 0;

			for (int i = 0; i < RMAX; i++) {
				lcg = lcg * 1103515245u + 12345u;
				r_acc[i] = (int32_t)(lcg % 16516097u) - 8258048;
			}
			TIME(bf, 1, ref_matmul_requant(r_acc, r_ref, RMAX, total,
						       -128, 127));
			TIME(bi, 1, int_matmul_requant_s8(r_acc, r_int, RMAX, total,
							  -128, 127));
			for (int i = 0; i < RMAX; i++) {
				int d = r_int[i] - r_ref[i];

				d = d < 0 ? -d : d;
				if (d > err) {
					err = d;
				}
			}
			printk("REQUANT n=%d total=%d/65536 float=%llu int=%llu err=%d\n",
			       RMAX, (int)(total * 65536.0f),
			       (unsigned long long)(bf / RMAX),
			       (unsigned long long)(bi / RMAX), err);
		}
	}

	/* THE WHOLE INPUT DOMAIN, enumerated rather than sampled.  256 values is small
	 * enough to prove, which is the same argument DRONET_INTEGER.md 3 makes for
	 * batchnorm2d_s8 and add_s8 -- and it is checked ON THE BOARD, not only on the
	 * host, because the host and the target disagree about `double` promotion rules
	 * often enough to be worth a run. */
	{
		static const float sis[6] = {0.005f, 0.02f, 0.05f, 0.0781f, 0.2f, 0.5f};
		static const float sos[6] = {0.005f, 0.02f, 0.05f, 0.0781f, 0.2f, 0.5f};
		int worst = 0, nmis = 0, ncase = 0;

		for (int a = 0; a < 6; a++) {
			for (int b = 0; b < 6; b++) {
				int8_t tab[256];

				int_gelu_s8_table(tab, sis[a], sos[b], -128, 127);
				for (int q = -128; q < 128; q++) {
					int8_t r;
					int8_t qq = (int8_t)q;
					int d;

					ref_gelu(&qq, &r, 1, sis[a], sos[b], -128, 127);
					d = tab[(uint8_t)(q + 128)] - r;
					d = d < 0 ? -d : d;
					ncase++;
					if (d) {
						nmis++;
					}
					if (d > worst) {
						worst = d;
					}
				}
			}
		}
		printk("GELU_DOMAIN cases=%d mismatches=%d max_abs_err=%d\n",
		       ncase, nmis, worst);
	}

	printk("INT_NONLIN done fails=%d\n", fails);
	return 0;
}
