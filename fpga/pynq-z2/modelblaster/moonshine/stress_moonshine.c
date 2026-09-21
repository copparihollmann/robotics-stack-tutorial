/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Moonshine's curated pext_nl kernels against ModelBlaster's reference, on the host.
 * Driven by check_moonshine.py, which compiles it twice:
 *
 *   full  -O2, level 1: every enumeration at full size
 *   san   -O1 -fsanitize=address,undefined, level 0: the same tests, reduced counts,
 *         plus misaligned buffers (the MBP DOT8 path loads 8 bytes at a time)
 *
 * The reference kernels are ModelBlaster's KernelSpec.reference_impl VERBATIM, renamed
 * ref_kernel_<op> on the command line; the candidates are the curated files concatenated
 * the way generate_kernels concatenates them into kernels.c.  MB_PEXT_HW=0: pext.h's
 * software model of MBP, the normative definition of the instructions.
 *
 * Every test prints one line:
 *   RESULT test=<name> cases=<n> mismatches=<n> max_abs_err=<n> [slow=<n>]
 * and "model" tests print one line per dispatch of the model-data cases file.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "fexact32.h"

#define DECL_PAIR(ret, name, args) ret ref_kernel_##name args; ret kernel_##name args;
DECL_PAIR(void, tanh_s8, (const int8_t *, int8_t *, int, float, float, int, int))
DECL_PAIR(void, gelu_s8, (const int8_t *, int8_t *, int, float, float, int, int))
DECL_PAIR(void, add_s8, (const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int))
DECL_PAIR(void, mul_s8, (const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int))
DECL_PAIR(void, groupnorm_s8, (const int8_t *, const float *, const float *, int8_t *, int, int, int,
			       int, float, float, float, int, int))
DECL_PAIR(void, layernorm_s8, (const int8_t *, const float *, const float *, int8_t *, int, int,
			       float, float, float, int, int))
DECL_PAIR(void, rope_s8, (const int8_t *, const float *, const float *, int8_t *, int, int, int, int,
			  float, float, int, int))
DECL_PAIR(void, matmul_b_s8, (const int8_t *, const int8_t *, int8_t *, int, int, int, int, float,
			      float, float, int, float, int, int))
DECL_PAIR(void, softmax_s8, (const int8_t *, int8_t *, int, int, float, float))

#ifdef FX_STATS
extern unsigned long pint_add_slow_count, pint_add_count, pint_mul_slow_count, pint_mul_count;
extern unsigned long pint_rope_slow_count, pint_rope_count, pint_mmb_slow_count, pint_mmb_count;
#endif

static int LEVEL = 1;
static uint64_t rs = 0x243F6A8885A308D3ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static double urand(void) { return (double)(rnd() >> 11) / 9007199254740992.0; }
static float lscale(double lo, double hi) { return (float)exp(lo + (hi - lo) * urand()); }

/* A buffer at a chosen offset from an 8-aligned address, so misalignment is exercised. */
static void *abuf(size_t n, int off, void **base)
{
	*base = aligned_alloc(64, ((n + 64 + 63) / 64) * 64);
	return (char *)*base + off;
}

struct res { const char *name; unsigned long cases, mism; long maxe; };
static void res_add(struct res *r, const int8_t *x, const int8_t *y, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		if (x[i] != y[i]) {
			long e = labs((long)x[i] - (long)y[i]);
			r->mism++;
			if (e > r->maxe) r->maxe = e;
		}
	}
	r->cases += n;
}
static void res_print(struct res *r, const char *extra)
{
	printf("RESULT test=%s cases=%lu mismatches=%lu max_abs_err=%ld%s\n", r->name, r->cases,
	       r->mism, r->maxe, extra ? extra : "");
	fflush(stdout);
}

/* ------------------------------------------------------------------------------------ */
static int fx_same(fx32_t v, float f)
{
	fx32_t d = fx32_dec(f);
	uint64_t m = v.m;
	int32_t e = v.e;

	if (d.m == 0 && m == 0) return 1;
	while (m && m < (1u << 23)) { m <<= 1; e--; }
	return m == d.m && e == d.e && v.neg == d.neg;
}
static float rfloat(int lo, int hi)
{
	uint32_t b = (uint32_t)(rnd() & 0x7fffff) | ((uint32_t)(lo + 127 + (int)(rnd() % (uint64_t)(hi - lo))) << 23)
		     | (uint32_t)((rnd() & 1) << 31);
	float f;
	memcpy(&f, &b, 4);
	return f;
}
static void test_fexact(void)
{
	struct res r = { "fexact32_vs_fpu", 0, 0, 0 };
	long N = LEVEL ? 20000000 : 200000;

	for (long i = 0; i < N; i++) {
		float a = rfloat(-40, 30), b = rfloat(-40, 30);
		int8_t k = (int8_t)rnd();
		float nc = a * (1.0f + ldexpf(1.0f, -23 + (int)(rnd() % 3)));
		float q = rfloat(-30, 8), h = (float)((int)(rnd() % 400) - 200) + 0.5f;
		r.cases += 7;
		r.mism += !fx_same(fx32_mul(fx32_dec(a), fx32_dec(b)), a * b);
		r.mism += !fx_same(fx32_add(fx32_dec(a), fx32_dec(b)), a + b);
		r.mism += !fx_same(fx32_add(fx32_dec(a), fx32_neg(fx32_dec(nc))), a - nc);
		r.mism += !fx_same(fx32_div(fx32_dec(a), fx32_dec(b)), a / b);
		r.mism += !fx_same(fx32_mul(fx32_int(k), fx32_dec(a)), (float)k * a);
		r.mism += (long)roundf(q) != (long)fx32_roundf_i32(fx32_dec(q));
		r.mism += (long)roundf(h) != (long)fx32_roundf_i32(fx32_dec(h));
	}
	r.maxe = r.mism ? 1 : 0;
	res_print(&r, NULL);
}

/* ------------------------------------------------------------------------------------ */
static void test_tanh(void)
{
	struct res r = { "tanh_s8_memo_lut", 0, 0, 0 };
	int T = LEVEL ? 20000 : 300;
	int8_t in[1024], o1[1024], o2[1024];

	for (int t = 0; t < T; t++) {
		float si = lscale(-9, 1), so = (t % 3) ? 1.0f / 127.0f * (float)(0.5 + urand()) : lscale(-9, 0);
		int amin = (t % 7 == 0) ? -100 : -128, amax = (t % 11 == 0) ? 90 : 127;
		int n = (t % 5 == 0) ? (int)(rnd() % 32) : 256 + (int)(rnd() % 700);

		for (int i = 0; i < n; i++) in[i] = (int8_t)(i < 256 ? i : rnd());
		ref_kernel_tanh_s8(in, o1, n, si, so, amin, amax);
		kernel_tanh_s8(in, o2, n, si, so, amin, amax);
		res_add(&r, o1, o2, (size_t)n);
	}
	res_print(&r, NULL);
}

/* ------------------------------------------------------------------------------------ */
typedef void (*elt_fn)(const int8_t *, const int8_t *, int8_t *, int, float, float, float, int, int);

/* Mismatches where the REFERENCE is undefined -- its roundf result is outside int32, so
 * `(int32_t)roundf(...)` is UB (x86 returns INT_MIN, i.e. a clamp to activation_min;
 * this kernel saturates) -- are counted apart from the defined domain. */
static unsigned long elt_undefined;

static void elt_triple(struct res *r, elt_fn ref, elt_fn cand, float sa, float sb, float so,
		       int amin, int amax, int off, int is_mul)
{
	void *ba, *bb, *b1, *b2;
	int8_t *A = abuf(65536, off, &ba), *B = abuf(65536, (off * 3) & 7, &bb);
	int8_t *O1 = abuf(65536, 0, &b1), *O2 = abuf(65536, (off * 5) & 7, &b2);

	for (int i = 0; i < 65536; i++) { A[i] = (int8_t)(i & 255); B[i] = (int8_t)(i >> 8); }
	ref(A, B, O1, 65536, sa, sb, so, amin, amax);
	cand(A, B, O2, 65536, sa, sb, so, amin, amax);
	for (int i = 0; i < 65536; i++) {
		if (O1[i] != O2[i]) {
			float fa = (float)A[i] * sa, fb = (float)B[i] * sb;
			float fo = (is_mul ? fa * fb : fa + fb) / so;

			if (!(fabsf(roundf(fo)) < 2147483648.0f)) {
				elt_undefined++;
				O2[i] = O1[i];              /* not a defined-domain mismatch */
			}
		}
	}
	res_add(r, O1, O2, 65536);
	free(ba); free(bb); free(b1); free(b2);
}

static void test_elt(const char *name, elt_fn ref, elt_fn cand, int is_mul)
{
	struct res r = { name, 0, 0, 0 };
	int T = LEVEL ? 3000 : 40;
	char extra[200] = "";

	elt_undefined = 0;
	for (int t = 0; t < T; t++) {
		float sa = lscale(-10, 0), sb = lscale(-10, 0), so;
		int amin = (t % 9 == 4) ? 0 : -128, amax = 127;

		switch (t % 5) {
		case 0: /* independent, often saturating */
			so = lscale(-10, 0); break;
		case 1: /* calibrated-like */
			so = is_mul ? sa * sb * 127.0f * (float)(0.3 + urand()) : (sa + sb) * (float)(0.5 + urand());
			break;
		case 2: /* exact half-integer ties everywhere */
			so = sa; sb = is_mul ? 1.0f / 128.0f : sa * 0.5f; break;
		case 3: /* equal scales */
			sb = sa; so = is_mul ? sa * sa * 64.0f : sa; break;
		default: /* extreme ratios */
			so = lscale(-20, 5); break;
		}
		elt_triple(&r, ref, cand, sa, sb, so, amin, amax, t & 7, is_mul);
	}
#ifdef FX_STATS
	if (is_mul)
		snprintf(extra, sizeof extra, " reference_undefined=%lu slow=%lu/%lu", elt_undefined,
			 pint_mul_slow_count, pint_mul_count);
	else
		snprintf(extra, sizeof extra, " reference_undefined=%lu slow=%lu/%lu", elt_undefined,
			 pint_add_slow_count, pint_add_count);
#else
	snprintf(extra, sizeof extra, " reference_undefined=%lu", elt_undefined);
#endif
	res_print(&r, extra);
}

/* ------------------------------------------------------------------------------------ */
/* rope: every (a0, a1) pair against one (cos, sin) entry, via T=1, H=65536, D=4, R=2. */
static void rope_entry(struct res *r, float c, float s, float si, float so, int amin, int amax)
{
	static int8_t in[65536 * 4], o1[65536 * 4], o2[65536 * 4];

	for (int i = 0; i < 65536; i++) {
		in[4 * i] = (int8_t)(i & 255);
		in[4 * i + 1] = (int8_t)(i >> 8);
		in[4 * i + 2] = (int8_t)(i & 255);
		in[4 * i + 3] = (int8_t)(i >> 8);
	}
	ref_kernel_rope_s8(in, &c, &s, o1, 1, 65536, 4, 2, si, so, amin, amax);
	kernel_rope_s8(in, &c, &s, o2, 1, 65536, 4, 2, si, so, amin, amax);
	res_add(r, o1, o2, sizeof o1);
}

static void test_rope(void)
{
	struct res r = { "rope_s8_random", 0, 0, 0 };
	char extra[160] = "";
	int T = LEVEL ? 3000 : 30;

	for (int t = 0; t < T; t++) {
		double ang = urand() * 6.283185307179586 * (t % 4 ? 1.0 : 50.0);
		float c = (float)cos(ang), s = (float)sin(ang);
		float si = lscale(-8, 1), so = (t % 3) ? si * (float)(0.5 + urand()) : lscale(-9, 1);

		if (t % 17 == 0) { c = 1.0f; s = 0.0f; }
		if (t % 19 == 0) { c = (float)M_SQRT1_2; s = (float)M_SQRT1_2; so = si; }
		rope_entry(&r, c, s, si, so, (t % 13 == 3) ? -100 : -128, 127);
	}
	/* the real layout, random data: indexing, the pass-through dims, R < D */
	{
		const int TT = 165, H = 8, D = 36, R = 32;
		static int8_t in[165 * 8 * 36], o1[165 * 8 * 36], o2[165 * 8 * 36];
		static float ct[165 * 16], st[165 * 16];

		for (int k = 0; k < (LEVEL ? 50 : 3); k++) {
			float si = lscale(-6, 0), so = si * (float)(0.6 + 0.8 * urand());

			for (int t = 0; t < TT; t++)
				for (int i = 0; i < R / 2; i++) {
					double a = t * pow(10000.0, -(2.0 * i) / R);
					ct[t * 16 + i] = (float)cos(a);
					st[t * 16 + i] = (float)sin(a);
				}
			for (size_t i = 0; i < sizeof in; i++) in[i] = (int8_t)rnd();
			ref_kernel_rope_s8(in, ct, st, o1, TT, H, D, R, si, so, -128, 127);
			kernel_rope_s8(in, ct, st, o2, TT, H, D, R, si, so, -128, 127);
			res_add(&r, o1, o2, sizeof in);
		}
	}
#ifdef FX_STATS
	snprintf(extra, sizeof extra, " slow=%lu/%lu", pint_rope_slow_count, pint_rope_count);
#endif
	res_print(&r, extra);
}

/* ------------------------------------------------------------------------------------ */
/* matmul_b requantise: EVERY accumulator value in [-lim, lim], through one A row
 * [127 x (K-2), 1, 0] and B rows that encode the value in base 127. */
static void mmb_acc_sweep(struct res *r, int K, long lim, float sa, float sb, float so, float sd)
{
	enum { CH = 4096 };
	static int8_t A[256], B[CH * 256], O1[CH], O2[CH];
	long v = -lim;

	for (int k = 0; k < K - 2; k++) A[k] = 127;
	A[K - 2] = 1;
	A[K - 1] = 0;
	while (v <= lim) {
		int n = 0;

		for (; n < CH && v <= lim; n++, v++) {
			long a = labs(v), sg = v < 0 ? -1 : 1;
			int8_t *row = B + (size_t)n * K;

			memset(row, 0, (size_t)K);
			for (int k = 0; k < K - 2 && a >= 127; k++) {
				long q = a / 127 > 127 ? 127 : a / 127;
				row[k] = (int8_t)(sg * q);
				a -= q * 127;
			}
			row[K - 2] = (int8_t)(sg * a);
		}
		ref_kernel_matmul_b_s8(A, B, O1, 1, 1, K, n, sa, sb, so, 1, sd, -128, 127);
		kernel_matmul_b_s8(A, B, O2, 1, 1, K, n, sa, sb, so, 1, sd, -128, 127);
		res_add(r, O1, O2, (size_t)n);
	}
}

static void test_matmul_b(void)
{
	struct res r = { "matmul_b_s8_random", 0, 0, 0 };
	char extra[160] = "";
	const long lim = 166L * 127 * 127;          /* K = 168: 2,677,414, above any K <= 165 acc */
	int T = LEVEL ? 24 : 3;

	for (int t = 0; t < T; t++) {
		float sa = lscale(-6, 0), sb = lscale(-6, 0);
		float sd = (t % 2) ? 6.0f : 1.0f;
		float so = sa * sb * (float)(20.0 + 400.0 * urand()) / sd;

		if (t % 7 == 3) so = sa * sb / 128.0f;          /* exact ties */
		mmb_acc_sweep(&r, LEVEL ? 168 : 16, LEVEL ? lim : 3000, sa, sb, so, sd);
	}
	/* shapes: model-like and awkward, both transpose settings, misaligned operands */
	{
		static const int shapes[][4] = {
			{ 8, 165, 36, 165 }, { 8, 165, 165, 36 }, { 2, 7, 1, 9 }, { 3, 5, 7, 11 },
			{ 1, 33, 64, 17 }, { 1, 4, 9, 40000 },     /* N*W beyond the scratch: scalar */
		};
		for (size_t s = 0; s < sizeof shapes / sizeof shapes[0]; s++) {
			for (int tb = 0; tb < 2; tb++) {
				const int B = shapes[s][0], M = shapes[s][1], K = shapes[s][2], N = shapes[s][3];
				size_t na = (size_t)B * M * K, nb = (size_t)B * K * N, no = (size_t)B * M * N;
				void *p1, *p2, *p3, *p4;
				int8_t *a = abuf(na, (int)(s + tb) & 7, &p1), *b = abuf(nb, 3, &p2);
				int8_t *o1 = abuf(no, 0, &p3), *o2 = abuf(no, 5, &p4);
				float sa = lscale(-5, -1), sb = lscale(-5, -1);
				float so = sa * sb * (float)(K * 10), sd = tb ? 6.0f : 1.0f;

				if (!LEVEL && no > 200000) { free(p1); free(p2); free(p3); free(p4); continue; }
				for (size_t i = 0; i < na; i++) a[i] = (int8_t)rnd();
				for (size_t i = 0; i < nb; i++) b[i] = (int8_t)rnd();
				ref_kernel_matmul_b_s8(a, b, o1, B, M, K, N, sa, sb, so, tb, sd, -128, 127);
				kernel_matmul_b_s8(a, b, o2, B, M, K, N, sa, sb, so, tb, sd, -128, 127);
				res_add(&r, o1, o2, no);
				free(p1); free(p2); free(p3); free(p4);
			}
		}
	}
#ifdef FX_STATS
	snprintf(extra, sizeof extra, " slow=%lu/%lu", pint_mmb_slow_count, pint_mmb_count);
#endif
	res_print(&r, extra);
}

/* ------------------------------------------------------------------------------------ */
static void test_groupnorm(void)
{
	struct res r = { "groupnorm_s8_random", 0, 0, 0 };
	static const int shapes[][4] = { { 1, 288, 1, 999 }, { 2, 16, 3, 7 }, { 1, 1, 1, 1 }, { 1, 4, 1, 64 } };

	for (size_t s = 0; s < sizeof shapes / sizeof shapes[0]; s++) {
		for (int t = 0; t < (LEVEL ? 20 : 2); t++) {
			const int N = shapes[s][0], C = shapes[s][1], H = shapes[s][2], W = shapes[s][3];
			size_t n = (size_t)N * C * H * W;
			int8_t *in = malloc(n), *o1 = malloc(n), *o2 = malloc(n);
			float *g = malloc(sizeof(float) * C), *b = malloc(sizeof(float) * C);
			int spread = 1 + (int)(rnd() % 128);

			for (size_t i = 0; i < n; i++) in[i] = (int8_t)((long)(rnd() % (uint64_t)(2 * spread + 1)) - spread);
			for (int c = 0; c < C; c++) { g[c] = (float)(urand() * 2.0); b[c] = (float)(urand() - 0.5); }
			ref_kernel_groupnorm_s8(in, g, b, o1, N, C, H, W, 0.01f, 0.05f, 1e-5f, -128, 127);
			kernel_groupnorm_s8(in, g, b, o2, N, C, H, W, 0.01f, 0.05f, 1e-5f, -128, 127);
			res_add(&r, o1, o2, n);
			free(in); free(o1); free(o2); free(g); free(b);
		}
	}
	res_print(&r, " class=numeric_drift");
}

/* ------------------------------------------------------------------------------------ */
/* Model-data cases, written by check_moonshine.py: every dispatch of the kinds below with
 * its GOLDEN input tensors and its own quantisation parameters. */
static double *rd_params(FILE *f, int *np)
{
	double *p;

	if (fread(np, 4, 1, f) != 1) return NULL;
	p = malloc(sizeof(double) * (size_t)(*np ? *np : 1));
	if (fread(p, sizeof(double), (size_t)*np, f) != (size_t)*np) { free(p); return NULL; }
	return p;
}
static void *rd_array(FILE *f, int64_t *len)
{
	int32_t code;
	void *d;
	size_t esz;

	if (fread(&code, 4, 1, f) != 1 || fread(len, 8, 1, f) != 1) return NULL;
	esz = code == 1 ? 1 : 4;
	d = malloc((size_t)*len * esz + 8);
	if (fread(d, esz, (size_t)*len, f) != (size_t)*len) { free(d); return NULL; }
	return d;
}

static void test_model(const char *path, int only_exact_counts)
{
	FILE *f = fopen(path, "rb");
	char name[256];
	int32_t kind, nname;

	(void)only_exact_counts;
	if (!f) { printf("RESULT test=model_cases missing=%s\n", path); return; }
	while (fread(&kind, 4, 1, f) == 1) {
		int np;
		int64_t l0 = 0, l1 = 0, l2 = 0;
		double *p;
		void *x0 = NULL, *x1 = NULL, *x2 = NULL;
		int8_t *o1, *o2;
		size_t n = 0;
		struct res r = { name, 0, 0, 0 };

		if (fread(&nname, 4, 1, f) != 1 || nname >= 255) break;
		if (fread(name, 1, (size_t)nname, f) != (size_t)nname) break;
		name[nname] = 0;
		p = rd_params(f, &np);
		x0 = rd_array(f, &l0);
		if (kind == 2 || kind == 3 || kind == 4 || kind == 5 || kind == 7) x1 = rd_array(f, &l1);
		if (kind == 2 || kind == 3 || kind == 7) x2 = rd_array(f, &l2);
		switch (kind) {
		case 1: n = (size_t)p[0]; break;
		case 2: n = (size_t)(p[0] * p[1] * p[2] * p[3]); break;
		case 3: n = (size_t)(p[0] * p[1] * p[2]); break;
		case 4: n = (size_t)p[0]; break;
		case 5: n = (size_t)(p[0] * p[1] * p[3]); break;
		case 6: n = (size_t)p[0]; break;
		case 7: n = (size_t)(p[0] * p[1]); break;
		case 8: n = (size_t)(p[0] * p[1]); break;
		}
		o1 = malloc(n + 8);
		o2 = malloc(n + 8);
		switch (kind) {
		case 1:
			ref_kernel_tanh_s8(x0, o1, (int)n, (float)p[1], (float)p[2], (int)p[3], (int)p[4]);
			kernel_tanh_s8(x0, o2, (int)n, (float)p[1], (float)p[2], (int)p[3], (int)p[4]);
			break;
		case 2:
			ref_kernel_groupnorm_s8(x0, x1, x2, o1, (int)p[0], (int)p[1], (int)p[2], (int)p[3],
						(float)p[4], (float)p[5], (float)p[6], (int)p[7], (int)p[8]);
			kernel_groupnorm_s8(x0, x1, x2, o2, (int)p[0], (int)p[1], (int)p[2], (int)p[3],
					    (float)p[4], (float)p[5], (float)p[6], (int)p[7], (int)p[8]);
			break;
		case 3:
			ref_kernel_rope_s8(x0, x1, x2, o1, (int)p[0], (int)p[1], (int)p[2], (int)p[3],
					   (float)p[4], (float)p[5], (int)p[6], (int)p[7]);
			kernel_rope_s8(x0, x1, x2, o2, (int)p[0], (int)p[1], (int)p[2], (int)p[3],
				       (float)p[4], (float)p[5], (int)p[6], (int)p[7]);
			break;
		case 4:
			ref_kernel_add_s8(x0, x1, o1, (int)n, (float)p[1], (float)p[2], (float)p[3], (int)p[4], (int)p[5]);
			kernel_add_s8(x0, x1, o2, (int)n, (float)p[1], (float)p[2], (float)p[3], (int)p[4], (int)p[5]);
			break;
		case 5:
			ref_kernel_matmul_b_s8(x0, x1, o1, (int)p[0], (int)p[1], (int)p[2], (int)p[3], (float)p[4],
					       (float)p[5], (float)p[6], (int)p[7], (float)p[8], (int)p[9], (int)p[10]);
			kernel_matmul_b_s8(x0, x1, o2, (int)p[0], (int)p[1], (int)p[2], (int)p[3], (float)p[4],
					   (float)p[5], (float)p[6], (int)p[7], (float)p[8], (int)p[9], (int)p[10]);
			break;
		case 6:
			ref_kernel_gelu_s8(x0, o1, (int)n, (float)p[1], (float)p[2], (int)p[3], (int)p[4]);
			kernel_gelu_s8(x0, o2, (int)n, (float)p[1], (float)p[2], (int)p[3], (int)p[4]);
			break;
		case 7:
			ref_kernel_layernorm_s8(x0, x1, x2, o1, (int)p[0], (int)p[1], (float)p[2], (float)p[3],
						(float)p[4], (int)p[5], (int)p[6]);
			kernel_layernorm_s8(x0, x1, x2, o2, (int)p[0], (int)p[1], (float)p[2], (float)p[3],
					    (float)p[4], (int)p[5], (int)p[6]);
			break;
		case 8:
			ref_kernel_softmax_s8(x0, o1, (int)p[0], (int)p[1], (float)p[2], (float)p[3]);
			kernel_softmax_s8(x0, o2, (int)p[0], (int)p[1], (float)p[2], (float)p[3]);
			break;
		}
		res_add(&r, o1, o2, n);
		printf("MODEL dispatch=%s kind=%d elements=%zu mismatches=%lu max_abs_err=%ld\n", name, kind, n,
		       r.mism, r.maxe);
		free(p); free(x0); free(x1); free(x2); free(o1); free(o2);
	}
	fclose(f);
	fflush(stdout);
}

int main(int argc, char **argv)
{
	LEVEL = argc > 1 ? atoi(argv[1]) : 1;
	if (argc > 3 && !strcmp(argv[2], "model")) {
		test_model(argv[3], 0);
		return 0;
	}
	test_fexact();
	test_tanh();
	test_elt("add_s8_random", ref_kernel_add_s8, kernel_add_s8, 0);
	test_elt("mul_s8_random", ref_kernel_mul_s8, kernel_mul_s8, 1);
	test_rope();
	test_matmul_b();
	test_groupnorm();
	return 0;
}
