/* SPDX-License-Identifier: Apache-2.0
 *
 * sign_pre_rgb.h's implementation.  Integer only, no allocation, no OS calls: it compiles
 * unchanged for the board and for the host, where B144 drives it through ctypes and checks
 * it BYTE FOR BYTE against the Python definition in modelblaster/signdet/signpre_rgb.py.
 *
 * COST.  One pass over 320x320 = 102,400 bytes with a 2-bit phase test, then 12,288 bytes of
 * white balance and quantisation.  Against the ~9.6 M cycles of the network it is noise --
 * the same argument sign_pre.c makes for the grey path, and it should be measured on the
 * board rather than believed.
 */
#include "sign_pre_rgb.h"

void sign_pre_rgb64(const uint8_t *frame, uint8_t *rgb64)
{
	int oy, ox, dy, dx;

	for (oy = 0; oy < SPR_OUT; oy++) {
		for (ox = 0; ox < SPR_OUT; ox++) {
			uint32_t sum[3] = {0, 0, 0};
			uint32_t cnt[3] = {0, 0, 0};
			int ry, rx, c;

			for (dy = 0; dy < SPR_BOX; dy++) {
				/* absolute row/col within the 320 crop -- the parity here IS
				 * the CFA phase, and it is why the mask cannot be block-local. */
				int i = oy * SPR_BOX + dy;
				const uint8_t *p = frame
					+ (size_t)(SPR_OFF + i) * SPR_STRIDE
					+ SPR_PAD + SPR_OFF + ox * SPR_BOX;

				for (dx = 0; dx < SPR_BOX; dx++) {
					int j = ox * SPR_BOX + dx;
					/* BGGR: (even,even)=B  (odd,odd)=R  else G */
					int ch = ((i & 1) && (j & 1)) ? 0
					       : (!(i & 1) && !(j & 1)) ? 2 : 1;

					sum[ch] += p[dx];
					cnt[ch] += 1;
				}
			}
			/* round(sum/cnt) = (2*sum + cnt) / (2*cnt), integer. */
			ry = SPR_OUT - 1 - oy;          /* the 180 rotation, applied to the */
			rx = SPR_OUT - 1 - ox;          /* finished RGB, never to the mosaic */
			for (c = 0; c < 3; c++) {
				rgb64[(ry * SPR_OUT + rx) * 3 + c] =
					(uint8_t)((2u * sum[c] + cnt[c]) / (2u * cnt[c]));
			}
		}
	}
}

void sign_pre_rgb_wb(uint8_t *rgb64)
{
	int c, i;

	for (c = 0; c < 3; c++) {
		uint32_t s = 0, m;

		for (i = 0; i < SPR_PIX; i++) {
			s += rgb64[i * 3 + c];
		}
		m = s / SPR_PIX;                        /* floor, matching the Python */
		if (m < 1u) { m = 1u; }
		for (i = 0; i < SPR_PIX; i++) {
			uint32_t v = ((uint32_t)rgb64[i * 3 + c] * SPR_WB_TARGET + m / 2u) / m;

			rgb64[i * 3 + c] = (uint8_t)(v > 255u ? 255u : v);
		}
	}
}

void sign_pre_rgb_quant(const uint8_t *rgb64, int8_t *out)
{
	int c, i;

	/* HWC -> CHW: conv1 reads NCHW, so the three planes must be contiguous. */
	for (c = 0; c < 3; c++) {
		for (i = 0; i < SPR_PIX; i++) {
			uint32_t q = (2u * (uint32_t)SPR_IN_SCALE_RECIP
				      * (uint32_t)rgb64[i * 3 + c] + 255u) / 510u;

			if (q > 127u) { q = 127u; }
			out[c * SPR_PIX + i] = (int8_t)q;
		}
	}
}

int sign_pre_rgb_selftest(uint8_t *st_frame)
{
	uint8_t rgb[SPR_ELEMS];
	int i, j;

	/* A frame that is constant in each CFA plane must come back as that exact colour --
	 * this is the check that catches a phase error, because R and B are different here. */
	for (i = 0; i < SPR_H; i++) {
		for (j = 0; j < SPR_W; j++) {
			int ii = i - SPR_OFF, jj = j - SPR_OFF;
			uint8_t v = ((ii & 1) && (jj & 1)) ? 200      /* R */
				  : (!(ii & 1) && !(jj & 1)) ? 40     /* B */
				  : 120;                              /* G */

			st_frame[i * SPR_STRIDE + SPR_PAD + j] = v;
		}
	}
	sign_pre_rgb64(st_frame, rgb);
	for (i = 0; i < SPR_PIX; i++) {
		if (rgb[i * 3 + 0] != 200) { return 1; }
		if (rgb[i * 3 + 1] != 120) { return 2; }
		if (rgb[i * 3 + 2] != 40)  { return 3; }
	}
	return 0;
}
