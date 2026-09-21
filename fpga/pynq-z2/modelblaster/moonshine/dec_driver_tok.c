/* SPDX-License-Identifier: Apache-2.0
 *
 * dec_driver.c with one addition: a sidecar file carrying the per-step argmax VALUE beside
 * its index.  Lab B57 (scripts/74) compares the board's tokens against this driver's, and a
 * token match alone is weaker than it looks -- two different logit vectors can share an
 * argmax.  `val` is the winning int8 code, so a divergence anywhere in the arithmetic moves
 * it even where the chosen index does not.
 *
 * EVERYTHING ELSE IS dec_driver.c, deliberately unchanged: the argmax including its
 * lowest-index tie break, the EOS test, the embedding requantisation and the single forward
 * walk of the dispatch table in which EARLY EXIT IS THE LOOP BOUND.  The board's driver
 * (samples/modelblaster_pext/src/main.c, #if MB_DEC_AR) is a transcription of the same loop,
 * so a difference between the two is a difference in the MACHINE, which is the point.
 *
 * The unmangled aliases (model.h's tail) are used throughout so this file does not name the
 * model; the mangled ones would pin it to moonshine_dec.
 *
 *   dec_driver_tok <inputs.bin> <emb_f32.bin> <tokens_out.bin> <n_utts>
 *
 * writes <tokens_out.bin>          int32 count + int32[N_STEPS] per utterance (dec_driver's
 *                                  format, so model_dec_run.py reads it unchanged)
 *        <tokens_out.bin>.vals     text, one line per step: "u k tok val"
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
    const size_t IN = MODEL_INPUT_SIZE, OUT = MODEL_OUTPUT_SIZE;

    int8_t *inbuf = malloc(IN);
    int8_t *outbuf = malloc(OUT);
    float *emb = malloc((size_t)VOCAB * DHID * sizeof(float));
    if (!inbuf || !outbuf || !emb) { fprintf(stderr, "oom\n"); return 1; }
    FILE *fe = fopen(argv[2], "rb");
    if (!fe || fread(emb, sizeof(float), (size_t)VOCAB * DHID, fe) != (size_t)VOCAB * DHID) {
        fprintf(stderr, "emb read failed\n"); return 1;
    }
    fclose(fe);
    FILE *fi = fopen(argv[1], "rb"), *fo = fopen(argv[3], "wb");
    char vp[4096];
    snprintf(vp, sizeof vp, "%s.vals", argv[3]);
    FILE *fv = fopen(vp, "w");
    if (!fi || !fo || !fv) { fprintf(stderr, "open failed\n"); return 1; }

    for (long u = 0; u < n_utt; u++) {
        if (fread(inbuf, 1, IN, fi) != IN) { fprintf(stderr, "short input %ld\n", u); return 1; }
        model_state_t st = { inbuf, outbuf, NULL };
        model_reset_profile();
        int32_t toks[N_STEPS];
        int n = 0, d = 0;
        for (int k = 0; k < N_STEPS; k++) {
            for (; d <= STEP_END[k]; d++)
                model_dispatch_fns[d](&st);
            const int8_t *lg = outbuf + (size_t)k * VOCAB;
            int best = 0; int8_t bv = lg[0];
            for (int i = 1; i < VOCAB; i++) if (lg[i] > bv) { bv = lg[i]; best = i; }
            fprintf(fv, "%ld %d %d %d\n", u, n, best, (int)bv);
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
        memset(toks + n, 0, (size_t)(N_STEPS - n) * sizeof(int32_t));
        int32_t cnt = n;
        fwrite(&cnt, sizeof(int32_t), 1, fo);
        fwrite(toks, sizeof(int32_t), N_STEPS, fo);
    }
    fclose(fi); fclose(fo); fclose(fv);
    return 0;
}
