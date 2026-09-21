/* source: curated */
/* algorithm: pext_patch_dot8 */
/* accuracy_class: bit_exact */
/* origin: MBP.DOT8 / MBP.QMUL / MBP.CLIP8 / MBP.MAX8 on the big Rocket hart.
 *         fpga/pynq-z2/sw/pext.h is the contract; PEXT_SPEC.md 3.2/3.4/6 the rationale. */

/*
 * conv2d_s8 for the MBP packed-integer extension, NCHW activations, OIHW weights.
 *
 * WHY A PATCH GATHER AND NOT THE SPEC'S NHWC KERNEL.  PEXT_SPEC.md section 6 puts the
 * eight int8 values a DOT8 consumes along the *channel* axis, which is contiguous only
 * in NHWC.  ModelBlaster emits NCHW here (every algorithm in reference_kernels.py
 * declares act_layouts=("nchw",) and buffers.c is compiled once per model, so a kernel
 * cannot change a tensor's physical layout on its own).  In NCHW the reduction axis
 * (ic, kh, kw) is not contiguous in the activation at all -- the contiguous run is KW
 * bytes along W.  So this kernel takes section 6.3's IC % 8 != 0 answer and applies it
 * to *every* shape: materialise the K = IC*KH*KW reduction vector for one output pixel
 * in an 8-aligned, zero-padded scratch buffer, then run ceil(K/8) flat DOT8s per output
 * channel against it.  That is also exactly what LeNet needs -- IC = 1 and IC = 6, so
 * the ">= 8 consecutive input channels" form has no customer here even in NHWC.
 *
 * The weight side of a DOT8 must be 8-byte aligned too, and `weight + oc*K` is not when
 * K % 8 != 0 (LeNet: K = 25 and K = 150).  Rocket takes a misaligned-address exception
 * rather than emulating, so this is a correctness problem, not a speed one.  The fix is
 * to repack the weights into 8-aligned, zero-padded rows of KP = align8(K) bytes ONCE
 * per dispatch.  That costs OC*K byte copies against OH*OW*OC*K/8 groups of real work,
 * i.e. ~4/(OH*OW) of the loop -- 0.7% on LeNet conv1, 6% on conv2.  The alternative
 * (shifting the *patch* to match each weight row's misalignment) would pay 8x the gather
 * on every pixel, which is far worse; the patch is per-pixel, the weights are per-layer.
 *
 * ZERO PADDING IS LOAD-BEARING AND FREE.  input_offset and filter_offset are 0 in every
 * record this exporter emits (PEXT_SPEC.md 1.2), so an out-of-bounds tap contributes
 * exactly zero and a zero byte in the patch reproduces it.  Same for the align8 tail: the
 * repacked weight rows are zero there too, so both operands are zero and DOT8 adds 0.
 * When either offset is non-zero the fast path is refused outright and the bit-exact
 * scalar reference below runs instead -- an approximation there would be silently wrong.
 *
 * THE OUTPUT STAGE IS THREE STEPS, NOT ONE.  MBP.RQS did not fit (PEXT_SPEC.md's
 * DECISION block), so: QMUL, then a scalar rounding shift with MB_PEXT_ROUND(s) hoisted
 * out of the loop, then CLIP8.  Both roundings are round-half-up -- add-then-arithmetic-
 * shift on signed values -- because that is what the ModelBlaster reference expression
 * computes.  Rounding half away from zero instead is 1 LSB out on about half of all
 * negative outputs.
 *
 * activation_min = 0 (ReLU folded into the clamp, which is what LeNet's conv records
 * carry) is CLIP8 followed by MBP.MAX8 against x0.  CLIP8 always saturates to the full
 * int8 range, and [activation_min, activation_max] is always inside it, so clamping
 * twice is the same as clamping once.
 *
 * SINGLE-HART.  The scratch buffers below are static, like the curated gemmini maxpool's.
 * These instructions exist only on hart 0 (PEXT_SPEC.md section 7) and any thread running
 * them must be pinned there, so there is exactly one runner; a build that pinned two
 * threads to hart 0 and ran conv dispatches concurrently would race on them.
 */

#include <stddef.h>
#include <stdint.h>
#include "pext.h"

/* Repacked weight rows.  8 KB holds LeNet conv2 (16 x 152 = 2,432 B) and DroNet's
 * conv_modules.0 (32 x 32 = 1,024 B) whole; bigger layers are processed in output-channel
 * blocks, which re-gathers the patch once per block and is correct either way. */
#ifndef MB_PEXT_CONV_WBYTES
#define MB_PEXT_CONV_WBYTES 8192
#endif
/* One output pixel's reduction vector.  DroNet's deepest layer is K = 1152. */
#ifndef MB_PEXT_CONV_PBYTES
#define MB_PEXT_CONV_PBYTES 2048
#endif
/* Source-row pointers for one output row: IC*KH of them.  DroNet's widest is 128*3. */
#ifndef MB_PEXT_CONV_MAXROWS
#define MB_PEXT_CONV_MAXROWS 512
#endif

static int8_t mb_pext_conv_wpack[MB_PEXT_CONV_WBYTES] __attribute__((aligned(8)));
static int8_t mb_pext_conv_patch[MB_PEXT_CONV_PBYTES] __attribute__((aligned(8)));
static const int8_t *mb_pext_conv_rows[MB_PEXT_CONV_MAXROWS];

/* Keep the two hot helpers out of line.  Both are called from exactly one place, so -O2
 * inlines them by default and the whole loop nest becomes one function again -- which is
 * the state this kernel started in: `addi sp,sp,-624` at entry and a stack reload inside
 * the DOT8 loop.  Out of line, each gets the register file to itself. */
#if defined(__GNUC__)
#define MB_PEXT_NOINLINE __attribute__((noinline))
#else
#define MB_PEXT_NOINLINE
#endif

/* The per-layer half of the output stage, hoisted once and passed by pointer.
 *
 * WHY A STRUCT AND NOT ELEVEN ARGUMENTS.  The first version of this kernel was one
 * function with the whole loop nest and every hoisted constant live across it.  GCC ran
 * out of registers and spilled.  Splitting the inner work into small functions with few
 * live values is worth more here than any amount of cleverness in the DOT8 loop --
 * PEXT_SPEC.md 5.2 predicted the accelerated loop would be bound by everything except the
 * new instruction, and register pressure is what "everything else" turned out to mean
 * first.  The `__restrict` on the pointer to this struct is the other half: without it
 * GCC must assume the int8 store to `out` can alias the struct and reloads every field
 * for every output element. */
typedef struct {
    int64_t mult;
    int64_t rnd;
    int     shift;      /* output_shift, when positive */
    int     shl;        /* -output_shift, when negative */
    int     offset;     /* output_offset */
    int     relu0;      /* activation_min == 0: CLIP8 then MAX8 against x0 */
    int     wide;       /* the clamp is the full int8 range: CLIP8 alone */
    int     amin, amax;
    /* The shape EVERY conv2d_s8 and linear_s8 record this exporter emits actually has:
     * a positive shift, a zero output offset, and a ReLU folded into the clamp
     * (activation_min = 0, activation_max = 127).  PEXT_SPEC.md 1.2 is where that comes
     * from.  Knowing it once per dispatch turns the output stage from four runtime tests
     * and four field loads per output element into five instructions with no branch:
     * QMUL, add, sra, CLIP8, MAX8.  Measured at 6 instructions per output element on
     * LeNet, 6% of the whole kernel stream. */
    int     simple;
} mb_pext_oq_t;

static inline void mb_pext_oq_init(mb_pext_oq_t *q, int mult, int shift,
                                   int offset, int amin, int amax)
{
    q->mult   = (int64_t)mult;
    /* MB_PEXT_ROUND(s) is defined for s >= 0 only -- it is `1 << (s-1)`, so a negative
     * shift would shift by a negative amount.  A negative output_shift takes the
     * `scaled << -s` branch, which does not round at all. */
    q->rnd    = (shift > 0) ? MB_PEXT_ROUND(shift) : 0;
    q->shift  = (shift > 0) ? shift : 0;
    q->shl    = (shift < 0) ? -shift : 0;
    q->offset = offset;
    q->relu0  = (amin == 0);
    q->wide   = (amin <= -128) && (amax >= 127);
    q->amin   = amin;
    q->amax   = amax;
    q->simple = (shift > 0) && (offset == 0) && (amin == 0) && (amax >= 127);
}

/* MBP.QMUL, a scalar round-half-up shift with the rounding constant hoisted, MBP.CLIP8,
 * and MBP.MAX8 against x0 when the layer folds a ReLU into the clamp. */
static inline int8_t mb_pext_requant_out(int64_t acc, const mb_pext_oq_t *__restrict q)
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

/* One (ic, kh) row of the patch, with KW a compile-time constant.
 *
 * THE COPIES ARE WRITTEN OUT, NOT LOOPED, AND THAT IS NOT A STYLE CHOICE.  The obvious
 * form -- `for (k = 0; k < 5; k++) p[k] = s[k];` with 5 a literal -- looks unrolled and
 * is not: GCC recognises the constant-trip byte copy, decides its own loop is better than
 * five pairs of `lb`/`sb`, and emits `lbu/addi/addi/sb/bne` per byte.  Measured on LeNet
 * that was 5 instructions per gathered byte, 29.7% of the whole kernel instruction
 * stream, AFTER the switch was added.  Straight-line stores get `lbu rd, k(s)` and
 * `sb rd, k(p)` at immediate offsets: 2 per byte, and no loop at all. */
#define MB_PEXT_CP1   p[0] = s_[0];
#define MB_PEXT_CP2   MB_PEXT_CP1 p[1] = s_[1];
#define MB_PEXT_CP3   MB_PEXT_CP2 p[2] = s_[2];
#define MB_PEXT_CP4   MB_PEXT_CP3 p[3] = s_[3];
#define MB_PEXT_CP5   MB_PEXT_CP4 p[4] = s_[4];
#define MB_PEXT_CP6   MB_PEXT_CP5 p[5] = s_[5];
#define MB_PEXT_CP7   MB_PEXT_CP6 p[6] = s_[6];
#define MB_PEXT_CP8   MB_PEXT_CP7 p[7] = s_[7];

#define MB_PEXT_ZP1   p[0] = 0;
#define MB_PEXT_ZP2   MB_PEXT_ZP1 p[1] = 0;
#define MB_PEXT_ZP3   MB_PEXT_ZP2 p[2] = 0;
#define MB_PEXT_ZP4   MB_PEXT_ZP3 p[3] = 0;
#define MB_PEXT_ZP5   MB_PEXT_ZP4 p[4] = 0;
#define MB_PEXT_ZP6   MB_PEXT_ZP5 p[5] = 0;
#define MB_PEXT_ZP7   MB_PEXT_ZP6 p[6] = 0;
#define MB_PEXT_ZP8   MB_PEXT_ZP7 p[7] = 0;

#define MB_PEXT_GATHER_CASE(NKW)                                              \
    case NKW: {                                                               \
        int t_;                                                               \
        for (t_ = 0; t_ < nrows; t_++) {                                      \
            const int8_t *s_ = rows[t_];                                      \
            if (s_) {                                                         \
                s_ += iw0;                                                    \
                MB_PEXT_CP##NKW                                               \
            } else {                                                          \
                MB_PEXT_ZP##NKW                                               \
            }                                                                 \
            p += NKW;                                                         \
        }                                                                     \
        return;                                                               \
    }

/* Gather one output pixel's K bytes in (ic, kh, kw) order -- the order the OIHW weight
 * rows already have, which is what makes a flat DOT8 sweep legal.
 *
 * `rows` holds one source-row pointer per (ic, kh), already resolved for this output row
 * and NULL where the row is outside the image.  Resolving them per output ROW rather than
 * per output pixel takes IC*KH multiplies out of the per-pixel path.
 *
 * THIS IS THE KERNEL'S LARGEST NON-DOT8 COST AND IT IS WORTH THE SWITCH.  Profiled with
 * spike's PC histogram joined to the line table (check/profile_lines.py), the byte-copy
 * loop was 28.7% of the whole LeNet instruction stream -- more than twice what DOT8
 * itself was -- at 5.8 instructions per gathered byte, because KW is a runtime value and
 * GCC cannot unroll a loop whose trip count it does not know.  Switching on KW once per
 * pixel and running a constant-trip-count copy brings that to 2 instructions per byte.
 * KW <= 8 covers every convolution in every model in this repo (1, 3 and 5); anything
 * wider falls through to the generic loop, which is correct and merely slower.
 */
static MB_PEXT_NOINLINE void mb_pext_conv_gather(const int8_t *const *rows, int nrows,
                                                 int KW, int iw0, int IW,
                                                 int8_t *__restrict p)
{
    int t, kw;

    if (iw0 >= 0 && iw0 + KW <= IW) {
        switch (KW) {
        MB_PEXT_GATHER_CASE(1)
        MB_PEXT_GATHER_CASE(2)
        MB_PEXT_GATHER_CASE(3)
        MB_PEXT_GATHER_CASE(4)
        MB_PEXT_GATHER_CASE(5)
        MB_PEXT_GATHER_CASE(6)
        MB_PEXT_GATHER_CASE(7)
        MB_PEXT_GATHER_CASE(8)
        default: break;
        }
        for (t = 0; t < nrows; t++) {
            const int8_t *src = rows[t];
            if (src) {
                src += iw0;
                for (kw = 0; kw < KW; kw++) p[kw] = src[kw];
            } else {
                for (kw = 0; kw < KW; kw++) p[kw] = 0;
            }
            p += KW;
        }
        return;
    }
    /* The window hangs off the left or right edge of the image: every tap needs its own
     * bounds test, and the out-of-bounds ones become zero bytes (exact, because
     * input_offset is 0 -- see the header). */
    for (t = 0; t < nrows; t++) {
        const int8_t *src = rows[t];
        for (kw = 0; kw < KW; kw++) {
            const int iw = iw0 + kw;
            *p++ = (src && (unsigned)iw < (unsigned)IW) ? src[iw] : 0;
        }
    }
}

/* One output pixel, every output channel in the block.
 *
 * Four channels per pass over the patch, then two, then one: PEXT_SPEC.md 5.3's point
 * about the non-accumulating DOT8 is that the accumulators are ordinary registers, so one
 * patch load feeds four of them and the load count per MAC drops fourfold.  LeNet's conv1
 * has OC = 6, which is why the 2-wide tail exists -- without it a third of that layer's
 * channels would run one at a time.
 *
 * THE WEIGHTS ARE INTERLEAVED, WHICH IS THE POINT OF REPACKING THEM AT ALL.  Four
 * channels' group-g bytes are adjacent in mb_pext_conv_wpack, so the four weight loads
 * are `ld` at constant offsets 0, 8, 16, 24 off ONE pointer.  With four separate row
 * pointers, KP apart and KP a runtime value, GCC recomputed each address every iteration:
 * 23 instructions per four DOT8s instead of 16.  The repack is already paid for by the
 * alignment requirement, so choosing its layout is free.
 */
static MB_PEXT_NOINLINE void mb_pext_conv_pixel(const int8_t *__restrict p,
                                                const int8_t *__restrict wp,
                                                int KP, int G, int ocn,
                                                const int32_t *bias,
                                                int8_t *__restrict out, size_t ostride,
                                                const mb_pext_oq_t *__restrict q)
{
    const int quads = ocn >> 2;
    const int pairs = (ocn - 4 * quads) >> 1;
    /* Loaded once, not once per output element: with these in registers the common
     * output stage is QMUL, add, sra, CLIP8, MAX8 and nothing else. */
    const int64_t mult = q->mult;
    const int64_t rnd  = q->rnd;
    const int shift    = q->shift;
    const int simple   = q->simple;
    int b, g, i = 0;

#define MB_PEXT_OUT_SIMPLE(acc)                                               \
    ((int8_t)mb_pext_relu8(                                                   \
        mb_pext_clip8((mb_pext_qmul((acc), mult) + rnd) >> shift)))

    for (b = 0; b < quads; b++) {
        const int8_t *w = wp + (size_t)b * G * 32;
        const int8_t *pp = p;
        int64_t a0 = bias ? bias[i + 0] : 0;
        int64_t a1 = bias ? bias[i + 1] : 0;
        int64_t a2 = bias ? bias[i + 2] : 0;
        int64_t a3 = bias ? bias[i + 3] : 0;

        for (g = 0; g < G; g++) {
            const int64_t x = MB_PEXT_LD8(pp);
            a0 += mb_pext_dot8(x, MB_PEXT_LD8(w));
            a1 += mb_pext_dot8(x, MB_PEXT_LD8(w + 8));
            a2 += mb_pext_dot8(x, MB_PEXT_LD8(w + 16));
            a3 += mb_pext_dot8(x, MB_PEXT_LD8(w + 24));
            pp += 8;
            w += 32;
        }
        if (simple) {
            out[0]           = MB_PEXT_OUT_SIMPLE(a0);
            out[ostride]     = MB_PEXT_OUT_SIMPLE(a1);
            out[2 * ostride] = MB_PEXT_OUT_SIMPLE(a2);
            out[3 * ostride] = MB_PEXT_OUT_SIMPLE(a3);
        } else {
            out[0]           = mb_pext_requant_out(a0, q);
            out[ostride]     = mb_pext_requant_out(a1, q);
            out[2 * ostride] = mb_pext_requant_out(a2, q);
            out[3 * ostride] = mb_pext_requant_out(a3, q);
        }
        out += 4 * ostride;
        i += 4;
    }
    wp += (size_t)quads * G * 32;
    for (b = 0; b < pairs; b++) {
        const int8_t *w = wp + (size_t)b * G * 16;
        const int8_t *pp = p;
        int64_t a0 = bias ? bias[i + 0] : 0;
        int64_t a1 = bias ? bias[i + 1] : 0;

        for (g = 0; g < G; g++) {
            const int64_t x = MB_PEXT_LD8(pp);
            a0 += mb_pext_dot8(x, MB_PEXT_LD8(w));
            a1 += mb_pext_dot8(x, MB_PEXT_LD8(w + 8));
            pp += 8;
            w += 16;
        }
        if (simple) {
            out[0]       = MB_PEXT_OUT_SIMPLE(a0);
            out[ostride] = MB_PEXT_OUT_SIMPLE(a1);
        } else {
            out[0]       = mb_pext_requant_out(a0, q);
            out[ostride] = mb_pext_requant_out(a1, q);
        }
        out += 2 * ostride;
        i += 2;
    }
    wp += (size_t)pairs * G * 16;
    for (; i < ocn; i++) {
        const int8_t *w = wp;
        const int8_t *pp = p;
        int64_t a0 = bias ? bias[i] : 0;

        for (g = 0; g < G; g++) {
            a0 += mb_pext_dot8(MB_PEXT_LD8(pp), MB_PEXT_LD8(w));
            pp += 8;
            w += 8;
        }
        *out = simple ? MB_PEXT_OUT_SIMPLE(a0) : mb_pext_requant_out(a0, q);
        out += ostride;
        wp += (size_t)G * 8;
    }
#undef MB_PEXT_OUT_SIMPLE
}

/* Lay out one output-channel block's weights: `quads` groups of four interleaved
 * channels, then `pairs` groups of two, then the odd one out, each channel zero-padded
 * from K to KP.  Byte count is ocn*KP either way -- the interleave changes where the
 * bytes go, not how many there are. */
static void mb_pext_conv_repack(const int8_t *weight, int oc0, int ocn,
                                int K, int KP, int G, int8_t *wp)
{
    const int quads = ocn >> 2;
    const int pairs = (ocn - 4 * quads) >> 1;
    int i, g, j;

    for (i = 0; i < ocn; i++) {
        const int8_t *src = weight + (size_t)(oc0 + i) * K;
        int8_t *dst;
        int stride;

        if (i < 4 * quads) {
            dst = wp + (size_t)(i >> 2) * G * 32 + (size_t)(i & 3) * 8;
            stride = 32;
        } else if (i < 4 * quads + 2 * pairs) {
            const int u = i - 4 * quads;
            dst = wp + (size_t)quads * G * 32
                     + (size_t)(u >> 1) * G * 16 + (size_t)(u & 1) * 8;
            stride = 16;
        } else {
            const int u = i - 4 * quads - 2 * pairs;
            dst = wp + (size_t)quads * G * 32 + (size_t)pairs * G * 16
                     + (size_t)u * G * 8;
            stride = 8;
        }
        /* Eight bytes per group, straight-line for the same reason the gather is
         * straight-line: a `for (j = 0; j < 8; j++)` here compiled to a byte loop with a
         * bounds test per byte and measured 8 instructions per weight byte, 4.4% of the
         * kernel stream for a copy that happens once per dispatch. */
        for (g = 0; g < G; g++) {
            const int base = g * 8;
            if (base + 8 <= K) {
                dst[0] = src[base + 0]; dst[1] = src[base + 1];
                dst[2] = src[base + 2]; dst[3] = src[base + 3];
                dst[4] = src[base + 4]; dst[5] = src[base + 5];
                dst[6] = src[base + 6]; dst[7] = src[base + 7];
            } else {
                for (j = 0; j < 8; j++) {
                    dst[j] = (base + j < K) ? src[base + j] : 0;
                }
            }
            dst += stride;
        }
    }
}

void kernel_conv2d_s8(const int8_t *input, const int8_t *weight,
                      const int32_t *bias, int8_t *output,
                      int N, int IC, int IH, int IW, int OC,
                      int KH, int KW, int SH, int SW, int PH, int PW,
                      int input_offset, int filter_offset, int output_offset,
                      int output_multiplier, int output_shift,
                      int activation_min, int activation_max) {
    const int OH = (IH + 2*PH - KH) / SH + 1;
    const int OW = (IW + 2*PW - KW) / SW + 1;
    const int K  = IC * KH * KW;
    const int KP = (K + 7) & ~7;
    const int G  = KP >> 3;

    const int fast =
        (input_offset == 0) && (filter_offset == 0) &&
        (K > 0) && (KP <= MB_PEXT_CONV_PBYTES) && (KP <= MB_PEXT_CONV_WBYTES) &&
        (IC * KH <= MB_PEXT_CONV_MAXROWS) &&
        (OH > 0) && (OW > 0);

    if (fast) {
        const size_t ostride = (size_t)OH * OW;
        const int nrows = IC * KH;
        mb_pext_oq_t q;
        int ocb = MB_PEXT_CONV_WBYTES / KP;
        int n, oc0, j, ic, kh, oh, ow, t;

        mb_pext_oq_init(&q, output_multiplier, output_shift, output_offset,
                        activation_min, activation_max);
        if (ocb > OC) ocb = OC;

        /* The align8 tail of the patch is zero for every pixel and every channel, so it
         * is written once here rather than once per pixel. */
        for (j = K; j < KP; j++) {
            mb_pext_conv_patch[j] = 0;
        }

        for (n = 0; n < N; n++) {
        for (oc0 = 0; oc0 < OC; oc0 += ocb) {
            const int ocn = (OC - oc0 < ocb) ? (OC - oc0) : ocb;

            mb_pext_conv_repack(weight, oc0, ocn, K, KP, G, mb_pext_conv_wpack);

            for (oh = 0; oh < OH; oh++) {
                int8_t *orow = output +
                    ((size_t)(n * OC + oc0) * OH + oh) * OW;

                /* Resolve this output row's IC*KH source rows once. */
                t = 0;
                for (ic = 0; ic < IC; ic++) {
                    const int8_t *plane =
                        input + ((size_t)n * IC + ic) * IH * IW;
                    for (kh = 0; kh < KH; kh++) {
                        const int ih = oh * SH - PH + kh;
                        mb_pext_conv_rows[t++] =
                            ((unsigned)ih < (unsigned)IH)
                            ? plane + (size_t)ih * IW : (const int8_t *)0;
                    }
                }

                for (ow = 0; ow < OW; ow++) {
                    mb_pext_conv_gather(mb_pext_conv_rows, nrows, KW,
                                        ow * SW - PW, IW, mb_pext_conv_patch);
                    mb_pext_conv_pixel(mb_pext_conv_patch, mb_pext_conv_wpack,
                                       KP, G, ocn, bias ? bias + oc0 : 0,
                                       orow + ow, ostride, &q);
                }
            }
        }
        }
        return;
    }
    /* Refused: a non-zero zero point, a degenerate shape, or a reduction longer than the
     * scratch.  This is ModelBlaster's own reference expression, verbatim, so the kernel
     * is bit-exact on every shape rather than only on the ones it can accelerate. */
    {
        int n, oc, oh, ow, ic, kh, kw;
        for (n = 0; n < N; n++) {
            for (oc = 0; oc < OC; oc++) {
                for (oh = 0; oh < OH; oh++) {
                    for (ow = 0; ow < OW; ow++) {
                        int32_t acc = bias ? bias[oc] : 0;
                        for (ic = 0; ic < IC; ic++) {
                            const size_t in_row_base =
                                ((size_t)n * IC + ic) * IH;
                            for (kh = 0; kh < KH; kh++) {
                                int ih = oh * SH - PH + kh;
                                for (kw = 0; kw < KW; kw++) {
                                    int iw = ow * SW - PW + kw;
                                    int32_t in_v;
                                    int32_t w_v;
                                    if (ih < 0 || ih >= IH || iw < 0 || iw >= IW) {
                                        in_v = input_offset;
                                    } else {
                                        in_v = (int32_t)input[(in_row_base + ih) * IW + iw]
                                             + input_offset;
                                    }
                                    w_v = (int32_t)weight[((oc*IC + ic)*KH + kh)*KW + kw]
                                        + filter_offset;
                                    acc += in_v * w_v;
                                }
                            }
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
                            output[((n*OC + oc)*OH + oh)*OW + ow] = (int8_t)scaled;
                        }
                    }
                }
            }
        }
    }
}
