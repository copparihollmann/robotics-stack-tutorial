/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Lab B119 -- ASSEMBLE THE ENCODER'S 64,000-SAMPLE int8 INPUT WINDOW FROM THE MICROPHONE.
 *
 * This lab does NOT run the model.  The combined image has an open correctness defect
 * (max_abs_err 65, Lab B117 is chasing it) and feeding it microphone audio would confound
 * two unknowns.  What this produces is the WINDOW, and the evidence that it is well formed.
 *
 * ----------------------------------------------------------------------------------------
 * PUSH-TO-TALK, AND WHY IT IS NOT A COMPROMISE
 *
 * The FIFO is 1024 samples = 55.2 ms at 18,552.876 Hz and one inference takes 3.34 s, so
 * continuous capture would need hart 1 draining into DRAM while hart 0 runs the model.
 * IT IS NOT BUILT, AND THE REASON IS ARITHMETIC RATHER THAN EFFORT:
 *
 *     RTF_e2e on this image is 1.403303 (Lab B116, out/b116_lnsplit).  RTF > 1 means the
 *     model consumes 4.0 s of audio every 5.61 s of wall clock.  A perfectly drained FIFO
 *     does not change that; the backlog grows without bound at 1.61 s per utterance.
 *     CONTINUOUS CAPTURE IS NOT A DRAIN PROBLEM ON THIS IMAGE, IT IS AN RTF PROBLEM, and
 *     it becomes possible exactly when RTF crosses 1 -- which is the session's own target.
 *
 * So: hart 0 captures for 4.0022 s, filling the window, and only then would inference run.
 * One MMIO load per sample is 2156 core cycles apart and the resampler needs ~552 of them
 * (below), so the capturing hart is never the bottleneck and hart 1 is not needed.  The
 * cost of the choice is a gap between utterances, not a glitch inside one.
 *
 * ----------------------------------------------------------------------------------------
 * THE THREE CONTROLS, EACH OF WHICH CAN FAIL
 *
 *  1. THE RATE, by the clock and not by the register.  64,000 OUTPUT samples require
 *     74,212 input samples, which at 18,552.876 Hz is 4.0002 s.  If the resampler were a
 *     pass-through the same 64,000 outputs would take 3.4496 s.  Measured against mtime,
 *     those two are 16 % apart and cannot be confused.
 *
 *  2. THE ARITHMETIC, on a signal the board generates itself.  A 1000.000 Hz sine is
 *     synthesised AT f_mic, pushed through the SAME resampler, and Goertzel'd at 1000 Hz
 *     and at 862.400 Hz (= 1000 * 16000/18552.876, where a pass-through would put it).
 *     This needs no acoustic source and it is the direct analogue of Lab B110's
 *     `dc_bypass` arm: the discriminating control runs in the same pass as the claim.
 *
 *  3. THE TWO EVALUATION ORDERS.  MP2_AB runs the window again through the BANK order
 *     (539 phases materialised at boot from the same 640 bytes of coefficients) and the
 *     two must be BYTE-IDENTICAL.  They are also timed, which is the measurement that
 *     answers "is a 539-phase table affordable against a 16 KB L1D" instead of arguing it.
 *
 * ----------------------------------------------------------------------------------------
 * THE DEFECT THIS CODE IS SHAPED AROUND
 *
 * Lab B110 found that CTRL[3] `clear_sticky` does NOT clear STATUS[3] `overrun` -- only
 * `fifo_reset` does -- contradicting pdm_mic_core.v's own header and MICROPHONE.md s3.6.
 * The RTL says why: STATUS[4] `saturated` is a sticky register cleared by `clear_pulse`,
 * but STATUS[3] is `fifo_overrun`, a reg INSIDE pdm_mic_fifo.v cleared only by its `rst`.
 * So this lab (a) re-runs that as a control, and (b) uses fifo_reset, never clear_sticky,
 * to arm the overrun watch.  An overrun REFUSES the window; it does not transcribe a
 * discontinuity.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>
#include <stdint.h>

#include "b119_resamp.h"

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

#define NOUT   64000                 /* the encoder's IW */

int32_t b119_rs_bank[B119_RS_UP][B119_RS_N];   /* built at boot; see b119_resamp.h */

#define NOUT     64000               /* the encoder's IW */
/* PREROLL -- WHAT IS DISCARDED, AND WHY IT IS 1024 AND NOT 40.
 *
 * The resampler's own 40-tap history fills in 40 input samples (34 outputs).  That is NOT
 * what dominates.  Lab B119's first board arm captured a window whose first 500 output
 * samples carried a decaying transient 12 dB above the steady state, and the arithmetic
 * names it exactly: the DC blocker is y[n] = x[n] - x[n-1] + (1 - 2^-7)*y[n-1], a pole
 * with a 128-sample time constant, and it starts from ZERO facing the 1074 counts of DC
 * that the microphone's 0.5164 PDM density produces (MICROPHONE.md s3.5).  Decaying 1074
 * counts to below 1 takes 128*ln(1074) = 894 input samples = 48.2 ms.
 *
 * ***STATUS[0] `settling` CLEARING IS NOT THE MOMENT THE OUTPUT IS USABLE.***  The SETTLE
 * counter (131,072 PDM bits = 45.875 ms) holds the CIC and FIR in reset; the DC blocker
 * only BEGINS converging when samples start to flow.  1024 outputs is 64.0 ms, past the
 * 48.2 ms the pole needs, and the discarded pre-roll is MEASURED and printed rather than
 * silently dropped.
 */
#define PREROLL   1024
#define SYN_N    16384               /* the synthetic control's output length */
#define RANGE_N   8000               /* the auto-range pre-roll: 0.5 s of outputs */
/* The encoder's own int8 grid, in the units the calibration is stated in: the pinned
 * corpus's int8 rms, x1000.  b119_resamp.py --quantcheck computes it (21.773 counts over
 * 7,696,558 samples).  NOTHING else about the grid is needed on the board. */
#define TARGET_I8_RMS_MILLI  21773

static int8_t  win[NOUT];
static int8_t  syn_a[SYN_N], syn_b[SYN_N];
static int16_t raw_head[1024];
static uint32_t hist256[256];

static uint32_t gain_m = B119_RS_GAIN_M_DEFAULT;
static int32_t  gain_s = B119_RS_GAIN_S_DEFAULT;

static void ctrl(uint32_t v) { sys_write32(v, R_CTRL); }

static uint32_t fnv1a(const int8_t *p, uint32_t n)
{
	uint32_t h = 2166136261u;

	for (uint32_t i = 0; i < n; i++) { h ^= (uint32_t)(uint8_t)p[i]; h *= 16777619u; }
	return h;
}

/* cos(2*pi*t) for t in Q15 of one turn, result Q15.  65-entry table + linear
 * interpolation: 0.03 % worst case, which is a control's accuracy and not a signal's.
 * No libm and no float -- the guest is CONFIG_FPU=n. */
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

/* Goertzel magnitude^2 at f (millihertz) over n int8 samples at fs Hz.  Scaled down to
 * keep the console free of 64-bit formats: returns log2-ish magnitude as an integer. */
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
	/* return 100*log2(mag) + 200*e, so ratios are differences and nothing is 64-bit */
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

/* ---- the capture ----------------------------------------------------------------------
 * PUSH-TO-TALK: hart 0 polls LEVEL, pops one sample, and resamples it in the 2156 core
 * cycles before the next one arrives.  Nothing runs on hart 1 and nothing is buffered
 * beyond the 40-sample filter history: the int8 window IS the buffer.
 */
struct cap_result {
	uint32_t nin, nout, ticks;
	uint32_t st_first, st_or;
	int refused;
	uint32_t pre_rms, pre_peak;   /* the DISCARDED pre-roll, measured */
	struct b119_rs rs;
};

static uint64_t isqrt64(uint64_t v);

static void capture(struct cap_result *r, int8_t *dst, uint32_t want, uint32_t preroll)
{
	struct b119_rs *s = &r->rs;
	int8_t o[4];
	uint32_t got = 0, dropped = 0, nin = 0, st_or = 0;

	b119_rs_init(s, (int32_t)gain_m, gain_s);
	r->refused = 0;
	/* fifo_reset, NOT clear_sticky.  B110's defect: clear_sticky does not clear
	 * STATUS[3] overrun; only the FIFO's own reset does.  The reset arms the watch. */
	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE);
	while ((sys_read32(R_STATUS) & ST_SETTLING) != 0U) { }
	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET);
	ctrl(CTRL_ENABLE);
	while (sys_read32(R_LEVEL) != 0U) { (void)sys_read32(R_DATA); }
	while (sys_read32(R_LEVEL) == 0U) { }
	r->st_first = sys_read32(R_STATUS);
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
			g = b119_rs_push(s, v, o, 4);
			for (int j = 0; j < g; j++) {
				if (dropped < preroll) {
					dropped++;
					if (dropped == preroll) {
						/* measure what is being thrown away, then start
						 * the statistics the calibration reads. */
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
	/* AN OVERRUN REFUSES THE WINDOW.  A 55 ms hole in the middle of an utterance is a
	 * discontinuity, and transcribing one is worse than not transcribing it. */
	if (r->st_or & ST_OVERRUN) { r->refused |= 1; }
	ctrl(0U);
}

/* ---- control 1: the board's own 1000.000 Hz sine, through the same resampler ----------
 * If the resampler were a pass-through the tone would come out at
 *   1000 * 16000 / 18552.876 = 862.400 Hz.
 * Both bins are measured in the same pass, which is the shape of B110's dc_bypass arm.
 * And the DIRECT and BANK evaluation orders both run, on the same samples, and must
 * produce IDENTICAL bytes.
 */
static void synth_control(void)
{
	struct b119_rs s;
	int8_t o[4];
	uint32_t got, i, t0, t1, tdir, tbank, nd;
	int mode;

	for (mode = 0; mode < 2; mode++) {
		int8_t *dst = mode ? syn_b : syn_a;

		b119_rs_init(&s, (int32_t)gain_m, gain_s);
		s.use_bank = mode;
		got = 0;
		t0 = k_cycle_get_32();
		for (i = 0; got < SYN_N && i < 4u * SYN_N; i++) {
			int64_t t = ((int64_t)i * 1000 * 32768 * 1000) / B119_RS_FMIC_MILLIHZ;
			int16_t xv = (int16_t)((12000 * (int64_t)cos_q15(t - 8192)) >> 15);
			int g = b119_rs_push(&s, xv, o, 4);

			for (int j = 0; j < g && got < SYN_N; j++) { dst[got++] = o[j]; }
		}
		t1 = k_cycle_get_32();
		if (mode) { tbank = t1 - t0; } else { tdir = t1 - t0; }
	}
	nd = 0;
	for (i = 0; i < SYN_N; i++) { if (syn_a[i] != syn_b[i]) { nd++; } }
	printk("MW_SYNTH n=%u g1000_clog2=%u g862_clog2=%u g4000_clog2=%u verdict=%s\n",
	       SYN_N,
	       goertzel_db(syn_a + 512, 15360, 1000000u, 16000u),
	       goertzel_db(syn_a + 512, 15360,  862400u, 16000u),
	       goertzel_db(syn_a + 512, 15360, 4000000u, 16000u),
	       (goertzel_db(syn_a + 512, 15360, 1000000u, 16000u) >
	        goertzel_db(syn_a + 512, 15360, 862400u, 16000u) + 400u)
	       ? "RESAMPLED" : "PASSTHROUGH_OR_BROKEN");
	printk("MW_AB direct_ticks=%u bank_ticks=%u bytes_differing=%u of %u fnv_direct=0x%08x "
	       "fnv_bank=0x%08x verdict=%s\n", tdir, tbank, nd, SYN_N,
	       fnv1a(syn_a, SYN_N), fnv1a(syn_b, SYN_N),
	       nd == 0 ? "IDENTICAL" : "DISAGREE");
}

/* ---- control 2: B110's overrun defect, re-run ------------------------------------------ */
static void overrun_control(void)
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
	printk("MW_OVR provoked=0x%02x after_clear_sticky=0x%02x after_fifo_reset=0x%02x "
	       "verdict=%s\n", a, b, c,
	       ((a & ST_OVERRUN) && (b & ST_OVERRUN) && !(c & ST_OVERRUN))
	       ? "B110_DEFECT_CONFIRMED" : "UNEXPECTED");
	ctrl(0U);
}

static void dump_window(const int8_t *x, uint32_t n)
{
	static const char hx[] = "0123456789abcdef";
	char line[129];

	printk("MW_DUMP_BEGIN n=%u bytes_per_line=64\n", n);
	for (uint32_t i = 0; i < n; i += 64) {
		uint32_t k = 0;

		for (uint32_t j = 0; j < 64 && i + j < n; j++) {
			uint8_t v = (uint8_t)x[i + j];

			line[k++] = hx[v >> 4]; line[k++] = hx[v & 15];
		}
		line[k] = 0;
		printk("MWD %05u %s\n", i, line);
	}
	printk("MW_DUMP_END\n");
}

int main(void)
{
	struct cap_result r, pre;
	uint32_t hz = sys_clock_hw_cycles_per_sec();
	int32_t mn = 127, mx = -128;
	int64_t sum = 0, sumabs = 0, sumsq = 0;
	uint32_t zeros = 0, distinct = 0;

	printk("\nMW_BEGIN base=0x%08lx build=" __DATE__ " " __TIME__ "\n", (unsigned long)MIC_BASE);
	printk("MW_GUEST mtime_hz=%u\n", hz);
	printk("MW_CFG taps=%d D=%d q=%d hq=%d up=%d down=%d fmic_millihz=%d gain_m=%u "
	       "gain_s=%d scale_x_e9=%d nout=%d preroll=%d\n",
	       B119_RS_N, B119_RS_D, B119_RS_Q, B119_RS_HQ, B119_RS_UP, B119_RS_DOWN,
	       B119_RS_FMIC_MILLIHZ, gain_m, gain_s, B119_RS_SCALE_X_E9, NOUT, PREROLL);

	{
		uint32_t id = sys_read32(R_ID), depth = sys_read32(R_DEPTH);

		printk("MW_REGS id=0x%08x depth=%u rate_reg_millihz=%u\n",
		       id, depth, sys_read32(R_RATE));
		if (id != ID_MAGIC || depth != 1024U) {
			printk("MW_VERDICT NOT_MAPPED\nMW_DONE\n");
			return 0;
		}
		printk("MW_GATE1 PASS id and depth are both exact\n");
	}

	{
		uint32_t t0 = k_cycle_get_32();

		b119_rs_build_bank();
		printk("MW_BANK bytes=%u build_ticks=%u\n",
		       (unsigned)sizeof(b119_rs_bank), k_cycle_get_32() - t0);
	}
	synth_control();
	overrun_control();

	/* AUTO-RANGE.  One gain constant is the deliverable; this is the instrument that
	 * reads it.  The pre-roll measures the RESAMPLED signal's rms in int16 mic counts --
	 * the physical quantity -- and the gain follows from it by integer division.  Both
	 * the raw level and the gain are printed, because an auto-ranged window always LOOKS
	 * on scale: it is the mic-count rms that says whether it was speech or room noise. */
	capture(&pre, win, RANGE_N, PREROLL);
	{
		uint32_t rms = (uint32_t)isqrt64((uint64_t)(pre.rs.sum_sq
				/ (int64_t)(pre.rs.nout ? pre.rs.nout : 1)));

		printk("MW_RANGE nout=%u rms_counts=%u peak_counts=%u preroll_rms=%u "
		       "preroll_peak=%u status_or=0x%02x saturated=%d refused=%d\n",
		       pre.rs.nout, rms, (uint32_t)pre.rs.peak_abs, pre.pre_rms, pre.pre_peak,
		       pre.st_or, (pre.st_or & ST_SATURATED) ? 1 : 0, pre.refused);
		b119_rs_gain_from_rms(rms, TARGET_I8_RMS_MILLI, (int32_t *)&gain_m, &gain_s);
		printk("MW_GAIN target_i8_rms_milli=%d measured_rms_counts=%u gain_m=%u "
		       "gain_s=%d\n", TARGET_I8_RMS_MILLI, rms, gain_m, gain_s);
	}

	printk("MW_CAP_BEGIN want=%d preroll=%d expect_inputs=%u expect_us=%u\n",
	       NOUT, PREROLL, b119_rs_inputs_for(NOUT + PREROLL),
	       (uint32_t)(((uint64_t)b119_rs_inputs_for(NOUT + PREROLL) * 1000000ULL * 1000ULL)
	                  / B119_RS_FMIC_MILLIHZ));
	capture(&r, win, NOUT, PREROLL);
	{
		uint32_t us = (uint32_t)(((uint64_t)r.ticks * 1000000ULL) / hz);

		printk("MW_CAP nin=%u nout=%u ticks=%u us=%u status_first=0x%02x status_or=0x%02x "
		       "refused=%d clipped=%u sat_hi=%u sat_lo=%u peak_abs=%u\n",
		       r.nin, r.nout, r.ticks, us, r.st_first, r.st_or, r.refused,
		       r.rs.nclip, r.rs.nsat_hi, r.rs.nsat_lo, (uint32_t)r.rs.peak_abs);
		/* THE RATE, FROM THE CLOCK.  64,000 outputs take 4.0002 s through the
		 * resampler and 3.4496 s through a pass-through: 16 % apart. */
		printk("MW_RATE nin=%u elapsed_us=%u in_rate_millihz=%u out_rate_millihz=%u "
		       "passthrough_us=%u\n", r.nin, us,
		       (uint32_t)(((uint64_t)r.nin * hz * 1000ULL) / (r.ticks ? r.ticks : 1)),
		       (uint32_t)(((uint64_t)r.nout * hz * 1000ULL) / (r.ticks ? r.ticks : 1)),
		       (uint32_t)((uint64_t)NOUT * 1000000000ULL / B119_RS_FMIC_MILLIHZ * 1000ULL
		                  / 1000ULL));
		printk("MW_TRANSIENT preroll_outputs=%d preroll_rms=%u preroll_peak=%u  "
		       "(the DC blocker converging; discarded, and measured so it is not "
		       "silently dropped)\n", PREROLL, r.pre_rms, r.pre_peak);
		printk("MW_LEVEL resampled_rms_counts=%u peak_counts=%u  (int16 mic counts, "
		       "BEFORE the gain, over the KEPT samples only -- the calibration row)\n",
		       (uint32_t)isqrt64((uint64_t)(r.rs.sum_sq / (int64_t)(r.rs.nout ? r.rs.nout : 1))),
		       (uint32_t)r.rs.peak_abs);
	}
	printk("MW_RAWHEAD");
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
	printk("MW_WSTAT n=%d min=%d max=%d mean_milli=%d meanabs_milli=%d rms_milli=%u "
	       "zeros=%u distinct=%u\n", NOUT, mn, mx,
	       (int)((sum * 1000) / NOUT), (int)((sumabs * 1000) / NOUT),
	       (uint32_t)isqrt64((uint64_t)((sumsq * 1000000) / NOUT)),
	       zeros, distinct);
	printk("MW_BAND");
	for (uint32_t f = 250; f <= 7000; f = (f * 2)) {
		printk(" %u:%u", f, goertzel_db(win, 16384, f * 1000u, 16000u));
	}
	printk("\n");
	printk("MW_FNV window=0x%08x\n", fnv1a(win, NOUT));
	for (int b = 0; b < 16; b++) {
		printk("MW_FNVB blk=%d off=%d fnv=0x%08x\n", b, b * 4000, fnv1a(win + b * 4000, 4000));
	}
	printk("MW_HIST");
	for (int i = 0; i < 256; i++) { printk(" %u", hist256[i]); }
	printk("\n");

	if (r.refused) {
		printk("MW_VERDICT REFUSED status_or=0x%02x refused=%d -- the window is NOT offered\n",
		       r.st_or, r.refused);
	} else {
		printk("MW_VERDICT WINDOW_OK n=%d\n", NOUT);
		dump_window(win, NOUT);
	}
	printk("MW_DONE\n");
	return 0;
}
