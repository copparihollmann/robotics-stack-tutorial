/* SPDX-License-Identifier: Apache-2.0
 *
 * groupnorm_s8 pext_int_rsqrt_nhwc (the pixel-outer loop) against pext_int_rsqrt (NCHW):
 * every output byte of the NHWC kernel must equal the NCHW kernel's byte at the permuted
 * index, on random tensors, scales, eps, gamma/beta (with NULL gamma and beta), activation
 * ranges and shapes -- including Moonshine's stem shape (N 1, C 288, H 1, W 999) and a C past
 * PGN_NHWC_MAXC, which takes the channel-outer fallback.  Exit 0 only if every byte matches.
 *
 *   cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw check/groupnorm_nhwc_exact.c -lm
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define kernel_groupnorm_s8 kernel_groupnorm_s8_nchw
#define pgn_f2mss pgn_f2mss_nchw
#define pgn_msmul pgn_msmul_nchw
#include "pext_nl_groupnorm_s8_pext_int_rsqrt.c"
#undef kernel_groupnorm_s8
#undef pgn_f2mss
#undef pgn_msmul
#define kernel_groupnorm_s8 kernel_groupnorm_s8_nhwc
#include "pext_nl_groupnorm_s8_pext_int_rsqrt_nhwc.c"
#undef kernel_groupnorm_s8

static uint64_t rs_ = 88172645463325252ull;
static uint64_t xr(void) { rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17; return rs_; }
static double ur(void) { return (xr() >> 11) * (1.0 / 9007199254740992.0); }
static float rlog(double lo, double hi) { return (float)exp(log(lo) + ur() * (log(hi) - log(lo))); }

int main(void)
{
    long cases = 0, bytes = 0, bad = 0;
    for (int t = 0; t < 3000; t++) {
        int N, C, H, W;
        if (t < 20)            { N = 1; C = 288; H = 1; W = 999; }        /* Moonshine's stem */
        else if (t < 24)       { N = 1; C = PGN_NHWC_MAXC + 1 + (int)(xr() % 8); H = 1; W = 3; }
        else { N = 1 + (int)(xr() % 3); C = 1 + (int)(xr() % 300); H = 1 + (int)(xr() % 4); W = 1 + (int)(xr() % 64); }
        size_t HW = (size_t)H * W, CHW = (size_t)C * HW, tot = (size_t)N * CHW;
        int8_t *xn = malloc(tot), *xc = malloc(tot), *yn = malloc(tot), *yc = malloc(tot), *yp = malloc(tot);
        float *g = malloc(sizeof(float) * C), *b = malloc(sizeof(float) * C);
        int kind = (int)(xr() % 4);   /* input distribution */
        for (size_t i = 0; i < tot; i++) {
            int v = (int)(xr() % 256) - 128;
            if (kind == 1) v = (int)(xr() % 9) - 4;
            if (kind == 2) v = 127;
            if (kind == 3) v = (xr() & 1) ? -128 : 127;
            xn[i] = (int8_t)v;
        }
        for (int n = 0; n < N; n++)       /* NHWC -> NCHW */
            for (size_t p = 0; p < HW; p++)
                for (int c = 0; c < C; c++)
                    xc[((size_t)n * C + c) * HW + p] = xn[((size_t)n * HW + p) * C + c];
        for (int c = 0; c < C; c++) {
            g[c] = rlog(1e-3, 8.0) * ((xr() & 3) == 0 ? -1.0f : 1.0f);
            b[c] = rlog(1e-4, 4.0) * ((xr() & 1) ? -1.0f : 1.0f);
            if ((xr() % 50) == 0) g[c] = 0.0f;
            if ((xr() % 50) == 0) b[c] = 0.0f;
        }
        float si = rlog(1e-4, 2.0), so = rlog(1e-3, 1.0), eps = (xr() & 1) ? 1e-5f : rlog(1e-9, 1e-1);
        int amin = -128, amax = 127;
        if ((xr() % 4) == 0) { amin = (int)(xr() % 128) - 128; amax = amin + (int)(xr() % (128 - amin)); }
        const float *gg = ((xr() % 10) == 0) ? NULL : g, *bb = ((xr() % 10) == 0) ? NULL : b;
        memset(yn, 0x55, tot); memset(yc, 0x33, tot);
        kernel_groupnorm_s8_nchw(xc, gg, bb, yc, N, C, H, W, si, so, eps, amin, amax);
        kernel_groupnorm_s8_nhwc(xn, gg, bb, yn, N, C, H, W, si, so, eps, amin, amax);
        for (int n = 0; n < N; n++)
            for (size_t p = 0; p < HW; p++)
                for (int c = 0; c < C; c++)
                    yp[((size_t)n * HW + p) * C + c] = yc[((size_t)n * C + c) * HW + p];
        for (size_t i = 0; i < tot; i++) if (yp[i] != yn[i]) bad++;
        if (bad && cases < 5) fprintf(stderr, "mismatch at case %d (N%d C%d H%d W%d)\n", t, N, C, H, W);
        cases++; bytes += (long)tot;
        free(xn); free(xc); free(yn); free(yc); free(yp); free(g); free(b);
    }
    printf("groupnorm_nhwc_exact: %ld cases, %ld output bytes, %ld mismatches: %s\n",
           cases, bytes, bad, bad ? "FAIL" : "OK");
    return bad ? 1 : 0;
}
