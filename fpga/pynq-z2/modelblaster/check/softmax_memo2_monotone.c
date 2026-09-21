/* SPDX-License-Identifier: Apache-2.0
 *   cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw check/softmax_memo2_monotone.c -lm
 */
/* memo2's zero cutoff: out(d) must be nonincreasing in d for EVERY (scale_in, sum, scale_out),
 * and the bisection + cache must reproduce out(d) for every d.  Exhaustive over d in [0,255]
 * on a grid of scale_in x sum x scale_out, including sums of one element (every output
 * nonzero), uniform rows, and rows whose cutoff sits on a tie. */
#include <stdint.h>
#include <stdio.h>
#include <math.h>
#define kernel_softmax_s8 kernel_softmax_s8_memo2
#include "pext_nl_softmax_s8_pext_int_memo2.c"
#undef kernel_softmax_s8
int main(void)
{
    long evals = 0, nonmono = 0, grids = 0, allnz = 0, allz = 0;
    for (int a = 0; a < 2000; a++) {
        float sin_ = (float)exp(log(1e-4) + (log(40.0) - log(1e-4)) * a / 1999.0);
        int32_t im, om; int is, os;
        nl_f2ms(sin_, &im, &is);
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
        uint32_t ex[256];
        for (int d = 0; d < 256; d++) ex[d] = int_exp2_q31((int32_t)nl_scale((int64_t)(-d) << 16, im, is));
        for (int b = 0; b < 100; b++) {
            /* sum from one element at the max (ex[0]) to 512 elements at the max */
            uint64_t sum = (uint64_t)((double)ex[0] * exp(log(512.0) * b / 99.0));
            if (b == 0) sum = ex[0];
            if (sum < ex[0]) sum = ex[0];
            uint64_t inv = UINT64_MAX / sum, q_hi = inv >> 32, q_lo = inv & 0xffffffffull;
            for (int c = 0; c < 20; c++) {
                float sout = c == 0 ? (float)(1.0 / 127.0) : (float)exp(log(1e-3) + (log(2.0) - log(1e-3)) * c / 19.0);
                nl_f2ms_recip(sout, &om, &os);
                int s = os + 32 - 8;
                int8_t prev = 127, first = 0; int nz = 0;
                for (int d = 0; d < 256; d++) {
                    /* the reference expression, as pext_int_row computes it */
                    uint64_t p32r = (uint64_t)(((__uint128_t)ex[d] * inv) >> 32);
                    int8_t ref = nl_q8_to_s8(nl_scale((int64_t)p32r, om, s), -128, 127);
                    int8_t got = smx2_out(ex[d], q_hi, q_lo, om, s);
                    evals++;
                    if (got != ref) { printf("smx2_out != reference: a %d b %d c %d d %d\n", a, b, c, d); return 1; }
                    if (d == 0) first = ref;
                    if (d > 0 && ref > prev) nonmono++;
                    if (ref) nz++;
                    prev = ref;
                }
                if (nz == 256) allnz++;
                if (first == 0) allz++;
                grids++;
            }
        }
    }
    printf("%ld (scale_in, sum, scale_out) points x 256 d = %ld evaluations; smx2_out == reference at all; "
           "non-monotone steps %ld; grids with every d nonzero %ld, with out(0) == 0 %ld\n",
           grids, evals, nonmono, allnz, allz);
    return nonmono != 0;
}
