/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_fine_first */
/* accuracy_class: bit_exact */
/* origin: patches/0103, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * mrcombine_s16 -- recombine a split multi-range convolution's int8 codes into int16
 * (extract_q16).  The reference evaluates every range for every element and keeps the
 * last one that qualifies; this walks the ranges from the finest down and stops at the
 * first whose H and L codes are both off the rails, with the input rows of the element's
 * (group, row) hoisted out of the pixel loop.  Most elements take the finest range, so
 * most elements read two bytes.  Same selection rule, same product, same clamp:
 *   finest k with -128 < z_H < 127 and -128 < z_L < 127, else k = 0;
 *   out = clamp16((z_H + z_L) * (ratios[R-1] / ratios[k])).
 */
#include <stddef.h>
#include <stdint.h>

#define PMRC_MAXR 8

void kernel_mrcombine_s16(const int8_t *const *ins, const int32_t *gidx,
                          const int32_t *lidx, const int32_t *goc,
                          const int32_t *ratios, int16_t *output,
                          int N, int OC, int HW, int G, int R)
{
	int64_t mul[PMRC_MAXR];
	const int8_t *h[PMRC_MAXR], *l[PMRC_MAXR];

	(void)G;
	if (R > PMRC_MAXR)
		return;
	for (int k = 0; k < R; k++)
		mul[k] = ratios[R - 1] / ratios[k];
	for (int n = 0; n < N; n++) {
		for (int c = 0; c < OC; c++) {
			const int g = gidx[c];
			const size_t base = ((size_t)n * (size_t)goc[g] + (size_t)lidx[c]) * (size_t)HW;
			int16_t *o = output + ((size_t)n * (size_t)OC + (size_t)c) * (size_t)HW;

			for (int k = 0; k < R; k++) {
				h[k] = ins[(g * R + k) * 2] + base;
				l[k] = ins[(g * R + k) * 2 + 1] + base;
			}
			for (int p = 0; p < HW; p++) {
				int k = R - 1;
				int32_t zh, zl;

				for (;; k--) {
					zh = h[k][p];
					zl = l[k][p];
					if (k == 0 || (zh > -128 && zh < 127 && zl > -128 && zl < 127))
						break;
				}
				const int64_t v = (int64_t)(zh + zl) * mul[k];
				o[p] = (int16_t)(v < -32768 ? -32768 : (v > 32767 ? 32767 : v));
			}
		}
	}
}
