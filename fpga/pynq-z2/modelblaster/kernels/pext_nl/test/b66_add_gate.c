/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B66's pre-board gate for pext_nl_add_s8_pext_int_add.c -- host only, no board.
 *
 * B63 made the two 256-entry tables cheap to build.  B66 asks the question B63 did not:
 * whether to build them at all.  That is a question about n -- the build is a fixed cost
 * and the lookup's advantage over recomputing is per element -- and the two halves of this
 * model sit on opposite sides of the line (decoder n = 288 x 432 dispatches, encoder
 * n = 47,520 x 12).  The no-build route computes exactly the table entry the build would
 * have written, so nothing may move.
 *
 * Arms, one source, one define apart:
 *   a  shipped default                B66: no-build below MBP_ADD_MINN
 *   b  -DMBP_ADD_MINN=0               B63 as landed: always build (the SHIPPING kernel)
 *   c  -DMBP_ADD_MINN=1000000000      no-build at every n the regime allows
 *
 * a-vs-b is the deployed configuration; c-vs-b carries the coverage, because it drives the
 * no-build route through the exhaustive 65,536-pair sweeps that a would send to the table.
 * The gate also reports how many of the SHIPPING scale triples the no-build route's regime
 * admits, so "the calibration never leaves the regime" is counted rather than asserted.
 *
 * Coverage inherited from b63_add_gate.c: every add_s8 scale triple that ships
 * (b63_add_scales.h, 444 -- 12 encoder, 432 decoder), each over ALL 65,536 (a, b) pairs;
 * then the dispatch's own n on pseudorandom operands; then n = 0..600 across the block
 * boundary and the guard; then random and tie-heavy triples; then out-of-domain scales and
 * every activation clamp the graph can carry.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

void add_a(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_b(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_c(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);

#include "fexact32.h"
#include "b63_add_scales.h"

#define NPAIR 65536
static int8_t oc[NPAIR];

/* The no-build route's regime, computed the way the kernel computes it, so the count below
 * is the kernel's own decision and not a paraphrase of it. */
static int b66_regime(float scale_a, float scale_b, float scale_out)
{
	const fx32_t sa = fx32_dec(scale_a), sb = fx32_dec(scale_b), so = fx32_dec(scale_out);
	fx32_k_t ka, kb;
	int F, la, lb, lo;

	if (!(fx32_scale_ok(sa) && fx32_scale_ok(sb) && fx32_scale_ok(so)))
		return 0;
	la = fx32_bitlen64(sa.m) + sa.e;
	lb = fx32_bitlen64(sb.m) + sb.e;
	lo = fx32_bitlen64(so.m) + so.e;
	F = 44 - ((la > lb ? la : lb) - lo);
	if (F < 16 || F > 55)
		return 0;
	ka = fx32_ratio(sa, so);
	kb = fx32_ratio(sb, so);
	if (ka.q == 0 || kb.q == 0 ||
	    ka.q > ((uint64_t)1 << 40) || kb.q > ((uint64_t)1 << 40))
		return 0;
	la = ka.e + F;          /* == -sh: pint_add_table's left-shift arm */
	lb = kb.e + F;
	return la >= 0 && lb >= 0 && la <= 16 && lb <= 16;
}

static int8_t pa[NPAIR], pb[NPAIR], oa[NPAIR], ob[NPAIR];

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void)
{
	rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
	return rs;
}

static float rscale(int lo, int hi)
{
	union { uint32_t u; float f; } v;
	int e = lo + (int)(rnd() % (unsigned)(hi - lo + 1));

	v.u = ((uint32_t)(e + 127) << 23) | (uint32_t)(rnd() & 0x7fffffu);
	return v.f;
}

static long fails, cases;

static int cmp(const char *what, int n, float sa, float sb, float so, int lo, int hi)
{
	int i;

	memset(oa, 0x5a, sizeof(oa));
	memset(ob, 0xa5, sizeof(ob));
	memset(oc, 0x3c, sizeof(oc));
	add_a(pa, pb, oa, n, sa, sb, so, lo, hi);
	add_b(pa, pb, ob, n, sa, sb, so, lo, hi);
	add_c(pa, pb, oc, n, sa, sb, so, lo, hi);
	cases++;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i] || oc[i] != ob[i]) {
			if (fails < 10) {
				printf("MISMATCH %s i=%d a=%d b=%d  guard=%d ship=%d "
				       "nobuild=%d  sa=%.9g sb=%.9g so=%.9g clamp=[%d,%d]\n",
				       what, i, pa[i], pb[i], oa[i], ob[i], oc[i],
				       (double)sa, (double)sb, (double)so, lo, hi);
			}
			fails++;
			return 1;
		}
	}
	return 0;
}

int main(void)
{
	const int ncase = (int)(sizeof(mb_add_cases) / sizeof(mb_add_cases[0]));
	int i, c;

	setvbuf(stdout, NULL, _IONBF, 0);

	/* 0. HOW MANY SHIPPING TRIPLES THE NO-BUILD ROUTE'S REGIME ADMITS -- counted, so the
	 *    kernel's "the calibration never leaves the regime" is evidence, not a claim. */
	{
		int in_regime = 0, dec = 0, dec_in = 0;

		for (c = 0; c < ncase; c++) {
			const int r = b66_regime(mb_add_cases[c].sa, mb_add_cases[c].sb,
						 mb_add_cases[c].so);

			in_regime += r;
			if (mb_add_cases[c].n < 1320) {
				dec++;
				dec_in += r;
			}
		}
		printf("0. no-build regime admits %d of %d shipping triples; of the %d below "
		       "n=1320 it admits %d\n", in_regime, ncase, dec, dec_in);
	}

	/* 1. every (a, b) pair, at every scale triple that ships. */
	for (i = 0; i < NPAIR; i++) {
		pa[i] = (int8_t)(uint8_t)(i & 0xff);
		pb[i] = (int8_t)(uint8_t)((i >> 8) & 0xff);
	}
	for (c = 0; c < ncase; c++) {
		cmp("exhaustive", NPAIR, mb_add_cases[c].sa, mb_add_cases[c].sb,
		    mb_add_cases[c].so, -128, 127);
	}
	printf("1. exhaustive (a,b) x %d shipping triples: %ld cases, %ld fail\n",
	       ncase, cases, fails);

	/* 2. the dispatch's own n, on pseudorandom operands, at every shipping triple. */
	for (c = 0; c < ncase; c++) {
		int n = mb_add_cases[c].n > NPAIR ? NPAIR : mb_add_cases[c].n;

		for (i = 0; i < n; i++) {
			pa[i] = (int8_t)(uint8_t)rnd();
			pb[i] = (int8_t)(uint8_t)rnd();
		}
		cmp("shape", n, mb_add_cases[c].sa, mb_add_cases[c].sb,
		    mb_add_cases[c].so, mb_add_cases[c].amin, mb_add_cases[c].amax);
	}
	printf("2. dispatch shapes on random operands: cumulative %ld cases, %ld fail\n",
	       cases, fails);

	/* 3. every n from 0 to 600 -- the block boundary at 256 and its neighbours. */
	for (i = 0; i < NPAIR; i++) {
		pa[i] = (int8_t)(uint8_t)rnd();
		pb[i] = (int8_t)(uint8_t)rnd();
	}
	for (c = 0; c <= 600; c++) {
		cmp("n-sweep", c, mb_add_cases[0].sa, mb_add_cases[0].sb,
		    mb_add_cases[0].so, -128, 127);
		cmp("n-sweep", c, mb_add_cases[ncase - 1].sa, mb_add_cases[ncase - 1].sb,
		    mb_add_cases[ncase - 1].so, -128, 127);
	}
	printf("3. n = 0..600 across the 256-element block boundary: "
	       "cumulative %ld cases, %ld fail\n", cases, fails);

	/* 4. random scale triples over the whole documented domain, and the tie-heavy ones
	 *    (so == sa == sb, and power-of-two ratios) where the guard band actually fires. */
	for (c = 0; c < 4000; c++) {
		float sa = rscale(-40, 8), sb = rscale(-40, 8), so = rscale(-40, 8);

		for (i = 0; i < NPAIR; i++) {
			pa[i] = (int8_t)(uint8_t)(i & 0xff);
			pb[i] = (int8_t)(uint8_t)((i >> 8) & 0xff);
		}
		cmp("random-scale", NPAIR, sa, sb, so, -128, 127);
	}
	for (c = -30; c <= 8; c++) {
		float s = (float)ldexp(1.0, c);

		cmp("tie-heavy", NPAIR, s, s, s, -128, 127);
		cmp("tie-heavy", NPAIR, s, s, s * 2.0f, -128, 127);
		cmp("tie-heavy", NPAIR, s * 2.0f, s, s, -128, 127);
		cmp("tie-heavy", NPAIR, s, s * 3.0f, s * 7.0f, -128, 127);
	}
	printf("4. random + tie-heavy triples: cumulative %ld cases, %ld fail\n",
	       cases, fails);

	/* 5. out-of-domain scales, which must still agree -- both arms go to slow_all.
	 *    scale_out = 0 is excluded: fexact32.h's stated domain is non-zero scales and
	 *    the REFERENCE itself divides by it, so both arms fault identically there and a
	 *    comparison would only be measuring that.  Zero is still exercised on sa and sb. */
	{
		const float bad[] = { 0.0f, -1.0f, 1e30f, 1e-30f, 3e38f, 1e-44f };
		const float badso[] = { -1.0f, 1e30f, 1e-30f, 3e38f, 1e-44f };
		unsigned x, y, z;

		for (x = 0; x < sizeof(bad) / sizeof(bad[0]); x++) {
			for (y = 0; y < sizeof(bad) / sizeof(bad[0]); y++) {
				for (z = 0; z < sizeof(badso) / sizeof(badso[0]); z++) {
					cmp("out-of-domain", 4096, bad[x], bad[y], badso[z],
					    -128, 127);
				}
			}
		}
	}
	/* 6. narrowed clamps (fused ReLU and friends). */
	for (c = 0; c < ncase; c += 37) {
		cmp("clamp", 4096, mb_add_cases[c].sa, mb_add_cases[c].sb,
		    mb_add_cases[c].so, 0, 127);
		cmp("clamp", 4096, mb_add_cases[c].sa, mb_add_cases[c].sb,
		    mb_add_cases[c].so, -128, 0);
		cmp("clamp", 4096, mb_add_cases[c].sa, mb_add_cases[c].sb,
		    mb_add_cases[c].so, -7, 11);
	}
	printf("5-6. out-of-domain scales and narrowed clamps: "
	       "cumulative %ld cases, %ld fail\n", cases, fails);

	printf("\n%s: %ld cases byte-for-byte, %ld mismatches\n",
	       fails ? "GATE FAILED" : "GATE PASSED", cases, fails);
	return fails ? 1 : 0;
}
