/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_memo2 */
/* accuracy_class: numeric_drift */
/* origin: pext_nl_softmax_s8_pext_int_memo.c, with its per-element multiplies priced */
/*
 * softmax_s8, BIT-EXACT with pext_int_row and pext_int_memo, for a core whose multiplier is
 * iterative.
 *
 * pext_int_memo removed pext_int_row's per-element exponential and was measured on the board at
 * 101.7 cycles/element (Lab B26, 0x5A5A0010, from 277.5), not the 30 estimated.  The rest is
 * multiplies: the big Rocket core is MulDivParams(mulUnroll = 8, mulEarlyOut = true), about
 * 8-10 cycles for a full 64-bit mul or mulh, and pext_int_memo pays four per element (the
 * 128-bit ev * inv, the 128-bit product inside nl_scale).  Three things remove them, and none
 * changes a bit of the result:
 *
 *   1. p32 = floor(ev * inv / 2^32) as ev*q_hi + floor(ev*q_lo / 2^32), q = inv split into
 *      halves: exact because ev < 2^31, and two 64-bit mul whose operands fit 32 bits.
 *   2. the output rescale in unsigned 64-bit arithmetic: p32 <= 2^32 (ev <= sum) and the
 *      multiplier < 2^31, so p32 * mult + 2^30 < 2^63 and nl_scale's __int128 never carries.
 *   3. the output is a MONOTONE function of d = max - x within a row (every stage is monotone),
 *      so the largest d with a nonzero output is found once per row by bisection, every
 *      element beyond it is written 0 without arithmetic, and the outputs for d below it are
 *      computed once per distinct d.  On Moonshine's encoder 71.3 % of softmax outputs are 0 and
 *      the per-row cutoff is d = 14 at the median, 26 at p99 (acts.npz, 1.31 M outputs).
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif

/*
 * B66 -- TWO UNGUARDED PER-DISPATCH FIXED COSTS, IN AN OP THAT BOTH HALVES DISPATCH.
 *
 * This kernel is the third instance of the bug B63 found twice, and the only one of the
 * three where the fast path was guarded on NOTHING AT ALL.  Both of its fixed costs were
 * justified -- in this file's own header, above -- with ENCODER statistics.
 *
 *   (A) ex[256] is built at every dispatch: 256 int_exp2_q31 with an nl_scale each.
 *   (B) the d0 bisection runs at every ROW: ~9 smx2_out calls to find the cutoff.
 *
 * B66 GUARDED (A) AND WITHDREW (B).  Only (A) is below; (B) is left exactly as it shipped.
 *
 * MEASURED (test/b66_icount.sh, retired instructions on spike at the board's own flags):
 * the dispatch costs 18,449 + ~250*M + 25.0*M*K.  Against the shapes this graph ships:
 *
 *   encoder    6 dispatches  M=1320 K=165   217,800 el   (A) is 0.34 % -- vacuously free
 *   decoder  144 dispatches  M=8    K=165     1,320 el   (A) is 58 %
 *   decoder  144 dispatches  M=8    K=1..24   8..192 el  (A) is up to 7.4x THE ELEMENT WORK
 *
 * Over the decoder's 288 dispatches that is 5,299,200 instructions of table build against
 * 5,112,000 of element work: THE UNGUARDED FIXED COST MORE THAN DOUBLES THE OP.  At K = 1
 * the bisection performs ~9 evaluations to place a cutoff for a row with one element.
 *
 * THE QUANTITIES.  (A) amortises over the dispatch's ELEMENTS, so the guard is on M*K.
 * (B) amortises over the ROW, so the guard is on K.  They are different quantities and get
 * different tests -- which is the whole lesson, and the reason one master define would have
 * been the wrong shape here.
 *
 * (A) IS BIT-IDENTICAL BY CONSTRUCTION, not by tolerance: a lazily filled entry is the SAME
 * expression evaluated on first use, and ex[d] depends only on d, im and is, all fixed for
 * the dispatch.  The guard is on M*K because that is what the 256 entries amortise over.
 *
 * (B) WAS WITHDRAWN, AND THE REASON IS A PRE-EXISTING SOUNDNESS BUG IN THIS KERNEL THAT ITS
 * GATE SURFACED.  The argument for skipping the bisection was that d0 = 255 writes the same
 * byte, because smx2_out returns 0 for exactly the d the cutoff zeroes -- true if and only
 * if the output is monotone in d, which this file's header asserts ("every stage is
 * monotone").  IT IS NOT, above a scale_in this graph never produces:
 *
 *     ex[d] = int_exp2_q31((int32_t)nl_scale((int64_t)(-d) << 16, im, is))
 *
 * and that cast is to int32.  At scale_in = 155.89, nl_scale(-255 << 16, ...) is
 * -3,758,573,285, which WRAPS to +536,394,011, so ex[255] == ex[0] == 2^31 and ex[] rises
 * again at d = 146.  The bisection then walks into the wrapped region, returns a d0 below
 * the true one, and ZEROES ELEMENTS WHOSE VALUE IS NOT ZERO -- so above roughly
 * scale_in = 2^31 / (255 * log2(e) * 65536) ~ 89 this kernel is NOT bit-exact with
 * pext_int_memo or pext_int_row, which is the claim its own header makes.  The two kernels
 * share the wrap; only this one also cuts off on it.
 *
 * Every softmax_s8 scale_in this graph ships is an activation scale of order 0.01..1, three
 * orders below that, so THE SHIPPED MODEL IS UNAFFECTED -- and nothing in the kernel checks
 * it, and check_moonshine.py cannot find it because it sweeps the scales calibration emits.
 * Left as it shipped rather than fixed here: changing it changes outputs outside the
 * calibrated domain, which is an accuracy-contract decision and not this lab's to take.
 * b66_smx_gate.c's arm c reproduces it in one run.
 *
 * mb_smx2_stats is untouched and keeps its meaning on both sides of the guard: (A) changes
 * only WHEN an ex[] entry is computed, never which rows are cut or which outputs evaluated.
 */
/*
 * DEFAULT OFF, AND THE MEASUREMENT SAYS WHY.  The lazy fill is exact and it is worth 74 % of
 * the dispatch at M=8 K=1 -- but threading its test through the code the EAGER path shares
 * costs +7 to +11 % at every shape, +10.80 % on the encoder's 217,800 elements, measured
 * against MBP_SMX_B66=0 rather than against another configuration of this file:
 *
 *     shape          B66 off      eager       lazy        eager%    lazy%
 *     M=8  K=1        20,140     21,526      5,188        +6.88   -74.24
 *     M=8  K=24       29,217     32,014     26,526        +9.57    -9.21
 *     M=8  K=165      57,550     62,668     71,346        +8.89   +23.97
 *     M=1320 K=165 6,651,616  7,370,157  8,985,542       +10.80   +35.09
 *
 * The encoder's cost in this kernel is NOT the 256-entry build -- that is 18,449 of
 * 6,651,616, 0.28 % -- it is per element and per distinct d, and any conditional on those
 * paths costs more than the build ever did.  A zero-cost eager path therefore needs the row
 * loop DUPLICATED, not a flag threaded through one copy: the body lifted into a helper taking
 * a constant `lazy`, with ex/exv/cache/stamp static as add_s8 keeps ta/tb.  That is a
 * refactor with its own gate and it is left to a lab that can give it a session.
 *
 * WHAT THE NUMBER IS WORTH when that is done: the 144 decoder dispatches at K = 1..24 are
 * ~33 % of decoder softmax_s8 and lazy takes 9..74 % off them, so ~16 % of the op and ~0.6 %
 * of decoder steady.  The 144 at K = 165 must stay eager -- lazy is +24 % there -- which is
 * the same guard-on-the-right-quantity conclusion arrived at by measurement.
 *
 * Turned on with -DMBP_SMX_B66=1.  At 0 this file is the shipped kernel: `eager` folds to a
 * constant 1, every ternary below folds with it, and smx2_ex is not emitted.
 */
#ifndef MBP_SMX_B66
#define MBP_SMX_B66 0
#endif
/* (A) at or above this many elements (M*K) the 256-entry table is built eagerly.
 *
 * MEASURED at M = 8: lazy is -9.21 % at M*K = 192 and +10.68 % at 384, so the arms cross at
 * M*K = 271.  288 is set just above it, which puts the decoder's 144 dispatches at K = 1..24
 * (M*K = 8..192) on the lazy side and its 144 at K = 165 (M*K = 1,320) on the eager side --
 * the split the shapes themselves argue for.  THIS CROSSOVER MUST BE RE-MEASURED once the
 * eager path is properly split, because it was measured with the eager arm carrying the
 * +7..+11 % flag penalty that the split removes; the crossover will move DOWN. */
#ifndef MBP_SMX_MINN
#define MBP_SMX_MINN 288
#endif

/* Counters the board harness prints (samples/modelblaster_pext, weak symbol): the per-row
 * cutoff histogram, so the zero fraction behind memo2's estimate is measured on the board and
 * not only taken from the host's acts.npz.  One increment per row, one per computed output. */
typedef struct {
	uint64_t rows, elements, zero_by_cutoff, exact_evals;
	uint64_t d0_hist[257];                  /* index d0 + 1: 0 means every output of the row is 0 */
} mb_smx2_stats_t;
mb_smx2_stats_t mb_smx2_stats;

/* ex[d] = 2^z for x - max = -d: pext_int_row's per-element expression, memoised.  Filled
 * on first use below the MBP_SMX_MINN guard and all at once above it; the expression is
 * the same one either way, so a lazily filled entry is bit-identical to an eagerly filled
 * one and the two paths cannot disagree. */
static inline uint32_t smx2_ex(uint32_t *ex, uint8_t *exv, int d, int32_t im, int is)
{
	if (!exv[d]) {
		ex[d] = int_exp2_q31((int32_t)nl_scale((int64_t)(-d) << 16, im, is));
		exv[d] = 1;
	}
	return ex[d];
}

/*
 * B76 -- THE REFACTOR B66 ASKED FOR AND DECLINED TO DO, plus the two things it found on
 * the way past.
 *
 * B66 measured the lazy fill at -74.24 % on the decoder's M=8 K=1 dispatch and SHIPPED IT
 * OFF, because threading its test through the one row loop both arms share cost +6.88 to
 * +10.80 % at every shape -- +10.80 % on the encoder's 217,800 elements, which dwarfs
 * anything the decoder's 144 small dispatches can return.  Its own note names the fix:
 * "the row loop DUPLICATED, not a flag threaded through one copy: the body lifted into a
 * helper taking a constant `lazy` ... a refactor with its own gate".  That is smx2_rows
 * below, always_inline and called once per arm, so the eager copy contains no test that
 * the lazy copy needs and vice versa.
 *
 * TWO MORE, both found by counting the build rather than by assuming it:
 *
 *   (1) nl_scale's `__int128` is dead in the table build.  a = -(d << 16) with d <= 255, so
 *       |a| <= 2^24, and mult < 2^31: the product is below 2^55 and cannot use the upper
 *       half.  smx_scale keeps nl_scale itself for anything outside that bound, so the two
 *       spellings agree on the whole domain BY CONSTRUCTION.  This is the same defect
 *       B66 removed from layernorm_s8's LN_XN and did not look for here.
 *
 *   (2) mb_smx2_stats.zero_by_cutoff is incremented PER ELEMENT -- a load, an add and a
 *       store to a global on 71.3 % of all outputs, which is instrumentation on the
 *       element path of a kernel whose element path is the thing being measured.
 *       Accumulated per row and added once; the counter's value is unchanged.
 *
 * WHAT IS NOT TOUCHED: the per-row bisection (B66 withdrew guarding it and the reason --
 * the ex[] wrap above scale_in ~ 89 -- is an accuracy-contract decision, not this lab's),
 * the arithmetic of smx2_out, and every value in ex[], cache[] and the output.
 *
 * -DMBP_B76=1 selects it.  At 0 this file is the shipped kernel, MBP_SMX_B66 and all.
 */
#ifndef MBP_B76
#define MBP_B76 0
#endif
/* (A) re-measured for the SPLIT eager path.  B66's 288 was measured with the eager arm
 * carrying the +7..+11 % flag penalty this refactor removes, and its own note says the
 * crossover "will move DOWN"; test/b76_icount.sh re-measures it and it did:
 *
 *     M = 8      eager (split)   lazy       eager - lazy
 *     K = 20      23,654        21,423       +2,231   lazy wins
 *     K = 24      24,964        24,335         +629   lazy wins
 *     K = 32      27,216        28,525       -1,309   eager wins
 *
 * so the arms cross at M*K = 213, down from 288, and 224 is set just above it.  NO SHAPE
 * EITHER HALF OF THIS GRAPH SHIPS LIES BETWEEN 213 AND 288 -- the decoder's are M*K = 8..192
 * and 1,320, the encoder's 217,800 -- so this number moves nothing on the board and is
 * recorded because the measurement was owed, not because it buys anything. */
#ifndef MBP_B76_SMX_MINN
#define MBP_B76_SMX_MINN 224
#endif
/* LIVE-PATH PROOF:
 *   8  smx_scale's int64 arm (and not the nl_scale fallback beside it)
 *   9  the split EAGER row loop
 *  10  the split LAZY row loop */
#ifndef MBP_B76_POISON
#define MBP_B76_POISON 0
#endif

#if MBP_B76
static inline int64_t smx_scale(int64_t a, int32_t mult, int s)
{
	uint64_t ua = (uint64_t)(a < 0 ? -a : a);
	int64_t p;

	if (s < 0) {
		if (s < -20 || (ua >> 31) != 0) {
			return nl_scale(a, mult, s);
		}
		a <<= -s;
		ua <<= -s;
		s = 0;
	}
	if ((ua >> 31) != 0 || s > 40) {
		return nl_scale(a, mult, s);
	}
	p = (a * (int64_t)mult + ((int64_t)1 << 30)) >> 31;
	if (s > 0) {
		p = (p + ((int64_t)1 << (s - 1))) >> s;
	}
#if MBP_B76_POISON == 8
	p -= 1 << 16;
#endif
	return p;
}
#endif

static inline int8_t smx2_out(uint32_t ev, uint64_t q_hi, uint64_t q_lo, int32_t om, int s)
{
	uint64_t p32 = (uint64_t)ev * q_hi + (((uint64_t)ev * q_lo) >> 32);
	int64_t v_q8;

	if (s >= 0 && s < 62) {
		uint64_t p = (p32 * (uint64_t)(uint32_t)om + (1ull << 30)) >> 31;
		if (s > 0) {
			p = (p + (1ull << (s - 1))) >> s;
		}
		v_q8 = (int64_t)p;
	} else {
		v_q8 = nl_scale((int64_t)p32, om, s);
	}
	return nl_q8_to_s8(v_q8, -128, 127);
}

#if MBP_B76
/* The row loop, ONCE PER ARM.  `lazy` is a constant at both call sites, so the eager copy
 * reads ex[] directly -- instruction for instruction the shipped loop -- and the lazy copy
 * carries the accessor with no flag to test.  This is the whole point of the refactor. */
static inline __attribute__((always_inline)) void
smx2_rows(const int8_t *input, int8_t *output, int M, int K,
	  uint32_t *ex, uint8_t *exv, int8_t *cache, uint16_t *stamp,
	  int32_t im, int is, int32_t om, int s, int lazy)
{
	uint16_t row_id = 0;
	int m, k;

#define SMX_EX(d_) (lazy ? smx2_ex(ex, exv, (d_), im, is) : ex[(d_)])
	for (m = 0; m < M; m++) {
		const int8_t *x = input + (size_t)m * K;
		int8_t *y = output + (size_t)m * K;
		int32_t mx = x[0];
		uint64_t sum = 0, inv, q_hi, q_lo, zc = 0, ev = 0;
		int d0, lo, hi;

		for (k = 1; k < K; k++) if (x[k] > mx) mx = x[k];
		for (k = 0; k < K; k++) sum += SMX_EX(mx - x[k]);
		mb_smx2_stats.rows++;
		mb_smx2_stats.elements += (uint64_t)K;
		if (!sum) {
			for (k = 0; k < K; k++) y[k] = 0;
			mb_smx2_stats.zero_by_cutoff += (uint64_t)K;
			mb_smx2_stats.d0_hist[0]++;
			continue;
		}
		inv = UINT64_MAX / sum;
		q_hi = inv >> 32;
		q_lo = inv & 0xffffffffull;
		if (++row_id == 0) {
			for (k = 0; k < 256; k++) stamp[k] = 0;
			row_id = 1;
		}
		if (smx2_out(SMX_EX(0), q_hi, q_lo, om, s) == 0) {
			d0 = -1;
		} else {
			lo = 0; hi = 255;
			while (lo < hi) {
				int mid = (lo + hi + 1) / 2;

				if (smx2_out(SMX_EX(mid), q_hi, q_lo, om, s) != 0) lo = mid;
				else hi = mid - 1;
			}
			d0 = lo;
		}
		mb_smx2_stats.d0_hist[d0 + 1]++;
		for (k = 0; k < K; k++) {
			int d = mx - x[k];

			if (d > d0) {
				y[k] = 0;
				zc++;
			} else {
				if (stamp[d] != row_id) {
					cache[d] = smx2_out(SMX_EX(d), q_hi, q_lo, om, s);
					stamp[d] = row_id;
					ev++;
				}
				y[k] = cache[d];
			}
		}
#if MBP_B76_POISON == 9
		if (!lazy) y[0] ^= 1;
#endif
#if MBP_B76_POISON == 10
		if (lazy) y[0] ^= 1;
#endif
		mb_smx2_stats.zero_by_cutoff += zc;
		mb_smx2_stats.exact_evals += ev;
	}
#undef SMX_EX
}
#endif /* MBP_B76 */

void kernel_softmax_s8(const int8_t *input, int8_t *output, int M, int K,
                       float scale_in, float scale_out) {
    int32_t im, om;
    int is, os, s;
    int m, k;
#if MBP_B76
    (void)m;
#endif
    uint32_t ex[256];
    /* Declared unconditionally and NOT as a null pointer: at MBP_SMX_B66 = 0 `eager` folds
     * to a constant 1, every smx2_ex call folds away and the array is dead-stored -- but a
     * null `exv` would let the compiler speculate a load from it on the folded branch, which
     * it did, and the gate segfaulted.  256 bytes of dead stack is the cheap, safe spelling. */
    uint8_t exv[256];
    int8_t cache[256];
    uint16_t stamp[256];
    uint16_t row_id = 0;
#if MBP_SMX_B66
    /* (A) on M*K: the elements the 256-entry build amortises over.  (B), the per-row
     * bisection, is NOT guarded -- see the note above for why the guard was withdrawn. */
    const int eager = ((int64_t)M * (int64_t)K) >= MBP_SMX_MINN;
#else
    const int eager = 1;
#endif
    (void)exv;
#if MBP_B76
    (void)eager;
    (void)row_id;
    {
    const int b76_eager = ((int64_t)M * (int64_t)K) >= MBP_B76_SMX_MINN;

    nl_f2ms(scale_in, &im, &is);
    nl_f2ms_recip(scale_out, &om, &os);
    {
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
    }
    for (k = 0; k < 256; k++) stamp[k] = 0;
    s = os + 32 - 8;
    if (b76_eager) {
        /* The 256-entry build, with the 128-bit intermediate gone.  exv[] is NOT zeroed
         * here -- nothing on the eager path reads it. */
        for (k = 0; k < 256; k++)
            ex[k] = int_exp2_q31((int32_t)smx_scale((int64_t)(-k) << 16, im, is));
        smx2_rows(input, output, M, K, ex, exv, cache, stamp, im, is, om, s, 0);
    } else {
        for (k = 0; k < 256; k++) exv[k] = 0;
        smx2_rows(input, output, M, K, ex, exv, cache, stamp, im, is, om, s, 1);
    }
    return;
    }
#else

    nl_f2ms(scale_in, &im, &is);
    nl_f2ms_recip(scale_out, &om, &os);
    {
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
    }
    for (k = 0; k < 256; k++) {
        stamp[k] = 0;
#if MBP_SMX_B66
        exv[k] = 0;
#endif
    }
    if (eager) {
        for (k = 0; k < 256; k++) {
            ex[k] = int_exp2_q31((int32_t)nl_scale((int64_t)(-k) << 16, im, is));
            exv[k] = 1;
        }
    }
    s = os + 32 - 8;
    for (m = 0; m < M; m++) {
        const int8_t *x = input + (size_t)m * K;
        int8_t *y = output + (size_t)m * K;
        int32_t mx = x[0];
        uint64_t sum = 0, inv, q_hi, q_lo;
        int d0, lo, hi;
        for (k = 1; k < K; k++) if (x[k] > mx) mx = x[k];
        /* THE SUM LOOP IS DUPLICATED, and that is the whole cost of the guard.  The lazy
         * accessor's test is two instructions, but this loop is the ONLY per-element site
         * that reads ex[], so leaving one shared copy behind the test puts those two
         * instructions on every element of the encoder's 217,800 as well -- measured at
         * +27.1 % on that dispatch, a regression that no A/B between two configurations of
         * THIS kernel can see, because both arms would carry it.  Above the guard the loop
         * is the shipped loop, instruction for instruction. */
        if (eager) {
            for (k = 0; k < K; k++) sum += ex[mx - x[k]];
        } else {
            for (k = 0; k < K; k++) sum += smx2_ex(ex, exv, mx - x[k], im, is);
        }
        mb_smx2_stats.rows++;
        mb_smx2_stats.elements += (uint64_t)K;
        if (!sum) {
            for (k = 0; k < K; k++) y[k] = 0;
            mb_smx2_stats.zero_by_cutoff += (uint64_t)K;
            mb_smx2_stats.d0_hist[0]++;
            continue;
        }
        inv = UINT64_MAX / sum;
        q_hi = inv >> 32;
        q_lo = inv & 0xffffffffull;
        if (++row_id == 0) {                     /* stamps wrapped: invalidate them all */
            for (k = 0; k < 256; k++) stamp[k] = 0;
            row_id = 1;
        }
        /* d0 = the largest d whose output is nonzero (-1 if none): outputs are monotone in d.
         *
         * B66 PROPOSED SKIPPING THIS AT SMALL K AND WITHDREW IT -- see the note above. */
        if (smx2_out(eager ? ex[0] : smx2_ex(ex, exv, 0, im, is),
                     q_hi, q_lo, om, s) == 0) {
            d0 = -1;
        } else {
            lo = 0; hi = 255;                    /* out(lo) != 0; find the last such d */
            while (lo < hi) {
                int mid = (lo + hi + 1) / 2;
                if (smx2_out(eager ? ex[mid] : smx2_ex(ex, exv, mid, im, is),
                             q_hi, q_lo, om, s) != 0) lo = mid;
                else hi = mid - 1;
            }
            d0 = lo;
        }
        mb_smx2_stats.d0_hist[d0 + 1]++;
        for (k = 0; k < K; k++) {
            int d = mx - x[k];
            if (d > d0) {
                y[k] = 0;
                mb_smx2_stats.zero_by_cutoff++;
            } else {
                if (stamp[d] != row_id) {
                    cache[d] = smx2_out(eager ? ex[d] : smx2_ex(ex, exv, d, im, is),
                                        q_hi, q_lo, om, s);
                    stamp[d] = row_id;
                    mb_smx2_stats.exact_evals++;
                }
                y[k] = cache[d];
            }
        }
    }
#endif
}
