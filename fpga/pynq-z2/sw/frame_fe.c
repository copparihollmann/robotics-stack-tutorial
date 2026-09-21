/* SPDX-License-Identifier: Apache-2.0
 *
 * The camera front end.  See frame_fe.h for the contract and the geometry.
 *
 * ONE SOURCE, TWO ARITHMETICS, exactly like fpga/pynq-z2/sw/audio_fe.c:
 *   FRAME_FE_PEXT = 0   the divide-by-9 is a 32-bit multiply-shift, the saturate a
 *                       pair of branches.  Runs anywhere.
 *   FRAME_FE_PEXT = 1   MBP.QMUL does the divide and MBP.CLIP8 the saturate.  Hart 0
 *                       of the P-extension bitstream only.
 * The two are bit-identical by construction: MBP.QMUL computes exactly
 * (a*m + 2^30) >> 31 and the scalar path computes the same expression with the same
 * rounding, from the same constant.  frame_fe_selftest() checks that on the silicon.
 *
 * WHY 1/9 IS A Q0.31 CONSTANT AND NOT A DIVIDE.  Rocket has no divider worth using here
 * (and ModelBlaster's own requantise already works this way), so the box average is
 * round(sum/9) computed as (sum * 238609294 + 2^30) >> 31.  sum <= 9*255 = 2295, so the
 * product is at most 5.5e11 and the int64 intermediate cannot overflow.  Checked
 * exhaustively over all 2296 possible sums against the integer round(sum/9) in
 * frame_fe_selftest().
 */

#include "frame_fe.h"

#ifndef FRAME_FE_PEXT
#  if defined(CONFIG_MB_PEXT) && CONFIG_MB_PEXT
#    define FRAME_FE_PEXT 1
#  else
#    define FRAME_FE_PEXT 0
#  endif
#endif

#if FRAME_FE_PEXT
#  ifndef MB_PEXT_HW
#    define MB_PEXT_HW 1
#  endif
#  include "pext.h"
#endif

/* round(x/9) as a Q0.31 multiply: 2^31 / 9 = 238609294.2 -> 238609294. */
#define FE_RECIP9   238609294

static inline int fe_div9(int32_t s)
{
#if FRAME_FE_PEXT
	return (int)mb_pext_qmul(s, FE_RECIP9);
#else
	return (int)(((int64_t)s * (int64_t)FE_RECIP9 + ((int64_t)1 << 30)) >> 31);
#endif
}

static inline int8_t fe_to_int8(int v)
{
	/* v is an 8-bit box average, so v - 128 is already inside [-128, 127]; the clamp
	 * exists to pin the LOW end at -127 rather than -128.  ModelBlaster's symmetric
	 * quantisation uses [-127, 127] (_INT8_RANGE = 127.0) and a stray -128 is a value
	 * the calibration never saw.
	 *
	 * AND THAT IS WHY MBP.CLIP8 IS NOT USED HERE.  CLIP8 saturates to the int8 range,
	 * [-128, 127], which is one LSB WIDER than the clamp this needs -- so it cannot
	 * express it, and putting it in front of the two branches would be an instruction
	 * that never changes the answer.  An earlier version of this file did exactly that
	 * and the header claimed CLIP8 did the saturate.  The P-extension's contribution to
	 * this front end is QMUL and only QMUL (a 32-bit multiply is 7.75 cycles on this
	 * core against QMUL's 1.00 -- SPEECH_ON_ROCKET.md section 1.1), which is worth
	 * saying plainly rather than padding the list. */
	int q = v - 128;

	if (q < -127) {
		q = -127;
	}
	if (q > 127) {
		q = 127;
	}
	return (int8_t)q;
}

/* ---------------------------------------------------------------------------------
 * Monochrome: 324x324 luma -> 1 x 96 x 96
 * --------------------------------------------------------------------------------- */
void frame_fe_mono96(const uint8_t *frame, int8_t *out)
{
	int oy, ox;

	for (oy = 0; oy < FE_OUT; oy++) {
		const uint8_t *row = frame + (size_t)(FE_CROP0 + 3 * oy) * FRAME_W + FE_CROP0;

		for (ox = 0; ox < FE_OUT; ox++) {
			const uint8_t *p = row + 3 * ox;
			int32_t s = (int32_t)p[0] + p[1] + p[2]
				  + p[FRAME_W] + p[FRAME_W + 1] + p[FRAME_W + 2]
				  + p[2 * FRAME_W] + p[2 * FRAME_W + 1] + p[2 * FRAME_W + 2];

			out[oy * FE_OUT + ox] = fe_to_int8(fe_div9(s));
		}
	}
}

/* ---------------------------------------------------------------------------------
 * Bayer, de-interleaved, NO demosaic: 324x324 RGGB -> 4 x 48 x 48
 *
 * The four sub-lattices of an RGGB mosaic are each a half-resolution image: R at (even,
 * even), G1 at (even, odd), G2 at (odd, even), B at (odd, odd).  A 324x324 mosaic gives
 * four 162x162 planes; the centre 144x144 of each (origin 9, which is FE_CROP0/2) is
 * box-averaged 3x3 down to 48x48.  That is the same field of view as the monochrome path
 * at half the linear resolution, and it needs no interpolation at all -- every output
 * sample is an average of nine photosites of the SAME colour.
 * --------------------------------------------------------------------------------- */
void frame_fe_bayer4_48(const uint8_t *frame, int8_t *out)
{
	static const int dy[4] = { 0, 0, 1, 1 };      /* R, G1, G2, B */
	static const int dx[4] = { 0, 1, 0, 1 };
	const int sub0 = FE_CROP0 / 2;                /* 9 */
	int k, oy, ox;

	for (k = 0; k < 4; k++) {
		int8_t *o = out + k * FE_OUT_BAYER * FE_OUT_BAYER;

		for (oy = 0; oy < FE_OUT_BAYER; oy++) {
			for (ox = 0; ox < FE_OUT_BAYER; ox++) {
				const uint8_t *p = frame
					+ (size_t)(2 * (sub0 + 3 * oy) + dy[k]) * FRAME_W
					+ 2 * (sub0 + 3 * ox) + dx[k];
				int32_t s = (int32_t)p[0] + p[2] + p[4]
					+ p[2 * FRAME_W] + p[2 * FRAME_W + 2] + p[2 * FRAME_W + 4]
					+ p[4 * FRAME_W] + p[4 * FRAME_W + 2] + p[4 * FRAME_W + 4];

				o[oy * FE_OUT_BAYER + ox] = fe_to_int8(fe_div9(s));
			}
		}
	}
}

/* ---------------------------------------------------------------------------------
 * Colour with demosaic: 324x324 RGGB -> 3 x 96 x 96
 *
 * Bilinear demosaic, fused into the box filter so no full-resolution RGB frame is ever
 * materialised: each of the 288x288 = 82,944 photosites in the crop is interpolated to
 * three channels and accumulated straight into the 96x96x3 output.  A separate demosaic
 * pass would need 315 KB of scratch, which is more than this SoC's entire L2.
 *
 * THIS FUNCTION IS THE COST OF COLOUR, and it is the reason frame_fe_bayer4_48 exists.
 * The sensor sends the same 104,976 bytes either way -- the colour is in the filter
 * array, not in extra bytes -- so demosaicing buys interpolated full-resolution colour
 * and pays for it in cycles here, not in DMA traffic.
 *
 * Index safety: the crop starts at 18 and ends at 305, and the frame is 324 wide, so
 * every +/-1 neighbour is in range and no clamping is needed in the inner loop.
 * FE_CROP0 being EVEN is what makes the crop's (0,0) an R site, so the parity test below
 * is against the output-relative coordinates.
 * --------------------------------------------------------------------------------- */
void frame_fe_rgb96(const uint8_t *frame, int8_t *out)
{
	int8_t *oR = out;
	int8_t *oG = out + FE_OUT * FE_OUT;
	int8_t *oB = out + 2 * FE_OUT * FE_OUT;
	int oy, ox, i, j;

	for (oy = 0; oy < FE_OUT; oy++) {
		for (ox = 0; ox < FE_OUT; ox++) {
			int32_t sr = 0, sg = 0, sb = 0;

			for (i = 0; i < 3; i++) {
				int y = FE_CROP0 + 3 * oy + i;
				const uint8_t *r0 = frame + (size_t)y * FRAME_W;
				const uint8_t *rm = r0 - FRAME_W;
				const uint8_t *rp = r0 + FRAME_W;

				for (j = 0; j < 3; j++) {
					int x = FE_CROP0 + 3 * ox + j;
					int odd_y = y & 1, odd_x = x & 1;
					int R, G, B;

					if (!odd_y && !odd_x) {          /* R site */
						R = r0[x];
						G = (rm[x] + rp[x] + r0[x - 1] + r0[x + 1] + 2) >> 2;
						B = (rm[x - 1] + rm[x + 1] + rp[x - 1] + rp[x + 1] + 2) >> 2;
					} else if (!odd_y && odd_x) {    /* G1 site: R left/right */
						G = r0[x];
						R = (r0[x - 1] + r0[x + 1] + 1) >> 1;
						B = (rm[x] + rp[x] + 1) >> 1;
					} else if (odd_y && !odd_x) {    /* G2 site: R up/down */
						G = r0[x];
						R = (rm[x] + rp[x] + 1) >> 1;
						B = (r0[x - 1] + r0[x + 1] + 1) >> 1;
					} else {                         /* B site */
						B = r0[x];
						G = (rm[x] + rp[x] + r0[x - 1] + r0[x + 1] + 2) >> 2;
						R = (rm[x - 1] + rm[x + 1] + rp[x - 1] + rp[x + 1] + 2) >> 2;
					}
					sr += R; sg += G; sb += B;
				}
			}
			oR[oy * FE_OUT + ox] = fe_to_int8(fe_div9(sr));
			oG[oy * FE_OUT + ox] = fe_to_int8(fe_div9(sg));
			oB[oy * FE_OUT + ox] = fe_to_int8(fe_div9(sb));
		}
	}
}

int frame_fe_uses_pext(void)
{
	return FRAME_FE_PEXT;
}

/* ---------------------------------------------------------------------------------
 * Self-test.  Runs on the silicon in every lab, for the same reason
 * audio_fe_selftest() does: a fast wrong front end is worse than a slow right one, and
 * the failures that matter here are silent ones.
 * --------------------------------------------------------------------------------- */
static uint8_t fe_tb[FRAME_BYTES];

int frame_fe_selftest(void)
{
	static int8_t o_mono[FE_MONO_ELEMS];
	static int8_t o_bay[FE_BAYER_ELEMS];
	static int8_t o_rgb[FE_RGB_ELEMS];
	int i, k;

	/* 1. The reciprocal.  Every sum a 3x3 box of bytes can produce, against the
	 *    integer round(s/9).  This is the check that catches a Q0.31 constant that is
	 *    one LSB low -- which is correct for 99.9 % of inputs and wrong for the rest. */
	for (i = 0; i <= 9 * 255; i++) {
		int want = (i + 4) / 9;          /* round-half-up for non-negative i */

		if (fe_div9(i) != want) {
			return -1;
		}
	}

	/* 2. A uniform frame must come out uniform, and at the right level.  Catches a
	 *    wrong crop origin, a wrong stride and a wrong offset all at once. */
	for (i = 0; i < FRAME_BYTES; i++) {
		fe_tb[i] = 200;
	}
	frame_fe_mono96(fe_tb, o_mono);
	for (i = 0; i < FE_MONO_ELEMS; i++) {
		if (o_mono[i] != (int8_t)(200 - 128)) {
			return -2;
		}
	}

	/* 3. A COLOUR frame: each sub-lattice a different constant.  The de-interleaver
	 *    must report those four constants, one per plane, in R G1 G2 B order.  A
	 *    transposed or phase-shifted de-interleave still produces four uniform planes
	 *    and would pass any check that only looks at one. */
	{
		const uint8_t lev[4] = { 60, 120, 140, 220 };

		for (i = 0; i < FRAME_H; i++) {
			for (k = 0; k < FRAME_W; k++) {
				fe_tb[i * FRAME_W + k] = lev[((i & 1) << 1) | (k & 1)];
			}
		}
		frame_fe_bayer4_48(fe_tb, o_bay);
		for (k = 0; k < 4; k++) {
			for (i = 0; i < FE_OUT_BAYER * FE_OUT_BAYER; i++) {
				if (o_bay[k * FE_OUT_BAYER * FE_OUT_BAYER + i]
				    != (int8_t)((int)lev[k] - 128)) {
					return -3;
				}
			}
		}
		/* 4. The same frame through the demosaic.  R and B are interpolated only
		 *    from sites of their own colour, so both must come out EXACTLY uniform --
		 *    60 and 220.  If the demosaic has its parity backwards they swap, which
		 *    this catches and a grey test frame cannot.  G is deliberately only
		 *    bounded here: with G1 != G2 the interpolated green is 130 at an R or B
		 *    site and 120 or 140 at a green one, and the 3x3 box straddles a
		 *    different mixture depending on the parity of its origin, so a single
		 *    expected value would be wrong. */
		frame_fe_rgb96(fe_tb, o_rgb);
		for (i = 0; i < FE_OUT * FE_OUT; i++) {
			int g = o_rgb[FE_OUT * FE_OUT + i] + 128;

			if (o_rgb[i] != (int8_t)(60 - 128)) {
				return -4;
			}
			if (g < 120 || g > 140) {
				return -5;
			}
			if (o_rgb[2 * FE_OUT * FE_OUT + i] != (int8_t)(220 - 128)) {
				return -6;
			}
		}

		/* 4b. ... and with G1 == G2 the green plane IS exactly determined, which
		 *     pins the interpolation weights rather than just their range. */
		for (i = 0; i < FRAME_H; i++) {
			for (k = 0; k < FRAME_W; k++) {
				static const uint8_t sym[4] = { 60, 130, 130, 220 };

				fe_tb[i * FRAME_W + k] = sym[((i & 1) << 1) | (k & 1)];
			}
		}
		frame_fe_rgb96(fe_tb, o_rgb);
		for (i = 0; i < FE_OUT * FE_OUT; i++) {
			if (o_rgb[FE_OUT * FE_OUT + i] != (int8_t)(130 - 128)) {
				return -9;
			}
		}
	}

	/* 5. Saturation at both ends: a black frame must reach -127 and not -128, and a
	 *    white frame must reach +127. */
	for (i = 0; i < FRAME_BYTES; i++) {
		fe_tb[i] = 0;
	}
	frame_fe_mono96(fe_tb, o_mono);
	if (o_mono[0] != -127 || o_mono[FE_MONO_ELEMS - 1] != -127) {
		return -7;
	}
	for (i = 0; i < FRAME_BYTES; i++) {
		fe_tb[i] = 255;
	}
	frame_fe_mono96(fe_tb, o_mono);
	if (o_mono[0] != 127 || o_mono[FE_MONO_ELEMS - 1] != 127) {
		return -8;
	}
	return 0;
}
