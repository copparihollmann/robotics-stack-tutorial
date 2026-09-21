/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B66's pre-board gate for pext_nl_softmax_s8_pext_int_memo2.c -- host only, no board.
 *
 * THE THIRD INSTANCE OF THE GUARD BUG, and the only one of the three where the fast path
 * was guarded on nothing at all.  This kernel carries two per-dispatch fixed costs, each
 * justified in its own header with ENCODER statistics:
 *
 *   (A) ex[256], built at every dispatch -- 18,449 instructions, measured
 *   (B) the d0 bisection, run at every ROW -- ~9 smx2_out calls, measured
 *
 * The encoder dispatches this op 6 times at M=1320 K=165, where (A) is 0.34 %.  The decoder
 * dispatches it 288 times at M=8, K from 1 to 165, where (A) reaches 7.4x the element work
 * and (B) spends ~9 evaluations placing a cutoff for a row with ONE element.
 *
 * B66 GUARDED (A) AND WITHDREW (B), AND THIS GATE IS WHY.  (A) is bit-identical by
 * construction: a lazily filled ex[d] is the same expression evaluated on first use, and
 * ex[d] depends only on d, im and is, all fixed for the dispatch.
 *
 * (B) LOOKED IDENTICAL AND WAS NOT.  Skipping the bisection means d0 = 255, so the output
 * loop evaluates smx2_out for every distinct d instead of writing 0 for d > d0 -- the same
 * byte if and only if smx2_out returns 0 for exactly those d, which needs the output to be
 * monotone in d.  Run with -DMBP_SMX_MAXK_NOBISECT=100000, arm c produced 28 mismatches out
 * of 4,300 cases, ALL of them at scale_in above ~89 and none at a scale this graph ships.
 * The cause is in the SHIPPING kernel, not in the change:
 *
 *     ex[d] = int_exp2_q31((int32_t)nl_scale((int64_t)(-d) << 16, im, is))
 *
 * casts to int32.  At scale_in = 155.89 that argument is -3,758,573,285 for d = 255, which
 * WRAPS positive, so ex[255] == ex[0] == 2^31 and ex[] rises again at d = 146.  The
 * bisection walks into the wrapped region and zeroes elements whose value is not zero, so
 * above scale_in ~ 89 this kernel is NOT bit-exact with pext_int_memo or pext_int_row --
 * the claim its own header makes.  Recorded, not fixed: it changes outputs outside the
 * calibrated domain and that is an accuracy-contract decision.
 *
 * Arms, one source:
 *   a  -DMBP_SMX_B66=1                          lazy ex[] below MBP_SMX_MINN elements
 *   b  default, MBP_SMX_B66=0                   the SHIPPING kernel, and what still ships
 *   c  -DMBP_SMX_B66=1 -DMBP_SMX_MINN=1e9       lazy ex[] at every shape: the coverage arm
 *
 * THE FEATURE IS DEFAULTED OFF and this gate turns it on, because the measurement says the
 * lazy fill is exact but its test costs +7..+11 % on the path the encoder takes.  The gate
 * exists so the exactness is banked and the follow-on lab starts from a green gate.
 *
 * a-vs-b is the deployed configuration; c-vs-b is the coverage, because it drives the lazy
 * fill through EVERY shape including the encoder's, which the guard sends down the eager
 * path.  Without arm c a lazy-fill bug at large M*K could not be seen -- "a dead path
 * passes a byte-for-byte gate perfectly" -- and it is arm c that refused (B).
 *
 * Coverage: every softmax_s8 dispatch the model ships (b66_smx_cases.h, 294 -- 6 encoder at
 * M=1320 K=165, 288 decoder at M=8 with K in 1..24 and 165, and all 294 scale pairs
 * DISTINCT), then M and K swept across both guards, then rows built to exercise the cutoff,
 * the sum == 0 path and the saturating ends of the domain.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void smx_a(const int8_t *, int8_t *, int, int, float, float);
void smx_b(const int8_t *, int8_t *, int, int, float, float);
void smx_c(const int8_t *, int8_t *, int, int, float, float);   /* lazy ex[] at every shape */
void smx_d(const int8_t *, int8_t *, int, int, float, float);   /* the kernel BEFORE B66 */

#include "b66_smx_cases.h"

static uint64_t rs_ = 0xD1B54A32D192ED03ull;
static uint64_t rnd(void)
{
	rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17;
	return rs_;
}

static float rfloat(int elo, int ehi)
{
	union { uint32_t u; float f; } v;
	int e = elo + (int)(rnd() % (unsigned)(ehi - elo + 1));

	v.u = ((uint32_t)(e + 127) << 23) | (uint32_t)(rnd() & 0x7fffffu);
	return v.f;
}

static long fails, cases, bytes, rows_small, rows_big;

static void fill(int8_t *p, size_t n, int mode)
{
	size_t i;

	switch (mode) {
	case 0: for (i = 0; i < n; i++) p[i] = (int8_t)(uint8_t)(i & 0xff); break;
	case 1: for (i = 0; i < n; i++) p[i] = (int8_t)(uint8_t)(rnd() & 0xff); break;
	case 2: for (i = 0; i < n; i++) p[i] = (rnd() & 1) ? (int8_t)127 : (int8_t)-128; break;
	case 3: memset(p, 7, n); break;                     /* every d is 0: one distinct entry */
	case 4: memset(p, -128, n); break;
	case 5: for (i = 0; i < n; i++) p[i] = (int8_t)(127 - (int)(rnd() % 4u)); break;
	default: for (i = 0; i < n; i++) p[i] = (int8_t)((int)(rnd() % 3u) - 1); break;
	}
}

static void cmp(const char *what, int M, int K, float si, float so, int mode)
{
	const size_t n = (size_t)M * (size_t)K;
	int8_t *in = malloc(n), *oa = malloc(n), *ob = malloc(n), *oc = malloc(n),
	       *od = malloc(n);
	size_t i;

	if (!in || !oa || !ob || !oc || !od) {
		printf("OOM\n");
		exit(2);
	}
	memset(in, 0, n);
	fill(in, n, mode);
	memset(oa, 0x5a, n);
	memset(ob, 0xa5, n);
	memset(oc, 0x3c, n);
	memset(od, 0xc3, n);
	smx_a(in, oa, M, K, si, so);
	smx_b(in, ob, M, K, si, so);
	smx_c(in, oc, M, K, si, so);
	smx_d(in, od, M, K, si, so);
	cases++;
	bytes += (long)n;
	if (n < 1024)
		rows_small++;
	else
		rows_big++;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i] || oc[i] != ob[i] || od[i] != ob[i]) {
			if (fails < 10)
				printf("MISMATCH %s i=%zu in=%d  guard=%d shipped=%d lazy=%d "
				       "pre-B66=%d  M=%d K=%d si=%.9g so=%.9g mode=%d\n",
				       what, i, in[i], oa[i], ob[i], oc[i], od[i], M, K,
				       (double)si, (double)so, mode);
			fails++;
			break;
		}
	}
	free(in); free(oa); free(ob); free(oc); free(od);
}

int main(void)
{
	const int ncase = (int)(sizeof(mb_smx_cases) / sizeof(mb_smx_cases[0]));
	int c, t, mode;

	setvbuf(stdout, NULL, _IONBF, 0);

	/* 0. WHICH SIDE OF EACH GUARD THE SHIPPING DISPATCHES FALL ON -- printed first,
	 *    because a guard that never fires would pass everything below perfectly. */
	{
		int lazy = 0, nobis = 0, enc = 0;

		for (c = 0; c < ncase; c++) {
			if ((long)mb_smx_cases[c].M * mb_smx_cases[c].K < 1024) lazy++;
			if (mb_smx_cases[c].K <= 16) nobis++;
			if (mb_smx_cases[c].half[0] == 'e') enc++;
		}
		(void)nobis;
		printf("0. of %d shipping dispatches (%d encoder): %d take the lazy ex[] fill "
		       "and %d take the eager build\n", ncase, enc, lazy, ncase - lazy);
	}

	/* 1. every shipping dispatch, at its own M, K and scales, over seven populations. */
	for (c = 0; c < ncase; c++)
		for (mode = 0; mode < 7; mode++)
			cmp(mb_smx_cases[c].half, mb_smx_cases[c].M, mb_smx_cases[c].K,
			    mb_smx_cases[c].si, mb_smx_cases[c].so, mode);
	printf("1. every shipping dispatch x 7 populations: %ld cases, %ld fail\n",
	       cases, fails);

	/* 2. M*K SWEPT ACROSS THE ELEMENT GUARD, M and K separately, because M*K is the
	 *    quantities the two fixed costs amortise over, swept separately so neither hides
	 *    the other. */
	{
		static const int ks[] = { 1, 2, 3, 4, 8, 15, 16, 17, 24, 32, 64, 128, 165, 256, 300 };
		static const int ms[] = { 1, 2, 4, 8, 16, 64, 128 };

		for (t = 0; t < (int)(sizeof(ks) / sizeof(ks[0])); t++)
			for (c = 0; c < (int)(sizeof(ms) / sizeof(ms[0])); c++)
				for (mode = 0; mode < 7; mode++)
					cmp("sweep", ms[c], ks[t], mb_smx_cases[0].si,
					    mb_smx_cases[0].so, mode);
	}
	printf("2. M x K swept across the element guard: cumulative %ld cases, %ld fail\n",
	       cases, fails);

	/* 3. random scale pairs over the whole exponent range, at shapes on both sides of the
	 *    element guard, including the ones where sum == 0 and the whole row is written 0. */
	for (t = 0; t < 1500; t++) {
		const float si = rfloat(-20, 8), so = rfloat(-20, 8);
		const int M = 1 + (int)(rnd() % 40u);
		const int K = 1 + (int)(rnd() % 200u);

		cmp("randscale", M, K, si, so, (int)(rnd() % 7u));
	}
	printf("3. random scale pairs: cumulative %ld cases, %ld fail\n", cases, fails);

	/* 4. the encoder's own shape, which is the one the guard sends down the OLD path and
	 *    which only arm c drives through the lazy fill. */
	for (mode = 0; mode < 7; mode++)
		cmp("encoder-shape", 1320, 165, mb_smx_cases[ncase - 1].si,
		    mb_smx_cases[ncase - 1].so, mode);
	printf("4. encoder shape M=1320 K=165 through the lazy fill: "
	       "cumulative %ld cases, %ld fail\n", cases, fails);

	printf("\nb66 softmax gate: cases=%ld (M*K<1024: %ld, >=1024: %ld) bytes_compared=%ld "
	       "max_abs_err=%d fails=%ld  %s\n",
	       cases, rows_small, rows_big, bytes, fails ? -1 : 0, fails,
	       fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
