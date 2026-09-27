/* SPDX-License-Identifier: Apache-2.0
 *
 * ospi_cam -- see ospi_cam.h.  Shared by samples/cam_rtl_sim (Verilator) and samples/cam_capture
 * (Zephyr on the board).
 */
#include "ospi_cam.h"

void ospi_read_regs(uintptr_t base, struct ospi_regs *r)
{
	r->ctrl        = ospi_rd(base, OSPI_CTRL);
	r->geom        = ospi_rd(base, OSPI_GEOM);
	r->mclkdiv     = ospi_rd(base, OSPI_MCLKDIV);
	r->fifocount   = ospi_rd(base, OSPI_FIFOCOUNT);
	r->framecnt    = ospi_rd(base, OSPI_FRAMECNT);
	r->lastwidth   = ospi_rd(base, OSPI_LASTWIDTH);
	r->lastheight  = ospi_rd(base, OSPI_LASTHEIGHT);
	r->flags       = ospi_rd(base, OSPI_FLAGS);
	r->capacity    = ospi_rd(base, OSPI_CAPACITY);
	r->pixtarget   = ospi_rd(base, OSPI_PIXTARGET);
	r->capcount    = ospi_rd(base, OSPI_CAPCOUNT);
	r->pclkcnt     = ospi_rd(base, OSPI_PCLKCNT);
	r->fvldcnt     = ospi_rd(base, OSPI_FVLDCNT);
	r->lvldcnt     = ospi_rd(base, OSPI_LVLDCNT);
	r->lastpix     = ospi_rd(base, OSPI_LASTPIX);
	r->capstat     = ospi_rd(base, OSPI_CAPSTAT);
	r->dma_addr_lo = ospi_rd(base, OSPI_DMA_ADDR_LO);
	r->dma_addr_hi = ospi_rd(base, OSPI_DMA_ADDR_HI);
	r->dma_len     = ospi_rd(base, OSPI_DMA_LEN);
	r->dma_ctrl    = ospi_rd(base, OSPI_DMA_CTRL);
	r->dma_status  = ospi_rd(base, OSPI_DMA_STATUS);
	r->dma_bytes   = ospi_rd(base, OSPI_DMA_BYTES);
}

/* ---- HM01B0: 16-bit register address, 8-bit data ---- */
int hm01b0_read(const struct cam_i2c *bus, uint16_t reg, uint8_t *val)
{
	uint8_t a[2] = { (uint8_t)(reg >> 8), (uint8_t)reg };
	return bus->write_read(bus->ctx, HM01B0_I2C_ADDR, a, 2, val, 1);
}

int hm01b0_write(const struct cam_i2c *bus, uint16_t reg, uint8_t val)
{
	uint8_t b[3] = { (uint8_t)(reg >> 8), (uint8_t)reg, val };
	return bus->write(bus->ctx, HM01B0_I2C_ADDR, b, 3);
}

int hm01b0_model_id(const struct cam_i2c *bus, uint16_t *id)
{
	uint8_t hi = 0, lo = 0;
	int rc = hm01b0_read(bus, HM01B0_REG_MODEL_ID_H, &hi);
	if (rc == 0) {
		rc = hm01b0_read(bus, HM01B0_REG_MODEL_ID_L, &lo);
	}
	*id = (uint16_t)((hi << 8) | lo);
	return rc;
}

/* ---- DMA ---- */
int ospi_dma_start(uintptr_t base, uint32_t addr, uint32_t len)
{
	if (addr & 7u) {
		return -4;
	}
	ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_CLEAR);
	ospi_wr(base, OSPI_DMA_ADDR_LO, addr);
	ospi_wr(base, OSPI_DMA_ADDR_HI, 0);
	ospi_wr(base, OSPI_DMA_LEN, len);
	ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_START);
	return 0;
}

int ospi_dma_capture_frame(uintptr_t base, uint32_t addr, uint32_t cap, uint16_t w, uint16_t h,
			   uint32_t max_polls, int (*wait)(void *ctx), void *ctx,
			   struct ospi_frame_result *res)
{
	uint32_t want = (uint32_t)w * (uint32_t)h;

	*res = (struct ospi_frame_result){ 0 };
	if ((addr & 7u) || w == 0 || h == 0 || cap < want) {
		return -4;
	}
	if (ospi_rd(base, OSPI_DMA_STATUS) & OSPI_DMA_ST_BUSY) {
		return -1;   /* a transfer is still waiting for data; only data or a reset ends it */
	}

	for (uint32_t attempt = 1; attempt <= 3; attempt++) {
		res->attempts = attempt;

		/* capture off, sticky flags cleared, frame buffer flushed; DMA owns the read port */
		ospi_wr(base, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
		ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_CLEAR);
		ospi_wr(base, OSPI_GEOM, ((uint32_t)h << 16) | w);
		ospi_wr(base, OSPI_DMA_ADDR_LO, addr);
		ospi_wr(base, OSPI_DMA_ADDR_HI, 0);

		/* DMA_LEN IS THE ONLY THING THAT BOUNDS THIS TRANSFER.  It used to be 0 ("run to
		 * the EOF marker"), and a sensor whose frame is larger than w*h then writes past
		 * the caller's buffer -- on 0x5A5A001E's Zephyr image the first 16 bytes past a
		 * 324x324 buffer land on printk's spinlock and ~7 KiB past it on the main thread's
		 * stack, so the guest dies silently in the poll loop below.  `cap` is the caller's
		 * buffer size and the hardware compares (bytesWritten + collectCount) >= DMA_LEN,
		 * so the transfer can never leave the array.  A frame that does not fit ends on
		 * lenReached WITHOUT sawEof and is reported as -3 rather than written. */
		ospi_wr(base, OSPI_DMA_LEN, cap);

		uint32_t fc0 = ospi_rd(base, OSPI_FRAMECNT);
		/* transfer 1 starts; transfer 2 is queued behind it (pendingStart) */
		ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_START);
		ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_START);
		ospi_wr(base, OSPI_CTRL, OSPI_CTRL_ENABLE);

		uint32_t st = 0, fc = fc0, polls = 0;
		for (;;) {
			st = ospi_rd(base, OSPI_DMA_STATUS);
			fc = ospi_rd(base, OSPI_FRAMECNT);
			/* both EOFs counted, and the second transfer finished (done, not busy).
			 * A transfer that ended on the DMA_LEN cap instead of an EOF never bumps
			 * FRAMECNT (the RTL counts frames as EOF markers leave the frame buffer), so
			 * take that as an end too, and let the byte/geometry test below reject it --
			 * otherwise an oversized frame spins here until max_polls on every attempt. */
			if ((st & OSPI_DMA_ST_DONE) && !(st & OSPI_DMA_ST_BUSY) &&
			    (fc >= fc0 + 2u || !(st & OSPI_DMA_ST_SAWEOF))) {
				break;
			}
			if (++polls >= max_polls || (wait && wait(ctx))) {
				res->polls += polls;
				res->dma_status = st;
				res->framecnt = fc;
				res->bytes = ospi_rd(base, OSPI_DMA_BYTES);
				res->flags = ospi_rd(base, OSPI_FLAGS);
				return -1;
			}
		}
		res->polls += polls;
		res->dma_status = st;
		res->framecnt = fc;
		res->bytes = ospi_rd(base, OSPI_DMA_BYTES);
		res->flags = ospi_rd(base, OSPI_FLAGS);
		res->width = ospi_rd(base, OSPI_LASTWIDTH);
		res->height = ospi_rd(base, OSPI_LASTHEIGHT);
		if (st & OSPI_DMA_ST_ERROR) {
			return -2;
		}
		/* FLAGS.overflow is reported, not tested: its clear is a one-cycle pulse on the SoC
		 * clock resampled on PCLK (AsyncFifo clearOverflow), so it can stay set from an earlier
		 * session.  A dropped beat shows up here anyway, as a short byte count or a wrong
		 * geometry, because the EOF marker travels in the same FIFO. */
		if (res->bytes == want && res->width == w && res->height == h &&
		    (st & OSPI_DMA_ST_SAWEOF)) {
			/* capture off again: with the DMA idle the line buffer would only fill and
			 * overflow.  CLEAR also acknowledges the DMA-done IRQ latch. */
			ospi_wr(base, OSPI_CTRL, OSPI_CTRL_CLEAR);
			return 0;
		}
	}
	ospi_wr(base, OSPI_CTRL, OSPI_CTRL_CLEAR);
	return -3;
}

/* ---- a whole frame, with no expectation about its size ----
 *
 * ospi_dma_capture_frame() above answers "is the frame the one I asked for"; this answers
 * "what does this sensor actually send".  Same two-start sequence and the same DMA_LEN cap,
 * but no GEOM test: it reports the byte count, the measured geometry and whether the
 * transfer ended on an EOF marker or on the length cap.  GEOM is left where the caller put
 * it, because GEOM only feeds the sticky geomErr flag and never truncates a transfer.
 *
 * Returns 0 when a transfer ended (look at res->bytes and DMA_STATUS.sawEof to see how),
 * -1 on timeout, -2 on a DENIED/CORRUPT Put, -4 on bad arguments.
 */
int ospi_dma_capture_raw(uintptr_t base, uint32_t addr, uint32_t cap, uint32_t max_polls,
			 int (*wait)(void *ctx), void *ctx, struct ospi_frame_result *res)
{
	*res = (struct ospi_frame_result){ 0 };
	if ((addr & 7u) || cap < 8u) {
		return -4;
	}
	if (ospi_rd(base, OSPI_DMA_STATUS) & OSPI_DMA_ST_BUSY) {
		return -1;
	}
	res->attempts = 1;
	ospi_wr(base, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
	ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_CLEAR);
	ospi_wr(base, OSPI_DMA_ADDR_LO, addr);
	ospi_wr(base, OSPI_DMA_ADDR_HI, 0);
	ospi_wr(base, OSPI_DMA_LEN, cap);

	uint32_t fc0 = ospi_rd(base, OSPI_FRAMECNT);
	ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_START);
	ospi_wr(base, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_START);
	ospi_wr(base, OSPI_CTRL, OSPI_CTRL_ENABLE);

	uint32_t st = 0, fc = fc0, polls = 0;
	int rc = 0;
	for (;;) {
		st = ospi_rd(base, OSPI_DMA_STATUS);
		fc = ospi_rd(base, OSPI_FRAMECNT);
		if ((st & OSPI_DMA_ST_DONE) && !(st & OSPI_DMA_ST_BUSY) &&
		    (fc >= fc0 + 2u || !(st & OSPI_DMA_ST_SAWEOF))) {
			break;
		}
		if (++polls >= max_polls || (wait && wait(ctx))) {
			rc = -1;
			break;
		}
	}
	res->polls = polls;
	res->dma_status = st;
	res->framecnt = fc;
	res->bytes = ospi_rd(base, OSPI_DMA_BYTES);
	res->flags = ospi_rd(base, OSPI_FLAGS);
	res->width = ospi_rd(base, OSPI_LASTWIDTH);
	res->height = ospi_rd(base, OSPI_LASTHEIGHT);
	ospi_wr(base, OSPI_CTRL, OSPI_CTRL_CLEAR);
	if (rc == 0 && (st & OSPI_DMA_ST_ERROR)) {
		rc = -2;
	}
	return rc;
}
