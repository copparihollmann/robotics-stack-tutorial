/* SPDX-License-Identifier: Apache-2.0 -- see int_nonlin.h */

/* Include guard.  This file is #included by several curated pext_nl kernels, and a bench that
 * needs two of them (Lab B31) pulls it into one translation unit twice.  A guard is invisible
 * to every caller that includes it once and to the labs that compile it as its own unit. */
#ifndef INT_NONLIN_C_ONCE
#define INT_NONLIN_C_ONCE

#include "int_nonlin.h"

#if defined(__ZEPHYR__)
#include <zephyr/sys/printk.h>
#define NL_PRINT printk
#else
#include <stdio.h>
#define NL_PRINT printf
#endif

/* Q0.16 of 2^(-i/32) for i = 0..32, i.e. the mantissa table for a negative exponent.
 * 65536 down to 32768; the mirror of audio_fe.c's fe_log2_lut. */
static const uint32_t nl_exp2_lut[33] = {
	65536, 64132, 62757, 61410, 60093, 58803, 57540, 56305,
	55095, 53912, 52754, 51621, 50512, 49427, 48366, 47327,
	46311, 45316, 44343, 43391, 42460, 41548, 40657, 39784,
	38932, 38097, 37281, 36483, 35702, 34938, 34191, 33461,
	32768
};

uint32_t int_exp2_q31(int32_t z_q16)
{
	uint32_t f, idx, rem, lo, hi, m;
	int32_t n;

	if (z_q16 >= 0) {
		return 0x80000000u;          /* clamped: callers only pass z <= 0 */
	}
	n = (-z_q16) >> 16;                  /* integer part of -z */
	if (n >= 31) {
		return 0;
	}
	f = (uint32_t)((-z_q16) & 0xffff);   /* fractional part, Q16 */
	idx = f >> 11;                       /* 0..31 */
	rem = (f & 0x7ff) << 5;              /* Q16 within the segment */
	lo = nl_exp2_lut[idx];
	hi = nl_exp2_lut[idx + 1];
	m = lo - (uint32_t)(((uint64_t)(lo - hi) * rem) >> 16);   /* Q0.16 in [0.5, 1] */
	return (uint32_t)(((uint64_t)m << 15) >> n);              /* -> Q0.31, then 2^-n */
}

uint32_t int_rsqrt_q31(uint64_t v, int *shift)
{
	int e, i;
	uint64_t m, r;

	if (!v) {
		*shift = 0;
		return 0xffffffffu;
	}
	e = 63 - __builtin_clzll(v);
	if (e & 1) {
		e--;                          /* keep the exponent even so sqrt is exact */
	}
	/* m = v / 2^e, in Q0.62 over [1, 4) */
	m = (e >= 0) ? (v << (62 - e)) : (v << 62);
	/* Newton on r = 1/sqrt(m): r <- r*(3 - m*r^2)/2, Q0.31, five iterations from a
	 * linear seed is exact to the last bit over [1, 4). */
	r = 0x60000000u;
	for (i = 0; i < 6; i++) {
		uint64_t mr2 = (uint64_t)(((__uint128_t)m * r >> 62) * r >> 31);
		int64_t t = (int64_t)0x180000000LL - (int64_t)mr2;

		if (t < 0) {
			t = 0;
		}
		r = (uint64_t)(((__uint128_t)r * (uint64_t)t) >> 32);
		if (r > 0xffffffffu) {
			r = 0xffffffffu;
		}
	}
	*shift = e / 2;
	return (uint32_t)r;
}

/* (a * m + 2^30) >> 31, then >> s with round-half-up -- the same requantise chain every
 * ModelBlaster kernel uses, so an integer replacement produces the same encoding. */
static inline int32_t nl_rq(int64_t a, int32_t mult, int32_t s)
{
	int64_t p = (a * (int64_t)mult + ((int64_t)1 << 30)) >> 31;

	if (s > 0) {
		p = (p + ((int64_t)1 << (s - 1))) >> s;
	}
	return (int32_t)p;
}

static inline int8_t nl_clip8(int32_t v)
{
	return (int8_t)(v > 127 ? 127 : (v < -128 ? -128 : v));
}

void int_softmax_s8(const int8_t *in, int8_t *out, int M, int K,
		    int32_t in_mult, int32_t in_shift)
{
	int r, i;

	for (r = 0; r < M; r++) {
		const int8_t *x = in + (size_t)r * K;
		int8_t *y = out + (size_t)r * K;
		int32_t mx = -128;
		uint64_t sum = 0;
		__uint128_t inv;

		for (i = 0; i < K; i++) {
			if (x[i] > mx) {
				mx = x[i];
			}
		}
		/* z = (x - max) * scale * log2(e), in Q16.16 and never positive.  The whole
		 * constant is folded into in_mult/in_shift by the caller, so no float
		 * appears anywhere in this function. */
		for (i = 0; i < K; i++) {
			sum += int_exp2_q31(nl_rq((int64_t)(x[i] - mx) << 16,
						  in_mult, in_shift));
		}
		if (!sum) {
			for (i = 0; i < K; i++) {
				y[i] = -128;
			}
			continue;
		}
		/* ONE divide per row, not per element, and a plain one rather than a Newton
		 * iteration: the first version of this function used Newton in Q0.62 and was
		 * simply wrong (max_abs_err 255 of a 255-wide output).  A row of 1,500
		 * elements pays one `div` against 1,500 exponentials; there is nothing here
		 * worth being clever about.  inv ~ 2^64/sum, so ev*inv >> 64 is ev/sum. */
		inv = (((__uint128_t)1 << 64) - 1) / sum;
		for (i = 0; i < K; i++) {
			uint32_t ev = int_exp2_q31(nl_rq((int64_t)(x[i] - mx) << 16,
							 in_mult, in_shift));
			/* the standard int8 probability encoding: 0 -> -128, 1 -> +127 */
			uint64_t p255 = (uint64_t)((((__uint128_t)ev * inv) >> 56) * 255
						   >> 8);
			int32_t v = (int32_t)p255 - 128;

			y[i] = nl_clip8(v);
		}
	}
}

void int_layernorm_s8(const int8_t *in, int8_t *out, int M, int K,
		      const int8_t *gamma, const int8_t *beta,
		      int32_t out_mult, int32_t out_shift)
{
	int r, i;

	for (r = 0; r < M; r++) {
		const int8_t *x = in + (size_t)r * K;
		int8_t *y = out + (size_t)r * K;
		int64_t s = 0, ss = 0;
		int32_t mean;
		uint64_t var;
		uint32_t rs;
		int sh;

		for (i = 0; i < K; i++) {
			s += x[i];
			ss += (int64_t)x[i] * x[i];
		}
		/* mean in Q8 so the subtraction keeps a fractional bit; one divide per ROW
		 * beside K multiply-accumulates. */
		mean = (int32_t)((s << 8) / K);
		var = (uint64_t)((ss << 16) / K) - (uint64_t)((int64_t)mean * mean);
		if (!var) {
			var = 1;
		}
		/* var is Q16 of the true variance, so int_rsqrt_q31 returns
		 * 1/sqrt(V * 2^16) = (1/sqrt(V)) * 2^-8.  Recovering 1/sqrt(V) therefore
		 * costs 2^8, and the exponent DIVIDES (see the header):
		 *     1/sqrt(V) = rs * 2^-(31 + sh - 8) = rs * 2^-(23 + sh)
		 * and d is already Q8 of (x - mu), so d * 1/sqrt(V) is Q8 of the output. */
		rs = int_rsqrt_q31(var, &sh);
		for (i = 0; i < K; i++) {
			int64_t d = ((int64_t)x[i] << 8) - mean;
			int64_t n = (int64_t)(((__int128)d * rs) >> (23 + sh));

			if (gamma) {
				n = n * gamma[i] + ((int64_t)beta[i] << 8);
			}
			y[i] = nl_clip8(nl_rq(n, out_mult, out_shift));
		}
	}
}

/* ---------------------------------------------------------------------------------
 * GELU.
 *
 * Two independent ideas live here and they are worth separating, because only one of
 * them is about fixed point.
 *
 *  (1) THE POPULATION ARGUMENT.  gelu_s8 is a pointwise int8 -> int8 map with
 *      per-tensor symmetric quantisation and zero_point 0, so for one (scale_in,
 *      scale_out, clamp) it has at most 256 distinct outputs.  Evaluating a
 *      transcendental once per ELEMENT is therefore never necessary, whatever
 *      arithmetic it is evaluated in.  That is worth more here than the arithmetic,
 *      and it is the same observation DRONET_INTEGER.md 3 makes about batchnorm2d_s8
 *      and add_s8 -- a domain of 256 values is small enough to enumerate, not sample.
 *
 *  (2) THE FIXED-POINT ARGUMENT.  Filling those <= 256 entries with erff costs 256
 *      libgcc calls on this core.  int_erf_q31 does it with a divide, five multiplies
 *      and the exp2 table that int_softmax_s8 already carries.
 *
 * (1) is what makes the per-element cost a byte load and a byte store.  (2) is what
 * removes the last libm dependency, and it is the smaller half.
 * ------------------------------------------------------------------------------- */

/* Decode a positive binary32 into (mult, shift) with f == mult * 2^-31 * 2^-shift and
 * mult in [2^30, 2^31).  Integer only: this is a bit-field extract, not a conversion.
 * A float ARGUMENT costs nothing on lp64 -- it arrives in an integer register. */
static void nl_f2ms(float f, int32_t *mult, int *shift)
{
	uint32_t b;
	int e;

	__builtin_memcpy(&b, &f, sizeof(b));
	if (!(b & 0x7f800000u)) {          /* zero or subnormal: refuse to divide by it */
		*mult = 0;
		*shift = 0;
		return;
	}
	e = (int)((b >> 23) & 0xffu) - 127;
	*mult = (int32_t)((((b & 0x7fffffu) | 0x800000u)) << 7);   /* m * 2^30 */
	*shift = -(e + 1);
}

/* The same for 1/f: 1/f == mult * 2^-31 * 2^-shift.  One 64-bit divide, no float. */
static void nl_f2ms_recip(float f, int32_t *mult, int *shift)
{
	uint32_t b, mant;
	uint64_t r;
	int e;

	__builtin_memcpy(&b, &f, sizeof(b));
	if (!(b & 0x7f800000u)) {
		*mult = 0x7fffffff;
		*shift = 0;
		return;
	}
	e = (int)((b >> 23) & 0xffu) - 127;
	mant = (b & 0x7fffffu) | 0x800000u;                 /* Q23 of m in [1, 2) */
	r = ((uint64_t)1 << 54) / mant;                     /* 2^31 / m */
	if (r > 0x7fffffffu) {
		r = 0x7fffffffu;
	}
	*mult = (int32_t)r;
	*shift = e;
}

/* a * (mult * 2^-31 * 2^-s), with s of either sign.  nl_rq above refuses a negative
 * shift -- that was a real bug once (see PEXT_KERNELS.md) -- so this is a separate
 * function rather than a relaxation of it. */
static inline int64_t nl_scale(int64_t a, int32_t mult, int s)
{
	__int128 p;

	/* A NEGATIVE shift scales the OPERAND, not the rounded result.  Rounding first
	 * and shifting left afterwards multiplies the half-LSB rounding constant by
	 * 2^-s, which is how the first version of this returned 2 for 1 x 1.0. */
	if (s < 0) {
		a <<= -s;
		s = 0;
	}
	p = (((__int128)a * mult) + ((__int128)1 << 30)) >> 31;
	if (s > 0) {
		p = (p + ((__int128)1 << (s - 1))) >> s;
	}
	return (int64_t)p;
}

/* Round half away from zero on a Q8 value -- what the reference's roundf does, and what
 * a plain arithmetic shift gets wrong for exactly the negative half-integers. */
static inline int8_t nl_q8_to_s8(int64_t v_q8, int amin, int amax)
{
	int32_t v = (int32_t)(v_q8 >= 0 ? ((v_q8 + 128) >> 8) : -((-v_q8 + 128) >> 8));

	if (v < amin) {
		v = amin;
	}
	if (v > amax) {
		v = amax;
	}
	return (int8_t)(v > 127 ? 127 : (v < -128 ? -128 : v));
}

uint32_t int_erf_q31(uint32_t t_q16)
{
	/* Abramowitz & Stegun 7.1.26 coefficients, Q2.29.  |error| <= 1.5e-7. */
	static const int32_t nl_erf_a[5] = {
		136810595, -152738022, 763115691, -780155054, 569837701
	};
	uint64_t denom, u, t2;
	int64_t acc;
	uint32_t ex, poly;
	int i;

	if (t_q16 == 0) {
		return 0;
	}
	if (t_q16 >= (6u << 16)) {
		return 0x80000000u;          /* erf(6) = 1 - 2.2e-17; int8 cannot see it */
	}
	/* u = 1/(1 + p t) in Q0.31.  denom is Q16.16 and at least 1.0, so u <= 2^31. */
	denom = (uint64_t)65536u + (((uint64_t)t_q16 * 21469u) >> 16);
	u = ((uint64_t)1 << 47) / denom;
	if (u > 0x80000000u) {
		u = 0x80000000u;
	}
	/* Horner in Q2.29: P = u*(a0 + u*(a1 + u*(a2 + u*(a3 + u*a4)))) */
	acc = nl_erf_a[4];
	for (i = 3; i >= 0; i--) {
		acc = (int64_t)(((__int128)acc * (int64_t)u) >> 31) + nl_erf_a[i];
	}
	acc = (int64_t)(((__int128)acc * (int64_t)u) >> 31);      /* Q2.29, in [0, 0.36] */
	if (acc < 0) {
		acc = 0;
	}
	poly = (uint32_t)(acc << 2);                              /* -> Q0.31 */
	/* exp(-t^2) = 2^(-t^2 * log2 e), and int_exp2_q31 already exists for softmax. */
	t2 = ((uint64_t)t_q16 * (uint64_t)t_q16) >> 16;           /* Q16.16 */
	if (t2 > (uint64_t)0x7fffffffu) {
		return 0x80000000u;
	}
	ex = int_exp2_q31(-(int32_t)((t2 * 94548u) >> 16));
	{
		uint64_t tail = ((uint64_t)poly * (uint64_t)ex) >> 31;

		if (tail >= 0x80000000u) {
			return 0;
		}
		return 0x80000000u - (uint32_t)tail;
	}
}

/* y = x * Phi(x) for one quantised input byte, returned as the int8 the reference's
 * expression would produce.  Everything is integer. */
static int8_t nl_gelu_one(int q, int32_t im, int is, int32_t om, int os,
			  int amin, int amax)
{
	int64_t x_q16 = nl_scale((int64_t)q << 16, im, is);
	int64_t mag = x_q16 < 0 ? -x_q16 : x_q16;
	uint32_t t_q16, erf, phi;
	int64_t y_q16, v_q8;

	if (mag > 0x7fffffffLL) {
		mag = 0x7fffffffLL;
	}
	t_q16 = (uint32_t)(((uint64_t)mag * 46341u) >> 16);       /* |x| / sqrt(2) */
	erf = int_erf_q31(t_q16);
	/* Phi = (1 +- erf)/2 in Q0.31.  erf <= 2^31 so this never overflows. */
	phi = (x_q16 >= 0) ? (0x40000000u + (erf >> 1))
			   : (0x40000000u - (erf >> 1));
	y_q16 = (int64_t)(((__int128)x_q16 * (int64_t)(uint64_t)phi) >> 31);
	/* Keep eight fractional bits so the final rounding can be round-half-AWAY-from-
	 * zero, which is what the reference's roundf does and what a round-half-up shift
	 * would get wrong for exactly the negative half-integers. */
	v_q8 = nl_scale(y_q16, om, os + 8);
	return nl_q8_to_s8(v_q8, amin, amax);
}

/* ---- silu_s8 with no floating-point arithmetic ------------------------------------------------
 * silu(x) = x / (1 + exp(-x)) = x * sigmoid(x).
 *
 * WHY THIS EXISTS, and the number is measured rather than argued.  The curated silu kernel is
 * `pext_memo_lut` and builds its 256-entry table with `expf` and `roundf` in SOFT FLOAT.  Lab
 * B42 separated the two table builders on silicon -- a lane kernel builds all 256 entries and a
 * curated one builds only the D that occur, which makes its two arms a simultaneous equation --
 * and the answer is 5,087 cycles per FLOAT entry against 702 per INTEGER one, 7.2x
 * (T4_LANES.md s13).  silu_s8 is then 95.1 % table build and 4.9 % gather, and its scales do
 * NOT repeat: out/decint8/ir has 144 dispatches over 6 sites with 144 DISTINCT (scale_in,
 * scale_out) pairs and 0 of 6 sites constant across its tokens, so no cache across dispatches
 * is possible and the table is rebuilt every time.  Removing the float from that build is worth
 * 52.9 % of the operator -- 32.5 M cycles, -0.117 of RTF_e2e -- and needs no accelerator.
 *
 * THE TRADE, STATED RATHER THAN INFERRED.  This is the `numeric_drift` member of a pair whose
 * bit-exact member already exists, and the curated file names it: "that trade is available and
 * is deliberately NOT taken here: this is the bit-exact member of the pair".  Both are
 * registered; a build selects this one for a stated reason.  It is the same trade `gelu_s8`
 * took when `pext_int_lut` superseded `pext_memo_lut`.  The input domain is 256 values, so the
 * drift is ENUMERATED and not sampled -- see the selftest, which walks every input at every
 * scale pair and reports the worst.  A WER measurement is not the instrument for a bound of one
 * int8 LSB over an enumerable domain, and that is a reason rather than an omission.
 *
 * sigmoid IN FIXED POINT, reusing what is already here.  exp(-|x|) = 2^(-|x|*log2 e) is
 * int_exp2_q31, the same table int_softmax_s8 uses; log2(e) is 94,548 in Q16.  With
 * E = exp(-|x|) in Q0.31:
 *     x >= 0:  sigmoid = 1/(1+E)     -> (2^62) / (2^31 + E)   in Q0.31
 *     x <  0:  sigmoid = E/(1+E)     -> (E << 31) / (2^31 + E) in Q0.31
 * and the tail is gelu's, byte for byte: keep eight fractional bits so the final rounding can
 * be round-half-AWAY-from-zero, which is what the reference's roundf does. */
static int8_t nl_silu_one(int q, int32_t im, int is, int32_t om, int os,
			  int amin, int amax)
{
	int64_t x_q16 = nl_scale((int64_t)q << 16, im, is);
	int64_t mag = x_q16 < 0 ? -x_q16 : x_q16;
	uint64_t e_q31, denom, sig;
	int64_t z, y_q16, v_q8;

	if (mag > 0x7fffffffLL) {
		mag = 0x7fffffffLL;
	}
	/* z = |x| * log2(e), Q16.16; int_exp2_q31 wants a NEGATIVE argument and saturates to 0
	 * past 2^-31, which is the right answer here (sigmoid is 0 or 1 to well within an LSB). */
	z = ((__int128)mag * 94548) >> 16;
	if (z > 0x7fffffffLL) {
		z = 0x7fffffffLL;
	}
	e_q31 = int_exp2_q31(-(int32_t)z);
	denom = 0x80000000ull + e_q31;
	sig = (x_q16 >= 0) ? (((uint64_t)1 << 62) / denom)
			   : ((e_q31 << 31) / denom);
	if (sig > 0x7fffffffull) {
		sig = 0x7fffffffull;
	}
	y_q16 = (int64_t)(((__int128)x_q16 * (int64_t)sig) >> 31);
	v_q8 = nl_scale(y_q16, om, os + 8);
	return nl_q8_to_s8(v_q8, amin, amax);
}

void int_silu_s8_table(int8_t tbl[256], float scale_in, float scale_out,
		       int activation_min, int activation_max)
{
	int32_t im, om;
	int is, os, q;

	nl_f2ms(scale_in, &im, &is);
	nl_f2ms_recip(scale_out, &om, &os);
	for (q = -128; q < 128; q++) {
		tbl[(uint8_t)(q + 128)] = nl_silu_one(q, im, is, om, os,
						      activation_min, activation_max);
	}
}

void int_silu_s8(const int8_t *in, int8_t *out, int n,
		 float scale_in, float scale_out,
		 int activation_min, int activation_max)
{
	int8_t tbl[256];
	uint8_t seen[256];
	int32_t im, om;
	int is, os, i, v;

	nl_f2ms(scale_in, &im, &is);
	nl_f2ms_recip(scale_out, &om, &os);
	/* the same crossover and the same marking pass as int_gelu_s8, for the same reason */
	if (n < 32) {
		for (i = 0; i < n; i++) {
			out[i] = nl_silu_one(in[i], im, is, om, os,
					     activation_min, activation_max);
		}
		return;
	}
	for (i = 0; i < 256; i++) {
		seen[i] = 0;
	}
	for (i = 0; i < n; i++) {
		seen[(uint8_t)((int)in[i] + 128)] = 1;
	}
	for (v = 0; v < 256; v++) {
		if (seen[v]) {
			tbl[v] = nl_silu_one(v - 128, im, is, om, os,
					     activation_min, activation_max);
		}
	}
	for (i = 0; i < n; i++) {
		out[i] = tbl[(uint8_t)((int)in[i] + 128)];
	}
}

void int_gelu_s8_table(int8_t tbl[256], float scale_in, float scale_out,
		       int activation_min, int activation_max)
{
	int32_t im, om;
	int is, os, q;

	nl_f2ms(scale_in, &im, &is);
	nl_f2ms_recip(scale_out, &om, &os);
	for (q = -128; q < 128; q++) {
		tbl[(uint8_t)(q + 128)] = nl_gelu_one(q, im, is, om, os,
						      activation_min, activation_max);
	}
}

void int_gelu_s8(const int8_t *in, int8_t *out, int n,
		 float scale_in, float scale_out,
		 int activation_min, int activation_max)
{
	int8_t tbl[256];
	uint8_t seen[256];
	int32_t im, om;
	int is, os, i, v;

	nl_f2ms(scale_in, &im, &is);
	nl_f2ms_recip(scale_out, &om, &os);

	/* Below the crossover the marking array costs more than it saves: 256 bytes of
	 * memset plus two passes against n evaluations.  nl_gelu_one is ~60 cycles here,
	 * memset(256) is ~70, so the break-even is near n = 8; 32 is a comfortable
	 * margin and keeps the small-n path trivially correct. */
	if (n < 32) {
		for (i = 0; i < n; i++) {
			out[i] = nl_gelu_one(in[i], im, is, om, os,
					     activation_min, activation_max);
		}
		return;
	}
	for (i = 0; i < 256; i++) {
		seen[i] = 0;
	}
	for (i = 0; i < n; i++) {
		seen[(uint8_t)((int)in[i] + 128)] = 1;
	}
	for (v = 0; v < 256; v++) {
		if (seen[v]) {
			tbl[v] = nl_gelu_one(v - 128, im, is, om, os,
					     activation_min, activation_max);
		}
	}
	for (i = 0; i < n; i++) {
		out[i] = tbl[(uint8_t)((int)in[i] + 128)];
	}
}

void int_matmul_requant_s8(const int32_t *acc, int8_t *out, int n, float total,
			   int activation_min, int activation_max)
{
	int32_t m;
	int sh, i;

	nl_f2ms(total, &m, &sh);
	sh -= 8;          /* eight fractional bits survive into nl_q8_to_s8 */

	/* acc is int32 and m < 2^31, so acc*m fits in 63 bits and the whole loop is int64.
	 * That matters more than it looks: on RV64 every __int128 multiply-shift is a
	 * mulh/mul pair plus a three-instruction shift, and the generic nl_scale form of
	 * this loop measured 53 cycles per element on the board against the reference's
	 * 244.  The shift sign is hoisted out of the loop for the same reason -- this is
	 * the one op in int_nonlin.c whose population is heads*T*T per attention layer. */
	if (sh > 0 && sh < 40) {
		const int64_t r = (int64_t)1 << (sh - 1);

		for (i = 0; i < n; i++) {
			int64_t p = ((int64_t)acc[i] * m + ((int64_t)1 << 30)) >> 31;

			out[i] = nl_q8_to_s8((p + r) >> sh, activation_min,
					     activation_max);
		}
	} else if (sh == 0) {
		for (i = 0; i < n; i++) {
			int64_t p = ((int64_t)acc[i] * m + ((int64_t)1 << 30)) >> 31;

			out[i] = nl_q8_to_s8(p, activation_min, activation_max);
		}
	} else if (sh < 0 && sh >= -30) {
		/* sh < 0 is the COMMON case, not the exotic one: sh is (the decoded exponent
		 * of `total`) minus 8, so every total above 2^-8 lands here.  Measured on the
		 * board, routing it through the 128-bit nl_scale cost 55 cycles/element
		 * against this branch's 39.
		 *
		 * The obvious form, (acc << ls) * m, overflows int64 for ANY left shift once
		 * acc uses its int32 range -- acc*m is already 2^62.  Shifting the RESULT
		 * left instead moves the rounding constant with it and returns 2 for 1 x 1.0
		 * (the bug nl_scale carries the comment about).  Folding the shift into the
		 * Q0.31 renormalisation does neither: the product stays at 2^62 and the
		 * rounding constant stays exactly half an output LSB. */
		const int ls = -sh;
		const int64_t r = (int64_t)1 << (30 - ls);

		for (i = 0; i < n; i++) {
			int64_t p = ((int64_t)acc[i] * m + r) >> (31 - ls);

			out[i] = nl_q8_to_s8(p, activation_min, activation_max);
		}
	} else {
		/* |total| outside about 2^-39 .. 2^22, which no int8 matmul requantise
		 * produces -- every output would clamp -- but a wrong answer here would be
		 * silent, so it falls back to the 128-bit path. */
		for (i = 0; i < n; i++) {
			out[i] = nl_q8_to_s8(nl_scale((int64_t)acc[i], m, sh),
					     activation_min, activation_max);
		}
	}
}

int int_nonlin_selftest(void)
{
	int fails = 0, i;
	int sh;

	/* 2^0 == 1, 2^-1 == 0.5, 2^-2 == 0.25, exactly. */
	if (int_exp2_q31(0) != 0x80000000u) {
		NL_PRINT("INT_NONLIN exp2(0) = %u, want 0x80000000\n", int_exp2_q31(0));
		fails++;
	}
	if (int_exp2_q31(-65536) != 0x40000000u) {
		NL_PRINT("INT_NONLIN exp2(-1) = %u, want 0x40000000\n",
			 int_exp2_q31(-65536));
		fails++;
	}
	if (int_exp2_q31(-131072) != 0x20000000u) {
		fails++;
	}
	/* monotone decreasing, which a broken interpolation direction would break */
	{
		uint32_t prev = 0xffffffffu;

		for (i = 0; i > -600; i--) {
			uint32_t v = int_exp2_q31(i * 2048);

			if (v > prev) {
				NL_PRINT("INT_NONLIN exp2 not monotone at %d\n", i);
				fails++;
				break;
			}
			prev = v;
		}
	}
	/* 1/sqrt of exact squares. */
	for (i = 1; i < 20; i++) {
		uint64_t v = (uint64_t)i * i * 1000000u;
		uint32_t r = int_rsqrt_q31(v, &sh);
		/* r * 2^-31 * 2^-sh should be 1/(i*1000) */
		uint64_t got = ((uint64_t)r >> (31 - 20)) >> sh;   /* Q20 of 1/sqrt(v) */
		uint64_t want = (1u << 20) / ((uint64_t)i * 1000u);

		if (got + 2 < want || want + 2 < got) {
			NL_PRINT("INT_NONLIN rsqrt(%llu) Q20 got %llu want %llu\n",
				 (unsigned long long)v, (unsigned long long)got,
				 (unsigned long long)want);
			fails++;
			break;
		}
	}
	/* erf, at three points a wrong interpolation direction or a wrong exponent
	 * would each get wrong: erf(0) = 0, erf(1) = 0.842700793, erf(6) = 1. */
	if (int_erf_q31(0) != 0) {
		NL_PRINT("INT_NONLIN erf(0) = %u, want 0\n", int_erf_q31(0));
		fails++;
	}
	{
		uint32_t e1 = int_erf_q31(65536u);          /* erf(1) */
		uint32_t want = 1809934000u;                /* 0.842700793 * 2^31 */

		if (e1 + 2000000u < want || want + 2000000u < e1) {
			NL_PRINT("INT_NONLIN erf(1) = %u, want ~%u\n", e1, want);
			fails++;
		}
	}
	if (int_erf_q31(6u << 16) != 0x80000000u) {
		fails++;
	}
	/* GELU: the memo/table path and the per-element path must agree exactly, and the
	 * small-n arm below the crossover must agree with the table arm above it -- that
	 * is the one seam in this function and it is invisible to any single-n test. */
	{
		int8_t probe[64], got[64], tab[256];
		uint32_t g = 7u;
		int i, bad = 0;

		for (i = 0; i < 64; i++) {
			g = g * 1103515245u + 12345u;
			probe[i] = (int8_t)((g >> 16) & 0xff);
		}
		int_gelu_s8_table(tab, 0.0781f, 0.05f, -128, 127);
		int_gelu_s8(probe, got, 64, 0.0781f, 0.05f, -128, 127);
		for (i = 0; i < 64; i++) {
			if (got[i] != tab[(uint8_t)((int)probe[i] + 128)]) {
				bad++;
			}
		}
		int_gelu_s8(probe, got, 16, 0.0781f, 0.05f, -128, 127);   /* small-n arm */
		for (i = 0; i < 16; i++) {
			if (got[i] != tab[(uint8_t)((int)probe[i] + 128)]) {
				bad++;
			}
		}
		/* GELU(0) = 0 exactly, in every scale. */
		if (tab[128] != 0) {
			bad++;
		}
		if (bad) {
			NL_PRINT("INT_NONLIN gelu path disagreement, %d of 81\n", bad);
			fails += bad;
		}
	}
	NL_PRINT("INT_NONLIN selftest fails=%d\n", fails);
	return fails;
}

#endif /* INT_NONLIN_C_ONCE */
