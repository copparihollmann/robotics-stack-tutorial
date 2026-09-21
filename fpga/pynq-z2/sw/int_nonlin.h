/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * int_nonlin -- softmax, layer norm and the two transcendentals under them, in integer
 * fixed point, for a core with no FPU.
 *
 * WHY THIS EXISTS.  ModelBlaster's reference `softmax_s8` is two `expf` per element and
 * its `layernorm_s8` is `double` with a `sqrt`.  On this SoC both are libgcc soft-float,
 * and they sit on the critical path of every transcription model in
 * fpga/pynq-z2/docs/SPEECH_ON_ROCKET.md section 6 -- unlike a keyword spotter, which
 * never touches either.  Lab B19 measures what they cost; this is the answer to whether
 * they have to.
 *
 * THE QUESTION THIS FILE SETTLES IS "DOES THIS NEED FLOAT AT ALL".  It is the same
 * question audio_fe.c already answered for the FFT, where fixed point was worth 37.0x
 * and lost 0.076 log2 of accuracy.  If the answer here is also no, then the right
 * response to the float-tainted kernels is a few hundred lines of C and not a
 * floating-point unit -- which is a cheaper answer and a better one.
 *
 * THE TWO PRIMITIVES.  Both are the same shape as audio_fe.c's fe_log2_q8: strip the
 * exponent with a count-leading-zeros, look the mantissa up in a 33-entry table, and
 * interpolate linearly between neighbours.  No libm, no float, no division except one
 * reciprocal per softmax row.
 *
 *   int_exp2_q31(z)   2^z for z <= 0, z in Q16.16, result Q0.31 in (0, 1]
 *   int_rsqrt_q31(v)  1/sqrt(v) for v > 0, with the result's exponent returned
 *                     separately so the caller keeps full precision
 *
 * ACCURACY IS A MEASURED BAR, NOT AN ASSUMED ONE.  int_nonlin_selftest() sweeps both
 * against a double-precision reference on the host and reports the worst relative error;
 * the softmax and layernorm entry points are then compared against ModelBlaster's own
 * reference expressions over realistic activation distributions, and the acceptance
 * criterion is the int8 OUTPUT, because that is all a downstream layer can see.
 */

#ifndef INT_NONLIN_H_
#define INT_NONLIN_H_

#include <stdint.h>

/* 2^z for z <= 0, z in Q16.16.  Returns Q0.31 in (0, 2^31].  z <= -31 returns 0. */
uint32_t int_exp2_q31(int32_t z_q16);

/* 1/sqrt(v) for v > 0.  Returns a Q0.31 mantissa and writes a binary exponent to
 * *shift (always >= 0), such that
 *
 *     1/sqrt(v) == result * 2^-31 * 2^-(*shift)
 *
 * The SIGN of that exponent is the part worth stating: v is large, so 1/sqrt(v) is
 * small, so the shift divides.  Getting it backwards produces a layer norm whose output
 * scales with the variance instead of against it, which still looks like a normalised
 * tensor and is wrong in a way no range check catches. */
uint32_t int_rsqrt_q31(uint64_t v, int *shift);

/* int8 softmax over the last axis: M rows of K, in place-compatible layout.
 *
 * `in_mult`/`in_shift` carry the input scale as a Q0.31 multiplier and a right shift,
 * the same representation every ModelBlaster requantise already uses -- so the caller
 * hands over an integer, and nothing in this path ever sees a float.  The output is the
 * standard int8 probability encoding: 0 maps to -128 and 1 maps to +127.
 */
void int_softmax_s8(const int8_t *in, int8_t *out, int M, int K,
		    int32_t in_mult, int32_t in_shift);

/* int8 layer norm over the last axis, with int8 gamma/beta and their own scales as
 * (multiplier, shift) pairs.  Pass gamma = NULL for the affine-free form. */
void int_layernorm_s8(const int8_t *in, int8_t *out, int M, int K,
		      const int8_t *gamma, const int8_t *beta,
		      int32_t out_mult, int32_t out_shift);

/* erf(t) for t >= 0, t in Q16.16.  Returns Q0.31 in [0, 2^31].
 *
 * Abramowitz & Stegun 7.1.26 evaluated entirely in fixed point: one 64-bit divide for
 * u = 1/(1 + p*t), a five-term Horner in Q2.29, and int_exp2_q31 for exp(-t^2).  The
 * formula's own bound is 1.5e-7, which is 3.8e-5 of an int8 LSB at a typical GELU
 * output scale -- so what this feeds is limited by the int8 encoding, not by the
 * approximation. */
uint32_t int_erf_q31(uint32_t t_q16);

/* int8 GELU, exact (erf) form, matching ModelBlaster's kernel_gelu_s8 semantics:
 *
 *     f = in[i] * scale_in
 *     y = 0.5 * f * (1 + erf(f / sqrt(2)))
 *     out[i] = clamp(round(y / scale_out), activation_min, activation_max)
 *
 * NO FLOATING-POINT ARITHMETIC IS EXECUTED.  scale_in and scale_out are in the
 * signature because the reference kernel's signature has them there, but they are
 * decoded from their IEEE-754 bit patterns with integer shifts and one integer divide;
 * nothing in this file emits a libgcc soft-float call.
 *
 * AND THE REAL POINT IS NOT THE ARITHMETIC.  With per-tensor symmetric quantisation
 * this op is a pointwise map from 256 input bytes to 256 output bytes, so for any n
 * bigger than a couple of hundred elements the transcendental should be evaluated at
 * most 256 times and never per element.  int_gelu_s8 marks which of the 256 input
 * bytes actually occur, evaluates only those, and gathers -- so its per-element cost
 * is a byte load, an index and a byte store, and the erf cost amortises to nothing.
 * That argument is independent of whether the table is filled in integer or in float,
 * which is why it is worth more than the fixed point is. */
void int_gelu_s8(const int8_t *in, int8_t *out, int n,
		 float scale_in, float scale_out,
		 int activation_min, int activation_max);

/* Fill tbl[(uint8_t)(q + 128)] for every q in [-128, 127] with the integer GELU.
 * Exposed so a caller that dispatches the same (scale_in, scale_out, clamp) many times
 * can build the table once, and so a test can enumerate the ENTIRE input domain -- 256
 * values is small enough to prove rather than sample. */
/* silu_s8 with no float: the numeric_drift member of the pair whose bit_exact member is
 * pext_nl/pext_nl_silu_s8_pext_memo_lut.c.  See int_nonlin.c for the trade and its measurement. */
void int_silu_s8_table(int8_t tbl[256], float scale_in, float scale_out,
		       int activation_min, int activation_max);
void int_silu_s8(const int8_t *in, int8_t *out, int n, float scale_in, float scale_out,
		 int activation_min, int activation_max);

void int_gelu_s8_table(int8_t tbl[256], float scale_in, float scale_out,
		       int activation_min, int activation_max);

/* matmul_s8's requantise tail, in integer.
 *
 * ModelBlaster's kernel_matmul_s8 reduces in int32 -- which is already integer and
 * already fast -- and then spends `(int32_t)roundf((float)acc * total)` PER OUTPUT
 * ELEMENT.  On a WithoutFPU core that one line is libgcc, and for attention it is paid
 * heads*T*T times per layer, which is the largest population in an encoder.  This is
 * the same Q0.31 rescale every curated convolution kernel already does, so the fix is
 * not new arithmetic; it is noticing that the op was never float in the first place and
 * only its tail was.
 *
 * `total` is decoded from its IEEE-754 bits, so no float instruction executes. */
void int_matmul_requant_s8(const int32_t *acc, int8_t *out, int n, float total,
			   int activation_min, int activation_max);

/* Returns 0 on success; prints a verdict. */
int int_nonlin_selftest(void);

#endif /* INT_NONLIN_H_ */
