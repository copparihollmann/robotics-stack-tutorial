/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Status screen for a 128x64 SSD1306 on the camera's I2C bus. See oled_status.h for the
 * rules and fpga/pynq-z2/docs/OLED_SSD1306.md section 5 for why each one exists.
 *
 * Output is printk, not LOG_*: the boards this runs on build with CONFIG_LOG=n, the lab
 * scripts grep the console, and pulling in the logging subsystem for four messages would
 * cost more than this whole file.
 */
#include "oled_status.h"

#include <errno.h>
#include <string.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/display/cfb.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/kernel.h>
#include <zephyr/spinlock.h>
#include <zephyr/sys/printk.h>

#if defined(CONFIG_RISCV)
#include <zephyr/arch/riscv/csr.h>
#define OLED_CYCLES() ((uint32_t)csr_read(mcycle))
#else
#define OLED_CYCLES() ((uint32_t)k_cycle_get_32())
#endif

#define COLS  25	/* 128 px / 5 px font */
#define ROW_H 8

/* ---- candidates: every okay SSD1306 node labelled oled_3c / oled_3d ---- */

struct oled_candidate {
	const struct device *disp;
	const struct device *bus;
	uint16_t addr;
};

#define OLED_CANDIDATE(label)                                                              \
	COND_CODE_1(DT_NODE_HAS_STATUS_OKAY(DT_NODELABEL(label)),                          \
		    ({.disp = DEVICE_DT_GET(DT_NODELABEL(label)),                           \
		      .bus = DEVICE_DT_GET(DT_BUS(DT_NODELABEL(label))),                    \
		      .addr = DT_REG_ADDR(DT_NODELABEL(label))},),                          \
		    ())

static const struct oled_candidate candidates[] = {
	OLED_CANDIDATE(oled_3c)
	OLED_CANDIDATE(oled_3d)
};

/* ---- shared state ---- */

K_MUTEX_DEFINE(oled_bus_mutex);
static K_SEM_DEFINE(post_sem, 0, 1);
static struct k_spinlock post_lock;
static struct oled_status posted;
static bool post_is_pattern;

static atomic_t state = ATOMIC_INIT(OLED_STATE_IDLE);
static uint16_t addr_in_use;
static atomic_t frames_drawn;
static uint32_t last_render_cycles, last_xfer_cycles;

void oled_status_bus_lock(void)
{
	k_mutex_lock(&oled_bus_mutex, K_FOREVER);
}

void oled_status_bus_unlock(void)
{
	k_mutex_unlock(&oled_bus_mutex);
}

enum oled_state oled_status_state(void)
{
	return (enum oled_state)atomic_get(&state);
}

const char *oled_state_name(enum oled_state st)
{
	switch (st) {
	case OLED_STATE_IDLE:    return "IDLE";
	case OLED_STATE_PROBING: return "PROBING";
	case OLED_STATE_READY:   return "READY";
	case OLED_STATE_ABSENT:  return "ABSENT";
	case OLED_STATE_FAILED:  return "FAILED";
	}
	return "?";
}

uint16_t oled_status_addr(void)
{
	return addr_in_use;
}

uint32_t oled_status_frames_drawn(void)
{
	return (uint32_t)atomic_get(&frames_drawn);
}

uint32_t oled_status_last_render_cycles(void)
{
	return last_render_cycles;
}

uint32_t oled_status_last_xfer_cycles(void)
{
	return last_xfer_cycles;
}

void oled_status_post(const struct oled_status *s)
{
	k_spinlock_key_t key = k_spin_lock(&post_lock);

	posted = *s;
	posted.label[OLED_STATUS_LABEL_MAX - 1] = '\0';
	post_is_pattern = false;
	k_spin_unlock(&post_lock, key);
	k_sem_give(&post_sem);
}

void oled_status_post_pattern(void)
{
	k_spinlock_key_t key = k_spin_lock(&post_lock);

	post_is_pattern = true;
	k_spin_unlock(&post_lock, key);
	k_sem_give(&post_sem);
}

/* ---- rendering (CFB buffer only, no bus access) ---- */

static void put_hex32(char *p, uint32_t v)
{
	static const char hex[] = "0123456789ABCDEF";

	for (int i = 7; i >= 0; i--) {
		p[i] = hex[v & 0xf];
		v >>= 4;
	}
}

static int print_row(const struct device *disp, int row, const char *s)
{
	char buf[COLS + 1];

	/* Truncate rather than let CFB wrap onto the next row. */
	strncpy(buf, s, COLS);
	buf[COLS] = '\0';
	return cfb_print(disp, buf, 0, row * ROW_H);
}

int oled_bar(const struct device *disp, uint16_t x, uint16_t y, uint16_t w, uint16_t h,
	     uint32_t value, uint32_t full_scale)
{
	struct cfb_position start = {.x = x, .y = y};
	struct cfb_position end = {.x = x + w - 1, .y = y + h - 1};
	uint32_t inner = w - 4U;
	uint32_t fill;
	int ret;

	if (w < 5U || h < 5U || full_scale == 0U) {
		return -EINVAL;
	}
	if (value > full_scale) {
		value = full_scale;
	}
	ret = cfb_draw_rect(disp, &start, &end);
	if (ret) {
		return ret;
	}
	fill = (uint32_t)(((uint64_t)inner * value) / full_scale);
	if (fill == 0U) {
		return 0;
	}
	return cfb_invert_area(disp, x + 2, y + 2, fill, h - 4);
}

int oled_status_render(const struct device *disp, const struct oled_status *s)
{
	char buf[COLS + 8];
	int ret;

	ret = cfb_framebuffer_clear(disp, false);
	if (ret) {
		return ret;
	}

	/* row 0: MAGIC and SoC name */
	memcpy(buf, "0x", 2);
	put_hex32(buf + 2, s->soc_magic);
	buf[10] = ' ';
	strncpy(buf + 11, s->soc_name ? s->soc_name : "", COLS - 11);
	buf[COLS] = '\0';
	ret |= print_row(disp, 0, buf);

	/* rows 1-2: frame counter and fps */
	snprintk(buf, sizeof(buf), "frame %u", s->frame);
	ret |= print_row(disp, 1, buf);
	snprintk(buf, sizeof(buf), "fps   %u.%02u", s->fps_milli / 1000U,
		 (s->fps_milli % 1000U) / 10U);
	ret |= print_row(disp, 2, buf);

	/* row 3: label and confidence; row 4: its bar */
	snprintk(buf, sizeof(buf), "%s", s->label);
	for (size_t n = strlen(buf); n < 20U; n++) {
		buf[n] = ' ';
	}
	snprintk(buf + 20, sizeof(buf) - 20, "%3u%%", s->score_pct > 100 ? 100 : s->score_pct);
	ret |= print_row(disp, 3, buf);
	ret |= oled_bar(disp, 0, 4 * ROW_H + 1, 128, 6, s->score_pct, 100);

	/* row 5: RTF, row 6: its bar against CONFIG_OLED_STATUS_RTF_FULL_SCALE_MILLI */
	snprintk(buf, sizeof(buf), "RTF   %u.%03u", s->rtf_milli / 1000U, s->rtf_milli % 1000U);
	ret |= print_row(disp, 5, buf);
	ret |= oled_bar(disp, 0, 6 * ROW_H + 1, 128, 6, s->rtf_milli,
			CONFIG_OLED_STATUS_RTF_FULL_SCALE_MILLI);

	/* row 7: legend for the second bar */
	snprintk(buf, sizeof(buf), "RTF bar 0..%u", CONFIG_OLED_STATUS_RTF_FULL_SCALE_MILLI / 1000U);
	ret |= print_row(disp, 7, buf);

	return ret ? -EIO : 0;
}

int oled_test_pattern(const struct device *disp)
{
	struct cfb_position a = {.x = 0, .y = 0};
	struct cfb_position b = {.x = 127, .y = 63};
	int ret = cfb_framebuffer_clear(disp, false);

	ret |= cfb_draw_rect(disp, &a, &b);
	/* 8x8 checkerboard in the right third, one tile per cell */
	for (uint16_t ty = 1; ty < 7; ty++) {
		for (uint16_t tx = 12; tx < 15; tx++) {
			if (((tx + ty) & 1U) == 0U) {
				ret |= cfb_invert_area(disp, tx * 8, ty * 8, 8, 8);
			}
		}
	}
	ret |= cfb_print(disp, "OLED TEST", 4, 1 * ROW_H);
	ret |= cfb_print(disp, "128x64", 4, 2 * ROW_H);
	ret |= cfb_print(disp, "ABCabc 0123", 4, 4 * ROW_H);
	ret |= oled_bar(disp, 4, 6 * ROW_H, 88, 7, 1, 2);
	return ret ? -EIO : 0;
}

int oled_cfb_setup(const struct device *disp)
{
	int n, ret;
	uint8_t w, h;

	ret = cfb_framebuffer_init(disp);
	if (ret) {
		return ret;
	}
	/* Pick the 5x8 font by size, so an image that also links the stock fonts still works. */
	n = cfb_get_numof_fonts(disp);
	for (int i = 0; i < n; i++) {
		if (cfb_get_font_size(disp, i, &w, &h) == 0 && w == 5 && h == 8) {
			cfb_framebuffer_set_font(disp, i);
			break;
		}
	}
	/*
	 * The SSD1306 driver reports PIXEL_FORMAT_MONO01, and CFB's finalize inverts the
	 * buffer for MONO01 unless the framebuffer is marked inverted. Marking it here makes
	 * a set bit a lit pixel: light text on a dark panel. No bus traffic.
	 */
	return cfb_framebuffer_invert(disp);
}

/* ---- the display thread ---- */

static void say_once(const char *what, int err, uint16_t addr)
{
	printk("oled: %s (addr 0x%02x, err %d) -- display disabled, capture and inference unaffected\n",
	       what, addr, err);
}

static const struct oled_candidate *probe(void)
{
	/* One NOP under a command control byte: harmless on an SSD1306, ACKed if present. */
	static const uint8_t nop[] = {0x00, 0xE3};

	for (size_t i = 0; i < ARRAY_SIZE(candidates); i++) {
		const struct oled_candidate *c = &candidates[i];
		int ret;

		if (!device_is_ready(c->bus)) {
			continue;
		}
		oled_status_bus_lock();
		ret = i2c_write(c->bus, nop, sizeof(nop), c->addr);
		oled_status_bus_unlock();
		if (ret == 0) {
			return c;
		}
	}
	return NULL;
}

static void oled_thread(void *p1, void *p2, void *p3)
{
	const struct oled_candidate *c;
	struct oled_status snap;
	bool pattern;
	int64_t next = 0;
	int ret;

	ARG_UNUSED(p1);
	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	atomic_set(&state, OLED_STATE_PROBING);
	c = probe();
	if (c == NULL) {
		atomic_set(&state, OLED_STATE_ABSENT);
		say_once("no ACK at 0x3c/0x3d, not fitted", -EIO, 0);
		return;
	}
	addr_in_use = c->addr;

	oled_status_bus_lock();
	ret = device_init(c->disp); /* the SSD1306 init sequence */
	oled_status_bus_unlock();
	if (ret != 0 && ret != -EALREADY) {
		atomic_set(&state, OLED_STATE_FAILED);
		say_once("ACKed but init failed", ret, c->addr);
		return;
	}
	ret = oled_cfb_setup(c->disp);
	if (ret) {
		atomic_set(&state, OLED_STATE_FAILED);
		say_once("framebuffer setup failed", ret, c->addr);
		return;
	}
	atomic_set(&state, OLED_STATE_READY);
	printk("oled: ready at 0x%02x\n", c->addr);

	for (;;) {
		k_sem_take(&post_sem, K_FOREVER);

		/* Rate limit: at most one refresh per period; the newest post wins. */
		int64_t now = k_uptime_get();

		if (now < next) {
			k_sleep(K_MSEC(next - now));
		}

		k_spinlock_key_t key = k_spin_lock(&post_lock);

		snap = posted;
		pattern = post_is_pattern;
		k_spin_unlock(&post_lock, key);

		uint32_t t0 = OLED_CYCLES();

		if (pattern) {
			ret = oled_test_pattern(c->disp);
		} else {
			ret = oled_status_render(c->disp, &snap);
		}
		uint32_t t1 = OLED_CYCLES();

		if (ret == 0) {
			oled_status_bus_lock();
			ret = cfb_framebuffer_finalize(c->disp);
			oled_status_bus_unlock();
		}
		last_render_cycles = t1 - t0;
		last_xfer_cycles = OLED_CYCLES() - t1;
		if (ret) {
			atomic_set(&state, OLED_STATE_FAILED);
			say_once("refresh failed", ret, c->addr);
			return;
		}
		atomic_inc(&frames_drawn);
		next = k_uptime_get() + CONFIG_OLED_STATUS_PERIOD_MS;
	}
}

K_THREAD_STACK_DEFINE(oled_stack, CONFIG_OLED_STATUS_STACK_SIZE);
static struct k_thread oled_thread_data;

int oled_status_start(void)
{
	if (atomic_cas(&state, OLED_STATE_IDLE, OLED_STATE_PROBING) == false) {
		return -EALREADY;
	}
	if (ARRAY_SIZE(candidates) == 0) {
		atomic_set(&state, OLED_STATE_ABSENT);
		say_once("no SSD1306 node in the devicetree", -ENODEV, 0);
		return 0;
	}
	k_thread_create(&oled_thread_data, oled_stack, K_THREAD_STACK_SIZEOF(oled_stack),
			oled_thread, NULL, NULL, NULL, K_LOWEST_APPLICATION_THREAD_PRIO, 0,
			K_NO_WAIT);
	k_thread_name_set(&oled_thread_data, "oled");
	return 0;
}
