/* SPDX-License-Identifier: Apache-2.0 */
/*
 * A five-line status screen on a 128x64 SSD1306 OLED that shares the camera's I2C bus.
 *
 * The rules this code keeps (fpga/pynq-z2/docs/OLED_SSD1306.md section 5):
 *
 *   NEVER IN THE BOOT PATH.  Both candidate display nodes (0x3c, 0x3d) are
 *   `zephyr,deferred-init`, so nothing touches the bus before main().  Probing and the
 *   SSD1306 init sequence run in oled_status's own thread.
 *
 *   NEVER BLOCKS THE CALLER.  oled_status_post() copies the numbers under a spinlock and
 *   gives a semaphore.  Rendering and the I2C transfer happen in a preemptible thread at
 *   the lowest application priority, at most once per CONFIG_OLED_STATUS_PERIOD_MS.
 *
 *   ABSENT IS NOT AN ERROR.  If neither address ACKs, it logs "not fitted" once and the
 *   thread exits.  If a transfer fails later, it logs once and stops using the bus.
 *
 *   ONE BUS, ONE LOCK.  Zephyr's i2c_sifive has no lock of its own.  Every user of the
 *   same I2C controller in the image -- the camera's exposure writes included -- must hold
 *   oled_status_bus_lock() around each transfer.
 */
#ifndef OLED_STATUS_H_
#define OLED_STATUS_H_

#include <stdbool.h>
#include <stdint.h>
#include <zephyr/device.h>

#define OLED_STATUS_LABEL_MAX 16

struct oled_status {
	uint32_t soc_magic;      /* SOC_MAGIC, e.g. 0x5A5A001E */
	const char *soc_name;    /* static string, e.g. "roccmoon" */
	uint32_t frame;          /* frame counter */
	uint32_t fps_milli;      /* frames per second x 1000 */
	char label[OLED_STATUS_LABEL_MAX]; /* classification label */
	uint8_t score_pct;       /* label confidence, 0..100 (drawn as a bar) */
	uint32_t rtf_milli;      /* real-time factor x 1000, supplied by the application */
};

enum oled_state {
	OLED_STATE_IDLE = 0,     /* oled_status_start() not called yet */
	OLED_STATE_PROBING,
	OLED_STATE_READY,
	OLED_STATE_ABSENT,       /* no ACK at any candidate address: not fitted */
	OLED_STATE_FAILED,       /* ACKed, then a transfer failed: stopped using the bus */
};

/* Start the display thread. Returns immediately; never touches the bus itself. */
int oled_status_start(void);

/* Latest numbers for the screen. Non-blocking, callable from any thread. */
void oled_status_post(const struct oled_status *s);

/* Show the test pattern instead, until the next oled_status_post(). Non-blocking. */
void oled_status_post_pattern(void);

enum oled_state oled_status_state(void);
const char *oled_state_name(enum oled_state st);
uint16_t oled_status_addr(void);          /* 7-bit address in use, 0 if none */
uint32_t oled_status_frames_drawn(void);  /* completed screen refreshes */

/*
 * Cost of the last refresh in core cycles (mcycle), split into the CFB rendering and the
 * I2C transfer the driver busy-polls through. 0 until the first refresh. Used by the RTL
 * simulation and the board lab to put a measured number against OLED_SSD1306.md section 4.
 */
uint32_t oled_status_last_render_cycles(void);
uint32_t oled_status_last_xfer_cycles(void);

/* The application's I2C bus mutex (a k_mutex: priority inheritance). */
void oled_status_bus_lock(void);
void oled_status_bus_unlock(void);

/*
 * Rendering, exposed for the host test and for applications that drive the display
 * themselves. All three draw into the CFB buffer only; call cfb_framebuffer_finalize()
 * (under the bus lock) to send it.
 */
int oled_status_render(const struct device *disp, const struct oled_status *s);
int oled_test_pattern(const struct device *disp);

/*
 * Horizontal bar graph: a 1-pixel outline of w x h at (x, y), filled from the left in
 * proportion to value/full_scale with a 1-pixel gap inside the outline. value is clamped
 * to full_scale. Needs w >= 5 and h >= 5.
 */
int oled_bar(const struct device *disp, uint16_t x, uint16_t y, uint16_t w, uint16_t h,
	     uint32_t value, uint32_t full_scale);

/* CFB setup shared by the thread and the host test: font, lit-on-dark polarity. */
int oled_cfb_setup(const struct device *disp);

#endif /* OLED_STATUS_H_ */
