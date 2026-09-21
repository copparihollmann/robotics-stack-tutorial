/* SPDX-License-Identifier: Apache-2.0
 *
 * The camera front end: one HM01B0 frame in DRAM -> the int8 tensor a network takes.
 *
 * Three functions, because the sensor can be specified three ways and the choice is not
 * free on this core.  All three produce a tensor whose spatial extent after the first
 * convolution is identical (48 x 48), so the networks behind them differ only in their
 * first layer -- see fpga/pynq-z2/modelblaster/vision/vision_models.py.
 *
 *   frame_fe_mono96      324x324 luma          -> 1 x 96 x 96   (monochrome sensor)
 *   frame_fe_rgb96       324x324 RGGB mosaic   -> 3 x 96 x 96   (colour + demosaic)
 *   frame_fe_bayer4_48   324x324 RGGB mosaic   -> 4 x 48 x 48   (colour, NO demosaic)
 *
 * GEOMETRY, STATED ONCE.  The sensor window is 324 x 324 and the network wants 96 x 96,
 * and 324/96 = 3.375 is not an integer.  Rather than resample, the front end takes the
 * centre 288 x 288 -- 88.9 % of the frame, 3 x 96 exactly -- and box-averages 3x3.  An
 * integer decimation has no phase error and needs no filter design; the cost is the
 * 6.1 % border, which on a sensor pointed at a room is the part nothing is ever in.
 *
 * THE INT8 MAP HAS NO PARAMETERS.  out = clamp(avg - 128, -127, 127).  No per-frame
 * autoscale, no mean subtraction, no histogram anything: all of those need a second pass
 * over the frame (or a float) before the first convolution can start, and this core has
 * no FPU.  The models are trained on exactly this.
 *
 * FRAME_FE_PEXT selects MBP.QMUL for the divide-by-9, against a 32-bit multiply-shift
 * otherwise.  Same one-source-two-arithmetics idea as fpga/pynq-z2/sw/audio_fe.c, so the
 * comparison is the arithmetic and not two people's code.
 *
 * QMUL is the ONLY MBP instruction this front end can use, and that is a finding rather
 * than an oversight.  DOT8 reduces eight int8 lanes and a box filter sums nine UNSIGNED
 * bytes with no weights; MAX8 has nothing to compare; CLIP8 saturates to [-128, 127] and
 * the int8 map here needs [-127, 127], which is one LSB narrower.  See frame_fe.c.
 */
#ifndef FRAME_FE_H
#define FRAME_FE_H

#include <stddef.h>
#include <stdint.h>

#define FRAME_W       324      /* HM01B0 8-bit mode, max window                       */
#define FRAME_H       324
#define FRAME_BYTES   (FRAME_W * FRAME_H)

#define FE_CROP       288      /* 3 * 96, centred                                     */
#define FE_CROP0      ((FRAME_W - FE_CROP) / 2)   /* 18 -- even, so the CFA phase of a
                                                   * Bayer frame survives the crop     */
#define FE_OUT        96       /* mono / rgb output side                              */
#define FE_OUT_BAYER  48       /* one Bayer sub-lattice plane                         */

#define FE_MONO_ELEMS   (1 * FE_OUT * FE_OUT)
#define FE_RGB_ELEMS    (3 * FE_OUT * FE_OUT)
#define FE_BAYER_ELEMS  (4 * FE_OUT_BAYER * FE_OUT_BAYER)

#ifdef __cplusplus
extern "C" {
#endif

/* All three write planar (NCHW) int8 and read a byte-per-pixel frame. */
void frame_fe_mono96(const uint8_t *frame, int8_t *out);
void frame_fe_rgb96(const uint8_t *frame, int8_t *out);
void frame_fe_bayer4_48(const uint8_t *frame, int8_t *out);

/* 1 if this translation unit was built with the MBP instructions, 0 otherwise. */
int  frame_fe_uses_pext(void);

/* Self-test: three synthetic frames whose correct output can be written down.
 * Returns 0 on success, or a negative code naming the check that failed. */
int  frame_fe_selftest(void);

#ifdef __cplusplus
}
#endif
#endif /* FRAME_FE_H */
