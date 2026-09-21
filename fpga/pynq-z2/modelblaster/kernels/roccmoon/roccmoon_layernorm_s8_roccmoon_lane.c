/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: roccmoon_lane */
/* accuracy_class: numeric_drift */
/*
 * PER-TENSOR LayerNorm ON THE LayerNorm LANE.
 *
 * WHY THIS FILE IS THE WHOLE GAP.  The lane serves `layernorm_pc_s8` and the shipping candidate
 * QATU emits per-tensor `layernorm_s8` -- the ONLY op QATU cannot reach a lane for.  It already
 * reaches the engine (b34, b35 arm A: linear_s8 and conv2d_s8 on roccmoon_engine) and the
 * attention unit (b35 arm E: attention_s8 -> roccmoon_lane, max_abs_err 0), so this is not an
 * extractor problem and never was.  Lab B41 measures the lane at 3.8632 c/el on M=165 K=288 --
 * QATU's exact LayerNorm shape -- against 60.67 for reference C.
 *
 * "PER-TENSOR" NAMES THE ACTIVATION SCALES, NOT THE AFFINE.  This op carries per-channel gamma
 * and beta exactly as `layernorm_pc_s8` does, over the same normalisation axis; the difference
 * is only that they arrive as FLOATS with tensor-level scales rather than pre-quantised
 * integers.  So the entry point is a derivation and then the same driver, and everything below
 * it -- the q16 core, the tiling, the staging, the fill/drain plan, the reference fallback --
 * is shared rather than copied.
 *
 * IT CHANGES THE OPERATOR'S ARITHMETIC, AND max_abs_err CANNOT SEE THAT.  The board lab's golden
 * is rebuilt from whatever kernel is selected, so once this file exists a bit-exactness check
 * compares the new arithmetic against itself and passes at 0.  The check that decides is WER
 * against the candidate's measured baseline: QATU_nl on dev-clean, 0.1059892 = 630 errors of
 * 5,944 words over 765 utterances (moonshine/model_qatu_long_c_dev.json), against a float
 * reference of 540 errors.  moonshine/ln_pt_check.py is the PREDICTOR, not the check: over all
 * 13 QATU sites the two cores differ on 0.17-0.24 % of elements, never by more than 1 LSB, with
 * zero elements differing by 2 or more.
 *
 * NOT YET RUN ON A BOARD.  The arithmetic is verified off-board twice -- ln_pt_check.py against
 * the tree's own pext_int_rsqrt kernel, and tb_mbxr --lanes' per-tensor case (constant 2^24
 * table, QATU's own eps_q, 165x288 through the six-tile sequence, bad = 0 of 47,520) -- and the
 * driver it calls is the one B41 measured.  What has not happened is a QATU image dispatching
 * through it.  That is a board arm, not a design question, and the row says so.
 */
#include <stddef.h>
#include <stdint.h>
#include "pext.h"
#include "roccmoon/mbxr_rt.h"
#include "roccmoon/mbxr_lanes.h"

#include "roccmoon/mbxr_ln_driver.h"

/* K is bounded by the lane's reach, not by this array: mbxr_ln_plan refuses a row wider than the
 * 1,024-word activation buffer long before K could reach this.  Sized to the same MBP_LN_MAXK
 * the per-tensor reference kernel uses, so a model that fits one fits the other. */
#ifndef MBXR_LN_PT_MAXK
#define MBXR_LN_PT_MAXK 1024
#endif

void kernel_layernorm_s8(const int8_t *input, const float *gamma, const float *beta,
			 int8_t *output, int M, int K, float scale_in, float scale_out,
			 float eps, int activation_min, int activation_max)
{
	static int32_t umul[MBXR_LN_PT_MAXK];
	static int64_t gmul[MBXR_LN_PT_MAXK], badd[MBXR_LN_PT_MAXK];
	int64_t eps_q;

	if (K > 0 && K <= MBXR_LN_PT_MAXK &&
	    mbxr_ln_derive_pt(gamma, beta, K, scale_in, scale_out, eps,
			      activation_min, activation_max, umul, gmul, badd, &eps_q)) {
		mbxr_ln_run(input, umul, gmul, badd, output, M, K, eps_q);
		return;
	}
	/* THE DERIVATION REFUSED, so this op is not expressible in the lane's fields -- an
	 * activation range narrower than int8, a gmul past int32, an eps below the lane's floor.
	 * There is no lane path and no q16 path either, because the q16 core IS what the lane
	 * computes.  Falling through silently would report a successful encoder that computed
	 * something else, so it is counted where the runtime's other fallbacks are counted. */
#if defined(__ZEPHYR__) && MBXR_LN_LANE
	mbxr_rt_stats.calls_fallback++;
#endif
	mbxr_ln_pt_reference(input, gamma, beta, output, M, K, scale_in, scale_out, eps,
			     activation_min, activation_max);
}
