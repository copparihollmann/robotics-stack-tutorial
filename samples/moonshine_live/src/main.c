/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * MOONSHINE, LIVE.  Clap, speak, read the transcript -- on the board, from the board's own
 * microphone, with nothing on the host but a serial console.
 *
 * WHAT THIS IS AND IS NOT A MEASUREMENT OF.  The arithmetic here is the SAME arithmetic the
 * measured results use: the same generated kernels (kernel_picks_digest 9005f05c...), the
 * same kernel cflags (77424eb4...), the same embedding table, the same capture path
 * (b119_resamp.h / b122_capture.h, unmodified and shared with samples/mic_speech).  What
 * differs is B.  ***THE MEASURED RTF_e2e 0.892873 IS A B = 4 NUMBER*** -- it decodes four
 * utterances in one pass of the graph.  A live demo has one utterance and nothing to batch
 * it with, so this image runs the B = 1 graph, whose RTF_e2e is ~1.18.  ***THAT IS SLOWER
 * THAN REAL TIME BY DESIGN AND IT IS NOT A REGRESSION***: it is the price of not having
 * three other people talking at the same time.  ~4.7 s of compute for a 4.0 s window.
 *
 * THE THREE STATES, ON THE LEDS, BECAUSE A CONSOLE ACROSS A ROOM IS NOT READABLE.
 *
 *   LD4 RED      idle -- clap to start
 *   LD4 GREEN    recording -- speak now
 *   LD4 BLUE     thinking -- the model is running
 *   LD5 GREEN    the last transcript was produced; LD5 RED it was refused
 *
 * WHY A CLAP AND NOT A BUTTON.  The PYNQ's pushbuttons are not in this bitstream: the RTL
 * top has no button port and no XDC constrains one, so neither Rocket nor the PS can see
 * them.  The microphone is the only physical input this SoC has, so the microphone is the
 * button.  A clap is 20-30 dB over a room floor and is far easier to detect than speech
 * onset -- which is the detector B128 and B130 spent two labs establishing is the fragile
 * part -- so the trigger is deliberately NOT the same decision as the window choice.
 *
 * THE ORDER, AND WHY RECORD-THEN-PROCESS IS NOT A CONCESSION.  samples/digits_live's header
 * states it for the digit model and it holds here: while the model runs, nothing drains the
 * microphone FIFO.  Recording to completion before inference starts removes that constraint
 * by construction, and leaves only "is the wait tolerable".
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>
#include <zephyr/drivers/gpio.h>
#include <string.h>

#include "model.h"
#include "driver_meta.h"
#include "mb_vocab.h"
#include "b122_capture.h"          /* brings b119_resamp.h -- both shared, neither copied */
#if ML_SELFTEST
#include "mb_selftest.h"
#endif
#if ML_OLED
/* THE DISPLAY IS OPTIONAL AND ITS ABSENCE IS NOT AN ERROR.  samples/oled_status/oled.overlay
 * declares oled_3c and oled_3d deferred, because a 0.96" module is strapped for one address
 * or the other and nothing should probe the bus before main().  This file does its own
 * probe-and-init rather than using oled_status's thread: a transcript is multi-line text,
 * and oled_status renders a fixed label/score/rtf layout for the vision demo. */
#include <zephyr/drivers/i2c.h>
#include <zephyr/device.h>
#include <zephyr/display/cfb.h>
#endif

/* ---- the microphone, raw MMIO (samples/mic_speech's map, unchanged) --------------------- */
#define MIC_BASE   0x10090000UL
#define R_ID       (MIC_BASE + 0x00)
#define R_CTRL     (MIC_BASE + 0x08)
#define R_STATUS   (MIC_BASE + 0x10)
#define R_LEVEL    (MIC_BASE + 0x18)
#define R_DATA     (MIC_BASE + 0x20)

#define ID_MAGIC          0x504D4331U
#define CTRL_ENABLE       0x1U
#define CTRL_FIFO_RESET   0x2U
#define CTRL_CLR_STICKY   0x8U
#define ST_SETTLING       0x1U
#define ST_OVERRUN        0x8U
#define ST_SATURATED      0x10U

/* ---- the shapes, all of them samples/mic_speech's ---------------------------------------- */
#define NOUT      64000              /* the encoder's input width */
#define NCAP      96000              /* 6.0 s: the window is CHOSEN out of this */
#define PREROLL    1024              /* B119's DC-blocker convergence -- NOT the onset lead */
#define PROF_BLK   1600              /* 0.1 s per energy-profile block */
#define NPROF     (NCAP / PROF_BLK)  /* 60 */
#define ONSET_LEAD 6400              /* 0.4 s kept before the detected onset (B130's value) */
#define MS_TARGET_I8_RMS_MILLI  11967   /* B122's calibration target, int8 rms x 1000 */

/* THE TRIGGER.  A block this much over the running floor, twice running, is a clap.  It is
 * deliberately far coarser than the onset detector below: a false trigger costs one wasted
 * six-second window and a false onset costs a wrong transcript. */
#ifndef ML_CLAP_MULT
#define ML_CLAP_MULT  12u            /* ~21 dB over the floor */
#endif
#ifndef ML_CLAP_FLOOR_BLKS
#define ML_CLAP_FLOOR_BLKS 20u       /* 2.0 s of room before the floor is believed */
#endif
/* HOW MUCH IS DISCARDED AFTER THE CLAP, AND WHY 0.5 s WAS NOT ENOUGH.  The first board run
 * fired the ONSET detector at sample 3,200 -- 0.2 s in -- on the clap's decaying tail, not on
 * speech.  The onset threshold is 4 x floor + 4, which is right when the only sound in the
 * buffer is the utterance (B134's flow) and far too sensitive when a transient precedes it.
 * Discarding 1.5 s puts the clap and its room reverb outside the buffer entirely, so the two
 * decisions -- "start now" and "the speech begins here" -- stop interfering. */
#ifndef ML_SETTLE_OUT
#define ML_SETTLE_OUT  24000u        /* 1.5 s */
#endif
/* Below this window rms the buffer is room noise, not speech.  B134's 80 real captures ran
 * win_rms 93-335; its silence control sat far below that. */
#ifndef ML_MIN_WIN_RMS
#define ML_MIN_WIN_RMS 40u
#endif
/* Drained after a display write, to flush whatever the bus transfer cost us. */
#ifndef ML_OLED_DRAIN_OUT
#define ML_OLED_DRAIN_OUT 8000u      /* 0.5 s */
#endif
#ifndef ML_BTN_SETTLE_OUT
#define ML_BTN_SETTLE_OUT 4000u      /* 0.25 s */
#endif

/* The Farrow phase bank, defined here exactly as samples/mic_speech and samples/mic_window
 * define it: b119_resamp.h declares it extern so that one TU owns the 539 x N table. */
int32_t b119_rs_bank[B119_RS_UP][B119_RS_N];

extern const int8_t mb_ar_tail[];    /* the 6,912 B every packed record ends with */
extern const unsigned char mb_ar_emb[];

static model_input_t  ar_input[MODEL_INPUT_SIZE];
static model_output_t model_output[MODEL_OUTPUT_SIZE];
static int64_t  cap[NCAP];                    /* pass 1: the resampler's own accumulators */
static uint32_t prof_rms[NPROF];
static int32_t  tok[N_STEPS];
static char     text[N_STEPS * 32];

/* ---- LEDs -------------------------------------------------------------------------------- */
#define LED_SPEC(n) GPIO_DT_SPEC_GET_OR(DT_ALIAS(n), gpios, {0})
static const struct gpio_dt_spec ld4_b = LED_SPEC(led0), ld4_g = LED_SPEC(led1),
				 ld4_r = LED_SPEC(led2), ld5_b = LED_SPEC(led3),
				 ld5_g = LED_SPEC(led4), ld5_r = LED_SPEC(led5);
static int leds_ok;

static void leds_init(void)
{
	const struct gpio_dt_spec *all[] = { &ld4_b, &ld4_g, &ld4_r, &ld5_b, &ld5_g, &ld5_r };

	leds_ok = 1;
	for (int i = 0; i < 6; i++) {
		if (all[i]->port == NULL || !gpio_is_ready_dt(all[i]) ||
		    gpio_pin_configure_dt(all[i], GPIO_OUTPUT_INACTIVE) < 0) {
			leds_ok = 0;
		}
	}
	/* NOT FATAL.  A board with no LEDs still transcribes; it just cannot say so across a
	 * room.  The console carries the same three states. */
	printk("ML_LEDS ok=%d\n", leds_ok);
}

static void ld4(int r, int g, int b)
{
	if (!leds_ok) { return; }
	gpio_pin_set_dt(&ld4_r, r); gpio_pin_set_dt(&ld4_g, g); gpio_pin_set_dt(&ld4_b, b);
}

static void ld5(int r, int g, int b)
{
	if (!leds_ok) { return; }
	gpio_pin_set_dt(&ld5_r, r); gpio_pin_set_dt(&ld5_g, g); gpio_pin_set_dt(&ld5_b, b);
}

static inline unsigned long rdcycle(void)
{
	unsigned long c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/* ---- small integer helpers (samples/mic_speech's, character for character) ---------------- */
static uint64_t isqrt64(uint64_t v)
{
	uint64_t r = 0, bit = 1ULL << 62;

	while (bit > v) { bit >>= 2; }
	while (bit) {
		if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; }
		else { r >>= 1; }
		bit >>= 2;
	}
	return r;
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

/* ---- the microphone ---------------------------------------------------------------------- */
static uint32_t mic_start(void)
{
	sys_write32(CTRL_ENABLE | CTRL_FIFO_RESET | CTRL_CLR_STICKY, R_CTRL);
	while ((sys_read32(R_STATUS) & ST_SETTLING) != 0U) { }
	sys_write32(CTRL_ENABLE | CTRL_FIFO_RESET, R_CTRL);
	while (sys_read32(R_LEVEL) != 0U) { (void)sys_read32(R_DATA); }
	while (sys_read32(R_LEVEL) == 0U) { }
	return sys_read32(R_STATUS);
}

/* Pop `nout` resampler outputs into `dst` (or discard them when dst is NULL), returning the
 * OR of every STATUS read.  One MMIO load per microphone sample, 2156 core cycles apart. */
static uint32_t pump(struct b119_rs *s, int64_t *dst, uint32_t nout)
{
	uint32_t got = 0, st = 0;

	while (got < nout) {
		int64_t o[4];
		int n;

		while (sys_read32(R_LEVEL) == 0U) { }
		st |= sys_read32(R_STATUS);
		n = b122_rs_push_acc(s, (int16_t)sys_read32(R_DATA), o, 4);
		for (int i = 0; i < n && got < nout; i++) {
			if (dst) { dst[got] = o[i]; }
			got++;
		}
	}
	return st;
}

#if ML_BUTTON
static void wait_for_clap(struct b119_rs *s);   /* the fallback, defined below */

/* ---- THE TRIGGER, WHEN THERE IS A BUTTON TO PRESS ---------------------------------------
 * 0x5A5A0037 routes BTN0..BTN3 (D19/D20/L20/L19, active high per the PYNQ-Z1 reference
 * manual) into the Chipyard GPIO, which is why this build exists at all: on 0x5A5A0035 the
 * RTL top has no button port and the microphone had to BE the button.
 *
 * A BUTTON IS NOT A BETTER CLAP, IT IS A DIFFERENT DECISION.  The clap detector had to share
 * the microphone with the thing it was triggering, which is what made the first live runs
 * pick the wrong window.  A button does not touch the audio path at all, so the onset
 * detector sees only speech. */
static void wait_for_button(struct b119_rs *s)
{
	static const struct gpio_dt_spec btn = GPIO_DT_SPEC_GET_OR(DT_ALIAS(sw0), gpios, {0});
	static int64_t blk[PROF_BLK];
	int was = 0;

	if (btn.port == NULL || !gpio_is_ready_dt(&btn) ||
	    gpio_pin_configure_dt(&btn, GPIO_INPUT) < 0) {
		printk("ML_BTN not available -- falling back to the clap trigger\n");
		wait_for_clap(s);
		return;
	}
	printk("ML_ARM press BTN0 to start\n");
	for (;;) {
		int v = gpio_pin_get_dt(&btn);

		/* THE MICROPHONE KEEPS RUNNING WHILE WE WAIT.  Draining it here is what keeps
		 * the FIFO from overrunning and keeps the resampler's history warm, so the
		 * recording that follows is continuous with this stream -- the same property
		 * that the clap path needed and that record_window relies on. */
		(void)pump(s, blk, PROF_BLK);
		if (v > 0 && !was) {
			printk("ML_BTN pressed\n");
			return;
		}
		was = (v > 0);
	}
}
#endif

/* ---- THE TRIGGER ------------------------------------------------------------------------- */
static void wait_for_clap(struct b119_rs *s)
{
	static int64_t blk[PROF_BLK];
	uint32_t floor_rms = 0xffffffffu, nblk = 0, hot = 0;

	printk("ML_ARM waiting for a clap (floor over %u blocks of %u)\n",
	       ML_CLAP_FLOOR_BLKS, (uint32_t)PROF_BLK);
	for (;;) {
		uint32_t r;

		(void)pump(s, blk, PROF_BLK);
		r = rms_counts(blk, PROF_BLK);
		if (nblk < ML_CLAP_FLOOR_BLKS) {
			/* THE FLOOR IS THE ROOM, AND IT IS LEARNED BEFORE IT IS USED.  A
			 * threshold taken from one block is a threshold taken from whatever
			 * happened in that block. */
			if (r < floor_rms) { floor_rms = r; }
			nblk++;
			continue;
		}
		if (r > floor_rms * ML_CLAP_MULT + 8u) {
			if (++hot >= 2u) {
				printk("ML_CLAP floor=%u thr=%u blk_rms=%u\n",
				       floor_rms, floor_rms * ML_CLAP_MULT + 8u, r);
				return;
			}
		} else {
			hot = 0;
			/* the floor tracks the room down, never up, so a noisy moment cannot
			 * desensitise the trigger permanently */
			if (r < floor_rms) { floor_rms = r; }
		}
	}
}

/* ---- the window: pass 1, onset, pass 2 --------------------------------------------------- */
/* THE MICROPHONE IS ALREADY RUNNING WHEN THIS IS CALLED, and re-starting it is what broke
 * the first two live runs.  mic_start() resets the FIFO and then spins on ST_SETTLING; doing
 * that AFTER the trigger inserts an unbounded gap between "clap" and "recording", and the
 * talker is already finished when the buffer finally opens.  The board read win_rms 20 and
 * transcribed 4.0 s of room noise as "Thank you".  wait_for_clap has already started the
 * microphone and already paid PREROLL, so this continues the SAME stream. */
static int record_window(struct b119_rs *s, int8_t *win, uint32_t *out_start, int *out_found,
			 uint32_t *out_rms)
{
	uint32_t st, floor_rms, thr, onset_blk = 0, win_start;
	unsigned int key;
	int found = 0;
	int32_t gm, gs;

	/* CLEAR THE STICKY STATUS IMMEDIATELY BEFORE THE CAPTURE, so `st` below describes
	 * THIS capture and not whatever disturbed the FIFO while the talker was getting
	 * ready.  It is a pulse: mic_start() asserts CTRL_CLR_STICKY and then de-asserts it,
	 * and a single asserting write does NOT clear the bit -- the first attempt at this
	 * fix wrote it once and the board still reported a stale st=0x8. */
	sys_write32(CTRL_ENABLE | CTRL_CLR_STICKY, R_CTRL);
	sys_write32(CTRL_ENABLE, R_CTRL);
	/* THE PROBE THAT SPLITS TWO HYPOTHESES.  `st` below is the OR of STATUS across the
	 * capture, so an OVERRUN in it cannot distinguish "the bit was already set and the
	 * clear pulse failed" from "the capture really starved".  Reading STATUS and LEVEL
	 * here -- after the clear, before a single sample is popped -- separates them. */
	printk("ML_PRECAP status=0x%x level=%u\n",
	       sys_read32(R_STATUS), sys_read32(R_LEVEL));
	/* THE CAPTURE IS INTERRUPT-LOCKED, and the panel build is why.  This loop must pop a
	 * sample every ~2,156 core cycles against a FIFO ~55-64 ms deep; it is a tight MMIO
	 * poll that makes no kernel call, so locking costs it nothing.  Measured, one variable
	 * changed: the SAME bitstream and the SAME board with the display stack compiled out
	 * captured at st=0x0 and transcribed correctly, while with CONFIG_I2C/DISPLAY/CFB in
	 * the image every capture came back st=0x8 OVERRUN -- four times.  The decode loop has
	 * always been irq_lock()ed for the same reason; the capture never was, because until
	 * 0x5A5A0037 there was no other driver in the image to steal the cycles. */
	key = irq_lock();
	st = pump(s, cap, NCAP);
	irq_unlock(key);

	for (uint32_t b = 0; b < NPROF; b++) {
		prof_rms[b] = rms_counts(cap + (uint32_t)b * PROF_BLK, PROF_BLK);
	}
	floor_rms = 0xffffffffu;
	for (uint32_t b = 0; b < NPROF; b++) {
		if (prof_rms[b] < floor_rms) { floor_rms = prof_rms[b]; }
	}
	/* 12 dB over the quietest 0.1 s, twice in a row, so one click is not an onset.  This is
	 * samples/mic_speech's detector unchanged -- B130 measured it fires between 72 ms early
	 * and 170 ms late against real speech onset, median 32 ms early. */
	thr = floor_rms * 4u + 4u;
	for (uint32_t b = 0; b + 1 < NPROF; b++) {
		if (prof_rms[b] > thr && prof_rms[b + 1] > thr) {
			onset_blk = b; found = 1; break;
		}
	}
	if (found) {
		uint32_t o = onset_blk * PROF_BLK;

		win_start = (o > ONSET_LEAD) ? (o - ONSET_LEAD) : 0u;
		if (win_start > NCAP - NOUT) { win_start = NCAP - NOUT; }
	} else {
		win_start = 8000;
	}

	/* PASS 2: the gain comes from the window it is applied to.  B119's G = 136.03 was
	 * calibrated to a noise floor BECAUSE NOBODY SPOKE, and speech at that gain clips; the
	 * auto-range is the fix and B134 measured it holding 80 captures inside 80.7 ppm of the
	 * int8 rail across a 3x level range. */
	*out_rms = rms_counts(cap + win_start, NOUT);
	b119_rs_gain_from_rms(*out_rms, MS_TARGET_I8_RMS_MILLI, &gm, &gs);
	for (uint32_t i = 0; i < NOUT; i++) {
		win[i] = b122_quant(cap[win_start + i], gm, gs);
	}
	*out_start = win_start;
	*out_found = found;
	printk("ML_PROF n=%d blk=%d", NPROF, PROF_BLK);
	for (uint32_t b = 0; b < NPROF; b++) { printk(" %u", prof_rms[b]); }
	printk("\n");
	printk("ML_WIN start=%u onset_found=%d onset=%u floor=%u thr=%u win_rms=%u "
	       "gain_m=%d gain_s=%d st=0x%x%s%s\n",
	       win_start, found, onset_blk * PROF_BLK, floor_rms, thr, *out_rms, gm, gs, st,
	       (st & ST_OVERRUN) ? " OVERRUN" : "", (st & ST_SATURATED) ? " SATURATED" : "");
	return (st & ST_OVERRUN) ? -1 : 0;
}

/* ---- the model: ONE utterance, B = 1 ----------------------------------------------------- */
static int decode(int *ntok, unsigned long *cycles)
{
	model_state_t st = { ar_input, model_output, NULL };
	unsigned long t0;
	int d = 0, n = 0, hit_eos = 0;

	model_reset_profile();
	t0 = rdcycle();
	for (int k = 0; k < N_STEPS; k++) {
		const int8_t *lg;
		int best = 0;
		int8_t bv;

		/* `d` is never reset: the walk is cumulative and an early EOS simply leaves the
		 * remaining steps' dispatches unexecuted.  Same shape as the measured harness. */
		for (; d <= STEP_END[k]; d++) {
			model_dispatch_fns[d](&st);
		}
		lg = model_output + (size_t)k * VOCAB;
		bv = lg[0];
		for (int i = 1; i < VOCAB; i++) {
			if (lg[i] > bv) { bv = lg[i]; best = i; }
		}
		tok[n++] = best;
		if (best == EOS_ID) { hit_eos = 1; break; }
		if (k + 1 < N_STEPS) {
			const float sc = H_SCALE[k + 1];
			int8_t *dst = ar_input + H_OFF[k + 1];
			const float *row = (const float *)mb_ar_emb + (size_t)best * DHID;

			for (int j = 0; j < DHID; j++) {
				float q = row[j] / sc;
				int v = (int)(q < 0 ? q - 0.5f : q + 0.5f);

				dst[j] = (int8_t)(v > 127 ? 127 : (v < -127 ? -127 : v));
			}
		}
	}
	*cycles = rdcycle() - t0;
	*ntok = n;
	return hit_eos;
}

/* ---- the transcript ---------------------------------------------------------------------- */
/* emit_vocab.py pre-applied the decoder's Replace and ByteFallback steps, so what is left is
 * Fuse (concatenate) and Strip (one leading space).  That equivalence is GATED on the host:
 * emit_vocab.py --verify reproduced PreTrainedTokenizerFast.decode character for character on
 * all 324 token sequences B134's board actually produced. */
static const char *detok(const int32_t *t, int n)
{
	size_t w = 0;

	for (int i = 0; i < n; i++) {
		uint32_t id = (uint32_t)t[i];
		uint32_t a, b;

		if (id >= MB_VOCAB_N) { continue; }
		a = mb_vocab_off[id]; b = mb_vocab_off[id + 1];
		for (uint32_t k = a; k < b && w + 1 < sizeof(text); k++) {
			text[w++] = (char)mb_vocab_blob[k];
		}
	}
	text[w] = '\0';
	return (text[0] == ' ') ? text + 1 : text;
}

#if ML_OLED
/* ---- the display ------------------------------------------------------------------------ */
#define ML_OLED_COLS 25              /* 128 px / the 5x8 font's 5+ffill advance */
#define ML_OLED_ROWS 8

static const struct device *oled_dev;

static void oled_init(void)
{
	static const struct {
		const struct device *disp, *bus;
		uint16_t addr;
	} cand[] = {
#if DT_NODE_HAS_STATUS_OKAY(DT_NODELABEL(oled_3c))
		{ DEVICE_DT_GET(DT_NODELABEL(oled_3c)),
		  DEVICE_DT_GET(DT_BUS(DT_NODELABEL(oled_3c))), 0x3c },
#endif
#if DT_NODE_HAS_STATUS_OKAY(DT_NODELABEL(oled_3d))
		{ DEVICE_DT_GET(DT_NODELABEL(oled_3d)),
		  DEVICE_DT_GET(DT_BUS(DT_NODELABEL(oled_3d))), 0x3d },
#endif
	};
	uint8_t nop[2] = { 0x00, 0xE3 };

	for (size_t i = 0; i < ARRAY_SIZE(cand); i++) {
		if (!device_is_ready(cand[i].bus)) { continue; }
		if (i2c_write(cand[i].bus, nop, sizeof(nop), cand[i].addr) != 0) { continue; }
		if (device_init(cand[i].disp) != 0) { continue; }
		if (cfb_framebuffer_init(cand[i].disp) != 0) { continue; }
		oled_dev = cand[i].disp;
		printk("ML_OLED ready at 0x%02x\n", cand[i].addr);
		return;
	}
	/* NOT FATAL, and said once: the console carries every line the display would. */
	printk("ML_OLED no ACK at 0x3c/0x3d -- not fitted, console only\n");
}

/* Word-wrapped transcript, newest at the top.  cfb_print does not wrap. */
static void oled_show(const char *title, const char *body)
{
	char line[ML_OLED_COLS + 1];
	int row = 0;
	size_t i = 0, n;

	if (oled_dev == NULL) { return; }
	if (cfb_framebuffer_clear(oled_dev, false) != 0) { return; }
	cfb_print(oled_dev, (char *)title, 0, 0);
	row = 1;
	n = strlen(body);
	while (i < n && row < ML_OLED_ROWS) {
		size_t take = n - i, brk;

		if (take > ML_OLED_COLS) {
			take = ML_OLED_COLS;
			for (brk = take; brk > 0; brk--) {
				if (body[i + brk] == ' ') { take = brk; break; }
			}
		}
		memcpy(line, body + i, take);
		line[take] = '\0';
		cfb_print(oled_dev, line, 0, row * 8);
		row++;
		i += take;
		while (i < n && body[i] == ' ') { i++; }
	}
	(void)cfb_framebuffer_finalize(oled_dev);
}
#else
static inline void oled_init(void) { }
static inline void oled_show(const char *t, const char *b) { (void)t; (void)b; }
#endif

/* ---- the boot self-test ------------------------------------------------------------------ */
#if ML_SELFTEST
static int selftest(void)
{
	unsigned long cyc;
	int n = 0, i;

	memcpy(ar_input, mb_selftest_in, MODEL_INPUT_SIZE);
	(void)decode(&n, &cyc);
	/* THIS SEPARATES TWO FAILURES THAT LOOK THE SAME ON A CONSOLE.  If the baked record
	 * decodes to the tokens the board itself produced for it in a scored run, the model,
	 * the kernels, the embedding and the detokeniser are all correct, and anything wrong
	 * afterwards is the microphone.  If it does not, nothing downstream is worth reading. */
	if (n != MB_SELFTEST_NTOK) {
		printk("ML_SELFTEST FAIL ntok=%d want=%d\n", n, MB_SELFTEST_NTOK);
		return -1;
	}
	for (i = 0; i < n; i++) {
		if (tok[i] != mb_selftest_tok[i]) {
			printk("ML_SELFTEST FAIL tok[%d]=%d want=%d\n",
			       i, (int)tok[i], (int)mb_selftest_tok[i]);
			return -1;
		}
	}
	printk("ML_SELFTEST PASS %d tokens, %lu cycles -- \"%s\"\n", n, cyc, detok(tok, n));
	return 0;
}
#endif

int main(void)
{
	static int8_t win[NOUT];
	uint32_t id = sys_read32(R_ID);

	printk("\nML_BOOT moonshine_live  B=1  N_STEPS=%d VOCAB=%d DHID=%d  in=%d out=%d\n",
	       N_STEPS, VOCAB, DHID, (int)MODEL_INPUT_SIZE, (int)MODEL_OUTPUT_SIZE);
	printk("ML_MIC id=0x%08x %s\n", id, id == ID_MAGIC ? "ok" : "*** NOT THE PDM MIC ***");
	leds_init();
	oled_init();
	ld4(1, 0, 0); ld5(0, 0, 0);
	oled_show("MOONSHINE LIVE", "clap, then speak");

#if ML_SELFTEST
	if (selftest() < 0) {
		/* Refuse to pretend. A board that cannot reproduce its own banked tokens on a
		 * baked record has nothing useful to say about live audio. */
		ld4(1, 0, 0); ld5(1, 0, 0);
		printk("ML_DONE refusing to run live: the self-test failed\n");
		return 0;
	}
#endif
	if (id != ID_MAGIC) {
		ld5(1, 0, 0);
		printk("ML_DONE no microphone at 0x%08lx\n", (unsigned long)MIC_BASE);
		return 0;
	}

	for (;;) {
		struct b119_rs s;
		uint32_t win_start, wrms;
		unsigned long cyc;
		int found = 0, n = 0, eos;

		ld4(1, 0, 0);                                    /* idle */
#if ML_BUTTON
		printk("\nML_READY press BTN0 to start\n");
		oled_show("MOONSHINE LIVE", "press BTN0, then speak");
#else
		printk("\nML_READY clap to start\n");
#endif
		b119_rs_build_bank();
		b119_rs_init(&s, 1, 0);
		(void)mic_start();
		(void)pump(&s, NULL, PREROLL);
#if ML_BUTTON
		wait_for_button(&s);
		/* No acoustic transient to outlive, so the settle is short: it only covers
		 * the hand leaving the button. */
		(void)pump(&s, NULL, ML_BTN_SETTLE_OUT);
#else
		wait_for_clap(&s);
		(void)pump(&s, NULL, ML_SETTLE_OUT);             /* let the clap decay */
#endif

		/* THE DISPLAY MUST NOT SIT BETWEEN THE TRIGGER AND THE CAPTURE.  A full
		 * 128x64 frame is 1,024 B over a ~113 kHz bus -- about 82 ms in which nothing
		 * drains the microphone, against a FIFO roughly 55-64 ms deep.  Drawing here
		 * and then recording produced st=0xc (OVERRUN|FULL) on the first panel run and
		 * the capture was correctly refused.  So: draw FIRST, then clear the sticky
		 * status the draw provoked, then let the settle drain the stale FIFO.  The
		 * samples lost are inside the discarded settle window, which is exactly the
		 * region whose audio is thrown away anyway.
		 * CTRL_CLR_STICKY WITHOUT CTRL_FIFO_RESET on purpose: a reset would restart
		 * the PDM settling and reintroduce the trigger-to-recording gap that the
		 * mic-continuity fix removed. */
		/* NO DISPLAY WRITE BETWEEN THE TRIGGER AND THE CAPTURE.  A 128x64 frame is
		 * ~82 ms of I2C with nothing draining a FIFO ~55-64 ms deep, so it sets
		 * ST_OVERRUN -- and CTRL_CLR_STICKY on its own does NOT clear that bit, as
		 * ML_PRECAP proved by reading status=0x8 level=28 before a single sample was
		 * popped.  The capture was never starving; the gate was rejecting good audio
		 * on a stale flag.  mic_start()'s full reset at the top of the next round is
		 * what actually clears it, so the idle screen carries the whole instruction
		 * and the display is not touched again until the transcript exists. */
		ld4(0, 1, 0);                                    /* recording */
		printk("ML_REC speak now (%d.%d s)\n", NCAP / 16000, (NCAP / 1600) % 10);
		if (record_window(&s, win, &win_start, &found, &wrms) < 0) {
			ld4(1, 0, 0); ld5(1, 0, 0);
			printk("ML_DONE refused: the FIFO overran during capture\n");
			continue;
		}

		ld4(0, 0, 1);                                    /* thinking */
		oled_show("THINKING", "");
		memcpy(ar_input, win, NOUT);
		memcpy(ar_input + NOUT, mb_ar_tail, MODEL_INPUT_SIZE - NOUT);
		eos = decode(&n, &cyc);

		printk("ML_TOK n=%d eos=%d cycles=%lu\n", n, eos, cyc);
		/* A NEAR-SILENT WINDOW STILL DECODES TO SOMETHING, and that something reads like
		 * a transcript.  B134's silence arm produced "So" on four identical silent
		 * records and this image produced "Thank you" on 4.0 s of room noise.  Neither
		 * is a transcription, so neither is printed as one. */
		if (!found || wrms < ML_MIN_WIN_RMS) {
			printk("ML_TEXT (nothing heard -- win_rms %u, onset_found %d)\n",
			       wrms, found);
			oled_show("NOTHING HEARD", "clap and speak again");
		} else {
			const char *t = detok(tok, n);

			printk("ML_TEXT %s\n", t);
			oled_show("TRANSCRIPT", t);
		}
		/* RTF against the 4.0 s the window is worth, in permille so no float is printed. */
		printk("ML_RTF permille=%lu (cycles / (4.0 s x 40 MHz))\n",
		       (unsigned long)((cyc * 1000UL) / 160000000UL));
		ld5(0, 1, 0);
	}
	return 0;
}
