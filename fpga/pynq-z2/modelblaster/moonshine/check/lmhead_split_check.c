/* SPDX-License-Identifier: Apache-2.0
 *
 * The host half of the bar for splitting a wide linear_s8 by N (ROCC_DECOUPLED.md 8.15.28).
 *
 * On the host there is no engine, so the curated kernel takes its fallback and the split path is
 * not executed.  What CAN be proved without hardware is the property the split rests on, and it is
 * the property that matters: **N chunks concatenated equal the whole**.  If that holds for the
 * reference expression, then a split dispatch is the same arithmetic as an unsplit one and the
 * only remaining question is whether the engine agrees -- which is the board's job.
 *
 * It also checks the chunk arithmetic itself, because an off-by-one there is a silent fallback
 * rather than a wrong answer: a chunk one quad too wide is refused by the staging guard and the
 * whole dispatch quietly goes back to software, which is exactly the failure this fix exists to
 * remove.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define MBXR_NCH 4
#define MBXR_LIN_STAGE_LIMIT (8UL << 20)
static int mbxr_lin_chunk_n(int N, int Kp)
{
	long need = (long)N * Kp;
	int chunks, nc;
	if (need <= (long)MBXR_LIN_STAGE_LIMIT) return N;
	chunks = (int)((need + (long)MBXR_LIN_STAGE_LIMIT - 1) / (long)MBXR_LIN_STAGE_LIMIT);
	nc = (N + chunks - 1) / chunks;
	nc = (nc + MBXR_NCH - 1) & ~(MBXR_NCH - 1);
	if ((long)nc * Kp > (long)MBXR_LIN_STAGE_LIMIT) nc -= MBXR_NCH;
	return nc > 0 ? nc : 0;
}

/* the reference expression, as kernel_linear_s8 defines it */
static int32_t rq(int32_t acc, int32_t mult, int shift, int amin, int amax)
{
	int64_t t = (int64_t)acc * (int64_t)mult;
	int64_t r = (t + ((int64_t)1 << 30)) >> 31;
	if (shift > 0) r <<= shift;
	else if (shift < 0) { int s = -shift; r = (r + ((int64_t)1 << (s - 1))) >> s; }
	if (r < amin) r = amin;
	if (r > amax) r = amax;
	return (int32_t)r;
}
static void lin(const int8_t *in, const int8_t *w, const int32_t *bias, int8_t *out,
		int M, int K, int N, int mult, int shift, int amin, int amax)
{
	for (int m = 0; m < M; m++)
		for (int n = 0; n < N; n++) {
			int32_t acc = bias[n];
			for (int k = 0; k < K; k++)
				acc += (int32_t)in[(size_t)m * K + k] * (int32_t)w[(size_t)n * K + k];
			out[(size_t)m * N + n] = (int8_t)rq(acc, mult, shift, amin, amax);
		}
}

static uint32_t lcg = 987654321u;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 16) % (unsigned)(hi - lo + 1)); }

int main(void)
{
	int fails = 0;

	/* 1. the chunk arithmetic, including the case the guard refuses by 12.5 % */
	struct { int N, Kp, want_split; const char *what; } cs[] = {
		{   288, 288, 0, "qkvo: 0.08 MB, whole" },
		{  1152, 288, 0, "fc1 half: 0.32 MB, whole" },
		{  2304, 288, 0, "fc1: 0.63 MB, whole" },
		{ 32768, 288, 1, "lm_head: 9.00 MB -- over the guard by 12.5 %" },
	};
	for (unsigned i = 0; i < sizeof cs / sizeof cs[0]; i++) {
		int nc = mbxr_lin_chunk_n(cs[i].N, cs[i].Kp);
		int split = (nc > 0 && nc < cs[i].N);
		long each = (long)nc * cs[i].Kp;
		int chunks = split ? (cs[i].N + nc - 1) / nc : 1;
		printf("  N=%-6d %-44s chunks=%-2d of %-6d (%.2f MB each) %s\n",
		       cs[i].N, cs[i].what, chunks, nc, each / 1048576.0,
		       split == cs[i].want_split ? "ok" : "MISMATCH");
		if (split != cs[i].want_split) fails++;
		if (split && each > (long)MBXR_LIN_STAGE_LIMIT) {
			printf("  FAIL: a chunk is still over the staging guard\n"); fails++;
		}
		if (split && (long)chunks * nc < cs[i].N) {
			printf("  FAIL: the chunks do not cover N\n"); fails++;
		}
	}

	/* 2. THE PROPERTY THE SPLIT RESTS ON: chunks concatenated == whole, at M = 1 */
	{
		const int K = 288, N = 1024;          /* small enough to brute force, same shape class */
		static int8_t in[288], w[1024 * 288], whole[1024], part[1024];
		static int32_t bias[1024];
		for (int i = 0; i < K; i++) in[i] = (int8_t)rnd(-128, 127);
		for (int i = 0; i < N * K; i++) w[i] = (int8_t)rnd(-128, 127);
		for (int i = 0; i < N; i++) bias[i] = rnd(-4000, 4000);
		const int mult = 1518500250, shift = -9;
		lin(in, w, bias, whole, 1, K, N, mult, shift, -128, 127);
		for (int nc = 4; nc <= N; nc *= 2) {
			memset(part, 0x5A, sizeof part);
			for (int n0 = 0; n0 < N; n0 += nc) {
				int nn = N - n0 < nc ? N - n0 : nc;
				lin(in, w + (size_t)n0 * K, bias + n0, part + n0, 1, K, nn,
				    mult, shift, -128, 127);
			}
			int bad = 0;
			for (int i = 0; i < N; i++) bad += (part[i] != whole[i]);
			if (bad) { printf("  FAIL: %d of %d bytes differ at chunk width %d\n", bad, N, nc); fails++; }
		}
		printf("  chunks concatenated == whole, at every chunk width 4..%d: %s\n",
		       N, fails ? "NO" : "yes");
		/* and an uneven split, since 32,768 / 16,384 is even but N need not be */
		const int nc = 300;
		memset(part, 0x5A, sizeof part);
		for (int n0 = 0; n0 < N; n0 += nc) {
			int nn = N - n0 < nc ? N - n0 : nc;
			lin(in, w + (size_t)n0 * K, bias + n0, part + n0, 1, K, nn, mult, shift, -128, 127);
		}
		int bad = 0;
		for (int i = 0; i < N; i++) bad += (part[i] != whole[i]);
		printf("  an uneven split (300, last chunk 124): %s\n", bad ? "DIFFERS" : "exact");
		if (bad) fails++;
	}

	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
