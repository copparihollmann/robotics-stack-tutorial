/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B66's pre-board gate for pext_nl_groupnorm_s8_pext_int_rsqrt.c -- host only, no board.
 *
 * THE CHANGE IS AN IDENTITY, NOT A TOLERANCE, AND THAT IS WHAT THIS GATE CHECKS.
 * Inside one channel the kernel's map is a function of the input BYTE alone (mean, rs and
 * sh are fixed for the sample; gm, gs, gneg and b8 are fixed for the channel), so a
 * 256-entry table reproduces it ON ITS ENTIRE DOMAIN.  There is therefore no tolerance to
 * set and no sampling argument to make: every comparison below must be byte-identical, and
 * a single differing byte is a failure.
 *
 * Three arms of ONE source, so nothing but the guard differs:
 *   a  shipped default          MBP_GN_MINHW = 320, the guard as it will ship
 *   b  -DMBP_GN_MINHW=2000000000   the per-element path always: the SHIPPING kernel
 *   c  -DMBP_GN_MINHW=1            the table path always
 *
 * a-vs-b is the deployed configuration.  c-vs-b is the one that carries the coverage: it
 * runs the table at EVERY shape, including the ones the guard will send down the old path,
 * so a table bug cannot hide behind the guard.
 *
 * Inputs are built to contain all 256 codes rather than taken from a recording.  That is
 * deliberate and it is stronger: the claim being checked is that the table equals the
 * function on its whole domain, and a real activation visits only the codes it happens to
 * contain.  The real gamma, beta and quant of the one dispatch Moonshine ships are in
 * b66_gn_cases.h and are used as well.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void gn_a(const int8_t *, const float *, const float *, int8_t *,
	  int, int, int, int, float, float, float, int, int);
void gn_b(const int8_t *, const float *, const float *, int8_t *,
	  int, int, int, int, float, float, float, int, int);
void gn_c(const int8_t *, const float *, const float *, int8_t *,
	  int, int, int, int, float, float, float, int, int);

#include "b66_gn_cases.h"

static uint64_t rs_ = 0x243F6A8885A308D3ull;
static uint64_t rnd(void)
{
	rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17;
	return rs_;
}

/* A float with a chosen exponent range and a random mantissa, sign included: the kernel
 * decodes gamma and beta from their BITS, so the bit patterns are the coverage. */
static float rfloat(int elo, int ehi, int allow_neg)
{
	union { uint32_t u; float f; } v;
	int e = elo + (int)(rnd() % (unsigned)(ehi - elo + 1));

	v.u = ((uint32_t)(e + 127) << 23) | (uint32_t)(rnd() & 0x7fffffu);
	if (allow_neg && (rnd() & 1))
		v.u |= 0x80000000u;
	return v.f;
}

static long fails, cases, bytes;

static void fill(int8_t *p, size_t n, int mode)
{
	size_t i;

	switch (mode) {
	case 0:                                   /* every code, in order and repeating */
		for (i = 0; i < n; i++) p[i] = (int8_t)(uint8_t)(i & 0xff);
		break;
	case 1:                                   /* pseudorandom over all 256 codes */
		for (i = 0; i < n; i++) p[i] = (int8_t)(uint8_t)(rnd() & 0xff);
		break;
	case 2:                                   /* the two extremes only */
		for (i = 0; i < n; i++) p[i] = (rnd() & 1) ? (int8_t)127 : (int8_t)-128;
		break;
	case 3:                                   /* constant: var_q == 0, eps decides */
		for (i = 0; i < n; i++) p[i] = 7;
		break;
	case 4:                                   /* all zero */
		memset(p, 0, n);
		break;
	default:                                  /* narrow band around zero */
		for (i = 0; i < n; i++) p[i] = (int8_t)((int)(rnd() % 5u) - 2);
		break;
	}
}

static void cmp(const char *what, int N, int C, int H, int W,
		const float *g, const float *b, float si, float so, float eps,
		int amin, int amax, int mode)
{
	const size_t n = (size_t)N * C * H * W;
	int8_t *in = malloc(n), *oa = malloc(n), *ob = malloc(n), *oc = malloc(n);
	size_t i;

	if (!in || !oa || !ob || !oc) {
		printf("OOM\n");
		exit(2);
	}
	memset(in, 0, n);          /* before fill: keeps -Wmaybe-uninitialized quiet after constprop */
	fill(in, n, mode);
	memset(oa, 0x5a, n);
	memset(ob, 0xa5, n);
	memset(oc, 0x3c, n);
	gn_a(in, g, b, oa, N, C, H, W, si, so, eps, amin, amax);
	gn_b(in, g, b, ob, N, C, H, W, si, so, eps, amin, amax);
	gn_c(in, g, b, oc, N, C, H, W, si, so, eps, amin, amax);
	cases++;
	bytes += (long)n;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i] || oc[i] != ob[i]) {
			if (fails < 10)
				printf("MISMATCH %s i=%zu in=%d  guard=%d ship=%d always=%d  "
				       "N=%d C=%d H=%d W=%d si=%.9g so=%.9g eps=%.9g "
				       "clamp=[%d,%d] mode=%d\n",
				       what, i, in[i], oa[i], ob[i], oc[i],
				       N, C, H, W, (double)si, (double)so, (double)eps,
				       amin, amax, mode);
			fails++;
			break;
		}
	}
	free(in); free(oa); free(ob); free(oc);
}

int main(void)
{
	static float g[4096], b[4096];
	int i, mode, t;

	/* 1. The dispatch Moonshine actually ships, with its real gamma, beta and quant,
	 *    over six input populations.  HW = 999, so the guard takes the table. */
	for (mode = 0; mode < 6; mode++)
		cmp("real", GN_N, GN_C, GN_H, GN_W, gn_gamma, gn_beta,
		    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, GN_AMIN, GN_AMAX, mode);

	/* 2. The same dispatch with gamma and/or beta absent -- three separate code paths
	 *    in the channel prologue, and the table must follow each. */
	for (mode = 0; mode < 3; mode++) {
		cmp("real/nogamma", GN_N, GN_C, GN_H, GN_W, NULL, gn_beta,
		    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, GN_AMIN, GN_AMAX, mode);
		cmp("real/nobeta", GN_N, GN_C, GN_H, GN_W, gn_gamma, NULL,
		    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, GN_AMIN, GN_AMAX, mode);
		cmp("real/neither", GN_N, GN_C, GN_H, GN_W, NULL, NULL,
		    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, GN_AMIN, GN_AMAX, mode);
	}

	/* 3. HW ON BOTH SIDES OF THE GUARD.  HW is the quantity the trade depends on, so it
	 *    is the quantity swept: 1..20, then powers of two to 4096, through the crossover
	 *    at 320.  Arm c runs the table at every one of them. */
	for (i = 0; i < 288; i++) {
		g[i] = rfloat(-8, 3, 1);
		b[i] = rfloat(-10, 2, 1);
	}
	{
		static const int hws[] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
					   15, 16, 17, 18, 19, 20, 31, 32, 33, 63, 64, 65,
					   127, 128, 129, 255, 256, 257, 318, 319, 320, 321,
					   322, 511, 512, 513, 998, 999, 1000, 2048, 4096 };
		for (t = 0; t < (int)(sizeof(hws) / sizeof(hws[0])); t++)
			for (mode = 0; mode < 6; mode++)
				cmp("hwsweep", 1, 8, 1, hws[t], g, b,
				    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, -128, 127, mode);
	}

	/* 4. Random scales across the exponent range, random gamma and beta with signs,
	 *    zeros and subnormals mixed in. */
	for (t = 0; t < 400; t++) {
		const float si = rfloat(-20, 8, 0), so = rfloat(-20, 8, 0);
		const float eps = (t % 4) ? rfloat(-30, -4, 0) : 0.0f;
		int C = 1 + (int)(rnd() % 6u), W = 1 + (int)(rnd() % 1200u);

		for (i = 0; i < C; i++) {
			unsigned r = (unsigned)(rnd() % 16u);

			g[i] = r == 0 ? 0.0f : (r == 1 ? 1.4e-45f : rfloat(-25, 12, 1));
			b[i] = r == 2 ? 0.0f : (r == 3 ? -1.4e-45f : rfloat(-25, 12, 1));
		}
		cmp("random", 1, C, 1, W, g, b, si, so, eps, -128, 127,
		    (int)(rnd() % 6u));
	}

	/* 5. Every activation clamp the graph can carry, at a shape on each side of the
	 *    guard, because the clamp is inside the table entry. */
	{
		static const int cl[][2] = { { -128, 127 }, { 0, 127 }, { -100, 100 },
					     { -1, 1 }, { 0, 0 }, { -128, -128 },
					     { 127, 127 }, { -5, 120 } };
		for (t = 0; t < (int)(sizeof(cl) / sizeof(cl[0])); t++) {
			cmp("clamp/big", 1, 4, 1, 999, g, b,
			    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, cl[t][0], cl[t][1], 1);
			cmp("clamp/small", 1, 4, 1, 17, g, b,
			    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, cl[t][0], cl[t][1], 1);
		}
	}

	/* 6. N > 1 and C = 1: the table is rebuilt per (sample, channel) and must follow
	 *    both loop variables. */
	for (t = 0; t < 8; t++) {
		cmp("multiN", 3, 5, 1, 400 + t, g, b,
		    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, -128, 127, t % 6);
		cmp("C1", 1, 1, 1, 999, g, b,
		    GN_SCALE_IN, GN_SCALE_OUT, GN_EPS, -128, 127, t % 6);
	}

	printf("b66 groupnorm gate: cases=%ld bytes_compared=%ld max_abs_err=%d fails=%ld  %s\n",
	       cases, bytes, fails ? -1 : 0, fails, fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
