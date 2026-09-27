/* SPDX-License-Identifier: Apache-2.0 */
#ifndef OSPI_CAMERA_DMA_H_
#define OSPI_CAMERA_DMA_H_

#include <stdint.h>

/* Register offsets are relative to the capture peripheral. wait() yields for
 * one polling interval, returning nonzero to cancel. No allocation or OS API. */
struct ospi_camera_io {
	uint32_t (*read)(void *ctx, uint32_t offset);
	void (*write)(void *ctx, uint32_t offset, uint32_t value);
	int (*wait)(void *ctx);
	void *ctx;
};

struct ospi_camera_dma_result {
	uint32_t bytes, width, height, status, flags, frames, polls;
	/* An unsuccessful armed transfer requires a SoC reset before reusing
	 * the destination. This RTL has no abort, even when capture is disabled. */
	uint32_t reset_required;
};

enum ospi_camera_dma_error {
	OSPI_CAMERA_DMA_OK = 0,
	OSPI_CAMERA_DMA_ARGUMENT = -1,
	OSPI_CAMERA_DMA_BUSY = -2,
	OSPI_CAMERA_DMA_TIMEOUT = -3,
	OSPI_CAMERA_DMA_BUS_ERROR = -4,
	OSPI_CAMERA_DMA_TRUNCATED = -5,
	OSPI_CAMERA_DMA_GEOMETRY = -6,
};

/* The sensor must already be streaming. The reference DMA has a 32-bit address
 * space and 8-byte beats. addr must name an 8-byte-aligned, coherent, writable
 * DRAM allocation of capacity bytes. capacity must EXCEED the frame size: a
 * transfer reaching the byte limit stops before consuming its EOF marker.
 * Two queued transfers discard an initial partial frame without a software gap.
 * The second overwrites the first. On failure keep this buffer alive until reset.
 * DMA capability must be known from the SoC configuration, not probed via writes.
 */
int ospi_camera_dma_capture(const struct ospi_camera_io *io, uint32_t addr,
			    uint32_t capacity, uint32_t max_polls,
			    struct ospi_camera_dma_result *out);

#endif
