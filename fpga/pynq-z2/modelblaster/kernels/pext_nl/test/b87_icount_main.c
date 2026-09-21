/* SPDX-License-Identifier: Apache-2.0
 *
 * B87 -- WHERE rope_s8's, add_s8's AND groupnorm_s8's CYCLES ACTUALLY GO, and what each
 * term becomes, settled off the board.
 *
 * WHAT IT COUNTS.  `minstret`, retired instructions, read by the guest on either side of
 * each call and corrected for the counter reads, on spike, with the board's own compiler
 * and flags.  Same harness and method as b66/b67/b74/b86_icount_main.c.
 *
 * INSTRUCTIONS ARE NOT CYCLES, AND THE CONVERSION IS MEASURED, NOT ASSUMED.  Each of
 * these three loops has its OWN cycles-per-instruction, taken from the shipped run
 * (out/b86_attn_on2, 0x5A5A0032 at 41.6667 MHz) divided by this program's control count:
 *
 *     rope_s8        16,092,214 / 12 = 1,341,018 cyc  /  1,126,222 instr  =  1.1907
 *     add_s8         12,667,390 / 12 = 1,055,616 cyc  /    817,102 instr  =  1.2919
 *     groupnorm_s8            9,844,709 cyc           /  (this program)
 *
 * B76 priced an instruction removal at a cross-op rate and missed by 32 %; B86 took the
 * midpoint between a cross-op rate and the loop's own CPI and missed by 20.6 %, in the
 * same direction.  The band built on this program uses each loop's own number.
 *
 * THE SPLITS ARE SOLVED, NOT ASSERTED.
 *
 *   rope_s8       I(T,H) = S + T*BLD*R2 + T*H*(PAIR*R2 + PASS*(D-R)).  Sweeping H at
 *                 fixed T brackets (PAIR*R2 + PASS*(D-R)) with no build in it; sweeping T
 *                 at fixed H then gives BLD; D = R against D = R+4 separates PAIR from
 *                 PASS.  (B74's own solve, re-run on today's tree.)
 *   add_s8        I(n) = S + E*n, two points.
 *   groupnorm_s8  I(C,HW) = S + (RED+APP)*C*HW + BLD*C, with RED and APP per element and
 *                 BLD the 256-entry per-channel build.  Sweeping HW at fixed C gives
 *                 (RED+APP)*C; sweeping C at fixed HW then gives BLD.  RED and APP are
 *                 separated by the disassembly, which b87_gate.sh prints from the very
 *                 objects measured here.
 */

#include <stdint.h>
#include <stddef.h>

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

#include "pext.h"
#include "b87_gn_affine.h"

/* ---- the arms under measurement, one object each ---------------------------------- */
void rope_ctl(const int8_t *, const float *, const float *, int8_t *,
	      int, int, int, int, float, float, int, int);
void rope_b87(const int8_t *, const float *, const float *, int8_t *,
	      int, int, int, int, float, float, int, int);
void add_ctl(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void add_b87(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);
void gn_ctl(const int8_t *, const float *, const float *, int8_t *,
	    int, int, int, int, float, float, float, int, int);
void gn_b87(const int8_t *, const float *, const float *, int8_t *,
	    int, int, int, int, float, float, float, int, int);

/* ---- buffers ---------------------------------------------------------------------- */
#define TMAX  200
#define HMAX  8
#define DMAX  40
#define NROPE (TMAX * HMAX * DMAX)
#define NADD  49152
#define NGN   (288 * 2048)

static int8_t rin[NROPE], rout[NROPE];
static float ctab[TMAX * 32], stab[TMAX * 32];
static int8_t ain[NADD], bin[NADD], aout[NADD];
static int8_t gin[NGN] __attribute__((aligned(64)));
static int8_t gout[NGN] __attribute__((aligned(64)));

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

/* ---- Moonshine's own rotary tables: theta = t / 10000^(2i/R) ------------------------ */
/* Harness only, outside every measurement window -- see b74_icount_main.c. */
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

static uint64_t sd = 0x1234567890abcdefull;
static int8_t nxt(void)
{
	sd ^= sd << 13; sd ^= sd >> 7; sd ^= sd << 17;
	return (int8_t)(uint8_t)(sd >> 33);
}

static void fill_rope(int n)
{
	int i;

	sd = 0x1234567890abcdefull;
	for (i = 0; i < n; i++) {
		rin[i] = nxt();
	}
}

static void fill_add(int n)
{
	int i;

	sd = 0x0fedcba987654321ull;
	for (i = 0; i < n; i++) {
		ain[i] = nxt();
		bin[i] = nxt();
	}
}

static void fill_gn(int n)
{
	int i;

	sd = 0x00c0ffeebadf00d1ull;
	for (i = 0; i < n; i++) {
		gin[i] = nxt();
	}
}

/* The encoder's own scale triples, from gen/model.c: layer 0 q (rope), layer 0 self-attn
 * add, and the stem groupnorm. */
#define ROPE_SI 0.0563248396f
#define ROPE_SO 0.0632022619f
#define ADD_SA  0.490539283f
#define ADD_SB  0.504428208f
#define ADD_SO  0.572304666f
#define GN_SI   0.00664364267f
#define GN_SO   0.0466533378f
#define GN_EPS  9.99999975e-06f

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

static uint64_t gn_one(void (*f)(const int8_t *, const float *, const float *, int8_t *,
				 int, int, int, int, float, float, float, int, int),
		       int C, int HW)
{
	uint64_t a, b;

	fill_gn(C * HW);
	a = rd_minstret();
	f(gin, b87_gn_gamma, b87_gn_beta, gout, 1, C, 1, HW, GN_SI, GN_SO, GN_EPS, -128, 127);
	b = rd_minstret();
	return b - a - ovh;
}

int main(void)
{
	uint64_t r_c_165_8, r_c_165_1, r_c_33_8, r_c_165_8_d32, r_c_165_1_d32;
	uint64_t r_b_165_8, r_b_165_1, r_b_33_8, r_b_165_8_d32, r_b_165_1_d32;
	uint64_t a_c_47520, a_c_23760, a_b_47520, a_b_23760;
	uint64_t g_c_288_999, g_c_288_1999, g_c_144_999;
	uint64_t g_b_288_999, g_b_288_1999, g_b_144_999;
	uint64_t ph, bl;

	ovh = probe_overhead();
	line("MB_B87 probe_overhead=", ovh);
	tables(166, 16, 32);

	/* ===================== rope_s8, D = 36, R = 32 ===================== */
	r_c_165_8 = rope_one(rope_ctl, 165, 8, 36, 32);
	r_b_165_8 = rope_one(rope_b87, 165, 8, 36, 32);
	line("MB_B87 rope_ctl_T165_H8_D36_R32=", r_c_165_8);   /* the shipped dispatch */
	line("MB_B87 rope_b87_T165_H8_D36_R32=", r_b_165_8);

	r_c_165_1 = rope_one(rope_ctl, 165, 1, 36, 32);
	r_b_165_1 = rope_one(rope_b87, 165, 1, 36, 32);
	r_c_33_8 = rope_one(rope_ctl, 33, 8, 36, 32);
	r_b_33_8 = rope_one(rope_b87, 33, 8, 36, 32);
	r_c_165_8_d32 = rope_one(rope_ctl, 165, 8, 32, 32);
	r_b_165_8_d32 = rope_one(rope_b87, 165, 8, 32, 32);
	r_c_165_1_d32 = rope_one(rope_ctl, 165, 1, 32, 32);
	r_b_165_1_d32 = rope_one(rope_b87, 165, 1, 32, 32);

	ph = (r_c_165_8 - r_c_165_1) / (165 * 7);
	line("MB_B87 rope_ctl_perh_D36_x1=", ph);
	bl = (r_c_165_8 - r_c_33_8 - (uint64_t)(165 - 33) * 8 * ph) / (165 - 33);
	line("MB_B87 rope_ctl_build_x16=", bl);
	line("MB_B87 rope_ctl_pair_x16=", (r_c_165_8_d32 - r_c_165_1_d32) / (165 * 7));
	line("MB_B87 rope_ctl_pass_x4=", ph - (r_c_165_8_d32 - r_c_165_1_d32) / (165 * 7));

	ph = (r_b_165_8 - r_b_165_1) / (165 * 7);
	line("MB_B87 rope_b87_perh_D36_x1=", ph);
	bl = (r_b_165_8 - r_b_33_8 - (uint64_t)(165 - 33) * 8 * ph) / (165 - 33);
	line("MB_B87 rope_b87_build_x16=", bl);
	line("MB_B87 rope_b87_pair_x16=", (r_b_165_8_d32 - r_b_165_1_d32) / (165 * 7));
	line("MB_B87 rope_b87_pass_x4=", ph - (r_b_165_8_d32 - r_b_165_1_d32) / (165 * 7));

	/* ============ THE DECODER'S OWN SHAPES -- T = 1, n = 288 ============
	 * B87 was banded and measured on the ENCODER.  Both add_s8 and rope_s8 are
	 * dispatched by the decoder too, at shapes an order of magnitude smaller, and a
	 * fast path's profitability is a function of the quantity it amortises over.
	 * rope_s8's B87 pass-through TABLE is 256 entries; the decoder's dispatch has
	 * T*H*(D-R) = 1*8*4 = 32 pass-through elements to amortise it over. */
	line("MB_B87 rope_ctl_T1_H8_D36_R32=", rope_one(rope_ctl, 1, 8, 36, 32));
	line("MB_B87 rope_b87_T1_H8_D36_R32=", rope_one(rope_b87, 1, 8, 36, 32));
	line("MB_B87 rope_ctl_T1_H8_D32_R32=", rope_one(rope_ctl, 1, 8, 32, 32));
	line("MB_B87 rope_b87_T1_H8_D32_R32=", rope_one(rope_b87, 1, 8, 32, 32));

	/* ===================== add_s8, n = 47,520 ========================== */
	a_c_47520 = add_one(add_ctl, 47520);
	a_b_47520 = add_one(add_b87, 47520);
	a_c_23760 = add_one(add_ctl, 23760);
	a_b_23760 = add_one(add_b87, 23760);
	line("MB_B87 add_ctl_n47520=", a_c_47520);
	line("MB_B87 add_b87_n47520=", a_b_47520);
	line("MB_B87 add_ctl_E_x23760=", a_c_47520 - a_c_23760);
	line("MB_B87 add_b87_E_x23760=", a_b_47520 - a_b_23760);
	line("MB_B87 add_ctl_n288=", add_one(add_ctl, 288));
	line("MB_B87 add_b87_n288=", add_one(add_b87, 288));

	/* ================ groupnorm_s8, C = 288, HW = 999 ================== */
	g_c_288_999 = gn_one(gn_ctl, 288, 999);
	g_b_288_999 = gn_one(gn_b87, 288, 999);
	line("MB_B87 gn_ctl_C288_HW999=", g_c_288_999);        /* the shipped dispatch */
	line("MB_B87 gn_b87_C288_HW999=", g_b_288_999);

	g_c_288_1999 = gn_one(gn_ctl, 288, 1999);
	g_b_288_1999 = gn_one(gn_b87, 288, 1999);
	g_c_144_999 = gn_one(gn_ctl, 144, 999);
	g_b_144_999 = gn_one(gn_b87, 144, 999);
	line("MB_B87 gn_ctl_C288_HW1999=", g_c_288_1999);
	line("MB_B87 gn_b87_C288_HW1999=", g_b_288_1999);
	line("MB_B87 gn_ctl_C144_HW999=", g_c_144_999);
	line("MB_B87 gn_b87_C144_HW999=", g_b_144_999);

	/* (RED + APP) per element, from the HW sweep at fixed C: no build term in it. */
	line("MB_B87 gn_ctl_elem_x288=", (g_c_288_1999 - g_c_288_999) / 1000);
	line("MB_B87 gn_b87_elem_x288=", (g_b_288_1999 - g_b_288_999) / 1000);
	/* the per-channel build, from the C sweep with that term subtracted */
	line("MB_B87 gn_ctl_build_x144=",
	     g_c_288_999 - g_c_144_999 - 144 * 999 * ((g_c_288_1999 - g_c_288_999) / 1000) / 288);
	line("MB_B87 gn_b87_build_x144=",
	     g_b_288_999 - g_b_144_999 - 144 * 999 * ((g_b_288_1999 - g_b_288_999) / 1000) / 288);

	htif_exit(0);
	return 0;
}
