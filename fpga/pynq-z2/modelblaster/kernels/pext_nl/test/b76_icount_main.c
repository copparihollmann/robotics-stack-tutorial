/* SPDX-License-Identifier: Apache-2.0
 *
 * B76 -- THE INSTRUCTION ACCOUNT FOR THE DECODER'S FOUR HART-0 ELEMENTWISE KERNELS, at the
 * shapes the decoder actually dispatches and not at a benchmark's.
 *
 * WHAT THIS COUNTS.  `minstret`, retired instructions, read by the guest either side of
 * each call and corrected for the counter reads, on spike, with the board's own compiler
 * and flags -- including -DMB_PEXT_HW=1 and -falign-loops=4, which b66_icount.sh did not
 * carry and which change both the clip8 tail and the loop alignment.  Same method as
 * check/count_instructions.py and as b74_icount.sh.
 *
 * INSTRUCTIONS ARE NOT CYCLES and this file does not pretend otherwise.  The decoder's own
 * board record (out/b73_dec_ship/run.json) gives the cycles these shapes cost, so each row
 * below is reported next to the per-dispatch cycles it has to explain:
 *
 *     layernorm_s8   456 x M=1 K=288      39,817 cyc/dispatch    37,787 instr  CPI 1.054
 *     softmax_s8     144 x M=8 K=165      62,584 cyc/dispatch
 *                    144 x M=8 K=1..24    23,752..30,878
 *     permute4_s8    282 head-splits      ~5.96 cyc/BYTE
 *                      6 transposes       10.48 cyc/byte
 *     mul_s8         144 x n=1152         74,223 cyc/dispatch
 *
 * The RATIO is what survives the conversion, and it moves only to the extent that the two
 * arms' cycles-per-instruction differ.  Here they differ in a KNOWN DIRECTION for three of
 * the four -- B76 removes multiplies (mul_s8's builder, layernorm's nl_scale) and memory
 * operations (permute4's 3-per-byte copy) on a core where an L1-hit load is nearly free and
 * an iterative `mul` is not -- so the instruction saving is a CONSERVATIVE bound on the
 * cycle saving for those. softmax_s8 is the one where it is not, and it is banded as such.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

void perm_ship(const int8_t *, int8_t *, int, int, int, int, int, int, int, int,
	       float, float, int, int);
void perm_b76(const int8_t *, int8_t *, int, int, int, int, int, int, int, int,
	      float, float, int, int);
void mul_ship(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void mul_b76(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void ln_ship(const int8_t *, const float *, const float *, int8_t *,
	     int, int, float, float, float, int, int);
void ln_b76(const int8_t *, const float *, const float *, int8_t *,
	    int, int, float, float, float, int, int);
void smx_ship(const int8_t *, int8_t *, int, int, float, float);
void smx_b76(const int8_t *, int8_t *, int, int, float, float);
void smx_eager(const int8_t *, int8_t *, int, int, float, float);   /* B76, MINN = 0 */
void smx_lazy(const int8_t *, int8_t *, int, int, float, float);    /* B76, MINN = 1e9 */

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
static int8_t in_a[MAXEL] __attribute__((aligned(64)));
static int8_t in_b[MAXEL] __attribute__((aligned(64)));
static int8_t out_[MAXEL] __attribute__((aligned(64)));
static float gam[1024], bet[1024];

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
		long elems, long ndisp, uint64_t instr)
{
	htif_puts("MB_B76 op=");
	htif_puts(op);
	htif_puts(" arm=");
	htif_puts(arm);
	htif_puts(" ");
	htif_puts(qname);
	htif_puts("=");
	htif_putu((uint64_t)qty);
	htif_puts(" elems=");
	htif_putu((uint64_t)elems);
	htif_puts(" ndisp=");
	htif_putu((uint64_t)ndisp);
	htif_puts(" instret=");
	htif_putu(instr);
	htif_puts("\n");
}

#define TIME(call, op, arm, qname, qty, elems, ndisp)                   \
	do {                                                            \
		uint64_t t0, t1;                                        \
		t0 = rd_minstret();                                     \
		call;                                                   \
		t1 = rd_minstret();                                     \
		row(op, arm, qname, qty, elems, ndisp, t1 - t0 - ovh);  \
	} while (0)

/* The decoder's own quants (out/b73_dec_ship/ir_vlayout/graph.json).  Given as bit patterns
 * so the constant in the image is the constant the board runs, not a decimal round-trip. */
#define LN_SI  bits(0x3C3F86DCu)      /* layers.0.input_layernorm */
#define LN_SO  bits(0x3CCA4B3Du)
#define LN_EPS bits(0x3727C5ACu)      /* 1e-5 */
#define MU_SA  bits(0x3C31FDD1u)      /* the first mul_s8 dispatch */
#define MU_SB  bits(0x3C73F5B3u)
#define MU_SO  bits(0x3C117AD0u)
#define SM_SI  bits(0x3D0A6D7Bu)      /* a decoder softmax scale_in, 0.0337884993 */
#define SM_SO  bits(0x3C010204u)      /* 1/127, the same for all 288 */
#define PM_S   bits(0x3CBDF3B6u)      /* permute4 scale_in == scale_out */

/* Every DISTINCT permute4_s8 shape the decoder ships, with how many dispatches run it. */
static const struct { int d0, d1, d2, d3, p0, p1, p2, p3, ndisp; } pshapes[] = {
	{ 1, 165, 8, 36, 0, 2, 1, 3, 6 },      /* RUNS,   1,320 runs of 36 */
	{ 1, 165, 8, 36, 0, 2, 3, 1, 6 },      /* STRIDE,   288 runs of 165, os[2] == 1 */
	{ 1, 2, 8, 36, 0, 2, 1, 3, 12 },  { 1, 3, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 4, 8, 36, 0, 2, 1, 3, 12 },  { 1, 5, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 6, 8, 36, 0, 2, 1, 3, 12 },  { 1, 7, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 8, 8, 36, 0, 2, 1, 3, 12 },  { 1, 9, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 10, 8, 36, 0, 2, 1, 3, 12 }, { 1, 11, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 12, 8, 36, 0, 2, 1, 3, 12 }, { 1, 13, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 14, 8, 36, 0, 2, 1, 3, 12 }, { 1, 15, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 16, 8, 36, 0, 2, 1, 3, 12 }, { 1, 17, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 18, 8, 36, 0, 2, 1, 3, 12 }, { 1, 19, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 20, 8, 36, 0, 2, 1, 3, 12 }, { 1, 21, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 22, 8, 36, 0, 2, 1, 3, 12 }, { 1, 23, 8, 36, 0, 2, 1, 3, 12 },
	{ 1, 24, 8, 36, 0, 2, 1, 3, 12 },
};

int main(void)
{
	int i, t;

	ovh = probe_overhead();
	for (i = 0; i < 1024; i++) {
		gam[i] = bits(0x3F000000u | (uint32_t)(rnd() & 0x7fffffu));
		bet[i] = bits(0x3C000000u | (uint32_t)(rnd() & 0x7fffffu));
	}
	fill(in_a, MAXEL);
	fill(in_b, MAXEL);

	/* ---- 1. permute4_s8: every shape the decoder ships, both arms.  The quantity is the
	 *         shape itself -- there is no scalar to sweep -- so `ndisp` carries the weight
	 *         each row has in the op total. ---- */
	for (t = 0; t < (int)(sizeof(pshapes) / sizeof(pshapes[0])); t++) {
		const long n = (long)pshapes[t].d0 * pshapes[t].d1 *
			       pshapes[t].d2 * pshapes[t].d3;

		TIME(perm_ship(in_a, out_, pshapes[t].d0, pshapes[t].d1, pshapes[t].d2,
			       pshapes[t].d3, pshapes[t].p0, pshapes[t].p1, pshapes[t].p2,
			       pshapes[t].p3, PM_S, PM_S, -128, 127),
		     "permute4_s8", "ship", "shape", t, n, pshapes[t].ndisp);
		TIME(perm_b76(in_a, out_, pshapes[t].d0, pshapes[t].d1, pshapes[t].d2,
			      pshapes[t].d3, pshapes[t].p0, pshapes[t].p1, pshapes[t].p2,
			      pshapes[t].p3, PM_S, PM_S, -128, 127),
		     "permute4_s8", "b76", "shape", t, n, pshapes[t].ndisp);
	}

	/* ---- 2. mul_s8: the decoder's n = 1152, plus a sweep so the builder's fixed cost is
	 *         the INTERCEPT of instret against n and not an assertion. ---- */
	{
		static const int ns[] = { 0, 64, 256, 512, 1152, 2048, 4096, 8192 };

		for (t = 0; t < (int)(sizeof(ns) / sizeof(ns[0])); t++) {
			TIME(mul_ship(in_a, in_b, out_, ns[t], MU_SA, MU_SB, MU_SO, -128, 127),
			     "mul_s8", "ship", "n", ns[t], ns[t], ns[t] == 1152 ? 144 : 0);
			TIME(mul_b76(in_a, in_b, out_, ns[t], MU_SA, MU_SB, MU_SO, -128, 127),
			     "mul_s8", "b76", "n", ns[t], ns[t], ns[t] == 1152 ? 144 : 0);
		}
	}

	/* ---- 3. layernorm_s8: the decoder's 456 dispatches are ALL M = 1, K = 288, where the
	 *         B66 guard sends the kernel down the per-element fallback.  M = 165 is the
	 *         encoder's, on the hoisted path, and is reported because the file is shared
	 *         and a change here is crosstalk there. ---- */
	{
		static const int ms[] = { 1, 2, 8, 165 };

		for (t = 0; t < (int)(sizeof(ms) / sizeof(ms[0])); t++) {
			TIME(ln_ship(in_a, gam, bet, out_, ms[t], 288, LN_SI, LN_SO, LN_EPS,
				     -128, 127),
			     "layernorm_s8", "ship", "M", ms[t], (long)ms[t] * 288,
			     ms[t] == 1 ? 456 : 0);
			TIME(ln_b76(in_a, gam, bet, out_, ms[t], 288, LN_SI, LN_SO, LN_EPS,
				    -128, 127),
			     "layernorm_s8", "b76", "M", ms[t], (long)ms[t] * 288,
			     ms[t] == 1 ? 456 : 0);
		}
		/* A narrowed clamp, so the `full` test's other arm is priced too. */
		TIME(ln_ship(in_a, gam, bet, out_, 1, 288, LN_SI, LN_SO, LN_EPS, -100, 100),
		     "layernorm_s8", "ship_narrow", "M", 1, 288, 0);
		TIME(ln_b76(in_a, gam, bet, out_, 1, 288, LN_SI, LN_SO, LN_EPS, -100, 100),
		     "layernorm_s8", "b76_narrow", "M", 1, 288, 0);
	}

	/* ---- 4. softmax_s8.  Two questions: what the SPLIT eager path costs against the
	 *         shipped one (B66 measured its unsplit eager arm at +7..+11 %, which is the
	 *         whole reason the lazy fill ships off), and where the M*K crossover now sits.
	 *         Both arms of the crossover are forced, so the guard's choice is measured and
	 *         not assumed. ---- */
	{
		static const int ks[] = { 1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 32, 48, 96, 165 };

		for (t = 0; t < (int)(sizeof(ks) / sizeof(ks[0])); t++) {
			const long e = 8L * ks[t];
			const long nd = ks[t] <= 24 ? 6 : (ks[t] == 165 ? 144 : 0);

			TIME(smx_ship(in_a, out_, 8, ks[t], SM_SI, SM_SO),
			     "softmax_s8", "ship", "K", ks[t], e, nd);
			TIME(smx_b76(in_a, out_, 8, ks[t], SM_SI, SM_SO),
			     "softmax_s8", "b76", "K", ks[t], e, nd);
			TIME(smx_eager(in_a, out_, 8, ks[t], SM_SI, SM_SO),
			     "softmax_s8", "b76eager", "K", ks[t], e, nd);
			TIME(smx_lazy(in_a, out_, 8, ks[t], SM_SI, SM_SO),
			     "softmax_s8", "b76lazy", "K", ks[t], e, nd);
		}
		/* The encoder's own dispatch: 6 of them, and the shape the guard must keep
		 * eager.  This is the row B66's +10.80 % landed on. */
		TIME(smx_ship(in_a, out_, 1320, 165, SM_SI, SM_SO),
		     "softmax_s8", "ship", "ENC_K", 165, 217800L, 6);
		TIME(smx_b76(in_a, out_, 1320, 165, SM_SI, SM_SO),
		     "softmax_s8", "b76", "ENC_K", 165, 217800L, 6);
		TIME(smx_eager(in_a, out_, 1320, 165, SM_SI, SM_SO),
		     "softmax_s8", "b76eager", "ENC_K", 165, 217800L, 6);
		TIME(smx_lazy(in_a, out_, 1320, 165, SM_SI, SM_SO),
		     "softmax_s8", "b76lazy", "ENC_K", 165, 217800L, 6);
	}

	htif_puts("MB_B76_DONE\n");
	return 0;
}
