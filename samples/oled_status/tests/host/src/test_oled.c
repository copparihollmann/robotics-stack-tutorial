/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Host test: samples/oled_status on the stock ssd1306 driver and CFB, over Zephyr's I2C
 * emulator, into the behavioural SSD1306 model. See fpga/pynq-z2/docs/OLED_SSD1306.md
 * sections 5.2 (the init sequence) and 7 (results).
 *
 * The rendered images are not compared here. They are dumped as
 *     PGMHEX <name> <offset> <hex bytes>
 * lines, and scripts/54_oled_host_tests.sh rebuilds the PGM files, hashes them and compares
 * the hashes with expected/oled_status.json. The RTL simulation's model writes the same
 * PGM, so one golden serves both.
 */
#include <string.h>
#include <zephyr/display/cfb.h>
#include <zephyr/drivers/display.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/ztest.h>

#include "oled_golden.h"
#include "oled_status.h"
#include "ssd1306_emul.h"

static uint8_t pgm[16 + SSD1306_MODEL_W * SSD1306_MODEL_H];

static void dump_pgm(const char *name, const struct ssd1306_model *m)
{
	size_t n = ssd1306_model_pgm(m, pgm, sizeof(pgm));

	zassert_true(n > 0, "pgm buffer too small");
	for (size_t off = 0; off < n; off += 64) {
		printk("PGMHEX %s %zu ", name, off);
		for (size_t i = off; i < n && i < off + 64; i++) {
			printk("%02x", pgm[i]);
		}
		printk("\n");
	}
}

static void dump_wire(const char *name, const struct ssd1306_model *m)
{
	/* printk has a line limit; emit the log a line at a time */
	const char *p = m->log;

	while (*p) {
		const char *e = strchr(p, '\n');
		size_t len = e ? (size_t)(e - p) : strlen(p);

		/* long transfers go out in 240-character pieces; "WIRE+" continues a line */
		for (size_t off = 0; off < len; off += 240) {
			char piece[241];
			size_t n = MIN(len - off, 240);

			/* copy: a %.*s argument is still packaged whole by deferred printk */
			memcpy(piece, p + off, n);
			piece[n] = '\0';
			printk("WIRE%s %s %s\n", off ? "+" : "", name, piece);
		}
		p += len + (e ? 1 : 0);
	}
}

static bool wait_state(enum oled_state want, uint32_t drawn, int ms)
{
	for (int i = 0; i < ms; i++) {
		if (oled_status_state() == want && oled_status_frames_drawn() >= drawn) {
			return true;
		}
		k_msleep(1);
	}
	return false;
}

/* The exact command bytes of probe + ssd1306_init_device(), from the driver source. */
static const uint8_t expected_init_cmds[] = {
	0xe3,                                     /* our probe: NOP */
	0xae,                                     /* display off */
	0xd5, 0x80, 0xd9, 0x22, 0xdb, 0x20,       /* clock, precharge, VCOMH */
	0x40, 0xd3, 0x00, 0xda, 0x12, 0xa8, 0x3f, /* start line, offset, COM pins, mux */
	0xa1, 0xc8,                               /* segment remap, COM scan flipped */
	0x8d, 0x14, 0x33,                         /* charge pump on, then 0x33 */
	0xa4, 0xa6,                               /* RAM content, normal */
	0x81, 0x80,                               /* contrast 128 */
	0xaf,                                     /* display on */
};

static const uint8_t expected_window[] = {0x20, 0x00, 0x21, 0x00, 0x7f, 0x22, 0x00, 0x07};

#if !defined(CONFIG_OLED_TEST_ABSENT)

ZTEST(oled_present, test_01_probe_and_init_sequence)
{
	struct ssd1306_model *m = ssd1306_emul_model(0x3c);
	int pump = -1, on = -1;

	zassert_not_null(m);
	ssd1306_emul_set_wire(SSD1306_EMUL_WIRE_CONTRACT);
	zassert_ok(oled_status_start());
	zassert_true(wait_state(OLED_STATE_READY, 0, 2000), "state %s",
		     oled_state_name(oled_status_state()));
	zassert_equal(oled_status_addr(), 0x3c);
	dump_wire("init", m);

	zassert_equal(m->n_cmds_kept, sizeof(expected_init_cmds), "got %zu command bytes",
		      m->n_cmds_kept);
	zassert_mem_equal(m->cmds, expected_init_cmds, sizeof(expected_init_cmds));

	/* datasheet ordering, asserted independently of the exact list */
	for (size_t i = 0; i + 1 < m->n_cmds_kept; i++) {
		if (m->cmds[i] == 0x8d && m->cmds[i + 1] == 0x14 && pump < 0) {
			pump = (int)i;
		}
	}
	for (size_t i = 0; i < m->n_cmds_kept; i++) {
		if (m->cmds[i] == 0xaf) {
			on = (int)i;
		}
	}
	zassert_true(pump >= 0, "charge pump 8D 14 never sent");
	zassert_true(on > pump, "display on (AF) must follow 8D 14");
	zassert_equal(on, (int)m->n_cmds_kept - 1, "AF must be the last init command");
	zassert_equal(m->cmds[1], 0xae, "init must start with the panel off");
	zassert_false(m->pump_before_on_violation);
	zassert_true(m->display_on && m->charge_pump);
	zassert_equal(m->mux, 63);
	zassert_equal(m->com_pins, 0x12, "128x64 panels use alternative COM pins");
	zassert_equal(m->n_bad_ctrl, 0);
	zassert_equal(m->n_restart, 0, "API-contract wire: no repeated START");
	zassert_equal(m->n_start, m->n_stop, "every transfer closed");
	zassert_equal(m->n_unknown_cmds, 1, "exactly one unassigned code: the 0x33 after 8D 14");
	zassert_equal(m->n_data_bytes, 0);
}

ZTEST(oled_present, test_02_golden_status_screen)
{
	struct ssd1306_model *m = ssd1306_emul_model(0x3c);
	size_t cmds_before = m->n_cmds_kept;
	uint32_t drawn = oled_status_frames_drawn();

	m->log_len = 0;
	m->log[0] = '\0';
	oled_status_post(&oled_golden_status);
	zassert_true(wait_state(OLED_STATE_READY, drawn + 1, 2000));

	/* addressing mode + window before the data, then exactly one frame of GDDRAM */
	zassert_equal(m->n_cmds_kept - cmds_before, sizeof(expected_window));
	zassert_mem_equal(m->cmds + cmds_before, expected_window, sizeof(expected_window));
	zassert_equal(m->mode, 0, "horizontal addressing");
	zassert_equal(m->n_data_bytes, 1024);
	zassert_equal(m->n_restart, 0);
	zassert_equal(m->n_bad_ctrl, 0);
	dump_pgm("status", m);
}

ZTEST(oled_present, test_03_golden_test_pattern)
{
	struct ssd1306_model *m = ssd1306_emul_model(0x3c);
	uint32_t drawn = oled_status_frames_drawn();

	oled_status_post_pattern();
	zassert_true(wait_state(OLED_STATE_READY, drawn + 1, 2000));
	zassert_equal(m->n_data_bytes, 2048);
	/* the border is lit on all four edges */
	zassert_true(ssd1306_model_pixel(m, 0, 0) && ssd1306_model_pixel(m, 127, 63));
	zassert_true(ssd1306_model_pixel(m, 64, 0) && ssd1306_model_pixel(m, 0, 32));
	dump_pgm("pattern", m);
}

ZTEST(oled_present, test_04_bar_graph_geometry)
{
	struct ssd1306_model *m = ssd1306_emul_model(0x3c);
	const struct device *disp = DEVICE_DT_GET(DT_NODELABEL(oled_3c));
	static const uint32_t vals[] = {0, 25, 100, 150};
	static const int fill_px[] = {0, 31, 124, 124}; /* (128-4) * v / 100, clamped */

	for (size_t k = 0; k < ARRAY_SIZE(vals); k++) {
		int lit = 0;

		zassert_ok(cfb_framebuffer_clear(disp, false));
		zassert_ok(oled_bar(disp, 0, 8, 128, 8, vals[k], 100));
		oled_status_bus_lock();
		zassert_ok(cfb_framebuffer_finalize(disp));
		oled_status_bus_unlock();
		/* outline: rows 8 and 15, columns 0 and 127 */
		zassert_true(ssd1306_model_pixel(m, 0, 8) && ssd1306_model_pixel(m, 127, 15));
		zassert_true(ssd1306_model_pixel(m, 0, 12) && ssd1306_model_pixel(m, 127, 12));
		/* 1-pixel gap inside the outline */
		zassert_false(ssd1306_model_pixel(m, 1, 12));
		zassert_false(ssd1306_model_pixel(m, 60, 9));
		/* fill row 12, columns 2..125 */
		for (int x = 2; x < 126; x++) {
			lit += ssd1306_model_pixel(m, x, 12);
		}
		zassert_equal(lit, fill_px[k], "value %u: %d px lit", vals[k], lit);
		/* nothing outside the bar */
		zassert_false(ssd1306_model_pixel(m, 10, 7) || ssd1306_model_pixel(m, 10, 16));
	}
	zassert_equal(oled_bar(disp, 0, 0, 4, 8, 1, 2), -EINVAL);
	zassert_equal(oled_bar(disp, 0, 0, 8, 8, 1, 0), -EINVAL);
}

ZTEST(oled_present, test_05_post_never_blocks)
{
	/* A burst of posts while refreshes run: each returns without waiting for the bus. */
	struct oled_status s = oled_golden_status;
	int64_t t0 = k_uptime_ticks();

	oled_status_bus_lock(); /* hold the bus: a blocking post would deadlock here */
	for (int i = 0; i < 1000; i++) {
		s.frame = i;
		oled_status_post(&s);
	}
	oled_status_bus_unlock();
	zassert_true(k_uptime_ticks() - t0 <= 1, "posting took %lld ticks",
		     k_uptime_ticks() - t0);
}

/*
 * Negative control for the golden comparison: the same screen through a wire model of the
 * stock i2c_sifive reading (a repeated START before every payload) must NOT reproduce the
 * golden. Run last: it leaves the model's panel state scrambled.
 */
ZTEST(oled_present, test_99_stock_sifive_wire_negative_control)
{
	struct ssd1306_model *m = ssd1306_emul_model(0x3c);
	const struct device *disp = DEVICE_DT_GET(DT_NODELABEL(oled_3c));
	unsigned long restarts = m->n_restart;

	zassert_ok(oled_status_render(disp, &oled_golden_status));
	ssd1306_emul_set_wire(SSD1306_EMUL_WIRE_STOCK_SIFIVE);
	m->log_len = 0;
	m->log[0] = '\0';
	oled_status_bus_lock();
	(void)cfb_framebuffer_finalize(disp);
	oled_status_bus_unlock();
	ssd1306_emul_set_wire(SSD1306_EMUL_WIRE_CONTRACT);
	dump_wire("stock", m);
	zassert_true(m->n_restart > restarts, "stock wire model sends Sr before each payload");
	dump_pgm("stock_status", m);
}

ZTEST_SUITE(oled_present, NULL, NULL, NULL, NULL, NULL);

#else /* CONFIG_OLED_TEST_ABSENT */

ZTEST(oled_absent, test_01_absent_is_not_fitted_and_nothing_blocks)
{
	struct ssd1306_model *m3c = ssd1306_emul_model(0x3c);
	struct ssd1306_model *m3d = ssd1306_emul_model(0x3d);
	struct oled_status s = oled_golden_status;

	zassert_ok(oled_status_start());
	zassert_true(wait_state(OLED_STATE_ABSENT, 0, 2000), "state %s",
		     oled_state_name(oled_status_state()));
	zassert_equal(oled_status_addr(), 0);
	/* exactly one probe per address, and the bus left alone afterwards */
	zassert_equal(m3c->n_addr_nack, 1);
	zassert_equal(m3d->n_addr_nack, 1);
	for (int i = 0; i < 100; i++) {
		s.frame = i;
		oled_status_post(&s);
	}
	k_msleep(100);
	zassert_equal(m3c->n_start + m3d->n_start, 2, "no bus traffic after 'not fitted'");
	zassert_equal(oled_status_frames_drawn(), 0);
	zassert_equal(oled_status_start(), -EALREADY);
}

ZTEST_SUITE(oled_absent, NULL, NULL, NULL, NULL, NULL);

#endif
