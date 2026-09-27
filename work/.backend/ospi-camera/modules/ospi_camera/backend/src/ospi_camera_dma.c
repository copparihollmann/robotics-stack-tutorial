/* SPDX-License-Identifier: Apache-2.0 */
#include "ospi_camera_dma.h"
#include "ospi_camera_regs.h"
#include <stddef.h>

static int pause_poll(const struct ospi_camera_io *io, uint32_t limit,
		      struct ospi_camera_dma_result *out)
{
	if (++out->polls >= limit) {
		return 1;
	}
	return io->wait && io->wait(io->ctx);
}

int ospi_camera_dma_capture(const struct ospi_camera_io *io, uint32_t addr,
			    uint32_t capacity, uint32_t max_polls,
			    struct ospi_camera_dma_result *out)
{
	uint32_t first_frame;
	int rc = OSPI_CAMERA_DMA_OK;

	if (!out) {
		return OSPI_CAMERA_DMA_ARGUMENT;
	}
	*out = (struct ospi_camera_dma_result){0};
	if (!io || !io->read || !io->write || (addr & 7u) || capacity < 8u ||
	    capacity - 1u > UINT32_MAX - addr || !max_polls) {
		return OSPI_CAMERA_DMA_ARGUMENT;
	}
	if (io->read(io->ctx, OSPI_DMA_STATUS) & OSPI_DMA_STATUS_BUSY) {
		out->reset_required = 1;
		return OSPI_CAMERA_DMA_BUSY;
	}

	io->write(io->ctx, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
	io->write(io->ctx, OSPI_PIXTARGET, 0);
	io->write(io->ctx, OSPI_DMA_CTRL, OSPI_DMA_CTRL_ENABLE | OSPI_DMA_CTRL_CLEAR);
	io->write(io->ctx, OSPI_DMA_ADDR_LO, addr);
	io->write(io->ctx, OSPI_DMA_ADDR_HI, 0);
	io->write(io->ctx, OSPI_DMA_LEN, capacity);
	first_frame = io->read(io->ctx, OSPI_FRAMECNT);
	out->reset_required = 1;
	io->write(io->ctx, OSPI_DMA_CTRL, OSPI_DMA_CTRL_ENABLE | OSPI_DMA_CTRL_START);
	/* A read-back ensures the first start has reached COLLECT before the
	 * second pulse sets pendingStart. Capture is disabled and the FIFO empty. */
	while (!(io->read(io->ctx, OSPI_DMA_STATUS) & OSPI_DMA_STATUS_BUSY)) {
		if (pause_poll(io, max_polls, out)) {
			rc = OSPI_CAMERA_DMA_TIMEOUT;
			goto finish;
		}
	}
	io->write(io->ctx, OSPI_DMA_CTRL, OSPI_DMA_CTRL_ENABLE | OSPI_DMA_CTRL_START);
	io->write(io->ctx, OSPI_CTRL, OSPI_CTRL_ENABLE);
	for (;;) {
		out->frames = io->read(io->ctx, OSPI_FRAMECNT) - first_frame;
		out->status = io->read(io->ctx, OSPI_DMA_STATUS);
		if ((out->status & OSPI_DMA_STATUS_DONE) &&
		    !(out->status & OSPI_DMA_STATUS_BUSY)) {
			if (out->status & OSPI_DMA_STATUS_ERROR) {
				rc = OSPI_CAMERA_DMA_BUS_ERROR;
				break;
			}
			if (!(out->status & OSPI_DMA_STATUS_SAW_EOF)) {
				rc = OSPI_CAMERA_DMA_TRUNCATED;
				break;
			}
			if (out->frames >= 2u) {
				out->reset_required = 0;
				break;
			}
		}
		if (pause_poll(io, max_polls, out)) {
			rc = OSPI_CAMERA_DMA_TIMEOUT;
			break;
		}
	}
finish:
	/* Disable acquisition and pending DMA starts. This is NOT an abort of an
	 * active transaction. The caller must retain dst on reset_required. */
	io->write(io->ctx, OSPI_CTRL, OSPI_CTRL_CLEAR);
	io->write(io->ctx, OSPI_DMA_CTRL, 0);
	out->status = io->read(io->ctx, OSPI_DMA_STATUS);
	out->bytes = io->read(io->ctx, OSPI_DMA_BYTES);
	out->width = io->read(io->ctx, OSPI_LASTWIDTH);
	out->height = io->read(io->ctx, OSPI_LASTHEIGHT);
	out->flags = io->read(io->ctx, OSPI_FLAGS);
	if (rc == 0 && (!out->width || !out->height || out->bytes >= capacity ||
			out->bytes != out->width * out->height)) {
		rc = OSPI_CAMERA_DMA_GEOMETRY;
	}
	return rc;
}
