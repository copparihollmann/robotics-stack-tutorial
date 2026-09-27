/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * One HM01B0 frame, captured into a caller-supplied buffer.
 *
 * The sequence -- MCLK before SCCB, streaming before PCLK is meaningful, arm on
 * a frame boundary, stop the sensor the moment PIXTARGET is satisfied -- is
 * board knowledge, and every step of it is a way a capture can look broken
 * while the hardware is fine. It lives here so a workload that wants a picture
 * does not have to re-derive it.
 *
 * This reports rather than prints: the caller owns its own output format, and
 * bootup_check's one-line-per-stage table and camera_photo's nine stages of
 * evidence want different things from the same capture.
 *
 * NOTE ON DUPLICATION: workloads/camera_photo predates this module and still
 * carries its own copy of the sequence. It is the reference implementation the
 * camera docs quote verbatim, so it was left alone rather than refactored
 * mid-bench-session; migrating it here is the outstanding follow-up, and until
 * that happens a fix to the sequence belongs in both places.
 */

#ifndef OSPI_CAMERA_CAMERA_H_
#define OSPI_CAMERA_CAMERA_H_

#include <stdint.h>
#include <stdbool.h>

struct device;

/* Supplied by the Zephyr device binding; calls must be serialized by the caller. */
struct ospi_camera_context {
	uintptr_t base;
	const struct device *sensor_bus;
	uint32_t mclk_div;
	uint32_t timeout_ms;
	bool reset_required;
};

/* What the capture observed. Populated as far as the sequence got, so a failed
 * capture still says how far it got and what the core saw. */
struct ospi_camera_capture {
	uint16_t model_id;
	uint32_t pclk_before;
	uint32_t pclk_after;
	uint32_t captured;        /* pixels the core counted */
	uint32_t drained;         /* pixels actually read into the buffer */
	uint32_t measured_width;  /* LASTWIDTH -- reshape rows at THIS, not GEOM */
	uint32_t measured_height;
	uint32_t configured_width;
	uint32_t configured_height;
	uint32_t flags;
	uint32_t dma_status;
	uint32_t reset_required;  /* keep destination alive until SoC reset if set */
	uint8_t vmin;
	uint8_t vmax;
	/* Readout mode as the sensor actually reports it, not as configured.
	 * readout_ok is 0 when every read succeeded; a non-zero value means the
	 * four bytes below are meaningless. See the note in hm01b0.h: a colour
	 * part that is binning or subsampling produces a frame with no mosaic,
	 * which looks exactly like a mono part. */
	uint8_t x_odd_inc;
	uint8_t y_odd_inc;
	uint8_t binning_mode;
	uint8_t qvga_win_en;      /* bit 0 only; see hm01b0.h */
	int readout_ok;
	/*
	 * What OSPI_CAMERA_FULL_READOUT did, if it was built in.
	 *   OSPI_CAMERA_PROGRAM_OFF      not compiled in -- the default
	 *   OSPI_CAMERA_PROGRAM_OK       the sequence was written and read back clean
	 *   anything else              the negative errno of the write that failed
	 * Separate from readout_ok because "the sensor would not accept the
	 * configuration" and "the sensor would not tell me its configuration" are
	 * different faults and the second is survivable.
	 */
	int program_ok;
};

#define OSPI_CAMERA_PROGRAM_OFF      1    /* not built in */
#define OSPI_CAMERA_PROGRAM_OK       0
#define OSPI_CAMERA_READOUT_NOT_READ (-1000)  /* capture stopped before the probe */

/*
 * Pixels the capture core can hold in one capture -- the hard ceiling on a
 * frame, and lower than a full frame on at least one shipped shell. A caller
 * that wants "as much of the picture as fits" clamps to whole rows against
 * this rather than hardcoding a height, so a core with a bigger buffer needs
 * no code change.
 */
uint32_t ospi_camera_capacity(const struct ospi_camera_context *ctx);

/*
 * Capture `want` pixels into `dst`. Returns 0 on success, or -1 with *stage and
 * *detail set to static strings naming where it stopped and why.
 *
 * Needs a DDR-backed shell: a full frame is ~79 KB and a scratchpad holds 32 KB.
 */
int ospi_camera_capture_frame(struct ospi_camera_context *ctx, uint8_t *dst, uint32_t want,
				    struct ospi_camera_capture *out,
				    const char **stage, const char **detail);

/* Whole-frame DMA for WithOspiCaptureDma SoCs, including 512-beat line buffers.
 * capacity is the size of dst, NOT a pixel target; leave headroom above the
 * expected frame (e.g. 256 KiB for 326x324). dst must be 8-byte aligned, coherent
 * DRAM in the DMA master's 32-bit address space. Returns measured geometry and
 * bytes in out. A failed armed DMA sets reset_required: keep dst allocated until
 * a SoC reset, and do not start another capture. No runtime DMA autodetection. */
int ospi_camera_capture_dma(struct ospi_camera_context *ctx, uint8_t *dst, uint32_t capacity,
			    struct ospi_camera_capture *out,
			    const char **stage, const char **detail);

#endif /* OSPI_CAMERA_CAMERA_H_ */
