/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Compiles Zephyr's drivers/i2c/i2c_sifive.c UNMODIFIED (the script copies it next to this
 * file as i2c_sifive_under_test.c and records its md5) against host stubs, and exposes the
 * two API calls plus the two message shapes the SSD1306 driver and the sensor drivers use.
 */
#include "i2c_sifive_under_test.c"

int stub_log_enabled = 1;

static struct i2c_sifive_cfg glue_cfg;
static const struct device glue_dev = {
	.name = "i2c@10040000",
	.config = &glue_cfg,
	.api = &i2c_sifive_api,
};

int glue_init(uint32_t base, uint32_t f_bus)
{
	glue_cfg.base = base;
	glue_cfg.f_sys = SIFIVE_PERIPHERAL_CLOCK_FREQUENCY;
	glue_cfg.f_bus = f_bus;
	return i2c_sifive_init(&glue_dev);
}

/* i2c_transfer() as Zephyr's inline wrapper does it: STOP forced onto the last message. */
static int transfer(struct i2c_msg *msgs, uint8_t n, uint16_t addr)
{
	msgs[n - 1].flags |= I2C_MSG_STOP;
	return i2c_sifive_api.transfer(&glue_dev, msgs, n, addr);
}

/* i2c_write(): one message. */
int glue_i2c_write(const uint8_t *buf, uint32_t len, uint16_t addr)
{
	struct i2c_msg m = {.buf = (uint8_t *)buf, .len = len, .flags = I2C_MSG_WRITE};

	return transfer(&m, 1, addr);
}

/* i2c_burst_write(): a one-byte message then the payload, exactly as <zephyr/drivers/i2c.h>. */
int glue_i2c_burst_write(uint16_t addr, uint8_t start_addr, const uint8_t *buf, uint32_t num)
{
	struct i2c_msg msg[2];

	msg[0].buf = &start_addr;
	msg[0].len = 1U;
	msg[0].flags = I2C_MSG_WRITE;
	msg[1].buf = (uint8_t *)buf;
	msg[1].len = num;
	msg[1].flags = I2C_MSG_WRITE | I2C_MSG_STOP;
	return transfer(msg, 2, addr);
}

void glue_set_log(int on)
{
	stub_log_enabled = on;
}
