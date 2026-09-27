/* SPDX-License-Identifier: Apache-2.0
 *
 * ospi_camera -- the HM01B0 camera as a Zephyr device.
 *
 * WHAT THIS ADDS TO fpga/pynq-z2/sw/cam/ospi_cam.h, AND WHAT IT DELIBERATELY DOES NOT.
 *
 * ospi_cam.h is the register map and the measured register sequences, and it is written to
 * run on two hosts: samples/cam_rtl_sim drives it on the Chipyard TestHarness in Verilator
 * against a model sensor, and Zephyr drives it on the board.  That is why its functions take
 * a raw `uintptr_t base` and two I2C callbacks -- it cannot depend on Zephyr, because half
 * its callers are not Zephyr.  Nothing here changes that file.
 *
 * This header is the Zephyr half.  It binds `ucbbar,ospi-hm01b0` with DEVICE_DT_INST_DEFINE,
 * so the three things an application used to have to know for itself now come out of the
 * devicetree:
 *
 *   the register base      from the node's `reg`, not a #define of 0x10080000
 *   the sensor's I2C bus   from the node's `sensor-i2c` phandle, through DEVICE_DT_GET --
 *                          the reason that phandle is in the node at all
 *   the frame buffer depth from `frame-buffer-depth`
 *
 * and an application gets a `const struct device *` like it does for every other peripheral
 * on this board:
 *
 *     const struct device *cam = DEVICE_DT_GET(DT_ALIAS(camera0));
 *     struct ospi_camera_frame f;
 *
 *     if (!device_is_ready(cam)) { ... }
 *     ospi_camera_stream(cam, true, NULL);
 *     ospi_camera_capture(cam, buf, sizeof buf, &f);
 *
 * WHAT IS NOT HERE: Zephyr's video subsystem API (include/zephyr/drivers/video.h).  That API
 * is built around a buffer queue -- video_enqueue()/video_dequeue() hand buffers to a driver
 * that fills them as frames arrive -- and around video_set_format(), which asks a driver to
 * accept a pixel format and a frame size.  Neither fits this hardware.  The capture core's
 * frame buffer is 512 BEATS, one line rather than one frame, so a transfer has to be armed
 * and draining before a frame starts and there is nothing to queue behind it; and the core
 * does not choose a geometry, it reports the one the sensor sent (GEOM only feeds a sticky
 * error flag, it never truncates a transfer).  An application here asks "what did the sensor
 * just send", which is what ospi_camera_capture() answers.
 *
 * ADDRESSES ARE PHYSICAL AND ALSO POINTERS.  Zephyr runs in M-mode with no MMU on this SoC,
 * so `buf` is passed to the DMA as it stands.  It must be 8-byte aligned (the master issues
 * 8-byte Puts) and in ExtMem, 0x8000_0000-0x8FFF_FFFF.
 */
#ifndef OSPI_CAMERA_H
#define OSPI_CAMERA_H

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ospi_cam.h"   /* the register map, struct ospi_regs, struct ospi_frame_result */

#ifdef __cplusplus
extern "C" {
#endif

/* What one capture produced.  This is struct ospi_frame_result with the one derived bit the
 * callers all recompute spelled out: saw_eof.  A transfer that ends on an EOF marker sent a
 * whole frame; one that ends on the length cap did not, and the two produce the same byte
 * count and different pictures, so nothing here is complete without it. */
struct ospi_camera_frame {
	uint32_t bytes;        /* DMA_BYTES: how many bytes the transfer wrote */
	uint32_t width;        /* LASTWIDTH -- 9 bits in the RTL, so this is modulo 512 */
	uint32_t height;       /* LASTHEIGHT, likewise */
	uint32_t framecnt;
	uint32_t dma_status;
	uint32_t flags;
	uint32_t attempts;
	uint32_t polls;
	bool saw_eof;
};

/* The capture core's own diagnostic counters, which are the only way to tell "the sensor is
 * streaming" from "the sensor answered on I2C and sends no pixels".  They count on the PCLK
 * domain and never reset, so a reader takes two samples and subtracts. */
struct ospi_camera_counters {
	uint32_t pclk, fvld, lvld, capcount, lastpix, flags;
};

/* A sensor register write and the read that checks it, reported separately: a write can be
 * ACKed and then not take -- see ospi_camera_sensor_set(). */
struct ospi_camera_sensor_write {
	int write_rc;
	int read_rc;
	uint8_t readback;
};

struct ospi_camera_driver_api {
	int (*capture)(const struct device *dev, uint8_t *buf, size_t len, uint32_t max_polls,
		       struct ospi_camera_frame *out);
	int (*capture_geometry)(const struct device *dev, uint8_t *buf, size_t len,
				uint16_t width, uint16_t height, uint32_t max_polls,
				struct ospi_camera_frame *out);
	int (*stream)(const struct device *dev, bool on, uint8_t *mode_readback);
	int (*sensor_id)(const struct device *dev, uint16_t *id);
	int (*sensor_read)(const struct device *dev, uint16_t reg, uint8_t *val);
	int (*sensor_write)(const struct device *dev, uint16_t reg, uint8_t val);
	int (*sensor_set)(const struct device *dev, uint16_t reg, uint8_t val,
			  struct ospi_camera_sensor_write *res);
	int (*set_mclk_div)(const struct device *dev, uint8_t div, uint8_t *readback,
			    uint32_t *hz);
	int (*read_regs)(const struct device *dev, struct ospi_regs *regs);
	int (*counters)(const struct device *dev, struct ospi_camera_counters *c);
	int (*flush_to_dram)(const struct device *dev, uint64_t *acc);
};

/* ---- one whole frame, with no expectation about its size ----------------------------
 *
 * Arms the DMA, enables capture, and returns when a transfer has ended.  The transfer is
 * bounded by `len`: the hardware compares bytes written against DMA_LEN, so it cannot leave
 * the buffer whatever the sensor does.  `out->bytes` is then the sensor's own frame size,
 * measured, and `out->saw_eof` says whether the transfer ended at a frame boundary or on the
 * cap.
 *
 * Returns 0 when a transfer ended -- look at out->bytes and out->saw_eof to see how it
 * ended; -1 on timeout (and the DMA stays BUSY: this RTL has no abort, only a SoC reset or
 * more sensor data ends a transfer); -2 when the transfer reported a DENIED or CORRUPT Put;
 * -4 on bad arguments (buf not 8-byte aligned, or len under 8).
 *
 * Preconditions: the sensor is streaming (ospi_camera_stream(dev, true, NULL)), and `buf` is
 * 8-byte aligned and in ExtMem.
 */
static inline int ospi_camera_capture_polls(const struct device *dev, uint8_t *buf, size_t len,
					    uint32_t max_polls, struct ospi_camera_frame *out)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->capture(dev, buf, len, max_polls, out);
}

static inline int ospi_camera_capture(const struct device *dev, uint8_t *buf, size_t len,
				      struct ospi_camera_frame *out)
{
	return ospi_camera_capture_polls(dev, buf, len, CONFIG_OSPI_HM01B0_MAX_POLLS, out);
}

/* The same transfer, but asserting a geometry: GEOM is programmed, and the capture is retried
 * up to three times and then reported as -3 unless the byte count and the core's own measured
 * width and height all match what was asked for and the transfer ended on an EOF.  Use this
 * when the frame feeds something with a fixed input shape; use ospi_camera_capture() when the
 * question is what the sensor sends.  -4 if len is under width * height. */
static inline int ospi_camera_capture_geometry(const struct device *dev, uint8_t *buf, size_t len,
					       uint16_t width, uint16_t height, uint32_t max_polls,
					       struct ospi_camera_frame *out)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->capture_geometry(dev, buf, len, width, height, max_polls, out);
}

/* MODE_SELECT: 1 streaming, 0 standby.  `mode_readback` is optional and is the register read
 * back afterwards, because the part can ACK a mode change and stay where it was.  The pixel
 * clock does not start on the same cycle; a caller that measures it should sleep first. */
static inline int ospi_camera_stream(const struct device *dev, bool on, uint8_t *mode_readback)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->stream(dev, on, mode_readback);
}

/* MODEL_ID, and the cheapest test of whether the shield is on the board at all: with no
 * shield, address 0x24 NACKs and this returns -EIO. */
static inline int ospi_camera_sensor_id(const struct device *dev, uint16_t *id)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->sensor_id(dev, id);
}

static inline int ospi_camera_sensor_read(const struct device *dev, uint16_t reg, uint8_t *val)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->sensor_read(dev, reg, val);
}

/* A bare write, with no grouped-parameter-hold dance and no read back.  For registers that
 * do not affect readout (MODE_SELECT, GRP_HOLD itself); for the rest use sensor_set(). */
static inline int ospi_camera_sensor_write(const struct device *dev, uint16_t reg, uint8_t val)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->sensor_write(dev, reg, val);
}

/* A write that actually takes effect, and then says what came back.
 *
 * The HM01B0 buffers writes to readout-affecting registers while GRP_HOLD (0x0104) is
 * engaged and applies them when it is released.  This part is found with the hold ENGAGED
 * after power-on -- read back as 0x01 on the first board that ever ran this code -- so a
 * write to gain or orientation is ACKed, changes nothing, and is then applied at some
 * arbitrary later moment by whoever next releases the hold.  So: hold, write, release, read
 * back.  `res` reports the write and the read separately because a register that is ACKed
 * and ignored looks exactly like one that took.
 *
 * Returns res->write_rc if that failed, else res->read_rc.
 */
static inline int ospi_camera_sensor_set(const struct device *dev, uint16_t reg, uint8_t val,
					 struct ospi_camera_sensor_write *res)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->sensor_set(dev, reg, val, res);
}

/* MCLK = SoC clock / (2 * (div + 1)).  `readback` and `hz` are optional.  The SoC clock is
 * taken from CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC rather than written into the driver, so the
 * frequency is right on both boards that carry this camera (34.4828 MHz and 40 MHz). */
static inline int ospi_camera_set_mclk_div(const struct device *dev, uint8_t div,
					   uint8_t *readback, uint32_t *hz)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->set_mclk_div(dev, div, readback, hz);
}

/* Every capture register except DATA, which pops when read. */
static inline int ospi_camera_read_regs(const struct device *dev, struct ospi_regs *regs)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->read_regs(dev, regs);
}

static inline int ospi_camera_counters(const struct device *dev, struct ospi_camera_counters *c)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->counters(dev, c);
}

/* MAKE DRAM AGREE WITH WHAT THE DMA WROTE, before anything outside this SoC reads it.
 *
 * The capture DMA is a TileLink master on the front bus, so its Puts land in the L2
 * InclusiveCache.  That is what makes both harts see a frame coherently, and exactly why the
 * ARM in the PS does not: it reads physical DRAM from outside that cache, and a line the L2
 * still holds dirty has not reached DRAM.  There is no cache-control node in this SoC's
 * devicetree, so the eviction is done the only way software here can -- read enough other
 * memory to push the dirty lines out.  `acc` is optional and is the sum of what was read,
 * returned only so a caller can keep the compiler from eliding the reads if it ever prints
 * it; the driver's own reads are volatile and happen regardless.
 */
static inline int ospi_camera_flush_to_dram(const struct device *dev, uint64_t *acc)
{
	const struct ospi_camera_driver_api *api =
		(const struct ospi_camera_driver_api *)dev->api;

	return api->flush_to_dram(dev, acc);
}

/* ---- what the devicetree said, for code that still works at register level --------------
 *
 * ospi_camera_reg_base() is here for register-level diagnostics -- samples/cam_capture dumps
 * every register at reset and then deliberately arms a transfer with no pixel clock to show
 * what a hung transfer looks like.  Neither is an operation a driver should offer, and both
 * need the base.  An application that captures frames does not need this.
 */
uintptr_t ospi_camera_reg_base(const struct device *dev);

/* The I2C controller the node's sensor-i2c phandle names.  For code that has to talk to
 * something else on the same bus -- on this board the display is at 0x3c on it. */
const struct device *ospi_camera_sensor_bus(const struct device *dev);

/* The node's frame-buffer-depth, in beats.  512 in these builds, and that is A LINE, NOT A
 * FRAME: it is why a transfer has to be armed before a frame starts. */
uint32_t ospi_camera_frame_buffer_depth(const struct device *dev);

#ifdef __cplusplus
}
#endif

#endif /* OSPI_CAMERA_H */
