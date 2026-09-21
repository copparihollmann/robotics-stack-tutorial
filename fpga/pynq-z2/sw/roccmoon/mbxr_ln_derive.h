/* SPDX-License-Identifier: Apache-2.0 */
/*
 * THE ARITHMETIC OF A PER-TENSOR LAYERNORM ON THE LayerNorm LANE.  Derivation only: this file
 * defines no kernel entry point and issues no dispatch, because the three copies of the lane
 * dispatch protocol are being factored into one helper and a fourth copy is the thing to avoid.
 * `kernel_layernorm_s8` is a ~20-line call on top of this, and it is sequenced separately.
 *
 * WHY IT EXISTS.  The LayerNorm lane serves `layernorm_pc_s8`, and the shipping candidate QATU
 * emits per-tensor `layernorm_s8` -- the ONLY op QATU cannot reach a lane for (it already
 * reaches the engine and the attention unit; b35_armE dispatches attention_s8 to roccmoon_lane
 * at max_abs_err 0).  So this is the whole gap between a measured 9.26x lane and the model the
 * campaign actually ships.
 *
 * WHAT "PER-TENSOR" MEANS HERE, because the name misleads: it names the ACTIVATION scales, not
 * the affine.  `layernorm_s8` carries per-channel gamma and beta exactly as `layernorm_pc_s8`
 * does, over the same normalisation axis.  The only difference is that its parameters arrive as
 * FLOATS with tensor-level scales instead of pre-quantised integers -- so the work is to do,
 * on the host side of a dispatch, what patches/0103's `layernorm()` does offline.  Every input
 * it needs is already an argument of `kernel_layernorm_s8`: gamma, beta, scale_in, scale_out,
 * eps.
 *
 * THE DERIVATION IS 0103's, TERM FOR TERM:
 *     umul[k] = rint(vec[k] / max(vec) * 2^24)      vec is the per-channel input scale
 *     gmul[k] = rint(gamma[k] / scale_out * 65536)
 *     badd[k] = rint(beta[k]  / scale_out * 65536)
 *     eps_q   = rint(eps * K^2 * (2^24 / scale_in)^2)
 * For a per-tensor input `vec` is constant -- `_chan_vec()`'s own docstring is "a per-tensor
 * scale repeated" -- so umul is the CONSTANT 2^24 on every channel and scale_in enters only
 * through eps_q.
 *
 * THE ONE RISK THAT IS NEW, AND IT IS TESTED RATHER THAN ASSERTED.  Per-CHANNEL puts only the
 * largest channel at umul = 2^24; per-TENSOR puts ALL K channels there at once, and the lane's
 * Q accumulates K terms of u^2.  That is a strictly harsher load than candidate R has ever
 * produced and it is not covered by mbxr_ln_consts_fit's bounds.  `tb_mbxr --lanes` carries the
 * case -- constant 2^24 table, QATU's own eps_q, 165x288 through the six-tile sequence -- at
 * bad = 0 of 47,520.  The lane can serve per-tensor.
 *
 * AND THE CHECK THAT DOES NOT WORK, stated because it is the trap: this changes the operator's
 * arithmetic from pext_int_rsqrt's mantissa/shift pipeline to _Q16_NORM_CORE.  `max_abs_err`
 * CANNOT see that -- the lab's host golden is rebuilt from the same new kernel, so it compares
 * the new arithmetic against itself and passes at 0.  The check is WER against the candidate's
 * measured baseline.  Measured separately (moonshine/ln_pt_check.py): over all 13 QATU sites
 * the two cores differ on 0.15-0.24 % of elements and NEVER by more than 1 LSB, with zero
 * elements differing by 2 or more.
 */
#ifndef MBXR_LN_DERIVE_H
#define MBXR_LN_DERIVE_H

#include <stdint.h>
#include <stddef.h>

#define MBXR_LN_DERIVE_F   24        /* _LN_F: per-channel input multiplier precision */
#define MBXR_LN_DERIVE_EPS_MIN  262144.0   /* mbxr_ln_cfg_ok: c_eps must be STRICTLY greater */

/* rint() without pulling in libm: the values here are positive-or-small and well inside the
 * int64 range by the checks below, so round-half-away-from-zero on a double is enough.  Kept
 * as one function so the rounding rule is stated once and matches 0103's np.rint on ties to
 * within the 1 LSB this whole substitution is already accepted to cost. */
static int64_t mbxr_ln_rint(double x)
{
	return (int64_t)(x < 0.0 ? x - 0.5 : x + 0.5);
}

/*
 * Derive one site's lane table.  Returns 1 and fills the arrays, or 0 if any field would
 * overflow -- in which case the caller must NOT dispatch to the lane.  The bounds are
 * mbxr_ln_consts_fit's and mbxr_ln_cfg_ok's, restated here so a refusal happens before any
 * instruction is issued rather than after.
 *
 * `out_umul` is filled with the constant for uniformity: the lane's table is written per
 * channel regardless, and a caller that special-cased a constant umul would have to special-
 * case it again the day a per-channel `layernorm_s8` appears.
 */
/* Newton on a double, so this include pulls in no libm.  Cold path only. */
static double mbxr_ln_sqrt(double v)
{
	double r = v > 1.0 ? v : 1.0;
	int i;

	if (!(v > 0.0))
		return 0.0;
	for (i = 0; i < 64; i++)
		r = 0.5 * (r + v / r);
	return r;
}

static int mbxr_ln_derive_pt(const float *gamma, const float *beta, int K,
			     float scale_in, float scale_out, float eps,
			     int activation_min, int activation_max,
			     int32_t *out_umul, int64_t *out_gmul, int64_t *out_badd,
			     int64_t *out_eps_q)
{
	const int32_t umul = (int32_t)1 << MBXR_LN_DERIVE_F;
	double s, E;
	int k;

	if (K <= 0 || scale_out <= 0.0f || scale_in <= 0.0f || eps <= 0.0f)
		return 0;
	/* THE LANE CLAMPS TO int8 AND ONLY TO int8.  A narrower activation range is not a slow
	 * path, it is a different function, so it is refused rather than approximated. */
	if (activation_min != -128 || activation_max != 127)
		return 0;
	/* umul is constant, so these two bounds are decided once rather than per channel */
	if (umul < 0 || umul >= (1 << 25))
		return 0;
	if ((int64_t)K * (int64_t)umul >= ((int64_t)1 << 40))
		return 0;

	for (k = 0; k < K; k++) {
		int64_t g = mbxr_ln_rint((double)(gamma ? gamma[k] : 1.0f) / (double)scale_out * 65536.0);
		int64_t b = mbxr_ln_rint((double)(beta  ? beta[k]  : 0.0f) / (double)scale_out * 65536.0);

		if (g < -(int64_t)0x80000000 || g > (int64_t)0x7fffffff)
			return 0;
		if (b < -(int64_t)0x80000000 || b > (int64_t)0x7fffffff)
			return 0;
		out_umul[k] = umul;
		out_gmul[k] = g;
		out_badd[k] = b;
	}

	/* eps in the Q16 units the lane's variance is computed in.  Done in double because the
	 * square of 2^24/scale_in overflows a float's exponent well before its mantissa matters,
	 * and because this runs ONCE PER SITE and never per dispatch. */
	s = (double)((int64_t)1 << MBXR_LN_DERIVE_F) / (double)scale_in;
	E = (double)eps * (double)K * (double)K * s * s;
	if (!(E > MBXR_LN_DERIVE_EPS_MIN) || E >= 9.2e18)
		return 0;                       /* mbxr_ln_cfg_ok's floor, and the int64 ceiling */
	*out_eps_q = mbxr_ln_rint(E);
	return 1;
}


/* THE LAST-RESORT PER-TENSOR REFERENCE, for the path where the derivation REFUSES.  Deliberately
 * plain: it is not the q16 core (that is what the lane computes, and if the fields do not hold it
 * cannot be used) and it is not pext_int_rsqrt (which lives in a different curated tree and is
 * not ours to include).  It is the operator's definition in double, honouring the activation
 * range the lane cannot.  If this ever runs in a measured image the run is not a lane
 * measurement, which is why the caller counts it as a fallback rather than taking it quietly. */
static void mbxr_ln_pt_reference(const int8_t *input, const float *gamma, const float *beta,
				 int8_t *output, int M, int K, float scale_in, float scale_out,
				 float eps, int activation_min, int activation_max)
{
	int m, k;

	for (m = 0; m < M; m++) {
		const int8_t *x = input + (size_t)m * (size_t)K;
		int8_t *y = output + (size_t)m * (size_t)K;
		double mean = 0.0, var = 0.0, inv;

		for (k = 0; k < K; k++)
			mean += (double)x[k] * (double)scale_in;
		mean /= (double)K;
		for (k = 0; k < K; k++) {
			double d = (double)x[k] * (double)scale_in - mean;
			var += d * d;
		}
		var /= (double)K;
		inv = 1.0 / mbxr_ln_sqrt(var + (double)eps);
		for (k = 0; k < K; k++) {
			double d = ((double)x[k] * (double)scale_in - mean) * inv;
			double v = (d * (double)(gamma ? gamma[k] : 1.0f)
				    + (double)(beta ? beta[k] : 0.0f)) / (double)scale_out;
			int64_t q = mbxr_ln_rint(v);

			if (q < activation_min) q = activation_min;
			if (q > activation_max) q = activation_max;
			y[k] = (int8_t)q;
		}
	}
}

#endif /* MBXR_LN_DERIVE_H */
