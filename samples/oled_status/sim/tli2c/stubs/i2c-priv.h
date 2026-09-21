/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <zephyr/drivers/i2c.h>
static inline uint32_t i2c_map_dt_bitrate(uint32_t bitrate)
{
	return bitrate == I2C_BITRATE_FAST ? I2C_SPEED_SET(I2C_SPEED_FAST) : I2C_SPEED_SET(I2C_SPEED_STANDARD);
}
