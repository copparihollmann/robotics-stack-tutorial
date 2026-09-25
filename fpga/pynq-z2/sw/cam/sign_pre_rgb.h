/* SPDX-License-Identifier: Apache-2.0
 *
 * Lab B144's COLOUR front end.  Separate from sign_pre.h on purpose: that header is the
 * frozen contract of the grey GTSRB demo and nothing here changes it.
 *
 * WHAT IS DIFFERENT, AND WHY IT HAD TO BE.  sign_pre.h's grey path deliberately NEVER ASKS
 * the CFA phase -- it averages raw Bayer bytes over an EVEN box, and any even box holds one
 * R, two G and one B whatever the phase.  A colour front end cannot dodge that: it must
 * commit.  This one commits to BGGR, and the evidence is in the captures themselves --
 * decoded BGGR the frame's illuminant reads warm (R~=G>B, the fluorescent tubes you can see
 * in the picture) and the props read red; decoded RGGB the same frame reads cyan and a STOP
 * sign reads blue.
 *
 * NO DEMOSAIC.  Each 5x5 output block accumulates each CFA colour into its own accumulator
 * and divides by its own count -- an unbiased mean over the 4..9 samples of that colour.
 * That is cheaper than a demosaic AND strictly better here: measured on snap_015, a bilinear
 * demosaic leaves the sign's red excess at ~15/255 buried under interpolation speckle of
 * amplitude 171, and this averages the speckle away by never interpolating.
 *
 * THE BOX IS ODD (5) AND THE PHASE THEREFORE ALTERNATES BETWEEN BLOCKS.  A mask fixed in
 * block-local coordinates averages R and B together on half the blocks and returns a grey
 * picture; this was measured during B144 (the sign collapsed to R82.6 G83.2 B83.4) before
 * the absolute-parity form below replaced it.  Index by ABSOLUTE row/col, always.
 *
 * GEOMETRY.  324x324 in a 326-byte stride with 2 pad bytes a line.  Rows and cols 2..321 are
 * a 320x320 crop -- offset 2, EVEN, so crop parity is frame parity -- tiled 5x5 into 64x64.
 * This is NOT the centre crop the lab ruled out: it drops a 2-pixel vignetted border, not the
 * 62% of frame a sign-sized crop would.  The 180 rotation (the camera is mounted upside down)
 * is applied to the finished RGB, never to the mosaic, so it cannot disturb the phase.
 */
#ifndef SIGN_PRE_RGB_H
#define SIGN_PRE_RGB_H

#include <stddef.h>
#include <stdint.h>

#define SPR_STRIDE      326
#define SPR_PAD         2
#define SPR_W           324
#define SPR_H           324
#define SPR_FRAME_BYTES (SPR_STRIDE * SPR_H)      /* 105,624 */

#define SPR_CROP        320
#define SPR_OFF         ((SPR_W - SPR_CROP) / 2)  /* 2, even -> CFA phase preserved */
#define SPR_OUT         64
#define SPR_BOX         (SPR_CROP / SPR_OUT)      /* 5 */
#define SPR_PIX         (SPR_OUT * SPR_OUT)       /* 4,096 */
#define SPR_ELEMS       (SPR_PIX * 3)             /* 12,288 */

#define SPR_WB_TARGET   110                       /* gray-world per-channel target mean */
#define SPR_IN_SCALE_RECIP 127                    /* [0,255] -> [0,127], as SignNet's */

/* Bayer frame -> 64x64x3 RGB, interleaved (HWC), upright. */
void sign_pre_rgb64(const uint8_t *frame, uint8_t *rgb64);

/* Gray-world white balance, in place.  This is what removes the illuminant, and it is why
 * the network does not have to spend capacity learning to ignore a yellow room. */
void sign_pre_rgb_wb(uint8_t *rgb64);

/* HWC uint8 -> CHW int8, which is the NCHW the model's conv1 reads. */
void sign_pre_rgb_quant(const uint8_t *rgb64, int8_t *out);

/* 0 on success; non-zero names the failing check. */
int sign_pre_rgb_selftest(uint8_t *st_frame);

#endif /* SIGN_PRE_RGB_H */
