/* SPDX-License-Identifier: Apache-2.0
 *
 * B84 -- THE INSTRUCTION ACCOUNT FOR THE DECODER BUNDLE, at the DECODER's own shapes,
 * on spike, at the board's own flags.  Three levers, all already written:
 *
 *   1. MBP_B74   rope_s8 + add_s8.  B74 measured these on the ENCODER (T = 165, n = 47,520)
 *      and shipped them OFF, saying in as many words that "by B68's rule its end-to-end
 *      worth there [the decoder] is unknown and is NOT claimed here".  The decoder runs
 *      rope_s8 at T = 1 and add_s8 at n = 288, where the per-dispatch table BUILD is
 *      amortised over 288 elements instead of 47,520 -- so the split is not the encoder's
 *      and neither is the answer.  This harness measures the decoder's shapes.
 *
 *   2. MBP_B84   the seven shifted pad passes in matmul_b_s8's pmmb_m1_rows, interchanged.
 *      MATMUL_B_COST.md section 32.8 item 1 costed a binary-doubling cascade at
 *      1,514 -> 1,017 instructions per batch at T = 22 and did not build it.  The
 *      interchange is a different shape and its number is measured here, not carried.
 *
 * WHAT IS REPORTED IS WHOLE DISPATCHES, not inner loops, because the conversion to cycles
 * is against the board's own per-dispatch rows.  matmul_b is swept against N so the fixed
 * and marginal terms separate (MATMUL_B_COST.md section 31.1's rule).
 *
 * THE POISON IS IN THE OUTPUT.  Every matmul_b arm's result is compared byte for byte
 * against the shipping kernel's on the same data; a `diff` column that is not zero means
 * the arm is not the same function and the instruction count is meaningless.  B74's
 * lesson (L346 (10)): a poison that only moves an intermediate proves nothing.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

#include "pext.h"

void mmb_ship(const int8_t *, const int8_t *, int8_t *, int, int, int, int,
	      float, float, float, int, float, int, int);
void mmb_b84(const int8_t *, const int8_t *, int8_t *, int, int, int, int,
	     float, float, float, int, float, int, int);
void rope_ship(const int8_t *, const float *, const float *, int8_t *,
	       int, int, int, int, float, float, int, int);
void rope_b74(const int8_t *, const float *, const float *, int8_t *,
	      int, int, int, int, float, float, int, int);
void add_ship(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_b74(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);

static inline uint64_t rd_minstret(void)
{
	uint64_t v;

	__asm__ volatile("csrr %0, minstret" : "=r"(v));
	return v;
}

static uint64_t ovh;

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

static uint32_t rng = 12345u;
static int rnd(void) { rng = rng * 1103515245u + 12345u; return (int)((rng >> 16) & 0xff); }

/* ---------------- matmul_b ---------------- */
#define BB    8
#define KMAX  200
#define NMAX  288

static int8_t  A[BB * KMAX]                 __attribute__((aligned(64)));
static int8_t  Bt[(size_t)BB * NMAX * KMAX] __attribute__((aligned(64)));
static int8_t  O[BB * NMAX]                 __attribute__((aligned(64)));
static int8_t  Oref[BB * NMAX]              __attribute__((aligned(64)));

static void mfill(int K, int N)
{
	int bi, j, k;

	rng = 12345u;
	for (bi = 0; bi < BB; bi++) {
		for (k = 0; k < K; k++) {
			A[bi * K + k] = (int8_t)(rnd() - 128);
		}
		for (j = 0; j < N; j++) {
			int8_t *row = Bt + ((size_t)bi * N + j) * K;

			for (k = 0; k < K; k++) {
				row[k] = (int8_t)(rnd() - 128);
			}
		}
	}
}

static int mcmp(int n)
{
	int i, d = 0;

	for (i = 0; i < n; i++) {
		if (O[i] != Oref[i]) {
			d++;
		}
	}
	return d;
}

static void row(const char *tag, int K, int N, uint64_t instr, int el, int diff)
{
	htif_puts("MB_B84 ");
	htif_puts(tag);
	htif_puts(" K="); htif_putu((uint64_t)K);
	htif_puts(" N="); htif_putu((uint64_t)N);
	htif_puts(" instr="); htif_putu(instr);
	htif_puts(" el="); htif_putu((uint64_t)el);
	htif_puts(" ipe_x1000="); htif_putu(instr * 1000u / (uint64_t)el);
	htif_puts(" diff="); htif_putu((uint64_t)diff);
	htif_puts("\n");
}

static void line(const char *tag, uint64_t v)
{
	htif_puts("MB_B84 "); htif_puts(tag); htif_putu(v); htif_puts("\n");
}

/* the decoder's own cross-PV scale triple, verbatim from gen/model.c */
#define PV_SA 0.00787401572f
#define PV_SB 0.0118207913f
#define PV_SO 0.005805308f
/* and its cross-QK^T triple */
#define QK_SA 0.0463244766f
#define QK_SB 0.023331482f
#define QK_SO 0.0595385246f

static uint64_t mrun(int which, int K, int N, int tb, float sa, float sb, float so, float sd)
{
	uint64_t t0, t1;

	if (which == 0) {
		t0 = rd_minstret();
		mmb_ship(A, Bt, O, BB, 1, K, N, sa, sb, so, tb, sd, -128, 127);
		t1 = rd_minstret();
	} else {
		t0 = rd_minstret();
		mmb_b84(A, Bt, O, BB, 1, K, N, sa, sb, so, tb, sd, -128, 127);
		t1 = rd_minstret();
	}
	return t1 - t0 - ovh;
}

static void save_ref(int n) { int i; for (i = 0; i < n; i++) Oref[i] = O[i]; }

/* ---------------- rope_s8 and add_s8 ---------------- */
#define TR 1
#define HR 8
#define DR 36
#define RR 32
#define NROPE (TR * HR * DR)
#define NADD  288

static int8_t rin[NROPE], rout[NROPE];
static float ctab[TR * 32], stab[TR * 32];
static int8_t ain[NADD], bin[NADD], aout[NADD], aref[NADD];

/* the decoder's rope tables are built by emit_driver_meta from the model; their VALUES
 * decide which entries take fx32's fast class, so they are the model's own here: a
 * rotary table at the decoder's single position with theta = 10000^(-2i/D). */
static void fill_rope(void)
{
	int i;
	/* cos/sin at position 0 are exactly 1 and 0; the decoder's step 0 is what this
	 * graph dispatches (T = 1, one token at a time).  The table build cost does not
	 * depend on the position, and the pair loop's class does -- so sweep both. */
	for (i = 0; i < TR * 32; i++) {
		ctab[i] = (float)(0.9999 - 0.0003 * i);
		stab[i] = (float)(0.0004 * i);
	}
	rng = 999u;
	for (i = 0; i < NROPE; i++) {
		rin[i] = (int8_t)(rnd() - 128);
	}
}

static void fill_add(void)
{
	int i;

	rng = 4242u;
	for (i = 0; i < NADD; i++) {
		ain[i] = (int8_t)(rnd() - 128);
		bin[i] = (int8_t)(rnd() - 128);
	}
}

#define ROPE_SI 0.02616488f
#define ROPE_SO 0.02616488f

static uint64_t rope_one(int which)
{
	uint64_t a, b;

	fill_rope();
	a = rd_minstret();
	if (which == 0) {
		rope_ship(rin, ctab, stab, rout, TR, HR, DR, RR, ROPE_SI, ROPE_SO, -128, 127);
	} else {
		rope_b74(rin, ctab, stab, rout, TR, HR, DR, RR, ROPE_SI, ROPE_SO, -128, 127);
	}
	b = rd_minstret();
	return b - a - ovh;
}

static uint64_t add_one(int which, float sa, float sb, float so, int8_t *o)
{
	uint64_t a, b;

	fill_add();
	a = rd_minstret();
	if (which == 0) {
		add_ship(ain, bin, o, NADD, sa, sb, so, -128, 127);
	} else {
		add_b74(ain, bin, o, NADD, sa, sb, so, -128, 127);
	}
	b = rd_minstret();
	return b - a - ovh;
}

int main(void)
{
	static const int NS[4] = { 36, 72, 144, 288 };
	int i;

	ovh = probe_overhead();
	line("probe_overhead=", ovh);

	/* ---- cross PV: K = 165, tb = 1, L = 8 -- the only family B84 touches ---- */
	for (i = 0; i < 4; i++) {
		int N = NS[i], n = BB * N;
		uint64_t a, b;

		mfill(165, N);
		(void)mrun(0, 165, N, 1, PV_SA, PV_SB, PV_SO, 1.0f);
		a = mrun(0, 165, N, 1, PV_SA, PV_SB, PV_SO, 1.0f);
		row("pv_ship", 165, N, a, n, 0);
		save_ref(n);
		(void)mrun(1, 165, N, 1, PV_SA, PV_SB, PV_SO, 1.0f);
		b = mrun(1, 165, N, 1, PV_SA, PV_SB, PV_SO, 1.0f);
		row("pv_b84", 165, N, b, n, mcmp(n));
	}

	/* ---- cross QK^T: K = 36, tb = 1, L = 2 -- B84 must NOT fire, and the count
	 *      must therefore be identical to the shipping kernel's ---- */
	{
		static const int NQ[3] = { 41, 165, 288 };
		int q;

		for (q = 0; q < 3; q++) {
			int N = NQ[q], n = BB * N;
			uint64_t a, b;

			mfill(36, N);
			(void)mrun(0, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			a = mrun(0, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			row("qk_ship", 36, N, a, n, 0);
			save_ref(n);
			(void)mrun(1, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			b = mrun(1, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			row("qk_b84", 36, N, b, n, mcmp(n));
		}
	}

	/* ---- self QK^T at the shapes the growing cache dispatches, N = 1..24 ---- */
	{
		uint64_t sa = 0, sb = 0;
		int N, bad = 0;

		for (N = 1; N <= 24; N++) {
			int n = BB * N;

			mfill(36, N);
			(void)mrun(0, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			sa += mrun(0, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			save_ref(n);
			(void)mrun(1, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			sb += mrun(1, 36, N, 1, QK_SA, QK_SB, QK_SO, 6.0f);
			bad += mcmp(n);
		}
		line("selfqk_ship_sum_N1_24=", sa);
		line("selfqk_b84_sum_N1_24=", sb);
		line("selfqk_diff=", (uint64_t)bad);
	}

	/* ---- rope_s8 at the DECODER's shape: T = 1, H = 8, D = 36, R = 32 ---- */
	{
		uint64_t a, b;

		(void)rope_one(0);
		a = rope_one(0);
		(void)rope_one(1);
		b = rope_one(1);
		line("rope_ship_T1_H8_D36_R32=", a);
		line("rope_b74_T1_H8_D36_R32=", b);
	}

	/* ---- add_s8 at n = 288, the decoder's three shipped scale triples ---- */
	{
		static const float SA[3] = { 0.0116899032f, 0.0115270056f, 0.0514027402f };
		static const float SB[3] = { 0.00266063074f, 0.0489305109f, 0.104930677f };
		static const float SO[3] = { 0.0115270056f, 0.0514027402f, 0.150750071f };
		int t, bad = 0;
		uint64_t sa = 0, sb = 0;

		for (t = 0; t < 3; t++) {
			int k;

			(void)add_one(0, SA[t], SB[t], SO[t], aout);
			sa += add_one(0, SA[t], SB[t], SO[t], aout);
			for (k = 0; k < NADD; k++) {
				aref[k] = aout[k];
			}
			(void)add_one(1, SA[t], SB[t], SO[t], aout);
			sb += add_one(1, SA[t], SB[t], SO[t], aout);
			for (k = 0; k < NADD; k++) {
				if (aout[k] != aref[k]) {
					bad++;
				}
			}
		}
		line("add_ship_n288_x3=", sa);
		line("add_b74_n288_x3=", sb);
		line("add_diff=", (uint64_t)bad);
	}

	htif_puts("MB_B84 done\n");
	htif_exit(0);
	return 0;
}
