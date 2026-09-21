/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Stress the curated pext_nl kernels of patches/0103 against their references, on inputs a
 * model does not produce: full-range and rail codes, extreme multipliers, constant samples,
 * padding, both paths of every kernel that has two.  q16_gates.py writes q16_ref.c (each
 * KernelSpec's reference, renamed ref_*) and builds this with the curated sources renamed
 * cur_*.  A mismatch prints the case and exits non-zero.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DECL_ADD(p, T) void p##add(const T *a, const int8_t *b, const int64_t *am, const int64_t *bm, int8_t *o, int n, int C);
void ref_kernel_add_pc_s8(const int8_t *, const int8_t *, const int64_t *, const int64_t *, int8_t *, int, int);
void cur_kernel_add_pc_s8(const int8_t *, const int8_t *, const int64_t *, const int64_t *, int8_t *, int, int);
void ref_kernel_add_s16_pc_s8(const int16_t *, const int8_t *, const int64_t *, const int64_t *, int8_t *, int, int);
void cur_kernel_add_s16_pc_s8(const int16_t *, const int8_t *, const int64_t *, const int64_t *, int8_t *, int, int);
void ref_kernel_mrcombine_s16(const int8_t *const *, const int32_t *, const int32_t *, const int32_t *,
                              const int32_t *, int16_t *, int, int, int, int, int);
void cur_kernel_mrcombine_s16(const int8_t *const *, const int32_t *, const int32_t *, const int32_t *,
                              const int32_t *, int16_t *, int, int, int, int, int);
void ref_kernel_groupnorm_s16(const int16_t *, const int64_t *, const int64_t *, int16_t *, int, int, int, int64_t);
void cur_kernel_groupnorm_s16(const int16_t *, const int64_t *, const int64_t *, int16_t *, int, int, int, int64_t);
void ref_kernel_conv2d_s16_pc(const int16_t *, const int8_t *, const int64_t *, const int32_t *, const int32_t *,
                              int16_t *, int, int, int, int, int, int, int, int, int, int, int, int, int);
void cur_kernel_conv2d_s16_pc(const int16_t *, const int8_t *, const int64_t *, const int32_t *, const int32_t *,
                              int16_t *, int, int, int, int, int, int, int, int, int, int, int, int, int);

static uint64_t rs = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int64_t rr(int64_t lo, int64_t hi) { return lo + (int64_t)(rnd() % (uint64_t)(hi - lo + 1)); }
static int8_t r8(void) { int k = (int)(rnd() % 8); return k == 0 ? -128 : k == 1 ? 127 : (int8_t)rr(-128, 127); }
static int16_t r16(int narrow)
{
	int k = (int)(rnd() % 10);
	if (k == 0) return -32768;
	if (k == 1) return 32767;
	return narrow ? (int16_t)rr(-narrow, narrow) : (int16_t)rr(-32768, 32767);
}

static unsigned long cases, bad;
#define CHECK(name, eq) do { cases++; if (!(eq)) { bad++; if (bad < 20) fprintf(stderr, "MISMATCH %s case %lu\n", name, cases); } } while (0)

static void t_add(int iters)
{
	for (int it = 0; it < iters; it++) {
		int C = (int)rr(1, 300), n = (int)rr(1, 5000);
		int8_t *a8 = malloc(n), *b = malloc(n), *o1 = malloc(n), *o2 = malloc(n);
		int16_t *a16 = malloc(2 * (size_t)n);
		int64_t *am = malloc(8 * (size_t)C), *bm = malloc(8 * (size_t)C);
		int shift_bits = (int)rr(0, 40);
		for (int i = 0; i < n; i++) { a8[i] = r8(); b[i] = r8(); a16[i] = r16(0); }
		for (int c = 0; c < C; c++) { am[c] = rr(0, (int64_t)1 << shift_bits); bm[c] = rr(0, (int64_t)1 << shift_bits); }
		ref_kernel_add_pc_s8(a8, b, am, bm, o1, n, C);
		cur_kernel_add_pc_s8(a8, b, am, bm, o2, n, C);
		CHECK("add_pc_s8", !memcmp(o1, o2, n));
		ref_kernel_add_s16_pc_s8(a16, b, am, bm, o1, n, C);
		cur_kernel_add_s16_pc_s8(a16, b, am, bm, o2, n, C);
		CHECK("add_s16_pc_s8", !memcmp(o1, o2, n));
		free(a8); free(b); free(o1); free(o2); free(a16); free(am); free(bm);
	}
}

static void t_mrc(int iters)
{
	for (int it = 0; it < iters; it++) {
		int N = (int)rr(1, 2), G = (int)rr(1, 4), R = (int)rr(1, 4), HW = (int)rr(1, 200);
		int32_t goc[4], ratios[4];
		int OC = 0;
		for (int g = 0; g < G; g++) { goc[g] = (int32_t)rr(1, 40); OC += goc[g]; }
		ratios[0] = 1;
		for (int k = 1; k < R; k++) ratios[k] = ratios[k - 1] * (int32_t)(1 << rr(1, 8));
		int32_t *gidx = malloc(4 * (size_t)OC), *lidx = malloc(4 * (size_t)OC);
		/* a random permutation of (g, j) over the output channels */
		int c = 0;
		for (int g = 0; g < G; g++) for (int j = 0; j < goc[g]; j++, c++) { gidx[c] = g; lidx[c] = j; }
		for (int i = OC - 1; i > 0; i--) { int j = (int)rr(0, i); int32_t t = gidx[i]; gidx[i] = gidx[j]; gidx[j] = t; t = lidx[i]; lidx[i] = lidx[j]; lidx[j] = t; }
		const int8_t *ins[32];
		int8_t *bufs[32];
		for (int g = 0; g < G; g++) for (int k = 0; k < R; k++) for (int p = 0; p < 2; p++) {
			int idx = (g * R + k) * 2 + p;
			size_t sz = (size_t)N * goc[g] * HW;
			bufs[idx] = malloc(sz);
			for (size_t i = 0; i < sz; i++) bufs[idx][i] = r8();
			ins[idx] = bufs[idx];
		}
		int16_t *o1 = malloc(2 * (size_t)N * OC * HW), *o2 = malloc(2 * (size_t)N * OC * HW);
		ref_kernel_mrcombine_s16(ins, gidx, lidx, goc, ratios, o1, N, OC, HW, G, R);
		cur_kernel_mrcombine_s16(ins, gidx, lidx, goc, ratios, o2, N, OC, HW, G, R);
		CHECK("mrcombine_s16", !memcmp(o1, o2, 2 * (size_t)N * OC * HW));
		for (int i = 0; i < 2 * G * R; i++) free(bufs[i]);
		free(o1); free(o2); free(gidx); free(lidx);
	}
}

static void t_gn(int iters)
{
	for (int it = 0; it < iters; it++) {
		int N = (int)rr(1, 3), C = (int)rr(1, 64), HW = (int)rr(1, 400);
		size_t K = (size_t)C * HW;
		int mode = (int)rr(0, 3);
		int16_t *x = malloc(2 * N * K), *o1 = malloc(2 * N * K), *o2 = malloc(2 * N * K);
		int64_t *g = malloc(8 * (size_t)C), *b = malloc(8 * (size_t)C);
		int16_t cst = r16(0);
		for (size_t i = 0; i < N * K; i++)
			x[i] = mode == 0 ? r16(0) : mode == 1 ? r16(300) : mode == 2 ? cst : (int16_t)rr(-3, 3);
		int gb = (int)rr(10, 34);
		for (int c = 0; c < C; c++) { g[c] = rr(-((int64_t)1 << gb), (int64_t)1 << gb); b[c] = rr(-((int64_t)1 << 30), (int64_t)1 << 30); }
		int64_t eps = rr(1, (int64_t)1 << rr(0, 50));
		ref_kernel_groupnorm_s16(x, g, b, o1, N, C, HW, eps);
		cur_kernel_groupnorm_s16(x, g, b, o2, N, C, HW, eps);
		CHECK("groupnorm_s16", !memcmp(o1, o2, 2 * N * K));
		free(x); free(o1); free(o2); free(g); free(b);
	}
}

static void t_conv(int iters)
{
	for (int it = 0; it < iters; it++) {
		int N = (int)rr(1, 2), IC = (int)rr(1, 20), IH = (int)rr(1, 12), IW = (int)rr(1, 40);
		int KH = (int)rr(1, 4), KW = (int)rr(1, 9), SH = (int)rr(1, 3), SW = (int)rr(1, 4);
		int PH = (int)rr(0, KH - 1), PW = (int)rr(0, KW - 1);
		if (rnd() % 20 == 0) { IC = (int)rr(900, 1100); IH = 1; KH = 1; KW = (int)rr(7, 9); IW = 30; }  /* > MBP_C16_PWORDS words: fallback */
		if (IH + 2 * PH < KH || IW + 2 * PW < KW) continue;
		int OH = (IH + 2 * PH - KH) / SH + 1, OW = (IW + 2 * PW - KW) / SW + 1, OC = (int)rr(1, 24);
		size_t K = (size_t)IC * KH * KW;
		int16_t *x = malloc(2 * (size_t)N * IC * IH * IW);
		int8_t *w = malloc(OC * K);
		int64_t *bias = malloc(8 * (size_t)OC);
		int32_t *mult = malloc(4 * (size_t)OC), *shift = malloc(4 * (size_t)OC);
		int16_t *o1 = malloc(2 * (size_t)N * OC * OH * OW), *o2 = malloc(2 * (size_t)N * OC * OH * OW);
		int narrow = (int)(rnd() % 2) ? 0 : 100;
		for (size_t i = 0; i < (size_t)N * IC * IH * IW; i++) x[i] = r16(narrow);
		for (size_t i = 0; i < OC * K; i++) w[i] = (int8_t)rr(-127, 127);
		for (int c = 0; c < OC; c++) {
			bias[c] = rr(-((int64_t)1 << 40), (int64_t)1 << 40);
			mult[c] = (int32_t)rr((int64_t)1 << 30, ((int64_t)1 << 31) - 1);
			shift[c] = (int32_t)rr(-20, 30);
		}
		ref_kernel_conv2d_s16_pc(x, w, bias, mult, shift, o1, N, IC, IH, IW, OC, OH, OW, KH, KW, SH, SW, PH, PW);
		cur_kernel_conv2d_s16_pc(x, w, bias, mult, shift, o2, N, IC, IH, IW, OC, OH, OW, KH, KW, SH, SW, PH, PW);
		CHECK("conv2d_s16_pc", !memcmp(o1, o2, 2 * (size_t)N * OC * OH * OW));
		free(x); free(w); free(bias); free(mult); free(shift); free(o1); free(o2);
	}
}

int main(int argc, char **argv)
{
	int scale = argc > 1 ? atoi(argv[1]) : 1;
	unsigned long c0;
	c0 = cases; t_add(2000 * scale); printf("add_pc_s8 + add_s16_pc_s8   %lu cases\n", cases - c0);
	c0 = cases; t_mrc(2000 * scale); printf("mrcombine_s16               %lu cases\n", cases - c0);
	c0 = cases; t_gn(1000 * scale);  printf("groupnorm_s16               %lu cases\n", cases - c0);
	c0 = cases; t_conv(500 * scale); printf("conv2d_s16_pc               %lu cases\n", cases - c0);
	printf("RESULT cases=%lu mismatches=%lu\n", cases, bad);
	return bad != 0;
}
