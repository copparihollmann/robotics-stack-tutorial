/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Walk the PYNQ-Z1's two RGB LEDs (LD4, LD5) through a sequence a person can check at a
 * glance, and check everything about it that software CAN check.
 *
 * ---------------------------------------------------------------------------------------
 * WHY THIS SAMPLE IS SHAPED LIKE THIS
 *
 * An output pin has no readback. Nothing running on this board can tell you that the LED
 * marked LD4 went red, because nothing on this board can see it. So the checks split in
 * two and the sample is honest about which is which:
 *
 *   WHAT SOFTWARE PROVES.  Every step reads gpio_port_get_raw() back and compares it
 *   against the six-bit pattern it just wrote. That path is: Zephyr -> the sifive GPIO
 *   controller's output_value/output_en registers -> six ChipTop ports -> the FPGA top's
 *   pad model -> back into input_value. A bit vector swapped or truncated anywhere in
 *   that chain is caught here, with nobody looking at the board. (The FPGA top reproduces
 *   sifive's own pad loopback, ival = (oe ? oval : pue) & ie, which is why this sample
 *   asks for GPIO_OUTPUT | GPIO_INPUT: without input_en the controller's input register
 *   reads zero by design and the readback would be vacuously wrong.)
 *
 *   WHAT ONLY THE EYE PROVES.  That bit 2 is the RED die of the LED silkscreened LD4.
 *   The mapping comes from two independent vendor sources that agree (see
 *   fpga/pynq-z2/docs/RGB_LEDS.md section 1) and the ball placement is asserted against
 *   the routed design at build time -- but "N15 is LD4's red cathode" is a fact about a
 *   PCB, and the only instrument for it is a person. Hence the sequence below, which is
 *   slow, narrated, and deliberately asymmetric at the end.
 *
 * ---------------------------------------------------------------------------------------
 * WHAT A PERSON SHOULD SEE.  Eleven steps of RGB_STEP_MS ms each, RGB_CYCLES times round
 * -- at the defaults, 1000 ms and 2, so 22 seconds -- then it stops and holds the last
 * state forever:
 *
 *      all dark -> LD4 red -> LD4 green -> LD4 blue -> LD4 dark
 *               -> LD5 red -> LD5 green -> LD5 blue -> LD5 dark
 *               -> BOTH on (all six dice)  -> all dark
 *      ... and then PARKED at  LD4 red + LD5 blue,  which stays lit.
 *
 * The park state is asymmetric on purpose. "Both white" looks the same however the six
 * bits are permuted; "one red and one blue, and specifically THAT one red" does not. If
 * the two LEDs are swapped, or red and blue are swapped within a group, the parked board
 * says so at a glance -- and the run still passes every software check, which is the
 * point. (One case survives the parked state: the whole six-bit vector reversed parks as
 * LD4 red + LD5 blue and looks correct. Only the WALK catches that one -- the console
 * would say "LD4 red" while LD5 lit blue. RGB_LEDS.md section 6 has the full table.)
 *
 * "BOTH ON" is written as "both on", not "white". Red, green and blue dice in one package
 * do not have equal efficiency, so all three at equal drive gives a tinted white --
 * usually towards blue-green. Anything pale is right; neutral white is not the claim.
 *
 * BRIGHTNESS IS NOT THIS PROGRAM'S BUSINESS. The PYNQ-Z1 Reference Manual section 12.1
 * asks for no more than a 50% duty cycle on these pins ("a steady logic '1' will result in
 * the LED being illuminated at an uncomfortably bright level"), and the FPGA top honours
 * that in hardware with a fixed 12.5% chopper on all six signals. Writing 1 here gives a
 * comfortably lit LED, not a full-brightness one, and there is no way from software to
 * make it brighter. That is deliberate.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>

/* How long each step is held. 1000 ms is slow enough that a person can read the console
 * line and look up before the LED changes, which is the whole point of the exercise. */
#ifndef RGB_STEP_MS
#define RGB_STEP_MS 1000
#endif
#ifndef RGB_CYCLES
#define RGB_CYCLES 2
#endif

/* One gpio_dt_spec per die, straight out of the board's gpio-leds node. The pin numbers
 * and the active-high polarity live there, not here. */
#define SPEC(nodelabel) GPIO_DT_SPEC_GET(DT_NODELABEL(nodelabel), gpios)

static const struct gpio_dt_spec die[6] = {
	SPEC(ld4_blue),   /* bit 0  L15 */
	SPEC(ld4_green),  /* bit 1  G17 */
	SPEC(ld4_red),    /* bit 2  N15 */
	SPEC(ld5_blue),   /* bit 3  G14 */
	SPEC(ld5_green),  /* bit 4  L14 */
	SPEC(ld5_red),    /* bit 5  M15 */
};
static const char *const die_name[6] = {
	"LD4.blue", "LD4.green", "LD4.red", "LD5.blue", "LD5.green", "LD5.red",
};

/* The sequence, as six-bit masks over the vector above. */
#define B(n) (1U << (n))
#define LD4_BLUE  B(0)
#define LD4_GREEN B(1)
#define LD4_RED   B(2)
#define LD5_BLUE  B(3)
#define LD5_GREEN B(4)
#define LD5_RED   B(5)

struct step {
	uint32_t mask;
	const char *what;
};

static const struct step seq[] = {
	{ 0,                                   "all dark" },
	{ LD4_RED,                             "LD4 red" },
	{ LD4_GREEN,                           "LD4 green" },
	{ LD4_BLUE,                            "LD4 blue" },
	{ 0,                                   "LD4 dark" },
	{ LD5_RED,                             "LD5 red" },
	{ LD5_GREEN,                           "LD5 green" },
	{ LD5_BLUE,                            "LD5 blue" },
	{ 0,                                   "LD5 dark" },
	{ LD4_RED | LD4_GREEN | LD4_BLUE |
	  LD5_RED | LD5_GREEN | LD5_BLUE,      "BOTH on (all six dice)" },
	{ 0,                                   "all dark" },
};
#define NSTEPS ((int)(sizeof(seq) / sizeof(seq[0])))

/* Where the run stops and stays. Asymmetric on purpose -- see the header. */
#define PARK_MASK (LD4_RED | LD5_BLUE)
#define PARK_WHAT "LD4 RED + LD5 BLUE"

static void bits6(uint32_t v, char out[7])
{
	/* Printed MSB-first, i.e. bit 5 leftmost, so it reads like the constants above. */
	for (int i = 0; i < 6; i++) {
		out[i] = (v & (1U << (5 - i))) ? '1' : '0';
	}
	out[6] = '\0';
}

static int checks_ok, checks_bad;

/* Drive the six pins to `mask` and read the controller's input register back.
 * Returns the raw readback, masked to six bits. */
static uint32_t apply_and_read(uint32_t mask)
{
	gpio_port_value_t raw = 0;
	int rc;

	for (int i = 0; i < 6; i++) {
		rc = gpio_pin_set_dt(&die[i], (mask >> i) & 1U);
		if (rc != 0) {
			printk("RGB: FAIL gpio_pin_set_dt(%s) = %d\n", die_name[i], rc);
			checks_bad++;
		}
	}

	rc = gpio_port_get_raw(die[0].port, &raw);
	if (rc != 0) {
		printk("RGB: FAIL gpio_port_get_raw = %d\n", rc);
		checks_bad++;
		return 0xFFFFFFFFU;
	}
	return (uint32_t)raw & 0x3FU;
}

int main(void)
{
	char wb[7], rb[7];
	int64_t t0;

	printk("\nRGB_LED_WALK starting\n");

	if (!gpio_is_ready_dt(&die[0])) {
		printk("RGB: FAIL gpio controller not ready\n");
		printk("RGB: DONE\n");
		return 0;
	}
	printk("RGB: controller %s, 6 pins\n", die[0].port->name);

	/*
	 * GPIO_OUTPUT_INACTIVE starts every die off, so nothing flashes between here and
	 * the first step. GPIO_INPUT is ORed in ON PURPOSE and is not cargo cult: sifive's
	 * pad model gates the input register with input_en, so without it input_value reads
	 * zero regardless of what is being driven and every readback below would be a lie.
	 */
	for (int i = 0; i < 6; i++) {
		int rc = gpio_pin_configure_dt(&die[i],
					       GPIO_OUTPUT_INACTIVE | GPIO_INPUT);
		if (rc != 0) {
			printk("RGB: FAIL gpio_pin_configure_dt(%s) = %d\n", die_name[i], rc);
			checks_bad++;
		}
	}

	/* One deliberate negative check before the show: with everything off, the readback
	 * must be 0. If it comes back all-ones the pad model is inverted somewhere and the
	 * per-step comparisons below would still pass by symmetry on the "both on" step. */
	{
		uint32_t r = apply_and_read(0);

		bits6(r, rb);
		printk("RGB: quiescent readback %s (expect 000000) %s\n",
		       rb, r == 0 ? "ok" : "MISMATCH");
		if (r == 0) {
			checks_ok++;
		} else {
			checks_bad++;
		}
	}

	printk("RGB: WHAT YOU SHOULD SEE -- %d cycles of %d steps at %d ms, %d s in total:\n",
	       RGB_CYCLES, NSTEPS, RGB_STEP_MS, (RGB_CYCLES * NSTEPS * RGB_STEP_MS) / 1000);
	printk("RGB:   LD4 red -> green -> blue -> dark, then LD5 red -> green -> blue -> dark,\n");
	printk("RGB:   then BOTH on together (a pale, probably blue-ish white), then dark.\n");
	printk("RGB:   The bit pattern below is [LD5.r LD5.g LD5.b LD4.r LD4.g LD4.b].\n");
	printk("RGB: IT THEN STOPS AND HOLDS %s. That is the state to check.\n", PARK_WHAT);

	t0 = k_uptime_get();

	for (int c = 0; c < RGB_CYCLES; c++) {
		for (int s = 0; s < NSTEPS; s++) {
			uint32_t want = seq[s].mask;
			uint32_t got = apply_and_read(want);
			int ok = (got == want);

			bits6(want, wb);
			bits6(got, rb);
			printk("RGB: t=%6lld ms  cycle %d step %2d/%2d  %-24s "
			       "drive=%s read=%s %s\n",
			       (long long)(k_uptime_get() - t0), c + 1, s + 1, NSTEPS,
			       seq[s].what, wb, rb, ok ? "ok" : "MISMATCH");
			if (ok) {
				checks_ok++;
			} else {
				checks_bad++;
			}
			k_msleep(RGB_STEP_MS);
		}
	}

	{
		uint32_t got = apply_and_read(PARK_MASK);

		bits6(PARK_MASK, wb);
		bits6(got, rb);
		printk("RGB: PARK  %s  drive=%s read=%s %s\n",
		       PARK_WHAT, wb, rb, got == PARK_MASK ? "ok" : "MISMATCH");
		if (got == PARK_MASK) {
			checks_ok++;
		} else {
			checks_bad++;
		}
	}

	printk("RGB: elapsed %lld ms for %d steps of %d ms (expect %d)\n",
	       (long long)(k_uptime_get() - t0), RGB_CYCLES * NSTEPS, RGB_STEP_MS,
	       RGB_CYCLES * NSTEPS * RGB_STEP_MS);
	printk("RGB: readbacks %d ok, %d mismatched\n", checks_ok, checks_bad);
	printk("RGB: the board is now holding %s -- look at it.\n", PARK_WHAT);
	printk("RGB: DONE\n");
	return 0;
}
