/* source: curated */
/* algorithm: pext_row_dot8 */
/* accuracy_class: bit_exact */
/* origin: MBP.DOT8 / MBP.QMUL / MBP.CLIP8 / MBP.MAX8 on the big Rocket hart.
 *         fpga/pynq-z2/sw/pext.h is the contract; PEXT_SPEC.md 3.2/3.4 the rationale. */

/*
 * linear_s8 for the MBP packed-integer extension.  input [M,K], weight [N,K], both
 * row-major, so the reduction axis is already contiguous in both operands -- linear is
 * the one op where DOT8 needs no gather at all.  What it does need is 8-byte alignment,
 * because Rocket takes a misaligned-address exception rather than emulating.
 *
 * TWO MISALIGNMENTS, AND ONLY ONE OF THEM IS FREE TO FIX.
 *
 *   The input row is copied once per m into an 8-aligned, zero-padded scratch.  That is
 *   K byte copies against N*K MACs, i.e. 1/N of the work -- 0.8% on LeNet's fc1.
 *
 *   The weight row cannot be copied: at M = 1 (every linear dispatch in this repo's
 *   models, and DroNet's two heads) a repack of the whole [N,K] weight tensor costs more
 *   byte copies than the DOT8 loop saves.  LeNet fc1 would pay 30,720 copies to remove
 *   3,840 DOT8s.  So the weight rows are read WHERE THEY ARE, and the copy of the input
 *   row is shifted to match instead:
 *
 *     r     = (weight + n*K) & 7            the row's own misalignment
 *     a     = weight + n*K - r              8-aligned, r bytes early
 *     xs[]  = r zero bytes, then the input row, then zero to the next multiple of 8
 *
 *   DOT8 over (xs, a) then computes exactly sum_k x[k]*w[n][k]: the r leading weight
 *   bytes belong to row n-1 and the trailing ones to row n+1, and both are multiplied by
 *   the zeros in xs.  The same zero padding absorbs K % 8 != 0.
 *
 *   r depends on n only through (n*K) mod 8, which takes 8/gcd(K,8) distinct values -- 1
 *   when K is a multiple of 8 (LeNet fc1 K=256, fc2 K=120; DroNet K=2048), 2 for LeNet's
 *   fc3 (K=84).  So the n loop is walked once per residue class and one shifted copy is
 *   live at a time: O(1) scratch, 8/gcd(K,8) copies of the input row per m.  Outputs are
 *   written in a different ORDER than the reference writes them, and each one is an
 *   independent function of its own inputs, so the result is identical.
 *
 * THE TWO READS THAT WOULD GO OUT OF BOUNDS.  `a` deliberately points r bytes before
 * row n, and the sweep deliberately runs past its end -- that is what makes the zero
 * padding do its work.  At the two edges of the WHOLE tensor there is nothing there:
 * the first row's `a` is before the array, and the last row's final group runs past it.
 * So only 8-byte groups lying wholly inside the tensor are done with DOT8, and the data
 * outside them is picked up by two scalar edges of at most 7 bytes each.  This is not a
 * theoretical concern: ASan reports both in seconds (fpga/pynq-z2/modelblaster/check),
 * the second one only for small K where every row overruns, not just the last.
 *
 * Output stage and clamp shapes: identical to the conv kernel -- QMUL, a scalar
 * round-half-up shift with MB_PEXT_ROUND(s) hoisted, CLIP8, and MAX8 against x0 when the
 * layer folds a ReLU into activation_min = 0.  Non-zero input/filter offsets fall through
 * to the bit-exact scalar reference; this exporter never emits them (PEXT_SPEC.md 1.2).
 *
 * SINGLE-HART: static scratch, one pinned runner.  See the conv kernel's header.
 */

#include <stddef.h>
#include <stdint.h>
#include "pext.h"

/* One shifted, zero-padded copy of an input row.  4 KB covers K up to 4,081 -- DroNet's
 * 2,048-deep heads included.  Longer reductions fall through to the scalar reference. */
#ifndef MB_PEXT_LIN_XBYTES
#define MB_PEXT_LIN_XBYTES 4096
#endif

static int8_t mb_pext_lin_x[MB_PEXT_LIN_XBYTES] __attribute__((aligned(8)));

/* Same reasoning as the conv kernel: keep the hot loops out of line so each gets the
 * register file to itself, and mark the quant-parameter pointer __restrict so the int8
 * store to `output` does not force a reload of every field on every output element. */
#if defined(__GNUC__)
#define MB_PEXT_NOINLINE __attribute__((noinline))
#else
#define MB_PEXT_NOINLINE
#endif

typedef struct {
    int64_t mult;
    int64_t rnd;
    int     shift;
    int     shl;
    int     offset;
    int     relu0;
    int     wide;
    int     amin, amax;
} mb_pext_linq_t;

static inline int8_t mb_pext_lin_out(int64_t acc, const mb_pext_linq_t *__restrict q)
{
    int64_t v = mb_pext_qmul(acc, q->mult);

    if (q->shift) {
        v = (v + q->rnd) >> q->shift;
    } else if (q->shl) {
        v = (int32_t)((uint32_t)(int32_t)v << q->shl);
    }
    v += q->offset;
    v = mb_pext_clip8(v);
    if (q->relu0) {
        v = mb_pext_relu8(v);
    } else if (!q->wide) {
        if (v < q->amin) v = q->amin;
        if (v > q->amax) v = q->amax;
    }
    return (int8_t)v;
}

/* Four weight rows of one residue class against one shifted input copy.
 *
 * The rows in a residue class are `period*K` bytes apart, and period*K is a multiple of
 * 8 by construction (period = 8/gcd(K,8)), so all four pointers are 8-aligned if the
 * first one is.  One input load feeds four DOT8s: 19 instructions per four groups
 * against 28 for four separate single-row sweeps, because the input load, the loop
 * counter and the branch are paid once instead of four times. */
static MB_PEXT_NOINLINE void mb_pext_lin_dot4(const int8_t *__restrict x,
                                              const int8_t *a, size_t step,
                                              int G, int64_t *__restrict out4)
{
    const int8_t *a0 = a;
    const int8_t *a1 = a + step;
    const int8_t *a2 = a1 + step;
    const int8_t *a3 = a2 + step;
    int64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    int g;

    for (g = 0; g < G; g++) {
        const int64_t v = MB_PEXT_LD8(x);
        s0 += mb_pext_dot8(v, MB_PEXT_LD8(a0));
        s1 += mb_pext_dot8(v, MB_PEXT_LD8(a1));
        s2 += mb_pext_dot8(v, MB_PEXT_LD8(a2));
        s3 += mb_pext_dot8(v, MB_PEXT_LD8(a3));
        x += 8; a0 += 8; a1 += 8; a2 += 8; a3 += 8;
    }
    out4[0] = s0; out4[1] = s1; out4[2] = s2; out4[3] = s3;
}

/* One weight row, whole-sweep (no edge): the row lies wholly inside the tensor. */
static MB_PEXT_NOINLINE int64_t mb_pext_lin_dot1(const int8_t *__restrict x,
                                                 const int8_t *a, int G)
{
    int64_t s = 0;
    int g;

    for (g = 0; g < G; g++) {
        s += mb_pext_dot8(MB_PEXT_LD8(x), MB_PEXT_LD8(a));
        x += 8; a += 8;
    }
    return s;
}

/* One weight row at either end of the tensor, where the padded sweep would read outside
 * it.  `a` deliberately points r bytes BEFORE row n and the sweep deliberately runs past
 * its end -- that is what makes the zero padding do its work, and in the middle of the
 * tensor the bytes it touches are the neighbouring rows', multiplied by zeros.  At the
 * two ends there is nothing there, so only the 8-byte groups lying wholly inside the
 * tensor are done with DOT8 and whatever data falls outside them is picked up by two
 * scalar edges of at most seven bytes each.  ASan reports both overruns in seconds
 * without this (fpga/pynq-z2/modelblaster/check). */
static int64_t mb_pext_lin_dot_edge(const int8_t *__restrict x, const int8_t *a,
                                    int r, int K, int L, int n, int N)
{
    const long before = (long)n * K;             /* bytes of tensor before `a` + r */
    const long after  = (long)(N - n) * K + r;   /* bytes of tensor from `a` onward */
    const int j0 = (r > before) ? (int)(r - before) : 0;
    const int j1 = (after < (long)L) ? (int)after : L;
    const int g0 = (j0 + 7) >> 3;
    int g1 = j1 >> 3;
    int lo, hi, g, j;
    int64_t acc = 0;

    if (g1 < g0) g1 = g0;
    lo = 8 * g0;
    hi = 8 * g1;
    for (g = g0; g < g1; g++) {
        acc += mb_pext_dot8(MB_PEXT_LD8(x + 8 * g), MB_PEXT_LD8(a + 8 * g));
    }
    for (j = r; j < r + K && j < lo; j++) {
        acc += (int64_t)((int32_t)x[j] * (int32_t)a[j]);
    }
    for (j = (hi > r) ? hi : r; j < r + K; j++) {
        acc += (int64_t)((int32_t)x[j] * (int32_t)a[j]);
    }
    return acc;
}

void kernel_linear_s8(const int8_t *input, const int8_t *weight,
                      const int32_t *bias, int8_t *output,
                      int M, int K, int N,
                      int input_offset, int filter_offset, int output_offset,
                      int output_multiplier, int output_shift,
                      int activation_min, int activation_max) {
    const int fast =
        (input_offset == 0) && (filter_offset == 0) &&
        (K > 0) && (N > 0) && (K + 15 <= MB_PEXT_LIN_XBYTES);

    if (fast) {
        mb_pext_linq_t q;
        /* 8/gcd(K,8): how many distinct weight-row misalignments this K produces. */
        int period = 8;
        int m, t, n, j;

        q.mult   = (int64_t)output_multiplier;
        /* MB_PEXT_ROUND(s) is defined for s >= 0 only; see the conv kernel. */
        q.rnd    = (output_shift > 0) ? MB_PEXT_ROUND(output_shift) : 0;
        q.shift  = (output_shift > 0) ? output_shift : 0;
        q.shl    = (output_shift < 0) ? -output_shift : 0;
        q.offset = output_offset;
        q.relu0  = (activation_min == 0);
        q.wide   = (activation_min <= -128) && (activation_max >= 127);
        q.amin   = activation_min;
        q.amax   = activation_max;

        if ((K & 1) == 0) period = 4;
        if ((K & 3) == 0) period = 2;
        if ((K & 7) == 0) period = 1;

        for (m = 0; m < M; m++) {
            const int8_t *xrow = input + (size_t)m * K;
            int8_t *orow = output + (size_t)m * N;

            for (t = 0; t < period && t < N; t++) {
                const int r = (int)(((uintptr_t)(weight + (size_t)t * K)) & 7u);
                const int L = (r + K + 7) & ~7;  /* bytes a full sweep would read */
                const int G = L >> 3;
                const size_t step = (size_t)period * K;
                /* Rows n in [nlo, nhi] are INTERIOR: `a` = weight + n*K - r starts at or
                 * after the tensor, and the sweep ends at or before its end, so the whole
                 * L bytes are readable and no edge handling is needed.  Hoisting this out
                 * of the row loop is what makes the fast path fast: computing it per row
                 * cost two 64-bit multiplies and a dozen instructions on every row, which
                 * on LeNet's fc1 was more than the DOT8 sweep it was guarding. */
                const int nlo = (r + K - 1) / K;          /* n*K >= r      */
                const int nhi = N - (L - r + K - 1) / K;  /* (N-n)*K >= L-r */
                int64_t acc4[4];

                for (j = 0; j < r; j++) {
                    mb_pext_lin_x[j] = 0;
                }
                for (j = 0; j < K; j++) {
                    mb_pext_lin_x[r + j] = xrow[j];
                }
                for (j = r + K; j < L; j++) {
                    mb_pext_lin_x[j] = 0;
                }

                n = t;
                /* Leading rows whose window starts before the tensor. */
                while (n < N && n < nlo) {
                    orow[n] = mb_pext_lin_out(
                        (bias ? bias[n] : 0) +
                        mb_pext_lin_dot_edge(mb_pext_lin_x,
                                             weight + (size_t)n * K - r,
                                             r, K, L, n, N), &q);
                    n += period;
                }
                /* Interior, four rows at a time. */
                while (n + 3 * period <= nhi && n + 3 * period < N) {
                    const int8_t *a = weight + (size_t)n * K - r;
                    int u;

                    mb_pext_lin_dot4(mb_pext_lin_x, a, step, G, acc4);
                    for (u = 0; u < 4; u++) {
                        const int nn = n + u * period;
                        orow[nn] = mb_pext_lin_out(
                            acc4[u] + (bias ? bias[nn] : 0), &q);
                    }
                    n += 4 * period;
                }
                /* Interior, one row at a time. */
                while (n <= nhi && n < N) {
                    orow[n] = mb_pext_lin_out(
                        (bias ? bias[n] : 0) +
                        mb_pext_lin_dot1(mb_pext_lin_x,
                                         weight + (size_t)n * K - r, G), &q);
                    n += period;
                }
                /* Trailing rows whose window runs past the end of the tensor. */
                while (n < N) {
                    orow[n] = mb_pext_lin_out(
                        (bias ? bias[n] : 0) +
                        mb_pext_lin_dot_edge(mb_pext_lin_x,
                                             weight + (size_t)n * K - r,
                                             r, K, L, n, N), &q);
                    n += period;
                }
            }
        }
        return;
    }

    /* Refused: a non-zero zero point, or a reduction longer than the scratch.  This is
     * ModelBlaster's own reference expression, verbatim. */
    {
        int m, n, k;
        for (m = 0; m < M; m++) {
            for (n = 0; n < N; n++) {
                int32_t acc = bias ? bias[n] : 0;
                for (k = 0; k < K; k++) {
                    int32_t in_v = (int32_t)input[m * K + k] + input_offset;
                    int32_t w_v  = (int32_t)weight[n * K + k] + filter_offset;
                    acc += in_v * w_v;
                }
                {
                    int64_t prod = (int64_t)acc * (int64_t)output_multiplier;
                    int32_t scaled;
                    prod = (prod + (1LL << 30)) >> 31;
                    scaled = (int32_t)prod;
                    if (output_shift > 0) {
                        scaled = (int32_t)(((int64_t)scaled
                            + ((int64_t)1 << (output_shift - 1))) >> output_shift);
                    } else if (output_shift < 0) {
                        scaled = scaled << (-output_shift);
                    }
                    scaled += output_offset;
                    if (scaled < activation_min) scaled = activation_min;
                    if (scaled > activation_max) scaled = activation_max;
                    output[m * N + n] = (int8_t)scaled;
                }
            }
        }
    }
}
