/* SPDX-License-Identifier: Apache-2.0
 *
 * softmax_s8 pext_int_memo and pext_int_memo2 against pext_int_row: exhaustive over the memo
 * table (20,000 scales x 256 differences) and 400,000 random and corner-case dispatches
 * (all-equal rows, one-hot rows, row max at +127 and -128, lengths 1..512; 186 M elements).
 * Exit 0 only if every output byte of both is identical to pext_int_row's.
 * memo2's zero cutoff is checked exhaustively in softmax_memo2_monotone.c.
 *
 *   cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw check/softmax_memo_exact.c -lm
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define kernel_softmax_s8 kernel_softmax_s8_row
#include "pext_nl_softmax_s8_pext_int_row.c"
#undef kernel_softmax_s8
#define kernel_softmax_s8 kernel_softmax_s8_memo
#include "pext_nl_softmax_s8_pext_int_memo.c"
#undef kernel_softmax_s8
#define kernel_softmax_s8 kernel_softmax_s8_memo2
#include "pext_nl_softmax_s8_pext_int_memo2.c"
#undef kernel_softmax_s8

static uint64_t rs = 88172645463325252ull;
static uint64_t xr(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static float rfloat(double lo, double hi) { double u = (xr() >> 11) * (1.0 / 9007199254740992.0); return (float)exp(log(lo) + u * (log(hi) - log(lo))); }

int main(void)
{
    long rows = 0, elems = 0, bad = 0, cases = 0;
    /* (1) exhaustive over the 256 table entries, many scales */
    for (int t = 0; t < 20000; t++) {
        float s = rfloat(1e-5, 30.0);
        int32_t im; int is;
        nl_f2ms(s, &im, &is);
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
        for (int d = 0; d < 256; d++) {
            uint32_t a = int_exp2_q31((int32_t)nl_scale((int64_t)(-d) << 16, im, is));
            /* the per-element form: x - mx with x = mx - d, over every representable mx */
            for (int mx = -128 + d; mx <= 127; mx += 37) {
                int x = mx - d;
                uint32_t b = int_exp2_q31((int32_t)nl_scale((int64_t)(x - mx) << 16, im, is));
                if (a != b) { bad++; }
            }
        }
    }
    printf("table: %ld mismatches over 20000 scales x 256 differences\n", bad);
    /* (2) rows */
    static const int Ks[] = { 1, 2, 3, 7, 36, 165, 512 };
    int8_t in[512 * 8], o1[512 * 8], o2[512 * 8], o3[512 * 8];
    long mism3 = 0;
    long mism = 0;
    for (int t = 0; t < 400000; t++) {
        int K = Ks[xr() % 7], M = 1 + (int)(xr() % 8);
        float sin_ = rfloat(1e-4, 20.0), sout = (xr() % 3 == 0) ? rfloat(1e-3, 1.0) : (float)(1.0 / 127.0);
        int kind = (int)(xr() % 8);
        for (int i = 0; i < M * K; i++) {
            switch (kind) {
            case 0: in[i] = 5; break;                                   /* all equal */
            case 1: in[i] = (i % K == (int)(t % K)) ? 127 : -128; break; /* one-hot, max +127 */
            case 2: in[i] = -128; break;                                /* max at -128 */
            case 3: in[i] = (int8_t)(-128 + (int)(xr() % 3)); break;    /* max near -127 */
            case 4: in[i] = (int8_t)(127 - (int)(xr() % 2)); break;     /* max +127, near-equal */
            default: in[i] = (int8_t)(xr() & 0xff); break;
            }
        }
        kernel_softmax_s8_row(in, o1, M, K, sin_, sout);
        kernel_softmax_s8_memo(in, o2, M, K, sin_, sout);
        if (memcmp(o1, o2, (size_t)(M * K))) mism++;
        kernel_softmax_s8_memo2(in, o3, M, K, sin_, sout);
        if (memcmp(o1, o3, (size_t)(M * K))) mism3++;
        rows += M; elems += M * K; cases++;
    }
    printf("rows: %ld cases, %ld rows, %ld elements, memo %ld / memo2 %ld mismatching cases\n", cases, rows, elems, mism, mism3);
    return (bad || mism || mism3) ? 1 : 0;
}
