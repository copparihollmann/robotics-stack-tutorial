/* accuracy_class: bit_exact */
/* act_layouts: nhwc */
/*
 * conv2d_s8 on the decoupled RoCC engine, for NHWC activations: roccmoon_engine with its
 * two copies DELETED.  T1 lever 2 of ROCC_DECOUPLED.md section 8.14 (TODO.md item 5).
 *
 * roccmoon_conv2d_s8_roccmoon_engine.c gathers the NCHW input into an NHWC-contiguous window
 * (IC x IW bytes, on hart 0) and transposes the engine's [OW, OC] output back to NCHW.  On
 * Moonshine's stem that staging is 35 M cycles of the encoder's 983 M, measured (Lab B25 run 8:
 * 11.6 M, 15.6 M and 7.9 M for conv1..conv3).  When the IR declares the stem's tensors nhwc
 * (pipeline/assign_layouts.py --policy islands), the input already IS the window the engine
 * strides, and the engine's output already IS the layout the next op reads: this kernel hands
 * both buffers to the engine as they are.  The arithmetic is the engine's, unchanged, so the
 * output is the same bytes as roccmoon_engine's in a different order -- which is what the lab
 * checks (the model's host-C golden is byte-identical to the NCHW build's).
 *
 * The one copy left is for an input that is not 8-byte aligned (the engine fetches whole
 * 64-bit words).  Shapes the engine does not take (not 1-D, padding, IC*SW not a multiple of
 * 8) are relaid to NCHW and handed to the curated MBP convolution, on the host always.
 */
#include <stddef.h>
#include <stdint.h>
#ifndef __ZEPHYR__
#include <stdlib.h>
#endif
#include "pext.h"
#include "roccmoon/mbxr_rt.h"

#include "../modelblaster/kernels/pext/pext_conv2d_s8_pext_patch_dot8.c"
#define MBXR_FALLBACK_CONV_NHWC MBXR_RT_CAT(kernel, _conv2d_s8)

#ifdef __ZEPHYR__
typedef struct { const int8_t *w; int IC, KW, Kp; } mbxr_convn_rows_t;
static void mbxr_convn_row(void *ctx, int n, int8_t *dst)
{
	const mbxr_convn_rows_t *r = (const mbxr_convn_rows_t *)ctx;
	for (int kw = 0; kw < r->KW; kw++)
		for (int ic = 0; ic < r->IC; ic++)
			dst[kw * r->IC + ic] = r->w[((size_t)n * r->IC + ic) * r->KW + kw];
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
	int OW = (IW + 2 * PW - KW) / (SW > 0 ? SW : 1) + 1;
	int OH = (IH + 2 * PH - KH) / (SH > 0 ? SH : 1) + 1;
#ifdef __ZEPHYR__
	int K = IC * KW, Kp = (K + 7) & ~7;
	if (N == 1 && IH == 1 && KH == 1 && PH == 0 && PW == 0 && SW > 0 && IW >= KW &&
	    ((IC * SW) % 8) == 0 && input_offset == 0 && filter_offset == 0 && output_offset == 0 &&
	    (uint64_t)OW * K * OC >= MBXR_RT_MIN_MACS &&
	    (size_t)IW * IC + 64 <= (8UL << 20) && mbxr_rt_available()) {
		mbxr_convn_rows_t rows = { weight, IC, KW, Kp };
		const mbxr_wimage *img = mbxr_rt_image(weight, 1, OC, Kp, bias, mbxr_convn_row, &rows);
		if (img) {
			uint64_t in_pa = (uint64_t)(uintptr_t)input;
			if (in_pa & 7) {
				uint64_t c0 = mbxr_rt_cyc();
				int8_t *s = (int8_t *)MBXR_RT_IN_STAGE;
				for (size_t i = 0; i < (size_t)IW * IC; i++) s[i] = input[i];
				for (int i = 0; i < 64; i++) s[(size_t)IW * IC + i] = 0;
				mbxr_rt_stats.cycles_stage += mbxr_rt_cyc() - c0;
				in_pa = MBXR_RT_IN_STAGE;
			}
			if (mbxr_rt_run(img, in_pa, OW, SW * IC / 8, output_multiplier, output_shift,
					activation_min, activation_max, output) == MBXR_OK)
				return;
		}
	}
	mbxr_rt_stats.calls_fallback++;
#endif
	{
		/* relay to NCHW, convolve with the curated MBP kernel, relay back */
		size_t HWin = (size_t)IH * IW, HWout = (size_t)OH * OW;
#ifdef __ZEPHYR__
		/* no heap on the board: the runtime's staging windows (8 MB each) */
		if ((size_t)N * IC * HWin > (8UL << 20) || (size_t)N * OC * HWout > (8UL << 20)) return;
		int8_t *xi = (int8_t *)MBXR_RT_IN_STAGE;
		int8_t *yo = (int8_t *)MBXR_RT_OUT_STAGE;
#else
		int8_t *xi = (int8_t *)malloc((size_t)N * IC * HWin);
		int8_t *yo = (int8_t *)malloc((size_t)N * OC * HWout);
		if (!xi || !yo) { free(xi); free(yo); return; }
#endif
		for (int n = 0; n < N; n++)
			for (size_t p = 0; p < HWin; p++)
				for (int c = 0; c < IC; c++)
					xi[((size_t)n * IC + c) * HWin + p] = input[((size_t)n * HWin + p) * IC + c];
		MBXR_FALLBACK_CONV_NHWC(xi, weight, bias, yo, N, IC, IH, IW, OC, KH, KW, SH, SW, PH, PW,
				       input_offset, filter_offset, output_offset, output_multiplier,
				       output_shift, activation_min, activation_max);
		for (int n = 0; n < N; n++)
			for (size_t p = 0; p < HWout; p++)
				for (int c = 0; c < OC; c++)
					output[((size_t)n * HWout + p) * OC + c] = yo[((size_t)n * OC + c) * HWout + p];
#ifndef __ZEPHYR__
		free(xi);
		free(yo);
#endif
	}
}
