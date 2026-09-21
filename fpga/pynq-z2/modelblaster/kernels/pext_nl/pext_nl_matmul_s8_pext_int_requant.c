/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_requant */
/* accuracy_class: numeric_drift */
/* origin: fpga/pynq-z2/sw/int_nonlin.c, measured by Lab B20 */
/*
 * matmul_s8 -- activation x activation, which is what attention needs, and which nobody
 * had looked at on this core because it LOOKS integer.  Its reduction is int32.  Its
 * tail is
 *
 *      int32_t v = (int32_t)roundf((float)acc * total);
 *
 * one float multiply and one roundf per OUTPUT element, on a WithoutFPU core.  Measured
 * on the board: 244 cycles per output element for that one line.  For an encoder the
 * population is heads*T*T per layer -- 1.59 million elements per second of audio on
 * Squeezeformer-XS -- which makes it the largest float cost in a transformer after GELU,
 * hiding inside an op the tables call integer.
 *
 * Two changes, both small:
 *
 *   1. The requantise becomes the same Q0.31 rescale every curated convolution kernel
 *      already does, with `total` decoded from its IEEE-754 bits rather than multiplied.
 *      Measured on the board: 244 -> 37 cycles/element, 6.6x.  The loop is specialised
 *      on the sign of the decoded shift, and that matters more than it looks: the
 *      generic 128-bit form measured 55 rather than 37, because acc is int32 and the
 *      multiplier is 31 bits so the product never needs 128 bits at all.
 *
 *   2. MBP.DOT8 for the reduction when transpose_b makes the K axis contiguous in BOTH
 *      operands and both rows are 8-aligned -- which is exactly the Q.K^T shape.  No
 *      gather, no repack; the guard falls through to the scalar reduction otherwise
 *      rather than pretending.
 *
 * Accuracy: over 450,000 accumulators spanning the full range an int8 matmul with
 * K <= 512 can produce, across nine values of `total`, 103 differ from roundf and the
 * worst is 1 LSB.  It is NOT bit-exact and does not claim to be: float32 has a 24-bit
 * mantissa and this does not, so above 2^24 this kernel is the MORE accurate of the two.
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif
#include "pext.h"

#ifndef MBP_MM_ACCMAX
#define MBP_MM_ACCMAX 4096
#endif

void kernel_matmul_s8(const int8_t *a, const int8_t *b, int8_t *output,
                      int M, int K, int N,
                      float scale_a, float scale_b, float scale_out,
                      int transpose_b, float scale_div,
                      int activation_min, int activation_max) {
    static int32_t acc_row[MBP_MM_ACCMAX];
    float total = (scale_a * scale_b) / (scale_out * scale_div);
    int i, j, k;

    /* DOT8 needs eight contiguous bytes from each operand at an 8-aligned address;
     * Rocket traps on misaligned rather than emulating, so the guard is a hard one. */
    const int dot8_ok = transpose_b && ((K & 7) == 0)
                        && ((((uintptr_t)a | (uintptr_t)b | (unsigned)K) & 7u) == 0u);

    for (i = 0; i < M; i++) {
        int n0 = 0;
        while (n0 < N) {
            int nn = N - n0;
            if (nn > MBP_MM_ACCMAX) nn = MBP_MM_ACCMAX;
            for (j = 0; j < nn; j++) {
                int32_t acc = 0;
                if (dot8_ok) {
                    const int8_t *ap = a + (size_t)i * K;
                    const int8_t *bp = b + (size_t)(n0 + j) * K;
                    int64_t s = 0;
                    for (k = 0; k < K; k += 8) {
                        s += mb_pext_dot8(*(const int64_t *)(ap + k),
                                      *(const int64_t *)(bp + k));
                    }
                    acc = (int32_t)s;
                } else {
                    for (k = 0; k < K; k++) {
                        int8_t av = a[(size_t)i * K + k];
                        int8_t bv = transpose_b ? b[(size_t)(n0 + j) * K + k]
                                                : b[(size_t)k * N + (n0 + j)];
                        acc += (int32_t)av * (int32_t)bv;
                    }
                }
                acc_row[j] = acc;
            }
            int_matmul_requant_s8(acc_row, output + (size_t)i * N + n0, nn, total,
                                  activation_min, activation_max);
            n0 += nn;
        }
    }
}
