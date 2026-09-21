/* SPDX-License-Identifier: Apache-2.0
 *
 * B87's pre-board gate: the shipped kernels against the B87 kernels, BYTE FOR BYTE, at
 * the encoder's own shapes and at every scale triple/pair this graph dispatches, plus
 * adversarial ones.  Host only -- no board, no bitstream, no lock.
 *
 * WHY BYTE-FOR-BYTE IS THE RIGHT INSTRUMENT AND NOT A TOLERANCE.  None of the three
 * changes is an arithmetic change:
 *   groupnorm_s8  DOT8 sums the same int8 codes exactly; the LUT entries are the shipped
 *                 expression at the same argument; pgn_scale64 is nl_scale in 64 bits,
 *                 guarded by a test the caller makes against the table's own extremes.
 *   add_s8        the same products, the same tie tests, the same marks in the same order.
 *   rope_s8       the pass-through table IS the shipped pass body evaluated at x == u; the
 *                 hoisted G only WIDENS the tie band, and both sides of that band return
 *                 the reference value.
 * So a single differing byte is a failure, and each poison arm must produce some.
 *
 * IT ALSO COUNTS THE EXACT-PATH RATE.  rope_s8's hoisted G is the one change that moves a
 * decision rather than only the instructions that implement it: a wider band sends more
 * elements down the exact route.  Built with -DFX_STATS the two arms report their own
 * slow-path counts, so the widening is MEASURED here rather than argued in a comment.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

#include "b87_gn_affine.h"

void gn_ctl(const int8_t *, const float *, const float *, int8_t *,
	    int, int, int, int, float, float, float, int, int);
void gn_b87(const int8_t *, const float *, const float *, int8_t *,
	    int, int, int, int, float, float, float, int, int);
void add_ctl(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_b87(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void rope_ctl(const int8_t *, const float *, const float *, int8_t *,
	      int, int, int, int, float, float, int, int);
void rope_b87(const int8_t *, const float *, const float *, int8_t *,
	      int, int, int, int, float, float, int, int);

#ifdef FX_STATS
/* Both arms define these, so b87_gate.sh renames them per arm at compile time. */
extern unsigned long rope_slow_ctl, rope_n_ctl, rope_slow_b87, rope_n_b87;
extern unsigned long add_slow_ctl, add_n_ctl, add_slow_b87, add_n_b87;
#endif

static uint64_t rs_ = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void)
{
	rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17;
	return rs_;
}
static int8_t rb(void) { return (int8_t)(uint8_t)(rnd() >> 33); }

static long total_bytes, total_bad, total_cases;

static void cmp(const char *what, const int8_t *a, const int8_t *b, size_t n)
{
	size_t i;
	long bad = 0;

	for (i = 0; i < n; i++) {
		if (a[i] != b[i]) {
			if (bad < 3) {
				printf("    %s: byte %zu  ctl %d  b87 %d\n",
				       what, i, (int)a[i], (int)b[i]);
			}
			bad++;
		}
	}
	total_bytes += (long)n;
	total_bad += bad;
	total_cases++;
}

/* ---------------- groupnorm_s8 ---------------- */
#define GNC 288
#define GNHW 999
#define GNN (GNC * GNHW)
static int8_t gin[GNN] __attribute__((aligned(64)));
static int8_t ga[GNN], gb[GNN];
static float rg[GNC], rbt[GNC];

static void gn_case(const char *tag, const float *gam, const float *bet,
		    float si, float so, float eps, int amin, int amax, int spread)
{
	int i;

	for (i = 0; i < GNN; i++) {
		gin[i] = spread ? rb() : (int8_t)((int)rb() / 8);
	}
	memset(ga, 0x5A, sizeof ga);
	memset(gb, 0xA5, sizeof gb);
	gn_ctl(gin, gam, bet, ga, 1, GNC, 1, GNHW, si, so, eps, amin, amax);
	gn_b87(gin, gam, bet, gb, 1, GNC, 1, GNHW, si, so, eps, amin, amax);
	cmp(tag, ga, gb, GNN);
}

/* ---------------- add_s8 ---------------- */
#define ADDN 47520
static int8_t ain[ADDN], bin[ADDN], oa[ADDN], ob[ADDN];

static const float add_scales[][3] = {
	{0.490539283f, 0.504428208f, 0.572304666f},
	{0.572304666f, 0.189057589f, 0.656255424f},
	{0.656255424f, 0.150072828f, 0.752780914f},
	{0.752780914f, 0.184564769f, 0.866061151f},
	{0.866061151f, 0.129093751f, 0.891218841f},
	{0.891218841f, 0.268802106f, 1.084777f},
	{1.084777f, 0.1778377f, 0.989863753f},
	{0.989863753f, 0.300426781f, 1.22425318f},
	{1.22425318f, 0.347311378f, 1.08938992f},
	{1.08938992f, 0.504831612f, 1.39106619f},
	{1.39106619f, 1.06085646f, 2.19702148f},
	{2.19702148f, 5.3478632f, 7.05366898f},
	/* adversarial: tie-heavy (so an exact power-of-two multiple of sa + sb) and extreme */
	{1.0f, 1.0f, 2.0f}, {1.0f, 1.0f, 1.0f}, {0.5f, 0.5f, 1.0f},
	{1.0f, 3.0f, 4.0f}, {1e-6f, 1e-6f, 1e-6f}, {100.0f, 0.001f, 7.0f},
};

static void add_cases(int n)
{
	unsigned s;
	int i;

	for (s = 0; s < sizeof add_scales / sizeof *add_scales; s++) {
		char tag[48];
		int amin = (s & 1) ? -128 : -128, amax = (s & 1) ? 127 : 127;

		if (s == 5) { amin = -100; amax = 90; }   /* the non-full clamp route */
		for (i = 0; i < n; i++) { ain[i] = rb(); bin[i] = rb(); }
		memset(oa, 0x5A, sizeof oa);
		memset(ob, 0xA5, sizeof ob);
		add_ctl(ain, bin, oa, n, add_scales[s][0], add_scales[s][1],
			add_scales[s][2], amin, amax);
		add_b87(ain, bin, ob, n, add_scales[s][0], add_scales[s][1],
			add_scales[s][2], amin, amax);
		snprintf(tag, sizeof tag, "add[%u] n=%d", s, n);
		cmp(tag, oa, ob, (size_t)n);
	}
}

/* ---------------- rope_s8 ---------------- */
#define RT 165
#define RH 8
#define RD 36
#define RR 32
#define RN (RT * RH * RD)
static int8_t rin[RN], ra[RN], rb_[RN];
static float ctab[RT * (RR / 2)], stab[RT * (RR / 2)];

static const float rope_scales[][2] = {
	{0.0563248396f, 0.0632022619f}, {0.0890492871f, 0.0915410593f},
	{0.0451285653f, 0.0445857197f}, {0.0596134737f, 0.0589658991f},
	{0.0380824581f, 0.0369582586f}, {0.0775125176f, 0.077293545f},
	{0.0462182723f, 0.0460857898f}, {0.0631247014f, 0.0639584437f},
	{0.0375060663f, 0.0377578177f}, {0.0763365701f, 0.0759598762f},
	{0.0363169126f, 0.0366573408f}, {0.0621069521f, 0.0623351075f},
	/* adversarial: si == so (KF a power of two, every product a tie candidate), and
	 * the extremes of the F window */
	{1.0f, 1.0f}, {0.5f, 1.0f}, {1.0f, 0.5f}, {1e-7f, 1.0f}, {1.0f, 1e-7f},
};

static void rope_tables(void)
{
	int t, i;

	for (t = 0; t < RT; t++) {
		for (i = 0; i < RR / 2; i++) {
			double inv = 1.0 / pow(10000.0, (double)(2 * i) / (double)RR);

			ctab[t * (RR / 2) + i] = (float)cos((double)t * inv);
			stab[t * (RR / 2) + i] = (float)sin((double)t * inv);
		}
	}
}

static void rope_cases(void)
{
	unsigned s;
	int i;

	for (s = 0; s < sizeof rope_scales / sizeof *rope_scales; s++) {
		char tag[48];
		int amin = -128, amax = 127;

		if (s == 3) { amin = -120; amax = 100; }   /* the non-full clamp route */
		for (i = 0; i < RN; i++) { rin[i] = rb(); }
		memset(ra, 0x5A, sizeof ra);
		memset(rb_, 0xA5, sizeof rb_);
		rope_ctl(rin, ctab, stab, ra, RT, RH, RD, RR,
			 rope_scales[s][0], rope_scales[s][1], amin, amax);
		rope_b87(rin, ctab, stab, rb_, RT, RH, RD, RR,
			 rope_scales[s][0], rope_scales[s][1], amin, amax);
		snprintf(tag, sizeof tag, "rope[%u]", s);
		cmp(tag, ra, rb_, RN);
	}
}

int main(void)
{
	int i;

	for (i = 0; i < GNC; i++) {
		rg[i] = (float)((double)(int64_t)(rnd() % 4000) / 1000.0 - 2.0);
		rbt[i] = (float)((double)(int64_t)(rnd() % 2000) / 1000.0 - 1.0);
	}
	rope_tables();

	printf("--- groupnorm_s8  N=1 C=%d H=1 W=%d (%d elements a case) ---\n",
	       GNC, GNHW, GNN);
	gn_case("gn[model]", b87_gn_gamma, b87_gn_beta,
		0.00664364267f, 0.0466533378f, 9.99999975e-06f, -128, 127, 1);
	gn_case("gn[model,narrow]", b87_gn_gamma, b87_gn_beta,
		0.00664364267f, 0.0466533378f, 9.99999975e-06f, -128, 127, 0);
	gn_case("gn[rand]", rg, rbt, 0.00664364267f, 0.0466533378f, 1e-5f, -128, 127, 1);
	gn_case("gn[clamped]", rg, rbt, 0.00664364267f, 0.0466533378f, 1e-5f, -100, 90, 1);
	gn_case("gn[nogamma]", NULL, b87_gn_beta, 0.00664364267f, 0.0466533378f,
		1e-5f, -128, 127, 1);
	gn_case("gn[nobeta]", b87_gn_gamma, NULL, 0.00664364267f, 0.0466533378f,
		1e-5f, -128, 127, 1);
	gn_case("gn[bigscale]", rg, rbt, 4.0f, 0.001f, 1e-3f, -128, 127, 1);
	gn_case("gn[tinyscale]", rg, rbt, 1e-5f, 8.0f, 1e-9f, -128, 127, 1);

	printf("--- add_s8  n=%d, %zu scale triples ---\n",
	       ADDN, sizeof add_scales / sizeof *add_scales);
	add_cases(ADDN);
	add_cases(47519);        /* not a multiple of 4: the unrolled tail */
	add_cases(3);            /* shorter than one unrolled iteration */
	add_cases(288);          /* the decoder's own n */

	printf("--- rope_s8  T=%d H=%d D=%d R=%d (%d elements a case), %zu scale pairs ---\n",
	       RT, RH, RD, RR, RN, sizeof rope_scales / sizeof *rope_scales);
	rope_cases();

#ifdef FX_STATS
	/* The exact-path rate, per arm, over the model's own 12 rope scale pairs and 12 add
	 * scale triples.  rope's hoisted G WIDENS the band, so b87's count must be strictly
	 * larger than the control's -- that, and not a byte, is what proves the hoist live. */
	rope_slow_ctl = rope_n_ctl = rope_slow_b87 = rope_n_b87 = 0;
	add_slow_ctl = add_n_ctl = add_slow_b87 = add_n_b87 = 0;
	for (i = 0; i < 12; i++) {
		int j;

		for (j = 0; j < RN; j++) { rin[j] = rb(); }
		rope_ctl(rin, ctab, stab, ra, RT, RH, RD, RR,
			 rope_scales[i][0], rope_scales[i][1], -128, 127);
		rope_b87(rin, ctab, stab, rb_, RT, RH, RD, RR,
			 rope_scales[i][0], rope_scales[i][1], -128, 127);
		cmp("rope[fx]", ra, rb_, RN);
	}
	for (i = 0; i < 12; i++) {
		int j;

		for (j = 0; j < ADDN; j++) { ain[j] = rb(); bin[j] = rb(); }
		add_ctl(ain, bin, oa, ADDN, add_scales[i][0], add_scales[i][1],
			add_scales[i][2], -128, 127);
		add_b87(ain, bin, ob, ADDN, add_scales[i][0], add_scales[i][1],
			add_scales[i][2], -128, 127);
		cmp("add[fx]", oa, ob, ADDN);
	}
	/* Only the R rotated dimensions go through the pair loop the G hoist feeds; the
	 * D - R pass-through dimensions are the table, whose own tie tests are made once per
	 * entry and are not counted per element.  So the ceiling poison 6 can reach is the
	 * rotated count, not the element count. */
	printf("MB_B87_GATE exact_path rope ctl=%lu b87=%lu of %lu rotated %lu\n",
	       rope_slow_ctl, rope_slow_b87, rope_n_ctl,
	       (unsigned long)(12L * RT * RH * RR));
	printf("MB_B87_GATE exact_path add  ctl=%lu b87=%lu of %lu\n",
	       add_slow_ctl, add_slow_b87, add_n_ctl);
#endif

	printf("MB_B87_GATE cases=%ld bytes=%ld mismatches=%ld %s\n",
	       total_cases, total_bytes, total_bad, total_bad ? "FAIL" : "PASS");
	return total_bad ? 1 : 0;
}
