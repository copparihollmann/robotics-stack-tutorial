/* SPDX-License-Identifier: Apache-2.0
 *
 * SIGNDET LIVE (Lab B146) -- point the board's camera at a traffic sign and read the answer
 * off the OLED.  Camera -> colour front end -> SignDetLite on the P-extension -> an 8x8x3
 * grid -> one class name, large, on the glass.  One image, one SoC (0x5A5A0038), the camera
 * and the display on the SAME I2C bus.
 *
 * ---------------------------------------------------------------------------------------
 * WHY THIS IS A NEW APP AND NOT A FLAG ON samples/sign_live
 *
 * samples/sign_live is Lab B139's validated demo and other records depend on it byte for
 * byte.  It reads ONE softmax row of 43 GTSRB classes; this network's output is 64 cells x 3
 * classes and there is no flag that turns one into the other.  samples/cam_snap was forked
 * from sign_live the same way earlier today, and this is forked from cam_snap -- the camera
 * bring-up, the bus mutex discipline and the I2C ordering below are all B139's, unchanged.
 *
 * ---------------------------------------------------------------------------------------
 * WHAT THE MODEL SAYS, AND WHY "NO SIGN" IS THE POINT OF IT
 *
 * SignDetLite (Lab B144) emits an 8x8 spatial grid, each cell a 3-way softmax over
 * {background, stop, yield}.  The decode here is the decode B144's host_gate.py uses, line
 * for line:
 *
 *     for every cell, the objectness is max(P_stop, P_yield)
 *     the answer's cell is the FIRST maximum of that over the grid, in (row, col) order
 *     the class at that cell is the first maximum of {stop, yield}   (a tie is STOP)
 *     if the objectness is NOT above the threshold the answer is BACKGROUND
 *
 * That last line is the whole reason this model exists.  The GTSRB classifier it replaces
 * answered all 8 of this bench's real captures at ~100 % confidence and was WRONG on all 8:
 * a 43-class softmax has no way to say "nothing here".  This one declines -- on B144's bench
 * set the strongest response on any cell not touching a sign is 0.305, against sign responses
 * up to 0.984.  A UI that guessed anyway would throw that away, so below the threshold the
 * glass says NO SIGN and no class is drawn.
 *
 * THE THRESHOLD IS A BUILD KNOB (SD_THR_PCT, default 50 = B144's untuned default) so it can
 * be moved at the bench without editing this file.  It is printed in SD_BOOT and on the glass.
 *
 * ---------------------------------------------------------------------------------------
 * THE HAZARD THIS APP IS SHAPED AROUND (B139's, verbatim, because it has not gone away)
 *
 * The sensor's control port (0x24) and the display (0x3c) are one bus, one controller.  NEVER
 * TOUCH THE BUS BETWEEN THE TRIGGER AND THE CAPTURE: the capture holds oled_status_bus_lock()
 * across the whole DMA, and oled_status's refresh takes the same mutex around
 * cfb_framebuffer_finalize(), so the display physically cannot reach the bus while a transfer
 * is armed.  Measured rather than asserted: oled_draws_during is counted per capture and must
 * be 0.  B139's phase-B interleave PROBE is deliberately NOT carried over -- it is a
 * measurement, this is a demo, and a demo that races its own display for science is a demo
 * that shows a torn screen to the person at the bench.
 *
 * ---------------------------------------------------------------------------------------
 * REPLAY -- the gate that does not need a person
 *
 * Built with -DSD_FRAMES_DIR=..., the image carries the 8 REAL HM01B0 captures from
 * out/cam_snap/snaps together with the HOST's answer for each: its class, its peak cell, its
 * confidence AND its whole 192-byte output tensor (signdet/bake_live_frames.py).  The board
 * must reproduce all of it from the raw 105,624-byte frame, through the same sign_pre_rgb.c
 * and the same kernels.  It tests the PIPELINE, never the optics, and this app never claims
 * otherwise.  One of the 8 is a frame the host DECLINES (snap_015, objectness 0.425 < 0.50):
 * the board has to decline it too, which is the only way to gate the behaviour above.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/display/cfb.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>
#include <string.h>

#include "pext.h"
#include "ospi_cam.h"
#include "sign_pre_rgb.h"
#include "oled_status.h"
#include "model.h"

#define MBXR_RT_TYPES_ONLY
#include "roccmoon/mbxr_rt.h"
#pragma weak mbxr_rt_stats

#ifdef SD_REPLAY
#include "signdet_frames.h"
#endif

/* ---- the grid ---------------------------------------------------------------------------- */
#define SD_GRID    8
#define SD_CELLS   (SD_GRID * SD_GRID)
#define SD_CLASSES 3

BUILD_ASSERT(MODEL_INPUT_SIZE == SPR_ELEMS,
	     "this model does not take a 64x64x3 int8 tensor -- wrong MODEL_DIR");
BUILD_ASSERT(MODEL_OUTPUT_SIZE == SD_CELLS * SD_CLASSES,
	     "this model does not emit an 8x8x3 grid -- wrong MODEL_DIR");

/* ---- build knobs ----------------------------------------------------------------------- */
#ifndef SD_FRAMES
#define SD_FRAMES 0             /* live inferences; 0 = until the console reader gives up */
#endif

/*
 * SD_STOP_HOOK -- ADDITIVE AND DEFAULT-OFF, like SD_NO_MAIN.  Lab B156.
 *
 * A live loop bounded only by SD_FRAMES is bounded by a COUNT, and a count cannot be made
 * to agree with the other hart's count: B153's run asked for 8 replay + 2 live frames and
 * for 8 s of audio, and hart 0 finished at 11.1 s of a 55.0 s trace.  The detector then sat
 * in the idle thread for 80 % of the artefact -- five gates passed and the centrepiece of
 * the tutorial's TACIT unit showed one busy hart and one dead one.
 *
 * A WALL-CLOCK WINDOW is the bound that can be shared: give each workload more work than
 * the window can consume, and stop both when the window closes.  So the loop asks an
 * external predicate whether to keep going.  Nothing in this repo defines SD_STOP_HOOK but
 * samples/tacit_duo, where it is samples/tacit_duo/src/main.c's window timer; everywhere
 * else this compiles to `while (btn && !0 && ...)` and every image scripts/83, scripts/86
 * and scripts/87 build is unchanged.
 *
 * IT DOES NOT GUARD THE REPLAY LOOP.  The 8 baked frames are the correctness gate
 * (8/8 decisions, 8/8 tensors, max |d| = 0); a window that cut them short would turn a
 * too-small window into a silent loss of evidence rather than a shorter trace.  They run
 * to completion and the hook bounds the LIVE loop only.
 */
#ifdef SD_STOP_HOOK
int sd_should_stop(void);
#else
static inline int sd_should_stop(void) { return 0; }
#endif
#ifndef SD_THR_PCT
/*
 * B144's UNTUNED default, 0.50, at which the model scored 7/8 on this bench's real captures
 * and did not once fire confidently on clutter.  A knob so the bench can move it without a
 * code edit -- and NOT a number to tune against the replay gate: if the board and the host
 * disagree, that is a finding about the pipeline and moving this hides it.
 */
#define SD_THR_PCT 50
#endif
#ifndef SD_OUT_SCALE_PPB
/* The output softmax's quantisation in parts per billion; the build passes the graph's own
 * value so a model with a different output scale cannot report a wrong confidence.
 * 7874016 = 1/127, which is what B144's graph.json carries. */
#define SD_OUT_SCALE_PPB 7874016u
#endif
#ifndef SD_MCLKDIV
#define SD_MCLKDIV 3            /* 0x5A5A0038 ran at 3 in CAMERA_Z1.md section 9.5 */
#endif
#ifndef SD_AE_TARGET
/*
 * 0x60, the SAME target samples/cam_snap used to take the 8 captures B144 trained the PTQ
 * calibration on and gated the model against.  Keeping it is not inertia: change it and the
 * live frames stop resembling the frames the replay gate passes on.
 */
#define SD_AE_TARGET 0x60
#endif
#ifndef SD_BUTTON
#define SD_BUTTON 0             /* 1 = one inference per BTN0 press (cam_snap's shutter) */
#endif
#ifndef SD_EVICT
/*
 * Sweep 4 MiB of the L2 after every live inference so the PS can read the frame back.  The
 * capture DMA is a TileLink master on the front bus, so its Puts land in the L2
 * InclusiveCache and the ARM, reading physical DRAM from outside it, gets STALE BYTES
 * (CAMERA_Z1.md section 9.5).  This is what makes the addr= in SD_INFER a pullable frame;
 * set to 0 to trade scripts/85_cam_snap_pull.sh for a few ms per frame.
 */
#define SD_EVICT 1
#endif
#ifndef SD_SNAP_LINE
/*
 * ALSO print cam_snap's SNAP line, so scripts/85_cam_snap_pull.sh works on this app
 * UNMODIFIED -- it parses exactly that shape (addr, bytes, saweof, name, pct).
 *
 * DEFAULT OFF, AND THAT DEFAULT WAS BOUGHT.  scripts/85 keys on the LINE, not on the app:
 * two of them had been tailing this board's console since 12:26 with --name cam_snap, and
 * the moment this image printed a SNAP line they pulled 82 frames of the live demo into
 * out/cam_snap/snaps -- which is Lab B144's ground-truth directory, and which B144's
 * host_gate.py and this lab's own bake both read.  A demo must not be able to rewrite
 * another lab's evidence by printing a line.  Turn it on deliberately (scripts/87 --pull)
 * when you want the frames, and pull them with a --name of your own.
 *
 * SD_INFER carries the same addr= and bytes= in every build, so nothing is lost by default.
 */
#define SD_SNAP_LINE 0
#endif
#ifndef SD_DUMP_GRID
#define SD_DUMP_GRID 1          /* one SD_GRIDDUMP block per replay frame and per first live */
#endif

#define OSPI      ((uintptr_t)DT_REG_ADDR(DT_ALIAS(camera0)))
#define FCLK0_HZ  ((uint32_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * 1000u)

static const struct device *const i2c_bus = DEVICE_DT_GET(DT_ALIAS(camera_i2c));

/* Per-hart mcycle, the same reader every measurement sample in this tree uses. */
static inline unsigned long rdcycle(void)
{
	unsigned long c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/* HM01B0 registers this app writes; ospi_cam.h carries the rest. */
#define HM_IMAGE_ORIENT  0x0101
#define HM_GRP_HOLD      0x0104
#define HM_INTEG_H       0x0202
#define HM_INTEG_L       0x0203
#define HM_ANA_GAIN      0x0205
#define HM_AE_CTRL       0x2100
#define HM_AE_TARGET     0x2101

/* ---- buffers ----------------------------------------------------------------------------
 * 256 KiB frame buffer, 64-byte aligned, exactly as samples/cam_capture sizes it: DMA_LEN is
 * the only bound on the transfer and a buffer smaller than what the part can send once ran
 * 584 bytes into printk's spinlock (CAMERA_Z1.md section 9.5).                              */
#define CAP_BYTES (256u * 1024u)
static uint8_t frame[CAP_BYTES] __aligned(64);
static uint8_t rgb64[SPR_ELEMS];
static model_input_t net_in[MODEL_INPUT_SIZE];
static model_output_t net_out[MODEL_OUTPUT_SIZE];

/* ---- the decode -------------------------------------------------------------------------- */
static const char *const cls_short[SD_CLASSES] = { "NO SIGN", "STOP", "YIELD" };
/* No spaces: scripts/85_cam_snap_pull.sh reads name= with a \S+ pattern. */
static const char *const cls_name[SD_CLASSES] = { "none", "stop", "yield" };

struct det {
	int cls;                /* 0 background / no sign, 1 stop, 2 yield */
	int raw_cls;            /* the best SIGN class, whatever the threshold said */
	int gx, gy;             /* the peak cell */
	int q;                  /* that cell's quantised objectness */
	uint8_t pct;            /* and the same as a percentage */
};

static uint8_t pct_of(int q)
{
	uint32_t p;

	if (q <= 0) {
		return 0;
	}
	p = (uint32_t)(((uint64_t)q * SD_OUT_SCALE_PPB + 5000000ull) / 10000000ull);
	return (uint8_t)(p > 100u ? 100u : p);
}

/* Strictly above, as host_gate.py's `c > thr` is: at the threshold exactly, the answer is
 * background.  Done in integers against the graph's own scale so no float and no rounding of
 * the percentage can move the decision. */
static int above_threshold(int q)
{
	return q > 0 &&
	       (uint64_t)q * SD_OUT_SCALE_PPB > (uint64_t)SD_THR_PCT * 10000000ull;
}

static void decode_grid(const model_output_t *o, struct det *d)
{
	int best = -1000, bi = 0, bc = 1;

	for (int i = 0; i < SD_CELLS; i++) {
		const model_output_t *p = o + i * SD_CLASSES;
		/* argmax over {stop, yield}; numpy's argmax keeps the FIRST maximum, so a
		 * tie is STOP, and `>` below keeps the first maximal CELL for the same
		 * reason.  These two tie-breaks are why the board can match the host on a
		 * frame where two cells are equally strong. */
		int c = (p[2] > p[1]) ? 2 : 1;

		if ((int)p[c] > best) {
			best = (int)p[c];
			bi = i;
			bc = c;
		}
	}
	d->gy = bi / SD_GRID;
	d->gx = bi % SD_GRID;
	d->q = best;
	d->pct = pct_of(best);
	d->raw_cls = bc;
	d->cls = above_threshold(best) ? bc : 0;
}

/* ---- the display ------------------------------------------------------------------------ */
#define OLED_COLS 25            /* at 5x8 */

static const struct device *oled;
static uint16_t oled_addr;
static uint32_t oled_draws;
static uint32_t oled_render_cyc, oled_xfer_cyc;
static int font_big = -1, font_mid = -1, font_small = -1;

static struct sd_screen {
	uint32_t seq;
	int cls;
	uint8_t pct;
	uint16_t ms;
	int gx, gy;
	const char *note;       /* replaces everything when there is no result at all */
	const char *src;
} scr;

static void i2c_scan(void)
{
	char found[64];
	int n = 0;

	found[0] = '\0';
	oled_status_bus_lock();
	for (uint16_t a = 0x08; a <= 0x77; a++) {
		if (i2c_write(i2c_bus, NULL, 0, a) == 0) {
			n += snprintk(found + n, sizeof(found) - (size_t)n, " 0x%02x", a);
			if ((size_t)n >= sizeof(found) - 8) { break; }
		}
	}
	oled_status_bus_unlock();
	printk("SD_I2CSCAN range=0x08..0x77 acked=%d addrs=%s%s\n",
	       n ? 1 : 0, n ? found : " none",
	       n ? "" : "  (0x24 is the HM01B0, 0x3c the SSD1306)");
}

/*
 * PRESENCE IS AN ADDRESS ACK, NOT A COMMAND ACK -- B139 measured that on both boards on
 * 2026-09-22: a two-byte NOP write to 0x3c returned no ACK while a zero-length write to the
 * same address ACKed.  Everything after the address ACK is REPORTED rather than used to
 * decide, so "not fitted" and "fitted but would not initialise" stay different facts.
 */
static void oled_probe(void)
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

	for (size_t i = 0; i < ARRAY_SIZE(cand); i++) {
		static const uint8_t nop[2] = { 0x00, 0xE3 };
		int ack, nrc, drc, src;

		if (!device_is_ready(cand[i].bus)) {
			printk("SD_OLED probe addr=0x%02x bus_not_ready=1\n", cand[i].addr);
			continue;
		}
		oled_status_bus_lock();
		ack = i2c_write(cand[i].bus, NULL, 0, cand[i].addr);
		nrc = (ack == 0) ? i2c_write(cand[i].bus, nop, sizeof(nop), cand[i].addr) : -ENODEV;
		drc = (ack == 0) ? device_init(cand[i].disp) : -ENODEV;
		oled_status_bus_unlock();
		/* oled_cfb_setup() calls cfb_framebuffer_init() ITSELF.  Calling it here as
		 * well returns -ENOMEM: CFB k_malloc()s 1,024 bytes per init and the pool is
		 * 2,048.  One init, and it belongs to the helper that owns the polarity. */
		src = (ack == 0 && (drc == 0 || drc == -EALREADY))
			? oled_cfb_setup(cand[i].disp) : -ENODEV;
		printk("SD_OLED probe addr=0x%02x addr_ack_rc=%d nop_rc=%d init_rc=%d "
		       "setup_rc=%d\n", cand[i].addr, ack, nrc, drc, src);
		if (ack != 0) { continue; }
		if (src != 0) {
			printk("SD_OLED state=FAILED addr=0x%02x reason=acked_but_init_failed\n",
			       cand[i].addr);
			continue;
		}
		oled = cand[i].disp;
		oled_addr = cand[i].addr;
		/*
		 * THE FONTS, FOUND BY SIZE.  This image links samples/oled_status's three
		 * pixel-doubled fonts; CFB indexes them in link order, which is not a thing
		 * to hard-code.  A missing font is reported and falls back to 5x8 rather
		 * than drawing nothing.
		 */
		{
			int n = cfb_get_numof_fonts(oled);
			uint8_t w, h;

			for (int f = 0; f < n; f++) {
				if (cfb_get_font_size(oled, f, &w, &h) != 0) { continue; }
				if (w == 15 && h == 24) { font_big = f; }
				if (w == 10 && h == 16) { font_mid = f; }
				if (w == 5  && h == 8)  { font_small = f; }
			}
			printk("SD_FONTS n=%d big15x24=%d mid10x16=%d small5x8=%d\n",
			       n, font_big, font_mid, font_small);
			if (font_big < 0) { font_big = font_mid; }
			if (font_big < 0) { font_big = font_small; }
			if (font_mid < 0) { font_mid = font_small; }
		}
		printk("SD_OLED state=READY addr=0x%02x\n", oled_addr);
		return;
	}
	printk("SD_OLED state=ABSENT addr=0x00 reason=no_ack_at_0x3c_0x3d\n");
}

static void put(int font, int x, int y, const char *s)
{
	if (font >= 0) { (void)cfb_framebuffer_set_font(oled, font); }
	(void)cfb_print(oled, s, (uint16_t)x, (uint16_t)y);
}

/*
 * THE LAYOUT, and why the class gets 24 of the 64 rows.
 *
 *   y  0..23   the class, 15x24  -- "STOP" / "YIELD" / "NO SIGN".  This is read from across
 *              a bench; the same word in 5x8 is 20 pixels wide and is not.
 *   y 24..39   10x16: the confidence and the peak cell, the two numbers that say WHY
 *   y 40..47   5x8:  sequence, milliseconds per frame, and where the frame came from
 *   y 48..54   a bar of the confidence against the threshold mark
 *   y 56..63   5x8:  the threshold in force, so nobody reads a tuned run as an untuned one
 */
static void oled_draw(void)
{
	char b[40];
	uint32_t t0, t1;
	int rc;

	if (oled == NULL) { return; }
	t0 = (uint32_t)rdcycle();
	if (cfb_framebuffer_clear(oled, false) != 0) { return; }

	if (scr.note != NULL) {
		put(font_mid, 0, 0, "SIGNDET");
		put(font_small, 0, 24, scr.note);
	} else {
		put(font_big, 0, 0, cls_short[scr.cls]);
		if (scr.cls == 0) {
			snprintk(b, sizeof b, "%2u%% < %u%%", scr.pct, (unsigned)SD_THR_PCT);
		} else {
			snprintk(b, sizeof b, "%3u%% @%d,%d", scr.pct, scr.gx, scr.gy);
		}
		put(font_mid, 0, 24, b);
		snprintk(b, sizeof b, "#%-4u %4ums %s", scr.seq, scr.ms,
			 scr.src ? scr.src : "");
		put(font_small, 0, 40, b);
		(void)oled_bar(oled, 0, 48, 128, 7, scr.pct, 100);
		snprintk(b, sizeof b, "thr %u%%  cell %d,%d", (unsigned)SD_THR_PCT,
			 scr.gx, scr.gy);
		put(font_small, 0, 56, b);
	}

	t1 = (uint32_t)rdcycle();
	/* THE ONLY BUS ACCESS IN THIS FUNCTION, and it is the one the mutex guards. */
	oled_status_bus_lock();
	rc = cfb_framebuffer_finalize(oled);
	oled_status_bus_unlock();
	oled_render_cyc = t1 - t0;
	oled_xfer_cyc = (uint32_t)rdcycle() - t1;
	if (rc != 0) {
		printk("SD_OLED state=FAILED addr=0x%02x rc=%d -- the bus is not touched again\n",
		       oled_addr, rc);
		oled = NULL;
		return;
	}
	oled_draws++;
}

/* ---- the sensor -------------------------------------------------------------------------- */
static int z_write(void *ctx, uint8_t addr, const uint8_t *buf, uint32_t len)
{ ARG_UNUSED(ctx); return i2c_write(i2c_bus, buf, len, addr); }
static int z_write_read(void *ctx, uint8_t addr, const uint8_t *w, uint32_t wl,
			uint8_t *r, uint32_t rl)
{ ARG_UNUSED(ctx); return i2c_write_read(i2c_bus, addr, w, wl, r, rl); }
static const struct cam_i2c bus = { z_write, z_write_read, NULL };

static uint32_t i2c_xfers;

/* GROUPED HOLD -> WRITE -> RELEASE -> READ BACK.  0x0104 was found ENGAGED on this part with
 * nothing in this repo having written it, which is why writes ACK and change nothing until
 * the hold is let go (CAMERA_Z1.md section 9.5).  Every write is reported with its readback. */
static int hm_set(uint16_t reg, uint8_t val)
{
	uint8_t rb = 0xff;
	int rc, rel, rrc;

	oled_status_bus_lock();
	rc = hm01b0_write(&bus, HM_GRP_HOLD, 1);
	if (rc == 0) { rc = hm01b0_write(&bus, reg, val); }
	rel = hm01b0_write(&bus, HM_GRP_HOLD, 0);
	rrc = hm01b0_read(&bus, reg, &rb);
	oled_status_bus_unlock();
	i2c_xfers += 4;
	if (rc == 0) { rc = rel; }
	printk("SD_SET reg=0x%04x wrote=0x%02x rc=%d readback=0x%02x read_rc=%d\n",
	       reg, val, rc, rb, rrc);
	return rc ? rc : rrc;
}

/* ---- the button (optional shutter) ------------------------------------------------------- */
static const struct gpio_dt_spec snap_btn = GPIO_DT_SPEC_GET_OR(DT_ALIAS(sw0), gpios, {0});

__maybe_unused static int snap_btn_ready(void)
{
	if (snap_btn.port == NULL || !gpio_is_ready_dt(&snap_btn) ||
	    gpio_pin_configure_dt(&snap_btn, GPIO_INPUT) < 0) {
		return 0;
	}
	return 1;
}

/* Blocks until BTN0 goes 0 -> 1.  Edge triggered, so holding it down fires once. */
__maybe_unused static int wait_for_press(void)
{
	int was = gpio_pin_get_dt(&snap_btn) > 0;

	for (;;) {
		int v = gpio_pin_get_dt(&snap_btn);

		if (v < 0) { return -1; }
		if (v > 0 && !was) { return 0; }
		was = (v > 0);
		k_msleep(10);
	}
}

static uint32_t evict_l2_4mib(void)
{
	/* 0x8E00_0000, NOT 0x8800_0000: this image links the engine runtime, whose weight
	 * image and staging windows run 0x8800_0000 .. 0x8E00_0000 (sw/roccmoon/mbxr_rt.h). */
	volatile const uint64_t *p = (const uint64_t *)0x8E000000UL;
	uint64_t acc = 0;

	for (uint32_t i = 0; i < (4u * 1024u * 1024u) / 8u; i += 8) { acc += p[i]; }
	return (uint32_t)acc;
}

/* ---- one inference ----------------------------------------------------------------------- */
struct shot {
	int rc;
	uint32_t bytes, polls, attempts, dma_status, flags;
	uint32_t pre_cyc, inf_cyc, evict_cyc;
	uint32_t mean_x10, sd_x10, distinct;
	struct det d;
	uint32_t oled_draws_during;
};

static int sleep1(void *ctx) { ARG_UNUSED(ctx); k_msleep(1); return 0; }

/* Plain statistics over the 64x64x3 the network sees.  REPORTED, never used to refuse an
 * inference: on this model a frame with nothing in it is the model's own job to decline, and
 * a front-end gate that pre-empted that would hide the behaviour the demo exists to show. */
static void rgb_stats(struct shot *s)
{
	uint32_t sum = 0, n = SPR_ELEMS, d = 0;
	uint64_t sq = 0;
	uint8_t seen[256];

	memset(seen, 0, sizeof seen);
	for (uint32_t i = 0; i < n; i++) {
		uint32_t v = rgb64[i];

		sum += v;
		sq += (uint64_t)v * v;
		seen[v] = 1;
	}
	for (int i = 0; i < 256; i++) { d += seen[i]; }
	s->mean_x10 = (uint32_t)((uint64_t)sum * 10u / n);
	{
		uint64_t m = sum / n;
		uint64_t var = sq / n - m * m;
		uint32_t r = 0;

		while ((uint64_t)(r + 1) * (r + 1) <= var * 100u) { r++; }
		s->sd_x10 = r;
	}
	s->distinct = d;
}

static void one_shot(uint32_t seq, const uint8_t *replay, struct shot *s)
{
	struct ospi_frame_result fr;
	uint32_t d0 = oled_draws, t0;

	ARG_UNUSED(seq);
	memset(s, 0, sizeof *s);

	if (replay != NULL) {
		memcpy(frame, replay, SPR_FRAME_BYTES);
		s->rc = 0;
		s->bytes = SPR_FRAME_BYTES;
		/* dma_status and flags STAY ZERO: no DMA ran.  src=replay is what tells a
		 * reader; printing the 0x0a a good capture reads would be a number shaped
		 * like a result. */
	} else {
		oled_status_bus_lock();   /* the display cannot reach the bus until this drops */
		s->rc = ospi_dma_capture_frame(OSPI, (uint32_t)(uintptr_t)frame, CAP_BYTES,
					       SPR_STRIDE, SPR_H, 5000, sleep1, NULL, &fr);
		oled_status_bus_unlock();
		s->bytes = fr.bytes;
		s->polls = fr.polls;
		s->attempts = fr.attempts;
		s->dma_status = fr.dma_status;
		s->flags = fr.flags;
	}
	s->oled_draws_during = oled_draws - d0;

	t0 = (uint32_t)rdcycle();
	sign_pre_rgb64(frame, rgb64);
	sign_pre_rgb_wb(rgb64);
	sign_pre_rgb_quant(rgb64, net_in);
	s->pre_cyc = (uint32_t)rdcycle() - t0;
	rgb_stats(s);

	s->d.cls = -1;
	if (s->rc == 0) {
		t0 = (uint32_t)rdcycle();
		run_model(net_in, net_out, NULL);
		s->inf_cyc = (uint32_t)rdcycle() - t0;
		decode_grid(net_out, &s->d);
	}
}

static uint32_t cyc_ms(uint32_t c) { return (uint32_t)((uint64_t)c * 1000u / FCLK0_HZ); }

static void dump_grid(uint32_t seq, const char *src)
{
#if SD_DUMP_GRID
	/* One row per line, each cell two hex digits of max(P_stop, P_yield) and one letter
	 * for which class won it.  This is the picture the decode is reading. */
	for (int gy = 0; gy < SD_GRID; gy++) {
		char line[SD_GRID * 4 + 1];
		int n = 0;

		for (int gx = 0; gx < SD_GRID; gx++) {
			const model_output_t *p = net_out + (gy * SD_GRID + gx) * SD_CLASSES;
			int c = (p[2] > p[1]) ? 2 : 1;

			n += snprintk(line + n, sizeof(line) - (size_t)n, "%02x%c ",
				      (unsigned)(p[c] & 0xff), c == 1 ? 's' : 'y');
		}
		printk("SD_GRIDDUMP seq=%u src=%s row=%d %s\n", seq, src, gy, line);
	}
#else
	ARG_UNUSED(seq); ARG_UNUSED(src);
#endif
}

static void print_shot(uint32_t seq, const char *src, const struct shot *s)
{
	int live = (strcmp(src, "replay") != 0);

	printk("SD_FRAME seq=%u src=%s rc=%d bytes=%u saweof=%d polls=%u attempts=%u "
	       "dma_status=0x%02x flags=0x%02x overflow=%d oled_draws_during=%u\n",
	       seq, src, s->rc, s->bytes,
	       live ? ((s->dma_status & OSPI_DMA_ST_SAWEOF) ? 1 : 0) : -1, s->polls,
	       s->attempts, s->dma_status, s->flags,
	       (s->flags & OSPI_FLAG_OVERFLOW) ? 1 : 0, s->oled_draws_during);
	printk("SD_PRE seq=%u cycles=%u mean_x10=%u stddev_x10=%u distinct=%u\n",
	       seq, s->pre_cyc, s->mean_x10, s->sd_x10, s->distinct);
}

/* THE machine-readable line.  One per inference, and it carries the frame buffer address so
 * scripts/85_cam_snap_pull.sh can pull the picture that produced it. */
static void print_infer(uint32_t seq, const char *src, const struct shot *s)
{
	int live = (strcmp(src, "replay") != 0);

	printk("SD_INFER seq=%u ms=%u cls=%d name=%s pct=%u cell=%d,%d addr=0x%08lx "
	       "bytes=%u saweof=%d src=%s q=%d best=%s thr=%u\n",
	       seq, cyc_ms(s->inf_cyc), s->d.cls,
	       s->d.cls >= 0 ? cls_name[s->d.cls] : "nothing", s->d.pct, s->d.gx, s->d.gy,
	       (unsigned long)(uintptr_t)frame, s->bytes,
	       live ? ((s->dma_status & OSPI_DMA_ST_SAWEOF) ? 1 : 0) : -1, src,
	       s->d.q, s->d.raw_cls >= 0 ? cls_name[s->d.raw_cls] : "-",
	       (unsigned)SD_THR_PCT);
}

static void post_screen(uint32_t seq, const struct shot *s, const char *src)
{
	scr.seq = seq;
	scr.cls = (s->d.cls < 0) ? 0 : s->d.cls;
	scr.pct = s->d.pct;
	scr.ms = (uint16_t)cyc_ms(s->inf_cyc);
	scr.gx = s->d.gx;
	scr.gy = s->d.gy;
	scr.src = src;
	scr.note = (s->rc != 0) ? "camera gave no frame" : NULL;
}

static int ops_printed;

static void print_ops(void)
{
	int n = 0;
	const model_op_record_t *r;

	if (ops_printed) { return; }
	ops_printed = 1;
	r = model_profile_records(&n);
	for (int i = 0; i < n; i++) {
		printk("SD_OP id=%d name=%s op=%s shape=%s cycles=%lu\n",
		       r[i].dispatch_id, r[i].name, r[i].op, r[i].shape, r[i].cycles);
	}
}

static void print_engine(const char *phase)
{
	if (&mbxr_rt_stats == NULL) {
		printk("SD_ROCCMOON phase=%s absent=1 (conv2d_s8_pc has no engine kernel: the "
		       "engine runtime is not linked at all, so 0 is structural)\n", phase);
		return;
	}
	printk("SD_ROCCMOON phase=%s calls_engine=%llu calls_fallback=%llu\n", phase,
	       (unsigned long long)mbxr_rt_stats.calls_engine,
	       (unsigned long long)mbxr_rt_stats.calls_fallback);
}

/* ---- the demo ---------------------------------------------------------------------------- */
#ifdef SD_NO_MAIN
/* Lab B151 links this file into samples/tacit_duo, where the thread is created, pinned
 * and started by that sample's own main(). The entry point has to be visible there --
 * and only there: everywhere else it stays static, as it has always been. */
#define SD_DEMO_LINKAGE
#else
#define SD_DEMO_LINKAGE static
#endif
SD_DEMO_LINKAGE void demo(void *a1, void *a2, void *a3)
{
	uint32_t seq = 0, ok = 0, live_n = 0;
	uint64_t ms_sum = 0;
	uint32_t ms_min = 0xffffffffu, ms_max = 0;
	uint16_t model_id = 0;
	int rc, pre_rc, shield, btn = 0;
	int replay_ok = -1, replay_bytes_ok = -1;

	ARG_UNUSED(a1); ARG_UNUSED(a2); ARG_UNUSED(a3);

	printk("\nSD_BOOT sample=signdet_live model=%s in=%d out=%d grid=%dx%dx%d thr_pct=%u "
	       "out_scale_ppb=%u in_recip=%d ae_target=0x%02x mclkdiv=%d frames=%d button=%d "
	       "evict=%d\n",
	       MODEL_NAME, (int)MODEL_INPUT_SIZE, (int)MODEL_OUTPUT_SIZE,
	       SD_GRID, SD_GRID, SD_CLASSES, (unsigned)SD_THR_PCT,
	       (unsigned)SD_OUT_SCALE_PPB, SPR_IN_SCALE_RECIP, SD_AE_TARGET, SD_MCLKDIV,
	       SD_FRAMES, SD_BUTTON, SD_EVICT);
	printk("SD_HART cpu=%d mhartid=%lu mbp_available=%d\n",
	       arch_curr_cpu()->id, (unsigned long)csr_read(mhartid), mb_pext_available());
	MB_PEXT_ASSERT_BIG_HART();

	/* The front end's own arithmetic, before any of it is believed.  The frame buffer is
	 * the scratch -- nothing has captured into it yet. */
	pre_rc = sign_pre_rgb_selftest(frame);
	printk("SD_SELFTEST sign_pre_rgb=%d\n", pre_rc);
	if (pre_rc != 0) {
		printk("SD_RESULT ok=0 reason=selftest_failed\n");
		printk("SD_DONE\n");
		return;
	}

	/* 1. The display FIRST, while no capture exists to be disturbed. */
	if (!device_is_ready(i2c_bus)) {
		printk("SD_RESULT ok=0 reason=i2c_not_ready\n");
		printk("SD_DONE\n");
		return;
	}
	i2c_scan();
	oled_probe();
	scr.note = "starting up";
	oled_draw();

	/* 2. The sensor.  Every I2C transaction in this block. */
	oled_status_bus_lock();
	rc = hm01b0_model_id(&bus, &model_id);
	oled_status_bus_unlock();
	i2c_xfers += 1;
	shield = (rc == 0 && model_id == HM01B0_MODEL_ID);
	printk("SD_CAM rc=%d model_id=0x%04x shield=%d ospi=0x%08lx\n",
	       rc, model_id, shield, (unsigned long)OSPI);

	if (shield) {
		ospi_wr(OSPI, OSPI_MCLKDIV, SD_MCLKDIV);
		printk("SD_MCLK div=%d readback=%u hz=%u\n", SD_MCLKDIV,
		       ospi_rd(OSPI, OSPI_MCLKDIV), FCLK0_HZ / (2u * (SD_MCLKDIV + 1u)));
		/* A bare grouped-hold release first: anything a previous session left
		 * pending must land BEFORE the first frame, not in the middle of one. */
		oled_status_bus_lock();
		(void)hm01b0_write(&bus, HM_GRP_HOLD, 0);
		oled_status_bus_unlock();
		i2c_xfers++;
		k_msleep(200);
		if (SD_AE_TARGET) {
			(void)hm_set(HM_AE_CTRL, 0x01);
			(void)hm_set(HM_AE_TARGET, SD_AE_TARGET);
		} else {
			(void)hm_set(HM_AE_CTRL, 0x00);
			(void)hm_set(HM_ANA_GAIN, 0x00);
			(void)hm_set(HM_INTEG_H, 0x00);
			(void)hm_set(HM_INTEG_L, 0x78);
		}
		(void)hm_set(HM_IMAGE_ORIENT, 0x00);
		oled_status_bus_lock();
		rc = hm01b0_write(&bus, HM01B0_REG_MODE_SELECT, 1);
		oled_status_bus_unlock();
		i2c_xfers++;
		printk("SD_STREAM mode_select_rc=%d\n", rc);
		k_msleep(1500);        /* let auto-exposure settle before the first frame */
	} else {
		printk("SD_NOSHIELD the sensor did not answer at 0x24 -- the live loop is "
		       "skipped; the replay gate below does not need it\n");
	}

	/* 3a. REPLAY -- the only claim about detection that does not need a person. */
#ifdef SD_REPLAY
	printk("SD_REPLAY_BEGIN n=%d bytes=%d thr_pct=%d ir_md5=%s\n",
	       SDF_N, SDF_FRAME_BYTES, SDF_THR_PCT, SDF_IR_MD5);
	BUILD_ASSERT(SDF_FRAME_BYTES == SPR_FRAME_BYTES,
		     "the baked frames are not this front end's frame size");
	BUILD_ASSERT(SDF_OUT_LEN == MODEL_OUTPUT_SIZE,
		     "the baked host outputs are not this model's output size");
	/*
	 * A THRESHOLD MISMATCH WOULD MAKE EVERY VERDICT BELOW MEANINGLESS, and silently:
	 * the board would decide at one threshold and be scored against a host that decided
	 * at another.  The bake records the threshold it used; if the build moved
	 * SD_THR_PCT, the DECISION comparison is skipped and the run says so -- the tensor
	 * comparison, which no threshold can affect, still runs.
	 */
	replay_ok = 1;
	replay_bytes_ok = 1;
	for (int i = 0; i < SDF_N; i++) {
		struct shot s;
		int dmatch, bmatch, ndiff = 0, maxabs = 0;

		seq++;
		one_shot(seq, signdet_frames[i].bytes, &s);
		print_shot(seq, "replay", &s);
		print_infer(seq, "replay", &s);
		dump_grid(seq, "replay");

		for (int k = 0; k < MODEL_OUTPUT_SIZE; k++) {
			int d = (int)net_out[k] - (int)signdet_frames[i].host_out[k];

			if (d != 0) { ndiff++; }
			if (d < 0) { d = -d; }
			if (d > maxabs) { maxabs = d; }
		}
		bmatch = (ndiff == 0);
		dmatch = (s.d.cls == signdet_frames[i].host_cls &&
			  s.d.gx == signdet_frames[i].host_gx &&
			  s.d.gy == signdet_frames[i].host_gy);
		printk("SD_REPLAY i=%d name=%s truth=%s host=%s,%d,%d,%u%% board=%s,%d,%d,%u%% "
		       "decision=%s bytes_differ=%d max_abs_err=%d tensor=%s correct=%d "
		       "thr_match=%d note=%s\n",
		       i, signdet_frames[i].name, signdet_frames[i].truth,
		       cls_name[signdet_frames[i].host_cls], signdet_frames[i].host_gx,
		       signdet_frames[i].host_gy, signdet_frames[i].host_pct,
		       s.d.cls >= 0 ? cls_name[s.d.cls] : "nothing", s.d.gx, s.d.gy, s.d.pct,
		       dmatch ? "MATCH" : "MISMATCH", ndiff, maxabs,
		       bmatch ? "MATCH" : "MISMATCH",
		       (s.d.cls >= 0 &&
			strcmp(cls_name[s.d.cls], signdet_frames[i].truth) == 0) ||
		       (s.d.cls == 0 && strcmp("background", signdet_frames[i].truth) == 0),
		       SDF_THR_PCT == SD_THR_PCT, signdet_frames[i].note);
		if (SDF_THR_PCT == SD_THR_PCT && !dmatch) { replay_ok = 0; }
		if (!bmatch) { replay_bytes_ok = 0; }
		print_ops();
		post_screen(seq, &s, "RPL");
		oled_draw();
		k_msleep(500);        /* long enough for a person to see one go past */
	}
	printk("SD_REPLAY_END decisions_ok=%d tensors_ok=%d thr_match=%d\n",
	       replay_ok, replay_bytes_ok, SDF_THR_PCT == SD_THR_PCT);
#else
	printk("SD_REPLAY_BEGIN n=0 -- NO BAKED FRAMES: this image makes no checkable claim "
	       "about detection.  Build with -DSD_FRAMES_DIR=...\n");
#endif

	/* 3b. THE LIVE LOOP -- the demo itself. */
	if (shield) {
#if SD_BUTTON
		btn = snap_btn_ready();
		printk("SD_READY button=%d mode=shutter buf=0x%08lx bytes=%u\n", btn,
		       (unsigned long)(uintptr_t)frame, (unsigned)SPR_FRAME_BYTES);
		if (!btn) {
			printk("SD_RESULT ok=0 reason=no_button_at_sw0_alias\n");
		}
#else
		btn = 1;
		printk("SD_READY button=0 mode=free_running buf=0x%08lx bytes=%u\n",
		       (unsigned long)(uintptr_t)frame, (unsigned)SPR_FRAME_BYTES);
#endif
		print_engine("pre_live");

		while (btn && !sd_should_stop() &&
		       (SD_FRAMES == 0 || live_n < (uint32_t)SD_FRAMES)) {
			struct shot s;

#if SD_BUTTON
			scr.note = "PRESS BTN0";
			oled_draw();
			if (wait_for_press() != 0) {
				printk("SD_RESULT ok=0 reason=button_read_failed\n");
				break;
			}
			scr.note = NULL;
#endif
			seq++;
			live_n++;
			one_shot(seq, NULL, &s);
			print_shot(seq, "live", &s);
#if SD_EVICT
			{
				uint32_t t = (uint32_t)rdcycle();

				s.evict_cyc = 0;
				(void)evict_l2_4mib();
				s.evict_cyc = (uint32_t)rdcycle() - t;
			}
#endif
			/* The sweep is before the line a puller keys off, never after. */
			print_infer(seq, "live", &s);
#if SD_SNAP_LINE
			printk("SNAP seq=%u addr=0x%08lx bytes=%u stride=%u h=%u rc=%d "
			       "dma_status=0x%02x saweof=%d class=%d name=%s pct=%u "
			       "cell=%d,%d ms=%u evict_cycles=%u\n",
			       seq, (unsigned long)(uintptr_t)frame, s.bytes,
			       (unsigned)SPR_STRIDE, (unsigned)SPR_H, s.rc, s.dma_status,
			       (s.dma_status & OSPI_DMA_ST_SAWEOF) ? 1 : 0, s.d.cls,
			       s.d.cls >= 0 ? cls_name[s.d.cls] : "nothing", s.d.pct,
			       s.d.gx, s.d.gy, cyc_ms(s.inf_cyc), s.evict_cyc);
#endif
			if (live_n == 1) { dump_grid(seq, "live"); }
			if (s.rc == 0 && (s.dma_status & OSPI_DMA_ST_SAWEOF) &&
			    s.bytes == SPR_FRAME_BYTES) {
				uint32_t ms = cyc_ms(s.inf_cyc);

				ok++;
				ms_sum += ms;
				if (ms < ms_min) { ms_min = ms; }
				if (ms > ms_max) { ms_max = ms; }
			}
			print_ops();
			post_screen(seq, &s, "live");
			oled_draw();
			printk("SD_OLEDCOST seq=%u draws=%u render_cycles=%u xfer_cycles=%u\n",
			       seq, oled_draws, oled_render_cyc, oled_xfer_cyc);
		}

		print_engine("total");
		oled_status_bus_lock();
		(void)hm01b0_write(&bus, HM01B0_REG_MODE_SELECT, 0);
		oled_status_bus_unlock();
		i2c_xfers++;
	}

	printk("SD_I2C sensor_xfers=%u oled_draws=%u oled_state=%s addr=0x%02x\n",
	       i2c_xfers, oled_draws, oled ? "READY" : "ABSENT_OR_FAILED", oled_addr);
	printk("SD_MS live_ok=%u ms_mean=%u ms_min=%u ms_max=%u\n", ok,
	       ok ? (uint32_t)(ms_sum / ok) : 0u, ok ? ms_min : 0u, ms_max);
	printk("SD_RESULT shield=%d seq=%u live_ok=%u replay_decisions_ok=%d "
	       "replay_tensors_ok=%d oled=%d thr_pct=%u\n",
	       shield, seq, ok, replay_ok, replay_bytes_ok, oled != NULL,
	       (unsigned)SD_THR_PCT);
	printk("SD_DONE\n");
}

/*
 * THE WHOLE DEMO RUNS PINNED TO CPU 0.  The MBP instructions exist on HART 0 ONLY
 * (PEXT_SPEC.md section 7): every curated kernel here emits real custom-0 encodings, so a
 * thread that reaches one on hart 1 takes an illegal-instruction trap.  main() starts on CPU
 * 0, but this loop sleeps -- in the capture poll and between screens -- and a rescheduled
 * thread on an SMP kernel is free to come back on the other CPU.  k_thread_cpu_pin() needs a
 * thread that has not begun running, so the worker is created K_FOREVER, pinned, then started.
 */
#ifdef SD_NO_MAIN

/*
 * SD_NO_MAIN -- ADDITIVE AND DEFAULT-OFF.  Nothing defines it but samples/tacit_duo,
 * so every image scripts/83, scripts/86 and scripts/87 have ever built still gets the
 * main() below, byte for byte.
 *
 * The duo image holds TWO pinned workloads and therefore cannot have two main()s. It
 * creates, pins and starts `demo` itself -- with the same create-K_FOREVER / pin / start
 * discipline and the same reason for it (the MBP encodings exist on hart 0 only), so the
 * property this block was protecting is not lost, only moved.
 */

#else

K_THREAD_STACK_DEFINE(demo_stack, 16384);
static struct k_thread demo_thread;

int main(void)
{
	k_tid_t tid = k_thread_create(&demo_thread, demo_stack,
				      K_THREAD_STACK_SIZEOF(demo_stack), demo,
				      NULL, NULL, NULL, 0, 0, K_FOREVER);
	int rc = k_thread_cpu_pin(tid, 0);

	k_thread_name_set(tid, "signdet_live");
	if (rc != 0) {
		printk("SD_PIN rc=%d -- could not pin the demo to CPU 0; if SD_HART reports "
		       "mhartid != 0 or mbp_available=0, stop reading here\n", rc);
	} else {
		printk("SD_PIN rc=0 cpu=0\n");
	}
	k_thread_start(tid);
	k_thread_join(tid, K_FOREVER);
	return 0;
}

#endif /* SD_NO_MAIN */
