/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Bit-level I2C target for cycle-based RTL simulation, in front of model/ssd1306_model.c.
 *
 * Call i2c_target_eval() once per simulated clock cycle with the RESOLVED bus levels
 * (wired-AND of every driver and the pull-up); it returns, through scl_low/sda_low, what
 * this target drives for the next cycle. It
 *
 *   - detects START / repeated START / STOP (SDA edges while SCL is high),
 *   - samples a bit on every SCL rising edge and hands whole bytes to the SSD1306 model,
 *   - drives the ACK low from the SCL falling edge after bit 8 to the falling edge after
 *     the ACK clock (only if the model ACKs),
 *   - optionally stretches the clock: holds SCL low for stretch_cycles after the falling
 *     edge that ends bit stretch_bit of data byte stretch_byte (1-based, address = byte 0),
 *   - measures SCL timing, split into within-byte samples (second to ninth rising edge of a
 *     byte: the master's steady bit period, no software gap) and everything else.
 *
 * Pure C99, no simulator headers: the TLI2C testbench calls it directly, the SoC
 * TestHarness calls it through a DPI wrapper.
 */
#ifndef I2C_TARGET_H_
#define I2C_TARGET_H_

#include <stdbool.h>
#include <stdint.h>
#include "ssd1306_model.h"

#define I2C_TARGET_HIST 4096 /* period histogram bins, in cycles */

struct i2c_hist {
	uint64_t n, sum, min, max;
	uint32_t bins[I2C_TARGET_HIST]; /* bins[I2C_TARGET_HIST-1] collects everything above */
};

struct i2c_target {
	struct ssd1306_model *model;

	/* line history */
	int scl, sda;
	bool bus_busy;

	/* bit state */
	int bits;              /* data bits sampled in the current byte */
	uint8_t shreg;
	bool in_ack_clock;     /* between the fall after bit 8 and the fall after the ACK clock */
	bool ack_pending;      /* byte complete, ACK decision made, waiting for the fall */
	bool ack;
	int rises_in_byte;     /* SCL rising edges since START or the last ACK clock */
	long byte_no;          /* bytes since the last START (address = 0) */

	/* drives */
	bool sda_low, scl_low;

	/* clock stretching injection */
	long stretch_byte;     /* <0: never */
	int stretch_bit;
	uint64_t stretch_cycles;
	uint64_t stretch_until;
	bool stretched;

	/* timing, in cycles */
	uint64_t cyc, last_rise, last_fall;
	struct i2c_hist period_in_byte, high_in_byte, low_in_byte, high_all;
	uint64_t n_rises, n_bytes;
	bool glitch;           /* SDA changed while SCL high other than START/STOP (unexpected) */
};

void i2c_target_init(struct i2c_target *t, struct ssd1306_model *m);
void i2c_target_eval(struct i2c_target *t, int scl, int sda);
void i2c_hist_add(struct i2c_hist *h, uint64_t v);
/* "n=.. min=.. max=.. mean=.. mode=..(count)" into buf */
void i2c_hist_str(const struct i2c_hist *h, char *buf, int cap);

#endif /* I2C_TARGET_H_ */
