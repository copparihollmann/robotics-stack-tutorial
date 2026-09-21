/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_lut */
/* accuracy_class: numeric_drift */
/* origin: fpga/pynq-z2/sw/int_nonlin.c, measured by Lab B42 */
/*
 * silu_s8 with no floating-point arithmetic anywhere: the 256-entry table of
 * pext_nl/pext_nl_silu_s8_pext_memo_lut.c, filled by a fixed-point sigmoid instead of expf.
 *
 * WHY, AND THE NUMBER IS MEASURED.  Lab B42 separated the two table builders on silicon.  A
 * lane kernel builds all 256 entries and a curated one builds only the D that occur, which
 * makes the two arms of that lab a simultaneous equation for the cost of a table entry and of
 * the curated gather: FLOAT 5,087 cycles/entry, INTEGER 702, and the gather solves to 18.3
 * cycles/element from tanh_s8 and 18.3 from gelu_s8 INDEPENDENTLY (T4_LANES.md s13).
 *
 * On that decomposition silu_s8 is 95.1 % TABLE BUILD and 4.9 % gather -- 405,258 of 426,350
 * cycles per dispatch.  So the expensive thing about this operator is not the lookup, and an
 * accelerator that replaces the lookup is worth 3.7 % of it.  This file replaces the build.
 *
 * AND THE TABLE CANNOT BE CACHED, checked in the IR rather than assumed: out/decint8/ir has
 * 144 silu_s8 dispatches over 6 sites with 144 DISTINCT (scale_in, scale_out) pairs, and 0 of
 * the 6 sites holds its scales constant across its 24 tokens.  A per-site cache would build
 * 144 tables instead of 144.  ROCC_DECOUPLED.md s8.15.16's "six 256-byte tables built once at
 * model load serve every token" is false for this IR, and so is every projection resting on it.
 *
 * WHAT IT IS WORTH: 200,848 cycles per dispatch against 426,350 -- 52.9 %, 32.5 M cycles,
 * -0.117 of RTF_e2e -- with no accelerator at all.
 *
 * THE TRADE, STATED RATHER THAN INFERRED.  This is the numeric_drift member of a pair whose
 * bit_exact member is pext_nl_silu_s8_pext_memo_lut.c, and that file names the trade in its own
 * header: "that trade is available and is deliberately NOT taken here: this is the bit-exact
 * member of the pair".  Both are registered and a build selects one for a stated reason.  It is
 * the same trade gelu_s8 took when pext_int_lut superseded pext_memo_lut.
 *
 * ACCURACY, ENUMERATED RATHER THAN SAMPLED, because the input domain is 256 values.  Over the
 * model's OWN 144 (scale_in, scale_out) pairs x all 256 inputs = 36,864 cases: 101 differ, max
 * 1 LSB.  int_gelu_s8's own recorded figure on the same kind of sweep is 99 of 36,864, max 1.
 * A WER measurement is not the instrument for a one-LSB bound over an enumerable domain; that
 * is a reason and not an omission.
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif

void kernel_silu_s8(const int8_t *input, int8_t *output, int n,
                    float scale_in, float scale_out,
                    int activation_min, int activation_max) {
    int_silu_s8(input, output, n, scale_in, scale_out,
                activation_min, activation_max);
}
