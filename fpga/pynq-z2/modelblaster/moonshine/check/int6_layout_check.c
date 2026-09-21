/* SPDX-License-Identifier: Apache-2.0
 *
 * The HOST half of the int6 weight grid: the driver's planner, the bit order, and the layout,
 * checked against B77's numbers and against the int8 planner it must not have disturbed.
 *
 * WHAT THIS CAN PROVE WITHOUT HARDWARE, and it is the half that is cheapest to get wrong:
 *
 *   1. mbxr_wimage_plan_ex is still exactly mbxr_wimage_plan_bits(.., 8, ..).  Every existing
 *      caller goes through the first; if it moved, every int8 image in the tree moved with it
 *      and no int6 measurement would mean anything.
 *   2. mbxr_pack6 / mbxr_unpack6 round trip on every code in [-31, 31], at every offset in a
 *      row.  The bit order is a CONTRACT with the engine's 48-bit select, so it is checked
 *      here rather than assumed and then debugged on silicon.
 *   3. mbxr_pack6_rowz agrees with mbxr_pack6 on in-range codes, pads with zero past n, and
 *      COUNTS what it clamps.  That count is the only thing that separates "a six-bit guest
 *      was built against an int8 IR" from "the unpacker is broken", and a wrong answer alone
 *      cannot tell them apart.
 *   4. THE LAYOUT IS B77's.  Kp, G, Q, lgpw and the tile count for the decoder's shapes, at 8
 *      and at 6 bits, are asserted against the table B77 measured -- including the two facts
 *      that were counter-intuitive and are the reason this is checked rather than recomputed:
 *      lgpw does NOT shrink (it is 10 at both grids), and what shrinks is the TILE COUNT.
 *   5. K and Kw are different lengths and act on different things.  The activation extent is
 *      derived from K and the row width from Kw; the defect this whole file exists around is
 *      the two being one field.
 *
 * Build:  cc -O2 -I../../../sw/roccmoon -o int6_layout_check int6_layout_check.c ../../../sw/roccmoon/mbxr.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "mbxr.h"

static int fails;
#define CHECK(cond, ...) do { if (!(cond)) { printf("  FAIL: "); printf(__VA_ARGS__); \
                              printf("\n"); fails++; } } while (0)

int main(void)
{
	/* ---- 1. the int8 planner has not moved ------------------------------------------- */
	int moved = 0, planned = 0;
	static const int Ks[] = { 8, 16, 64, 128, 192, 288, 384, 512, 768, 1152, 1536, 2048, 4096 };
	for (unsigned ki = 0; ki < sizeof Ks / sizeof Ks[0]; ki++)
		for (int N = 4; N <= 32768; N *= 2)
			for (int sd = 0; sd < 2; sd++) {
				mbxr_wimage a, b;
				memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
				size_t sa = mbxr_wimage_plan_ex(&a, N, Ks[ki], sd);
				size_t sb = mbxr_wimage_plan_bits(&b, N, Ks[ki], 8, sd);
				if (sa != sb || memcmp(&a, &b, sizeof a) != 0) moved++;
				if (sa) {
					planned++;
					/* at eight bits the two lengths coincide, and G comes from Kw */
					if (a.Kw != a.K || a.wbits != 8 || a.G != a.Kw / 8) moved++;
				}
			}
	CHECK(moved == 0, "the int8 planner moved on %d of %d shapes", moved, planned);
	printf("  int8 planner identical on %d planned shapes\n", planned);

	/* ---- 2. the bit order round trips -------------------------------------------------- */
	int rt = 0;
	for (int K = 32; K <= 2048; K *= 2) {
		int8_t *codes = malloc(K), *back = malloc(K);
		uint8_t *packed = malloc((size_t)K * 6 / 8);
		for (int trial = 0; trial < 64; trial++) {
			for (int k = 0; k < K; k++) codes[k] = (int8_t)((k * 7 + trial * 13) % 63 - 31);
			mbxr_pack6(codes, K, packed);
			mbxr_unpack6(packed, K, back);
			for (int k = 0; k < K; k++) if (back[k] != codes[k]) rt++;
		}
		/* every code value at every offset mod 4 */
		for (int off = 0; off < 4; off++)
			for (int v = -31; v <= 31; v++) {
				memset(codes, 0, K);
				codes[off] = (int8_t)v;
				mbxr_pack6(codes, K, packed);
				mbxr_unpack6(packed, K, back);
				if (back[off] != v) rt++;
			}
		free(codes); free(back); free(packed);
	}
	CHECK(rt == 0, "mbxr_pack6/unpack6 round trip failed %d times", rt);
	printf("  pack6/unpack6 exact over every code in [-31,31] at every offset\n");

	/* ---- 3. the builder's form: padding and the clamp count ---------------------------- */
	{
		const int K = 288, Kp = 288, n = 200;
		int8_t codes[288], ref[288], back[288];
		uint8_t a[216], b[216];
		for (int k = 0; k < K; k++) codes[k] = (int8_t)(k % 63 - 31);
		for (int k = 0; k < n; k++)  ref[k] = codes[k];
		for (int k = n; k < Kp; k++) ref[k] = 0;
		uint64_t clipped = mbxr_pack6_rowz(codes, n, Kp, a);
		mbxr_pack6(ref, Kp, b);
		CHECK(clipped == 0, "in-range row reported %llu clamps", (unsigned long long)clipped);
		CHECK(memcmp(a, b, sizeof a) == 0, "pack6_rowz disagrees with pack6 on an in-range row");
		mbxr_unpack6(a, Kp, back);
		int zbad = 0;
		for (int k = n; k < Kp; k++) if (back[k] != 0) zbad++;
		CHECK(zbad == 0, "pack6_rowz padded %d of %d tail codes with something other than 0",
		      zbad, Kp - n);
		/* an int8 grid handed to a six-bit builder: every out-of-range code counted */
		int8_t hot[288];
		int expect = 0;
		for (int k = 0; k < K; k++) { hot[k] = (int8_t)(k - 144); if (hot[k] > 31 || hot[k] < -31) expect++; }
		clipped = mbxr_pack6_rowz(hot, K, Kp, a);
		CHECK((int)clipped == expect, "clamp count %llu, expected %d",
		      (unsigned long long)clipped, expect);
		printf("  pack6_rowz: zero padding exact, %d of %d out-of-range codes counted\n",
		       expect, K);
	}

	/* ---- 4/5. THE LAYOUT IS B77's ------------------------------------------------------ */
	/* B77 section 6's tile column is PER CHUNK for lm_head, because at eight bits
	 * mbxr_lin_chunk_n splits 32,768 x 288 into two 16,384-wide images (N*Kp = 9.00 MB
	 * exceeds the 8 MB staging limit).  `chunks` below carries that, so the table's 152 and
	 * 114 are reconciled to the driver's whole-tensor 304 and 228 HERE rather than left as a
	 * discrepancy for a board run to find.  At six bits N*Kw is 7,077,888 B and the split
	 * stops -- 228 tiles either way and identical bytes, which is B77 section 11(b). */
	struct { const char *name; int N, K, chunks;
	         int Kw8, G8, Q8, lg8, t8;
	         int Kw6, G6, Q6, lg6, t6; } L[] = {
		/*                             ---- 8 bits ----      ---- 6 bits ----   */
		{ "dec_qkvo",   288,  288, 1,  288, 36, 27, 10,  3,  216, 27, 36, 10,  2 },
		{ "dec_fc1",   1152,  288, 1,  288, 36, 27, 10, 11,  216, 27, 36, 10,  8 },
		{ "dec_fc2",    288, 1152, 1,  1152,144,  7, 10, 11,  864,108,  9, 10,  8 },
		{ "lm_head",  32768,  288, 2,  288, 36, 27, 10,152,  216, 27, 36, 10,114 },
	};
	for (unsigned i = 0; i < sizeof L / sizeof L[0]; i++) {
		mbxr_wimage a, b;
		CHECK(mbxr_wimage_plan_bits(&a, L[i].N, L[i].K, 8, 0) != 0, "%s: 8-bit plan refused", L[i].name);
		CHECK(mbxr_wimage_plan_bits(&b, L[i].N, L[i].K, 6, 0) != 0, "%s: 6-bit plan refused", L[i].name);
		CHECK(a.Kw == L[i].Kw8 && a.G == L[i].G8 && a.Q == L[i].Q8 && a.lgpw == L[i].lg8 &&
		      a.tiles == L[i].t8 * L[i].chunks,
		      "%s @8: Kw %d G %d Q %d lgpw %d tiles %d, B77 says %d %d %d %d %d x %d chunks",
		      L[i].name, a.Kw, a.G, a.Q, a.lgpw, a.tiles, L[i].Kw8, L[i].G8, L[i].Q8, L[i].lg8,
		      L[i].t8, L[i].chunks);
		CHECK(b.Kw == L[i].Kw6 && b.G == L[i].G6 && b.Q == L[i].Q6 && b.lgpw == L[i].lg6 &&
		      b.tiles == L[i].t6 * L[i].chunks,
		      "%s @6: Kw %d G %d Q %d lgpw %d tiles %d, B77 says %d %d %d %d %d x %d chunks",
		      L[i].name, b.Kw, b.G, b.Q, b.lgpw, b.tiles, L[i].Kw6, L[i].G6, L[i].Q6, L[i].lg6,
		      L[i].t6, L[i].chunks);
		/* THE DEFECT THIS FILE EXISTS AROUND: the activation extent is K at BOTH grids */
		CHECK(a.K == L[i].K && b.K == L[i].K,
		      "%s: the activation extent moved with the weight grid (%d, %d), it is %d",
		      L[i].name, a.K, b.K, L[i].K);
		/* lgpw does NOT shrink; the TILE COUNT does (B77 section 7) */
		CHECK(a.lgpw == b.lgpw, "%s: lgpw moved %d -> %d; B77 proved it does not",
		      L[i].name, a.lgpw, b.lgpw);
		CHECK(b.tiles < a.tiles, "%s: the tile count did not shrink (%d -> %d)",
		      L[i].name, a.tiles, b.tiles);
		printf("  %-10s N %5d K %4d | 8: Kw %4d G %3d Q %2d tiles %3d %8zu B | "
		       "6: Kw %4d G %3d Q %2d tiles %3d %8zu B | x%.4f\n",
		       L[i].name, L[i].N, L[i].K, a.Kw, a.G, a.Q, a.tiles, a.bytes,
		       b.Kw, b.G, b.Q, b.tiles, b.bytes, (double)b.bytes / (double)a.bytes);
	}

	/* a packed row must be a whole number of 64-bit words, and a shape that is not is REFUSED
	 * rather than rounded: the scratchpad has no sub-word addressing. */
	{
		mbxr_wimage z;
		/* K * 6 must be a multiple of 64, i.e. K a multiple of 32.  K = 8 is 48 bits and
		 * K = 16 is 96: both are REFUSED rather than rounded up into a row that does not
		 * start on a word.  K = 32 is 192 bits = 3 words and plans. */
		CHECK(mbxr_wimage_plan_bits(&z, 64, 8, 6, 0) == 0, "K=8 at 6 bits (48 bits a row) was not refused");
		CHECK(mbxr_wimage_plan_bits(&z, 64, 16, 6, 0) == 0, "K=16 at 6 bits (96 bits a row) was not refused");
		CHECK(mbxr_wimage_plan_bits(&z, 64, 32, 6, 0) != 0, "K=32 at 6 bits (3 whole words) should plan");
		CHECK(mbxr_wimage_plan_bits(&z, 64, 288, 6, 0) != 0, "K=288 at 6 bits should plan");
		CHECK(mbxr_wimage_plan_bits(&z, 64, 288, 4, 0) == 0, "wbits=4 was not refused");
		CHECK(mbxr_wimage_plan_bits(&z, 64, 288, 7, 0) == 0, "wbits=7 was not refused");
	}

	if (fails) { printf("INT6_LAYOUT_FAIL %d checks\n", fails); return 1; }
	printf("INT6_LAYOUT_OK -- the int8 planner is unmoved, the bit order round trips, and the "
	       "layout is B77's\n");
	return 0;
}
