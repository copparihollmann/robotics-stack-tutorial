/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_memo */
/* accuracy_class: numeric_drift */
/* origin: pext_nl_softmax_s8_pext_int_row.c, with its exponential memoised per dispatch */
/*
 * softmax_s8, BIT-EXACT with pext_int_row, at a fraction of its cycles.
 *
 * pext_int_row computes, for every element and TWICE (once for the row sum, once for the
 * output), 2^z with z = (x - max) * scale_in * log2(e): an nl_scale (a 128-bit multiply and
 * two rounding shifts) and an int_exp2_q31 (a table interpolation with a 64-bit multiply).
 * Measured on Moonshine's encoder (Lab B26): 277 cycles per element, 37 % of the encoder.
 *
 * But the input is int8, so x - max takes one of 256 values (0, -1, ..., -255), and z and
 * 2^z are functions of that difference and of scale_in alone.  scale_in is fixed for the
 * dispatch.  So the exponential is a 256-entry table, filled once per dispatch with the
 * SAME expression pext_int_row evaluates per element, and read back twice per element.
 * Every value that reaches the sum and the output is the value pext_int_row computes:
 * the result is identical to the bit, which is how it is verified (exhaustively over the
 * table, and on random and corner rows against the unmodified kernel).
 *
 * The row reciprocal (2^64 - 1) / sum is the same quotient as pext_int_row's
 * (((unsigned __int128)1 << 64) - 1) / sum; the dividend fits 64 bits, so it is taken with
 * one 64-bit divide instead of a 128-by-64 library call.
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif
void kernel_softmax_s8(const int8_t *input, int8_t *output, int M, int K,
                       float scale_in, float scale_out) {
    int32_t im, om;
    int is, os;
    int m, k;
    uint32_t ex[256];
    nl_f2ms(scale_in, &im, &is);
    nl_f2ms_recip(scale_out, &om, &os);
    {
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
    }
    /* ex[d] = 2^z for x - max = -d: exactly pext_int_row's per-element expression */
    for (k = 0; k < 256; k++) {
        ex[k] = int_exp2_q31((int32_t)nl_scale((int64_t)(-k) << 16, im, is));
    }
    for (m = 0; m < M; m++) {
        const int8_t *x = input + (size_t)m * K;
        int8_t *y = output + (size_t)m * K;
        int32_t mx = x[0];
        uint64_t sum = 0, inv;
        for (k = 1; k < K; k++) if (x[k] > mx) mx = x[k];
        for (k = 0; k < K; k++) sum += ex[mx - x[k]];
        if (!sum) {
            for (k = 0; k < K; k++) y[k] = 0;
            continue;
        }
        inv = UINT64_MAX / sum;
        for (k = 0; k < K; k++) {
            uint32_t ev = ex[mx - x[k]];
            uint64_t p32 = (uint64_t)(((__uint128_t)ev * inv) >> 32);   /* Q0.32 */
            int64_t v_q8 = nl_scale((int64_t)p32, om, os + 32 - 8);
            y[k] = nl_q8_to_s8(v_q8, -128, 127);
        }
    }
}
