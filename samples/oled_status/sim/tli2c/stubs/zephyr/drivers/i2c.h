/* SPDX-License-Identifier: Apache-2.0 */
/* Host stub: the <zephyr/drivers/i2c.h> definitions i2c_sifive.c uses, values copied from Zephyr 4.2. */
#pragma once
#include <zephyr/device.h>
#define BIT(n) (1UL << (n))
#define I2C_SPEED_STANDARD  (0x1U)
#define I2C_SPEED_FAST      (0x2U)
#define I2C_SPEED_FAST_PLUS (0x3U)
#define I2C_SPEED_HIGH      (0x4U)
#define I2C_SPEED_ULTRA     (0x5U)
#define I2C_SPEED_SHIFT     (1U)
#define I2C_SPEED_SET(speed) (((speed) << I2C_SPEED_SHIFT) & I2C_SPEED_MASK)
#define I2C_SPEED_MASK      (0x7U << I2C_SPEED_SHIFT)
#define I2C_SPEED_GET(cfg)  (((cfg) & I2C_SPEED_MASK) >> I2C_SPEED_SHIFT)
#define I2C_ADDR_10_BITS    BIT(0)
#define I2C_MODE_CONTROLLER BIT(4)
#define I2C_MSG_WRITE   (0U << 0U)
#define I2C_MSG_READ    BIT(0)
#define I2C_MSG_RW_MASK BIT(0)
#define I2C_MSG_STOP    BIT(1)
#define I2C_MSG_RESTART BIT(2)
#define I2C_BITRATE_STANDARD 100000
#define I2C_BITRATE_FAST     400000
struct i2c_msg {
	uint8_t *buf;
	uint32_t len;
	uint8_t flags;
};
struct i2c_driver_api {
	int (*configure)(const struct device *dev, uint32_t dev_config);
	int (*transfer)(const struct device *dev, struct i2c_msg *msgs, uint8_t num_msgs, uint16_t addr);
};
