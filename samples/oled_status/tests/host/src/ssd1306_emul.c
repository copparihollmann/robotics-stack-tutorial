/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Zephyr I2C emulator for the SSD1306 nodes, backed by model/ssd1306_model.c.
 *
 * The emulated controller hands the target a whole i2c_msg array. What that array looks
 * like ON THE WIRE is a property of the controller driver, so the translation into
 * START / byte / STOP events is selectable:
 *
 *   SSD1306_EMUL_WIRE_CONTRACT  the Zephyr I2C API contract: an address phase only at the
 *        start of a transfer, after a STOP, on I2C_MSG_RESTART, or on a change of direction
 *        (the rule i2c_bitbang.c and i2c_dw.c implement). i2c_burst_write() is one transfer.
 *
 *   SSD1306_EMUL_WIRE_STOCK_SIFIVE  a transcription of the stock i2c_sifive.c: START +
 *        address for every message, STOP only after the last byte of a message flagged
 *        I2C_MSG_STOP, no STOP after a NACK. This is a MODEL OF A READING of that driver,
 *        used as the negative control for the golden comparison; whether the real driver
 *        on the real TLI2C does this is settled by the RTL test (OLED_SSD1306.md P2), not
 *        here.
 */
#define DT_DRV_COMPAT solomon_ssd1306fb

#include <errno.h>
#include <zephyr/device.h>
#include <zephyr/drivers/emul.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/i2c_emul.h>

#include "ssd1306_emul.h"

struct ssd1306_emul_data {
	struct ssd1306_model m;
	bool bus_busy; /* a START has been sent without a STOP (stock mode) */
};

static enum ssd1306_emul_wire wire_mode = SSD1306_EMUL_WIRE_CONTRACT;

void ssd1306_emul_set_wire(enum ssd1306_emul_wire w)
{
	wire_mode = w;
}

static int xfer_contract(struct ssd1306_emul_data *d, struct i2c_msg *msgs, int n, int addr)
{
	struct ssd1306_model *m = &d->m;
	bool in_xfer = false;
	int prev_rw = -1;

	for (int i = 0; i < n; i++) {
		int rw = msgs[i].flags & I2C_MSG_READ;

		if (!in_xfer || (msgs[i].flags & I2C_MSG_RESTART) || rw != prev_rw) {
			ssd1306_model_start(m, in_xfer);
			if (!ssd1306_model_byte(m, (uint8_t)((addr << 1) | rw))) {
				ssd1306_model_stop(m);
				return -EIO;
			}
		}
		if (rw) {
			ssd1306_model_stop(m);
			return -EIO; /* the SSD1306 has no read path */
		}
		for (uint32_t j = 0; j < msgs[i].len; j++) {
			if (!ssd1306_model_byte(m, msgs[i].buf[j])) {
				ssd1306_model_stop(m);
				return -EIO;
			}
		}
		if (msgs[i].flags & I2C_MSG_STOP) {
			ssd1306_model_stop(m);
			in_xfer = false;
		} else {
			in_xfer = true;
		}
		prev_rw = rw;
	}
	return 0;
}

static int xfer_stock_sifive(struct ssd1306_emul_data *d, struct i2c_msg *msgs, int n, int addr)
{
	struct ssd1306_model *m = &d->m;

	for (int i = 0; i < n; i++) {
		int rw = msgs[i].flags & I2C_MSG_READ;

		ssd1306_model_start(m, d->bus_busy);
		d->bus_busy = true;
		if (!ssd1306_model_byte(m, (uint8_t)((addr << 1) | rw))) {
			return -EIO; /* i2c_sifive_send_addr: return without STOP */
		}
		if (rw) {
			return -EIO;
		}
		for (uint32_t j = 0; j < msgs[i].len; j++) {
			bool ack = ssd1306_model_byte(m, msgs[i].buf[j]);

			if (j == msgs[i].len - 1 && (msgs[i].flags & I2C_MSG_STOP)) {
				ssd1306_model_stop(m);
				d->bus_busy = false;
			}
			if (!ack) {
				return -EIO;
			}
		}
	}
	return 0;
}

static int ssd1306_emul_transfer(const struct emul *target, struct i2c_msg *msgs, int num_msgs,
				 int addr)
{
	struct ssd1306_emul_data *d = target->data;

	if (wire_mode == SSD1306_EMUL_WIRE_STOCK_SIFIVE) {
		return xfer_stock_sifive(d, msgs, num_msgs, addr);
	}
	return xfer_contract(d, msgs, num_msgs, addr);
}

static const struct i2c_emul_api ssd1306_emul_bus_api = {
	.transfer = ssd1306_emul_transfer,
};

static int ssd1306_emul_init(const struct emul *target, const struct device *parent)
{
	struct ssd1306_emul_data *d = target->data;
	uint16_t addr = target->bus.i2c->addr;
	bool present = (addr == 0x3c) && !IS_ENABLED(CONFIG_OLED_TEST_ABSENT);

	ARG_UNUSED(parent);
	ssd1306_model_init(&d->m, addr, present);
	return 0;
}

#define SSD1306_EMUL(n)                                                                    \
	static struct ssd1306_emul_data ssd1306_emul_data_##n;                              \
	EMUL_DT_INST_DEFINE(n, ssd1306_emul_init, &ssd1306_emul_data_##n, NULL,             \
			    &ssd1306_emul_bus_api, NULL)

DT_INST_FOREACH_STATUS_OKAY(SSD1306_EMUL)

struct ssd1306_model *ssd1306_emul_model(uint16_t addr)
{
#define SSD1306_EMUL_MATCH(n)                                                              \
	if (DT_INST_REG_ADDR(n) == addr) {                                                  \
		return &ssd1306_emul_data_##n.m;                                            \
	}
	DT_INST_FOREACH_STATUS_OKAY(SSD1306_EMUL_MATCH)
	return NULL;
}
