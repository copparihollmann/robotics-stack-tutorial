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

/* Counters the board harness prints (samples/modelblaster_pext, weak symbol): the per-row
 * cutoff histogram, so the zero fraction behind memo2's estimate is measured on the board and
 * not only taken from the host's acts.npz.  One increment per row, one per computed output. */
typedef struct {
	uint64_t rows, elements, zero_by_cutoff, exact_evals;
	uint64_t d0_hist[257];                  /* index d0 + 1: 0 means every output of the row is 0 */
} mb_smx2_stats_t;
mb_smx2_stats_t mb_smx2_stats;

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

void kernel_softmax_s8(const int8_t *input, int8_t *output, int M, int K,
                       float scale_in, float scale_out) {
    int32_t im, om;
    int is, os, s;
    int m, k;
    uint32_t ex[256];
    int8_t cache[256];
    uint16_t stamp[256];
    uint16_t row_id = 0;
    nl_f2ms(scale_in, &im, &is);
    nl_f2ms_recip(scale_out, &om, &os);
    {
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
    }
    for (k = 0; k < 256; k++) {
        ex[k] = int_exp2_q31((int32_t)nl_scale((int64_t)(-k) << 16, im, is));
        stamp[k] = 0;
    }
    s = os + 32 - 8;
    for (m = 0; m < M; m++) {
        const int8_t *x = input + (size_t)m * K;
        int8_t *y = output + (size_t)m * K;
        int32_t mx = x[0];
        uint64_t sum = 0, inv, q_hi, q_lo;
        int d0, lo, hi;
        for (k = 1; k < K; k++) if (x[k] > mx) mx = x[k];
        for (k = 0; k < K; k++) sum += ex[mx - x[k]];
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
        /* d0 = the largest d whose output is nonzero (-1 if none): outputs are monotone in d */
        if (smx2_out(ex[0], q_hi, q_lo, om, s) == 0) {
            d0 = -1;
        } else {
            lo = 0; hi = 255;                    /* out(lo) != 0; find the last such d */
            while (lo < hi) {
                int mid = (lo + hi + 1) / 2;
                if (smx2_out(ex[mid], q_hi, q_lo, om, s) != 0) lo = mid;
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
                    cache[d] = smx2_out(ex[d], q_hi, q_lo, om, s);
                    stamp[d] = row_id;
                    mb_smx2_stats.exact_evals++;
                }
                y[k] = cache[d];
            }
        }
    }
}
