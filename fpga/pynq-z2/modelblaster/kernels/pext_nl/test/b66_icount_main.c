/* SPDX-License-Identifier: Apache-2.0
 *
 * B66 -- WHERE EACH OF THE THREE GUARDS CROSSES, MEASURED RATHER THAN ASSUMED.
 *
 * Every one of B66's three changes is a fixed cost traded against a per-element cost, so
 * each has a crossover, and each crossover is a number about ONE quantity:
 *
 *   groupnorm_s8   256 table entries per CHANNEL against HW elements per channel   -> HW
 *   layernorm_s8   K decodes stored and reloaded against (M-1)*K decodes saved      -> M
 *   add_s8         512 table entries per DISPATCH against n elements                -> n
 *
 * C and N cancel out of the first, K cancels out of the second, and the kernel's identity
 * is irrelevant to all three.  Guarding on anything else is the bug B63 found twice.
 *
 * WHAT THIS COUNTS.  `minstret`, retired instructions, read by the guest on either side of
 * each call and corrected for the counter reads, on spike, with the board's own compiler
 * and flags (riscv64-zephyr-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64
 * -mcmodel=medany -O2).  Same method and same harness files as
 * fpga/pynq-z2/modelblaster/check/count_instructions.py.
 *
 * INSTRUCTIONS ARE NOT CYCLES, and this file does not pretend otherwise -- B59 measured
 * 1.377 cyc/instr on this hart.  What survives the conversion is the RATIO: a crossover is
 * where two instruction counts are equal, and it moves only to the extent that the two
 * arms' cycles-per-instruction differ.  They do differ, and in a known direction: the
 * per-element arms are multiply-heavy (Rocket's `mul` is multi-cycle) and the table arms
 * are load-heavy on a 256-byte table that is hot in a 16 KB L1D, so a crossover measured in
 * instructions is a CONSERVATIVE bound on the crossover in cycles for the table.  The board
 * arm is what settles the cycles; this settles the shape of the curve and the guard.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

/* groupnorm arms: the table always, and the per-element path always. */
void gn_lut(const int8_t *, const float *, const float *, int8_t *,
	    int, int, int, int, float, float, float, int, int);
void gn_el(const int8_t *, const float *, const float *, int8_t *,
	   int, int, int, int, float, float, float, int, int);
/* layernorm arms: hoist always, fallback always, and the shipping kernel (hoist + __int128). */
void ln_h(const int8_t *, const float *, const float *, int8_t *,
	  int, int, float, float, float, int, int);
void ln_f(const int8_t *, const float *, const float *, int8_t *,
	  int, int, float, float, float, int, int);
void ln_ship(const int8_t *, const float *, const float *, int8_t *,
	     int, int, float, float, float, int, int);
/* add arms: table always, no table always, and the pre-B63 shipping builder. */
void add_tab(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_nob(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_ship(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
/* THE THIRD INSTANCE, measured rather than argued: the shipping softmax_s8 and mul_s8 each
 * carry an UNGUARDED per-dispatch fixed cost, and each is dispatched at both halves' shapes.
 * Only one arm of each exists -- there is nothing to turn off -- so the fixed cost is
 * extracted from the shape sweep as the intercept of instret against elements. */
void smx(const int8_t *, int8_t *, int, int, float, float);
void smx_ship(const int8_t *, int8_t *, int, int, float, float);   /* -DMBP_SMX_B66=0 */
void smx_eager(const int8_t *, int8_t *, int, int, float, float);
void smx_lazy(const int8_t *, int8_t *, int, int, float, float);
void mul_(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);

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

		if (b - a < best)
			best = b - a;
	}
	return best;
}

static uint64_t ovh;

#define MAXEL 300000
static int8_t in_a[MAXEL], in_b[MAXEL], out_[MAXEL];
static float gam[4096], bet[4096];

static uint64_t rs_ = 0x9E3779B97F4A7C15ull;
static uint64_t rnd(void)
{
	rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17;
	return rs_;
}

static void fill(int8_t *p, int n)
{
	int i;

	for (i = 0; i < n; i++)
		p[i] = (int8_t)(uint8_t)(rnd() & 0xff);
}

static float bits(uint32_t u)
{
	float f;

	__builtin_memcpy(&f, &u, sizeof(f));
	return f;
}

static void row(const char *op, const char *arm, const char *qname, long qty,
		long elems, uint64_t instr)
{
	htif_puts("MB_B66 op=");
	htif_puts(op);
	htif_puts(" arm=");
	htif_puts(arm);
	htif_puts(" ");
	htif_puts(qname);
	htif_puts("=");
	htif_putu((uint64_t)qty);
	htif_puts(" elems=");
	htif_putu((uint64_t)elems);
	htif_puts(" instret=");
	htif_putu(instr);
	htif_puts("\n");
}

/* Moonshine's own quant for the one groupnorm dispatch (out/attnfuse_on/graph.json). */
#define GN_SI  bits(0x3BD9AC4Bu)      /* 0.006643642859196113 */
#define GN_SO  bits(0x3D3F0C1Cu)      /* 0.04665333774521984  */
#define GN_EPS bits(0x3727C5ACu)      /* 1e-5 */
/* The first decoder layernorm's quant, and the first decoder add's scale triple. */
#define LN_SI  bits(0x3C3F86DCu)
#define LN_SO  bits(0x3CCA4B3Du)
#define AD_SA  bits(0x3C3F86DCu)
#define AD_SB  bits(0x3B2E5E7Bu)
#define AD_SO  bits(0x3C3CE0DAu)

#define TIME(call, op, arm, qname, qty, elems)                  \
	do {                                                    \
		uint64_t t0, t1;                                \
		t0 = rd_minstret();                             \
		call;                                           \
		t1 = rd_minstret();                             \
		row(op, arm, qname, qty, elems, t1 - t0 - ovh); \
	} while (0)

int main(void)
{
	static const int hws[] = { 32, 64, 128, 192, 256, 288, 320, 384, 448, 512,
				   640, 768, 999, 1280, 2048 };
	static const int ms[] = { 1, 2, 3, 4, 6, 8, 16, 165 };
	static const int ns[] = { 64, 128, 256, 288, 512, 768, 1024, 1152, 1320,
				  1536, 2048, 4096, 8192, 47520 };
	int i, t;

	ovh = probe_overhead();
	for (i = 0; i < 4096; i++) {
		gam[i] = bits(0x3F000000u | (uint32_t)(rnd() & 0x7fffffu));
		bet[i] = bits(0x3C000000u | (uint32_t)(rnd() & 0x7fffffu));
	}
	fill(in_a, MAXEL);
	fill(in_b, MAXEL);

	/* ---- 1. groupnorm: the quantity is HW, at a fixed C so nothing else moves ---- */
	for (t = 0; t < (int)(sizeof(hws) / sizeof(hws[0])); t++) {
		const int C = 8, W = hws[t];

		TIME(gn_el(in_a, gam, bet, out_, 1, C, 1, W, GN_SI, GN_SO, GN_EPS, -128, 127),
		     "groupnorm_s8", "perelem", "HW", W, (long)C * W);
		TIME(gn_lut(in_a, gam, bet, out_, 1, C, 1, W, GN_SI, GN_SO, GN_EPS, -128, 127),
		     "groupnorm_s8", "lut", "HW", W, (long)C * W);
	}
	/* and the dispatch Moonshine actually ships */
	TIME(gn_el(in_a, gam, bet, out_, 1, 288, 1, 999, GN_SI, GN_SO, GN_EPS, -128, 127),
	     "groupnorm_s8", "perelem", "SHIP_HW", 999, 287712L);
	TIME(gn_lut(in_a, gam, bet, out_, 1, 288, 1, 999, GN_SI, GN_SO, GN_EPS, -128, 127),
	     "groupnorm_s8", "lut", "SHIP_HW", 999, 287712L);

	/* ---- 2. layernorm: the quantity is M, at the model's K = 288 throughout ---- */
	for (t = 0; t < (int)(sizeof(ms) / sizeof(ms[0])); t++) {
		const int M = ms[t], K = 288;

		TIME(ln_f(in_a, gam, bet, out_, M, K, LN_SI, LN_SO, GN_EPS, -128, 127),
		     "layernorm_s8", "fallback", "M", M, (long)M * K);
		TIME(ln_h(in_a, gam, bet, out_, M, K, LN_SI, LN_SO, GN_EPS, -128, 127),
		     "layernorm_s8", "hoist", "M", M, (long)M * K);
		TIME(ln_ship(in_a, gam, bet, out_, M, K, LN_SI, LN_SO, GN_EPS, -128, 127),
		     "layernorm_s8", "ship", "M", M, (long)M * K);
	}

	/* ---- 3. add: the quantity is n ---- */
	for (t = 0; t < (int)(sizeof(ns) / sizeof(ns[0])); t++) {
		const int n = ns[t];

		TIME(add_tab(in_a, in_b, out_, n, AD_SA, AD_SB, AD_SO, -128, 127),
		     "add_s8", "table", "n", n, n);
		TIME(add_nob(in_a, in_b, out_, n, AD_SA, AD_SB, AD_SO, -128, 127),
		     "add_s8", "nobuild", "n", n, n);
		TIME(add_ship(in_a, in_b, out_, n, AD_SA, AD_SB, AD_SO, -128, 127),
		     "add_s8", "preb63", "n", n, n);
	}

	/* ---- 4. THE THIRD INSTANCE.  softmax_s8's 256-entry ex[] table and its per-ROW
	 *         256-wide bisection are built at every dispatch with no guard at all, and the
	 *         decoder dispatches this op at M = 8, K = 1..24 -- eight elements in the worst
	 *         case -- while the encoder dispatches it at M = 1320, K = 165.  Swept in K at
	 *         the decoder's M, then at both halves' own shapes. ---- */
	{
		static const int ks[] = { 1, 2, 4, 8, 12, 16, 24, 48, 96, 165, 330, 660 };

		for (t = 0; t < (int)(sizeof(ks) / sizeof(ks[0])); t++)
			TIME(smx(in_a, out_, 8, ks[t], LN_SI, LN_SO),
			     "softmax_s8", "ship", "K", ks[t], 8L * ks[t]);
		TIME(smx(in_a, out_, 8, 165, LN_SI, LN_SO),
		     "softmax_s8", "ship", "DEC_K", 165, 1320L);
		TIME(smx(in_a, out_, 1320, 165, LN_SI, LN_SO),
		     "softmax_s8", "ship", "ENC_K", 165, 217800L);

		/* B66's guard on M*K: eager 256-entry build against a lazy fill, at the
		 * decoder's M and across the shapes it ships, then at the encoder's. */
		for (t = 0; t < (int)(sizeof(ks) / sizeof(ks[0])); t++) {
			TIME(smx_ship(in_a, out_, 8, ks[t], LN_SI, LN_SO),
			     "softmax_s8", "b66off", "K", ks[t], 8L * ks[t]);
			TIME(smx_eager(in_a, out_, 8, ks[t], LN_SI, LN_SO),
			     "softmax_s8", "eager", "K", ks[t], 8L * ks[t]);
			TIME(smx_lazy(in_a, out_, 8, ks[t], LN_SI, LN_SO),
			     "softmax_s8", "lazy", "K", ks[t], 8L * ks[t]);
		}
		TIME(smx_ship(in_a, out_, 1320, 165, LN_SI, LN_SO),
		     "softmax_s8", "b66off", "ENC_K", 165, 217800L);
		TIME(smx_eager(in_a, out_, 1320, 165, LN_SI, LN_SO),
		     "softmax_s8", "eager", "ENC_K", 165, 217800L);
		TIME(smx_lazy(in_a, out_, 1320, 165, LN_SI, LN_SO),
		     "softmax_s8", "lazy", "ENC_K", 165, 217800L);
	}

	/* ---- 5. mul_s8: one 256-entry table, every entry an fx32_apply -- a 128-bit multiply
	 *         and an fx32_bitlen128 that this ISA lowers to an out-of-line libgcc __clzdi2.
	 *         That is the builder B63 removed from add_s8 and left standing here.  144
	 *         decoder dispatches, n = 1152. ---- */
	for (t = 0; t < (int)(sizeof(ns) / sizeof(ns[0])); t++)
		TIME(mul_(in_a, in_b, out_, ns[t], AD_SA, AD_SB, AD_SO, -128, 127),
		     "mul_s8", "ship", "n", ns[t], ns[t]);

	htif_puts("MB_B66_DONE\n");
	return 0;
}
