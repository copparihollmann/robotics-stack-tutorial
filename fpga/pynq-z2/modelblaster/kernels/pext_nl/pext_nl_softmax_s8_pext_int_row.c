/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_row */
/* accuracy_class: numeric_drift */
/* origin: fpga/pynq-z2/sw/int_nonlin.c, measured by Lab B20 */
/*
 * softmax_s8 with no floating-point arithmetic: 2^x from a 33-entry table with linear
 * interpolation, ONE integer divide per ROW and none per element.  The same shape
 * audio_fe.c's fe_log2_q8 already uses, and the same question -- does this need float at
 * all -- that fixed point already answered for the FFT at 37.0x.
 *
 * Measured on the board (Lab B20, hart 0), against the reference expression compiled in
 * the same image: 5,550 -> 168 cycles per element at K = 512, i.e. 32.9x, with a worst
 * int8 output difference of 2 LSB.  Two LSB on a 255-level encoding is 0.8% of full
 * scale, on a quantity the next layer immediately requantises.
 *
 * WHAT THE BENCHMARK GOT WRONG AND THIS DOES NOT.  int_nonlin.c's own int_softmax_s8
 * writes the probability as 0 -> -128, 1 -> +127, because that was the encoding the
 * benchmark's transcription used.  reference_kernels.py's softmax_s8 writes
 * round(p / scale_out), which for the usual scale_out = 1/127 is 0 -> 0, 1 -> 127.
 * Those are DIFFERENT TENSORS, and a curated kernel that shipped the benchmark's
 * encoding would verify against the benchmark and be wrong in every model.  So this
 * kernel uses int_nonlin.c's exponential and reciprocal and its own output stage.
 *
 * The row reciprocal is one plain 128-bit divide, not a Newton iteration.  The first
 * version of int_softmax_s8 used Newton in Q0.62 and was simply wrong -- max_abs_err 255
 * of a 255-wide output.  A row of 512 elements pays one divide against 512
 * exponentials; there is nothing here worth being clever about.
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif

void kernel_softmax_s8(const int8_t *input, int8_t *output, int M, int K,
                       float scale_in, float scale_out) {
    /* z = (x - max) * scale_in * log2(e), in Q16.16 and never positive.  scale_in and
     * 1/scale_out are decoded from their IEEE-754 bit patterns; no float instruction
     * executes anywhere in this kernel. */
    int32_t im, om;
    int is, os;
    int m, k;

    nl_f2ms(scale_in, &im, &is);
    nl_f2ms_recip(scale_out, &om, &os);
    /* fold log2(e) into the input multiplier: m <- m * log2(e), renormalised. */
    {
        uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
        while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
        im = (int32_t)p;
    }

    for (m = 0; m < M; m++) {
        const int8_t *x = input + (size_t)m * K;
        int8_t *y = output + (size_t)m * K;
        int32_t mx = x[0];
        uint64_t sum = 0;
        __uint128_t inv;

        for (k = 1; k < K; k++) if (x[k] > mx) mx = x[k];
        for (k = 0; k < K; k++) {
            sum += int_exp2_q31((int32_t)nl_scale((int64_t)(x[k] - mx) << 16, im, is));
        }
        if (!sum) {
            for (k = 0; k < K; k++) y[k] = 0;
            continue;
        }
        inv = (((__uint128_t)1 << 64) - 1) / sum;
        for (k = 0; k < K; k++) {
            uint32_t ev = int_exp2_q31((int32_t)nl_scale((int64_t)(x[k] - mx) << 16,
                                                         im, is));
            /* p = ev/sum in Q0.32, then out = round(p / scale_out) with eight
             * fractional bits kept so the rounding is half-away-from-zero. */
            uint64_t p32 = (uint64_t)(((__uint128_t)ev * inv) >> 32);   /* Q0.32 */
            int64_t v_q8 = nl_scale((int64_t)p32, om, os + 32 - 8);

            y[k] = nl_q8_to_s8(v_q8, -128, 127);
        }
    }
}
