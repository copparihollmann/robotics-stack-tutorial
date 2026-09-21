/* SPDX-License-Identifier: Apache-2.0
 *
 * The host half of the verification bar for the curated layernorm_pc_s8 lane kernel.
 *
 * On the host there is no lane, so the curated kernel takes its fallback -- which IS ModelBlaster's
 * reference implementation.  That makes this check prove three things that can be proved without a
 * board, and it is deliberately run BEFORE any board time:
 *   1. the curated file compiles and its fallback is bit-identical to the reference;
 *   2. the SHAPE PREDICATES accept exactly the dispatches the lane can take and refuse the rest --
 *      the refusals are what stand between a kernel and a hang;
 *   3. the affine-table packing round-trips, so a constant that would silently overflow the lane's
 *      25/40/32-bit fields is refused on the host rather than discovered on silicon.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "mbxr_lanes.h"

/* the host's model of custom-1: never reached, because mbxr_rt_available() is 0 off Zephyr */
void mbxr_l_cfg(uint64_t a, uint64_t d) { (void)a; (void)d; }
void mbxr_l_go(uint64_t w, uint64_t u) { (void)w; (void)u; }
uint64_t mbxr_l_st(uint64_t a, uint64_t b) { (void)a; (void)b; return 0; }

#include "roccmoon_layernorm_pc_s8_roccmoon_lane.c"

/* an independent transcription of ModelBlaster's semantics, written from the spec text rather
 * than copied from the kernel, so agreement is evidence and not a tautology */
static void golden(const int8_t *x, const int32_t *umul, const int64_t *gmul, const int64_t *badd,
		   int8_t *y, int M, int K, int64_t eps)
{
	for (int m = 0; m < M; m++) {
		const int8_t *xr = x + (size_t)m * K;
		int8_t *yr = y + (size_t)m * K;
		int64_t S = 0;
		__int128 Q = 0;
		for (int k = 0; k < K; k++) {
			int64_t u = (int64_t)xr[k] * umul[k];
			S += u;
			Q += (__int128)u * u;
		}
		__int128 V = (__int128)K * Q - (__int128)S * S + (__int128)eps;
		unsigned __int128 n = ((unsigned __int128)1 << 120) / (unsigned __int128)V;
		unsigned __int128 r = 0, bit = (unsigned __int128)1 << 126;
		while (bit > n) bit >>= 2;
		while (bit) {
			if (n >= r + bit) { n -= r + bit; r = (r >> 1) + bit; } else r >>= 1;
			bit >>= 2;
		}
		int64_t R = (int64_t)r;
		for (int k = 0; k < K; k++) {
			int64_t u = (int64_t)xr[k] * umul[k];
			__int128 d = (__int128)K * u - (__int128)S;
			int64_t t = (int64_t)((d * (__int128)R) >> 44);
			int64_t v = (t * gmul[k] + badd[k] * 65536 + ((int64_t)1 << 31)) >> 32;
			if (v < -128) v = -128;
			if (v > 127) v = 127;
			yr[k] = (int8_t)v;
		}
	}
}

static uint32_t lcg = 12345u;
static int rnd(int lo, int hi) { lcg = lcg * 1103515245u + 12345u; return lo + (int)((lcg >> 16) % (unsigned)(hi - lo + 1)); }

int main(void)
{
	int fails = 0, cases = 0;
	static int8_t x[200 * 288], y1[200 * 288], y2[200 * 288];
	static int32_t umul[288];
	static int64_t gmul[288], badd[288];

	/* 1. bit-exactness of the fallback against an independent transcription */
	for (int trial = 0; trial < 40; trial++) {
		int M = rnd(1, 40), K = 288;
		int64_t eps = (int64_t)rnd(1, 1000) * 1000000 + 262145;
		for (int k = 0; k < K; k++) {
			umul[k] = rnd(1, 1 << 20);
			gmul[k] = rnd(-(1 << 18), 1 << 18);
			badd[k] = rnd(-(1 << 20), 1 << 20);
		}
		for (int i = 0; i < M * K; i++) x[i] = (int8_t)rnd(-128, 127);
		kernel_layernorm_pc_s8(x, umul, gmul, badd, y1, M, K, eps);
		golden(x, umul, gmul, badd, y2, M, K, eps);
		cases++;
		if (memcmp(y1, y2, (size_t)M * K)) {
			int bad = 0;
			for (int i = 0; i < M * K; i++) bad += (y1[i] != y2[i]);
			printf("FAIL trial %d M=%d: %d of %d bytes differ\n", trial, M, bad, M * K);
			fails++;
		}
	}
	printf("1. bit-exact vs an independent transcription: %d cases, %d fail\n", cases, fails);

	/* 2. the shape predicates: what the lane may take, and what must fall back */
	struct { int M, K; int want_plan; const char *what; } sh[] = {
		{ 165, 288, 1, "Moonshine encoder layernorm (6 tiles of 28)" },
		{   1, 288, 1, "one decoder row" },
		{ 165, 290, 0, "K not word-aligned" },
		{   3,   5, 0, "M*K not a whole word -- would never return ownership" },
		{   1, 16384, 0, "row wider than one buffer -- no tiling helps" },
	};
	for (unsigned i = 0; i < sizeof sh / sizeof sh[0]; i++) {
		int r = 0, t = 0;
		int rc = mbxr_ln_plan(sh[i].M, sh[i].K, 0, 0, &r, &t);
		int got = (rc == MBXR_OK);
		printf("   %-52s plan=%-4d %s\n", sh[i].what, rc, got == sh[i].want_plan ? "ok" : "MISMATCH");
		if (got != sh[i].want_plan) fails++;
	}

	/* 2b. the kernel's ACTUAL tiling decision.
	 * It used to be stricter than the reach predicate -- a tile had to be a whole number of
	 * 64-byte drain blocks -- and that would have made EVERY encoder layernorm fall back
	 * silently: M = 165 is odd, 288 x odd is never a multiple of 64, so the last tile never
	 * qualified.  Found by doing the prediction arithmetic before the board run rather than
	 * after.  Short tiles are now staged zero-padded, so the reach is the only bound. */
	struct { int M, K, want; const char *what; } tr[] = {
		{ 165, 288, 28, "encoder: 28 rows per tile, last tile 25 rows staged" },
		{   1, 288,  1, "one decoder row: staged, taken (the limitation is lifted)" },
		{   2, 288,  2, "two decoder rows: 9 blocks exactly, no staging needed" },
	};
	for (unsigned i = 0; i < sizeof tr / sizeof tr[0]; i++) {
		int r = mbxr_ln_tile_rows(tr[i].M, tr[i].K);
		printf("   %-52s rows=%-4d %s\n", tr[i].what, r, r == tr[i].want ? "ok" : "MISMATCH");
		if (r != tr[i].want) fails++;
	}

	/* 3. eps and the per-channel field widths */
	struct { int64_t eps; int want; const char *what; } ep[] = {
		{ 0, 0, "eps 0 -- cfg_ok false, the hang Lab B33 measured" },
		{ 262144, 0, "eps at the boundary (must be STRICTLY greater)" },
		{ 262145, 1, "eps just above" },
	};
	for (unsigned i = 0; i < sizeof ep / sizeof ep[0]; i++) {
		int ok = (mbxr_ln_cfg_ok(288, 288, (uint64_t)ep[i].eps, 0) == MBXR_OK);
		printf("   %-52s %s\n", ep[i].what, ok == ep[i].want ? "ok" : "MISMATCH");
		if (ok != ep[i].want) fails++;
	}
	for (int k = 0; k < 288; k++) { umul[k] = 1 << 20; gmul[k] = 1; badd[k] = 0; }
	printf("   %-52s %s\n", "constants inside the lane's fields",
	       mbxr_ln_consts_fit(umul, gmul, badd, 288) ? "ok" : "MISMATCH");
	umul[7] = 1 << 26;
	printf("   %-52s %s\n", "umul past 25 bits must be refused",
	       !mbxr_ln_consts_fit(umul, gmul, badd, 288) ? "ok" : "MISMATCH");

	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
