/* SPDX-License-Identifier: Apache-2.0
 *
 * B87's decoder follow-on -- where the DECODER's layernorm_s8 cycles go, at M = 1.
 *
 * WHY THIS EXISTS RATHER THAN A QUOTE FROM B66.  B66 measured this kernel's hoist and
 * fallback at K = 288 and published
 *
 *     M      fallback      hoist
 *     1        37,787     40,666
 *     2        75,408     61,933
 *     165   6,209,035  3,529,858
 *
 * and set MBP_LN_MINM = 2 on it, correctly.  **B76 then changed the same kernel** --
 * ln_scale replaces two 128-bit products per element and ln_q8_full replaces the double
 * clamp -- and the decoder ships -DMBP_B76=1.  B66's numbers are therefore from a kernel
 * that is not the one running.  Dividing the shipped 14,699,654 cycles / 456 dispatches
 * by B66's 37,787 gives a CPI of 0.853, which a single-issue in-order hart cannot do:
 * that impossibility is the instrument telling us the two numbers come from different
 * builds.  So both arms are re-measured here at the flags the decoder actually ships.
 *
 * THE SPLIT, solved not asserted.  At fixed K the count is affine in M:
 *
 *     I(M) = S + BUILD + M * ROW          (hoist on)
 *     I(M) = S + M * ROW_INLINE           (hoist off, the shipped path at M = 1)
 *
 * Two M points per arm give ROW and then BUILD, and a third checks the fit.
 *
 * WHAT IT IS FOR.  The hoist is per DISPATCH and B66's guard is right about that: at
 * M = 1 a per-element decode and a per-row decode are the same 288 decodes, and only the
 * hoist also pays to store and reload them.  **The question nobody asked is whether the
 * decode is per dispatch at all.**  gamma and beta are WEIGHTS; the decoded table depends
 * on (gamma, beta, scale_out) and on nothing else in the dispatch.  The decoder issues
 * 456 layernorm_s8 dispatches over 6 layers x 2 sites = 12 distinct weight pairs -- 38
 * dispatches per site, every one of them rebuilding the same 288 entries.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

void ln_ship(const int8_t *, const float *, const float *, int8_t *,
	     int, int, float, float, float, int, int);
void ln_hoist(const int8_t *, const float *, const float *, int8_t *,
	      int, int, float, float, float, int, int);
void ln_cache(const int8_t *, const float *, const float *, int8_t *,
	      int, int, float, float, float, int, int);
extern unsigned long ln_cache_hits, ln_cache_misses;

#define KMAX 288
#define MMAX 4
static int8_t lin[KMAX * MMAX], lout[KMAX * MMAX];
static float gam[KMAX], bet[KMAX];

/* THE DECODER'S OWN DISPATCH PATTERN.  6 layers x 2 sites = 12 distinct weight pairs, all
 * twelve touched once per decode step and the step repeated 38 times = 456 dispatches.
 * The reuse distance is therefore TWELVE, which is why a one-entry cache would hit zero
 * times and why this is measured over the real sequence rather than over one dispatch. */
#define SITES 12
#define STEPS 38
static float sg[SITES][KMAX], sb[SITES][KMAX];

static inline uint64_t rd_minstret(void)
{
	uint64_t v;

	__asm__ volatile("csrr %0, minstret" : "=r"(v));
	return v;
}

static uint64_t probe_overhead(void)
{
	uint64_t best = (uint64_t)-1;
	int i;

	for (i = 0; i < 8; i++) {
		uint64_t a = rd_minstret();
		uint64_t b = rd_minstret();

		if (b - a < best) {
			best = b - a;
		}
	}
	return best;
}

static uint64_t ovh;

static void line(const char *tag, uint64_t v)
{
	htif_puts(tag);
	htif_putu(v);
	htif_puts("\n");
}

static uint64_t sd = 0x243F6A8885A308D3ull;
static uint32_t nxt(void)
{
	sd ^= sd << 13; sd ^= sd >> 7; sd ^= sd << 17;
	return (uint32_t)(sd >> 32);
}

/* The decoder's layer-0 input_layernorm scales, from out/b83_dec_f41667/dec_q16/gen/model.c */
#define LN_SI 0.0116899032f
#define LN_SO 0.024689531f
#define LN_EPS 9.99999975e-06f

/* gamma near 1 and beta near 0, which is what a trained LayerNorm carries; the decode
 * cost does not depend on the value but the clamp behaviour does, so they are kept in
 * the range the model actually ships rather than uniform random. */
static void fill(int n)
{
	int i;

	sd = 0x243F6A8885A308D3ull;
	for (i = 0; i < KMAX; i++) {
		gam[i] = 1.0f + (float)((int32_t)(nxt() % 2000) - 1000) / 4000.0f;
		bet[i] = (float)((int32_t)(nxt() % 2000) - 1000) / 8000.0f;
	}
	for (i = 0; i < n; i++) {
		lin[i] = (int8_t)(uint8_t)(nxt() >> 9);
	}
}

static uint64_t one(void (*f)(const int8_t *, const float *, const float *, int8_t *,
			      int, int, float, float, float, int, int), int M, int K)
{
	uint64_t a, b;

	fill(M * K);
	a = rd_minstret();
	f(lin, gam, bet, lout, M, K, LN_SI, LN_SO, LN_EPS, -128, 127);
	b = rd_minstret();
	return b - a - ovh;
}

static void fill_sites(void)
{
	int i, k;

	sd = 0x13198A2E03707344ull;
	for (i = 0; i < SITES; i++) {
		for (k = 0; k < KMAX; k++) {
			sg[i][k] = 1.0f + (float)((int32_t)(nxt() % 2000) - 1000) / 4000.0f;
			sb[i][k] = (float)((int32_t)(nxt() % 2000) - 1000) / 8000.0f;
		}
	}
	for (k = 0; k < KMAX; k++) {
		lin[k] = (int8_t)(uint8_t)(nxt() >> 9);
	}
}

/* the whole 456-dispatch sequence, one number, no fit */
static uint64_t sweep(void (*f)(const int8_t *, const float *, const float *, int8_t *,
				int, int, float, float, float, int, int))
{
	uint64_t a, b;
	int t, i;

	fill_sites();
	a = rd_minstret();
	for (t = 0; t < STEPS; t++) {
		for (i = 0; i < SITES; i++) {
			f(lin, sg[i], sb[i], lout, 1, 288, LN_SI, LN_SO, LN_EPS, -128, 127);
		}
	}
	b = rd_minstret();
	return b - a - ovh;
}

int main(void)
{
	uint64_t s1, s2, s3, h1, h2, h3, srow, hrow, hbuild;
	uint64_t sw_ship, sw_cache;

	ovh = probe_overhead();
	line("MB_B87LN probe_overhead=", ovh);

	/* K = 288 throughout -- the decoder's only layernorm_s8 shape, one shape, checked. */
	s1 = one(ln_ship, 1, 288);
	s2 = one(ln_ship, 2, 288);
	s3 = one(ln_ship, 4, 288);
	h1 = one(ln_hoist, 1, 288);
	h2 = one(ln_hoist, 2, 288);
	h3 = one(ln_hoist, 4, 288);

	line("MB_B87LN ship_M1_K288=", s1);      /* THE DECODER'S OWN DISPATCH */
	line("MB_B87LN ship_M2_K288=", s2);
	line("MB_B87LN ship_M4_K288=", s3);
	line("MB_B87LN hoist_M1_K288=", h1);
	line("MB_B87LN hoist_M2_K288=", h2);
	line("MB_B87LN hoist_M4_K288=", h3);

	srow = s2 - s1;
	hrow = h2 - h1;
	line("MB_B87LN ship_row=", srow);        /* inline-decode row, 288 elements */
	line("MB_B87LN hoist_row=", hrow);       /* table-read row, 288 elements */
	line("MB_B87LN hoist_build_plus_fixed=", h1 - hrow);
	line("MB_B87LN ship_fixed=", s1 - srow);
	/* the third point checks the fit rather than being used to make it */
	line("MB_B87LN ship_M4_recon=", s1 + 3 * srow);
	line("MB_B87LN hoist_M4_recon=", h1 + 3 * hrow);

	/* What a CROSS-DISPATCH cache would cost: the hoisted row plus the shipped fixed
	 * term, with BUILD paid once per site instead of once per dispatch. */
	hbuild = h1 - hrow - (s1 - srow);
	line("MB_B87LN build_alone=", hbuild);
	line("MB_B87LN cached_hit_dispatch=", hrow + (s1 - srow));
	line("MB_B87LN ship_dispatch=", s1);

	/* ===== THE MEASUREMENT THAT NEEDS NO FIT: the decoder's own 456-dispatch
	 * sequence, 12 sites x 38 steps, shipped arm against the cached arm. ===== */
	sw_ship = sweep(ln_ship);
	ln_cache_hits = ln_cache_misses = 0;
	sw_cache = sweep(ln_cache);
	line("MB_B87LN sweep_ship_456=", sw_ship);
	line("MB_B87LN sweep_cache_456=", sw_cache);
	line("MB_B87LN sweep_saving=", sw_ship - sw_cache);
	line("MB_B87LN cache_hits=", ln_cache_hits);
	line("MB_B87LN cache_misses=", ln_cache_misses);
	line("MB_B87LN sweep_ship_per_dispatch=", sw_ship / (STEPS * SITES));
	line("MB_B87LN sweep_cache_per_dispatch=", sw_cache / (STEPS * SITES));

	htif_exit(0);
	return 0;
}
