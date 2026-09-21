/* source: curated */
/* algorithm: pext_max8_rows */
/* accuracy_class: bit_exact */
/* origin: MBP.MAX8 on the big Rocket hart.  fpga/pynq-z2/sw/pext.h is the contract;
 *         PEXT_SPEC.md 2 ("MBP.MAX8 is justified by pooling, not by ReLU") the rationale. */

/*
 * maxpool2d_s8 for the MBP packed-integer extension, NCHW.
 *
 * Two passes, which is what NCHW makes natural: W is the innermost axis, so eight
 * *columns* of one row are contiguous and eight channels are not.
 *
 *   Pass 1 (vertical, SIMD).  For one output row, col[iw] = max over kh of
 *   input[ih0 + kh*DH][iw], computed eight columns at a time with MBP.MAX8.  KH loads
 *   and KH-1 MAX8s per eight columns, no lane interaction, nothing to extract.
 *
 *   Pass 2 (horizontal).  output[ow] = max over kw of col[ow*SW + kw*DW].  When the
 *   window is the common non-overlapping KW = SW = 2 (LeNet's pools, and every 2x2 pool
 *   in a convnet), this is also MAX8: max8(c, c >> 8) leaves the four pairwise maxima in
 *   lanes 0, 2, 4, 6, and four byte stores extract them.  Otherwise it is a scalar sweep
 *   over KW taps, which is still only KW compares per output because pass 1 already
 *   collapsed the vertical direction.
 *
 * ALIGNMENT IS A GUARANTEE, NOT A TEST (PEXT_SPEC.md 6.2).  An 8-byte load of a row
 * needs the plane base and the row stride both 8-aligned, so the fast path is entered
 * only when IW % 8 == 0 and the input pointer is 8-aligned -- ModelBlaster's buffers.c
 * declares plain `int8_t buf[N]` with no alignment attribute, so that is checked at
 * runtime rather than assumed.  LeNet's two pools (IW = 24 and IW = 8) and DroNet's
 * (IW = 56) all qualify; anything else runs the bit-exact scalar reference.
 *
 * Padding is INT8_MIN-filled per the spec, so a padded window can never select a zero
 * that was not in the input.  The fast path takes PH = PW = 0 only and leaves padded
 * pooling to the reference; DroNet's and LeNet's pools are unpadded.
 *
 * SINGLE-HART: static scratch, one pinned runner.  See the conv kernel's header.
 */

#include <stddef.h>
#include <stdint.h>
#include "pext.h"

/* One row of vertical maxima.  4 KB covers IW up to 4,088. */
#ifndef MB_PEXT_POOL_CBYTES
#define MB_PEXT_POOL_CBYTES 4096
#endif

static int8_t mb_pext_pool_col[MB_PEXT_POOL_CBYTES] __attribute__((aligned(8)));

void kernel_maxpool2d_s8(const int8_t *input, int8_t *output,
                         int N, int C, int IH, int IW,
                         int KH, int KW, int SH, int SW,
                         int PH, int PW, int DH, int DW) {
    const int OH = (IH + 2*PH - DH*(KH-1) - 1) / SH + 1;
    const int OW = (IW + 2*PW - DW*(KW-1) - 1) / SW + 1;

    const int fast =
        (PH == 0) && (PW == 0) && (DH == 1) && (DW == 1) &&
        (KH > 0) && (KW > 0) && (OH > 0) && (OW > 0) &&
        (IW > 0) && ((IW & 7) == 0) && (IW <= MB_PEXT_POOL_CBYTES) &&
        MB_PEXT_ALIGNED8(input);

    if (fast) {
        const int VG = IW >> 3;              /* 8-column groups per row */
        const int pair2 = (KW == 2) && (SW == 2);
        int n, c, oh, ow, kh, kw, g;

        for (n = 0; n < N; n++) {
        for (c = 0; c < C; c++) {
            const int8_t *plane = input + ((size_t)n * C + c) * IH * IW;
            int8_t *opl = output + ((size_t)n * C + c) * OH * OW;

            for (oh = 0; oh < OH; oh++) {
                const int8_t *r0 = plane + (size_t)(oh * SH) * IW;

                /* Pass 1: vertical maxima of the KH source rows, 8 columns at a time. */
                for (g = 0; g < VG; g++) {
                    int64_t v = MB_PEXT_LD8(r0 + 8 * g);
                    for (kh = 1; kh < KH; kh++) {
                        v = mb_pext_max8(v, MB_PEXT_LD8(r0 + (size_t)kh * IW + 8 * g));
                    }
                    MB_PEXT_ST8(mb_pext_pool_col + 8 * g, v);
                }

                /* Pass 2: horizontal maxima. */
                if (pair2) {
                    const int quads = OW >> 2;
                    for (g = 0; g < quads; g++) {
                        const int64_t c8 = MB_PEXT_LD8(mb_pext_pool_col + 8 * g);
                        const int64_t m =
                            mb_pext_max8(c8, (int64_t)((uint64_t)c8 >> 8));
                        int8_t *o = opl + (size_t)oh * OW + 4 * g;
                        o[0] = (int8_t)(int64_t)m;
                        o[1] = (int8_t)(int64_t)(m >> 16);
                        o[2] = (int8_t)(int64_t)(m >> 32);
                        o[3] = (int8_t)(int64_t)(m >> 48);
                    }
                    for (ow = quads * 4; ow < OW; ow++) {
                        const int8_t *s = mb_pext_pool_col + ow * 2;
                        opl[(size_t)oh * OW + ow] = (s[1] > s[0]) ? s[1] : s[0];
                    }
                } else {
                    for (ow = 0; ow < OW; ow++) {
                        const int8_t *s = mb_pext_pool_col + ow * SW;
                        int8_t mx = s[0];
                        for (kw = 1; kw < KW; kw++) {
                            if (s[kw] > mx) mx = s[kw];
                        }
                        opl[(size_t)oh * OW + ow] = mx;
                    }
                }
            }
        }
        }
        return;
    }

    /* Refused: padding, dilation, an odd row length, or an unaligned tensor.  This is
     * ModelBlaster's own reference expression, verbatim. */
    {
        int n, c, oh, ow, kh, kw;
        for (n = 0; n < N; n++) {
            for (c = 0; c < C; c++) {
                for (oh = 0; oh < OH; oh++) {
                    for (ow = 0; ow < OW; ow++) {
                        int8_t m = INT8_MIN;
                        for (kh = 0; kh < KH; kh++) {
                            int ih = oh*SH - PH + kh*DH;
                            if (ih < 0 || ih >= IH) continue;
                            for (kw = 0; kw < KW; kw++) {
                                int iw = ow*SW - PW + kw*DW;
                                int8_t v;
                                if (iw < 0 || iw >= IW) continue;
                                v = input[((n*C + c)*IH + ih)*IW + iw];
                                if (v > m) m = v;
                            }
                        }
                        output[((n*C + c)*OH + oh)*OW + ow] = m;
                    }
                }
            }
        }
    }
}
