/* SPDX-License-Identifier: Apache-2.0
 *
 * The C side of the softmax lane's testbench, compiled as C with the host checks' flags
 * (run from fpga/pynq-z2/modelblaster):
 *
 *   cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw -c smx_golden.c
 *
 *   smx_golden_kernel  kernel_softmax_s8 of pext_nl_softmax_s8_pext_int_memo2.c, unchanged: THE
 *                      golden.
 *   smx_lane_cfg       the software half of the lane: the table and the two scalars, computed
 *                      line for line as kernel_softmax_s8 computes them.  This is what hart 0
 *                      would run once per dispatch.
 *   smx_golden_table   the kernel's row arithmetic with the table and scalars INJECTED, for
 *                      synthetic tables (arbitrary uint32 entries, arbitrary om, s): once through
 *                      memo2's smx2_out and once through pext_int_memo's __int128 nl_scale form.
 *                      Returns the number of bytes where those two disagree (they must not, for
 *                      om in [0, 2^31)).
 */
#include <stdint.h>
#include <stddef.h>
#include "pext_nl_softmax_s8_pext_int_memo2.c"

void smx_golden_kernel(const int8_t *in, int8_t *out, int M, int K, float scale_in,
                       float scale_out)
{
    kernel_softmax_s8(in, out, M, K, scale_in, scale_out);
}

void smx_lane_cfg(float scale_in, float scale_out, uint32_t ex[256], int32_t *om_out, int *s_out)
{
    int32_t im, om;
    int is, os, k;

    nl_f2ms(scale_in, &im, &is);
    nl_f2ms_recip(scale_out, &om, &os);
    {
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
    }
    for (k = 0; k < 256; k++) {
        ex[k] = int_exp2_q31((int32_t)nl_scale((int64_t)(-k) << 16, im, is));
    }
    *om_out = om;
    *s_out = os + 32 - 8;
}

long smx_golden_table(const int8_t *in, int8_t *out, int M, int K, const uint32_t ex[256],
                      int32_t om, int s)
{
    long disagree = 0;
    int m, k;

    for (m = 0; m < M; m++) {
        const int8_t *x = in + (size_t)m * K;
        int8_t *y = out + (size_t)m * K;
        int32_t mx = x[0];
        uint64_t sum = 0, inv, q_hi, q_lo;

        for (k = 1; k < K; k++) if (x[k] > mx) mx = x[k];
        for (k = 0; k < K; k++) sum += ex[mx - x[k]];
        if (!sum) {
            for (k = 0; k < K; k++) y[k] = 0;
            continue;
        }
        inv = UINT64_MAX / sum;
        q_hi = inv >> 32;
        q_lo = inv & 0xffffffffull;
        for (k = 0; k < K; k++) {
            uint32_t ev = ex[mx - x[k]];
            /* memo2 */
            int8_t a = smx2_out(ev, q_hi, q_lo, om, s);
            /* pext_int_memo */
            uint64_t p32 = (uint64_t)(((__uint128_t)ev * inv) >> 32);
            int8_t b = nl_q8_to_s8(nl_scale((int64_t)p32, om, s), -128, 127);

            y[k] = a;
            if (a != b) disagree++;
        }
    }
    return disagree;
}
