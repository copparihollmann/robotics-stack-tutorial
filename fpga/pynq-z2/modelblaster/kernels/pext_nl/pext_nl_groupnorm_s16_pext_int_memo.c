/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_memo */
/* accuracy_class: bit_exact */
/* origin: patches/0103, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * groupnorm_s16 -- GroupNorm(1) on int16 in exact integers (extract_q16's normalisation
 * core).  Within one sample the normalised value t = floor((K*x - S)*R / 2^44) depends on
 * the int16 code x alone, so it is tabulated once per sample over the codes the sample
 * spans [xmin, xmax] -- the reference's own 128-bit expression per table entry -- and each
 * element is then a table read and one int64 multiply-shift with its channel's affine:
 *   out = clamp16((t[x]*gmul[c] + badd[c]*2^16 + 2^31) >> 32).
 * When the span is wider than the sample the table would not pay, and the reference
 * expression runs per element instead; either way the answer is the reference's.
 * The table is static (hart 0, one dispatch at a time).
 */
#include <stddef.h>
#include <stdint.h>

#ifndef MB_Q16_NORM_CORE
#define MB_Q16_NORM_CORE
static inline unsigned __int128 mb_q16_isqrt128(unsigned __int128 v) {
    unsigned __int128 r = 0, bit = (unsigned __int128)1 << 126;
    while (bit > v) bit >>= 2;
    while (bit) {
        if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; }
        else r >>= 1;
        bit >>= 2;
    }
    return r;
}
static inline int64_t mb_q16_norm_r(int64_t K, int64_t S, __int128 Q, int64_t eps_q) {
    __int128 V = (__int128)K * Q - (__int128)S * (__int128)S + (__int128)eps_q;
    return (int64_t)mb_q16_isqrt128(((unsigned __int128)1 << 120) / (unsigned __int128)V);
}
static inline int64_t mb_q16_norm_out(int64_t K, int64_t u, int64_t S, int64_t R,
                                      int64_t g, int64_t b) {
    __int128 d = (__int128)K * (__int128)u - (__int128)S;
    int64_t t = (int64_t)((d * (__int128)R) >> 44);
    return (t * g + b * 65536 + ((int64_t)1 << 31)) >> 32;
}
#endif

static int64_t pgn16_t[65536];

static inline int16_t pgn16_clip16(int64_t v)
{
	return (int16_t)(v < -32768 ? -32768 : (v > 32767 ? 32767 : v));
}

void kernel_groupnorm_s16(const int16_t *input, const int64_t *gmul, const int64_t *badd,
                          int16_t *output, int N, int C, int HW, int64_t eps_q)
{
	const int64_t K = (int64_t)C * (int64_t)HW;

	for (int n = 0; n < N; n++) {
		const int16_t *x = input + (size_t)n * (size_t)K;
		int16_t *y = output + (size_t)n * (size_t)K;
		int64_t S = 0;
		__int128 Q = 0;
		int32_t xmin = 32767, xmax = -32768;

		for (int64_t i = 0; i < K; i++) {
			const int32_t v = x[i];
			S += v;
			Q += (int64_t)v * (int64_t)v;
			if (v < xmin) xmin = v;
			if (v > xmax) xmax = v;
		}
		const int64_t R = mb_q16_norm_r(K, S, Q, eps_q);
		const int64_t span = (int64_t)xmax - (int64_t)xmin + 1;

		if (span > K) {
			for (int c = 0; c < C; c++)
				for (int p = 0; p < HW; p++) {
					const size_t i = (size_t)c * (size_t)HW + (size_t)p;
					y[i] = pgn16_clip16(mb_q16_norm_out(K, x[i], S, R, gmul[c], badd[c]));
				}
			continue;
		}
		for (int64_t v = 0; v < span; v++) {
			const __int128 d = (__int128)K * (__int128)(v + xmin) - (__int128)S;
			pgn16_t[v] = (int64_t)((d * (__int128)R) >> 44);
		}
		for (int c = 0; c < C; c++) {
			const int64_t g = gmul[c];
			const int64_t bb = badd[c] * 65536 + ((int64_t)1 << 31);
			const int16_t *xc = x + (size_t)c * (size_t)HW;
			int16_t *yc = y + (size_t)c * (size_t)HW;

			for (int p = 0; p < HW; p++)
				yc[p] = pgn16_clip16((pgn16_t[xc[p] - xmin] * g + bb) >> 32);
		}
	}
}
