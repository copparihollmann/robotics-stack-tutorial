/* SPDX-License-Identifier: Apache-2.0
 *
 * B82 -- THE INSTRUCTION ACCOUNT FOR THE "K A MULTIPLE OF 8" ROUTE in matmul_b_s8's
 * tb = 1 path, fitted against N and against K, on spike, at the board's own flags.
 *
 * MATMUL_B_COST.md section 32.8 item 2 records the route and prices it at 199.68
 * instructions per element against K = 165's 256.87 (-22.3 %), "the largest single
 * remaining item".  That figure is per ELEMENT on ONE family.  This harness measures
 * the whole dispatch so the saving can be converted to cycles against the board's own
 * per-family rows, and fits it against N so the fixed and marginal terms separate --
 * section 31.1's rule, which section 30.4 and section 17 each broke once.
 *
 * WHAT IS PADDED AND WHY IT IS EXACT.  At K = 168 the pads' bytes 165..167 multiply
 * A's bytes 165..167.  pmmb_m1_pad0 zeroes nothing there (168 is a multiple of 8, so
 * every word is a "full" word), so ONE of the two operands must carry real zeros.
 * The harness zeroes A's tail (probs) and fills B's tail with NON-ZERO poison, so a
 * result that matches the K = 165 reference proves the zeros are doing the work and
 * a result that does not proves the route needs both sides padded.  A poison that is
 * visible in the OUTPUT, not in an intermediate.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

void mmb_ship(const int8_t *, const int8_t *, int8_t *, int, int, int, int,
	      float, float, float, int, float, int, int);
void mmb_unr(const int8_t *, const int8_t *, int8_t *, int, int, int, int,
	     float, float, float, int, float, int, int);

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

#define BB    8
#define KMAX  200
#define NMAX  288

static int8_t  A[BB * KMAX]                 __attribute__((aligned(64)));
static int8_t  Bt[(size_t)BB * NMAX * KMAX] __attribute__((aligned(64)));
static int8_t  O[BB * NMAX]                 __attribute__((aligned(64)));
static int8_t  Oref[BB * NMAX]              __attribute__((aligned(64)));

static uint32_t rng = 12345u;
static int rnd(void) { rng = rng * 1103515245u + 12345u; return (int)((rng >> 16) & 0xff); }

/* fill A with K_real live bytes then `pad` zero bytes; B's rows at stride K_use with
 * K_real live bytes then POISON in the pad -- the poison must reach the output if the
 * padding argument is wrong. */
static int apad_val;

static void fill(int K_real, int K_use, int N, int poison)
{
	int bi, j, k;

	rng = 12345u;              /* the two arms must see the SAME data, or `diff` is noise */
	for (bi = 0; bi < BB; bi++) {
		for (k = 0; k < K_use; k++) {
			A[bi * K_use + k] = (int8_t)(k < K_real ? (rnd() - 128) : apad_val);
		}
		for (j = 0; j < N; j++) {
			int8_t *row = Bt + ((size_t)bi * N + j) * K_use;

			for (k = 0; k < K_use; k++) {
				row[k] = (int8_t)(k < K_real ? (rnd() - 128) : poison);
			}
		}
	}
}

static int cmp(int n)
{
	int i, d = 0;

	for (i = 0; i < n; i++) {
		if (O[i] != Oref[i]) {
			d++;
		}
	}
	return d;
}

static void row(const char *tag, int K_use, int N, uint64_t instr, int el, int diff)
{
	htif_puts("MB_B82 ");
	htif_puts(tag);
	htif_puts(" K="); htif_putu((uint64_t)K_use);
	htif_puts(" N="); htif_putu((uint64_t)N);
	htif_puts(" instr="); htif_putu(instr);
	htif_puts(" el="); htif_putu((uint64_t)el);
	/* instructions per element, x1000, so no float leaves the guest */
	htif_puts(" ipe_x1000="); htif_putu(instr * 1000u / (uint64_t)el);
	htif_puts(" diff="); htif_putu((uint64_t)diff);
	htif_puts("\n");
}

#define SA 0.0078125f
#define SB 0.0078125f
#define SO 0.0625f
#define SD 1.0f

static uint64_t run(int which, int K, int N, uint64_t ov)
{
	uint64_t t0, t1;

	if (which == 0) {
		t0 = rd_minstret();
		mmb_ship(A, Bt, O, BB, 1, K, N, SA, SB, SO, 1, SD, -128, 127);
		t1 = rd_minstret();
	} else {
		t0 = rd_minstret();
		mmb_unr(A, Bt, O, BB, 1, K, N, SA, SB, SO, 1, SD, -128, 127);
		t1 = rd_minstret();
	}
	return t1 - t0 - ov;
}

static void save_ref(int n) { int i; for (i = 0; i < n; i++) Oref[i] = O[i]; }

int main(void)
{
	static const int NS[4] = { 36, 72, 144, 288 };
	uint64_t ov = probe_overhead();
	int i;

	/* ---- cross PV's shape: K = 165 (ships) against K = 168 (the route) ---- */
	for (i = 0; i < 4; i++) {
		int N = NS[i], n = BB * N;

		fill(165, 165, N, 0);
		(void)run(0, 165, N, ov);              /* warm */
		row("pv_ship", 165, N, run(0, 165, N, ov), n, 0);
		save_ref(n);

		/* K = 168, A zero-padded, B poisoned in the pad */
		fill(165, 168, N, 0x5a);
		(void)run(0, 168, N, ov);
		row("pv_k168", 168, N, run(0, 168, N, ov), n, cmp(n));

		/* the same, with B's pad zeroed as well -- section 32.8's own form */
		fill(165, 168, N, 0);
		(void)run(0, 168, N, ov);
		row("pv_k168z", 168, N, run(0, 168, N, ov), n, cmp(n));

		/* unrolled kernel, both K */
		fill(165, 165, N, 0);
		(void)run(1, 165, N, ov);
		row("pv_ship_u8", 165, N, run(1, 165, N, ov), n, cmp(n));
		fill(165, 168, N, 0x5a);
		(void)run(1, 168, N, ov);
		row("pv_k168_u8", 168, N, run(1, 168, N, ov), n, cmp(n));
	}

	/* ---- cross QK^T's shape: K = 36 (ships, L = 2) against K = 40 (L = 1) ---- */
	{
		static const int NQ[4] = { 41, 82, 165, 288 };
		int q;

		for (q = 0; q < 4; q++) {
			int N = NQ[q], n = BB * N;

			fill(36, 36, N, 0);
			(void)run(0, 36, N, ov);
			row("qk_ship", 36, N, run(0, 36, N, ov), n, 0);
			save_ref(n);

			fill(36, 40, N, 0x5a);
			(void)run(0, 40, N, ov);
			row("qk_k40", 40, N, run(0, 40, N, ov), n, cmp(n));

			fill(36, 36, N, 0);
			(void)run(1, 36, N, ov);
			row("qk_ship_u8", 36, N, run(1, 36, N, ov), n, cmp(n));

			fill(36, 40, N, 0x5a);
			(void)run(1, 40, N, ov);
			row("qk_k40_u8", 40, N, run(1, 40, N, ov), n, cmp(n));
		}
	}

	/* ---- self QK^T: K = 36, N = 1..24 -- the board dispatches all 24 ---- */
	{
		int N;

		for (N = 1; N <= 24; N++) {
			int n = BB * N;

			fill(36, 36, N, 0);
			(void)run(0, 36, N, ov);
			row("sq_ship", 36, N, run(0, 36, N, ov), n, 0);
			save_ref(n);
			fill(36, 40, N, 0x5a);
			(void)run(0, 40, N, ov);
			row("sq_k40", 40, N, run(0, 40, N, ov), n, cmp(n));
		}
	}

	/* ---- THE POISON'S OWN CONTROL.  The three rows above claim that zeroing A's
	 * tail alone is enough.  That claim is only worth something if the harness can
	 * see a pad byte reach the output.  Flip which side carries the zeros, then
	 * poison BOTH: the first two must match the K = 165 reference and the third
	 * must NOT.  If the third matches, the pad bytes are not being read at all and
	 * every row above is measuring the wrong thing. ---- */
	{
		int N = 36, n = BB * N;

		apad_val = 0;
		fill(165, 165, N, 0);
		(void)run(0, 165, N, ov);
		row("poison_ref", 165, N, run(0, 165, N, ov), n, 0);
		save_ref(n);

		apad_val = 0;   fill(165, 168, N, 0x5a);   /* A zero, B poison  -> must match */
		(void)run(0, 168, N, ov);
		row("poison_aZbP", 168, N, run(0, 168, N, ov), n, cmp(n));

		apad_val = 0x5a; fill(165, 168, N, 0);     /* A poison, B zero  -> must match */
		(void)run(0, 168, N, ov);
		row("poison_aPbZ", 168, N, run(0, 168, N, ov), n, cmp(n));

		apad_val = 0x5a; fill(165, 168, N, 0x5a);  /* both poison -> MUST NOT match */
		(void)run(0, 168, N, ov);
		row("poison_aPbP", 168, N, run(0, 168, N, ov), n, cmp(n));
		apad_val = 0;
	}

	htif_puts("MB_B82 DONE\n");
	htif_exit(0);
	return 0;
}
