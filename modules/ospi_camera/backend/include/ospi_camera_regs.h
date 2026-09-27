/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ospi_camera_regs.h -- register map of the HM01B0 capture peripheral.
 *
 * This header is the software contract, and it is platform-neutral: plain macros,
 * no includes, no bus or OS assumptions. Every offset is relative to the
 * peripheral's base address, which is a property of YOUR SoC (the Chipyard
 * reference integration puts it at 0x10080000 -- see integrations/chipyard/).
 *
 * WHERE THESE NUMBERS COME FROM. Each field below was read off the hardware
 * construction in integrations/chipyard/OspiChipyard.scala -- the `regmap(...)`
 * call and the Cat() that builds each packed word -- NOT off that file's doc
 * comment. The two disagree in one place: the comment lists the CTRL write
 * pulses as bits 3..5 and omits ARM at bit 6, which the regmap does implement
 * and the driver does use. docs/register-map.md is the long-form version.
 */
#ifndef OSPI_CAMERA_REGS_H_
#define OSPI_CAMERA_REGS_H_

/* ---- Offsets ------------------------------------------------------------ */

#define OSPI_CTRL        0x00  /* RW + write-one pulses, see CTRL_* */
#define OSPI_GEOM        0x04  /* RW  expected geometry, see GEOM_* */
#define OSPI_MCLKDIV     0x08  /* RW  MCLK = sysclk / (2 * (MCLKDIV + 1)) */
#define OSPI_FIFOCOUNT   0x0c  /* RO  beats currently in the frame buffer */
#define OSPI_FRAMECNT    0x10  /* RO  frames committed to the frame buffer */
#define OSPI_LASTWIDTH   0x14  /* RO  measured width of the last frame */
#define OSPI_LASTHEIGHT  0x18  /* RO  measured height of the last frame */
#define OSPI_FLAGS       0x1c  /* RO  see FLAG_* */
#define OSPI_DATA        0x20  /* RO  read POPS one beat, see DATA_* */
#define OSPI_CAPACITY    0x24  /* RO  frame-buffer capacity in beats */

/* Bring-up diagnostics. With no logic analyser on the board these counters are
 * the only view of the sensor interface: each one reading zero isolates a
 * different failure (no clock / no frame sync / no line sync). */
#define OSPI_PIXTARGET   0x28  /* RW  pixels per bounded capture; 0 = free-run */
#define OSPI_CAPCOUNT    0x2c  /* RO  pixels in the current/last bounded capture */
#define OSPI_PCLKCNT     0x30  /* RO  PCLK rising edges -- 0 means no camera clock */
#define OSPI_FVLDCNT     0x34  /* RO  FVLD rising edges -- 0 means no frame sync */
#define OSPI_LVLDCNT     0x38  /* RO  LVLD rising edges -- 0 means no line sync */
#define OSPI_LASTPIX     0x3c  /* RO  [7:0] most recent pixel presented */
#define OSPI_CAPSTAT     0x40  /* RO  see CAPSTAT_* */

/* DMA block. Control registers also exist without enableDma but status remains
 * zero and writes cannot start a transfer. Select DMA from the SoC configuration. */
#define OSPI_DMA_ADDR_LO 0x44  /* RW  target address [31:0] */
#define OSPI_DMA_ADDR_HI 0x48  /* RW  target address [63:32] */
#define OSPI_DMA_LEN     0x4c  /* RW  byte cap per transfer; 0 = until EOF */
#define OSPI_DMA_CTRL    0x50  /* RW + write-one pulses, see DMA_CTRL_* */
#define OSPI_DMA_STATUS  0x54  /* RO  see DMA_STATUS_* */
#define OSPI_DMA_BYTES   0x58  /* RO  bytes written by the current/last transfer */

/* ---- CTRL (0x00) ---------------------------------------------------------- */

/* Level bits: they hold what you write. */
#define OSPI_CTRL_ENABLE      (1u << 0)
#define OSPI_CTRL_CONTINUOUS  (1u << 1)
#define OSPI_CTRL_IRQ_ENABLE  (1u << 2)

/* Write-one PULSES: writing 1 fires once, and reads back 0. Because CTRL mixes
 * both kinds, every write has to carry the level bits you want to KEEP -- write
 * `OSPI_CTRL_ENABLE | OSPI_CTRL_ARM`, never `OSPI_CTRL_ARM` alone, or the same
 * write that arms a capture also disables the core. */
#define OSPI_CTRL_TRIGGER     (1u << 3)  /* pulse TRIG (snapshot mode only) */
#define OSPI_CTRL_CLEAR       (1u << 4)  /* clear sticky status and IRQ */
#define OSPI_CTRL_FLUSH       (1u << 5)  /* discard the frame buffer */
#define OSPI_CTRL_ARM         (1u << 6)  /* start a bounded capture of PIXTARGET px */

/* ---- GEOM (0x04) ---------------------------------------------------------- */

/* Only 9 bits of each half decode (log2Ceil(324 + 1) = 9), so the usable range
 * is 0..511 per axis even though the fields are nominally 16 bits wide. Reset
 * value is the QVGA window, 324 x 244. GEOM is EXPECTED geometry: a mismatch
 * sets FLAG_GEOM_ERR. It does not select a readout window -- the sensor does
 * that over I2C, and the core measures whatever arrives. */
#define OSPI_GEOM_WIDTH_SHIFT   0
#define OSPI_GEOM_HEIGHT_SHIFT  16
#define OSPI_GEOM_FIELD_MASK    0x1ffu
#define OSPI_GEOM_VALUE(w, h) \
	((((unsigned)(w) & OSPI_GEOM_FIELD_MASK) << OSPI_GEOM_WIDTH_SHIFT) | \
	 (((unsigned)(h) & OSPI_GEOM_FIELD_MASK) << OSPI_GEOM_HEIGHT_SHIFT))
#define OSPI_GEOM_RESET         0x00f40144u  /* OSPI_GEOM_VALUE(324, 244) */

/* ---- FLAGS (0x1c) --------------------------------------------------------- */

#define OSPI_FLAG_DATA_VALID  (1u << 0)  /* DATA would return a beat */
#define OSPI_FLAG_OVERFLOW    (1u << 1)  /* sticky: the CDC FIFO dropped a beat */
#define OSPI_FLAG_GEOM_ERR    (1u << 2)  /* sticky: last frame != GEOM */
#define OSPI_FLAG_SENSOR_INT  (1u << 3)  /* sensor INT pin, synchronised */
#define OSPI_FLAG_BUSY        (1u << 4)  /* FVLD high: a frame is in flight */
#define OSPI_FLAG_IRQ_PENDING (1u << 5)
#define OSPI_FLAG_FB_FULL     (1u << 6)  /* frame buffer cannot accept a beat */

/* ---- DATA (0x20) ---------------------------------------------------------- */

/* A read POPS one beat and never stalls the bus. An empty buffer returns 0, so
 * bit 31 is what tells a real 0x00 pixel from "nothing there". EOF beats are
 * in-band frame markers, not pixels: skip them when filling an image. */
#define OSPI_DATA_VALID       (1u << 31)
#define OSPI_DATA_EOF         (1u << 10)
#define OSPI_DATA_EOL         (1u << 9)
#define OSPI_DATA_SOF         (1u << 8)
#define OSPI_DATA_PIXEL_MASK  0xffu

/* ---- CAPSTAT (0x40) ------------------------------------------------------- */

#define OSPI_CAPSTAT_ARMED    (1u << 0)
#define OSPI_CAPSTAT_DONE     (1u << 1)

/* ---- DMA_CTRL (0x50) / DMA_STATUS (0x54) ---------------------------------- */

#define OSPI_DMA_CTRL_ENABLE  (1u << 0)  /* level: route the drain to DMA and
                                           * INHIBIT MMIO DATA pops */
#define OSPI_DMA_CTRL_START   (1u << 1)  /* pulse: begin a transfer now */
#define OSPI_DMA_CTRL_AUTO    (1u << 2)  /* level: start on every completed frame */
#define OSPI_DMA_CTRL_CLEAR   (1u << 3)  /* pulse: clear done/error */

#define OSPI_DMA_STATUS_BUSY     (1u << 0)
#define OSPI_DMA_STATUS_DONE     (1u << 1)
#define OSPI_DMA_STATUS_ERROR    (1u << 2)
#define OSPI_DMA_STATUS_SAW_EOF  (1u << 3)
#define OSPI_DMA_STATUS_STATE(v) (((v) >> 4) & 0xfu)

#endif /* OSPI_CAMERA_REGS_H_ */
