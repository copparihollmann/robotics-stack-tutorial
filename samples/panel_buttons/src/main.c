/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Read the PYNQ-Z1's four pushbuttons and report, for each one, whether its level EVER
 * CHANGED while this program was watching.
 *
 * WHAT THIS SAMPLE IS FOR, AND THE ONE THING IT REFUSES TO DO.  A button that is wired
 * correctly and a button whose pin is stuck at 0 read exactly the same when nobody is
 * touching it: 0.  So this sample does not report "the button works".  It reports
 *
 *     lo / hi   how many debounced samples read 0 and how many read 1
 *     rise / fall   how many 0 -> 1 and 1 -> 0 transitions it saw
 *     changed=YES   if and only if rise + fall > 0
 *
 * and the summary line says pressed_any=NO when nothing moved.  A stable reading is NOT
 * evidence, and the console says so in words, because the lab script that reads this
 * console cannot tell a broken button from an untouched one and neither can this program.
 *
 * WHY POLLING RATHER THAN INTERRUPTS.  The four pins have PLIC sources (9..12 on
 * 0x5A5A0037) and the sifive GPIO driver would connect them, but an interrupt-driven
 * version proves less: a missed edge is indistinguishable from an unpressed button, while
 * a poll that never sees a 1 has at least looked CONFIG_PANEL_BTN_SECONDS * 100 times.
 * The buttons are also undebounced in hardware -- there is no debounce circuit on the
 * board -- so an edge-triggered reader would count bounces as presses.
 *
 * input_en IS THE TRAP.  Nothing in the PL drives these balls; the top level feeds the
 * GPIO controller's i_ival from the pad gated by the controller's own input_en register
 * (src/pynqz2_rocket_top.v).  A guest that never configures the pins as inputs reads 0
 * forever and reports a healthy-looking "no press".  gpio_pin_configure_dt(GPIO_INPUT)
 * sets in_en (drivers/gpio/gpio_sifive.c writes it from the GPIO_INPUT flag), and this
 * sample prints the raw port word before and after configuring so the record shows the
 * register actually moved.
 *
 * THE LAMPS ARE FEEDBACK FOR THE PERSON AT THE BENCH, and are also the check that this
 * board's led0..led5 aliases still point where they did on chipyard_pynqz1_micrgb_f40:
 * LD4 is RED while nothing is pressed and GREEN while any button is held.  If the lamp
 * never changes colour when a button is pressed, the press did not reach the SoC.
 *
 * Console lines the lab greps (scripts/81_rocket_panel_board.sh):
 *   PANEL_BTN: start board=<target> buttons=<n>
 *   PANEL_BTN: raw in_val before=0x000 after=0x000
 *   PANEL_BTN: watching <n> s -- PRESS EVERY BUTTON NOW
 *   PANEL_BTN: sw0 pin=6 init=0 lo=1234 hi=56 rise=3 fall=3 changed=YES
 *   PANEL_BTN: pressed_any=YES
 *   PANEL_BTN: done
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/drivers/gpio.h>

#define HAS_SW(n) DT_NODE_EXISTS(DT_ALIAS(n))

BUILD_ASSERT(HAS_SW(sw0),
	     "no sw0 alias: this sample needs a board whose SoC has the four pushbuttons, "
	     "i.e. chipyard_pynqz1_panel_f40 (0x5A5A0037). chipyard_pynqz1_oled_f40 and "
	     "chipyard_pynqz1_micrgb_f40 have a six-pin GPIO controller and no button pins.");

static const struct gpio_dt_spec sw[] = {
	GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios),
#if HAS_SW(sw1)
	GPIO_DT_SPEC_GET(DT_ALIAS(sw1), gpios),
#endif
#if HAS_SW(sw2)
	GPIO_DT_SPEC_GET(DT_ALIAS(sw2), gpios),
#endif
#if HAS_SW(sw3)
	GPIO_DT_SPEC_GET(DT_ALIAS(sw3), gpios),
#endif
};
#define NSW ARRAY_SIZE(sw)

/* LD4's three colours, by the aliases every other sample on this SoC uses. */
#define LED_SPEC(n) GPIO_DT_SPEC_GET_OR(DT_ALIAS(n), gpios, {0})
static const struct gpio_dt_spec ld4_b = LED_SPEC(led0), ld4_g = LED_SPEC(led1),
				 ld4_r = LED_SPEC(led2);

static void led_set(const struct gpio_dt_spec *s, int on)
{
	if (s->port != NULL) {
		(void)gpio_pin_set_dt(s, on);
	}
}

struct btn_stat {
	int init;
	int last;
	uint32_t lo, hi, rise, fall;
};

int main(void)
{
	static struct btn_stat st[NSW];
	const int period_ms = 10;
	const int64_t secs = CONFIG_PANEL_BTN_SECONDS;
	gpio_port_value_t raw_before = 0, raw_after = 0;
	int any_change = 0;

	printk("PANEL_BTN: start board=%s buttons=%u\n", CONFIG_BOARD_TARGET, (unsigned)NSW);

	for (size_t i = 0; i < NSW; i++) {
		if (!gpio_is_ready_dt(&sw[i])) {
			printk("PANEL_BTN: FAIL sw%u device not ready\n", (unsigned)i);
			return 0;
		}
	}

	/*
	 * The raw input register BEFORE any pin is configured as an input.  On this SoC it
	 * must read 0 for the button pins whatever the buttons are doing, because input_en
	 * is clear -- gpio_sifive_init() zeroes it.  Printing it makes the "guest never set
	 * input_en" failure visible in the record instead of looking like "nobody pressed".
	 */
	(void)gpio_port_get_raw(sw[0].port, &raw_before);

	for (size_t i = 0; i < NSW; i++) {
		int rc = gpio_pin_configure_dt(&sw[i], GPIO_INPUT);

		if (rc != 0) {
			printk("PANEL_BTN: FAIL sw%u configure rc=%d\n", (unsigned)i, rc);
			return 0;
		}
	}
	(void)gpio_port_get_raw(sw[0].port, &raw_after);
	printk("PANEL_BTN: raw in_val before=0x%03x after=0x%03x\n",
	       (unsigned)raw_before, (unsigned)raw_after);

	for (size_t i = 0; i < NSW; i++) {
		int v = gpio_pin_get_dt(&sw[i]);

		st[i].init = v;
		st[i].last = v;
	}

	led_set(&ld4_b, 0);
	led_set(&ld4_g, 0);
	led_set(&ld4_r, 0);
	if (ld4_r.port != NULL) {
		(void)gpio_pin_configure_dt(&ld4_b, GPIO_OUTPUT_INACTIVE);
		(void)gpio_pin_configure_dt(&ld4_g, GPIO_OUTPUT_INACTIVE);
		(void)gpio_pin_configure_dt(&ld4_r, GPIO_OUTPUT_ACTIVE);
	}

	printk("PANEL_BTN: watching %lld s -- PRESS EVERY BUTTON NOW\n", secs);
	printk("PANEL_BTN:   LD4 is RED while nothing is pressed, GREEN while a button is held.\n");
	printk("PANEL_BTN:   A button that is never pressed and a button that is broken read\n");
	printk("PANEL_BTN:   the same. Only changed=YES is evidence.\n");

	int64_t end = k_uptime_get() + secs * 1000;
	int prev_any = 0;

	while (k_uptime_get() < end) {
		int any_down = 0;

		for (size_t i = 0; i < NSW; i++) {
			int a = gpio_pin_get_dt(&sw[i]);

			k_sleep(K_MSEC(1));
			int b = gpio_pin_get_dt(&sw[i]);

			if (a < 0 || b < 0 || a != b) {
				continue;       /* bounce or error: not a sample */
			}
			if (b) {
				st[i].hi++;
				any_down = 1;
			} else {
				st[i].lo++;
			}
			if (b != st[i].last) {
				if (b) {
					st[i].rise++;
				} else {
					st[i].fall++;
				}
				st[i].last = b;
				any_change = 1;
			}
		}
		if (any_down != prev_any && ld4_r.port != NULL) {
			led_set(&ld4_r, !any_down);
			led_set(&ld4_g, any_down);
			prev_any = any_down;
		}
		k_sleep(K_MSEC(period_ms));
	}

	if (ld4_r.port != NULL) {
		led_set(&ld4_g, 0);
		led_set(&ld4_r, 0);
		led_set(&ld4_b, 1);
	}

	for (size_t i = 0; i < NSW; i++) {
		printk("PANEL_BTN: sw%u pin=%u init=%d lo=%u hi=%u rise=%u fall=%u changed=%s\n",
		       (unsigned)i, (unsigned)sw[i].pin, st[i].init,
		       st[i].lo, st[i].hi, st[i].rise, st[i].fall,
		       (st[i].rise + st[i].fall) ? "YES" : "NO");
	}
	printk("PANEL_BTN: pressed_any=%s\n", any_change ? "YES" : "NO");
	if (!any_change) {
		printk("PANEL_BTN: NOT A RESULT -- no level changed. Either nobody pressed a\n");
		printk("PANEL_BTN: button, or the path from the pad to the GPIO register is\n");
		printk("PANEL_BTN: broken. This run cannot tell those apart.\n");
	}
	printk("PANEL_BTN: done\n");
	return 0;
}
