/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_mul */
/* accuracy_class: bit_exact */
/* origin: patches/0100, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * mul_s8 with no floating-point arithmetic, and still bit-exact.
 *
 * The reference is `(int32_t)roundf(((float)a*sa) * ((float)b*sb) / so)`, measured at
 * 704 cycles/element on this core (ROCC_DECOUPLED.md 2.2: the rotary embedding of
 * attn_block, and the SiLU gate of every Moonshine decoder MLP).
 *
 * FAST PATH.  tb[b] = b * (sa*sb/so) in fixed point with F fractional bits, one table
 * per dispatch; an element is one load, ONE multiply by an int8, a rounding shift and a
 * clamp.
 *
 * WHY IT IS STILL THE REFERENCE.  The reference's four float32 operations err by at most
 * 4.0001 * 2^-24 of the result; the table by at most 128 * (|tb| >> 38 + 1) units.  If
 * x = a*tb[b] is further from every half-integer than G = 2^-21 * |x| + that table bound
 * (an 8x margin on the float term), both round to the same integer.  Otherwise the element
 * takes the exact binary32 slow path of fpga/pynq-z2/sw/fexact32.h.  G is per ELEMENT here
 * because a product has no cancellation: its float error scales with |x| itself.
 *
 * No floating-point instruction executes.  Checked over all 65,536 (a, b) pairs per scale
 * triple by check_moonshine.py.
 */
#include <stddef.h>
#include <stdint.h>
#include "fexact32.h"
#include "pext.h"

/*
 * B76 -- THE LAST HOLDER OF THE fx32_apply BUILDER, AND ITS TABLE IS TWO COPIES OF 129
 * NUMBERS.  The defect B63 removed from add_s8, B67 from cat2 and B74 from rope_s8 is the
 * same one: 256 entries, each an `unsigned __int128` multiply and an fx32_bitlen128 that
 * this ISA lowers to an out-of-line libgcc `__clzdi2`.  23,148 instructions per dispatch,
 * 90 per entry, against 144 decoder dispatches of n = 1152 -- measured by B66's own sweep
 * (test/b66_icount.sh) and confirmed here.
 *
 * B74's restriction DOES NOT REACH THIS KERNEL, and the bound says why.  There m < 2^24;
 * here the builder's argument is m = |v| * sb.m with |v| <= 128 and sb.m < 2^24, so
 * m < 2^31 and m * k.q < 2^31 * 2^40 = 2^71.  The 128-bit product is NOT dead here the
 * way it was there.  Two things remove it anyway, and both are exact:
 *
 *   (1) SPLIT THE MULTIPLIER, NOT THE MULTIPLICAND.  k.q <= 2^40 splits as kh*2^20 + kl
 *       with kh, kl < 2^20, so A = m*kh and B = m*kl are each below 2^51 and p = A*2^20 + B
 *       is carried exactly in two 64-bit halves.  fx32_apply's rounded shift is then
 *
 *         sh in (20, 62]:  C = B + 2^(sh-1);  r = (A + (C >> 20)) >> (sh - 20)
 *         sh in [1, 20]:   r = (A << (20 - sh)) + ((B + 2^(sh-1)) >> sh)
 *
 *       Both are identities, not approximations: A*2^20 is a multiple of 2^sh in the second
 *       case, and in the first the low 20 bits discarded from C are below the shift.
 *       Outside [1, 62] -- which no shipped scale triple reaches -- the generic fx32_apply
 *       is called exactly as before.
 *
 *   (2) A AND B ARE ARITHMETIC SEQUENCES IN |v|, so the two multiplies per entry become two
 *       ADDS.  On a core whose multiplier is iterative (MulDivParams(mulUnroll = 8)) that is
 *       the larger half of the win.
 *
 * And the table is HALF REDUNDANT: fx32_apply's result depends on |v| only, its sign on
 * `neg` only, so tb[(uint8_t)(-v)] == -tb[(uint8_t)v] for every v.  128 magnitudes fill 256
 * entries.  This is exact by construction, not by tolerance -- the same argument shape as
 * B66's lazy softmax fill.
 *
 * WHAT DOES NOT CHANGE: the guard, `eb`, the element loop, the slow path, and every value
 * in tb[].  -DMBP_B76=1 selects it; at 0 this file is the shipped kernel.
 */
#ifndef MBP_B76
#define MBP_B76 0
#endif
/* LIVE-PATH PROOF.  Each value perturbs one new route visibly in the OUTPUT -- and a
 * perturbation of tb[] must be large enough to survive the >> F, which at F ~ 44 a unit
 * change is not (B74's first poison was absorbed exactly there and reported four live
 * routes as dead).  These scale the entry instead:
 *   1  the positive magnitudes (the incremental A/B recurrence)
 *   2  the negated half (the mirror), which only b < 0 reads
 *   3  the sh <= 20 arm of the rounded shift */
#ifndef MBP_B76_POISON
#define MBP_B76_POISON 0
#endif

/* -DFX_STATS (host checks only): count the elements that took the exact slow path. */
#ifdef FX_STATS
unsigned long pint_mul_slow_count, pint_mul_count;
#define PINT_MUL_SLOW() (pint_mul_slow_count++)
#define PINT_MUL_N(n) (pint_mul_count += (unsigned long)(n))
#else
#define PINT_MUL_SLOW() ((void)0)
#define PINT_MUL_N(n) ((void)0)
#endif

static int32_t pint_mul_exact(int a, int b, fx32_t sa, fx32_t sb, fx32_t so)
{
	PINT_MUL_SLOW();
	fx32_t fa = fx32_mul(fx32_int(a), sa);
	fx32_t fb = fx32_mul(fx32_int(b), sb);

	return fx32_roundf_i32(fx32_div(fx32_mul(fa, fb), so));
}

void kernel_mul_s8(const int8_t *a, const int8_t *b, int8_t *output, int n,
		   float scale_a, float scale_b, float scale_out,
		   int activation_min, int activation_max)
{
	const fx32_t sa = fx32_dec(scale_a), sb = fx32_dec(scale_b), so = fx32_dec(scale_out);
	static int64_t tb[256];     /* static: see pext_nl_add_s8_pext_int_add.c */
	fx32_k_t k;
	int F, lab, lo, ok = 1, i;
	uint64_t half, mask, eb = 0;
	int64_t hi, lo_lim;

	PINT_MUL_N(n);
	if (!(fx32_scale_ok(sa) && fx32_scale_ok(sb) && fx32_scale_ok(so))) {
		goto slow_all;
	}
	lab = fx32_bitlen64(sa.m) + sa.e + fx32_bitlen64(sb.m) + sb.e;
	lo = fx32_bitlen64(so.m) + so.e;
	F = 44 - (lab - lo);        /* 16384 * sa*sb/so * 2^F ~ 2^58 */
	if (F < 16 || F > 55) {
		goto slow_all;
	}
	/* tb[b] = |b| * sb (an exact integer, <= 31 bits) through K = sa/so: the fixed-point
	 * error bound (|t| >> 38) + 1 does not depend on the operand's width. */
	k = fx32_ratio(sa, so);
#if MBP_B76
	{
	const int sh = -(sb.e + k.e + F);

	if (sh >= 1 && sh <= 62) {
		/* THE SPLIT MULTIPLIER AND THE RECURRENCE.  Decided once, outside the loop,
		 * so neither arm below carries the other's test. */
		const uint64_t stepA = sb.m * (k.q >> 20);
		const uint64_t stepB = sb.m * (k.q & 0xfffffu);
		const uint64_t rhalf = (uint64_t)1 << (sh - 1);
		uint64_t A = 0, B = 0;

		tb[0] = 0;
		for (i = 1; i <= 128; i++) {
			uint64_t r;

			A += stepA;                     /* = |v| * sb.m * (k.q >> 20)  < 2^51 */
			B += stepB;                     /* = |v| * sb.m * (k.q & mask) < 2^51 */
			if (sh > 20) {
				r = (A + ((B + rhalf) >> 20)) >> (sh - 20);
			} else {
				if ((A >> (41 + sh)) != 0) {    /* A << (20-sh) would exceed 61 */
					goto slow_all;
				}
				r = (A << (20 - sh)) + ((B + rhalf) >> sh);
#if MBP_B76_POISON == 3
				r += r >> 8;
#endif
			}
			if ((r >> 61) != 0) {
				goto slow_all;
			}
#if MBP_B76_POISON == 1
			r += r >> 8;
#endif
			if (r >> 38 > eb) {
				eb = r >> 38;
			}
			if (i < 128) {
				tb[i] = (int64_t)r;
			}
#if MBP_B76_POISON == 2
			tb[256 - i] = -(int64_t)(r + (r >> 8));
#else
			tb[256 - i] = -(int64_t)r;      /* i = 128 lands on tb[128], v = -128 */
#endif
		}
	} else {
		for (i = 0; i < 256; i++) {
			int v = (int8_t)(uint8_t)i;
			uint64_t m = (uint64_t)(v < 0 ? -v : v) * sb.m;
			int64_t t = fx32_apply(m, sb.e, v < 0, k, F, &ok);

			if (!ok) {
				goto slow_all;
			}
			tb[i] = t;
			if ((uint64_t)(t < 0 ? -t : t) >> 38 > eb) {
				eb = (uint64_t)(t < 0 ? -t : t) >> 38;
			}
		}
	}
	}
#else
	for (i = 0; i < 256; i++) {
		int v = (int8_t)(uint8_t)i;
		uint64_t m = (uint64_t)(v < 0 ? -v : v) * sb.m;
		int64_t t = fx32_apply(m, sb.e, v < 0, k, F, &ok);

		if (!ok) {
			goto slow_all;
		}
		tb[i] = t;
		if ((uint64_t)(t < 0 ? -t : t) >> 38 > eb) {
			eb = (uint64_t)(t < 0 ? -t : t) >> 38;
		}
	}
#endif
	eb = 128 * (eb + 2) + 4;
	half = (uint64_t)1 << (F - 1);
	mask = ((uint64_t)1 << F) - 1;
	hi = (int64_t)((uint64_t)(activation_max + 1) << F);
	lo_lim = -(int64_t)((uint64_t)(1 - activation_min) << F);

	for (i = 0; i < n; i++) {
		int64_t x = (int64_t)a[i] * tb[(uint8_t)b[i]];
		uint64_t ax = (uint64_t)(x < 0 ? -x : x);
		uint64_t G = (ax >> 21) + eb;
		int64_t v;

		if (x >= hi) {
			/* x/2^F >= amax + 1 and the float error is < 2^-21 of it: the reference
			 * rounds to at least amax + 1 and clamps. */
			v = activation_max;
		} else if (x <= lo_lim) {
			v = activation_min;
		} else if (G >= half / 2 || (((uint64_t)x & mask) - half + G) <= 2 * G) {
			v = pint_mul_exact(a[i], b[i], sa, sb, so);
		} else {
			v = (x + (int64_t)half) >> F;
		}
		if (v < activation_min) v = activation_min;
		if (v > activation_max) v = activation_max;
		output[i] = (int8_t)v;
	}
	return;

slow_all:
	for (i = 0; i < n; i++) {
		int32_t v = pint_mul_exact(a[i], b[i], sa, sb, so);

		if (v < activation_min) v = activation_min;
		if (v > activation_max) v = activation_max;
		output[i] = (int8_t)v;
	}
}
