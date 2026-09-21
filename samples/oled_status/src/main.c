/* SPDX-License-Identifier: Apache-2.0 */
/*
 * OLED status demo. Stands in for the camera + inference loop of the tutorial: it counts
 * frames at CONFIG_OLED_DEMO_FRAME_MS, measures fps from k_uptime, cycles a label and a
 * score, and takes an RTF value "from the application". The display is fed with
 * oled_status_post(), which never blocks, so this loop's timing is the proof that the
 * display does not hold anything up: the summary line reports the loop's own worst-case
 * frame lateness alongside the number of screens drawn.
 *
 * Console lines the lab greps (scripts/56_rocket_oled_board.sh):
 *   OLED_DEMO: start
 *   oled: ready at 0x3c   |   oled: no ACK at 0x3c/0x3d, not fitted ...
 *   OLED_DEMO: state=READY addr=0x3c frames=300 drawn=9 late_max_ms=0
 *   OLED_DEMO: done
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <string.h>

#include "oled_status.h"
#include "oled_golden.h"

static const char *const labels[] = {"person", "no person", "person", "unknown"};

#if defined(CONFIG_UART_HTIF)
/*
 * RTL simulation only. fesvr watches the HTIF `tohost` word: writing 1 ends the simulation,
 * the way the bare-metal samples finish (samples/pext_rtl_selftest). Without it a Zephyr
 * guest that has finished just idles until +max-cycles, and the I2C model's dump waits with
 * it. CONFIG_UART_HTIF is n on every board target, so this is not built for the board.
 */
extern volatile uint64_t tohost;

static void sim_exit(void)
{
	tohost = 1;
}
#else
static void sim_exit(void)
{
}
#endif

/*
 * Wait until the display thread has either finished probing or drawn `drawn` screens.
 *
 * The poll interval is 1 ms in golden mode because that mode runs in RTL simulation, where
 * a millisecond of guest time is half a million simulated cycles: a 10 ms poll would cost
 * minutes of wall-clock per iteration. On the board, 10 ms is the cheaper choice.
 */
static void wait_display(uint32_t drawn, int64_t timeout_ms)
{
	const int poll_ms = IS_ENABLED(CONFIG_OLED_DEMO_GOLDEN) ? 1 : 10;
	int64_t end = k_uptime_get() + timeout_ms;

	while (k_uptime_get() < end) {
		enum oled_state st = oled_status_state();

		if (st == OLED_STATE_ABSENT || st == OLED_STATE_FAILED) {
			return;
		}
		if (st == OLED_STATE_READY && oled_status_frames_drawn() >= drawn) {
			return;
		}
		k_sleep(K_MSEC(poll_ms));
	}
}

static void summary(uint32_t frames, int64_t late_max)
{
	printk("OLED_DEMO: state=%s addr=0x%02x frames=%u drawn=%u late_max_ms=%lld "
	       "render_cycles=%u xfer_cycles=%u\n",
	       oled_state_name(oled_status_state()), oled_status_addr(), frames,
	       oled_status_frames_drawn(), late_max, oled_status_last_render_cycles(),
	       oled_status_last_xfer_cycles());
}

int main(void)
{
	printk("OLED_DEMO: start\n");
	oled_status_start();

	if (IS_ENABLED(CONFIG_OLED_DEMO_GOLDEN)) {
		oled_status_post(&oled_golden_status);
		wait_display(1, 600000);
		printk("OLED_GOLDEN: status screen drawn=%u render_cycles=%u xfer_cycles=%u\n",
		       oled_status_frames_drawn(), oled_status_last_render_cycles(),
		       oled_status_last_xfer_cycles());
		oled_status_post_pattern();
		wait_display(2, 600000);
		printk("OLED_GOLDEN: pattern drawn=%u render_cycles=%u xfer_cycles=%u\n",
		       oled_status_frames_drawn(), oled_status_last_render_cycles(),
		       oled_status_last_xfer_cycles());
		summary(0, 0);
		printk("OLED_DEMO: done\n");
		sim_exit();
		return 0;
	}

	oled_status_post_pattern();
	k_sleep(K_MSEC(CONFIG_OLED_DEMO_PATTERN_MS));

	struct oled_status s = oled_golden_status;
	int64_t t0 = k_uptime_get();
	int64_t due = t0;
	int64_t late_max = 0;
	uint32_t frame = 0;

	for (;;) {
		due += CONFIG_OLED_DEMO_FRAME_MS;
		k_sleep(K_TIMEOUT_ABS_MS(due));
		int64_t now = k_uptime_get();

		if (now - due > late_max) {
			late_max = now - due;
		}
		frame++;

		s.frame = frame;
		s.fps_milli = (uint32_t)((int64_t)frame * 1000000 / MAX(now - t0, 1));
		strncpy(s.label, labels[(frame / 30U) % ARRAY_SIZE(labels)], sizeof(s.label) - 1);
		s.score_pct = (uint8_t)(50U + (frame * 7U) % 50U);
		s.rtf_milli = 4350; /* the application's own number; the demo has none */
		oled_status_post(&s);

		if (CONFIG_OLED_DEMO_FRAMES && frame == CONFIG_OLED_DEMO_FRAMES) {
			wait_display(oled_status_frames_drawn() + 1, 5000);
			summary(frame, late_max);
			printk("OLED_DEMO: done\n");
			sim_exit();
			return 0;
		}
	}
}
