/* SPDX-License-Identifier: Apache-2.0
 *
 * B67's pre-board gate for pext_nl_cat2_c1_s8_pext_memo_lut.c.  Host only.
 *
 * THE BAR IS BYTE IDENTITY, not a tolerance.  The B67 builder claims to be the reference's
 * own answer -- it rounds the same real value the same way where it can prove the rounding,
 * and calls the reference expression itself where it cannot -- so any difference is a bug,
 * not drift.  The golden is arm b, the kernel compiled with -DMBP_CAT2_B67=0, which is the
 * pre-B67 file term for term.
 *
 * THE DOMAIN IS EXHAUSTED, not sampled.  cat2_c1_s8 is a pointwise int8 map, so its input
 * domain is 256 values; every case below feeds ALL 256 through BOTH inputs.  The scale
 * domain is the model's own: 274 (scale0, scale1, scale_out, amin, amax) tuples read out of
 * the decoder's IR (b67_cat2_cases.h), which is every one it ships.
 *
 * ARM c IS THE COVERAGE ARM AND IT IS THE POINT.  The shipped kernel takes its per-element
 * route only below MBP_CAT2_MINN = 256 elements, and the decoder's smallest side is 288 --
 * so on the model that route NEVER RUNS, and a gate that only compared the shipped default
 * against the golden would exercise it nowhere while passing every comparison.  B66 found
 * exactly that fault in add_s8.  Arm c is built with MBP_CAT2_MINN = 1e9, which forces the
 * per-element route at every shape including the ones the shipped guard sends to the table.
 * The path counts are this program's FIRST output line for that reason.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include "b67_cat2_cases.h"

void cat2_ship(const int8_t *, int, float, const int8_t *, int, float,
	       int8_t *, int, int, int, float, int, int);
void cat2_new(const int8_t *, int, float, const int8_t *, int, float,
	      int8_t *, int, int, int, float, int, int);
void cat2_cov(const int8_t *, int, float, const int8_t *, int, float,
	      int8_t *, int, int, int, float, int, int);

/* the new arms' coverage counters (FX_STATS) */
extern unsigned long n_tbl_sides, n_el_sides, n_slow, n_sat, n_slowside, n_entries;
extern unsigned long c_tbl_sides, c_el_sides, c_slow, c_sat, c_slowside, c_entries;

static long cases_run, bytes_cmp, bad_new, bad_cov;
static long shapes_run;
/* the model-only figures, snapshotted before the adversarial and out-of-domain phases */
static unsigned long m_slow, m_ent, m_sat, m_side;
static long m_bytes, m_shapes;

static int8_t *bufa, *bufb, *bufc, *in0, *in1;
static int cap;

static void need(int n)
{
	if (n <= cap)
		return;
	cap = n;
	bufa = realloc(bufa, (size_t)n * 2);
	bufb = realloc(bufb, (size_t)n * 2);
	bufc = realloc(bufc, (size_t)n * 2);
	in0 = realloc(in0, (size_t)n);
	in1 = realloc(in1, (size_t)n);
	if (!bufa || !bufb || !bufc || !in0 || !in1) {
		fprintf(stderr, "oom\n");
		exit(2);
	}
}

/* one comparison: c0 = c1 = 1, H = cnt, W = 1, so each side is one contiguous run of
 * cnt bytes -- the decoder's own [N, C, H*W] shape. */
static void one(float s0, float s1, float so, int lo, int hi, int cnt, unsigned seed)
{
	int k, n = 2 * cnt;

	need(cnt);
	for (k = 0; k < cnt; k++) {
		/* all 256 values when cnt >= 256, and a spread of them below that */
		in0[k] = (int8_t)((k + seed) & 0xff);
		in1[k] = (int8_t)((255 - ((k * 7 + seed) & 0xff)));
	}
	memset(bufa, 0x5a, (size_t)n);
	memset(bufb, 0xa5, (size_t)n);
	memset(bufc, 0x3c, (size_t)n);
	cat2_ship(in0, 1, s0, in1, 1, s1, bufb, 1, cnt, 1, so, lo, hi);
	cat2_new(in0, 1, s0, in1, 1, s1, bufa, 1, cnt, 1, so, lo, hi);
	cat2_cov(in0, 1, s0, in1, 1, s1, bufc, 1, cnt, 1, so, lo, hi);
	for (k = 0; k < n; k++) {
		if (bufa[k] != bufb[k]) {
			if (bad_new < 8)
				printf("  MISMATCH new  s=%.9g/%.9g->%.9g cnt=%d k=%d "
				       "in=%d ship=%d new=%d\n", (double)s0, (double)s1,
				       (double)so, cnt, k, (int)(k < cnt ? in0[k] : in1[k - cnt]),
				       bufb[k], bufa[k]);
			bad_new++;
		}
		if (bufc[k] != bufb[k]) {
			if (bad_cov < 8)
				printf("  MISMATCH cov  s=%.9g/%.9g->%.9g cnt=%d k=%d "
				       "in=%d ship=%d cov=%d\n", (double)s0, (double)s1,
				       (double)so, cnt, k, (int)(k < cnt ? in0[k] : in1[k - cnt]),
				       bufb[k], bufc[k]);
			bad_cov++;
		}
	}
	bytes_cmp += n;
	shapes_run++;
}

static float mkf(double x) { return (float)x; }

int main(void)
{
	int i, cnt;
	long a_tbl, a_el;

	/* 1. the model's own scale tuples, every one, all 256 inputs through both sides */
	for (i = 0; i < B67_NCASES; i++) {
		const b67_case_t *c = &b67_cases[i];

		one(c->s0, c->s1, c->so, c->amin, c->amax, 256, 0);
		one(c->s0, c->s1, c->so, c->amin, c->amax, 288, 1);   /* the shipped side size */
		cases_run++;
	}
	m_slow = n_slow; m_ent = n_entries; m_sat = n_sat; m_side = n_slowside;
	m_bytes = bytes_cmp; m_shapes = shapes_run;

	/* 2. the MINN guard's neighbourhood, on a spread of the model's tuples: the shipped
	 *    arm changes route at 256 and both routes must land on the same byte. */
	for (i = 0; i < B67_NCASES; i += 11) {
		const b67_case_t *c = &b67_cases[i];

		for (cnt = 1; cnt <= 24; cnt++)
			one(c->s0, c->s1, c->so, c->amin, c->amax, cnt, (unsigned)cnt);
		for (cnt = 250; cnt <= 264; cnt++)
			one(c->s0, c->s1, c->so, c->amin, c->amax, cnt, (unsigned)cnt);
	}

	/* 3. adversarial ratios.  r = s_in/s_out exactly on a half-integer grid puts EVERY
	 *    entry on a rounding boundary, which is where the guard must send the entry to
	 *    the reference rather than round it itself. */
	{
		static const double r[] = { 0.5, 1.5, 2.5, 0.25, 0.75, 1.0, 2.0, 3.0,
					    1.0 / 3.0, 2.0 / 3.0, 1.0 / 256.0, 1.0 / 255.0,
					    127.0, 128.0, 255.0, 256.0, 257.0, 1e3, 1e6,
					    1e-6, 1e-9, 1e9, 5e-4, 0.125, 0.0625 };
		static const double so[] = { 1.0, 0x1p-20, 0x1p20, 0.05180322, 3.7e-7 };
		static const int cl[][2] = { { -128, 127 }, { 0, 127 }, { -128, 0 },
					     { -5, 5 }, { -128, 126 }, { -127, 127 },
					     { 0, 0 }, { -255, 255 }, { -300, 300 } };
		unsigned a, b, cc;

		for (a = 0; a < sizeof(r) / sizeof(r[0]); a++)
			for (b = 0; b < sizeof(so) / sizeof(so[0]); b++)
				for (cc = 0; cc < sizeof(cl) / sizeof(cl[0]); cc++)
					one(mkf(r[a] * so[b]), mkf(r[a] * so[b] * 0.5),
					    mkf(so[b]), cl[cc][0], cl[cc][1], 256, (unsigned)a);
	}

	/* 4. outside fexact32's domain: the whole side must fall to the reference.  Zero,
	 *    subnormal, huge, and negative scales -- none of which calibration produces, and
	 *    all of which the kernel must survive rather than trust its bound on. */
	{
		static const double bad[] = { 0.0, 1e-45, 5e-324, 1e38, 3.4e38, -0.05,
					      1e-40, 1e-13, 1e13, 0x1p-41, 0x1p41 };
		unsigned a, b;

		for (a = 0; a < sizeof(bad) / sizeof(bad[0]); a++) {
			for (b = 0; b < sizeof(bad) / sizeof(bad[0]); b++)
				one(mkf(bad[a]), mkf(bad[b]), mkf(0.05180322), -128, 127, 256, 3);
			one(mkf(bad[a]), mkf(0.05), mkf(bad[a]), -128, 127, 256, 4);
			one(mkf(0.05), mkf(0.05), mkf(bad[a]), -128, 127, 256, 5);
		}
	}

	a_tbl = (long)n_tbl_sides;
	a_el = (long)n_el_sides;
	printf("COVERAGE  shipped-default arm: table %ld sides, per-element %ld sides\n",
	       a_tbl, a_el);
	printf("COVERAGE  coverage arm       : table %ld sides, per-element %ld sides\n",
	       (long)c_tbl_sides, (long)c_el_sides);
	printf("COVERAGE  the decoder's smallest side is 288, so on the MODEL the "
	       "per-element route is never taken; arm c forces it %ld times\n",
	       (long)c_el_sides);
	printf("MODEL     on the decoder's own %d tuples alone: %ld shapes, %ld bytes, "
	       "%ld of %ld entries to the reference (%.5f %%), %ld saturated, "
	       "%ld out-of-domain sides\n",
	       B67_NCASES, m_shapes, m_bytes, (long)m_slow, (long)m_ent,
	       m_ent ? 100.0 * (double)m_slow / (double)m_ent : 0.0,
	       (long)m_sat, (long)m_side);
	printf("GUARD     default arm: %ld of %ld entries fell back to the reference "
	       "expression (%.4f %%), %ld saturated, %ld sides out of domain\n",
	       (long)n_slow, (long)n_entries,
	       n_entries ? 100.0 * (double)n_slow / (double)n_entries : 0.0,
	       (long)n_sat, (long)n_slowside);
	printf("CASES     %ld model scale tuples, %ld shapes, %ld bytes compared\n",
	       cases_run, shapes_run, bytes_cmp);
	printf("RESULT    new vs shipped: %ld mismatches;  coverage vs shipped: %ld mismatches\n",
	       bad_new, bad_cov);
	if (a_tbl == 0 || a_el == 0 || c_el_sides == 0) {
		printf("FAIL      a path was never exercised\n");
		return 1;
	}
	if (n_slow == 0) {
		printf("FAIL      the guard's reference fallback never fired: it is untested\n");
		return 1;
	}
	if (n_slowside == 0) {
		printf("FAIL      the out-of-domain side path never fired: it is untested\n");
		return 1;
	}
	return (bad_new || bad_cov) ? 1 : 0;
}
