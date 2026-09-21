/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B76's pre-board gate for pext_nl_permute4_s8_pext_block.c -- host only, no board.
 *
 * A PERMUTE HAS NO ARITHMETIC TO HIDE BEHIND, which cuts both ways.  There is no rounding
 * to argue about -- the treatment must place every byte where the shipping kernel places
 * it, so the comparison is exact by definition -- but it also means the only poison that
 * can work is a flipped bit in a written byte, and that a route which never fires passes a
 * byte-for-byte gate perfectly.  Hence five poisoned arms, one per new route.
 *
 * WHAT IS BEING CHECKED:
 *   - the 8-byte and 4-byte run copies, whose whole justification is an ALIGNMENT claim
 *     computed once per call from the two bases, three strides and the run length.  The
 *     sweep below therefore runs every shape at every offset of input and output within
 *     an 8-byte window, so a wrong alignment rule is a mis-copy and not a silent trap;
 *   - the rewritten byte run copy;
 *   - pblk_tblock, the o2/o3 loop interchange taken when os[2] == 1;
 *   - pblk_stride, the general gather with od[3]/os[3] hoisted out of the element loop.
 *
 * Arms, one source, one define apart:
 *   a  -DMBP_B76=1   the treatment
 *   b  default       the shipping kernel
 * Poisons: 1 the 8-byte copy, 2 the 4-byte copy, 3 the byte copy, 4 pblk_tblock,
 *          5 pblk_stride.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void perm_a(const int8_t *, int8_t *, int, int, int, int, int, int, int, int,
	    float, float, int, int);
void perm_b(const int8_t *, int8_t *, int, int, int, int, int, int, int, int,
	    float, float, int, int);

#include "b76_perm_cases.h"

static uint64_t rs_ = 0x13198A2E03707344ull;
static uint64_t rnd(void)
{
	rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17;
	return rs_;
}

static long fails, cases, bytes, runs_mode, stride_mode, requant_mode;

/* 64-byte aligned, exactly as gen/buffers.c declares every ModelBlaster intermediate, with
 * room to slide both pointers through a whole alignment window on top. */
static int8_t in_[1 << 20] __attribute__((aligned(64)));
static int8_t oa_[1 << 20] __attribute__((aligned(64)));
static int8_t ob_[1 << 20] __attribute__((aligned(64)));

static void cmp(const char *what, int d0, int d1, int d2, int d3,
		int p0, int p1, int p2, int p3, float si, float so,
		int amin, int amax, int ioff, int ooff)
{
	const size_t n = (size_t)d0 * d1 * d2 * d3;
	const int8_t *in = in_ + ioff;
	int8_t *oa = oa_ + ooff, *ob = ob_ + ooff;
	size_t i;

	if (n == 0 || n + 64 > sizeof(in_))
		return;
	for (i = 0; i < n; i++)
		in_[ioff + i] = (int8_t)(uint8_t)(rnd() & 0xff);
	memset(oa_, 0x5a, n + (size_t)ooff + 8);
	memset(ob_, 0xa5, n + (size_t)ooff + 8);
	perm_a(in, oa, d0, d1, d2, d3, p0, p1, p2, p3, si, so, amin, amax);
	perm_b(in, ob, d0, d1, d2, d3, p0, p1, p2, p3, si, so, amin, amax);
	cases++;
	bytes += (long)n;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i]) {
			if (fails < 10)
				printf("MISMATCH %s i=%zu b76=%d ship=%d  d=(%d,%d,%d,%d) "
				       "p=(%d,%d,%d,%d) si=%.9g so=%.9g ioff=%d ooff=%d\n",
				       what, i, oa[i], ob[i], d0, d1, d2, d3,
				       p0, p1, p2, p3, (double)si, (double)so, ioff, ooff);
			fails++;
			break;
		}
	}
	/* The byte AFTER the output must be untouched: a width-4 or width-8 store that
	 * over-runs the run would otherwise be invisible to the comparison above. */
	if (oa[n] != (int8_t)0x5a) {
		if (fails < 10)
			printf("OVERRUN %s wrote past %zu bytes  d=(%d,%d,%d,%d)\n",
			       what, n, d0, d1, d2, d3);
		fails++;
	}
}

int main(void)
{
	const int ncase = (int)(sizeof(mb_perm_cases) / sizeof(mb_perm_cases[0]));
	int c, io, oo, t;

	/* 1. EVERY SHIPPING SHAPE, at its own scales, with both pointers slid through a full
	 *    8-byte alignment window.  The alignment rule is the treatment's only premise, so
	 *    it is the thing swept: 64 (input offset, output offset) combinations per shape. */
	for (c = 0; c < ncase; c++)
		for (io = 0; io < 8; io++)
			for (oo = 0; oo < 8; oo++) {
				cmp("ship", mb_perm_cases[c].d0, mb_perm_cases[c].d1,
				    mb_perm_cases[c].d2, mb_perm_cases[c].d3,
				    mb_perm_cases[c].p0, mb_perm_cases[c].p1,
				    mb_perm_cases[c].p2, mb_perm_cases[c].p3,
				    mb_perm_cases[c].si, mb_perm_cases[c].so,
				    mb_perm_cases[c].amin, mb_perm_cases[c].amax, io, oo);
				if (mb_perm_cases[c].p3 == 3)
					runs_mode++;
				else
					stride_mode++;
			}

	/* 2. ALL 24 PERMUTATIONS at shapes chosen so every one of the three modes is reached
	 *    and so run lengths land on, just below and just above the 4- and 8-byte
	 *    boundaries -- which is where a tail loop is either exercised or skipped. */
	{
		static const int dims[][4] = {
			{ 1, 2, 3, 36 }, { 1, 3, 5, 8 }, { 2, 3, 4, 5 }, { 1, 1, 1, 1 },
			{ 1, 8, 7, 165 }, { 3, 2, 5, 7 }, { 1, 4, 9, 4 }, { 1, 2, 2, 3 },
			{ 1, 6, 6, 9 }, { 1, 165, 8, 36 }, { 2, 2, 2, 64 }, { 1, 1, 33, 31 },
		};
		static const int perms[][4] = {
			{0,1,2,3},{0,1,3,2},{0,2,1,3},{0,2,3,1},{0,3,1,2},{0,3,2,1},
			{1,0,2,3},{1,0,3,2},{1,2,0,3},{1,2,3,0},{1,3,0,2},{1,3,2,0},
			{2,0,1,3},{2,0,3,1},{2,1,0,3},{2,1,3,0},{2,3,0,1},{2,3,1,0},
			{3,0,1,2},{3,0,2,1},{3,1,0,2},{3,1,2,0},{3,2,0,1},{3,2,1,0},
		};
		int d, p;

		for (d = 0; d < (int)(sizeof(dims) / sizeof(dims[0])); d++)
			for (p = 0; p < 24; p++)
				for (io = 0; io < 8; io++) {
					cmp("allperm", dims[d][0], dims[d][1], dims[d][2],
					    dims[d][3], perms[p][0], perms[p][1],
					    perms[p][2], perms[p][3], 0.03f, 0.03f,
					    -128, 127, io, (io * 3) & 7);
				}
	}

	/* 3. THE REQUANTISING MODE, which B76 does not touch and therefore must not move.
	 *    scale_in != scale_out routes every shape to PBLK_REQUANT in both arms. */
	{
		static const int dims[][4] = {
			{ 1, 2, 8, 36 }, { 1, 165, 8, 36 }, { 2, 3, 4, 5 }, { 1, 1, 1, 7 },
		};
		int d;

		for (d = 0; d < (int)(sizeof(dims) / sizeof(dims[0])); d++)
			for (t = 0; t < 8; t++) {
				const float si = 0.03f, so = 0.03f * (1.0f + 0.1f * (float)(t + 1));

				cmp("requant", dims[d][0], dims[d][1], dims[d][2], dims[d][3],
				    0, 2, 1, 3, si, so, -128, 127, t, 7 - t);
				requant_mode++;
			}
	}

	/* 4. Degenerate and near-degenerate extents: the early return, and single-element
	 *    axes that collapse a loop to one trip. */
	{
		static const int dims[][4] = {
			{ 0, 2, 3, 4 }, { 1, 0, 3, 4 }, { 1, 2, 0, 4 }, { 1, 2, 3, 0 },
			{ 1, 1, 1, 1 }, { 1, 1, 1, 8 }, { 1, 8, 1, 1 }, { 1, 1, 8, 1 },
		};
		int d;

		for (d = 0; d < (int)(sizeof(dims) / sizeof(dims[0])); d++)
			for (io = 0; io < 8; io++)
				cmp("degenerate", dims[d][0], dims[d][1], dims[d][2],
				    dims[d][3], 0, 2, 1, 3, 0.03f, 0.03f, -128, 127, io, io);
	}

	/* 5. Random shapes and random permutations, offsets included. */
	for (t = 0; t < 3000; t++) {
		const int d0 = 1 + (int)(rnd() % 4u), d1 = 1 + (int)(rnd() % 20u);
		const int d2 = 1 + (int)(rnd() % 20u), d3 = 1 + (int)(rnd() % 70u);
		int pp[4] = { 0, 1, 2, 3 };
		int i;

		for (i = 3; i > 0; i--) {
			int j = (int)(rnd() % (unsigned)(i + 1));
			int tmp = pp[i]; pp[i] = pp[j]; pp[j] = tmp;
		}
		cmp("rand", d0, d1, d2, d3, pp[0], pp[1], pp[2], pp[3], 0.03f, 0.03f,
		    -128, 127, (int)(rnd() & 7u), (int)(rnd() & 7u));
	}

	printf("b76 permute gate: cases=%ld (runs-shaped %ld, stride-shaped %ld, requant %ld) "
	       "bytes_compared=%ld max_abs_err=%d fails=%ld  %s\n",
	       cases, runs_mode, stride_mode, requant_mode, bytes,
	       fails ? -1 : 0, fails, fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
