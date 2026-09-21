/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_lut */
/* accuracy_class: numeric_drift */
/* origin: fpga/pynq-z2/sw/int_nonlin.c, measured by Lab B20 */
/*
 * gelu_s8 with no floating-point arithmetic anywhere: the 256-entry table of
 * pext/pext_gelu_s8_pext_memo_lut.c, filled by an integer erf instead of erff.
 *
 * TWO INDEPENDENT IDEAS, AND THE SMALLER ONE IS THE FIXED POINT.  The population
 * argument (evaluate the transcendental at most 256 times, never per element) is worth
 * 167x on its own and is bit-exact.  Removing the remaining 256 erff calls is worth a
 * further 1.55x and costs 1 int8 LSB.  Measured on the board at Lab B19's own ffn_block
 * quant parameters, n = 131,072: float 5,320 cycles/element, float table 31, integer
 * table 20.
 *
 * WHY IT IS WORTH THE LSB ANYWAY: the float table's cost is a property of the DATA.
 * picolibc's erff takes a rational polynomial below |x| = 0.84 and an expf above it, so
 * the same operator measured 3,093 cycles/element on Lab B19's real activation and
 * 6,605 on a uniform one.  The table costs 20 either way.
 *
 * ACCURACY, ENUMERATED RATHER THAN SAMPLED.  The input domain is 256 values, so it can
 * be proved rather than sampled -- the same argument DRONET_INTEGER.md 3 makes for
 * batchnorm2d_s8 and add_s8.  On the board, over 36 (scale_in, scale_out) pairs x all
 * 256 inputs = 9,216 cases: 21 differ, max_abs_err 1.  Off the board over 144 pairs =
 * 36,864 cases: 99 differ, max 1, and every one of the 99 sits within 0.014 LSB of an
 * exact half-integer rounding boundary -- i.e. they are ties broken differently, not
 * accuracy.
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif

void kernel_gelu_s8(const int8_t *input, int8_t *output, int n,
                    float scale_in, float scale_out,
                    int activation_min, int activation_max) {
    int_gelu_s8(input, output, n, scale_in, scale_out,
                activation_min, activation_max);
}
