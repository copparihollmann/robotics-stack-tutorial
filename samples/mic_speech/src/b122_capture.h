/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Lab B122 -- THE TWO-PASS CAPTURE, AND WHY IT IS NOT A REWRITE OF B119'S ARITHMETIC.
 *
 * B119 produced one int8 output per input sample with a gain that had been fixed 0.6 s
 * earlier by a 0.5 s auto-range pre-roll.  Its own write-up names the defect that leaves:
 *
 *     "G = 136.03 is calibrated to a -60.9 dBFS noise floor BECAUSE NOBODY SPOKE.  Speech
 *      would clip catastrophically.  The level range is ~40 dB, so no single baked
 *      constant covers it."
 *
 * A pre-roll cannot fix that either: a 0.5 s window of a 2.25 s utterance is not the
 * utterance's level, and a pre-roll taken BEFORE the talker starts is the room's level.
 * So this lab keeps the resampler exactly as B119 built it and moves ONE step later:
 *
 *   pass 1   push every microphone sample through b119_rs_push's OWN accumulator and keep
 *            the int64 `acc` (Q16 in int16 microphone counts).  No gain, no quantiser, no
 *            rounding beyond the one b119_rs_tap already did.
 *   pass 2   choose the 64,000-output window, measure ITS rms, derive the gain FROM IT,
 *            and quantise -- with the single expression b119_rs_push uses, unchanged.
 *
 * ***THE RISK THIS CREATES, AND THE CONTROL THAT CATCHES IT.***  Splitting a function is
 * exactly how an arithmetic silently changes.  So the board runs the SAME synthetic tone
 * through b119_rs_push (one pass, fixed gain) and through b122_rs_push_acc + b122_quant
 * (two passes, the same fixed gain) and requires the two int8 streams to be BYTE-IDENTICAL.
 * That check is printed as MS_TWOPASS and it runs in the same pass as the claim, which is
 * the shape Lab B110's `dc_bypass` arm established.
 *
 * b119_resamp.h itself is NOT copied and NOT edited: samples/mic_speech builds against
 * samples/mic_window/src, so there is one file and it is the one the host verifier
 * (b119_resamp.py --verify-c) compiles.
 */
#ifndef B122_CAPTURE_H_
#define B122_CAPTURE_H_

#include "b119_resamp.h"

/* b119_rs_push, with the gain/quantise step replaced by "hand me the accumulator".
 *
 * Everything above the marked line is b119_rs_push VERBATIM -- the same history write, the
 * same readiness predicate, the same b119_rs_acc call, the same v = round_shift(acc, HQ)
 * statistics, and the same phase advance.  Only the two lines that apply the gain and clip
 * to int8 are missing, and b122_quant below is those two lines. */
static inline int b122_rs_push_acc(struct b119_rs *s, int16_t x, int64_t *out, int max_out)
{
	int n_emitted = 0;

	s->hist[s->wr & (B119_RS_HIST - 1)] = x;
	s->wr++;

	while (s->idx + (B119_RS_N - 1 - B119_RS_D) < s->wr && n_emitted < max_out) {
		uint32_t mu = b119_rs_mu_q16(s->m);
		uint32_t base = s->idx - B119_RS_D;
		int64_t acc = b119_rs_acc(s, base, mu);
		int64_t v;

		v = b119_rs_round_shift(acc, B119_RS_HQ);
		if (v > s->peak_abs) { s->peak_abs = v; }
		if (-v > s->peak_abs) { s->peak_abs = -v; }
		s->sum_sq += v * v;

		/* ---- the only difference from b119_rs_push ---------------------------- */
		out[n_emitted++] = acc;
		/* ----------------------------------------------------------------------- */
		s->nout++;

		s->m += B119_RS_DOWN;
		while (s->m >= B119_RS_UP) { s->m -= B119_RS_UP; s->idx++; }
	}
	return n_emitted;
}

/* b119_rs_push's quantiser, character for character (its lines 271-274), lifted so that
 * pass 2 cannot drift from pass 1.  `nclip`/`nsat_*` are counted by the caller because a
 * two-pass run wants them per candidate gain, not per stream. */
static inline int8_t b122_quant(int64_t acc, int32_t gain_m, int32_t gain_s)
{
	int64_t q = b119_rs_round_shift(acc * (int64_t)gain_m, B119_RS_HQ + gain_s);

	if (q > 127) { q = 127; }
	else if (q < -127) { q = -127; }
	return (int8_t)q;
}

/* The int16 microphone count a stored accumulator stands for -- b119_rs_push's `v`. */
static inline int64_t b122_counts(int64_t acc)
{
	return b119_rs_round_shift(acc, B119_RS_HQ);
}

#endif /* B122_CAPTURE_H_ */
