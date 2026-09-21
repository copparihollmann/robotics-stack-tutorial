/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B63's pre-board gate for pext_nl_add_s8_pext_int_add.c -- host only, no board.
 *
 * The change is a PURE RESTRUCTURING in both of its halves:
 *   - the table build stops calling fx32_apply (128-bit multiply + fx32_bitlen128, which
 *     this core lowers to an out-of-line libgcc __clzdi2 per entry) and carries
 *     p = m * k.q by repeated addition in 64 bits, which is exact for m <= 128 and
 *     k.q <= 2^40;
 *   - the element loop writes the fast value for every element and fixes up the few that
 *     land in the tie band afterwards, instead of staging the exact fallback's arguments
 *     on every element.
 * Neither is allowed to move a single byte, so the gate has no tolerance.
 *
 * Compared: a = B63 default, b = -DMBP_ADD_NO_FAST=1 (the shipping kernel).
 * Coverage: every add_s8 scale triple that ships (b63_add_scales.h, 444 of them -- 12
 * encoder, 432 decoder, and the decoder's are all distinct), each over ALL 65,536 (a, b)
 * pairs; then the same triples at the dispatch's own n on pseudorandom operands; then
 * random and tie-heavy triples; then every activation clamp the graph can carry.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

void add_a(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_b(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);

#include "b63_add_scales.h"

#define NPAIR 65536
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
	add_a(pa, pb, oa, n, sa, sb, so, lo, hi);
	add_b(pa, pb, ob, n, sa, sb, so, lo, hi);
	cases++;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i]) {
			if (fails < 10) {
				printf("MISMATCH %s i=%d a=%d b=%d  new=%d ship=%d  "
				       "sa=%.9g sb=%.9g so=%.9g clamp=[%d,%d]\n",
				       what, i, pa[i], pb[i], oa[i], ob[i],
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
