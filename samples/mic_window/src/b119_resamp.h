/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Lab B119 -- THE PATH FROM THE MICROPHONE TO THE ENCODER'S INPUT TENSOR.
 *
 * ONE SOURCE, COMPILED TWICE.  This header is the whole arithmetic of the audio front
 * end, and Zephyr on the board and the host verifier in
 * fpga/pynq-z2/modelblaster/moonshine/b119_resamp.py --verify-c compile THE SAME FILE.
 * Nothing here is float: the guest is built CONFIG_FPU=n and every double on this hart is
 * soft-float (Lab B115 measured one such routine at 353,000 cycles per call).
 *
 * ------------------------------------------------------------------------------------
 * WHY A RESAMPLER AT ALL
 *
 * The PDM microphone's RATE register (0x28) reports 15,993,859 millihertz.  It is a
 * COMPILE-TIME Verilog constant computed for FCLK0 = 34.4828 MHz.  0x5A5A0035 runs at
 * 40.000000 MHz and the real rate is set by the divisor chain and nothing else:
 *
 *     f_mic = FCLK0 / (2*PDM_HALF * CIC_R * FIR_DECIM) = 40e6 / (14 * 22 * 7)
 *           = 40e6 / 2156 = 18,552.8757 Hz
 *
 * Lab B110 measured 18,552.875 Hz over 64,000 samples, -0.00004 % off that.  The
 * encoder's first dispatch is hard-shaped IW = 64000 samples at 16 kHz, so feeding raw
 * microphone samples would present speech 15.955 % fast.  The ratio is EXACT and rational:
 *
 *     f_out / f_mic = 16000 * 2156 / 40e6 = 34,496,000 / 40,000,000 = 539 / 625
 *
 * gcd(539, 625) = 1 (539 = 7*7*11, 625 = 5^4), so output k reads the input at
 * t_k = k * 625/539 input samples: index n_k = floor(k*625/539), fraction mu_k = m_k/539
 * with m_k = (k*625) mod 539.  Only 539 distinct fractions exist and the pattern repeats
 * every 539 outputs / 625 inputs.  Nothing here ever divides.
 *
 * ------------------------------------------------------------------------------------
 * WHY THE ANTI-ALIAS FILTER IS THIS LONG, MEASURED AND NOT ASSUMED
 *
 * The output Nyquist is 8000 Hz and the input Nyquist is 9276.4 Hz, so input content in
 * 8000..9276.4 Hz folds onto 6723.6..8000 Hz.  It would be comfortable to assume the
 * microphone's own 289-tap FIR has already removed it.  IT HAS NOT.  That FIR's stopband
 * edge is 8993 Hz AT ITS DESIGN RATE, which at 40 MHz scales to 10,431.8 Hz, and its
 * passband edge scales to 8119.3 Hz.  Evaluated from the shipping coefficients
 * (fpga/pynq-z2/src/pdm_fir_coeffs.vh, 289 taps, sum 586717) against the CIC^4/22 at
 * FCLK0 = 40 MHz, the chain's own response over the folding band is:
 *
 *     8000 Hz  -0.00 dB     8500 Hz  -0.37 dB     9000 Hz  -3.53 dB
 *     8119 Hz  -0.00 dB     8801 Hz  -1.70 dB     9276 Hz  -7.79 dB
 *
 * power-averaged over 8000..9276 Hz: -1.39 dB.  The folding band arrives essentially
 * UNATTENUATED and the entire anti-alias burden is on this filter.
 *
 * ------------------------------------------------------------------------------------
 * THE STRUCTURE, AND THE TWO PATHS THAT MUST AGREE BIT FOR BIT
 *
 * A Farrow (polynomial-interpolator) structure: each tap's weight is a cubic in mu,
 *
 *     h_mu[n] = C0[n] + mu*(C1[n] + mu*(C2[n] + mu*C3[n]))          n = 0 .. N-1
 *
 * so B119_RS_N * 4 integers describe every one of the 539 phases.  Two evaluation orders
 * are provided and THEY PRODUCE IDENTICAL BYTES, because both round the tap weight to the
 * same int32 h_q[n] at the same point and then run the same accumulation:
 *
 *   DIRECT  (b119_rs_out_direct)  evaluate the cubic per output.  N*4 multiplies,
 *                                 B119_RS_N*4*4 = 640 bytes of table.
 *   BANK    (b119_rs_out_bank)    evaluate all 539 phases ONCE at init into
 *                                 b119_rs_bank[539][N].  N multiplies per output,
 *                                 539*N*4 = 86,240 bytes, built from the same 640.
 *
 * The bank is NOT a 33.7 KB constant in the image: it is derived at boot from 640 bytes.
 * Having both is the control -- one arithmetic, two schedules, and a disagreement between
 * them is a defect report rather than a silent difference.
 *
 * ------------------------------------------------------------------------------------
 * THE QUANTISER IS THE HOST'S, TO THE TIE RULE
 *
 * model_dec_run.py packs the e2e graph's audio field as
 *
 *     q = np.clip(np.rint(w / sc["x"]), -127, 127).astype(np.int8)
 *
 * with w the float32 window on LibriSpeech's +-1.0 convention and sc["x"] the merged
 * graph's own input scale, 0.003431909275806016 (out/b116_lnsplit/ir_lnsplit/graph.json;
 * b114_e2e/ir_cse/graph.json carries the same value).  np.rint is round-half-to-EVEN, and
 * b119_rs_round_shift below implements that rule exactly rather than round-half-up: the
 * encoder's calibration was derived against this grid and a different tie rule is a
 * different grid.
 *
 * The microphone's own convention is fixed by its RTL: MICROPHONE.md s3.4 says the FIR
 * coefficients carry "the scale factor that makes the whole chain's DC gain exactly 32768,
 * so PDM density +-1 maps to +-full scale".  So mic float = pcm / 32768.0, and
 *
 *     int8 = rint_even( pcm * B119_MIC_GAIN / (32768 * 0.003431909275806016) )
 *          = rint_even( pcm * B119_MIC_GAIN / 112.45266... )
 *
 * with B119_MIC_GAIN the ONE calibration constant this path has.  It is carried as a
 * normalised (mantissa, shift) pair so that the whole chain is integer and the constant
 * itself is never the thing that moves an int8 byte.
 */
#ifndef B119_RESAMP_H_
#define B119_RESAMP_H_

#include <stdint.h>
#include "b119_rs_coeffs.h"     /* generated: B119_RS_N, B119_RS_Q, b119_rs_c[4][N], ... */

#define B119_RS_UP     539      /* f_out/f_mic = 539/625, exactly */
#define B119_RS_DOWN   625
#define B119_RS_HIST   64       /* power of two >= B119_RS_N, so the ring masks */
#define B119_RS_HQ     16       /* fractional bits of ONE TAP after the Farrow cubic */

/* WHY THE TAP IS ROUNDED TO Q16 AND THE COEFFICIENTS ARE NOT.  The cubic is evaluated in
 * Q(B119_RS_Q) = Q24 so its three Horner steps keep their precision, and the RESULT is
 * rounded once to Q16.  That is what bounds the accumulator:
 *
 *   |acc| <= 32767 * max_m sum_n |h_q[m][n]|  =  32767 * 137,363  =  2^32.07
 *
 * and it is what lets the gain be carried at nearly full int32 precision -- gain_m is
 * normalised into [2^28, 2^29), so acc * gain_m <= 2^61.1 and the ONE rounding in the
 * whole chain is the one that produces the int8.  Rounding the tap to Q16 costs 7.6e-6
 * per tap, which over 40 taps is 91 dB below the signal: two orders below the int8 input
 * grid's own 37.58 dB.  Carrying the tap at Q24 instead would put |acc| at 2^40.1 and
 * force either a second rounding or a gain quantised to 3.4e-6 -- and a gain quantised
 * that coarsely moves int8 bytes, which is the thing this layout exists to prevent.
 */

#if B119_RS_N > B119_RS_HIST
#error "B119_RS_HIST must be >= B119_RS_N"
#endif

struct b119_rs {
	int16_t  hist[B119_RS_HIST];  /* the last HIST input samples, newest at (wr-1)&mask */
	uint32_t wr;                  /* total input samples pushed, ever */
	uint32_t idx;                 /* input index the NEXT output reads (n_k) */
	uint32_t m;                   /* m_k = (k*625) mod 539, the phase numerator */
	int32_t  gain_m;              /* mantissa, normalised into [2^28, 2^29) */
	int32_t  gain_s;              /* G / (32768 * SCALE_X) == gain_m / 2^gain_s */
	int      use_bank;            /* 0 = evaluate the cubic per output, 1 = read the bank.
	                               * A RUNTIME choice, so one binary can run both orders
	                               * on the same input and prove they are byte-identical. */
	uint32_t nout;                /* outputs produced */
	uint32_t nclip;               /* outputs that hit +-127 */
	uint32_t nsat_lo, nsat_hi;    /* outputs at exactly -127 / +127 */
	int64_t  peak_abs;            /* max |resampled sample|, in int16 mic counts */
	int64_t  sum_sq;              /* sum of squares of the resampled samples */
};

/* ---- round-half-to-even, the rule np.rint uses -------------------------------------- */
static inline int64_t b119_rs_round_shift(int64_t v, int sh)
{
	int64_t half = (int64_t)1 << (sh - 1);
	int64_t frac = v & (((int64_t)1 << sh) - 1);      /* arithmetic: frac >= 0 */
	int64_t r = (v + half) >> sh;                     /* round half UP (toward +inf) */

	if (frac == half) {                               /* an exact tie */
		r -= (r & 1);                             /* ... goes to the EVEN neighbour */
	}
	return r;
}

/* mu in Q16 for phase numerator m: round(m * 65536 / 539), no runtime divide when the
 * caller keeps m incrementally.  539 fits in 10 bits so m*65536 fits in 26. */
static inline uint32_t b119_rs_mu_q16(uint32_t m)
{
	return (uint32_t)(((uint64_t)m * 65536u + 269u) / 539u);
}

/* The tap weight for one phase: the cubic in mu, rounded ONCE to int32 in Q(B119_RS_Q).
 * Both evaluation paths go through this function, which is why they cannot disagree. */
static inline int32_t b119_rs_tap(int n, uint32_t mu_q16)
{
	int64_t t = b119_rs_c[3][n];

	t = ((t * (int64_t)mu_q16) + 32768) >> 16;  t += b119_rs_c[2][n];
	t = ((t * (int64_t)mu_q16) + 32768) >> 16;  t += b119_rs_c[1][n];
	t = ((t * (int64_t)mu_q16) + 32768) >> 16;  t += b119_rs_c[0][n];
	/* Q24 -> Q16, round half to even, ONCE, here -- so the DIRECT and BANK paths cannot
	 * disagree about where the rounding happened. */
	return (int32_t)b119_rs_round_shift(t, B119_RS_Q - B119_RS_HQ);
}

/* The 539-phase bank.  NOT a constant in the image: 539*N*4 = %d bytes derived at boot
 * from the B119_RS_N*4 coefficients above.  Defined by the translation unit that wants it. */
extern int32_t b119_rs_bank[B119_RS_UP][B119_RS_N];

static inline void b119_rs_build_bank(void)
{
	for (uint32_t m = 0; m < B119_RS_UP; m++) {
		uint32_t mu = b119_rs_mu_q16(m);

		for (int n = 0; n < B119_RS_N; n++) {
			b119_rs_bank[m][n] = b119_rs_tap(n, mu);
		}
	}
}

static inline void b119_rs_init(struct b119_rs *s, int32_t gain_m, int32_t gain_s)
{
	for (int i = 0; i < B119_RS_HIST; i++) { s->hist[i] = 0; }
	s->wr = 0; s->idx = 0; s->m = 0; s->gain_m = gain_m; s->gain_s = gain_s;
	s->use_bank = 0;
	s->nout = 0; s->nclip = 0; s->nsat_lo = 0; s->nsat_hi = 0;
	s->peak_abs = 0; s->sum_sq = 0;
}

/* Zero the running statistics without touching the filter state.  THE LEVEL CALIBRATION
 * READS THESE, so they must cover the samples that are KEPT and not the pre-roll that is
 * thrown away -- Lab B119's first board arm set the gain 9.3 dB wrong from a pre-roll that
 * was measuring the DC blocker's startup transient. */
static inline void b119_rs_stats_reset(struct b119_rs *s)
{
	s->nout = 0; s->nclip = 0; s->nsat_lo = 0; s->nsat_hi = 0;
	s->peak_abs = 0; s->sum_sq = 0;
}

/* G / (32768 * SCALE_X) == gain_m / 2^gain_s, SCALE_X = 0.003431909275806016, with
 * gain_m normalised into [2^28, 2^29).  b119_resamp.py --design computes the pair and the
 * generated header carries the default; the board arm can override it with one measured
 * number without recompiling the coefficients. */
static inline void b119_rs_set_gain(struct b119_rs *s, int32_t gain_m, int32_t gain_s)
{
	s->gain_m = gain_m; s->gain_s = gain_s;
}

/* Accumulate one output.  base is the index of the FIRST tap: n_k - D, D = N/2 - 1. */
static inline int64_t b119_rs_acc(const struct b119_rs *s, uint32_t base, uint32_t mu_q16)
{
	int64_t acc = 0;
	uint32_t p = base & (B119_RS_HIST - 1);

	if (s->use_bank) {
		const int32_t *h = b119_rs_bank[s->m];

		for (int n = 0; n < B119_RS_N; n++) {
			acc += (int64_t)s->hist[p] * (int64_t)h[n];
			p = (p + 1) & (B119_RS_HIST - 1);
		}
	} else {
		for (int n = 0; n < B119_RS_N; n++) {
			acc += (int64_t)s->hist[p] * (int64_t)b119_rs_tap(n, mu_q16);
			p = (p + 1) & (B119_RS_HIST - 1);
		}
	}
	return acc;
}

/* Push one microphone sample.  Writes 0, 1 or 2 int8 outputs through `emit` and returns
 * how many.  (625/539 < 2, so at most one output per input in steady state; the loop is
 * written for `while` because the first outputs after a reset can bunch.) */
static inline int b119_rs_push(struct b119_rs *s, int16_t x, int8_t *out, int max_out)
{
	int n_emitted = 0;

	s->hist[s->wr & (B119_RS_HIST - 1)] = x;
	s->wr++;

	/* An output is ready once the newest sample is the LAST tap it needs:
	 * taps are idx-D .. idx-D+N-1, so we need wr-1 >= idx - D + N - 1. */
	while (s->idx + (B119_RS_N - 1 - B119_RS_D) < s->wr && n_emitted < max_out) {
		uint32_t mu = b119_rs_mu_q16(s->m);
		uint32_t base = s->idx - B119_RS_D;
		int64_t acc = b119_rs_acc(s, base, mu);
		int64_t v, q;

		/* statistics on the RESAMPLED signal, in int16 mic counts, before the gain.
		 * These are what the level calibration is read out of on the board. */
		v = b119_rs_round_shift(acc, B119_RS_HQ);
		if (v > s->peak_abs) { s->peak_abs = v; }
		if (-v > s->peak_abs) { s->peak_abs = -v; }
		s->sum_sq += v * v;

		/* ...then the encoder's own grid.  acc is Q16 in int16 mic counts and the gain
		 * is gain_m / 2^gain_s, so the product is Q(16+gain_s) in int8 counts.  ONE
		 * rounding, round-half-to-even, exactly as np.rint. */
		q = b119_rs_round_shift(acc * (int64_t)s->gain_m, B119_RS_HQ + s->gain_s);
		if (q >  127) { q =  127; s->nclip++; s->nsat_hi++; }
		else if (q < -127) { q = -127; s->nclip++; s->nsat_lo++; }
		out[n_emitted++] = (int8_t)q;
		s->nout++;

		/* advance: m += 625 (mod 539), idx += the carry.  625 = 539 + 86. */
		s->m += B119_RS_DOWN;
		while (s->m >= B119_RS_UP) { s->m -= B119_RS_UP; s->idx++; }
	}
	return n_emitted;
}

/* THE LEVEL CALIBRATION, AS INTEGER ARITHMETIC.
 *
 * The encoder's int8 grid was calibrated on LibriSpeech windows whose int8 rms is 21.773
 * counts (b119_resamp.py --quantcheck computes it over the pinned 73-utterance corpus:
 * 7,696,558 samples, float rms 0.075021 on a 0.003431909 grid).  So the calibration
 * target is stated IN int8 COUNTS and SCALE_X never appears at run time:
 *
 *     gain_m / 2^gain_s  =  target_int8_rms / measured_resampled_rms_in_mic_counts
 *
 * The normalisation puts gain_m in [2^28, 2^29) so the constant's own quantisation is
 * 2^-29 relative -- four orders below one int8 count, so the calibration can never be the
 * thing that moves a byte.
 */
static inline void b119_rs_gain_from_rms(uint32_t rms_counts, uint32_t target_milli,
					 int32_t *gm, int32_t *gs)
{
	uint64_t num = (uint64_t)target_milli;
	uint64_t den = (uint64_t)(rms_counts ? rms_counts : 1) * 1000u;
	int sh = 0;

	while (num < (den << 28) && sh < 33) { num <<= 1; sh++; }
	*gm = (int32_t)(num / den);
	*gs = sh;
}

/* How many input samples are needed for `nout` outputs, including the filter's warm-up. */
static inline uint32_t b119_rs_inputs_for(uint32_t nout)
{
	/* output nout-1 needs input index floor((nout-1)*625/539) - D + N - 1 */
	uint64_t last = ((uint64_t)(nout - 1) * B119_RS_DOWN) / B119_RS_UP;
	return (uint32_t)(last + B119_RS_N - B119_RS_D);
}

#endif /* B119_RESAMP_H_ */
