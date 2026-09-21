/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_memo_lut */
/* accuracy_class: bit_exact */
/* origin: Lab B28's decoder profile (board/b28_dec_run.json); builder from Lab B67 */
/*
 * cat2_c1_s8 -- the KV-cache append.  17.0 % of the Moonshine decoder at B63c
 * (49,967,860 of 294,618,511 steady cycles, 48.36 cycles/element over 1,033,344 elements
 * in 276 dispatches), second only to linear_s8, and the largest operator in this system
 * that had never had a workstream.
 *
 * WHAT IT IS.  The reference DEQUANTISES EACH INPUT BY ITS OWN SCALE AND REQUANTISES TO
 * scale_out, per element, in soft float --
 *
 *     f = in_i[...] * scales[i];  v = roundf(f / scale_out);  clamp
 *
 * -- so a float multiply, a float divide and a `roundf` per byte moved, on a core with no
 * FPU.  `permute4_s8`'s curated pext_block, which really is a copy, runs at 6.07.
 *
 * Per input tensor this is the SAME 256-entry pointwise map silu_s8 and gelu_s8 are: the
 * output byte depends only on the input byte and on which input it came from.  Two inputs,
 * two tables, at most 512 evaluations for a dispatch that at the decoder's average shape
 * moves 3,744 bytes.  Layout is [N, C, H*W], so each input is ONE CONTIGUOUS RUN in both
 * source and destination.
 *
 * ================================================================================
 * B67: THE BUILDER, AND WHY THE BUILDER IS THE WHOLE OPERATOR
 * ================================================================================
 *
 * Lab B44 (0b97844) put the gather on T4's LUT lane, predicted 15,727,562 cycles saved and
 * MEASURED 647,557 -- 1.3 %, a 24x miss -- because the split is three-way and a lane
 * removes only the GATHER.  Lab B67 measured that split for this operator rather than
 * apportioning it, on spike, at the model's own 552 sides and its own measured D, with the
 * board's compiler and flags (b67_icount):
 *
 *     build      23,539,645 instructions   60.7 %   the float chain, per TABLE ENTRY
 *     marking     6,023,808 instructions   15.5 %   seen[], per ELEMENT
 *     gather      8,031,744 instructions   20.7 %   tbl[], per ELEMENT
 *     per-side    1,194,484 instructions    3.1 %   memset(seen), identity test, prologue
 *     identity      148,448 instructions    0.4 %   the seven memcpy sides
 *     --------------------------------------------------------------------------
 *     total      38,938,129                         measured 38,793,436, +0.37 %
 *
 * against 49,967,860 cycles on silicon: 1.288 cycles per retired instruction for the
 * operator as a whole.
 *
 * THE SPLIT IS SOLVED AND CROSS-CHECKED, not apportioned.  The shipped kernel's
 * instruction count is affine, I(cnt, D) = S + (M + G) * cnt + B * D.  Holding cnt and
 * sweeping D gives B = 303.08 instructions per table entry; holding D and sweeping cnt
 * gives M + G = 14.000 per element; and the one thing a sweep cannot see, their RATIO,
 * comes from the DISASSEMBLY -- the marking inner loop is six instructions (lbu, addi,
 * xori, add, sb, bne) and the gather inner loop is eight (lbu, addi, addi, xori, add, lbu,
 * sb, bne), summing to the 14 the sweep found independently.
 *
 * D IS MEASURED, NOT ASSUMED.  The build is 77,668 entries, NOT 545 x 256, because the
 * shipped kernel marks seen[] first and builds only the values that occur.  Counted on the
 * host build of this decoder, per side: median 132, mean 143, min 63, max 241, and the 286
 * smallest sides average 109.6 (test/b67_sides.h carries all 552).
 *
 * IT DOES NOT SHARE mul_s8's fx32_apply, and that was worth checking rather than assuming:
 * add_s8, mul_s8, rope_s8 and matmul_b_s8 all build fixed-point tables through fexact32.h,
 * and cat2 alone still calls soft float.  So the answer is measured, not argued -- arm
 * `fx32` of b67_icount builds cat2's table the way mul_s8 builds its own: 23,554
 * instructions for 256 entries, 92.0 per entry.  3.3x better than the float chain and
 * 4.9x WORSE than what this file does, because fx32_apply carries an unsigned __int128
 * multiply and an out-of-line __clzdi2 (rv64imac, no Zbb) that this map does not need.
 * The fix was not already written.
 *
 * THE MAP IS LINEAR, WHICH IS THE WHOLE POINT.  tanhf and expf have to be evaluated per
 * entry; here
 *
 *     tbl[v] = clamp(roundf((v - 128) * s_in / s_out))
 *
 * is (v - 128) times ONE loop-invariant ratio.  The shipped builder recomputes that ratio
 * inside the loop -- a soft-float multiply AND a soft-float divide per entry -- when one
 * integer divide per SIDE suffices.  fx32_ratio gives s_in/s_out as (q + theta) * 2^e with
 * q in (2^38, 2^40] and theta in [0, 1) for one 64-bit divide; |k| times that is then an
 * ACCUMULATION, so an entry is an add, a shift, a rounding shift and a clamp with no
 * multiply at all.  Measured: 4,823 instructions for a whole 256-entry table including the
 * divide -- 18.8 per entry, 16.1x cheaper than the float chain.
 *
 * AND THAT IS WHY THE MARKING PASS DIES TOO.  B44's corrected rule says "only a kernel that
 * builds all 256 entries unconditionally removes the MARKING pass", and it was declined
 * then because 256 entries at 303 instructions cost far more than marking saved.  At 18.8
 * they do not: on the model, 545 tables at 4,823 = 2,628,535 instructions replace
 * 23,539,645 of float build PLUS 6,023,808 of marking PLUS 1,194,484 of per-side fixed
 * cost.  So B67 removes the build and the marking together -- the gelu_s8 treatment
 * (13.68x), reached for cat2 by making the builder cheap enough to afford it.
 *
 * MEASURED WHOLE-KERNEL, AT THE MODEL'S OWN 552 SIDES: 38,793,436 retired instructions ->
 * 10,814,288, a 72.1 % cut.  What is left is 74.3 % GATHER, 8 instructions per element,
 * untouched by this change -- and it is the next lever, not a rounding error.
 *
 * ON SILICON (B67, 0x5A5A0028 md5 32d10e5d47, one hold, two arms differing in this file's
 * one define and nothing else -- 10 of the image's 11 kernel bodies byte-identical after
 * preprocessing, max_abs_err 0 on both, host-C goldens byte-identical before the board):
 *
 *     cat2_c1_s8   50,516,540 -> 14,048,039 cycles   -72.19 %
 *                      48.886 ->     13.595 cyc/el   8.06x -> 2.24x permute4_s8's floor
 *     decoder steady  288,099,317 -> 254,165,311     -11.78 %, rtf_steady 2.0887 -> 1.8427
 *
 * AND THE CYCLES TRACK THE INSTRUCTIONS AT A FLAT RATE: 1.3022 cyc/instr before, 1.2990
 * after -- unchanged to 0.25 % across a 72 % instruction cut.  The band's two-term model,
 * which corrected the instruction count downward on the argument that the marking pass's
 * cache misses would transfer to the gather, predicted 32.0 M saved and MISSED HIGH: the
 * measurement is 36.47 M and the uncorrected count would have given 36.04 M.  For a hart-0
 * pointwise kernel whose per-dispatch working set fits L1D, do not make that correction.
 *
 * ================================================================================
 * BIT-EXACT, AND NOT BY ASSERTION
 * ================================================================================
 *
 * A = |k| * (q + theta) * 2^(e+30) is the reference's exact real value times 2^30.  Two
 * error terms, both bounded without a single float operation:
 *
 *   (i)  this kernel's:  |k| * theta * 2^(e+30) plus one truncation unit.  |k| * 2^(e+30)
 *        is A / q <= A / 2^38, so whenever A < 2^38 -- which is exactly the range where the
 *        answer is not a clamp -- the whole term is under 2 units.  The bound is
 *        SELF-LIMITING: it assumes nothing about the scales.
 *   (ii) the REFERENCE's own:  two binary32 roundings, at most 2^-23 * 1.0001 of the value,
 *        which is 2^7 units at A = 2^30 and dominates (i) by four orders of magnitude.
 *
 * G = (A >> 21) + 8 covers both, with a 4x margin on (ii).  If A is further than G from
 * every rounding boundary then the reference and this kernel round to the same integer, and
 * the entry's answer IS the reference's.  Otherwise -- and when A >= 2^38, where the
 * reference's value exceeds 255.9 and every int8 clamp is already decided -- the entry falls
 * back to THE REFERENCE EXPRESSION ITSELF, the same soft float the shipped builder runs.
 * The fallback is not an approximation of the reference; it is the reference.  On the
 * model's own scales it fires for 24 of 278,016 entries, 0.0086 %.
 *
 * The sign is taken out of the table: q(-k) = -q(k) exactly, because IEEE multiply, divide
 * and roundf are all sign-symmetric, so ONE rounding decision fills two entries and the
 * loop runs 129 times for 256 entries.  That symmetry is a claim and the gate tests it
 * rather than trusting it: every comparison is against the unmodified builder over all 256
 * inputs, negatives included.
 *
 * CHECKED OVER THE ENTIRE SHIPPED DOMAIN, not sampled.  kernels/pext_nl/test/b67_cat2_gate
 * compares this kernel byte for byte against -DMBP_CAT2_B67=0 -- the pre-B67 file, term for
 * term -- at the decoder's own 274 distinct (scale0, scale1, scale_out, amin, amax) tuples,
 * every one it ships, across all 256 input bytes through both inputs, plus adversarial
 * tie-heavy ratios, narrow clamps and scales outside fexact32's domain.  1,155,078 bytes
 * over 2,791 shapes, zero mismatches, and the same again under ASan + UBSan.  The input
 * domain of a pointwise int8 map IS 256 values, so this is exhaustion, not a tolerance.
 * (cat2_c1_s8 does not appear in the encoder at all -- checked over every graph.json in
 * out/, not inferred from the name.)
 *
 * THE IDENTITY CASE.  When s_in == scale_out and the clamp is full the map is the identity
 * and the whole input is a memcpy.  Checked in the IR rather than assumed: 7 of 552 sides
 * take it (1.3 % of sides, 2.8 % of elements) and ZERO dispatches have both inputs match.
 *
 * SMALL SIDES.  Below MBP_CAT2_MINN elements a table cannot amortise, and each element
 * takes the same integer evaluation directly with no table at all.  The crossover is 256 by
 * construction -- one entry built per element against 256 built once -- and is MEASURED at
 * 177, because an entry built in the loop is cheaper than one built stand-alone.  THE
 * SHIPPED MODEL NEVER TAKES THAT ROUTE: its smallest side is 288 elements, so the guard is
 * dead code for Moonshine, and the gate's coverage arm forces it at every shape rather than
 * letting a dead path pass a byte-for-byte gate and prove nothing (B66's add_s8 lesson).
 * The pre-B67 kernel's cnt < 64 branch ran the FLOAT chain per element; this one does not,
 * because an integer evaluation is cheaper than a float one at every n.
 *
 * WHAT THIS STILL DOES NOT FIX, and it is the bigger item.  The shapes are
 * C_inputs = [t, 1] with H = 288, W = 1 and t running 1..23 -- the KV-cache append, which
 * RE-COPIES THE WHOLE CACHE EVERY TOKEN.  1,033,344 elements over 276 dispatches, growing
 * linearly, is O(T^2) in the token count for what an append into a preallocated buffer does
 * in O(1).  This kernel makes each copy cheap; it does not stop the copy happening.  That is
 * a lowering change and it is worth more than this kernel is.
 */
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "fexact32.h"

/* B67's integer builder.  -DMBP_CAT2_B67=0 restores the pre-B67 kernel exactly: the float
 * builder, the seen[] marking pass and the cnt < 64 float element loop.  That define is
 * the A/B, and nothing else differs between the two arms. */
#ifndef MBP_CAT2_B67
#define MBP_CAT2_B67 1
#endif
/* Below this many elements a side evaluates each element directly instead of building a
 * 256-entry table.  MEASURED crossover 177 (b67_icount: the table arm is 4,703 + 8n retired
 * instructions, the per-element arm 458 + 32n).  Set just below it, on the side the cycle
 * crossover moves towards: the table arm is load-heavy on a 256-byte table hot in a 16 KB
 * L1D and the per-element arm is multiply-heavy on a core whose mul is multi-cycle, so the
 * crossover in CYCLES is lower than the crossover in instructions. */
#ifndef MBP_CAT2_MINN
#define MBP_CAT2_MINN 176
#endif

#if MBP_CAT2_B67

/* -DFX_STATS (host checks only): how many entries the guard sent to the reference. */
#ifdef FX_STATS
unsigned long pcat_slow_count, pcat_entry_count, pcat_sat_count, pcat_slowside_count;
unsigned long pcat_tbl_sides, pcat_el_sides;
#define PCAT_SLOW()  (pcat_slow_count++)
#define PCAT_SAT()   (pcat_sat_count++)
#define PCAT_ENT(n)  (pcat_entry_count += (unsigned long)(n))
#define PCAT_SIDE()  (pcat_slowside_count++)
#define PCAT_TBL()   (pcat_tbl_sides++)
#define PCAT_EL()    (pcat_el_sides++)
#else
#define PCAT_SLOW()  ((void)0)
#define PCAT_SAT()   ((void)0)
#define PCAT_ENT(n)  ((void)0)
#define PCAT_SIDE()  ((void)0)
#define PCAT_TBL()   ((void)0)
#define PCAT_EL()    ((void)0)
#endif

#define PCAT_F     30                              /* fractional bits of A */
#define PCAT_ONE   ((uint64_t)1 << PCAT_F)
#define PCAT_HALF  ((uint64_t)1 << (PCAT_F - 1))
#define PCAT_SAT_A ((uint64_t)1 << (PCAT_F + 8))   /* |value| >= 256: every clamp decided */

/* s_in / s_out as |k| * q2 >> nsh == |k| * s_in/s_out * 2^30.  ok = 0 means the side must
 * run the reference expression: a scale outside fexact32's domain, a clamp wider than the
 * saturation argument covers, or a ratio so extreme the fixed point cannot hold it. */
typedef struct {
	uint64_t q2;
	int nsh;
	int ok;
} pcat_lin_t;

static pcat_lin_t pcat_lin(float s_in, float s_out, int amin, int amax)
{
	pcat_lin_t L;
	fx32_t si = fx32_dec(s_in), so = fx32_dec(s_out);
	fx32_k_t k;
	int sft;

	L.q2 = 0;
	L.nsh = 0;
	L.ok = 0;
	if (!fx32_scale_ok(si) || !fx32_scale_ok(so)) {
		return L;
	}
	if (amin < -255 || amax > 255) {
		return L;                  /* PCAT_SAT_A's clamp argument needs this */
	}
	k = fx32_ratio(si, so);            /* one 64-bit divide, per side */
	sft = k.e + PCAT_F;
	if (sft > 16 || sft < -63) {
		return L;                  /* |k| * q2 would not fit, or the shift is UB */
	}
	if (sft >= 0) {
		L.q2 = k.q << sft;         /* k.q <= 2^40, sft <= 16, |k| <= 2^7: < 2^63 */
		L.nsh = 0;
	} else {
		L.q2 = k.q;
		L.nsh = -sft;
	}
	L.ok = 1;
	return L;
}

/* The reference expression, term for term and in the same order:
 * roundf(f / scale_out), not a multiply by a reciprocal, because in float those are not
 * the same number. */
static int32_t pcat_ref(int k, float s_in, float s_out)
{
	float f = (float)k * s_in;

	PCAT_SLOW();
	return (int32_t)roundf(f / s_out);
}

/* Round the magnitude A (value * 2^30) to an integer, half away from zero.
 * *st: 0 decided, 1 too close to a rounding boundary to decide, 2 saturating. */
static inline int32_t pcat_round(uint64_t A, int *st)
{
	uint64_t t, f, g;

	if (A >= PCAT_SAT_A) {
		*st = 2;
		PCAT_SAT();
		return 0;
	}
	t = A + PCAT_HALF;
	f = t & (PCAT_ONE - 1);
	g = (A >> 21) + 8;                 /* 4x the reference's 2^-23, plus this kernel's 2 */
	if (f < g || f > PCAT_ONE - g) {
		*st = 1;
		return 0;
	}
	*st = 0;
	return (int32_t)(t >> PCAT_F);
}

/* One entry, sign applied and clamped. */
static inline int32_t pcat_one(int k, uint64_t A,
			       float s_in, float s_out, int amin, int amax)
{
	int st;
	int32_t m = pcat_round(A, &st);
	int32_t q;

	if (st == 0) {
		q = k < 0 ? -m : m;
	} else if (st == 2) {
		q = k < 0 ? amin : amax;   /* |value| >= 255.9; |roundf| >= 256 > 255 */
	} else {
		q = pcat_ref(k, s_in, s_out);
	}
	if (q < amin) q = amin;
	if (q > amax) q = amax;
	return q;
}

/* All 256 entries.  One evaluation fills two, by the sign symmetry of the reference. */
static void pcat_build(int8_t tbl[256], float s_in, float s_out, int amin, int amax)
{
	pcat_lin_t L = pcat_lin(s_in, s_out, amin, amax);
	uint64_t acc = 0;
	int ka;

	PCAT_TBL();
	PCAT_ENT(256);
	if (!L.ok) {
		int v;

		PCAT_SIDE();
		for (v = 0; v < 256; v++) {
			int32_t q = pcat_ref(v - 128, s_in, s_out);

			if (q < amin) q = amin;
			if (q > amax) q = amax;
			tbl[v] = (int8_t)q;
		}
		return;
	}
	/* One rounding decision serves two entries: q(-k) == -q(k) before the clamp. */
	for (ka = 0; ka <= 128; ka++) {
		uint64_t A = acc >> L.nsh;
		int32_t qp, qn;
		int st;
		int32_t m = pcat_round(A, &st);

		if (st == 0) {
			qp = m;
			qn = -m;
		} else if (st == 2) {
			qp = amax;                 /* |value| >= 255.9; |roundf| >= 256 > 255 */
			qn = amin;
		} else {
			qp = pcat_ref(ka, s_in, s_out);
			qn = pcat_ref(-ka, s_in, s_out);
		}
		if (qp < amin) qp = amin;
		if (qp > amax) qp = amax;
		if (qn < amin) qn = amin;
		if (qn > amax) qn = amax;
		if (ka <= 127) {
			tbl[128 + ka] = (int8_t)qp;
		}
		tbl[128 - ka] = (int8_t)qn;
		acc += L.q2;
	}
}

#endif /* MBP_CAT2_B67 */

void kernel_cat2_c1_s8(const int8_t *in0, int c0, float scale0,
                       const int8_t *in1, int c1, float scale1,
                       int8_t *output, int N, int H, int W,
                       float scale_out, int activation_min, int activation_max) {
    const int stride = H * W;
    const int8_t *ins[2] = { in0, in1 };
    const int cs[2] = { c0, c1 };
    const float scales[2] = { scale0, scale1 };
    int8_t tbl[256];
#if !MBP_CAT2_B67
    unsigned char seen[256];
#endif
    int n, i, c, hw;
#if !MBP_CAT2_B67
    int v;
#endif

    for (n = 0; n < N; n++) {
        int out_c = 0;
        for (i = 0; i < 2; i++) {
            const float s_in = scales[i];
            const long cnt = (long)cs[i] * stride;
            const int8_t *src = ins[i] + (long)n * cs[i] * stride;
            int8_t *dst = output + ((long)n * (c0 + c1) + out_c) * stride;

            /* identity: the map is the identity byte for byte, so this is a copy */
            if (s_in == scale_out && activation_min <= -128 && activation_max >= 127) {
                memcpy(dst, src, (size_t)cnt);
                out_c += cs[i];
                continue;
            }
#if MBP_CAT2_B67
            if (cnt < MBP_CAT2_MINN) {
                /* Fewer elements than the table has entries: evaluate each element
                 * directly, through the same integer core and the same fallback. */
                pcat_lin_t L = pcat_lin(s_in, scale_out, activation_min, activation_max);

                PCAT_EL();
                for (c = 0; c < cs[i]; c++) {
                    const int8_t *s = src + (long)c * stride;
                    int8_t *d = dst + (long)c * stride;

                    for (hw = 0; hw < stride; hw++) {
                        int k = s[hw];
                        unsigned ka = (unsigned)(k < 0 ? -k : k);
                        int32_t q;

                        if (L.ok) {
                            q = pcat_one(k, ((uint64_t)ka * L.q2) >> L.nsh,
                                         s_in, scale_out,
                                         activation_min, activation_max);
                        } else {
                            q = pcat_ref(k, s_in, scale_out);
                            if (q < activation_min) q = activation_min;
                            if (q > activation_max) q = activation_max;
                        }
                        d[hw] = (int8_t)q;
                    }
                }
                out_c += cs[i];
                continue;
            }
            /* One table per input, all 256 entries: no seen[] mask, so no marking pass
             * over the elements and no memset.  B44's rule, paid for by a cheap builder. */
            pcat_build(tbl, s_in, scale_out, activation_min, activation_max);
#else
            /* Small input: the table cannot amortise.  On the BOARD the guard is nearly
             * never taken -- E is the reference's ~393 cycles and the lookup ~10, so
             * memoising pays whenever D < n, and the i = 1 side is 288 bytes with D <= 256.
             * On a HOST it is taken often, because an x86 FPU makes E small: the host
             * measures 0.91x at t = 1 and the board will not.  A host ratio is not a board
             * ratio -- the same lesson the LayerNorm hoist taught in the other direction. */
            if (cnt < 64) {
                for (c = 0; c < cs[i]; c++) {
                    const int8_t *s = src + (long)c * stride;
                    int8_t *d = dst + (long)c * stride;
                    for (hw = 0; hw < stride; hw++) {
                        float f = (float)s[hw] * s_in;
                        int32_t q = (int32_t)roundf(f / scale_out);
                        if (q < activation_min) q = activation_min;
                        if (q > activation_max) q = activation_max;
                        d[hw] = (int8_t)q;
                    }
                }
                out_c += cs[i];
                continue;
            }
            /* one table per input, the reference's own expression per entry, and only for
             * the bytes this input actually contains -- the i = 1 side of a KV append is a
             * single 288-byte channel, where 256 unconditional evaluations would not pay. */
            for (v = 0; v < 256; v++) seen[v] = 0;
            for (c = 0; c < cs[i]; c++) {
                const int8_t *s = src + (long)c * stride;
                for (hw = 0; hw < stride; hw++)
                    seen[(unsigned char)((int)s[hw] + 128)] = 1;
            }
            for (v = 0; v < 256; v++) {
                float f;
                int32_t q;
                if (!seen[v]) continue;
                f = (float)(v - 128) * s_in;
                q = (int32_t)roundf(f / scale_out);
                if (q < activation_min) q = activation_min;
                if (q > activation_max) q = activation_max;
                tbl[v] = (int8_t)q;
            }
#endif
            for (c = 0; c < cs[i]; c++) {
                const int8_t *s = src + (long)c * stride;
                int8_t *d = dst + (long)c * stride;
                for (hw = 0; hw < stride; hw++)
                    d[hw] = tbl[(unsigned char)((int)s[hw] + 128)];
            }
            out_c += cs[i];
        }
    }
}
