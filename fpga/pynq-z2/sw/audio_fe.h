/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * audio_fe -- the log-mel / MFCC front end for speech on the PYNQ-Z1 Rocket SoC.
 *
 * WHY THIS FILE EXISTS.  This core is `WithoutFPU`: every float operation is a libgcc
 * call.  A textbook MFCC front end is ~5,000 multiplies per 10 ms frame, and in soft
 * float that alone costs more than the acoustic model it feeds.  So the whole chain --
 * window, FFT, power, mel, log, DCT -- is fixed point, and it is written so that ONE
 * source compiles three ways:
 *
 *   FE_ARITH_FLOAT  reference/straw-man: float twiddles, floats throughout, libm logf.
 *                   Built to be MEASURED, not to be shipped.  It is the number that
 *                   says how much the fixed-point rewrite was worth.
 *   FE_ARITH_INT    fixed point, twiddle multiply by the core's own `mul`.
 *   FE_ARITH_PEXT   fixed point, twiddle multiply by MBP.QMUL from pext.h.
 *
 * THE POINT OF THE THIRD MODE.  MBP.QMUL was added for the int8 requantise stage:
 * rd = (rs1[31:0] * rs2[31:0] + 2^30) >> 31, i.e. a rounded Q0.31 fixed-point multiply,
 * single cycle on hart 0.  That is exactly the primitive an integer FFT's twiddle
 * multiply is.  MBP.DOT8 (8x int8) is useless here -- an FFT wants int16/int32 operands
 * -- so the ISA helps the front end, but not through the instruction it was named for.
 * See fpga/pynq-z2/docs/SPEECH_ON_ROCKET.md section 4.
 *
 * NUMERIC CONTRACT.  FE_ARITH_INT and FE_ARITH_PEXT are BIT-IDENTICAL by construction:
 * both route every twiddle multiply through fe_qmul(), which is mb_pext_qmul() from the
 * frozen contract in pext.h, whose software model and whose silicon are already shown
 * equal (PEXT_VALIDATION.md).  FE_ARITH_FLOAT is NOT bit-identical to either and is not
 * meant to be; audio_fe_selftest() reports the log-mel divergence in Q8 LSBs so the
 * fixed-point error is a measured quantity rather than an assumption.
 *
 * SCALING.  The FFT carries int32 data with no intermediate downscaling.  A 256-point
 * complex transform can grow its input by at most 256 (8 bits); the input is int16 PCM
 * sign-extended, so the worst case is 15 + 8 = 23 bits and int32 cannot overflow.  That
 * is why there is no "scaled FFT" here and no per-stage right shift: on this core the
 * shift would cost as much as the headroom is worth.
 *
 * The output log-mel is Q8 log2 of the mel energy, i.e. (256 * log2(E)).  The absolute
 * offset of E is arbitrary (it carries the FFT's and the window's scale) but it is
 * CONSTANT, and the features the model is trained on are produced by this same code
 * compiled for the host -- see scripts/lib/featurize.py.  A global scale in E is an
 * additive constant in log2(E), which the first layer's bias absorbs.
 */

#ifndef AUDIO_FE_H_
#define AUDIO_FE_H_

#include <stdint.h>

/* ---- geometry -------------------------------------------------------------------- */

/* The geometry is a build-time parameter, because two of them matter here and the
 * tutorial measures both:
 *
 *   "asr"  512 / 400 / 160  -- 25 ms window, 10 ms hop, 100 frames/s.  The framing
 *                             every open-vocabulary model in SPEECH_ON_ROCKET.md's
 *                             table assumes (Whisper, wav2vec2, Conformer).
 *   "kws"  512 / 480 / 320  -- 30 ms window, 20 ms hop, 50 frames/s, 49 frames per
 *                             1 s clip.  MLPerf Tiny's keyword-spotting front end
 *                             exactly (window_size_ms 30.0, window_stride_ms 20.0,
 *                             dct_coefficient_count 10 -- mlcommons/tiny kws_util.py),
 *                             so its published accuracies mean something here.  Note
 *                             this is the SAME 512-point transform as "asr" at HALF
 *                             the frame rate, so the front end costs half as much per
 *                             second of audio.
 *
 * fpga/pynq-z2/sw/tools/gen_fe_tables.py takes the same three numbers and MUST be run
 * with the matching ones -- audio_fe_tables.c carries a static assertion against them,
 * because a table built for one geometry and a kernel compiled for the other produces a
 * plausible-looking spectrum that is simply wrong. */
#ifndef FE_NFFT
#  define FE_NFFT      512      /* zero-padded transform length                        */
#endif
#ifndef FE_FRAME_LEN
#  define FE_FRAME_LEN 400      /* 25 ms at ~16 kHz                                    */
#endif
#ifndef FE_HOP_LEN
#  define FE_HOP_LEN   160      /* 10 ms at ~16 kHz                                    */
#endif
#define FE_NCFFT       (FE_NFFT / 2)      /* the complex transform actually executed   */
#define FE_NBINS       (FE_NFFT / 2 + 1)  /* one-sided power bins                      */
/* The rate this microphone's decimator actually produces, in millihertz, read out of
 * the RATE register by the DMIC driver (MICROPHONE.md section 3.2).  It is 15993.859 Hz
 * and it cannot be 16000: FCLK0 is 1000/29 MHz and 16 kHz needs a divisor of 2155.17. */
#define FE_SAMPLE_RATE_MILLIHZ  15993859u

#ifndef FE_NMEL
#  define FE_NMEL      40       /* mel filters                                         */
#endif
#ifndef FE_NDCT
#  define FE_NDCT      10       /* MFCC coefficients kept                              */
#endif

/* Which arithmetic. Exactly one is defined; the build system picks. */
#if !defined(FE_ARITH_FLOAT) && !defined(FE_ARITH_INT) && !defined(FE_ARITH_PEXT)
#  define FE_ARITH_INT 1
#endif

#if defined(FE_ARITH_PEXT)
#  define FE_ARITH_NAME "pext"
#elif defined(FE_ARITH_FLOAT)
#  define FE_ARITH_NAME "float"
#else
#  define FE_ARITH_NAME "int"
#endif

/* ---- the tables, generated by tools/gen_fe_tables.py ----------------------------- */

extern const int32_t fe_twiddle_q31[FE_NCFFT * 2];      /* interleaved re,im; W_512^k       */
extern const int16_t fe_window_q15[FE_FRAME_LEN];   /* periodic Hann                    */
extern const int16_t fe_mel_w_q15[];                /* triangular weights, packed       */
extern const uint16_t fe_mel_start[FE_NMEL];        /* first bin of each filter         */
extern const uint16_t fe_mel_len[FE_NMEL];          /* bins per filter                  */
extern const uint16_t fe_mel_off[FE_NMEL];          /* offset into fe_mel_w_q15         */
extern const int32_t fe_dct_q31[FE_NDCT * FE_NMEL]; /* DCT-II, orthonormal, Q0.31       */
extern const int fe_mel_nnz;

/* ---- the API --------------------------------------------------------------------- */

/* Scratch for one frame. Caller owns it; ~6 KB, so it goes in .bss, not on a stack. */
struct fe_scratch {
	int32_t re[FE_NCFFT];
	int32_t im[FE_NCFFT];
	int32_t xre[FE_NBINS];
	int32_t xim[FE_NBINS];
	uint64_t pow[FE_NBINS];
};

/* One frame of int16 PCM (FE_FRAME_LEN samples) -> FE_NMEL log-mel values in Q8 log2. */
void fe_logmel_frame(const int16_t *pcm, struct fe_scratch *s, int16_t *out_q8);

/* FE_NMEL log-mel (Q8) -> FE_NDCT MFCC (Q8). Identity-free: a real DCT-II. */
void fe_dct(const int16_t *logmel_q8, int16_t *out_q8);

/* The pieces, exposed so a benchmark can time them separately. */
void fe_window(const int16_t *pcm, struct fe_scratch *s);
void fe_cfft256(struct fe_scratch *s);
void fe_split_real(struct fe_scratch *s);
void fe_power(struct fe_scratch *s);
void fe_melbank(const struct fe_scratch *s, int16_t *out_q8);

/* A whole clip, framed.  Returns the number of frames written.  out_q8 must hold
 * fe_nframes(nsamp) * FE_NDCT int16 when want_mfcc, or * FE_NMEL when not.
 *
 * This is the entry point the keyword spotter uses AND the one the host featuriser
 * uses to build the training set, which is the whole point: the features a model is
 * trained on are produced by the same C, compiled for a different machine, so there is
 * no train/inference front-end mismatch to reason about.  (The training corpus is
 * sampled at exactly 16000 Hz and this microphone runs at 15993.859 -- 0.038 % low,
 * a quarter of a mel bin at the top of the band.  That is the one mismatch that does
 * remain, and SPEECH_ON_ROCKET.md says so.) */
int fe_nframes(int nsamp);
int fe_mfcc_clip(const int16_t *pcm, int nsamp, struct fe_scratch *s, int16_t *out_q8,
		 int want_mfcc);

/* The Q8 feature -> int8 model input map.  A shift and an offset, no float, and the
 * SAME constants the training set was built with -- they are printed by
 * fpga/pynq-z2/sw/tools/featurise.py and baked into the model's meta.json. */
static inline signed char fe_feat_to_int8(int v_q8, int off_q8, int shift)
{
	int q = (v_q8 - off_q8) >> shift;

	return (signed char)(q > 127 ? 127 : (q < -127 ? -127 : q));
}

/* Q8 log2 of a non-negative 64-bit value. log2(0) is clamped to FE_LOG2_MIN. */
#define FE_LOG2_MIN  ((int16_t)-2048)   /* -8.0 in Q8 */
int16_t fe_log2_q8(uint64_t v);

/* Self-test: transforms a known deterministic signal and returns 0 on success.
 * Writes a human-readable verdict through printk/printf. */
int audio_fe_selftest(void);

#endif /* AUDIO_FE_H_ */
