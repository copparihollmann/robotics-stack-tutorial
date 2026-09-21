/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_split_dot8 */
/* accuracy_class: bit_exact */
/* origin: patches/0103, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * conv2d_s16_pc -- an int16-by-int8 convolution with per-row requantise (extract_q16), with
 * MBP.DOT8 reductions.  DOT8 multiplies int8 by int8, so every int16 tap is split EXACTLY:
 *   x = 256*hi + lo + 128,   hi = x >> 8 in [-128, 127],   lo = (x & 0xFF) - 128 in [-128, 127]
 * and a row's accumulator is 256*DOT(hi, w) + DOT(lo, w) + 128*sum(w) + bias -- every term an
 * exact integer, so the sum is the reference's int64 accumulator whatever the operands (the
 * offset split cancels nothing that could saturate: nothing here is requantised before
 * the sum).  A tap outside the input reads hi = 0, lo = -128, i.e. x = 0.
 *
 * Per output position the patch is gathered ONCE into two 8-aligned int64 word buffers (hi
 * and lo bytes in the weight's OIHW order, zero-padded to a multiple of 8); the weights are
 * packed once per dispatch the same way.  Each output element is then 2*ceil(K/8) DOT8s
 * plus the reference's own tail: (acc*mult + 2^(30+shift)) >> (31+shift) in 128-bit, clamp16.
 * A weight block larger than MBP_C16_WWORDS words, or a patch larger than MBP_C16_PWORDS,
 * runs the reference loop.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "pext.h"

#ifndef MBP_C16_WWORDS
#define MBP_C16_WWORDS 262144        /* 2 MB of int64: Moonshine conv2 needs 145,152 */
#endif
#ifndef MBP_C16_PWORDS
#define MBP_C16_PWORDS 1024
#endif

static int64_t pc16_w[MBP_C16_WWORDS];
static int64_t pc16_hi[MBP_C16_PWORDS];
static int64_t pc16_lo[MBP_C16_PWORDS];
#ifndef MBP_C16_MAXOC
#define MBP_C16_MAXOC 4096
#endif
static int64_t pc16_sumw[MBP_C16_MAXOC];

static inline int16_t pc16_clip16(int64_t v)
{
	return (int16_t)(v < -32768 ? -32768 : (v > 32767 ? 32767 : v));
}

static void pc16_reference(const int16_t *input, const int8_t *weight, const int64_t *bias,
                           const int32_t *mult, const int32_t *shift, int16_t *output,
                           int N, int IC, int IH, int IW, int OC, int OH, int OW,
                           int KH, int KW, int SH, int SW, int PH, int PW)
{
	for (int n = 0; n < N; n++)
		for (int oc = 0; oc < OC; oc++) {
			const int tot = 31 + shift[oc];
			const __int128 rnd = (__int128)1 << (tot - 1);

			for (int oh = 0; oh < OH; oh++)
				for (int ow = 0; ow < OW; ow++) {
					int64_t acc = bias[oc];

					for (int ic = 0; ic < IC; ic++)
						for (int kh = 0; kh < KH; kh++) {
							const int ih = oh * SH - PH + kh;
							if (ih < 0 || ih >= IH) continue;
							for (int kw = 0; kw < KW; kw++) {
								const int iw = ow * SW - PW + kw;
								if (iw < 0 || iw >= IW) continue;
								acc += (int64_t)input[(((size_t)n * IC + ic) * IH + ih) * IW + iw]
								     * (int64_t)weight[(((size_t)oc * IC + ic) * KH + kh) * KW + kw];
							}
						}
					output[(((size_t)n * OC + oc) * OH + oh) * OW + ow] =
						pc16_clip16((int64_t)(((__int128)acc * (__int128)mult[oc] + rnd) >> tot));
				}
		}
}

void kernel_conv2d_s16_pc(const int16_t *input, const int8_t *weight, const int64_t *bias,
                          const int32_t *mult, const int32_t *shift, int16_t *output,
                          int N, int IC, int IH, int IW, int OC, int OH, int OW,
                          int KH, int KW, int SH, int SW, int PH, int PW)
{
	const size_t K = (size_t)IC * (size_t)KH * (size_t)KW;
	const size_t KWD = (K + 7) / 8;

	if (KWD > MBP_C16_PWORDS || KWD * (size_t)OC > MBP_C16_WWORDS || OC > MBP_C16_MAXOC) {
		pc16_reference(input, weight, bias, mult, shift, output,
		               N, IC, IH, IW, OC, OH, OW, KH, KW, SH, SW, PH, PW);
		return;
	}
	/* weights: OC rows of K bytes, 8-aligned, zero-padded */
	memset(pc16_w, 0, KWD * (size_t)OC * sizeof(int64_t));
	for (int oc = 0; oc < OC; oc++) {
		const int8_t *wr = weight + (size_t)oc * K;
		int64_t s = 0;

		memcpy((char *)(pc16_w + (size_t)oc * KWD), wr, K);
		for (size_t q = 0; q < K; q++)
			s += wr[q];
		pc16_sumw[oc] = s;      /* 128*sum(w): the lo split's offset, per row */
	}
	for (int n = 0; n < N; n++)
		for (int oh = 0; oh < OH; oh++)
			for (int ow = 0; ow < OW; ow++) {
				int8_t *hb = (int8_t *)pc16_hi, *lb = (int8_t *)pc16_lo;
				size_t j = 0;

				pc16_hi[KWD - 1] = 0;
				pc16_lo[KWD - 1] = 0;
				for (int ic = 0; ic < IC; ic++)
					for (int kh = 0; kh < KH; kh++) {
						const int ih = oh * SH - PH + kh;
						for (int kw = 0; kw < KW; kw++, j++) {
							const int iw = ow * SW - PW + kw;
							if (ih < 0 || ih >= IH || iw < 0 || iw >= IW) {
								hb[j] = 0;
								lb[j] = -128;
							} else {
								const int32_t x = input[(((size_t)n * IC + ic) * IH + ih) * IW + iw];
								hb[j] = (int8_t)(x >> 8);
								lb[j] = (int8_t)((x & 0xFF) - 128);
							}
						}
					}
				for (int oc = 0; oc < OC; oc++) {
					const int64_t *w = pc16_w + (size_t)oc * KWD;
					int64_t dh = 0, dl = 0;

					for (size_t q = 0; q < KWD; q++) {
						dh += mb_pext_dot8(pc16_hi[q], w[q]);
						dl += mb_pext_dot8(pc16_lo[q], w[q]);
					}
					const int64_t acc = bias[oc] + 256 * dh + dl + 128 * pc16_sumw[oc];
					const int tot = 31 + shift[oc];
					output[(((size_t)n * OC + oc) * OH + oh) * OW + ow] =
						pc16_clip16((int64_t)(((__int128)acc * (__int128)mult[oc]
						                       + ((__int128)1 << (tot - 1))) >> tot));
				}
			}
}
