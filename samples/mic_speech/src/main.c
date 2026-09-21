/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Lab B122 -- SPEAK INTO THE MICROPHONE.  Lab B119 built the path from the PDM microphone
 * to the encoder's 64,000-sample int8 input grid and measured it at +50.26 dB, 12.68 dB
 * below the grid's own 37.58 dB floor, and then wrote down what it could not do:
 *
 *     "THE MEASUREMENT NOT MADE: NOBODY HAS SPOKEN INTO THIS MICROPHONE."
 *
 * The speaker (a USB audio device) and this board are on the same bench and driven by the
 * same host, so one process plays a known utterance and captures it.  The utterance is
 * LibriSpeech dev-clean 1272-128104-0014, "BY HARRY QUILTER M A", 2.245 s -- the SAME
 * utterance Lab B114 transcribed FROM FILE on this bitstream as "By Harry Quelter m a".
 * Same utterance, same model, two input paths.  The number that means anything is the
 * delta between them, not either absolute.
 *
 * ----------------------------------------------------------------------------------------
 * WHAT IS INHERITED FROM B119 AND MUST NOT BE RE-DERIVED
 *
 *  PREROLL = 1024 outputs.  STATUS[0] `settling` clearing is NOT when the output is usable.
 *  The DC blocker is y[n] = x[n] - x[n-1] + (1 - 2^-7)*y[n-1], a 128-sample pole starting
 *  from the 1074 counts of PDM DC that a 0.5164 density produces, so it needs 128*ln(1074)
 *  = 894 input samples = 48.2 ms AFTER settling clears.  B119's first arm ran 12.0 dB hot
 *  over its first 500 samples for exactly this reason.  1024 outputs is 64.0 ms.  Inherited
 *  verbatim, discarded, and MEASURED so it is not silently dropped.
 *
 *  fifo_reset, never clear_sticky, to arm the overrun watch (B110's defect, re-run below).
 *  The resampler itself: 539/625 exactly, 40 taps, cubic Farrow, b119_resamp.h UNCHANGED
 *  and not copied -- this sample compiles against samples/mic_window/src.
 *
 * ----------------------------------------------------------------------------------------
 * WHAT IS NEW, AND WHY EACH PIECE HAS TO BE
 *
 * 1. A 6.0 s CAPTURE, NOT A 4.0 s ONE.  The model wants 64,000 samples; the utterance is
 *    2.245 s.  Capturing 96,000 and choosing the window by energy onset means the required
 *    playback precision is +-0.5 s against serial jitter of milliseconds, so no chirp, no
 *    cross-correlation and no tight synchronisation is needed.  100 ppm of clock drift
 *    between the speaker's DAC and this decimator is 0.4 ms over 4 s and is ignored.
 *
 * 2. THE GAIN COMES FROM THE WINDOW IT IS APPLIED TO.  B119's auto-range pre-roll reads
 *    0.5 s that ENDS 0.6 s before the window starts.  On room noise those are the same
 *    thing (it validated at +0.9 dB); on speech they are not, and on a pre-roll taken
 *    before the talker starts they are ~40 dB apart.  So pass 1 stores the resampler's own
 *    int64 accumulator and pass 2 sets the gain from the chosen window's rms.  See
 *    b122_capture.h for why this does not change B119's arithmetic and for the
 *    byte-identity check that proves it.
 *
 *    ***THE PRE-ROLL IS STILL COMPUTED AND REPORTED.***  MS_GAIN prints the gain B119's
 *    rule would have chosen from the first 0.5 s of this very capture, and MS_CLIP prints
 *    how many of the 64,000 samples that gain WOULD have clipped.  That is the
 *    quantitative form of "speech would clip catastrophically", measured rather than
 *    predicted, and it costs no extra board time.
 *
 * 3. A 24 s LEVEL MONITOR BEFORE THE CAPTURE.  Block rms/peak/STATUS[4] every 0.25 s, with
 *    nothing printed until it is over so the console cannot perturb the FIFO.  Played into
 *    with an amplitude staircase it is the level calibration; played into with silence it
 *    is the contemporaneous room noise floor that the captured speech is measured against.
 *    Same image, same run, host's choice.
 *
 * ----------------------------------------------------------------------------------------
 * WHAT THIS STILL DOES NOT DO
 *
 * It does not run the model.  The combined encoder+prologue+decoder image has an open
 * correctness defect (max_abs_err 65, second inference wrong, Lab B117) and feeding it
 * microphone audio would confound the acoustic question with a known unrelated one.  The
 * standalone encoder is proven exact across two inferences and is a separate arm.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>
#include <stdint.h>

#include "b119_resamp.h"
#include "b122_capture.h"

#define MIC_BASE   0x10090000UL
#define R_ID       (MIC_BASE + 0x00)
#define R_CTRL     (MIC_BASE + 0x08)
#define R_STATUS   (MIC_BASE + 0x10)
#define R_LEVEL    (MIC_BASE + 0x18)
#define R_DATA     (MIC_BASE + 0x20)
#define R_RATE     (MIC_BASE + 0x28)
#define R_DEPTH    (MIC_BASE + 0x30)

#define ID_MAGIC          0x504D4331U
#define CTRL_ENABLE       0x1U
#define CTRL_FIFO_RESET   0x2U
#define CTRL_DC_BYPASS    0x4U
#define CTRL_CLR_STICKY   0x8U
#define ST_SETTLING       0x1U
#define ST_EMPTY          0x2U
#define ST_FULL           0x4U
#define ST_OVERRUN        0x8U
#define ST_SATURATED      0x10U

#define NOUT      64000              /* the encoder's IW */
#define NCAP      96000              /* 6.0 s: the window is CHOSEN out of this */
#define PREROLL    1024              /* B119's, inherited -- see the header */
#define SYN_N     16384              /* the synthetic control's output length */
#define RANGE_N    8000              /* B119's auto-range pre-roll, kept as a REPORTED control */

#define MON_BLK    4000              /* 0.25 s per level-monitor block */
#define MON_BLOCKS   96              /* ... 24.0 s of monitor */
#define PROF_BLK   1600              /* 0.1 s per capture-profile block */
#define NPROF     (NCAP / PROF_BLK)  /* 60 */
#define ONSET_LEAD 6400              /* 0.4 s of lead kept before the detected onset */

/* ------------------------------------------------------------------------------------------
 * LAB B130 -- TWO MORE WINDOWS OUT OF THE SAME CAPTURE, SO THE LEAD IS MEASURED AND NOT GUESSED
 *
 * B128 measured WER through this microphone at 35.21 % against 21.13 % from file and attributed
 * the larger half of the gap to a LATE ONSET DECISION: on 20 of its 32 captures its aligner
 * reported that the window "began inside the speech", 19 head-losses, median 139 ms, worst
 * 349 ms.  ***THAT FLAG COUNTS REFERENCE SAMPLES, NOT REFERENCE ENERGY.***  Its aligner reports
 * the lag to reference sample 0, and these LibriSpeech utterances open with 0.2-0.6 s of
 * near-silence 18-26 dB below their own rms.  Re-measured in energy on B128's OWN captures
 * (b130_lead.py, no board time): the 19 "lost heads" carry at most **0.0146 %** of their
 * utterance's energy, and against REAL speech onset this detector fires between 72 ms EARLY and
 * 170 ms LATE, median 32 ms early.  ***At ONSET_LEAD 6400 not one of the 32 captures lost
 * measurable speech at either end.***
 *
 * THE TRADE IS REAL AND IT IS THE OTHER WAY ROUND.  NOUT is 64,000 samples = 4.0 s and it does
 * not move, so every sample of lead is a sample of tail.  Writing s and e for the first and
 * last samples of real speech in the capture buffer, a lead L is safe only while
 *
 *     L >= d - s   (head: the window must start at or before the speech)   ... max 2,728 here
 *     L <= d - e + NOUT  (tail: it must end at or after it)                ... min 10,833 here
 *
 * so the feasible band on this 32-utterance set is [2728, 10833] samples, and it is checked at
 * three definitions of "speech" a decade apart (1 %, 0.1 %, 0.01 % of cumulative energy): the
 * intersection is [6971, 10537].  6400 sits 380 samples from the 0.1 % band's midpoint.
 * ***The lead B128's own prescription implies -- 6400 + its worst counted head-loss = 11,984 --
 * is OUTSIDE the band and costs u16 0.82 % of its energy off the TAIL.***
 *
 * So this sample no longer picks one.  It emits THREE windows from ONE 6.0 s capture:
 *
 *     A  ONSET_LEAD    6400   the shipped value, B128's arm M, byte-for-byte the same code
 *     B  ONSET_LEAD_B  8800   inside the feasible band at all three thresholds
 *     C  ONSET_LEAD_C 12000   B128's prescription -- zeroes every head-loss it counted
 *
 * They come from the SAME acoustic event, so the lead comparison is paired on the capture and
 * not confounded by the room, the level or the playback, which two separate batches would be.
 * Each gets its own two-pass gain from the window it is applied to, exactly as A does, so the
 * three differ in PLACEMENT and in nothing else.
 *
 * ARM A's ARITHMETIC IS UNTOUCHED: the same win_start, the same gain, the same MS_* tags, the
 * same MSD dump.  b122_score.py and scripts/79 parse this console unmodified; B and C print
 * under _B/_C suffixes and dump under MSE/MSF, which their regexes do not match.
 *
 * THE CONTROL THAT CAN FAIL: built with -DMS_DEFS="ONSET_LEAD_B=6400 ONSET_LEAD_C=6400" the
 * three windows must come out BYTE-IDENTICAL (MS_FNV == MS_FNV_B == MS_FNV_C, MSD == MSE ==
 * MSF).  If they do not, the extra windows are not the same computation at another offset and
 * nothing measured with them means anything.
 *
 * THIS IS NOT PREROLL.  PREROLL (1024) is B119's DC-blocker convergence and is a different
 * problem with a different reason; the two knobs are not folded together.
 */
#ifndef ONSET_LEAD_B
#define ONSET_LEAD_B 8800            /* 0.55 s -- B130's sized value */
#endif
#ifndef ONSET_LEAD_C
#define ONSET_LEAD_C 12000           /* 0.75 s -- B128's prescription, outside the band */
#endif

/* THE CALIBRATION TARGET, IN THE UNITS THE GRID IS STATED IN: int8 rms x1000.
 *
 * B119 used 21.773 -- the pinned 73-utterance corpus's int8 rms, which is the right target
 * for an arbitrary talker.  THIS lab compares against ONE file, and the honest comparison
 * puts the two windows on the same level by construction rather than by a fitted scalar:
 * host_quantise(1272-128104-0014 padded to 64,000) has int8 rms 11.9673 and peak 77, i.e.
 * 4.33 dB of headroom to +-127.  Overridable at build time; printed either way.
 */
#ifndef MS_TARGET_I8_RMS_MILLI
#define MS_TARGET_I8_RMS_MILLI  11967
#endif

int32_t b119_rs_bank[B119_RS_UP][B119_RS_N];   /* built at boot; see b119_resamp.h */

static int64_t  cap[NCAP];                     /* pass 1: the resampler's own accumulators */
static int8_t   win[NOUT];
static int8_t   win_b[NOUT];          /* B130: ONSET_LEAD_B out of the same capture */
static int8_t   win_c[NOUT];          /* B130: ONSET_LEAD_C out of the same capture */
static int8_t   syn_a[SYN_N], syn_b[SYN_N];
static int16_t  raw_head[1024];
static uint32_t hist256[256];
static uint32_t mon_rms[MON_BLOCKS], mon_peak[MON_BLOCKS], mon_st[MON_BLOCKS];
static uint32_t prof_rms[NPROF];

static void ctrl(uint32_t v) { sys_write32(v, R_CTRL); }

static uint32_t fnv1a(const int8_t *p, uint32_t n)
{
	uint32_t h = 2166136261u;

	for (uint32_t i = 0; i < n; i++) { h ^= (uint32_t)(uint8_t)p[i]; h *= 16777619u; }
	return h;
}

/* cos(2*pi*t), t in Q15 of one turn, result Q15 -- B119's table, for the synthetic control
 * only.  No libm and no float: the guest is CONFIG_FPU=n. */
static const int16_t COSQ[65] = {
	32767, 32610, 32138, 31357, 30273, 28899, 27246, 25330, 23170, 20787, 18205, 15447,
	12540, 9512, 6393, 3212, 0, -3212, -6393, -9512, -12540, -15447, -18205, -20787,
	-23170, -25330, -27246, -28899, -30273, -31357, -32138, -32610, -32767, -32610,
	-32138, -31357, -30273, -28899, -27246, -25330, -23170, -20787, -18205, -15447,
	-12540, -9512, -6393, -3212, 0, 3212, 6393, 9512, 12540, 15447, 18205, 20787,
	23170, 25330, 27246, 28899, 30273, 31357, 32138, 32610, 32767
};

static int32_t cos_q15(int64_t t_q15)
{
	int64_t t = t_q15 & 32767;
	int64_t idx = (t * 64) / 32768;
	int64_t frac = (t * 64) - idx * 32768;

	return (int32_t)(COSQ[idx] + ((COSQ[idx + 1] - COSQ[idx]) * frac) / 32768);
}

static uint32_t goertzel_db(const int8_t *x, uint32_t n, uint32_t f_milli, uint32_t fs)
{
	int64_t c = cos_q15(((int64_t)f_milli * 32768) / ((int64_t)fs * 1000));
	int64_t coeff = 2 * c, s0, s1 = 0, s2 = 0;
	uint64_t mag;
	uint32_t e = 0;

	for (uint32_t i = 0; i < n; i++) {
		s0 = (int64_t)x[i] + ((coeff * s1) >> 15) - s2;
		s2 = s1; s1 = s0;
		if (s1 > (1LL << 40) || s1 < -(1LL << 40)) { s1 >>= 8; s2 >>= 8; e += 8; }
	}
	{
		int64_t m = s1 * s1 + s2 * s2 - ((coeff * s1 * s2) >> 15);

		mag = (m < 0) ? 0 : (uint64_t)m;
	}
	{
		uint32_t lg = 0;
		uint64_t v = mag;

		while (v > 1) { v >>= 1; lg++; }
		return lg * 100u + 200u * e;
	}
}

static uint64_t isqrt64(uint64_t v)
{
	uint64_t r = 0, b = 1ULL << 40;

	while (b > v) { b >>= 2; }
	while (b) {
		if (v >= r + b) { v -= r + b; r = (r >> 1) + b; } else { r >>= 1; }
		b >>= 2;
	}
	return r;
}

/* ---- arming the microphone, B119's sequence verbatim ------------------------------------
 * fifo_reset, NOT clear_sticky: B110 found that CTRL[3] does not clear STATUS[3] overrun --
 * only the FIFO's own reset does -- contradicting pdm_mic_core.v's header and
 * MICROPHONE.md s3.6.  Re-run as a control in ovr_control() below.
 */
static uint32_t mic_arm(void)
{
	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE);
	while ((sys_read32(R_STATUS) & ST_SETTLING) != 0U) { }
	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET);
	ctrl(CTRL_ENABLE);
	while (sys_read32(R_LEVEL) != 0U) { (void)sys_read32(R_DATA); }
	while (sys_read32(R_LEVEL) == 0U) { }
	return sys_read32(R_STATUS);
}

/* ---- pass 1: capture NCAP accumulators --------------------------------------------------
 * PUSH-TO-TALK.  One MMIO load per sample, 2156 core cycles apart; the resampler needs
 * ~552 of them, so hart 0 is never the bottleneck and hart 1 is not used.  (B119: continuous
 * capture is an RTF problem, not a FIFO-drain problem -- RTF_e2e is 1.403303, so the model
 * eats 4.0 s of audio every 5.61 s no matter who drains the FIFO.)
 */
struct cap_result {
	uint32_t nin, nout, ticks;
	uint32_t st_first, st_or;
	int refused;
	uint32_t pre_rms, pre_peak;   /* the DISCARDED DC-blocker pre-roll, measured */
	struct b119_rs rs;
};

static void capture(struct cap_result *r, int64_t *dst, uint32_t want, uint32_t preroll)
{
	struct b119_rs *s = &r->rs;
	int64_t o[4];
	uint32_t got = 0, dropped = 0, nin = 0, st_or = 0;

	b119_rs_init(s, 1, 0);          /* pass 1 applies no gain at all */
	r->refused = 0;
	r->st_first = mic_arm();
	r->ticks = k_cycle_get_32();

	while (got < want) {
		uint32_t guard = 0;

		while (sys_read32(R_LEVEL) == 0U) {
			if (++guard > 400000000U) { r->refused |= 2; goto done; }
		}
		st_or |= sys_read32(R_STATUS);
		{
			int16_t v = (int16_t)sys_read32(R_DATA);
			int g;

			if (nin < 1024) { raw_head[nin] = v; }
			nin++;
			g = b122_rs_push_acc(s, v, o, 4);
			for (int j = 0; j < g; j++) {
				if (dropped < preroll) {
					dropped++;
					if (dropped == preroll) {
						r->pre_rms = (uint32_t)isqrt64((uint64_t)
							(s->sum_sq / (int64_t)(s->nout ? s->nout : 1)));
						r->pre_peak = (uint32_t)s->peak_abs;
						b119_rs_stats_reset(s);
					}
					continue;
				}
				if (got < want) { dst[got++] = o[j]; }
			}
		}
	}
done:
	r->ticks = k_cycle_get_32() - r->ticks;
	r->nin = nin; r->nout = got;
	r->st_or = st_or | sys_read32(R_STATUS);
	/* AN OVERRUN REFUSES THE WINDOW.  A 55 ms hole inside an utterance is a
	 * discontinuity, and transcribing one is worse than not transcribing it. */
	if (r->st_or & ST_OVERRUN) { r->refused |= 1; }
	ctrl(0U);
}

/* ---- the level monitor -------------------------------------------------------------------
 * MON_BLOCKS x 0.25 s of block rms / peak / sticky STATUS, accumulated in RAM and printed
 * only when it is over: a 60-byte printk is 5.2 ms at 115200 baud against a 55 ms FIFO, and
 * a level calibration that perturbed the thing it measures would be worthless.
 */
static void monitor(struct cap_result *r)
{
	struct b119_rs *s = &r->rs;
	int64_t o[4];
	uint32_t dropped = 0, nin = 0, st_or = 0;

	b119_rs_init(s, 1, 0);
	r->refused = 0;
	r->st_first = mic_arm();
	r->ticks = k_cycle_get_32();

	for (uint32_t b = 0; b < MON_BLOCKS; b++) {
		uint32_t got = 0;
		uint64_t ss = 0;
		int64_t pk = 0;
		uint32_t stb = 0;

		while (got < MON_BLK) {
			uint32_t guard = 0;

			while (sys_read32(R_LEVEL) == 0U) {
				if (++guard > 400000000U) { r->refused |= 2; goto done; }
			}
			stb |= sys_read32(R_STATUS);
			{
				int16_t v = (int16_t)sys_read32(R_DATA);
				int g = b122_rs_push_acc(s, v, o, 4);

				nin++;
				for (int j = 0; j < g; j++) {
					int64_t c;

					if (dropped < PREROLL) { dropped++; continue; }
					c = b122_counts(o[j]);
					if (c < 0) { c = -c; }
					if (c > pk) { pk = c; }
					ss += (uint64_t)(c * c);
					if (++got >= MON_BLK) { break; }
				}
			}
		}
		st_or |= stb;
		mon_rms[b] = (uint32_t)isqrt64(ss / MON_BLK);
		mon_peak[b] = (uint32_t)pk;
		mon_st[b] = stb;
	}
done:
	r->ticks = k_cycle_get_32() - r->ticks;
	r->nin = nin; r->nout = MON_BLOCKS * MON_BLK;
	r->st_or = st_or | sys_read32(R_STATUS);
	if (r->st_or & ST_OVERRUN) { r->refused |= 1; }
	ctrl(0U);
}

/* ---- control 1: the board's own 1000.000 Hz sine, through the same resampler -------------
 * A pass-through would put it at 1000 * 16000/18552.876 = 862.400 Hz.  Both bins are
 * measured in the same pass.  DIRECT and BANK evaluation orders must agree byte for byte.
 * AND -- new here -- the one-pass and two-pass quantisers must agree byte for byte.
 */
static void synth_control(void)
{
	struct b119_rs s;
	int8_t o8[4];
	int64_t o64[4];
	uint32_t got, i, t0, t1, tdir = 0, tbank = 0, nd;
	int mode;
	int32_t gm, gs;

	/* a gain that is neither 1 nor a power of two, so a dropped rounding shows up */
	b119_rs_gain_from_rms(37u, 21773u, &gm, &gs);

	for (mode = 0; mode < 2; mode++) {
		int8_t *dst = mode ? syn_b : syn_a;

		b119_rs_init(&s, gm, gs);
		s.use_bank = mode;
		got = 0;
		t0 = k_cycle_get_32();
		for (i = 0; got < SYN_N && i < 4u * SYN_N; i++) {
			int64_t t = ((int64_t)i * 1000 * 32768 * 1000) / B119_RS_FMIC_MILLIHZ;
			int16_t xv = (int16_t)((12000 * (int64_t)cos_q15(t - 8192)) >> 15);
			int g = b119_rs_push(&s, xv, o8, 4);

			for (int j = 0; j < g && got < SYN_N; j++) { dst[got++] = o8[j]; }
		}
		t1 = k_cycle_get_32();
		if (mode) { tbank = t1 - t0; } else { tdir = t1 - t0; }
	}
	nd = 0;
	for (i = 0; i < SYN_N; i++) { if (syn_a[i] != syn_b[i]) { nd++; } }
	printk("MS_SYNTH n=%u g1000_clog2=%u g862_clog2=%u g4000_clog2=%u verdict=%s\n",
	       SYN_N,
	       goertzel_db(syn_a + 512, 15360, 1000000u, 16000u),
	       goertzel_db(syn_a + 512, 15360,  862400u, 16000u),
	       goertzel_db(syn_a + 512, 15360, 4000000u, 16000u),
	       (goertzel_db(syn_a + 512, 15360, 1000000u, 16000u) >
	        goertzel_db(syn_a + 512, 15360, 862400u, 16000u) + 400u)
	       ? "RESAMPLED" : "PASSTHROUGH_OR_BROKEN");
	printk("MS_AB direct_ticks=%u bank_ticks=%u bytes_differing=%u of %u fnv_direct=0x%08x "
	       "fnv_bank=0x%08x verdict=%s\n", tdir, tbank, nd, SYN_N,
	       fnv1a(syn_a, SYN_N), fnv1a(syn_b, SYN_N),
	       nd == 0 ? "IDENTICAL" : "DISAGREE");

	/* ---- control 1b: ONE PASS vs TWO PASSES, the same gain, the same samples ----------
	 * This is the check that b122_capture.h's split did not change B119's arithmetic.
	 * syn_a already holds the one-pass int8 stream (DIRECT order, gain gm/2^gs).  Rebuild
	 * it through the two-pass path and require every byte to match. */
	b119_rs_init(&s, gm, gs);
	got = 0;
	for (i = 0; got < SYN_N && i < 4u * SYN_N; i++) {
		int64_t t = ((int64_t)i * 1000 * 32768 * 1000) / B119_RS_FMIC_MILLIHZ;
		int16_t xv = (int16_t)((12000 * (int64_t)cos_q15(t - 8192)) >> 15);
		int g = b122_rs_push_acc(&s, xv, o64, 4);

		for (int j = 0; j < g && got < SYN_N; j++) {
			syn_b[got++] = b122_quant(o64[j], gm, gs);
		}
	}
	nd = 0;
	for (i = 0; i < SYN_N; i++) { if (syn_a[i] != syn_b[i]) { nd++; } }
	printk("MS_TWOPASS gain_m=%d gain_s=%d n=%u bytes_differing=%u fnv_onepass=0x%08x "
	       "fnv_twopass=0x%08x verdict=%s\n", gm, gs, SYN_N, nd,
	       fnv1a(syn_a, SYN_N), fnv1a(syn_b, SYN_N),
	       nd == 0 ? "IDENTICAL" : "DISAGREE");
}

/* ---- control 2: B110's overrun defect, re-run -------------------------------------------- */
static void ovr_control(void)
{
	uint32_t a, b, c;

	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE);
	while ((sys_read32(R_STATUS) & ST_SETTLING) != 0U) { }
	k_msleep(200);                      /* 1024 samples is 55 ms; 200 ms MUST overrun */
	a = sys_read32(R_STATUS);
	ctrl(CTRL_ENABLE | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE);
	b = sys_read32(R_STATUS);
	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET);
	ctrl(CTRL_ENABLE);
	c = sys_read32(R_STATUS);
	printk("MS_OVR provoked=0x%02x after_clear_sticky=0x%02x after_fifo_reset=0x%02x "
	       "verdict=%s\n", a, b, c,
	       ((a & ST_OVERRUN) && (b & ST_OVERRUN) && !(c & ST_OVERRUN))
	       ? "B110_DEFECT_CONFIRMED" : "UNEXPECTED");
	ctrl(0U);
}

static void dump_tagged(const char *begin, const char *row, const char *end,
			const int8_t *x, uint32_t n)
{
	static const char hx[] = "0123456789abcdef";
	char line[129];

	printk("%s n=%u bytes_per_line=64\n", begin, n);
	for (uint32_t i = 0; i < n; i += 64) {
		uint32_t k = 0;

		for (uint32_t j = 0; j < 64 && i + j < n; j++) {
			uint8_t v = (uint8_t)x[i + j];

			line[k++] = hx[v >> 4]; line[k++] = hx[v & 15];
		}
		line[k] = 0;
		printk("%s %05u %s\n", row, i, line);
	}
	printk("%s\n", end);
}

static void dump_window(const int8_t *x, uint32_t n)
{
	dump_tagged("MS_DUMP_BEGIN", "MSD", "MS_DUMP_END", x, n);
}

static uint32_t rms_counts(const int64_t *a, uint32_t n)
{
	uint64_t ss = 0;

	for (uint32_t i = 0; i < n; i++) {
		int64_t c = b122_counts(a[i]);

		ss += (uint64_t)(c * c);
	}
	return (uint32_t)isqrt64(ss / (n ? n : 1));
}

/* B130 -- ONE MORE WINDOW OUT OF THE SAME CAPTURE, AT ANOTHER LEAD.
 *
 * This is arm A's own arithmetic with `lead` as a parameter and nothing else changed: the same
 * clamp, the same two-pass gain taken from the window it is applied to, the same round-shift,
 * the same +-127 clip, the same fnv.  It is deliberately a SEPARATE function rather than a
 * refactor of main(), so arm A's code path is not touched at all and its bytes cannot move.
 * The control that proves the two are the same computation is the identity build: with
 * ONSET_LEAD_B == ONSET_LEAD the dumps must be byte-identical.
 */
static void emit_window(const char *sfx, uint32_t lead, int onset_found, uint32_t onset_blk,
			int8_t *dst, const char *dbegin, const char *drow, const char *dend)
{
	uint32_t win_start, wrms, nclip = 0, nsat_hi = 0, nsat_lo = 0;
	int32_t gm, gs, mn = 127, mx = -128;
	int64_t sum = 0, sumabs = 0, sumsq = 0;
	uint32_t zeros = 0, distinct = 0;

	if (onset_found) {
		uint32_t o = onset_blk * PROF_BLK;

		win_start = (o > lead) ? (o - lead) : 0u;
		if (win_start > NCAP - NOUT) { win_start = NCAP - NOUT; }
	} else {
		win_start = 8000;
	}
	printk("MS_ONSET_%s lead=%u onset_sample=%u win_start=%u win_end=%u lead_samples=%u\n",
	       sfx, lead, onset_blk * PROF_BLK, win_start, win_start + NOUT,
	       onset_found ? (onset_blk * PROF_BLK - win_start) : 0u);

	wrms = rms_counts(cap + win_start, NOUT);
	b119_rs_gain_from_rms(wrms, MS_TARGET_I8_RMS_MILLI, &gm, &gs);
	printk("MS_GAIN_%s target_i8_rms_milli=%d window_rms_counts=%u gain_m=%d gain_s=%d\n",
	       sfx, MS_TARGET_I8_RMS_MILLI, wrms, gm, gs);

	for (uint32_t i = 0; i < NOUT; i++) {
		int64_t q = b119_rs_round_shift(cap[win_start + i] * (int64_t)gm,
						B119_RS_HQ + gs);

		if (q > 127) { q = 127; nclip++; nsat_hi++; }
		else if (q < -127) { q = -127; nclip++; nsat_lo++; }
		dst[i] = (int8_t)q;
	}
	printk("MS_CLIP_%s window_gain_clipped=%u sat_hi=%u sat_lo=%u of %d\n",
	       sfx, nclip, nsat_hi, nsat_lo, NOUT);

	for (int i = 0; i < 256; i++) { hist256[i] = 0; }
	for (uint32_t i = 0; i < NOUT; i++) {
		int32_t v = dst[i];

		if (v < mn) { mn = v; }
		if (v > mx) { mx = v; }
		sum += v; sumabs += (v < 0) ? -v : v; sumsq += (int64_t)v * v;
		if (v == 0) { zeros++; }
		hist256[(uint8_t)v]++;
	}
	for (int i = 0; i < 256; i++) { if (hist256[i]) { distinct++; } }
	printk("MS_WSTAT_%s n=%d min=%d max=%d mean_milli=%d meanabs_milli=%d rms_milli=%u "
	       "zeros=%u distinct=%u\n", sfx, NOUT, mn, mx,
	       (int)((sum * 1000) / NOUT), (int)((sumabs * 1000) / NOUT),
	       (uint32_t)isqrt64((uint64_t)((sumsq * 1000000) / NOUT)), zeros, distinct);
	printk("MS_FNV_%s window=0x%08x\n", sfx, fnv1a(dst, NOUT));
	dump_tagged(dbegin, drow, dend, dst, NOUT);
}

int main(void)
{
	struct cap_result r, mon;
	uint32_t hz = sys_clock_hw_cycles_per_sec();
	int32_t mn = 127, mx = -128;
	int64_t sum = 0, sumabs = 0, sumsq = 0;
	uint32_t zeros = 0, distinct = 0;
	uint32_t floor_rms, onset_thr, onset_blk, win_start;
	int onset_found;
	int32_t gm_win, gs_win, gm_pre, gs_pre;
	uint32_t wrms, prerms;
	uint32_t nclip = 0, nsat_hi = 0, nsat_lo = 0, nclip_pre = 0;

	printk("\nMS_BEGIN base=0x%08lx build=" __DATE__ " " __TIME__ "\n", (unsigned long)MIC_BASE);
	printk("MS_GUEST mtime_hz=%u\n", hz);
	printk("MS_CFG taps=%d D=%d q=%d hq=%d up=%d down=%d fmic_millihz=%d scale_x_e9=%d "
	       "nout=%d ncap=%d preroll=%d range_n=%d mon_blocks=%d mon_blk=%d prof_blk=%d "
	       "nprof=%d onset_lead=%d target_i8_rms_milli=%d onset_lead_b=%d onset_lead_c=%d\n",
	       B119_RS_N, B119_RS_D, B119_RS_Q, B119_RS_HQ, B119_RS_UP, B119_RS_DOWN,
	       B119_RS_FMIC_MILLIHZ, B119_RS_SCALE_X_E9, NOUT, NCAP, PREROLL, RANGE_N,
	       MON_BLOCKS, MON_BLK, PROF_BLK, NPROF, ONSET_LEAD, MS_TARGET_I8_RMS_MILLI,
	       ONSET_LEAD_B, ONSET_LEAD_C);

	{
		uint32_t id = sys_read32(R_ID), depth = sys_read32(R_DEPTH);

		printk("MS_REGS id=0x%08x depth=%u rate_reg_millihz=%u\n",
		       id, depth, sys_read32(R_RATE));
		if (id != ID_MAGIC || depth != 1024U) {
			printk("MS_VERDICT NOT_MAPPED\nMS_DONE\n");
			return 0;
		}
		printk("MS_GATE1 PASS id and depth are both exact\n");
	}

	{
		uint32_t t0 = k_cycle_get_32();

		b119_rs_build_bank();
		printk("MS_BANK bytes=%u build_ticks=%u\n",
		       (unsigned)sizeof(b119_rs_bank), k_cycle_get_32() - t0);
	}
	synth_control();
	ovr_control();

	/* ---- the level monitor.  The host either plays an amplitude staircase into this or
	 * plays nothing; either way the numbers below are what the microphone actually saw. */
	printk("MS_MON_BEGIN blocks=%d block_outputs=%d block_ms=%d total_ms=%d\n",
	       MON_BLOCKS, MON_BLK, (MON_BLK * 1000) / 16000,
	       (MON_BLOCKS * MON_BLK * 1000) / 16000);
	monitor(&mon);
	{
		uint32_t us = (uint32_t)(((uint64_t)mon.ticks * 1000000ULL) / hz);
		uint32_t lo = 0xffffffffu, hi = 0, sat = 0;

		for (uint32_t b = 0; b < MON_BLOCKS; b++) {
			if (mon_rms[b] < lo) { lo = mon_rms[b]; }
			if (mon_rms[b] > hi) { hi = mon_rms[b]; }
			if (mon_st[b] & ST_SATURATED) { sat++; }
		}
		printk("MS_MON nin=%u nout=%u us=%u status_or=0x%02x refused=%d min_rms=%u "
		       "max_rms=%u blocks_saturated=%u\n",
		       mon.nin, mon.nout, us, mon.st_or, mon.refused, lo, hi, sat);
		for (uint32_t b = 0; b < MON_BLOCKS; b++) {
			printk("MS_LVL b=%u rms=%u peak=%u sat=%u st=0x%02x\n",
			       b, mon_rms[b], mon_peak[b],
			       (mon_st[b] & ST_SATURATED) ? 1 : 0, mon_st[b]);
		}
	}

	/* ---- the capture.  MS_CAP_BEGIN is the host's cue to start playing. --------------- */
	printk("MS_CAP_BEGIN ncap=%d preroll=%d expect_inputs=%u expect_us=%u\n",
	       NCAP, PREROLL, b119_rs_inputs_for(NCAP + PREROLL),
	       (uint32_t)(((uint64_t)b119_rs_inputs_for(NCAP + PREROLL) * 1000000ULL * 1000ULL)
	                  / B119_RS_FMIC_MILLIHZ));
	capture(&r, cap, NCAP, PREROLL);
	{
		uint32_t us = (uint32_t)(((uint64_t)r.ticks * 1000000ULL) / hz);

		printk("MS_CAP nin=%u nout=%u ticks=%u us=%u status_first=0x%02x status_or=0x%02x "
		       "refused=%d saturated=%d peak_abs=%u rms=%u\n",
		       r.nin, r.nout, r.ticks, us, r.st_first, r.st_or, r.refused,
		       (r.st_or & ST_SATURATED) ? 1 : 0, (uint32_t)r.rs.peak_abs,
		       (uint32_t)isqrt64((uint64_t)(r.rs.sum_sq
		                                    / (int64_t)(r.rs.nout ? r.rs.nout : 1))));
		/* THE RATE, FROM THE CLOCK.  96,000 outputs take 6.0003 s through the resampler
		 * and 5.1744 s through a pass-through: 16 % apart and not confusable. */
		printk("MS_RATE nin=%u elapsed_us=%u in_rate_millihz=%u out_rate_millihz=%u "
		       "passthrough_us=%u\n", r.nin, us,
		       (uint32_t)(((uint64_t)r.nin * hz * 1000ULL) / (r.ticks ? r.ticks : 1)),
		       (uint32_t)(((uint64_t)r.nout * hz * 1000ULL) / (r.ticks ? r.ticks : 1)),
		       (uint32_t)((uint64_t)NCAP * 1000000000ULL / B119_RS_FMIC_MILLIHZ * 1000ULL
		                  / 1000ULL));
		printk("MS_TRANSIENT preroll_outputs=%d preroll_rms=%u preroll_peak=%u  "
		       "(the DC blocker converging; discarded and measured, B119's PREROLL)\n",
		       PREROLL, r.pre_rms, r.pre_peak);
	}

	/* ---- the energy profile and the onset ---------------------------------------------- */
	for (uint32_t b = 0; b < NPROF; b++) {
		prof_rms[b] = rms_counts(cap + (uint32_t)b * PROF_BLK, PROF_BLK);
	}
	printk("MS_PROF n=%d blk=%d", NPROF, PROF_BLK);
	for (uint32_t b = 0; b < NPROF; b++) { printk(" %u", prof_rms[b]); }
	printk("\n");

	floor_rms = 0xffffffffu;
	for (uint32_t b = 0; b < NPROF; b++) {
		if (prof_rms[b] < floor_rms) { floor_rms = prof_rms[b]; }
	}
	/* 12 dB over the quietest 0.1 s, twice in a row, so one click is not an onset.  The
	 * +4 keeps a dead-silent floor of 0 or 1 count from making the threshold trivial. */
	onset_thr = floor_rms * 4u + 4u;
	onset_found = 0;
	onset_blk = 0;
	for (uint32_t b = 0; b + 1 < NPROF; b++) {
		if (prof_rms[b] > onset_thr && prof_rms[b + 1] > onset_thr) {
			onset_blk = b; onset_found = 1; break;
		}
	}
	if (onset_found) {
		uint32_t s = onset_blk * PROF_BLK;

		win_start = (s > ONSET_LEAD) ? (s - ONSET_LEAD) : 0u;
		if (win_start > NCAP - NOUT) { win_start = NCAP - NOUT; }
	} else {
		/* NO ONSET IS NOT A FAILURE -- it is what the silence control must report.  The
		 * window is still assembled, from the nominal position, and scored as usual. */
		win_start = 8000;
	}
	printk("MS_ONSET found=%d floor_rms=%u thr=%u onset_blk=%u onset_sample=%u "
	       "win_start=%u win_end=%u lead_samples=%u\n",
	       onset_found, floor_rms, onset_thr, onset_blk, onset_blk * PROF_BLK,
	       win_start, win_start + NOUT,
	       onset_found ? (onset_blk * PROF_BLK - win_start) : 0u);

	/* ---- the gain, from the window it is applied to ------------------------------------ */
	wrms = rms_counts(cap + win_start, NOUT);
	prerms = rms_counts(cap, RANGE_N);            /* what B119's auto-range pre-roll reads */
	b119_rs_gain_from_rms(wrms, MS_TARGET_I8_RMS_MILLI, &gm_win, &gs_win);
	b119_rs_gain_from_rms(prerms, MS_TARGET_I8_RMS_MILLI, &gm_pre, &gs_pre);
	printk("MS_GAIN target_i8_rms_milli=%d window_rms_counts=%u gain_m=%d gain_s=%d "
	       "preroll_rms_counts=%u preroll_gain_m=%d preroll_gain_s=%d\n",
	       MS_TARGET_I8_RMS_MILLI, wrms, gm_win, gs_win, prerms, gm_pre, gs_pre);

	/* ---- pass 2: quantise, and price B119's rule on the same samples -------------------- */
	for (uint32_t i = 0; i < NOUT; i++) {
		int64_t q = b119_rs_round_shift(cap[win_start + i] * (int64_t)gm_win,
						B119_RS_HQ + gs_win);
		int64_t p = b119_rs_round_shift(cap[win_start + i] * (int64_t)gm_pre,
						B119_RS_HQ + gs_pre);

		if (q > 127) { q = 127; nclip++; nsat_hi++; }
		else if (q < -127) { q = -127; nclip++; nsat_lo++; }
		win[i] = (int8_t)q;
		if (p > 127 || p < -127) { nclip_pre++; }
	}
	printk("MS_CLIP window_gain_clipped=%u sat_hi=%u sat_lo=%u  "
	       "preroll_gain_would_clip=%u of %d\n", nclip, nsat_hi, nsat_lo, nclip_pre, NOUT);

	printk("MS_RAWHEAD");
	for (int i = 0; i < 32; i++) { printk(" %d", raw_head[i]); }
	printk("\n");

	for (int i = 0; i < 256; i++) { hist256[i] = 0; }
	for (uint32_t i = 0; i < NOUT; i++) {
		int32_t v = win[i];

		if (v < mn) { mn = v; }
		if (v > mx) { mx = v; }
		sum += v; sumabs += (v < 0) ? -v : v; sumsq += (int64_t)v * v;
		if (v == 0) { zeros++; }
		hist256[(uint8_t)v]++;
	}
	for (int i = 0; i < 256; i++) { if (hist256[i]) { distinct++; } }
	printk("MS_WSTAT n=%d min=%d max=%d mean_milli=%d meanabs_milli=%d rms_milli=%u "
	       "zeros=%u distinct=%u\n", NOUT, mn, mx,
	       (int)((sum * 1000) / NOUT), (int)((sumabs * 1000) / NOUT),
	       (uint32_t)isqrt64((uint64_t)((sumsq * 1000000) / NOUT)),
	       zeros, distinct);
	printk("MS_BAND");
	for (uint32_t f = 250; f <= 7000; f = (f * 2)) {
		printk(" %u:%u", f, goertzel_db(win, 16384, f * 1000u, 16000u));
	}
	printk("\n");
	printk("MS_FNV window=0x%08x\n", fnv1a(win, NOUT));
	for (int b = 0; b < 16; b++) {
		printk("MS_FNVB blk=%d off=%d fnv=0x%08x\n", b, b * 4000, fnv1a(win + b * 4000, 4000));
	}
	printk("MS_HIST");
	for (int i = 0; i < 256; i++) { printk(" %u", hist256[i]); }
	printk("\n");

	if (r.refused) {
		printk("MS_VERDICT REFUSED status_or=0x%02x refused=%d -- the window is NOT offered\n",
		       r.st_or, r.refused);
	} else {
		printk("MS_VERDICT WINDOW_OK n=%d onset_found=%d\n", NOUT, onset_found);
		dump_window(win, NOUT);
		/* B130: the same capture, two more leads.  Arm A above is untouched. */
		emit_window("B", ONSET_LEAD_B, onset_found, onset_blk, win_b,
			    "MS_DUMPB_BEGIN", "MSE", "MS_DUMPB_END");
		emit_window("C", ONSET_LEAD_C, onset_found, onset_blk, win_c,
			    "MS_DUMPC_BEGIN", "MSF", "MS_DUMPC_END");
	}
	printk("MS_DONE\n");
	return 0;
}
