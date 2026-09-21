/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_memo_lut */
/* accuracy_class: bit_exact */
/* origin: the same argument as pext/pext_gelu_s8_pext_memo_lut.c, measured by Lab B28's
 *         decoder profile (board/b28_dec_run.json) */
/*
 * silu_s8 -- and the reason it is 30.19 % of a Moonshine decoder is that the reference
 * evaluates a FLOAT SIGMOID PER ELEMENT on a core with no FPU.  `expf`, a float divide and
 * `roundf`, all in soft-float, measured at 2,800.23 cycles/element over 144 dispatches of
 * 1,152 elements (Lab B28, 0x5A5A0028, 34.482759 MHz, decoder, in-model per-kind).
 *
 * WHAT IT NOTICES.  With per-tensor symmetric quantisation and zero_point 0 this is a
 * pointwise map from 256 input bytes to 256 output bytes, exactly as gelu_s8 is.  For one
 * (scale_in, scale_out, clamp) there are at most 256 distinct outputs, so evaluating the
 * sigmoid once per ELEMENT is never necessary.
 *
 * BIT-EXACT BY CONSTRUCTION.  Every table entry is the reference's own expression, in
 * float32, with the same `expf`, the same divide and the same `roundf`.  No other
 * arithmetic exists in this kernel, so there is no rounding mode to match -- the table is
 * the reference, memoised.
 *
 * ONE MARKING PASS.  A quantised activation repeats values heavily, so the fill is
 * distinct * E, not 256 * E.  Below the small-n guard the reference runs per element,
 * because the marking array costs more than it saves there.
 *
 * WHAT THIS IS WORTH, AND WHERE -- PRICED AT THE DISPATCH SIZE IT WILL SEE, because this
 * kernel's sibling advertised an encoder rate that a decoder never reaches:
 *
 *   The fill is `D * E` with E the cost of ONE reference evaluation, which IS the
 *   reference's own 2,800 c/el.  The lookup is a byte load, ~8 c/el.  So at a decoder's
 *   n = 1,152:
 *
 *      D = 256   ->  (256*2800 + 1152*8) / 1152  =  ~630 c/el     4.4x
 *      D = 128   ->  (128*2800 + 1152*8)  / 1152 =  ~319 c/el     8.8x
 *      D =  64   ->                                 ~164 c/el    17.1x
 *
 *   and at an ENCODER's n = 190,080 the same kernel is ~12 c/el, 230x.  THE RATE IS A
 *   FUNCTION OF n AND OF THE DATA.  Quote it with both.
 *
 * WHY NOT AN INTEGER TABLE.  pext_nl/pext_nl_gelu_s8_pext_int_lut.c reaches ~410 cycles per
 * distinct value instead of ~2,800 by evaluating in integers, which at n = 1,152 would be
 * ~100 c/el rather than ~630 -- but it is `numeric_drift`, 1 int8 LSB.  That trade is
 * available and is deliberately NOT taken here: this is the bit-exact member of the pair,
 * and it is the one to deploy first because it cannot change a WER.
 *
 * THE SCALES ARE NOT SHARED, so a cross-dispatch table cache buys nothing.  Checked, not
 * assumed: out/decint8/ir has 144 silu_s8 dispatches and 144 DISTINCT (scale_in, scale_out)
 * pairs.  ROCC_DECOUPLED.md s8.15.16 projects "six 256-byte tables built once at model load
 * serve every token" -- that is FALSE for this IR, and the projection built on it is too.
 */
#include <math.h>
#include <stdint.h>

void kernel_silu_s8(const int8_t *input, int8_t *output, int n,
                    float scale_in, float scale_out,
                    int activation_min, int activation_max) {
    int8_t tbl[256];
    unsigned char seen[256];
    int i, v;

    if (n < 32) {
        for (i = 0; i < n; i++) {
            float f = (float)input[i] * scale_in;
            float y = f / (1.0f + expf(-f));
            int32_t q = (int32_t)roundf(y / scale_out);
            if (q < activation_min) q = activation_min;
            if (q > activation_max) q = activation_max;
            output[i] = (int8_t)q;
        }
        return;
    }
    for (i = 0; i < 256; i++) seen[i] = 0;
    for (i = 0; i < n; i++) seen[(unsigned char)((int)input[i] + 128)] = 1;
    for (v = 0; v < 256; v++) {
        if (!seen[v]) continue;
        {
            float f = (float)(v - 128) * scale_in;
            float y = f / (1.0f + expf(-f));
            int32_t q = (int32_t)roundf(y / scale_out);
            if (q < activation_min) q = activation_min;
            if (q > activation_max) q = activation_max;
            tbl[v] = (int8_t)q;
        }
    }
    for (i = 0; i < n; i++) output[i] = tbl[(unsigned char)((int)input[i] + 128)];
}
