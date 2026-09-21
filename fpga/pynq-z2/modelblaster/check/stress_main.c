/* SPDX-License-Identifier: Apache-2.0
 *
 * Bit-exactness stress harness for the MBP curated kernels.
 *
 * ModelBlaster's own host verify (pipeline/verify_kernel.py) is a real check but a
 * narrow one: it calls every quantised kernel with input_offset = filter_offset =
 * output_offset = 0, output_multiplier = 1 << 30, output_shift = 8 and the full
 * [-128, 127] clamp, on a fixed handful of shapes.  None of LeNet's four distinct
 * multipliers, none of its shifts, and -- most importantly -- none of its
 * activation_min = 0 records (ReLU folded into the clamp, which is the path that uses
 * MBP.MAX8 after MBP.CLIP8) are exercised by it at all.
 *
 * This harness sweeps what that one does not:
 *
 *   - every output_shift the exporter can emit, including 0 and negative (the branch
 *     the reference takes with `scaled << -output_shift`), and 31;
 *   - multipliers across the whole normalised Q0.31 band plus the extremes;
 *   - all three clamp shapes: wide, ReLU-folded (activation_min = 0), and an
 *     arbitrary narrow window that neither CLIP8 nor MAX8 can express;
 *   - non-zero input/filter/output offsets, which the kernels must REFUSE and hand to
 *     the reference expression -- if that refusal ever stops working, the answer is
 *     silently wrong, so it is checked rather than assumed;
 *   - deliberately misaligned tensor bases, because ModelBlaster's buffers.c declares
 *     `int8_t buf[N]` with no alignment attribute and Rocket traps on a misaligned
 *     8-byte load rather than emulating it;
 *   - K values in every residue class mod 8 (the linear kernel walks the n loop once
 *     per distinct weight-row misalignment, which is 8/gcd(K,8) classes);
 *   - padded, strided and dilated pooling windows.
 *
 * Two independent checks run at once:
 *
 *   1. NUMERICS.  Every output element must equal the reference's, byte for byte.
 *   2. ALIGNMENT.  MB_PEXT_LD8 / MB_PEXT_ST8 are redefined below to route every
 *      8-byte access through mb_align_check() first.  A kernel that would take a
 *      misaligned-address exception on Rocket fails here on x86, where it otherwise
 *      would not: x86 does misaligned loads happily, so this is the only place the
 *      alignment contract of PEXT_SPEC.md section 6.2 can be tested off-target.
 *
 * Built with -fsanitize=address,undefined by check_bitexact.py, which adds a third:
 * every read stays inside the tensor it belongs to.  That is what catches the one real
 * hazard in the linear kernel -- the last weight row's final 8-byte group, which would
 * otherwise read up to 7 bytes past the end of the weight array.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- alignment instrumentation, installed before the kernels are pulled in ---- */
#include "pext.h"

static unsigned long mb_align_checks;
static unsigned long mb_align_faults;

static void mb_align_check(const void *p)
{
    mb_align_checks++;
    if (((uintptr_t)p & 7u) != 0u) {
        mb_align_faults++;
        fprintf(stderr, "MISALIGNED 8-byte access at %p\n", p);
    }
}

#undef MB_PEXT_LD8
#undef MB_PEXT_ST8
#define MB_PEXT_LD8(p)    (mb_align_check((const void *)(p)), \
                           (*(const mb_pext_i64a *)(const void *)(p)))
#define MB_PEXT_ST8(p, v) (mb_align_check((const void *)(p)), \
                           (void)(*(mb_pext_i64a *)(void *)(p) = (int64_t)(v)))

/* The kernels under test, verbatim.  They #include "pext.h" themselves; the include
 * guard makes that a no-op, so the redefinitions above survive. */
#include "pext_conv2d_s8_pext_patch_dot8.c"
#include "pext_linear_s8_pext_row_dot8.c"
#include "pext_maxpool2d_s8_pext_max8_rows.c"

/* The oracle: ModelBlaster's reference_impl for each op, emitted verbatim by
 * check_bitexact.py straight out of reference_kernels.py into its own translation unit
 * and renamed there with -Dkernel_<op>=ref_kernel_<op>.  A separate TU, not an #include,
 * precisely so the rename cannot touch the kernels under test in this one. */
void ref_kernel_conv2d_s8(const int8_t *input, const int8_t *weight,
                          const int32_t *bias, int8_t *output,
                          int N, int IC, int IH, int IW, int OC,
                          int KH, int KW, int SH, int SW, int PH, int PW,
                          int input_offset, int filter_offset, int output_offset,
                          int output_multiplier, int output_shift,
                          int activation_min, int activation_max);
void ref_kernel_linear_s8(const int8_t *input, const int8_t *weight,
                          const int32_t *bias, int8_t *output,
                          int M, int K, int N,
                          int input_offset, int filter_offset, int output_offset,
                          int output_multiplier, int output_shift,
                          int activation_min, int activation_max);
void ref_kernel_maxpool2d_s8(const int8_t *input, int8_t *output,
                             int N, int C, int IH, int IW,
                             int KH, int KW, int SH, int SW,
                             int PH, int PW, int DH, int DW);

/* ---- a deterministic PRNG, so a failure is reproducible from its seed ---- */
static uint64_t rs;
static uint32_t rnd32(void)
{
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return (uint32_t)(rs >> 32);
}
static int rnd_range(int lo, int hi) /* inclusive */
{
    return lo + (int)(rnd32() % (uint32_t)(hi - lo + 1));
}
static int8_t rnd_i8(void) { return (int8_t)(rnd32() & 0xff); }

/* Every buffer is over-allocated by 8 so a case can start it at any of the eight
 * byte offsets and exercise the kernels' alignment handling. */
#define SLACK 8

static long cases_run;
static long mismatches;
static long fastpath_refusals;

static const int mults[] = {
    1073741824, 1093035259, 1282547664, 1384681622, 1594199196,
    2074957671, 2147483647, 1, -1073741824, -2147483647,
};
static const int shifts[] = { -2, -1, 0, 1, 2, 6, 7, 8, 9, 10, 31 };

struct clampcase { int lo, hi; };
static const struct clampcase clamps[] = {
    { -128, 127 },   /* wide: CLIP8 alone */
    { 0, 127 },      /* ReLU folded: CLIP8 then MAX8 against x0 */
    { -50, 50 },     /* neither: CLIP8 then a scalar narrowing */
    { -128, 0 },
};

static int report(const char *what, const int8_t *a, const int8_t *b, size_t n,
                  const char *detail)
{
    size_t i;
    for (i = 0; i < n; i++) {
        if (a[i] != b[i]) {
            mismatches++;
            fprintf(stderr,
                    "MISMATCH %s at element %zu: ref=%d pext=%d  [%s]\n",
                    what, i, (int)a[i], (int)b[i], detail);
            return 1;
        }
    }
    return 0;
}

static void conv_case(int N, int IC, int IH, int IW, int OC,
                      int KH, int KW, int SH, int SW, int PH, int PW,
                      int io, int fo, int oo, int mult, int shift,
                      int amin, int amax, int align_in, int align_w, int align_out)
{
    const int OH = (IH + 2*PH - KH) / SH + 1;
    const int OW = (IW + 2*PW - KW) / SW + 1;
    size_t isz, wsz, osz;
    int8_t *ibuf, *wbuf, *obuf_r, *obuf_p;
    const int8_t *in, *w;
    int8_t *out_r, *out_p;
    int32_t *bias;
    size_t i;
    char detail[256];

    if (OH <= 0 || OW <= 0) return;
    isz = (size_t)N * IC * IH * IW;
    wsz = (size_t)OC * IC * KH * KW;
    osz = (size_t)N * OC * OH * OW;

    ibuf = malloc(isz + SLACK); wbuf = malloc(wsz + SLACK);
    obuf_r = malloc(osz + SLACK); obuf_p = malloc(osz + SLACK);
    bias = malloc(sizeof(int32_t) * (size_t)OC);
    if (!ibuf || !wbuf || !obuf_r || !obuf_p || !bias) exit(2);

    in = ibuf + align_in; w = wbuf + align_w;
    out_r = obuf_r + align_out; out_p = obuf_p + align_out;
    for (i = 0; i < isz; i++) ibuf[align_in + i] = rnd_i8();
    for (i = 0; i < wsz; i++) wbuf[align_w + i] = rnd_i8();
    for (i = 0; i < (size_t)OC; i++) bias[i] = (int32_t)rnd32() % 100000 - 50000;
    memset(obuf_r, 0, osz + SLACK);
    memset(obuf_p, 0, osz + SLACK);

    ref_kernel_conv2d_s8(in, w, bias, out_r, N, IC, IH, IW, OC,
                         KH, KW, SH, SW, PH, PW, io, fo, oo, mult, shift,
                         amin, amax);
    kernel_conv2d_s8(in, w, bias, out_p, N, IC, IH, IW, OC,
                     KH, KW, SH, SW, PH, PW, io, fo, oo, mult, shift,
                     amin, amax);

    snprintf(detail, sizeof detail,
             "conv N%d IC%d %dx%d OC%d K%dx%d S%dx%d P%dx%d off(%d,%d,%d) "
             "m%d s%d clamp[%d,%d] align(%d,%d,%d)",
             N, IC, IH, IW, OC, KH, KW, SH, SW, PH, PW, io, fo, oo,
             mult, shift, amin, amax, align_in, align_w, align_out);
    report("conv2d_s8", out_r, out_p, osz, detail);
    if (io != 0 || fo != 0) fastpath_refusals++;
    cases_run++;

    free(ibuf); free(wbuf); free(obuf_r); free(obuf_p); free(bias);
}

static void linear_case(int M, int K, int N, int io, int fo, int oo,
                        int mult, int shift, int amin, int amax,
                        int align_in, int align_w, int align_out)
{
    size_t isz = (size_t)M * K, wsz = (size_t)N * K, osz = (size_t)M * N;
    int8_t *ibuf = malloc(isz + SLACK), *wbuf = malloc(wsz + SLACK);
    int8_t *obuf_r = malloc(osz + SLACK), *obuf_p = malloc(osz + SLACK);
    int32_t *bias = malloc(sizeof(int32_t) * (size_t)N);
    const int8_t *in, *w;
    int8_t *out_r, *out_p;
    size_t i;
    char detail[256];

    if (!ibuf || !wbuf || !obuf_r || !obuf_p || !bias) exit(2);
    in = ibuf + align_in; w = wbuf + align_w;
    out_r = obuf_r + align_out; out_p = obuf_p + align_out;
    for (i = 0; i < isz; i++) ibuf[align_in + i] = rnd_i8();
    for (i = 0; i < wsz; i++) wbuf[align_w + i] = rnd_i8();
    for (i = 0; i < (size_t)N; i++) bias[i] = (int32_t)rnd32() % 100000 - 50000;
    memset(obuf_r, 0, osz + SLACK);
    memset(obuf_p, 0, osz + SLACK);

    ref_kernel_linear_s8(in, w, bias, out_r, M, K, N, io, fo, oo,
                         mult, shift, amin, amax);
    kernel_linear_s8(in, w, bias, out_p, M, K, N, io, fo, oo,
                     mult, shift, amin, amax);

    snprintf(detail, sizeof detail,
             "linear M%d K%d N%d off(%d,%d,%d) m%d s%d clamp[%d,%d] align(%d,%d,%d)",
             M, K, N, io, fo, oo, mult, shift, amin, amax,
             align_in, align_w, align_out);
    report("linear_s8", out_r, out_p, osz, detail);
    if (io != 0 || fo != 0) fastpath_refusals++;
    cases_run++;

    free(ibuf); free(wbuf); free(obuf_r); free(obuf_p); free(bias);
}

static void pool_case(int N, int C, int IH, int IW,
                      int KH, int KW, int SH, int SW, int PH, int PW,
                      int DH, int DW, int align_in, int align_out)
{
    const int OH = (IH + 2*PH - DH*(KH-1) - 1) / SH + 1;
    const int OW = (IW + 2*PW - DW*(KW-1) - 1) / SW + 1;
    size_t isz, osz;
    int8_t *ibuf, *obuf_r, *obuf_p;
    const int8_t *in;
    int8_t *out_r, *out_p;
    size_t i;
    char detail[256];

    if (OH <= 0 || OW <= 0) return;
    isz = (size_t)N * C * IH * IW;
    osz = (size_t)N * C * OH * OW;
    ibuf = malloc(isz + SLACK);
    obuf_r = malloc(osz + SLACK); obuf_p = malloc(osz + SLACK);
    if (!ibuf || !obuf_r || !obuf_p) exit(2);
    in = ibuf + align_in;
    out_r = obuf_r + align_out; out_p = obuf_p + align_out;
    for (i = 0; i < isz; i++) ibuf[align_in + i] = rnd_i8();
    memset(obuf_r, 0, osz + SLACK);
    memset(obuf_p, 0, osz + SLACK);

    ref_kernel_maxpool2d_s8(in, out_r, N, C, IH, IW, KH, KW, SH, SW,
                            PH, PW, DH, DW);
    kernel_maxpool2d_s8(in, out_p, N, C, IH, IW, KH, KW, SH, SW,
                        PH, PW, DH, DW);

    snprintf(detail, sizeof detail,
             "pool N%d C%d %dx%d K%dx%d S%dx%d P%dx%d D%dx%d align(%d,%d)",
             N, C, IH, IW, KH, KW, SH, SW, PH, PW, DH, DW,
             align_in, align_out);
    report("maxpool2d_s8", out_r, out_p, osz, detail);
    cases_run++;

    free(ibuf); free(obuf_r); free(obuf_p);
}

int main(int argc, char **argv)
{
    int iters = (argc > 1) ? atoi(argv[1]) : 300;
    int seed  = (argc > 2) ? atoi(argv[2]) : 1;
    int i, mi, si, ci, a;

    rs = 0x9e3779b97f4a7c15ULL ^ (uint64_t)seed;

    /* --- LeNet's own dispatches, with their real quant parameters --------- */
    /* conv1: 1x28x28 -> 6, k5, m=1282547664 s=8, ReLU folded (amin=0) */
    for (a = 0; a < 8; a++)
        conv_case(1, 1, 28, 28, 6, 5, 5, 1, 1, 0, 0, 0, 0, 0,
                  1282547664, 8, 0, 127, a, (a * 3) & 7, (a * 5) & 7);
    /* conv2: 6x12x12 -> 16, k5, m=1077058462 s=9, ReLU folded */
    for (a = 0; a < 8; a++)
        conv_case(1, 6, 12, 12, 16, 5, 5, 1, 1, 0, 0, 0, 0, 0,
                  1077058462, 9, 0, 127, a, (a * 3) & 7, (a * 5) & 7);
    /* fc1 / fc2 / fc3 */
    for (a = 0; a < 8; a++) {
        linear_case(1, 256, 120, 0, 0, 0, 1280059294, 9, 0, 127,
                    a, (a * 3) & 7, (a * 5) & 7);
        linear_case(1, 120, 84, 0, 0, 0, 1384681622, 9, 0, 127,
                    a, (a * 3) & 7, (a * 5) & 7);
        linear_case(1, 84, 10, 0, 0, 0, 1594199196, 9, -128, 127,
                    a, (a * 3) & 7, (a * 5) & 7);
    }
    /* pool1 / pool2 */
    for (a = 0; a < 8; a++) {
        pool_case(1, 6, 24, 24, 2, 2, 2, 2, 0, 0, 1, 1, a, (a * 3) & 7);
        pool_case(1, 16, 8, 8, 2, 2, 2, 2, 0, 0, 1, 1, a, (a * 3) & 7);
    }

    /* --- DroNet's shapes, which is where the extension was actually sized -- */
    conv_case(1, 3, 112, 112, 32, 3, 3, 2, 2, 1, 1, 0, 0, 0,
              1093035259, 10, 0, 127, 0, 0, 0);
    conv_case(1, 32, 27, 27, 32, 3, 3, 2, 2, 1, 1, 0, 0, 0,
              2074957671, 7, 0, 127, 0, 0, 0);
    conv_case(1, 32, 14, 14, 32, 3, 3, 1, 1, 1, 1, 0, 0, 0,
              1500000000, 6, -128, 127, 0, 0, 0);
    conv_case(1, 64, 7, 7, 128, 3, 3, 2, 2, 1, 1, 0, 0, 0,
              1900000000, 8, 0, 127, 0, 0, 0);
    conv_case(1, 32, 14, 14, 64, 1, 1, 2, 2, 0, 0, 0, 0, 0,
              1200000000, 2, -128, 127, 0, 0, 0);
    linear_case(1, 2048, 1, 0, 0, 0, 1700000000, 7, -128, 127, 0, 0, 0);
    pool_case(1, 32, 56, 56, 3, 3, 2, 2, 0, 0, 1, 1, 0, 0);

    /* --- every multiplier x shift x clamp combination, on a small conv ----- */
    for (mi = 0; mi < (int)(sizeof mults / sizeof mults[0]); mi++)
        for (si = 0; si < (int)(sizeof shifts / sizeof shifts[0]); si++)
            for (ci = 0; ci < (int)(sizeof clamps / sizeof clamps[0]); ci++) {
                conv_case(1, 3, 7, 7, 5, 3, 3, 1, 1, 1, 1, 0, 0, 0,
                          mults[mi], shifts[si], clamps[ci].lo, clamps[ci].hi,
                          0, 0, 0);
                linear_case(1, 37, 9, 0, 0, 0, mults[mi], shifts[si],
                            clamps[ci].lo, clamps[ci].hi, 0, 0, 0);
            }

    /* --- non-zero zero points: the kernels must REFUSE and hand off -------- */
    for (i = 0; i < 24; i++) {
        int io = rnd_range(-128, 127), fo = rnd_range(-128, 127);
        int oo = rnd_range(-20, 20);
        conv_case(1, 2, 9, 9, 4, 3, 3, 1, 1, 1, 1, io, fo, oo,
                  1500000000, 8, rnd_range(-128, -100), rnd_range(100, 127),
                  0, 0, 0);
        linear_case(1, 23, 7, io, fo, oo, 1500000000, 8, -128, 127, 0, 0, 0);
    }
    /* output_offset alone stays on the fast path: it is added before the clamp,
     * exactly where the reference adds it. */
    for (i = -8; i <= 8; i++) {
        conv_case(1, 2, 9, 9, 4, 3, 3, 1, 1, 1, 1, 0, 0, i,
                  1500000000, 8, -128, 127, 0, 0, 0);
        linear_case(1, 23, 7, 0, 0, i, 1500000000, 8, 0, 127, 0, 0, 0);
    }

    /* --- K in every residue class mod 8, every N parity -------------------- */
    for (i = 1; i <= 40; i++)
        for (a = 0; a < 8; a++)
            linear_case(1 + (i & 1), i, 1 + (i % 7), 0, 0, 0,
                        1400000000, 9, (i & 2) ? 0 : -128, 127,
                        a, (a * 3) & 7, 0);

    /* --- random sweep ------------------------------------------------------ */
    for (i = 0; i < iters; i++) {
        int IC = rnd_range(1, 12), IH = rnd_range(3, 14), IW = rnd_range(3, 14);
        int OC = rnd_range(1, 9);
        int KH = rnd_range(1, 3), KW = rnd_range(1, 3);
        int SH = rnd_range(1, 2), SW = rnd_range(1, 2);
        int PH = rnd_range(0, 1), PW = rnd_range(0, 1);
        int ci2 = (int)(rnd32() % 4), mi2 = (int)(rnd32() % 10),
            si2 = (int)(rnd32() % 11);
        if (KH > IH + 2*PH || KW > IW + 2*PW) continue;
        conv_case(1, IC, IH, IW, OC, KH, KW, SH, SW, PH, PW, 0, 0, 0,
                  mults[mi2], shifts[si2], clamps[ci2].lo, clamps[ci2].hi,
                  (int)(rnd32() & 7), (int)(rnd32() & 7), (int)(rnd32() & 7));
        linear_case(rnd_range(1, 3), rnd_range(1, 300), rnd_range(1, 40),
                    0, 0, 0, mults[mi2], shifts[si2],
                    clamps[ci2].lo, clamps[ci2].hi,
                    (int)(rnd32() & 7), (int)(rnd32() & 7), (int)(rnd32() & 7));
        {
            int C = rnd_range(1, 6);
            int PIH = rnd_range(3, 20), PIW = rnd_range(3, 20);
            int PKH = rnd_range(1, 3), PKW = rnd_range(1, 3);
            int PSH = rnd_range(1, 3), PSW = rnd_range(1, 3);
            int PPH = rnd_range(0, 1), PPW = rnd_range(0, 1);
            int PDH = rnd_range(1, 2), PDW = rnd_range(1, 2);
            if (PDH*(PKH-1) + 1 > PIH + 2*PPH) PDH = 1;
            if (PDW*(PKW-1) + 1 > PIW + 2*PPW) PDW = 1;
            if (PDH*(PKH-1) + 1 > PIH + 2*PPH) continue;
            if (PDW*(PKW-1) + 1 > PIW + 2*PPW) continue;
            if (PPH > PKH / 2 || PPW > PKW / 2) { PPH = 0; PPW = 0; }
            pool_case(1, C, PIH, PIW, PKH, PKW, PSH, PSW, PPH, PPW, PDH, PDW,
                      (int)(rnd32() & 7), (int)(rnd32() & 7));
        }
    }

    printf("cases=%ld  mismatches=%ld  fastpath_refusals=%ld  "
           "aligned8_accesses=%lu  misaligned=%lu\n",
           cases_run, mismatches, fastpath_refusals,
           mb_align_checks, mb_align_faults);
    if (mismatches || mb_align_faults) {
        printf("FAIL\n");
        return 1;
    }
    printf("PASS -- every output element identical, max_abs_err=0, "
           "and every 8-byte access 8-byte aligned\n");
    return 0;
}
