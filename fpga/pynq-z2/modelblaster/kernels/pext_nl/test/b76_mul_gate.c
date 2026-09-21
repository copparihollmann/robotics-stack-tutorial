/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B76's pre-board gate for pext_nl_mul_s8_pext_int_mul.c -- host only, no board.
 *
 * WHAT IS BEING CHECKED, AND WHY IT HAS NO TOLERANCE.  B76 rebuilds tb[] three ways and
 * every one of them is an identity, not an approximation:
 *
 *   1. k.q is split as kh*2^20 + kl so the 128-bit product m*k.q is carried in two 64-bit
 *      halves.  A*2^20 is a multiple of 2^sh when sh <= 20, and when sh > 20 the low 20
 *      bits dropped from B + 2^(sh-1) are below the shift -- so the rounded shift is the
 *      same integer, not a near one.
 *   2. A and B are arithmetic sequences in |v|, so the per-entry multiplies become adds.
 *   3. fx32_apply's magnitude depends only on |v| and its sign only on `neg`, so 128
 *      magnitudes fill all 256 entries.
 *
 * A SINGLE DIFFERING OUTPUT BYTE FAILS.  The comparison is over the FULL operand domain --
 * all 65,536 (a, b) pairs -- at every scale triple, so it is a proof over the domain and
 * not a sample of it.  That matters more here than in a restructuring gate: an error in
 * tb[] does not have to change the output, because the guard sends near-half-integer
 * elements to the exact slow path, so a table that is merely CLOSE would pass a sampled
 * comparison and fail somewhere the model actually visits.
 *
 * Arms, one source, one define apart:
 *   a  -DMBP_B76=1   the treatment
 *   b  default       the shipping kernel
 * and the poisoned arms, without which a route that never fires passes arm a perfectly:
 *   p1  the positive magnitudes (the A/B recurrence)
 *   p2  the negated half, which only b < 0 reads
 *   p3  the sh <= 20 arm of the rounded shift -- the one all 144 shipped triples take
 *       (sh = 19 for every one of them, computed in the lab notes)
 * Each poison SCALES the entry by 1 + 2^-8 rather than adding one unit, because at F ~ 44
 * a unit change in tb[] cannot survive the `>> F` -- B74 lost a session to exactly that.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void mul_a(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void mul_b(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);

#include "b76_mul_cases.h"

static uint64_t rs_ = 0x243F6A8885A308D3ull;
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

static long fails, cases, bytes;

/* All 65,536 (a, b) pairs, laid out so one call covers the whole domain. */
static int8_t in_a[65536], in_b[65536], oa[65536], ob[65536];

static void full_domain(const char *what, float sa, float sb, float so, int amin, int amax)
{
	int i;

	for (i = 0; i < 65536; i++) {
		in_a[i] = (int8_t)(uint8_t)(i >> 8);
		in_b[i] = (int8_t)(uint8_t)(i & 0xff);
	}
	memset(oa, 0x5a, sizeof(oa));
	memset(ob, 0xa5, sizeof(ob));
	mul_a(in_a, in_b, oa, 65536, sa, sb, so, amin, amax);
	mul_b(in_a, in_b, ob, 65536, sa, sb, so, amin, amax);
	cases++;
	bytes += 65536;
	for (i = 0; i < 65536; i++) {
		if (oa[i] != ob[i]) {
			if (fails < 10)
				printf("MISMATCH %s a=%d b=%d  b76=%d ship=%d  "
				       "sa=%.9g sb=%.9g so=%.9g clamp=[%d,%d]\n",
				       what, in_a[i], in_b[i], oa[i], ob[i],
				       (double)sa, (double)sb, (double)so, amin, amax);
			fails++;
			break;
		}
	}
}

/* Short n, so the element loop's tail and the n < 256 shapes are covered too. */
static void short_n(const char *what, int n, float sa, float sb, float so, int amin, int amax)
{
	int i;

	for (i = 0; i < n; i++) {
		in_a[i] = (int8_t)(uint8_t)(rnd() & 0xff);
		in_b[i] = (int8_t)(uint8_t)(rnd() & 0xff);
	}
	memset(oa, 0x5a, (size_t)n);
	memset(ob, 0xa5, (size_t)n);
	mul_a(in_a, in_b, oa, n, sa, sb, so, amin, amax);
	mul_b(in_a, in_b, ob, n, sa, sb, so, amin, amax);
	cases++;
	bytes += n;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i]) {
			if (fails < 10)
				printf("MISMATCH %s i=%d a=%d b=%d  b76=%d ship=%d n=%d\n",
				       what, i, in_a[i], in_b[i], oa[i], ob[i], n);
			fails++;
			break;
		}
	}
}

int main(void)
{
	const int ncase = (int)(sizeof(mb_mul_cases) / sizeof(mb_mul_cases[0]));
	int c, t;

	/* 1. EVERY SHIPPING DISPATCH's scale triple over the FULL (a, b) domain.  All 144 are
	 *    distinct, and all 144 land on sh = 19, the `sh <= 20` arm. */
	for (c = 0; c < ncase; c++)
		full_domain("ship", mb_mul_cases[c].sa, mb_mul_cases[c].sb,
			    mb_mul_cases[c].so, mb_mul_cases[c].amin, mb_mul_cases[c].amax);

	/* 2. The same triples at the dispatch's own n and at odd n, so the element loop's
	 *    shape is covered as well as the table's contents. */
	for (c = 0; c < ncase; c += 7) {
		static const int ns[] = { 0, 1, 2, 7, 8, 63, 64, 255, 256, 257, 1151, 1152, 1153 };

		for (t = 0; t < (int)(sizeof(ns) / sizeof(ns[0])); t++)
			short_n("nsweep", ns[t], mb_mul_cases[c].sa, mb_mul_cases[c].sb,
				mb_mul_cases[c].so, mb_mul_cases[c].amin,
				mb_mul_cases[c].amax);
	}

	/* 3. RANDOM SCALES ACROSS THE WHOLE EXPONENT RANGE.  This is the coverage that drives
	 *    `sh` off 19 -- onto the sh > 20 arm, past 62 where the generic fx32_apply must
	 *    take over, and into the F and *ok rejections that send the whole call to the
	 *    exact slow path.  The shipped triples alone exercise ONE of the four routes. */
	for (t = 0; t < 4000; t++) {
		const float sa = rfloat(-30, 10), sb = rfloat(-30, 10), so = rfloat(-30, 10);

		full_domain("randscale", sa, sb, so, -128, 127);
	}

	/* 4. Out-of-domain scales: subnormal, huge -- fx32_scale_ok must still route them to
	 *    slow_all in both arms.
	 *
	 *    scale_out = 0 IS NOT SWEPT, and that is a finding about the SHIPPING kernel
	 *    rather than an omission.  fx32_scale_ok rejects it, slow_all then calls
	 *    pint_mul_exact, and fx32_div divides by so.m -- so a zero scale_out is an integer
	 *    divide by zero in the shipped kernel and in every arm alike.  The first version of
	 *    this gate swept it and every mul_s8 arm died with SIGFPE.  fexact32.h's stated
	 *    domain is "finite, non-zero scales", so this is out of contract rather than a bug,
	 *    and it is recorded here rather than fixed: the same hole is in add_s8, rope_s8 and
	 *    cat2, and closing it is a contract change that belongs with whoever owns the
	 *    contract.  Zero scale_a and scale_b ARE swept -- those reach fx32_div with a zero
	 *    NUMERATOR, which returns early. */
	{
		static const float bad[] = { 0.0f, 1.4e-45f, 1e30f, 1e-38f, 3.4e38f };

		for (t = 0; t < (int)(sizeof(bad) / sizeof(bad[0])); t++) {
			full_domain("badscale/a", bad[t], 0.03f, 0.02f, -128, 127);
			full_domain("badscale/b", 0.03f, bad[t], 0.02f, -128, 127);
			if (bad[t] != 0.0f)
				full_domain("badscale/o", 0.03f, 0.02f, bad[t], -128, 127);
		}
	}

	/* 5. Every activation clamp the graph can carry.  hi/lo_lim are computed FROM the
	 *    clamp, so a narrowed clamp changes which elements take the early-exit arms. */
	{
		static const int cl[][2] = { { -128, 127 }, { 0, 127 }, { -100, 100 },
					     { -1, 1 }, { 0, 0 }, { -128, -128 },
					     { 127, 127 }, { -5, 120 } };

		for (t = 0; t < (int)(sizeof(cl) / sizeof(cl[0])); t++)
			for (c = 0; c < ncase; c += 23)
				full_domain("clamp", mb_mul_cases[c].sa, mb_mul_cases[c].sb,
					    mb_mul_cases[c].so, cl[t][0], cl[t][1]);
	}

	printf("b76 mul gate: cases=%ld bytes_compared=%ld max_abs_err=%d fails=%ld  %s\n",
	       cases, bytes, fails ? -1 : 0, fails, fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
