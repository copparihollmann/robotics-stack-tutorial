/* SPDX-License-Identifier: Apache-2.0 */
/*
 * The golden screen. The host test renders it and records the sha256 of the resulting
 * 128x64 image in expected/oled_status.json; the RTL simulation and the board lab draw the
 * same numbers so the SSD1306 model's framebuffer can be compared against that hash.
 * Changing anything here changes the golden: re-run scripts/54_oled_host_tests.sh --update.
 */
#ifndef OLED_GOLDEN_H_
#define OLED_GOLDEN_H_

#include "oled_status.h"

static const struct oled_status oled_golden_status = {
	.soc_magic = 0x5A5A001E,
	.soc_name = "roccmoon",
	.frame = 123456,
	.fps_milli = 29970,
	.label = "person",
	.score_pct = 87,
	.rtf_milli = 4350,
};

#endif /* OLED_GOLDEN_H_ */
