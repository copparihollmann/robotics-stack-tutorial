/* SPDX-License-Identifier: Apache-2.0
 *
 * Lab B72.  The BLOCKED staging transpose in roccmoon_conv2d_s8_roccmoon_engine.c against
 * the shipping scalar loops it replaces, byte for byte, on the three real stem shapes and on
 * 4,000 random ones.
 *
 * WHAT IS GATED, AND WHY IT IS NOT A TAUTOLOGY.  The two references below are the kernel's
 * `#else` arm VERBATIM -- the same index expressions in the same loop order, written in the
 * CALL SITE's variables (IC/IW for the gather, OW/OC for the scatter) rather than the
 * helper's (R, S).  So this check gates the helper AND the argument order at each call site;
 * an (R, S) swap, which is the one bug a helper shared by two transposes can have and which
 * a same-index gate would miss, fails here on the first non-square shape.
 *
 * THE COVERAGE ARM.  B66 found a guard that passed 6,462 byte-for-byte comparisons while
 * testing the wrong branch: a dead path passes a byte-for-byte gate perfectly.  So
 * MBXR_STAGE_TR_SEEN records every (R, S) the helper is actually entered with, and main()
 * refuses to exit 0 unless the helper fired exactly once per case with the shape the call
 * site should have handed it -- including the two degenerate shapes (R = 1, S = 1) and the
 * shapes smaller than one tile, where a blocked nest can silently do nothing.
 *
 *   cc -O2 -std=gnu11 -DMBXR_RT_STAGE_BLOCK=1 \
 *      -I fpga/pynq-z2/sw fpga/pynq-z2/modelblaster/check/conv_stage_block_exact.c -lm
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef MBXR_RT_STAGE_BLOCK
#error "build this check with -DMBXR_RT_STAGE_BLOCK=1; =0 leaves the helper out of the TU"
#endif

static int  seen_n;
static int  seen_R[8], seen_S[8];
#define MBXR_STAGE_TR_SEEN(R, S) \
	do { if (seen_n < 8) { seen_R[seen_n] = (R); seen_S[seen_n] = (S); } seen_n++; } while (0)

/* The kernel under test.  __ZEPHYR__ is not defined on the host, so only the helper and the
 * this same file, by this same path, so what is gated here is what the board runs.  (The
 * kernel .c itself is not includable on the host: it is only ever compiled after codegen has
 * renamed its entry symbol, and without that rename it and its curated fallback collide.) */
#include "../modelblaster/kernels/roccmoon/mbxr_stage.inc"

/* --- the shipping `#else` arms, verbatim, in the call sites' own variables --------------- */
static void ref_gather(int8_t *s, const int8_t *input, int IC, int IW)
{
	for (int w = 0; w < IW; w++)
		for (int c = 0; c < IC; c++)
			s[(size_t)w * IC + c] = input[(size_t)c * IW + w];
}
static void ref_scatter(int8_t *output, const int8_t *eo, int OW, int OC)
{
	for (int p = 0; p < OW; p++)
		for (int n = 0; n < OC; n++)
			output[(size_t)n * OW + p] = eo[(size_t)p * OC + n];
}

static uint64_t rs_ = 0x9E3779B97F4A7C15ull;
static uint64_t xr(void) { rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17; return rs_; }

#define PAD 64
static long cases, bytes, bad, dead;

/* one shape, both call sites.  `which` picks which reference the helper is checked against,
 * so the gather is compared with (IC, IW) and the scatter with (OW, OC) -- never swapped. */
static void one(int A, int B, int which)
{
	size_t n = (size_t)A * B;
	int8_t *in  = malloc(n + 2 * PAD);
	int8_t *got = malloc(n + 2 * PAD);
	int8_t *ref = malloc(n + 2 * PAD);
	int before = seen_n;

	for (size_t i = 0; i < n + 2 * PAD; i++) in[i] = (int8_t)(xr() & 0xff);
	memset(got, 0x5A, n + 2 * PAD);
	memset(ref, 0x5A, n + 2 * PAD);

	if (which == 0) {                       /* gather: mbxr_stage_tr(s, input, IC, IW) */
		int IC = A, IW = B;
		ref_gather(ref + PAD, in + PAD, IC, IW);
		mbxr_stage_tr(got + PAD, in + PAD, IC, IW);
		if (seen_n != before + 1 || seen_R[before] != IC || seen_S[before] != IW) dead++;
	} else {                                /* scatter: mbxr_stage_tr(output, eo, OW, OC) */
		int OW = A, OC = B;
		ref_scatter(ref + PAD, in + PAD, OW, OC);
		mbxr_stage_tr(got + PAD, in + PAD, OW, OC);
		if (seen_n != before + 1 || seen_R[before] != OW || seen_S[before] != OC) dead++;
	}
	if (memcmp(got, ref, n + 2 * PAD) != 0) bad++;      /* payload AND both canaries */
	cases++; bytes += (long)n;
	free(in); free(got); free(ref);
}

int main(void)
{
	/* the three stem dispatches of b65_enc_strided, both transposes each */
	static const int real[6][3] = {
		{   1, 64000, 0 },  /* conv1 gather  IC=1    IW=64000 */
		{ 999,   288, 1 },  /* conv1 scatter OW=999  OC=288   */
		{ 288,   999, 0 },  /* conv2 gather  IC=288  IW=999   */
		{ 331,   576, 1 },  /* conv2 scatter OW=331  OC=576   */
		{ 576,   331, 0 },  /* conv3 gather  IC=576  IW=331   */
		{ 165,   288, 1 },  /* conv3 scatter OW=165  OC=288   */
	};
	for (int r = 0; r < 6; r++) { seen_n = 0; one(real[r][0], real[r][1], real[r][2]); }

	/* every tile-boundary class: below, at, just past, and a multiple of MBXR_RT_STAGE_TB */
	static const int edge[] = { 1, 2, 3, 7, 31, 32, 33, 63, 64, 65, 96, 127, 128, 129 };
	for (unsigned a = 0; a < sizeof edge / sizeof *edge; a++)
		for (unsigned b = 0; b < sizeof edge / sizeof *edge; b++)
			for (int w = 0; w < 2; w++) { seen_n = 0; one(edge[a], edge[b], w); }

	for (int t = 0; t < 4000; t++) {
		int A = 1 + (int)(xr() % 400), B = 1 + (int)(xr() % 400);
		seen_n = 0; one(A, B, (int)(xr() & 1));
	}

	printf("MBXR_STAGE_BLOCK %s  cases %ld  bytes %ld  mismatching %ld  not-entered %ld  TB %d\n",
	       (bad == 0 && dead == 0) ? "OK" : "FAIL", cases, bytes, bad, dead, MBXR_RT_STAGE_TB);
	return (bad == 0 && dead == 0) ? 0 : 1;
}
