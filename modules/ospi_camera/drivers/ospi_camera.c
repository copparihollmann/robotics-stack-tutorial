/* SPDX-License-Identifier: Apache-2.0
 *
 * ospi_camera -- the Zephyr driver for ucbbar,ospi-hm01b0.  See ../include/ospi_camera.h.
 *
 * The photo operation delegates sensor setup and bounded DMA to the embedded ospi-camera
 * backend. The existing register-level diagnostic operations remain available below.
 *
 * WHAT INIT DOES, AND WHAT IT MUST NOT DO.  It checks that the I2C controller the node's
 * sensor-i2c phandle names is ready, and nothing else.  It writes no register.  The bring-up
 * sample reads every capture register before it does anything and asserts they are all at
 * their reset values -- CAPACITY 512, GEOM 324x244, CTRL 0, MCLKDIV 0, DMA idle -- so a
 * driver that "initialised" the peripheral would make that check fail, and it would fail by
 * reporting the driver's own writes as the hardware's reset state, which is worse than
 * failing.  Bringing this peripheral up is a thing an application asks for when it wants a
 * frame, not a thing that happens at boot.
 */
#define DT_DRV_COMPAT ucbbar_ospi_hm01b0

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <errno.h>

#include "ospi_camera.h"

/* 0x0104, grouped parameter hold.  Not in ospi_cam.h because that header names only the two
 * registers the RTL test needs; this is the one the driver needs. */
#define HM01B0_REG_GRP_HOLD 0x0104

struct ospi_camera_config {
	uintptr_t base;
	const struct device *sensor_bus;
	uint32_t frame_buffer_depth;
};

struct ospi_camera_data {
	struct cam_i2c bus;
	struct ospi_camera_context photo;
	struct k_mutex photo_lock;
};

int ospi_camera_take_photo(const struct device *dev, uint8_t *buf, size_t len,
			   struct ospi_camera_capture *out,
			   const char **stage, const char **detail)
{
	if (dev == NULL || out == NULL || stage == NULL || detail == NULL) {
		return -EINVAL;
	}
	*out = (struct ospi_camera_capture){0};
	*stage = "buffer";
	*detail = "expected an aligned buffer in Rocket DRAM";
	uintptr_t addr = (uintptr_t)buf;
	if (addr < 0x80000000UL || addr >= 0x90000000UL || (addr & 7U) ||
	    len < 8 || len > 0x90000000UL - addr) {
		return -EINVAL;
	}
	if (!device_is_ready(dev)) {
		*stage = "device";
		*detail = "camera device not ready";
		return -ENODEV;
	}
	struct ospi_camera_data *data = dev->data;

	k_mutex_lock(&data->photo_lock, K_FOREVER);
	int rc = ospi_camera_capture_dma(&data->photo, buf, (uint32_t)len,
					out, stage, detail);
	k_mutex_unlock(&data->photo_lock);
	return rc;
}

/* ---- the two I2C callbacks ospi_cam.h asks its caller for -------------------------------
 *
 * Moved verbatim from samples/cam_capture's z_write/z_write_read, with the file-static i2c
 * device replaced by the one the devicetree phandle named.  ctx is the camera device, so one
 * copy of these serves every instance.
 */
static int ospi_camera_i2c_write(void *ctx, uint8_t addr, const uint8_t *buf, uint32_t len)
{
	const struct device *dev = ctx;
	const struct ospi_camera_config *cfg = dev->config;

	return i2c_write(cfg->sensor_bus, buf, len, addr);
}

static int ospi_camera_i2c_write_read(void *ctx, uint8_t addr, const uint8_t *w, uint32_t wl,
				      uint8_t *r, uint32_t rl)
{
	const struct device *dev = ctx;
	const struct ospi_camera_config *cfg = dev->config;

	return i2c_write_read(cfg->sensor_bus, addr, w, wl, r, rl);
}

/* ---- the poll callback ospi_cam.c calls between polls of DMA_STATUS --------------------
 * samples/cam_capture's sleep_1ms, unchanged.  Returning nonzero would abandon the poll loop;
 * nothing here does.
 */
static int ospi_camera_sleep_1ms(void *ctx)
{
	ARG_UNUSED(ctx);
	k_msleep(1);
	return 0;
}

static void ospi_camera_fill(struct ospi_camera_frame *out, const struct ospi_frame_result *fr)
{
	out->bytes = fr->bytes;
	out->width = fr->width;
	out->height = fr->height;
	out->framecnt = fr->framecnt;
	out->dma_status = fr->dma_status;
	out->flags = fr->flags;
	out->attempts = fr->attempts;
	out->polls = fr->polls;
	out->saw_eof = !!(fr->dma_status & OSPI_DMA_ST_SAWEOF);
}

static int api_capture(const struct device *dev, uint8_t *buf, size_t len, uint32_t max_polls,
		       struct ospi_camera_frame *out)
{
	const struct ospi_camera_config *cfg = dev->config;
	struct ospi_frame_result fr;
	int rc;

	if (out == NULL || buf == NULL || len > UINT32_MAX) {
		return -4;
	}
	rc = ospi_dma_capture_raw(cfg->base, (uint32_t)(uintptr_t)buf, (uint32_t)len, max_polls,
				  ospi_camera_sleep_1ms, NULL, &fr);
	ospi_camera_fill(out, &fr);
	return rc;
}

static int api_capture_geometry(const struct device *dev, uint8_t *buf, size_t len, uint16_t w,
				uint16_t h, uint32_t max_polls, struct ospi_camera_frame *out)
{
	const struct ospi_camera_config *cfg = dev->config;
	struct ospi_frame_result fr;
	int rc;

	if (out == NULL || buf == NULL || len > UINT32_MAX) {
		return -4;
	}
	rc = ospi_dma_capture_frame(cfg->base, (uint32_t)(uintptr_t)buf, (uint32_t)len, w, h,
				    max_polls, ospi_camera_sleep_1ms, NULL, &fr);
	ospi_camera_fill(out, &fr);
	return rc;
}

static int api_stream(const struct device *dev, bool on, uint8_t *mode_readback)
{
	struct ospi_camera_data *data = dev->data;
	int rc = hm01b0_write(&data->bus, HM01B0_REG_MODE_SELECT, on ? 1 : 0);

	if (mode_readback != NULL) {
		*mode_readback = 0xff;
		int rrc = hm01b0_read(&data->bus, HM01B0_REG_MODE_SELECT, mode_readback);

		if (rc == 0) {
			rc = rrc;
		}
	}
	return rc;
}

static int api_sensor_id(const struct device *dev, uint16_t *id)
{
	struct ospi_camera_data *data = dev->data;

	return hm01b0_model_id(&data->bus, id);
}

static int api_sensor_read(const struct device *dev, uint16_t reg, uint8_t *val)
{
	struct ospi_camera_data *data = dev->data;

	return hm01b0_read(&data->bus, reg, val);
}

static int api_sensor_write(const struct device *dev, uint16_t reg, uint8_t val)
{
	struct ospi_camera_data *data = dev->data;

	return hm01b0_write(&data->bus, reg, val);
}

/* hold, write, release, read back -- samples/cam_capture's hm_set() verbatim, minus its
 * printk, which belongs to the sample and not to a driver.  The reason for every line of it
 * is in the header's comment on ospi_camera_sensor_set(). */
static int api_sensor_set(const struct device *dev, uint16_t reg, uint8_t val,
			  struct ospi_camera_sensor_write *res)
{
	struct ospi_camera_data *data = dev->data;
	struct ospi_camera_sensor_write local;

	if (res == NULL) {
		res = &local;
	}
	int rc = hm01b0_write(&data->bus, HM01B0_REG_GRP_HOLD, 1);

	if (rc == 0) {
		rc = hm01b0_write(&data->bus, reg, val);
	}
	int rel = hm01b0_write(&data->bus, HM01B0_REG_GRP_HOLD, 0);

	if (rc == 0) {
		rc = rel;
	}
	res->write_rc = rc;
	res->readback = 0xff;
	res->read_rc = hm01b0_read(&data->bus, reg, &res->readback);
	return rc ? rc : res->read_rc;
}

static int api_set_mclk_div(const struct device *dev, uint8_t div, uint8_t *readback, uint32_t *hz)
{
	const struct ospi_camera_config *cfg = dev->config;
	struct ospi_camera_data *data = dev->data;

	data->photo.mclk_div = div;
	ospi_wr(cfg->base, OSPI_MCLKDIV, div);
	if (readback != NULL) {
		*readback = (uint8_t)ospi_rd(cfg->base, OSPI_MCLKDIV);
	}
	if (hz != NULL) {
		/* mtime runs at the SoC clock / 1000 on every chipyard board in this tree, so
		 * this follows the board rather than nailing one board's clock into the driver:
		 * 0x5A5A001E is 34.4828 MHz and 0x5A5A0038 is 40 MHz, and an MCLK reported from
		 * the wrong one is wrong by 16 %. */
		uint32_t fclk0 = (uint32_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * 1000u;

		*hz = fclk0 / (2u * ((uint32_t)div + 1u));
	}
	return 0;
}

static int api_read_regs(const struct device *dev, struct ospi_regs *regs)
{
	const struct ospi_camera_config *cfg = dev->config;

	if (regs == NULL) {
		return -EINVAL;
	}
	ospi_read_regs(cfg->base, regs);
	return 0;
}

static int api_counters(const struct device *dev, struct ospi_camera_counters *c)
{
	const struct ospi_camera_config *cfg = dev->config;

	if (c == NULL) {
		return -EINVAL;
	}
	c->pclk = ospi_rd(cfg->base, OSPI_PCLKCNT);
	c->fvld = ospi_rd(cfg->base, OSPI_FVLDCNT);
	c->lvld = ospi_rd(cfg->base, OSPI_LVLDCNT);
	c->capcount = ospi_rd(cfg->base, OSPI_CAPCOUNT);
	c->lastpix = ospi_rd(cfg->base, OSPI_LASTPIX);
	c->flags = ospi_rd(cfg->base, OSPI_FLAGS);
	return 0;
}

/* samples/cam_capture's l2_evict() verbatim, minus its printk.  4 MiB at the top of ExtMem,
 * which Zephyr does not use; the reason is in the header. */
static int api_flush_to_dram(const struct device *dev, uint64_t *acc)
{
	ARG_UNUSED(dev);
	volatile const uint64_t *p = (const uint64_t *)0x88000000UL;
	uint64_t sum = 0;

	__asm__ volatile("fence rw,rw" ::: "memory");
	for (uint32_t i = 0; i < (4u * 1024u * 1024u) / 8u; i += 8) {
		sum += p[i];
	}
	__asm__ volatile("fence rw,rw" ::: "memory");
	if (acc != NULL) {
		*acc = sum;
	}
	return 0;
}

static const struct ospi_camera_driver_api ospi_camera_api = {
	.capture = api_capture,
	.capture_geometry = api_capture_geometry,
	.stream = api_stream,
	.sensor_id = api_sensor_id,
	.sensor_read = api_sensor_read,
	.sensor_write = api_sensor_write,
	.sensor_set = api_sensor_set,
	.set_mclk_div = api_set_mclk_div,
	.read_regs = api_read_regs,
	.counters = api_counters,
	.flush_to_dram = api_flush_to_dram,
};

uintptr_t ospi_camera_reg_base(const struct device *dev)
{
	const struct ospi_camera_config *cfg = dev->config;

	return cfg->base;
}

const struct device *ospi_camera_sensor_bus(const struct device *dev)
{
	const struct ospi_camera_config *cfg = dev->config;

	return cfg->sensor_bus;
}

uint32_t ospi_camera_frame_buffer_depth(const struct device *dev)
{
	const struct ospi_camera_config *cfg = dev->config;

	return cfg->frame_buffer_depth;
}

static int ospi_camera_init(const struct device *dev)
{
	const struct ospi_camera_config *cfg = dev->config;
	struct ospi_camera_data *data = dev->data;

	if (cfg->sensor_bus == NULL || !device_is_ready(cfg->sensor_bus)) {
		/* device_is_ready(camera) is then false, which is the one thing an application
		 * has to check, and it is false for the right reason: with no control port the
		 * sensor cannot be told to stream and there are no pixels to capture. */
		return -ENODEV;
	}
	data->bus.write = ospi_camera_i2c_write;
	data->bus.write_read = ospi_camera_i2c_write_read;
	data->bus.ctx = (void *)dev;
	data->photo = (struct ospi_camera_context){
		.base = cfg->base,
		.sensor_bus = cfg->sensor_bus,
		.mclk_div = 2,
		.timeout_ms = CONFIG_OSPI_HM01B0_MAX_POLLS,
	};
	k_mutex_init(&data->photo_lock);
	return 0;
}

/* One instance per enabled ucbbar,ospi-hm01b0 node.  There is exactly one on each of the
 * three boards that declare it, but nothing here assumes that.
 *
 * The sensor's bus is DEVICE_DT_GET(DT_INST_PHANDLE(inst, sensor_i2c)): the phandle is
 * resolved at build time, so a node pointing at something that is not a device fails to
 * build rather than to run, and there is no address written down anywhere in this file.
 * Ordering is the init priority's job -- CONFIG_OSPI_HM01B0_INIT_PRIORITY is above I2C's --
 * and init checks device_is_ready() on the controller anyway rather than assuming it.
 */
#define OSPI_CAMERA_DEFINE(inst)                                                              \
	BUILD_ASSERT(DT_INST_NODE_HAS_PROP(inst, sensor_i2c),                                 \
		     "ucbbar,ospi-hm01b0 needs sensor-i2c: the sensor's control port is I2C "  \
		     "address 0x24 and the driver has no other way to reach it");              \
	static struct ospi_camera_data ospi_camera_data_##inst;                               \
	static const struct ospi_camera_config ospi_camera_config_##inst = {                  \
		.base = (uintptr_t)DT_INST_REG_ADDR(inst),                                    \
		.sensor_bus = DEVICE_DT_GET(DT_INST_PHANDLE(inst, sensor_i2c)),                \
		.frame_buffer_depth = DT_INST_PROP_OR(inst, frame_buffer_depth, 0),            \
	};                                                                                    \
	DEVICE_DT_INST_DEFINE(inst, ospi_camera_init, NULL, &ospi_camera_data_##inst,          \
			      &ospi_camera_config_##inst, POST_KERNEL,                        \
			      CONFIG_OSPI_HM01B0_INIT_PRIORITY, &ospi_camera_api);

DT_INST_FOREACH_STATUS_OKAY(OSPI_CAMERA_DEFINE)
