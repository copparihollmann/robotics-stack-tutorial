/* SPDX-License-Identifier: Apache-2.0
 *
 * dec_driver.c + a KEEP MASK on the argmax -- the static lm_head prune, measured on the int8
 * path.  Byte-for-byte the archived driver except that the argmax runs over the kept rows only.
 *
 * Holding s_w and s_out fixed (the pruned checkpoint is a row SUBSET of the existing int8
 * weights, in ascending original-id order) makes every kept row's int8 logit code bit-identical
 * to the unpruned model's, so restricting the argmax IS the pruned model, exactly.
 *
 * INSTRUMENT: compared_steps counts the steps at which an argmax was actually taken.  A run that
 * decodes nothing reports 0 and the scorer refuses it -- a WER over zero comparisons must not be
 * indistinguishable from a good one.
 *
 *   dec_driver_mask <inputs.bin> <emb_f32.bin> <tokens_out.bin> <n_utts> [keep_mask.u8] [stats.txt]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "model.h"
#include "driver_meta.h"

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: %s in emb out n [mask] [stats]\n", argv[0]); return 2; }
    const long n_utt = atol(argv[4]);
    const size_t IN = MODEL_MOONSHINE_DEC_INPUT_SIZE, OUT = MODEL_MOONSHINE_DEC_OUTPUT_SIZE;

    int8_t *inbuf = malloc(IN);
    int8_t *outbuf = malloc(OUT);
    float *emb = malloc((size_t)VOCAB * DHID * sizeof(float));
    uint8_t *keep = malloc(VOCAB);
    long n_kept = 0;
    if (argc >= 6 && strcmp(argv[5], "-")) {
        FILE *fk = fopen(argv[5], "rb");
        if (!fk || fread(keep, 1, VOCAB, fk) != (size_t)VOCAB) {
            fprintf(stderr, "mask read failed: %s\n", argv[5]); return 1;
        }
        fclose(fk);
        for (int i = 0; i < VOCAB; i++) n_kept += (keep[i] != 0);
        if (n_kept == 0) { fprintf(stderr, "empty keep mask -- refusing\n"); return 1; }
        if (!keep[EOS_ID]) { fprintf(stderr, "EOS not in keep mask -- refusing\n"); return 1; }
    } else {
        memset(keep, 1, VOCAB);
        n_kept = VOCAB;
    }
    FILE *fe = fopen(argv[2], "rb");
    if (!fe || fread(emb, sizeof(float), (size_t)VOCAB * DHID, fe) != (size_t)VOCAB * DHID) {
        fprintf(stderr, "emb read failed\n"); return 1;
    }
    fclose(fe);
    FILE *fi = fopen(argv[1], "rb"), *fo = fopen(argv[3], "wb");
    if (!fi || !fo) { fprintf(stderr, "open failed\n"); return 1; }

    long compared_steps = 0, masked_away = 0, utts_done = 0;
    for (long u = 0; u < n_utt; u++) {
        if (fread(inbuf, 1, IN, fi) != IN) { fprintf(stderr, "short input %ld\n", u); return 1; }
        model_moonshine_dec_state_t st = { inbuf, outbuf, NULL };
        model_moonshine_dec_reset_profile();
        int32_t toks[N_STEPS];
        memset(toks, 0, sizeof(toks));
        int n = 0, d = 0;
        for (int k = 0; k < N_STEPS; k++) {
            for (; d <= STEP_END[k]; d++)
                MODEL_MOONSHINE_DEC_DISPATCH_FNS[d](&st);
            const int8_t *lg = outbuf + (size_t)k * VOCAB;
            /* the unmasked argmax, exactly as the archived driver computes it */
            int raw = 0; int8_t rv = lg[0];
            for (int i = 1; i < VOCAB; i++) if (lg[i] > rv) { rv = lg[i]; raw = i; }
            /* the kept argmax: same order, same strict >, so the same lowest-index tie break */
            int best = -1; int8_t bv = 0;
            for (int i = 0; i < VOCAB; i++) {
                if (!keep[i]) continue;
                if (best < 0 || lg[i] > bv) { bv = lg[i]; best = i; }
            }
            compared_steps++;
            if (best != raw) masked_away++;
            toks[n++] = best;
            if (best == EOS_ID) break;
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
        utts_done++;
    }
    fclose(fi); fclose(fo);
    fprintf(stderr, "DRIVER utts=%ld compared_steps=%ld kept_rows=%ld argmax_changed=%ld\n",
            utts_done, compared_steps, n_kept, masked_away);
    if (argc >= 7) {
        FILE *fs = fopen(argv[6], "w");
        if (fs) {
            fprintf(fs, "utts %ld\ncompared_steps %ld\nkept_rows %ld\nargmax_changed %ld\n",
                    utts_done, compared_steps, n_kept, masked_away);
            fclose(fs);
        }
    }
    return 0;
}
