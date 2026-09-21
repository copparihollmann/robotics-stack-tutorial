/* SPDX-License-Identifier: Apache-2.0
 *
 * EXHAUSTIVE bit-exactness for the integer batchnorm2d_s8 and add_s8 curated kernels,
 * against ModelBlaster's own float reference expression, on a model's REAL quantisation
 * parameters.
 *
 * WHY EXHAUSTIVE IS POSSIBLE HERE, AND WHY THAT MATTERS.
 *
 *   Both kernels are pointwise maps over int8 inputs with parameters that are fixed for
 *   the dispatch:
 *
 *     batchnorm2d_s8   output[n,c,h,w] = f_c(input[n,c,h,w])     -- one int8 in, one out
 *     add_s8           output[i]       = g(a[i], b[i])           -- two int8 in, one out
 *
 *   So the ENTIRE input domain of one batchnorm channel is 256 values, and of one add
 *   dispatch is 256 x 256 = 65,536 pairs.  Enumerating it is not a stress test that
 *   samples the space, it is a proof over the whole space: if this passes, no input the
 *   model can ever present to these kernels produces a different byte from the reference.
 *   That is a stronger statement than the pipeline's own verify, which draws random
 *   tensors at a handful of shapes.
 *
 *   It is also the RIGHT check for these two kernels specifically, because their general
 *   accuracy class is numeric_drift, not bit_exact -- see PEXT_SPEC.md section 1.5, which
 *   says of the integer rescale-add that it "is not bit-exact against the float
 *   reference; it belongs in NUMERIC_DRIFT", and it is correct.  Folding
 *   scale_a/scale_out into a fixed-point multiplier rounds differently from the
 *   reference's dequantize-then-divide, so SOME parameter set makes SOME input land on
 *   the far side of a rounding boundary.  Measured over random scale triples: 14.3% of
 *   triples drift somewhere, on 0.0005% of their inputs, always by exactly 1 LSB.
 *
 *   Which is why the claim this file checks is deliberately narrow and model-specific:
 *   not "these kernels are bit-exact", but "these kernels are bit-exact ON THIS GRAPH'S
 *   PARAMETERS, over every input that graph can produce".  Re-run it whenever the model
 *   is recalibrated, because recalibration is exactly what could invalidate it.
 *
 * WHAT IS UNDER TEST.  The curated kernel SOURCES THEMSELVES are #included below, with
 * their entry points renamed on the command line, so this exercises the files that ship
 * rather than a transcription of them.  The oracle is KernelSpec.reference_impl, emitted
 * verbatim by the Python driver for the same reason.
 *
 * Driven by check_dronet_integer.py, which generates dronet_params.h from a graph.json
 * and weights.npz.  Do not compile this by hand.
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

#include "dronet_params.h"

/* ModelBlaster's reference_impl, emitted verbatim by the driver, renamed. */
void ref_kernel_batchnorm2d_s8(const int8_t *input, const float *scale,
                               const float *bias, int8_t *output,
                               int N, int C, int H, int W,
                               float scale_in, float scale_out,
                               int activation_min, int activation_max);
void ref_kernel_add_s8(const int8_t *a, const int8_t *b, int8_t *output, int n,
                       float scale_a, float scale_b, float scale_out,
                       int activation_min, int activation_max);

/* The curated kernels under test, renamed by -D on the command line. */
void cur_kernel_batchnorm2d_s8(const int8_t *input, const float *scale,
                               const float *bias, int8_t *output,
                               int N, int C, int H, int W,
                               float scale_in, float scale_out,
                               int activation_min, int activation_max);
void cur_kernel_add_s8(const int8_t *a, const int8_t *b, int8_t *output, int n,
                       float scale_a, float scale_b, float scale_out,
                       int activation_min, int activation_max);

static int8_t in_buf[256], ref_buf[256], cur_buf[256];
static int8_t a_buf[256], b_buf[256], ra_buf[256], ca_buf[256];

int main(void)
{
    long total = 0, bad = 0;
    int worst = 0, failed = 0;

    printf("batchnorm2d_s8 -- every int8 input, every channel, every dispatch\n");
    for (unsigned d = 0; d < sizeof(BNS) / sizeof(BNS[0]); d++) {
        const bn_t *B = &BNS[d];
        long dbad = 0; int dworst = 0, badch = 0;
        for (int c = 0; c < B->C; c++) {
            /* One channel, all 256 inputs, as a 1 x 1 x 1 x 256 tensor so the kernel's
             * own per-channel setup runs exactly as it does in the model. */
            for (int i = 0; i < 256; i++) in_buf[i] = (int8_t)(i - 128);
            ref_kernel_batchnorm2d_s8(in_buf, B->sc + c, B->bi + c, ref_buf,
                                      1, 1, 1, 256, B->scale_in, B->scale_out,
                                      B->amin, B->amax);
            cur_kernel_batchnorm2d_s8(in_buf, B->sc + c, B->bi + c, cur_buf,
                                      1, 1, 1, 256, B->scale_in, B->scale_out,
                                      B->amin, B->amax);
            int cbad = 0;
            for (int i = 0; i < 256; i++) {
                int e = ref_buf[i] - cur_buf[i]; if (e < 0) e = -e;
                total++;
                if (e) { dbad++; bad++; cbad = 1; if (e > dworst) dworst = e; }
            }
            if (cbad) badch++;
        }
        if (dworst > worst) worst = dworst;
        printf("  %-16s C=%3d  cases=%6d  mismatches=%ld  bad_channels=%d  max_abs_err=%d\n",
               B->name, B->C, B->C * 256, dbad, badch, dworst);
        if (dbad) failed = 1;
    }

    printf("add_s8 -- every (a,b) int8 pair, every dispatch\n");
    for (unsigned d = 0; d < sizeof(ADDS) / sizeof(ADDS[0]); d++) {
        const add_t *A = &ADDS[d];
        long dbad = 0; int dworst = 0;
        for (int av = -128; av <= 127; av++) {
            for (int i = 0; i < 256; i++) { a_buf[i] = (int8_t)av; b_buf[i] = (int8_t)(i - 128); }
            ref_kernel_add_s8(a_buf, b_buf, ra_buf, 256, A->sa, A->sb, A->so,
                              A->amin, A->amax);
            cur_kernel_add_s8(a_buf, b_buf, ca_buf, 256, A->sa, A->sb, A->so,
                              A->amin, A->amax);
            for (int i = 0; i < 256; i++) {
                int e = ra_buf[i] - ca_buf[i]; if (e < 0) e = -e;
                total++;
                if (e) { dbad++; bad++; if (e > dworst) dworst = e; }
            }
        }
        if (dworst > worst) worst = dworst;
        printf("  %-16s n=%5d  cases=65536  mismatches=%ld  max_abs_err=%d\n",
               A->name, A->n, dbad, dworst);
        if (dbad) failed = 1;
    }

    printf("\ncases=%ld  mismatches=%ld  max_abs_err=%d\n", total, bad, worst);
    printf("RESULT: %s\n", failed ? "FAIL" : "PASS");
    return failed ? 1 : 0;
}
