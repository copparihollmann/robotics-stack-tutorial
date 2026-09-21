/* source: curated */
/* algorithm: direct */
/* accuracy_class: numeric_drift */
/* origin: hand-written, after ModelBlaster commit 49f5786 on branch
 *         riskybird-integer-dronet (kernels/gemmini_q31/gemmini_q31_add_s8_direct.c).
 *         INTEGER fixed-point two-scale residual add for the MBP/pext target on
 *         hart 0 of the PYNQ-Z1 big.LITTLE Rocket.
 *
 *   WHY.  add_s8's two inputs carry DIFFERENT scales, so it is not an add: it is two
 *   rescales and an add.  The ModelBlaster reference does that in float --
 *   clamp(roundf((a*scale_a + b*scale_b)/scale_out)) -- which on this WithoutFPU core
 *   is five libgcc soft-float calls per element, measured at 734 instructions per
 *   element in fpga/pynq-z2/docs/PEXT_SPEC.md sect 1.5.  That is the single most
 *   expensive element in DroNet's graph.
 *
 *   NO MBP INSTRUCTION APPLIES, AND THAT IS A DESIGN DECISION, NOT A GAP.
 *   PEXT_SPEC sect 2 "Rejected" records that a packed saturating byte add (padd8.sat)
 *   was considered and rejected for exactly this reason: the two operands are in
 *   different scales, so a lane-wise int8 add computes the wrong thing.  The correct
 *   form is two Q-format rescales into a common shift, one integer add, one rounding
 *   narrow -- which is plain RV64I, one instruction per step.  So this kernel uses no
 *   MBP at all.  It lives in the pext curated set because that is the kernel set this
 *   target resolves to, not because it uses the extension.
 *
 *   MATH (unchanged from 49f5786).  Fold each input's scale ratio into a Q(S) integer
 *   multiplier: ma = round((scale_a/scale_out)*2^S), mb likewise.  S is the largest
 *   value <= 24 that keeps acc = a*ma + b*mb inside int32 for the full int8 range.
 *   Then round-half-away(acc / 2^S), matching roundf, and clamp.
 *
 *   The setup here is O(1) PER DISPATCH, not per channel, so unlike the batchnorm
 *   companion there is nothing to win by making it integer: DroNet has three add
 *   dispatches, so the float search loop runs three times in the whole frame.  It is
 *   left exactly as 49f5786 wrote it, which keeps this kernel trivially comparable
 *   with the upstream one.
 *
 *   ACCURACY.  numeric_drift is the honest general class, and PEXT_SPEC sect 1.5 says
 *   so explicitly: the integer rescale-add "is not bit-exact against the float
 *   reference; it belongs in NUMERIC_DRIFT".  That is a statement about the general
 *   case and it is correct.  On DroNet's actual scales it does not drift, and that is
 *   exhaustive rather than sampled: add_s8 is an int8 x int8 -> int8 map, so 65,536
 *   pairs is the WHOLE domain of one dispatch, and all 196,608 cases of DroNet's three
 *   add dispatches were checked against the compiled float reference with
 *   max_abs_err = 0.  See fpga/pynq-z2/modelblaster/check/check_dronet_integer.c and
 *   fpga/pynq-z2/docs/DRONET_INTEGER.md.  The pipeline is the backstop regardless: the
 *   pext backend sets atol_override = 0.0, so a parameter set where this did drift
 *   would fail the curated verify and fall back to the reference expression.
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
static inline int32_t mb_add_rne_f2i(float v)
{
    int32_t t = (int32_t)v;                 /* truncate toward zero */
    float r = v - (float)t;                 /* exact remainder, |r| < 1 */
    float ar = r < 0.0f ? -r : r;
    int32_t step = v < 0.0f ? -1 : 1;
    if (ar > 0.5f) t += step;
    else if (ar == 0.5f && (t & 1)) t += step;   /* tie -> even */
    return t;
}


void kernel_add_s8(const int8_t *a, const int8_t *b, int8_t *output, int n,
                   float scale_a, float scale_b, float scale_out,
                   int activation_min, int activation_max)
{
    if (n <= 0) return;

    /* --- setup: once per dispatch --- */
    const float a_ratio = scale_a / scale_out;
    const float b_ratio = scale_b / scale_out;
    const float a_abs = a_ratio < 0 ? -a_ratio : a_ratio;
    const float b_abs = b_ratio < 0 ? -b_ratio : b_ratio;
    const float mx = a_abs > b_abs ? a_abs : b_abs;
    int S = 24;
    while (S > 1 && mx * (float)((uint32_t)1 << S) >= 8388608.0f) S--;
    const float pow2S = (float)((uint32_t)1 << S);          /* exact */
    const int32_t ma = mb_add_rne_f2i(a_ratio * pow2S);   /* == lrintf */
    const int32_t mb = mb_add_rne_f2i(b_ratio * pow2S);
    const int32_t rnd = (int32_t)1 << (S - 1);
    const int32_t lo = activation_min < -128 ? -128
                       : (activation_min > 127 ? 127 : activation_min);
    const int32_t hi = activation_max < -128 ? -128
                       : (activation_max > 127 ? 127 : activation_max);

    /* --- element loop: pure integer, no call, no float --- */
    for (int i = 0; i < n; i++) {
        int32_t acc = (int32_t)a[i] * ma + (int32_t)b[i] * mb;
        int32_t v = acc >= 0 ? (acc + rnd) >> S
                             : -(((-acc) + rnd) >> S);
        if (v < lo) v = lo;
        if (v > hi) v = hi;
        output[i] = (int8_t)v;
    }
}
