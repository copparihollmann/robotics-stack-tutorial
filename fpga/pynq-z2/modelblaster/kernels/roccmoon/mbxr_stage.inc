/* ------------------------------------------------------------------------------------
 * THE TWO STAGING TRANSPOSES, BLOCKED.  Lab B72.
 *
 * Both copies in this kernel are the same map: out[j*R + i] = in[i*S + j].  The gather is
 * (out = s, in = input, R = IC, S = IW); the scatter is (out = output, in = eo, R = OW,
 * S = OC).  Written as a plain double loop -- which is what the arm below `#else` is, the
 * shipping code verbatim -- one side of the inner loop strides by R or S, so on hart 0's
 * 16 KB L1D EVERY byte on that side takes its own 64-byte line and the line is dead before
 * its other 63 bytes are ever asked for.  Measured on `b65_enc_strided`: 25.4 cycles/byte on
 * the gather, 38.5 on the scatter, against 5 and 9 retired instructions per byte.
 *
 * TB x TB blocking fixes exactly that and nothing else: within a tile the read side is a
 * contiguous run of TB bytes and the TB write lines are reused by all TB rows, so a line is
 * fetched once and all of its bytes in the tile are used.  64 lines live (TB source + TB
 * destination) against the L1D's 256.
 *
 * The nest is LIFTED from reference_kernels.py's `gemmini_blocked_tb32` for
 * nchw_to_nhwc_s8, which is itself lifted from the input-transpose phase of
 * kernels/gemmini/gemmini_conv2d_s8_gemmini_tiled_conv.c.  Code motion, not new tuning; that
 * kernel's own comment records that removing the blocking cost its conv0 46 %.
 *
 * A transpose is a bijection and this nest visits every (i, j) exactly once, so the staged
 * bytes are the same bytes in the same places: the arithmetic downstream is untouched and
 * `max_abs_err` 0 is a real check of this change rather than a tautology.  Gated
 * byte-for-byte on the host by check/conv_stage_block_exact.c.
 *
 * Default OFF.  Turning it on is `-DMBXR_RT_STAGE_BLOCK=1`, which is the only difference
 * between the two arms of the A/B.
 * ------------------------------------------------------------------------------------ */
#ifndef MBXR_RT_STAGE_BLOCK
#define MBXR_RT_STAGE_BLOCK 0
#endif

#include "roccmoon/mbxr_b102.h"
#ifndef MBXR_RT_STAGE_TB
#define MBXR_RT_STAGE_TB 32
#endif

#if MBXR_RT_STAGE_BLOCK
#ifndef MBXR_STAGE_TR_SEEN            /* the coverage counter; the host check defines it */
#define MBXR_STAGE_TR_SEEN(R, S) ((void)0)
#endif
/* out[j*R + i] = in[i*S + j]   for i in [0, R), j in [jlo, jhi).
 *
 * B102 -- THE j RANGE, and it is one nest rather than two.  The outer loop already walks j,
 * and j is the axis both call sites need to chunk: for the GATHER j is the input width, so
 * [jlo, jhi) is exactly the contiguous output byte range [jlo*IC, jhi*IC) that hart 0 has to
 * publish to the fill; for the SCATTER j is the output channel, so [jlo, jhi) is exactly one
 * weight tile's columns.  A transpose is a bijection and this nest still visits every (i, j)
 * in the range once, so a full-range call is byte-for-byte the nest it replaced -- which
 * check/conv_stage_block_exact.c goes on gating through the wrapper below.
 *
 * jlo need not be a multiple of TB; the tiling then differs from the full-range call's and the
 * BYTES DO NOT, because which (i, j) share a tile changes nothing about where each one lands. */
static void mbxr_stage_tr_j(int8_t *out, const int8_t *in, int R, int S, int jlo, int jhi)
{
	const int TB = MBXR_RT_STAGE_TB;
	int j0, i0, i, j;

	for (j0 = jlo; j0 < jhi; j0 += TB) {
		int jn = jhi - j0 < TB ? jhi - j0 : TB;
		for (i0 = 0; i0 < R; i0 += TB) {
			int in_ = R - i0 < TB ? R - i0 : TB;
			for (i = 0; i < in_; i++) {
				const int8_t *src = in + (size_t)(i0 + i) * S + j0;
				int8_t *dst = out + (size_t)j0 * R + (i0 + i);
				for (j = 0; j < jn; j++) dst[(size_t)j * R] = src[j];
			}
		}
	}
}

/* out[j*R + i] = in[i*S + j]   for i in [0, R), j in [0, S) */
static void mbxr_stage_tr(int8_t *out, const int8_t *in, int R, int S)
{
	MBXR_STAGE_TR_SEEN(R, S);
	mbxr_stage_tr_j(out, in, R, S, 0, S);
}
#endif

#if MBP_B102 && MBXR_RT_STAGE_BLOCK
/* B102 -- stage through activation tile `a` and publish the TRUTH, never more.
 *
 * `wlo` is hart 0's w high-water mark.  The fill's demand is BLOCK-rounded and, on a short
 * last tile, runs past the plane -- act_extent() spans a full P-pixel window whatever the
 * clamped pixel count is -- so the extent to stage is mbxr_b102_arena(), not IW*IC, and the
 * gap between them is zero-filled rather than left as whatever the last convolution wrote.
 * Publishing more than has been written is exactly MBP_B102_POISON 1. */
static int mbxr_b102_stage_chunk(mbxr_b102_t *wm, int8_t *s, const int8_t *input,
				 int IC, int IW, int a, int P, int OW, int astride,
				 int K, uint64_t arena, int wlo)
{
	int p1 = (a + 1) * P;
	int last = p1 >= OW;
	uint64_t hi, wneed;
	int whi;

	if (p1 > OW) p1 = OW;
	hi = (uint64_t)(p1 - 1) * 8ULL * (uint64_t)astride + (uint64_t)K;
	hi = (hi + 63ULL) & ~63ULL;
	if (last || hi > arena) hi = arena;
	wneed = (hi + (uint64_t)IC - 1) / (uint64_t)IC;
	whi = (int)(wneed > (uint64_t)IW ? (uint64_t)IW : wneed);
	if (whi > wlo) mbxr_stage_tr_j(s, input, IC, IW, wlo, whi);
	if (whi >= IW) {
		uint64_t b;
		for (b = (uint64_t)IW * (uint64_t)IC; b < arena; b++) s[b] = 0;
		mbxr_b102_publish_stage(wm, arena);
	} else {
		mbxr_b102_publish_stage(wm, (uint64_t)whi * (uint64_t)IC);
	}
	return whi;
}
#endif
