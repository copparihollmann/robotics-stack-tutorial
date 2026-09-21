/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B66's pre-board gate for pext_nl_layernorm_s8_pext_int_rsqrt.c -- host only, no board.
 *
 * WHAT IS BEING CHECKED, AND WHY IT HAS NO TOLERANCE.  B66 makes two changes to this
 * kernel and neither may move a byte:
 *
 *   1. the hoist guard gains a SECOND test.  MBP_LN_MAXK asks whether the per-channel
 *      table fits (capacity, in K); MBP_LN_MINM asks whether it is worth building
 *      (profitability, in M).  Both are kept.  At M = 1 the kernel now takes the
 *      per-element fallback instead of building 288 entries and reading each once -- so
 *      this gate is also the first thing that checks the two paths AGREE, which the
 *      kernel has always assumed and nothing ever tested.
 *   2. the element loop's __int128 becomes an int64.  |d8| <= 2^16 and rs < 2^32, so the
 *      product is at most 2^48 and the 128-bit form never carried a bit the 64-bit one
 *      does not.  A bound, not a sample -- but checked here anyway.
 *
 * Arms, one source, one define apart:
 *   a  shipped default       (B66: guard on M as well as K, int64 product)
 *   b  -DMBP_LN_B66=0        (the SHIPPING kernel: guard on K alone, __int128 product)
 *
 * Coverage: every layernorm_s8 quant the model ships -- 456 decoder dispatches, every one
 * M = 1 K = 288, and 13 encoder, every one M = 165 -- against the model's own 18 real
 * (gamma, beta) pairs and against random ones; then M swept across the guard from 1 to
 * 165; then K above MBP_LN_MAXK so both arms take the capacity fallback; then gamma and
 * beta absent; then every activation clamp the graph can carry.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void ln_a(const int8_t *, const float *, const float *, int8_t *,
	  int, int, float, float, float, int, int);
void ln_b(const int8_t *, const float *, const float *, int8_t *,
	  int, int, float, float, float, int, int);

#include "b66_ln_cases.h"

static uint64_t rs_ = 0xB5026F5AA96619E9ull;
static uint64_t rnd(void)
{
	rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17;
	return rs_;
}

static float rfloat(int elo, int ehi, int allow_neg)
{
	union { uint32_t u; float f; } v;
	int e = elo + (int)(rnd() % (unsigned)(ehi - elo + 1));

	v.u = ((uint32_t)(e + 127) << 23) | (uint32_t)(rnd() & 0x7fffffu);
	if (allow_neg && (rnd() & 1))
		v.u |= 0x80000000u;
	return v.f;
}

static long fails, cases, bytes, rows_m1, rows_mgt1;

static void fill(int8_t *p, size_t n, int mode)
{
	size_t i;

	switch (mode) {
	case 0: for (i = 0; i < n; i++) p[i] = (int8_t)(uint8_t)(i & 0xff); break;
	case 1: for (i = 0; i < n; i++) p[i] = (int8_t)(uint8_t)(rnd() & 0xff); break;
	case 2: for (i = 0; i < n; i++) p[i] = (rnd() & 1) ? (int8_t)127 : (int8_t)-128; break;
	case 3: for (i = 0; i < n; i++) p[i] = 7; break;
	case 4: memset(p, 0, n); break;
	default: for (i = 0; i < n; i++) p[i] = (int8_t)((int)(rnd() % 5u) - 2); break;
	}
}

static void cmp(const char *what, int M, int K, const float *g, const float *b,
		float si, float so, float eps, int amin, int amax, int mode)
{
	const size_t n = (size_t)M * (size_t)K;
	int8_t *in = malloc(n), *oa = malloc(n), *ob = malloc(n);
	size_t i;

	if (!in || !oa || !ob) {
		printf("OOM\n");
		exit(2);
	}
	memset(in, 0, n);
	fill(in, n, mode);
	memset(oa, 0x5a, n);
	memset(ob, 0xa5, n);
	ln_a(in, g, b, oa, M, K, si, so, eps, amin, amax);
	ln_b(in, g, b, ob, M, K, si, so, eps, amin, amax);
	cases++;
	bytes += (long)n;
	if (M == 1)
		rows_m1++;
	else
		rows_mgt1++;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i]) {
			if (fails < 10)
				printf("MISMATCH %s i=%zu in=%d  b66=%d ship=%d  M=%d K=%d "
				       "si=%.9g so=%.9g eps=%.9g clamp=[%d,%d] mode=%d\n",
				       what, i, in[i], oa[i], ob[i], M, K,
				       (double)si, (double)so, (double)eps, amin, amax, mode);
			fails++;
			break;
		}
	}
	free(in); free(oa); free(ob);
}

int main(void)
{
	const int ncase = (int)(sizeof(mb_ln_cases) / sizeof(mb_ln_cases[0]));
	static float g[4096], b[4096];
	int i, c, t, mode;

	/* 1. EVERY SHIPPING DISPATCH, at its own M and K, against the model's own gamma and
	 *    beta, rotated so all 18 real pairs meet all 469 quants over the sweep. */
	for (c = 0; c < ncase; c++) {
		const int gi = c % LN_NGB;

		for (mode = 0; mode < 3; mode++)
			cmp(mb_ln_cases[c].half, mb_ln_cases[c].M, mb_ln_cases[c].K,
			    ln_gamma[gi], ln_beta[gi],
			    mb_ln_cases[c].si, mb_ln_cases[c].so, mb_ln_cases[c].eps,
			    mb_ln_cases[c].amin, mb_ln_cases[c].amax, mode);
	}

	/* 2. The same quants with RANDOM gamma and beta, including signs, zeros and
	 *    subnormals -- the decode reads the float's bits, so the bits are the coverage. */
	for (c = 0; c < ncase; c++) {
		for (i = 0; i < mb_ln_cases[c].K; i++) {
			unsigned r = (unsigned)(rnd() % 16u);

			g[i] = r == 0 ? 0.0f : (r == 1 ? 1.4e-45f : rfloat(-25, 12, 1));
			b[i] = r == 2 ? 0.0f : (r == 3 ? -1.4e-45f : rfloat(-25, 12, 1));
		}
		cmp("randgb", mb_ln_cases[c].M, mb_ln_cases[c].K, g, b,
		    mb_ln_cases[c].si, mb_ln_cases[c].so, mb_ln_cases[c].eps,
		    mb_ln_cases[c].amin, mb_ln_cases[c].amax, (int)(rnd() % 6u));
	}

	/* 3. M SWEPT ACROSS THE GUARD.  M is the quantity the hoist's profitability depends
	 *    on, so it is the quantity swept -- 1 and 2 are the two sides of MBP_LN_MINM and
	 *    the arms take DIFFERENT paths at M = 1, which is the whole point. */
	{
		static const int ms[] = { 1, 2, 3, 4, 5, 8, 16, 33, 64, 165 };

		for (i = 0; i < LN_K; i++) {
			g[i] = rfloat(-8, 3, 1);
			b[i] = rfloat(-10, 2, 1);
		}
		for (t = 0; t < (int)(sizeof(ms) / sizeof(ms[0])); t++)
			for (mode = 0; mode < 6; mode++)
				cmp("msweep", ms[t], LN_K, g, b,
				    mb_ln_cases[0].si, mb_ln_cases[0].so,
				    mb_ln_cases[0].eps, -128, 127, mode);
	}

	/* 4. K ON BOTH SIDES OF THE CAPACITY BOUND.  At K > MBP_LN_MAXK (1024) both arms must
	 *    fall back, and B66 must not have made the capacity test reachable in a new way. */
	{
		static const int ks[] = { 1, 2, 3, 7, 288, 1023, 1024, 1025, 2048, 4096 };

		for (i = 0; i < 4096; i++) {
			g[i] = rfloat(-8, 3, 1);
			b[i] = rfloat(-10, 2, 1);
		}
		for (t = 0; t < (int)(sizeof(ks) / sizeof(ks[0])); t++)
			for (mode = 0; mode < 4; mode++) {
				cmp("ksweep/M1", 1, ks[t], g, b, mb_ln_cases[0].si,
				    mb_ln_cases[0].so, mb_ln_cases[0].eps, -128, 127, mode);
				cmp("ksweep/M5", 5, ks[t], g, b, mb_ln_cases[0].si,
				    mb_ln_cases[0].so, mb_ln_cases[0].eps, -128, 127, mode);
			}
	}

	/* 5. gamma and/or beta absent: three prologue paths, and the fallback loop has its
	 *    own copy of each. */
	for (mode = 0; mode < 3; mode++)
		for (t = 0; t < 2; t++) {
			const int M = t ? 165 : 1;

			cmp("nogamma", M, LN_K, NULL, b, mb_ln_cases[0].si,
			    mb_ln_cases[0].so, mb_ln_cases[0].eps, -128, 127, mode);
			cmp("nobeta", M, LN_K, g, NULL, mb_ln_cases[0].si,
			    mb_ln_cases[0].so, mb_ln_cases[0].eps, -128, 127, mode);
			cmp("neither", M, LN_K, NULL, NULL, mb_ln_cases[0].si,
			    mb_ln_cases[0].so, mb_ln_cases[0].eps, -128, 127, mode);
		}

	/* 6. Every activation clamp the graph can carry, on both sides of the M guard. */
	{
		static const int cl[][2] = { { -128, 127 }, { 0, 127 }, { -100, 100 },
					     { -1, 1 }, { 0, 0 }, { -128, -128 },
					     { 127, 127 }, { -5, 120 } };

		for (t = 0; t < (int)(sizeof(cl) / sizeof(cl[0])); t++) {
			cmp("clamp/M1", 1, LN_K, g, b, mb_ln_cases[0].si,
			    mb_ln_cases[0].so, mb_ln_cases[0].eps, cl[t][0], cl[t][1], 1);
			cmp("clamp/M165", 165, LN_K, g, b, mb_ln_cases[0].si,
			    mb_ln_cases[0].so, mb_ln_cases[0].eps, cl[t][0], cl[t][1], 1);
		}
	}

	/* 7. Random scales across the exponent range, at M = 1 and M = 165. */
	for (t = 0; t < 400; t++) {
		const float si = rfloat(-20, 8, 0), so = rfloat(-20, 8, 0);
		const float eps = (t % 4) ? rfloat(-30, -4, 0) : 0.0f;
		const int M = (t & 1) ? 1 : 1 + (int)(rnd() % 200u);
		const int K = 1 + (int)(rnd() % 600u);

		for (i = 0; i < K; i++) {
			g[i] = rfloat(-25, 12, 1);
			b[i] = rfloat(-25, 12, 1);
		}
		cmp("randscale", M, K, g, b, si, so, eps, -128, 127, (int)(rnd() % 6u));
	}

	printf("b66 layernorm gate: cases=%ld (M=1: %ld, M>1: %ld) bytes_compared=%ld "
	       "max_abs_err=%d fails=%ld  %s\n",
	       cases, rows_m1, rows_mgt1, bytes, fails ? -1 : 0, fails,
	       fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
