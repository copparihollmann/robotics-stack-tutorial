/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_memo_lut */
/* accuracy_class: bit_exact */
/* origin: fpga/pynq-z2/docs/SPEECH_ON_ROCKET.md, Lab B20 */
/*
 * gelu_s8 for the MBP target -- and the interesting thing about it is that it uses no
 * MBP instruction at all.
 *
 * WHAT IT NOTICES.  With per-tensor symmetric quantisation and zero_point 0 this op is a
 * pointwise map from 256 input bytes to 256 output bytes.  For one (scale_in, scale_out,
 * clamp) it therefore has at most 256 distinct outputs, so evaluating erff once per
 * ELEMENT is never necessary -- whatever arithmetic it is evaluated in.  Lab B19
 * measured the reference at 3,093 cycles per element on an ffn_block activation of
 * 131,072 elements; that is 405 million cycles to evaluate a 256-entry function.
 *
 * BIT-EXACT BY CONSTRUCTION.  Every table entry is the reference's own expression, in
 * float32, with the same kInvSqrt2 constant, the same casts and the same roundf.  There
 * is no arithmetic anywhere else in this kernel, so there is no rounding mode to match.
 * That is the same argument kernels/rvv/rvv_gelu_s8_rvv_memo_lut_gather.c makes for a
 * vector unit; here the gather is a scalar byte load and the saving is entirely in the
 * erff count.
 *
 * ONE MARKING PASS, NOT 256 UNCONDITIONAL ENTRIES.  A quantised activation tensor
 * repeats values heavily and often does not use the whole range, so the cost is
 * distinct*erff rather than 256*erff.  Below the small-n guard the reference expression
 * runs per element instead: the marking array costs more than it saves there.
 *
 * Measured on the board (Lab B20, hart 0, 34.4828 MHz), against the reference
 * expression compiled in the same image, at Lab B19's own ffn_block quant parameters:
 *
 *      n         float   this kernel   speedup
 *        64      5,538       5,018       1.10x
 *     2,048      5,319         682       7.79x
 *    16,384      5,301         103      51.44x
 *   131,072      5,320          31     167.46x       max_abs_err 0 at every n
 *
 * The integer-table sibling (pext_nl/pext_nl_gelu_s8_pext_int_lut.c) reaches 20
 * cycles/element by removing the 256 erff calls too, at 1 int8 LSB.  This one is here
 * because it is bit-exact and the pext backend's atol is 0.
 */
#include <math.h>
#include <stdint.h>

void kernel_gelu_s8(const int8_t *input, int8_t *output, int n,
                    float scale_in, float scale_out,
                    int activation_min, int activation_max) {
    const float kInvSqrt2 = 0.70710678118f;
    int8_t tbl[256];
    unsigned char seen[256];
    int i, v;

    if (n < 32) {
        for (i = 0; i < n; i++) {
            float f = (float)input[i] * scale_in;
            float y = 0.5f * f * (1.0f + erff(f * kInvSqrt2));
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
            float y = 0.5f * f * (1.0f + erff(f * kInvSqrt2));
            int32_t q = (int32_t)roundf(y / scale_out);
            if (q < activation_min) q = activation_min;
            if (q > activation_max) q = activation_max;
            tbl[v] = (int8_t)q;
        }
    }
    for (i = 0; i < n; i++) output[i] = tbl[(unsigned char)((int)input[i] + 128)];
}
