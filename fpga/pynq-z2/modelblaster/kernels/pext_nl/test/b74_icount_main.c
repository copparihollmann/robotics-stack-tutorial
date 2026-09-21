/* SPDX-License-Identifier: Apache-2.0
 *
 * B74 -- WHERE rope_s8's AND add_s8's CYCLES ACTUALLY GO, and what floor applies to each,
 * both solved before any board time is taken.
 *
 * WHY THIS PROGRAM EXISTS.  The work list scores both operators against 6.07 cyc/element,
 * which is permute4_s8's PBLK_RUNS -- a CONTIGUOUS copy moved a WORD at a time.  B72
 * showed that figure is the wrong mode for a strided access (the same kernel's PBLK_STRIDE
 * measures 15.076 on the same bytes).  Neither of these operators is a copy in either
 * mode: add_s8 is two random 8-byte table reads per element over two byte streams, and
 * rope_s8 is four 64x64 multiplies per pair against a per-position table it BUILDS.  A
 * ratio against the wrong floor is worse than no ratio, so this program measures the
 * floors instead of quoting one.
 *
 * WHAT IT COUNTS.  `minstret`, retired instructions, read by the guest on either side of
 * each call and corrected for the counter reads, on spike, with the board's own compiler
 * and flags (riscv64-zephyr-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64
 * -mcmodel=medany -O2 -falign-loops=4).  Same method and harness as b66_icount_main.c and
 * b67_icount_main.c.
 *
 * INSTRUCTIONS ARE NOT CYCLES.  B59 measured 1.377 cyc/instr on this hart; B63c measured a
 * table BUILD at 3.97x its instruction account under engine load (a cold-line store on an
 * L1D that fills before writing) and the ELEMENT loop at 1.10x.  What survives the
 * conversion is the SHAPE -- which term dominates, and how far each is from the least
 * instructions its own semantics allow.  The board arm settles the cycles.
 *
 * THE SPLITS ARE SOLVED, NOT ASSERTED.
 *
 * rope_s8's instruction count is affine in (T, H) at fixed (D, R):
 *
 *     I(T, H) = S + T*BLD*R2 + T*H*(PAIR*R2 + PASS*(D-R))
 *
 * with BLD the per-position-entry table build, PAIR the pair loop's cost for TWO elements
 * and PASS the pass-through loop's per element.  Sweeping H at fixed T gives the bracket
 * (PAIR*R2 + PASS*(D-R)) with no build in it; sweeping T at fixed H then gives BLD; and
 * PAIR and PASS are separated by running D = R (no pass-through dimensions at all)
 * against D = R + 4, which is the encoder's own shape.  Every one of those is a different
 * call to the SAME object file, so nothing is taken on trust from a second build.
 *
 * add_s8's is affine in n:  I(n) = S + E*n, two points and a check at a third.
 *
 * AND THE DISASSEMBLY IS THE SECOND WITNESS.  b74_icount.sh objdumps the very objects
 * measured here and counts the inner loops' instructions between the backedge and its
 * target.  The sweep measures the sum of everything the loop pays; the disassembly
 * measures what is in the loop body.  B67 closed those two to 0.37 % and neither was
 * taken from the other.
 *
 * THE FLOOR ARMS.  Four kernels that are NOT candidates and are not bit-exact -- they
 * exist only to price the floor of each access pattern in the same harness, at the same
 * shapes, under the same compiler:
 *
 *   add_floor   the shipped element loop with the half-integer guard and the exact
 *               fallback DELETED: two table reads, an add, a rounding shift, a clip, a
 *               store.  The least a TABLE-MEDIATED two-stream add can retire.
 *   add_copy    out[i] = a[i] + b[i], byte at a time.  The least ANY two-stream byte
 *               pointwise operator can retire on this ISA, tables or no tables.
 *   rope_floor  the pair loop with the guard deleted and the build replaced by a trivial
 *               one: four multiplies, two adds, two rounding shifts, two clips, two
 *               stores per pair.
 *   rope_copy   y[i] = x[i], byte at a time, over rope's own shape.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

#include "pext.h"

/* ---- the arms under measurement, one object each ---------------------------------- */
void rope_ship(const int8_t *, const float *, const float *, int8_t *,
	       int, int, int, int, float, float, int, int);
void rope_pre(const int8_t *, const float *, const float *, int8_t *,
	      int, int, int, int, float, float, int, int);
void add_ship(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_pre(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void rope_b74(const int8_t *, const float *, const float *, int8_t *,
	      int, int, int, int, float, float, int, int);
void add_b74(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);

/* ---- buffers ---------------------------------------------------------------------- */
#define TMAX  200
#define HMAX  8
#define DMAX  40
#define NROPE (TMAX * HMAX * DMAX)
#define NADD  49152

static int8_t rin[NROPE], rout[NROPE];
static float ctab[TMAX * 32], stab[TMAX * 32];
static int8_t ain[NADD], bin[NADD], aout[NADD];

/* ---- floor arms -------------------------------------------------------------------- */
#include "fexact32.h"

static int64_t fta[256], ftb[256];

/* The shipped fast path with the guard and the exact fallback removed.  Same loads, same
 * stores, same arithmetic; NOT bit-exact, and not a candidate. */
static void add_floor(const int8_t *a, const int8_t *b, int8_t *o, int n,
		      float sa, float sb, float so)
{
	const fx32_t fa = fx32_dec(sa), fb = fx32_dec(sb), fo = fx32_dec(so);
	fx32_k_t ka, kb;
	int la, lb, lo, F, ok = 1, i;
	int64_t half;

	la = fx32_bitlen64(fa.m) + fa.e;
	lb = fx32_bitlen64(fb.m) + fb.e;
	lo = fx32_bitlen64(fo.m) + fo.e;
	F = 44 - ((la > lb ? la : lb) - lo);
	ka = fx32_ratio(fa, fo);
	kb = fx32_ratio(fb, fo);
	for (i = 0; i < 256; i++) {
		int v = (int8_t)(uint8_t)i;

		fta[i] = fx32_apply((uint64_t)(v < 0 ? -v : v), 0, v < 0, ka, F, &ok);
		ftb[i] = fx32_apply((uint64_t)(v < 0 ? -v : v), 0, v < 0, kb, F, &ok);
	}
	half = (int64_t)1 << (F - 1);
	for (i = 0; i < n; i++) {
		int64_t x = fta[(uint8_t)a[i]] + ftb[(uint8_t)b[i]];

		o[i] = (int8_t)mb_pext_clip8((x + half) >> F);
	}
	(void)ok;
}

static void add_copy(const int8_t *a, const int8_t *b, int8_t *o, int n)
{
	int i;

	for (i = 0; i < n; i++) {
		o[i] = (int8_t)(a[i] + b[i]);
	}
}

struct fe { int64_t ck, sk; uint64_t glo, ghi; };
static struct fe FE[64];

/* rope's pair loop with the guard removed and a trivial build, over the same shape. */
static void rope_floor(const int8_t *x, int8_t *y, int T, int H, int D, int R, int F)
{
	const int R2 = R / 2;
	const int64_t half = (int64_t)1 << (F - 1);
	int t, h, i, d;

	for (t = 0; t < T; t++) {
		for (i = 0; i < R2; i++) {
			FE[i].ck = 0x123456789ll + t + i;
			FE[i].sk = 0x987654321ll - t + i;
		}
		for (h = 0; h < H; h++) {
			const size_t base = ((size_t)t * (size_t)H + (size_t)h) * (size_t)D;
			const int8_t *p = x + base;
			int8_t *q = y + base;
			const struct fe *e = FE;
			const int8_t *pe = p + 2 * R2;

			for (; p < pe; p += 2, q += 2, e++) {
				const int a0 = p[0], a1 = p[1];
				const int64_t ck = e->ck, sk = e->sk;
				const int64_t x0 = (int64_t)a0 * ck - (int64_t)a1 * sk;
				const int64_t x1 = (int64_t)a1 * ck + (int64_t)a0 * sk;

				q[0] = (int8_t)mb_pext_clip8((x0 + half) >> F);
				q[1] = (int8_t)mb_pext_clip8((x1 + half) >> F);
			}
			for (d = R; d < D; d++) {
				q[d - 2 * R2] = (int8_t)mb_pext_clip8(
					(((int64_t)p[d - 2 * R2] * FE[0].ck) + half) >> F);
			}
		}
	}
}

static void rope_copy(const int8_t *x, int8_t *y, int n)
{
	int i;

	for (i = 0; i < n; i++) {
		y[i] = x[i];
	}
}

/* ---- minstret ---------------------------------------------------------------------- */
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

static void line2(const char *tag, uint64_t a, const char *tag2, uint64_t b)
{
	htif_puts(tag);
	htif_putu(a);
	htif_puts(tag2);
	htif_putu(b);
	htif_puts("\n");
}

/* ---- Moonshine's own rotary tables: theta = t / 10000^(2i/R) ------------------------ */
/* No libm here, and no FPU on the target.  cos/sin are computed from a Taylor/range
 * reduction in double-free integer-free form -- but this is the HARNESS, outside every
 * measurement window, so plain software double arithmetic via the compiler's soft-float
 * would be legal.  It is not available either (-ffreestanding, no libgcc soft-double is
 * linked for these ops on rv64imac?  it is: __adddf3 etc. come from -lgcc).  So: doubles
 * are used here and only here, before the first rd_minstret. */
static double d_pow(double b, double e);
static double d_exp(double x)
{
	double s = 1.0, t = 1.0;
	int k;

	for (k = 1; k < 24; k++) {
		t *= x / (double)k;
		s += t;
	}
	return s;
}

static double d_log(double x)
{
	/* log(x) = 2 atanh((x-1)/(x+1)), after scaling x into [0.75, 1.5) by powers of 2. */
	int e = 0;
	double z, z2, s, t;
	int k;

	while (x >= 1.5) { x *= 0.5; e++; }
	while (x < 0.75) { x *= 2.0; e--; }
	z = (x - 1.0) / (x + 1.0);
	z2 = z * z;
	s = 0.0;
	t = z;
	for (k = 0; k < 40; k++) {
		s += t / (double)(2 * k + 1);
		t *= z2;
	}
	return 2.0 * s + (double)e * 0.69314718055994530942;
}

static double d_pow(double b, double e)
{
	return d_exp(e * d_log(b));
}

static double d_sin(double x)
{
	const double TWOPI = 6.28318530717958647692;
	double t, s;
	int k;

	while (x > TWOPI) { x -= TWOPI; }
	while (x < -TWOPI) { x += TWOPI; }
	t = x;
	s = x;
	for (k = 1; k < 30; k++) {
		t *= -x * x / (double)((2 * k) * (2 * k + 1));
		s += t;
	}
	return s;
}

static double d_cos(double x)
{
	const double TWOPI = 6.28318530717958647692;
	double t, s;
	int k;

	while (x > TWOPI) { x -= TWOPI; }
	while (x < -TWOPI) { x += TWOPI; }
	t = 1.0;
	s = 1.0;
	for (k = 1; k < 30; k++) {
		t *= -x * x / (double)((2 * k - 1) * (2 * k));
		s += t;
	}
	return s;
}

static void tables(int T, int R2, int R)
{
	int t, i;

	for (t = 0; t < T; t++) {
		for (i = 0; i < R2; i++) {
			double inv = 1.0 / d_pow(10000.0, (double)(2 * i) / (double)R);
			double th = (double)t * inv;

			ctab[t * R2 + i] = (float)d_cos(th);
			stab[t * R2 + i] = (float)d_sin(th);
		}
	}
}

static void fill_rope(int n)
{
	int i;
	uint64_t s = 0x1234567890abcdefull;

	for (i = 0; i < n; i++) {
		s ^= s << 13; s ^= s >> 7; s ^= s << 17;
		rin[i] = (int8_t)(uint8_t)(s >> 33);
	}
}

static void fill_add(int n)
{
	int i;
	uint64_t s = 0x0fedcba987654321ull;

	for (i = 0; i < n; i++) {
		s ^= s << 13; s ^= s >> 7; s ^= s << 17;
		ain[i] = (int8_t)(uint8_t)(s >> 33);
		s ^= s << 13; s ^= s >> 7; s ^= s << 17;
		bin[i] = (int8_t)(uint8_t)(s >> 33);
	}
}

/* The encoder's own scale pairs: layer 0 q (rope) and layer 0 self-attn add. */
#define ROPE_SI 0.0563248396f
#define ROPE_SO 0.0632022619f
#define ADD_SA  0.490539283f
#define ADD_SB  0.504428208f
#define ADD_SO  0.572304666f

static uint64_t rope_one(void (*f)(const int8_t *, const float *, const float *, int8_t *,
				   int, int, int, int, float, float, int, int),
			 int T, int H, int D, int R)
{
	uint64_t a, b;

	fill_rope(T * H * D);
	a = rd_minstret();
	f(rin, ctab, stab, rout, T, H, D, R, ROPE_SI, ROPE_SO, -128, 127);
	b = rd_minstret();
	return b - a - ovh;
}

static uint64_t add_one(void (*f)(const int8_t *, const int8_t *, int8_t *, int,
				  float, float, float, int, int), int n)
{
	uint64_t a, b;

	fill_add(n);
	a = rd_minstret();
	f(ain, bin, aout, n, ADD_SA, ADD_SB, ADD_SO, -128, 127);
	b = rd_minstret();
	return b - a - ovh;
}

int main(void)
{
	uint64_t a, b;
	uint64_t r_T165H8, r_T165H4, r_T165H1, r_T33H8, r_T165H8_D32, r_T33H8_D32;
	uint64_t perh_D36, perh_D32, pass4, pairR2, bld;
	uint64_t i1, i2, i3;

	ovh = probe_overhead();
	line("MB_B74 probe_overhead=", ovh);

	/* Moonshine's tables once, at R2 = 16 -- every shape swept below has R = 32.  Built
	 * outside every measurement window; the soft-double here is the harness's, not the
	 * kernel's. */
	tables(166, 16, 32);

	/* ================= rope_s8: the affine solve, D = 36, R = 32 ================= */
	r_T165H8 = rope_one(rope_ship, 165, 8, 36, 32);
	r_T165H4 = rope_one(rope_ship, 165, 4, 36, 32);
	r_T165H1 = rope_one(rope_ship, 165, 1, 36, 32);
	r_T33H8  = rope_one(rope_ship,  33, 8, 36, 32);
	line("MB_B74 rope_ship_T165_H8_D36_R32=", r_T165H8);     /* the shipped dispatch */
	line("MB_B74 rope_ship_T165_H4_D36_R32=", r_T165H4);
	line("MB_B74 rope_ship_T165_H1_D36_R32=", r_T165H1);
	line("MB_B74 rope_ship_T33_H8_D36_R32=", r_T33H8);

	/* D = R: the pass-through loop does not run at all */
	r_T165H8_D32 = rope_one(rope_ship, 165, 8, 32, 32);
	r_T33H8_D32  = rope_one(rope_ship,  33, 8, 32, 32);
	line("MB_B74 rope_ship_T165_H8_D32_R32=", r_T165H8_D32);
	line("MB_B74 rope_ship_T33_H8_D32_R32=", r_T33H8_D32);

	/* per (t,h) bracket, from the H sweep -- no build term in it */
	perh_D36 = (r_T165H8 - r_T165H1) / (165 * 7);
	perh_D32 = (r_T165H8_D32 - rope_one(rope_ship, 165, 1, 32, 32)) / (165 * 7);
	line("MB_B74 rope_perh_D36_x1=", perh_D36);   /* PAIR*16 + PASS*4 */
	line("MB_B74 rope_perh_D32_x1=", perh_D32);   /* PAIR*16 */
	pass4 = perh_D36 - perh_D32;
	line("MB_B74 rope_pass_x4=", pass4);          /* / 4 = per pass-through element */
	pairR2 = perh_D32;
	line("MB_B74 rope_pair_x16=", pairR2);        /* / 16 = per PAIR (2 elements) */

	/* the build, from the T sweep at fixed H */
	bld = (r_T165H8 - r_T33H8) / 132 - 8 * perh_D36;
	line("MB_B74 rope_build_x16=", bld);          /* / 16 = per E[] entry */

	/* the whole-dispatch account, reconstructed, against the measured one */
	line("MB_B74 rope_recon_T165_H8_D36_R32=",
	     (uint64_t)165 * bld + (uint64_t)165 * 8 * perh_D36);

	/* the pre-B63 control, for the record */
	line("MB_B74 rope_pre_T165_H8_D36_R32=", rope_one(rope_pre, 165, 8, 36, 32));

	/* ---- the B74 arm, and the same affine solve on it ---- */
	{
		uint64_t n_T165H8 = rope_one(rope_b74, 165, 8, 36, 32);
		uint64_t n_T165H1 = rope_one(rope_b74, 165, 1, 36, 32);
		uint64_t n_T33H8  = rope_one(rope_b74,  33, 8, 36, 32);
		uint64_t n_T165H8_32 = rope_one(rope_b74, 165, 8, 32, 32);
		uint64_t n_T165H1_32 = rope_one(rope_b74, 165, 1, 32, 32);
		uint64_t nperh36 = (n_T165H8 - n_T165H1) / (165 * 7);
		uint64_t nperh32 = (n_T165H8_32 - n_T165H1_32) / (165 * 7);

		line("MB_B74 rope_b74_T165_H8_D36_R32=", n_T165H8);
		line("MB_B74 rope_b74_perh_D36_x1=", nperh36);
		line("MB_B74 rope_b74_pair_x16=", nperh32);
		line("MB_B74 rope_b74_pass_x4=", nperh36 - nperh32);
		line("MB_B74 rope_b74_build_x16=",
		     (n_T165H8 - n_T33H8) / 132 - 8 * nperh36);
	}

	/* floors, same shape, same harness */
	fill_rope(165 * 8 * 36);
	a = rd_minstret();
	rope_floor(rin, rout, 165, 8, 36, 32, 40);
	b = rd_minstret();
	line("MB_B74 rope_floor_T165_H8_D36_R32=", b - a - ovh);
	a = rd_minstret();
	rope_copy(rin, rout, 165 * 8 * 36);
	b = rd_minstret();
	line("MB_B74 rope_copy_47520=", b - a - ovh);

	/* ================= add_s8: the affine solve in n ================= */
	i1 = add_one(add_ship, 47520);
	i2 = add_one(add_ship, 23760);
	i3 = add_one(add_ship, 4096);
	line("MB_B74 add_ship_n47520=", i1);           /* the shipped dispatch */
	line("MB_B74 add_ship_n23760=", i2);
	line("MB_B74 add_ship_n4096=", i3);
	line2("MB_B74 add_E_x23760=", i1 - i2, " add_E_x19664=", i2 - i3);
	line("MB_B74 add_fixed=", i2 - (i1 - i2));     /* S = I(n) - E*n at n = 23760 */
	line("MB_B74 add_pre_n47520=", add_one(add_pre, 47520));
	i1 = add_one(add_b74, 47520);
	i2 = add_one(add_b74, 23760);
	line("MB_B74 add_b74_n47520=", i1);
	line("MB_B74 add_b74_n23760=", i2);
	line("MB_B74 add_b74_E_x23760=", i1 - i2);
	line("MB_B74 add_b74_fixed=", i2 - (i1 - i2));
	line("MB_B74 add_b74_n288=", add_one(add_b74, 288));
	line("MB_B74 add_ship_n288=", add_one(add_ship, 288));

	fill_add(47520);
	a = rd_minstret();
	add_floor(ain, bin, aout, 47520, ADD_SA, ADD_SB, ADD_SO);
	b = rd_minstret();
	line("MB_B74 add_floor_n47520=", b - a - ovh);
	a = rd_minstret();
	add_copy(ain, bin, aout, 47520);
	b = rd_minstret();
	line("MB_B74 add_copy_n47520=", b - a - ovh);

	htif_exit(0);
	return 0;
}
