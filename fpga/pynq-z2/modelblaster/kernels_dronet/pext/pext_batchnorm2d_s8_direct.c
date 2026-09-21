/* source: curated */
/* algorithm: direct */
/* accuracy_class: numeric_drift */
/* origin: hand-written, after ModelBlaster commit 49f5786 on branch
 *         riskybird-integer-dronet (kernels/gemmini_q31/gemmini_q31_batchnorm2d_s8_direct.c).
 *         INTEGER fixed-point per-channel batchnorm2d_s8 for NCHW int8, for the
 *         MBP/pext target on hart 0 of the PYNQ-Z1 big.LITTLE Rocket.
 *
 *   WHY.  This SoC is built WithoutFPU (fpga/pynq-z2/docs/PEXT_SPEC.md sect 1.5), so the
 *   ModelBlaster reference expression -- dequantize, gamma*x+beta, roundf(/scale_out)
 *   -- is four libgcc soft-float calls per element.  Measured at 649 instructions
 *   per element.  On DroNet that is 11% of the frame with the scalar kernels and
 *   72% of it after the MBP convolution speedup, so it, not the convolution, is
 *   what caps the model.  chipyard_pynqz1_biglittle_pext.json states the answer in
 *   its own notes: "a per-channel LUT and an integer rescale-add, both software,
 *   neither needing an instruction".  This is the integer rescale; no MBP
 *   instruction is used, and none would help (the work is one multiply-add and a
 *   shift per element, already one instruction each).
 *
 *   WHY NOT THE LUT.  PEXT_SPEC sect 1.5 also measured the 256-entry per-channel LUT
 *   at 205x -- but only if the table is built once at model load.  Built per
 *   dispatch it costs 256 float reference evaluations per channel, measured at
 *   58,586,963 instructions, WORSE than the float reference it replaces, because
 *   DroNet's last batchnorm covers 16 pixels per channel and would pay 256
 *   evaluations to save 16.  ModelBlaster has no model-load hook to hang a table
 *   on, so the LUT is not reachable from a curated kernel.  This is.
 *
 *   MATH (unchanged from 49f5786, and that is deliberate -- it is the part that was
 *   already measured bit-exact on hardware).  Per channel fold the affine into Q(S)
 *   integers:  cs = scale[c]*scale_in/scale_out,  cb = bias[c]/scale_out,
 *   Mc = round(cs*2^S), Bc = round(cb*2^S).  S is the largest value <= 24 keeping
 *   Mc < 2^22 (so x*Mc < 2^29) and Bc < 2^30, which keeps acc = x*Mc + Bc inside
 *   int32.  Then round-half-away(acc / 2^S) -- which is what roundf does -- and clamp.
 *
 *   WHAT IS NEW HERE: THE SETUP IS INTEGER.  49f5786 finds S with a float loop,
 *      while (S > 1 && (csa*2^S >= 2^22 || cba*2^S >= 2^30)) S--;
 *   which is up to 23 iterations x 2 soft-float multiplies and 2 soft-float
 *   compares -- about 92 soft-float operations per channel.  With 128 batchnorm
 *   channels in DroNet that setup costs MORE than the entire element loop it is
 *   setting up, which is the cost ModelBlaster commit 7ba093d removed by baking the
 *   constants into generated source with an out-of-pipeline script.  We do not need
 *   a script, because the loop has a closed form.
 *
 *   Multiplying an IEEE-754 float by 2^S is EXACT (it only adds S to the exponent
 *   field), so for a normal x = 2^(E-127) * (1 + M/2^23) with M/2^23 in [0,1):
 *       x*2^S >= 2^22   <=>   E + S - 127 >= 22   <=>   S >= 149 - E
 *   -- exactly, with no boundary case, because the mantissa factor is in [1,2) and
 *   so can never carry the product across a power-of-two boundary from below.  The
 *   same argument on the 2^30 bound gives S >= 157 - Eb.  The loop's answer is
 *   therefore  S = clamp(min(148 - Ea, 156 - Eb), 1, 24)  computed from the two
 *   exponent fields with integer instructions and no soft-float at all.  E == 0
 *   (zero or denormal) contributes no constraint: |x| < 2^-126, so x*2^24 < 2^-102,
 *   which is below both bounds.  Verified identical to the float loop -- same S,
 *   same Mc, same Bc -- on every channel of every DroNet batchnorm.
 *
 *   What remains per channel is 3 float multiplies and 2 float-to-int conversions,
 *   about 5 soft-float calls instead of ~97.
 *
 *   ACCURACY.  numeric_drift is the honest general class and it is the class
 *   49f5786 declares: folding scale*scale_in/scale_out into one constant rounds
 *   differently from the reference's dequantize-then-divide, so on some parameter
 *   set some input could land on the other side of a rounding boundary.  It does
 *   not happen on DroNet.  That is not an assumption here, it is exhaustive:
 *   batchnorm2d_s8 is a per-channel int8 -> int8 map, so 256 inputs per channel is
 *   the WHOLE domain, and all 32,768 cases (128 channels x 256) of DroNet's three
 *   batchnorm dispatches were checked against the compiled float reference with
 *   max_abs_err = 0.  See fpga/pynq-z2/modelblaster/check/check_dronet_integer.c and
 *   fpga/pynq-z2/docs/DRONET_INTEGER.md.  The pipeline is the backstop in any case:
 *   the pext backend sets atol_override = 0.0, so a parameter set where this did
 *   drift would fail the curated verify and fall back to the reference expression,
 *   which is slow but correct.  It cannot silently produce wrong numbers.
 *
 *   Every shape is handled; there is no fast-path refusal and no fallthrough. */

#include <stdint.h>
#include <stddef.h>

/* Round-to-nearest, ties-to-even, float -> int32, without libm.
 * NAME IS FILE-UNIQUE ON PURPOSE: generate_kernels concatenates every curated
 * kernel for a model into ONE kernels.c translation unit, so a helper called
 * the same thing in two curated files is a redefinition error at build time.
 * (Found exactly that way -- this helper and its twin in the add_s8 kernel.)
 * This is lrintf()'s default-rounding-mode behaviour, and 49f5786 uses lrintf,
 * so matching it here keeps the two kernels the SAME function rather than two
 * functions that happen to agree.  It matters more than it looks: at the
 * magnitudes these constants take (~2^21..2^22) float32 spacing is 0.25, so a
 * quarter of all values land exactly on a .5 tie, and a naive `(int32)(v+0.5f)`
 * differs from lrintf on every one of them -- 33 of DroNet's 128 channels.
 * (Those +-1 differences in a Q22 constant do not reach the int8 output on this
 * model -- checked exhaustively -- but "does not reach the output" is luck, and
 * this is construction.)
 * `v - (float)t` is exact: |v| here is well under 2^23, so t is representable
 * and the subtraction is a Sterbenz-exact cancellation. */
static inline int32_t mb_bn_rne_f2i(float v)
{
    int32_t t = (int32_t)v;                 /* truncate toward zero */
    float r = v - (float)t;                 /* exact remainder, |r| < 1 */
    float ar = r < 0.0f ? -r : r;
    int32_t step = v < 0.0f ? -1 : 1;
    if (ar > 0.5f) t += step;
    else if (ar == 0.5f && (t & 1)) t += step;   /* tie -> even */
    return t;
}

/* Exponent field of a float, read as an integer. Bit-punned through a union
 * rather than a cast so this stays strict-aliasing-clean at -O2. */
static inline int mb_bn_expfield(float v)
{
    union { float f; uint32_t u; } p;
    p.f = v;
    return (int)((p.u >> 23) & 0xFFu);
}

/* The closed form of 49f5786's float search loop. See the header comment. */
static inline int mb_bn_shift_for(float cs, float cb)
{
    int ea = mb_bn_expfield(cs);        /* sign bit is not in the field, so this */
    int eb = mb_bn_expfield(cb);        /* is already the exponent of |cs|, |cb|  */
    int s = 24;
    if (ea != 0) {                      /* ea == 0 => |cs| < 2^-126, no constraint */
        int lim = 148 - ea;
        if (lim < s) s = lim;
    }
    if (eb != 0) {
        int lim = 156 - eb;
        if (lim < s) s = lim;
    }
    return s < 1 ? 1 : s;               /* the loop's own `S > 1` floor */
}

void kernel_batchnorm2d_s8(const int8_t *input, const float *scale,
                           const float *bias, int8_t *output,
                           int N, int C, int H, int W,
                           float scale_in, float scale_out,
                           int activation_min, int activation_max)
{
    const float inv_so = 1.0f / scale_out;
    const int32_t lo = activation_min < -128 ? -128
                       : (activation_min > 127 ? 127 : activation_min);
    const int32_t hi = activation_max < -128 ? -128
                       : (activation_max > 127 ? 127 : activation_max);
    const long hw = (long)H * (long)W;

    for (int n = 0; n < N; n++) {
        for (int c = 0; c < C; c++) {
            /* --- per-channel setup: 3 soft-float multiplies, 2 conversions --- */
            const float cs = scale[c] * scale_in * inv_so;
            const float cb = bias[c] * inv_so;
            const int S = mb_bn_shift_for(cs, cb);
            const float pow2S = (float)((uint32_t)1 << S);   /* exact */
            const int32_t Mc = mb_bn_rne_f2i(cs * pow2S);   /* == lrintf */
            const int32_t Bc = mb_bn_rne_f2i(cb * pow2S);
            const int32_t rnd = (int32_t)1 << (S - 1);

            /* --- element loop: pure integer, no call, no float --- */
            const long base = ((long)n * C + c) * hw;
            const int8_t *in = input + base;
            int8_t *out = output + base;
            for (long i = 0; i < hw; i++) {
                int32_t acc = (int32_t)in[i] * Mc + Bc;
                /* round-half-away from zero, matching roundf */
                int32_t v = acc >= 0 ? (acc + rnd) >> S
                                     : -(((-acc) + rnd) >> S);
                if (v < lo) v = lo;
                if (v > hi) v = hi;
                out[i] = (int8_t)v;
            }
        }
    }
}
