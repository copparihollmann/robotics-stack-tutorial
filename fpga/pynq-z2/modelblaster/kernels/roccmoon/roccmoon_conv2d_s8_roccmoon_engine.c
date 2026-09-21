/* accuracy_class: bit_exact
 *
 * conv2d_s8 on the decoupled RoCC engine, for the 1-D convolutions a speech front end is
 * written as: one input row (IH = 1), (1, KW) kernels, no padding, no dilation, groups 1.
 * That is Moonshine's stem, with time on the width axis.
 *
 * NO IM2COL ENGINE.  The engine's sequencer strides its activation pointer by a whole number
 * of words per output pixel over a CONTIGUOUS window.  In NCHW that window is IC runs of KW
 * bytes, one per channel plane; in NHWC it is one run of KW x IC bytes.  So the input is
 * gathered to [IW, IC] once (a copy of IC x IW bytes on hart 0, counted), the weights are laid
 * out per output channel in the same (kw, ic) order in the cached image, and the output
 * [OW, OC] is transposed back to NCHW.  This is ROCC_DECOUPLED.md section 4.2's point about
 * NHWC turned into the engine's one data-layout requirement: IC x SW must be a multiple of 8.
 *
 * Integer sums commute, so reordering the reduction does not change a bit of the result; the
 * board checks it anyway (max_abs_err against the curated MBP kernel on the same dispatch).
 * Everything else falls back to the curated MBP convolution.
 */
#include <stddef.h>
#include <stdint.h>
#include "pext.h"
#include "roccmoon/mbxr_rt.h"

#include "../modelblaster/kernels/pext/pext_conv2d_s8_pext_patch_dot8.c"
#define MBXR_FALLBACK_CONV MBXR_RT_CAT(kernel, _conv2d_s8)

#include "../modelblaster/kernels/roccmoon/mbxr_stage.inc"

#ifdef __ZEPHYR__
typedef struct { const int8_t *w; int IC, KW, Kp; } mbxr_conv_rows_t;
static void mbxr_conv_row(void *ctx, int n, int8_t *dst)
{
	const mbxr_conv_rows_t *r = (const mbxr_conv_rows_t *)ctx;
	for (int kw = 0; kw < r->KW; kw++)
		for (int ic = 0; ic < r->IC; ic++)
			dst[kw * r->IC + ic] = r->w[(((size_t)n * r->IC + ic) * 1 + 0) * r->KW + kw];
	for (int k = r->KW * r->IC; k < r->Kp; k++) dst[k] = 0;
}
#endif

void kernel_conv2d_s8(const int8_t *input, const int8_t *weight,
                      const int32_t *bias, int8_t *output,
                      int N, int IC, int IH, int IW, int OC,
                      int KH, int KW, int SH, int SW, int PH, int PW,
                      int input_offset, int filter_offset, int output_offset,
                      int output_multiplier, int output_shift,
                      int activation_min, int activation_max)
{
#ifdef __ZEPHYR__
	int OW = (IW - KW) / (SW > 0 ? SW : 1) + 1;
	int K = IC * KW, Kp = (K + 7) & ~7;
	if (N == 1 && IH == 1 && KH == 1 && PH == 0 && PW == 0 && SW > 0 && IW >= KW &&
	    ((IC * SW) % 8) == 0 && input_offset == 0 && filter_offset == 0 && output_offset == 0 &&
	    (uint64_t)OW * K * OC >= MBXR_RT_MIN_MACS &&
	    (size_t)IW * IC + 64 <= (8UL << 20) && (size_t)OW * OC <= (8UL << 20) &&
	    mbxr_rt_available()) {
		mbxr_conv_rows_t rows = { weight, IC, KW, Kp };
		const mbxr_wimage *img = mbxr_rt_image(weight, 1, OC, Kp, bias, mbxr_conv_row, &rows);
#if MBP_B102 && MBXR_RT_STAGE_BLOCK
		/* B102 -- THE STAGING PIPELINE.  Hart 0 gathers while hart 1's engine runs, and
		 * transposes each weight tile's output columns as that tile's drain lands.
		 *
		 * THE ORDER IS THE CORRECTNESS ARGUMENT, not the poll budget.  Hart 1 waits on the
		 * gather watermark, so hart 0 must never wait on hart 1 while it still owes staging:
		 * PHASE 1 finishes the whole gather unconditionally, and only PHASE 2 polls.  There
		 * is therefore no cycle to deadlock in.
		 *
		 * B86d's rule 1 is also why the gather is not chunked ACROSS dispatches: mbxr_rt_job
		 * is one global struct, so exactly one dispatch is ever in flight here. */
		if (img && img->strided) {
			const int astride = SW * IC / 8;
			int P = (MBXR_BUF_WORDS - 7 - img->K / 8) / astride + 1;

			if (P > OW) P = OW;
			if (P >= 1 && img->tiles > 0) {
				const int tiles_a = (OW + P - 1) / P;
				const int cols = img->Q * MBXR_NCH;
				const uint64_t arena = mbxr_b102_arena(OW, P, astride, img->K);
				int8_t *s = (int8_t *)MBXR_RT_IN_STAGE;
				int8_t *eo = (int8_t *)MBXR_RT_OUT_STAGE;
				uint64_t c0, gcyc = 0, scyc = 0;
				mbxr_rt_tok tk;
				int wlo = 0, done = 0, a, rc, p;

				mbxr_b102_arm(&mbxr_b102, MBXR_RT_IN_STAGE, arena,
					      (uint32_t)img->tiles,
					      (uint32_t)((uint64_t)P * 8ULL * (uint64_t)astride),
					      (uint32_t)OW);
				c0 = mbxr_rt_cyc();
				wlo = mbxr_b102_stage_chunk(&mbxr_b102, s, input, IC, IW, 0, P, OW,
							    astride, img->K, arena, wlo);
				gcyc += mbxr_rt_cyc() - c0;
				tk = mbxr_rt_run_issue(img, MBXR_RT_IN_STAGE, OW, astride,
						       output_multiplier, output_shift,
						       activation_min, activation_max, eo);
				c0 = mbxr_rt_cyc();                       /* PHASE 1: the gather */
				for (a = 1; a < tiles_a; a++)
					wlo = mbxr_b102_stage_chunk(&mbxr_b102, s, input, IC, IW, a, P,
								    OW, astride, img->K, arena, wlo);
				gcyc += mbxr_rt_cyc() - c0;
				for (;;) {                                /* PHASE 2: the transpose */
					uint32_t d = mbxr_b102_tiles_done(&mbxr_b102);

					while (done < (int)d && done < img->tiles) {
						int n0 = done * cols, n1 = n0 + cols;

						if (n1 > OC) n1 = OC;
						c0 = mbxr_rt_cyc();
						mbxr_stage_tr_j(output, eo, OW, OC, n0, n1);
						scyc += mbxr_rt_cyc() - c0;
						done++;
					}
					p = mbxr_rt_run_poll(&tk);
					if (p != 0) break;
				}
				rc = (p == MBXR_E_TIMEOUT) ? MBXR_E_TIMEOUT
							   : mbxr_rt_run_wait(&tk);
				mbxr_b102_finish(&mbxr_b102);
				if (rc == MBXR_OK && !mbxr_b102.stall_now) {
					c0 = mbxr_rt_cyc();
					while (done < img->tiles) {
						int n0 = done * cols, n1 = n0 + cols;

						if (n1 > OC) n1 = OC;
						mbxr_stage_tr_j(output, eo, OW, OC, n0, n1);
						done++;
					}
					scyc += mbxr_rt_cyc() - c0;
					mbxr_rt_stats.cycles_stage += gcyc + scyc;
					mbxr_rt_stats.cycles_stage_in += gcyc;
					return;
				}
				/* A stall means hart 1 filled from bytes hart 0 had not written, so
				 * these output bytes are not trustworthy.  Fall through and redo the
				 * whole convolution the shipping way -- staging is idempotent and the
				 * re-dispatch is bit-identical, which is the same recovery B86d's
				 * `goto software` relies on. */
			}
		}
#endif
		if (img) {
			uint64_t c0 = mbxr_rt_cyc();
			int8_t *s = (int8_t *)MBXR_RT_IN_STAGE;
#if MBXR_RT_STAGE_BLOCK
			mbxr_stage_tr(s, input, IC, IW);
#else
			for (int w = 0; w < IW; w++)
				for (int c = 0; c < IC; c++)
					s[(size_t)w * IC + c] = input[(size_t)c * IW + w];
#endif
			for (int i = 0; i < 64; i++) s[(size_t)IW * IC + i] = 0;    /* the padded tail */
			{
				uint64_t d = mbxr_rt_cyc() - c0;
				mbxr_rt_stats.cycles_stage += d;
				mbxr_rt_stats.cycles_stage_in += d;   /* the gather half, on its own */
			}
			int8_t *eo = (int8_t *)MBXR_RT_OUT_STAGE;
			if (mbxr_rt_run(img, MBXR_RT_IN_STAGE, OW, SW * IC / 8, output_multiplier,
					output_shift, activation_min, activation_max, eo) == MBXR_OK) {
				c0 = mbxr_rt_cyc();
#if MBXR_RT_STAGE_BLOCK
				mbxr_stage_tr(output, eo, OW, OC);
#else
				for (int p = 0; p < OW; p++)
					for (int n = 0; n < OC; n++)
						output[(size_t)n * OW + p] = eo[(size_t)p * OC + n];
#endif
				mbxr_rt_stats.cycles_stage += mbxr_rt_cyc() - c0;
				return;
			}
		}
	}
	mbxr_rt_stats.calls_fallback++;
#endif
	MBXR_FALLBACK_CONV(input, weight, bias, output, N, IC, IH, IW, OC, KH, KW, SH, SW, PH, PW,
			   input_offset, filter_offset, output_offset, output_multiplier,
			   output_shift, activation_min, activation_max);
}
