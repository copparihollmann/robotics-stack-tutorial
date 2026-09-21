/* accuracy_class: bit_exact
 *
 * linear_s8 on the decoupled RoCC engine (ROCC_DECOUPLED.md section 8), hart 1.
 *
 * BIT-EXACT BY CONSTRUCTION AND BY TEST.  The engine computes kernel_linear_s8's reference
 * expression -- int32 accumulate from the bias, Q0.31 rounding multiply, round-half-up right
 * shift or unrounded left shift, clamp -- and tb_mbxr.cpp checks the RTL under this driver
 * against that reference copied verbatim (72 cases, every byte), as does the board
 * (samples/roccmoon_bench).  Shapes the engine does not take -- non-zero offsets, a dispatch
 * too small to be worth a hand-off, an image cache that is full -- go to the curated MBP
 * kernel, which is itself bit-exact against the same reference.
 *
 * K NOT A MULTIPLE OF 8: the weight rows are padded with zero bytes in the image and the
 * input rows are staged padded, so the extra products are 0 x 0.
 */
#include <stddef.h>
#include <stdint.h>
#include "pext.h"
#include "roccmoon/mbxr_rt.h"

/* The fallback: the curated MBP kernel, included whole.  Its entry point is reached through
 * a pasted name, because ModelBlaster renames every literal `kernel_<op>` token in this file
 * to `kernel_<op>_<id>` and a literal call here would become a call to this function. */
#include "../modelblaster/kernels/pext/pext_linear_s8_pext_row_dot8.c"
#define MBXR_FALLBACK_LINEAR MBXR_RT_CAT(kernel, _linear_s8)

#ifdef __ZEPHYR__
/* THE WEIGHT GRID, chosen at guest build time and NOT at bitstream build time.  One bitstream
 * runs both arms: the engine's unpacker is selected per dispatch by a cfg bit, and an image
 * that never sets it is bit-exact with every engine ever built here.  So the A/B is this
 * define and the int8 control is the decoder that was already measured.
 *
 * At 6 the WEIGHTS ARRIVE ONE CODE PER BYTE in [-31, 31] -- B77's `extract_graph.py
 * --weight-bits 6` emits exactly that, and a code in that range IS an ordinary int8 weight, so
 * an int6-GRID image with no packing runs on today's bitstream unmodified.  All this does is
 * buy the bytes. */
#ifndef MBXR_RT_WBITS
#define MBXR_RT_WBITS 8
#endif

typedef struct { const int8_t *w; int K, Kp; } mbxr_lin_rows_t;
static void mbxr_lin_row(void *ctx, int n, int8_t *dst)
{
	const mbxr_lin_rows_t *r = (const mbxr_lin_rows_t *)ctx;
	for (int k = 0; k < r->K; k++) dst[k] = r->w[(size_t)n * r->K + k];
	for (int k = r->K; k < r->Kp; k++) dst[k] = 0;
}

#if MBXR_RT_WBITS == 6
/* The packed row, through mbxr.c's mbxr_pack6 so there is ONE definition of the bit order and
 * the engine's 48-bit select is contracted against it rather than against a second copy.
 *
 * WHY IT COUNTS CLIPS.  A guest built for six bits against an int8 IR truncates every code
 * outside [-31, 31] and still produces plausible bytes.  That failure and an unpacker defect
 * are indistinguishable from a wrong answer alone, so the two are separated HERE: a non-zero
 * wpack_clipped says the IR is the wrong grid, and a zero one with wrong bytes says the
 * hardware. */
static void mbxr_lin_row6(void *ctx, int n, int8_t *dst)
{
	const mbxr_lin_rows_t *r = (const mbxr_lin_rows_t *)ctx;
	mbxr_rt_stats.wpack_clipped +=
		mbxr_pack6_rowz(r->w + (size_t)n * r->K, r->K, r->Kp, (uint8_t *)dst);
	mbxr_rt_stats.wpack_rows++;
}
#endif

/* SPLITTING A WIDE DISPATCH BY N, which is what makes the decoder's largest op reach the engine
 * at all (ROCC_DECOUPLED.md 8.15.28).  mbxr_rt_image() refuses an image whose staged rows exceed
 * the 8 MB row-staging buffer -- `N * Kp > 8 MB` -- and Moonshine's tied output projection is
 * 32,768 x 288 = 9.00 MB, over by 12.5 %.  It therefore ran in SOFTWARE every token: 24 of the
 * decoder's 1,320 linear dispatches, and 82.7 % of all its linear cycles.
 *
 * The limit is on one STAGED IMAGE, not on the work: the engine already tiles by N internally, so
 * the same matrix in two halves is the same arithmetic.  out[m][n] for n in a chunk is a
 * contiguous run only when M = 1, and M = 1 is exactly the case that needs this (a decoder token),
 * so the split is taken only there -- anything else keeps the old behaviour rather than growing a
 * strided scatter no measurement asks for.
 *
 * Chunks are balanced rather than greedy: ceil(N*Kp / limit) of them, each ceil(N/chunks) rounded
 * up to MBXR_NCH, so two 16,384-wide images of 4.72 MB rather than 29,124 + 3,644. */
#define MBXR_LIN_STAGE_LIMIT  (8UL << 20)
/* THE LIMIT IS ON THE IMAGE BYTES, WHICH ARE THE PACKED ONES.  At eight bits Kw == Kp and this
 * is the function it always was.  At six, lm_head's 32,768 x 288 is 7,077,888 B rather than
 * 9.00 MB and the split simply stops happening -- 228 tiles and identical bytes either way, so
 * a simplification rather than a change (B77 section 11(b)). */
static int mbxr_lin_chunk_n(int N, int Kp)
{
	const long Kw = (long)Kp * MBXR_RT_WBITS / 8;
	long need = (long)N * Kw;
	int chunks, nc;

	if (need <= (long)MBXR_LIN_STAGE_LIMIT)
		return N;                                  /* fits whole: no split */
	chunks = (int)((need + (long)MBXR_LIN_STAGE_LIMIT - 1) / (long)MBXR_LIN_STAGE_LIMIT);
	nc = (N + chunks - 1) / chunks;
	nc = (nc + MBXR_NCH - 1) & ~(MBXR_NCH - 1);        /* whole quads, as the engine wants */
	if ((long)nc * Kw > (long)MBXR_LIN_STAGE_LIMIT)    /* alignment pushed it back over */
		nc -= MBXR_NCH;
	return nc > 0 ? nc : 0;
}

#if MBXR_RT_WBITS == 6
#define MBXR_LIN_ROW_FN   mbxr_lin_row6
#else
#define MBXR_LIN_ROW_FN   mbxr_lin_row
#endif
#endif  /* __ZEPHYR__: MBXR_NCH comes from mbxr.h, which only the target build includes */

void kernel_linear_s8(const int8_t *input, const int8_t *weight,
                      const int32_t *bias, int8_t *output,
                      int M, int K, int N,
                      int input_offset, int filter_offset, int output_offset,
                      int output_multiplier, int output_shift,
                      int activation_min, int activation_max)
{
#ifdef __ZEPHYR__
	if (input_offset == 0 && filter_offset == 0 && output_offset == 0 &&
	    (uint64_t)M * K * N >= MBXR_RT_MIN_MACS && mbxr_rt_available()) {
		int Kp = (K + 7) & ~7;
		int Nc = mbxr_lin_chunk_n(N, Kp);
		if (Nc > 0 && Nc < N && M == 1) {
			/* the wide case: one image per chunk, each inside the staging limit, each
			 * writing its own contiguous run of the single output row */
			uint64_t in_pa = (uint64_t)(uintptr_t)input;
			int ok = 1;
			if ((in_pa & 7) != 0 || Kp != K) {
				uint64_t c0 = mbxr_rt_cyc();
				int8_t *st = (int8_t *)MBXR_RT_IN_STAGE;
				for (int k = 0; k < K; k++) st[k] = input[k];
				for (int k = K; k < Kp; k++) st[k] = 0;
				mbxr_rt_stats.cycles_stage += mbxr_rt_cyc() - c0;
				in_pa = MBXR_RT_IN_STAGE;
			}
			for (int n0 = 0; n0 < N && ok; n0 += Nc) {
				int nn = N - n0 < Nc ? N - n0 : Nc;
				mbxr_lin_rows_t cr = { weight + (size_t)n0 * K, K, Kp };
				/* the cache key is the chunk's own first weight byte, so the images
				 * are distinct entries and each is built once per model load */
				const mbxr_wimage *ci = mbxr_rt_image_bits(weight + (size_t)n0 * K, 0, nn, Kp,
									   MBXR_RT_WBITS, bias + n0,
									   MBXR_LIN_ROW_FN, &cr);
				if (!ci || mbxr_rt_run(ci, in_pa, 1, Kp / 8, output_multiplier,
						       output_shift, activation_min, activation_max,
						       output + n0) != MBXR_OK)
					ok = 0;
			}
			if (ok)
				return;
			/* a chunk refused: fall through to the whole-image path, then the kernel */
		}
		mbxr_lin_rows_t rows = { weight, K, Kp };
		const mbxr_wimage *img = mbxr_rt_image_bits(weight, 0, N, Kp, MBXR_RT_WBITS, bias,
							    MBXR_LIN_ROW_FN, &rows);
		if (img) {
			uint64_t in_pa = (uint64_t)(uintptr_t)input;
			if ((in_pa & 7) != 0 || Kp != K) {
				if ((size_t)M * Kp + 64 <= (8UL << 20)) {
					uint64_t c0 = mbxr_rt_cyc();
					int8_t *s = (int8_t *)MBXR_RT_IN_STAGE;
					for (int m = 0; m < M; m++) {
						for (int k = 0; k < K; k++) s[(size_t)m * Kp + k] = input[(size_t)m * K + k];
						for (int k = K; k < Kp; k++) s[(size_t)m * Kp + k] = 0;
					}
					mbxr_rt_stats.cycles_stage += mbxr_rt_cyc() - c0;
					in_pa = MBXR_RT_IN_STAGE;
				} else {
					in_pa = 0;
				}
			}
			if (in_pa && mbxr_rt_run(img, in_pa, M, Kp / 8, output_multiplier, output_shift,
						 activation_min, activation_max, output) == MBXR_OK)
				return;
		}
	}
	mbxr_rt_stats.calls_fallback++;
#endif
	MBXR_FALLBACK_LINEAR(input, weight, bias, output, M, K, N, input_offset, filter_offset,
			     output_offset, output_multiplier, output_shift, activation_min,
			     activation_max);
}
