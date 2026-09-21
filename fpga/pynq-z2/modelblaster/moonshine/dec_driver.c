/* SPDX-License-Identifier: Apache-2.0
 *
 * The autoregressive driver for the unrolled int8 decoder -- MOONSHINE_MODEL.md section 5.
 *
 * Everything data-dependent lives HERE, not in the graph: argmax over the step's logits, the
 * embedding row copy into the next step's input, and EOS as the bound on the dispatch table.
 * The generated model contributes MODEL_<MID>_DISPATCH_FNS[], one function pointer per dispatch,
 * and file-static intermediate buffers that outlive a dispatch -- which is the whole reason a
 * loop needs no codegen feature.
 *
 * EARLY EXIT IS THE LOOP BOUND.  We walk dispatches 0..STEP_END[k] for step k and simply stop,
 * so a sequence that ends at token 9 costs 9 steps and not 24.
 *
 *   dec_driver <inputs.bin> <emb_f32.bin> <tokens_out.bin> <n_utts>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "model.h"
#include "driver_meta.h"

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: %s in emb out n\n", argv[0]); return 2; }
    const long n_utt = atol(argv[4]);
    const size_t IN = MODEL_MOONSHINE_DEC_INPUT_SIZE, OUT = MODEL_MOONSHINE_DEC_OUTPUT_SIZE;

    int8_t *inbuf = malloc(IN);
    int8_t *outbuf = malloc(OUT);
    float *emb = malloc((size_t)VOCAB * DHID * sizeof(float));
    FILE *fe = fopen(argv[2], "rb");
    if (!fe || fread(emb, sizeof(float), (size_t)VOCAB * DHID, fe) != (size_t)VOCAB * DHID) {
        fprintf(stderr, "emb read failed\n"); return 1;
    }
    fclose(fe);
    FILE *fi = fopen(argv[1], "rb"), *fo = fopen(argv[3], "wb");
    if (!fi || !fo) { fprintf(stderr, "open failed\n"); return 1; }

    for (long u = 0; u < n_utt; u++) {
        if (fread(inbuf, 1, IN, fi) != IN) { fprintf(stderr, "short input %ld\n", u); return 1; }
        model_moonshine_dec_state_t st = { inbuf, outbuf, NULL };
        model_moonshine_dec_reset_profile();
        int32_t toks[N_STEPS];
        memset(toks, 0, sizeof(toks));   /* slots past the count are written out; do not emit stack garbage */
        int n = 0, d = 0;
        for (int k = 0; k < N_STEPS; k++) {
            for (; d <= STEP_END[k]; d++)
                MODEL_MOONSHINE_DEC_DISPATCH_FNS[d](&st);
            /* argmax on the int8 codes: one output tensor, one scale, so the code order IS the
             * value order.  Ties are broken by lowest index, which is deterministic and is what
             * the host reference does. */
            const int8_t *lg = outbuf + (size_t)k * VOCAB;
            int best = 0; int8_t bv = lg[0];
            for (int i = 1; i < VOCAB; i++) if (lg[i] > bv) { bv = lg[i]; best = i; }
            toks[n++] = best;
            if (best == EOS_ID) break;              /* EARLY EXIT: the loop bound */
            if (k + 1 < N_STEPS) {
                const float s = H_SCALE[k + 1];
                int8_t *dst = inbuf + H_OFF[k + 1];
                const float *row = emb + (size_t)best * DHID;
                for (int j = 0; j < DHID; j++) {
                    float q = row[j] / s;
                    int v = (int)(q < 0 ? q - 0.5f : q + 0.5f);
                    dst[j] = (int8_t)(v > 127 ? 127 : (v < -127 ? -127 : v));
                }
            }
        }
        int32_t cnt = n;
        fwrite(&cnt, sizeof(int32_t), 1, fo);
        fwrite(toks, sizeof(int32_t), N_STEPS, fo);
    }
    fclose(fi); fclose(fo);
    return 0;
}
