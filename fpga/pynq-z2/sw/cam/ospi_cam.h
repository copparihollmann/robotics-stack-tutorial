/* SPDX-License-Identifier: Apache-2.0
 *
 * ospi_cam -- the HM01B0 capture peripheral (generators/chipyard/.../ospi/OspiChipyard.scala)
 * with its DMA master, and the sensor's I2C control port, for 0x5A5A001E.
 *
 * ONE DRIVER, TWO HOSTS, the sw/roccmoon/mbxr.c arrangement: samples/cam_rtl_sim runs this file
 * on the Chipyard TestHarness in Verilator against a model sensor, and samples/cam_capture runs it
 * under Zephyr on the board.  I2C is reached through two callbacks so each host supplies its own
 * transfer: the RTL test a register-level TLI2C loop that issues exactly the commands Zephyr's
 * i2c_sifive.c issues, the board Zephyr's i2c_write()/i2c_write_read().
 *
 * NO FLOATING POINT, NO ALLOCATION, no OS calls.  Addresses are physical; Zephyr runs in M-mode
 * without an MMU, so they are also the pointers.
 *
 * Register map: OspiChipyard.scala's header comment, copied below as offsets.
 */
#ifndef OSPI_CAM_H
#define OSPI_CAM_H

#include <stddef.h>
#include <stdint.h>

#define OSPI_BASE            0x10080000UL
#define TLI2C_BASE           0x10040000UL

/* ---- ospi registers (32-bit, word offsets) ---- */
#define OSPI_CTRL            0x00  /* [0] enable [1] continuous [2] irqEnable; W1P [3] trig [4] clear [5] flush [6] arm */
#define OSPI_GEOM            0x04  /* [15:0] expWidth [31:16] expHeight */
#define OSPI_MCLKDIV         0x08  /* MCLK = sysclk / (2*(div+1)) */
#define OSPI_FIFOCOUNT       0x0c
#define OSPI_FRAMECNT        0x10
#define OSPI_LASTWIDTH       0x14
#define OSPI_LASTHEIGHT      0x18
#define OSPI_FLAGS           0x1c  /* [0] dataValid [1] overflow [2] geomErr [3] sensorInt [4] busy(FVLD) [5] irqPending [6] fbFull */
#define OSPI_DATA            0x20  /* READ POPS -- never read it while DMA is enabled, never in a register dump */
#define OSPI_CAPACITY        0x24
#define OSPI_PIXTARGET       0x28
#define OSPI_CAPCOUNT        0x2c
#define OSPI_PCLKCNT         0x30
#define OSPI_FVLDCNT         0x34
#define OSPI_LVLDCNT         0x38
#define OSPI_LASTPIX         0x3c
#define OSPI_CAPSTAT         0x40
#define OSPI_DMA_ADDR_LO     0x44
#define OSPI_DMA_ADDR_HI     0x48  /* stored, but the master's address is 32 bits: it is ignored */
#define OSPI_DMA_LEN         0x4c  /* 0 = until the EOF marker */
#define OSPI_DMA_CTRL        0x50  /* [0] enable [2] auto; W1P [1] start [3] clear */
#define OSPI_DMA_STATUS      0x54  /* [0] busy [1] done [2] error [3] sawEof [7:4] state */
#define OSPI_DMA_BYTES       0x58

#define OSPI_CTRL_ENABLE     (1u << 0)
#define OSPI_CTRL_CONTINUOUS (1u << 1)
#define OSPI_CTRL_IRQEN      (1u << 2)
#define OSPI_CTRL_TRIG       (1u << 3)
#define OSPI_CTRL_CLEAR      (1u << 4)
#define OSPI_CTRL_FLUSH      (1u << 5)
#define OSPI_CTRL_ARM        (1u << 6)

#define OSPI_FLAG_DATAVALID  (1u << 0)
#define OSPI_FLAG_OVERFLOW   (1u << 1)
#define OSPI_FLAG_GEOMERR    (1u << 2)
#define OSPI_FLAG_SENSORINT  (1u << 3)
#define OSPI_FLAG_BUSY       (1u << 4)
#define OSPI_FLAG_IRQPEND    (1u << 5)
#define OSPI_FLAG_FBFULL     (1u << 6)

#define OSPI_DMA_EN          (1u << 0)
#define OSPI_DMA_START       (1u << 1)
#define OSPI_DMA_AUTO        (1u << 2)
#define OSPI_DMA_CLEAR       (1u << 3)

#define OSPI_DMA_ST_BUSY     (1u << 0)
#define OSPI_DMA_ST_DONE     (1u << 1)
#define OSPI_DMA_ST_ERROR    (1u << 2)
#define OSPI_DMA_ST_SAWEOF   (1u << 3)
#define OSPI_DMA_STATE(s)    (((s) >> 4) & 0xf)   /* 0 idle 1 collect 2 write 3 resp 4 finish */

static inline uint32_t ospi_rd(uintptr_t base, uint32_t off)
{ return *(volatile uint32_t *)(base + off); }
static inline void ospi_wr(uintptr_t base, uint32_t off, uint32_t v)
{ *(volatile uint32_t *)(base + off) = v; }

/* Every register except DATA, which pops. */
struct ospi_regs {
	uint32_t ctrl, geom, mclkdiv, fifocount, framecnt, lastwidth, lastheight, flags, capacity,
		 pixtarget, capcount, pclkcnt, fvldcnt, lvldcnt, lastpix, capstat,
		 dma_addr_lo, dma_addr_hi, dma_len, dma_ctrl, dma_status, dma_bytes;
};
void ospi_read_regs(uintptr_t base, struct ospi_regs *r);

/* ---- the HM01B0 over I2C ---- */
#define HM01B0_I2C_ADDR          0x24
#define HM01B0_REG_MODEL_ID_H    0x0000
#define HM01B0_REG_MODEL_ID_L    0x0001
#define HM01B0_REG_MODE_SELECT   0x0100   /* 0 standby, 1 streaming */
#define HM01B0_MODEL_ID          0x01B0

struct cam_i2c {
	/* START addr/W buf STOP; 0 or a negative errno-style code (a NACK is negative) */
	int (*write)(void *ctx, uint8_t addr7, const uint8_t *buf, uint32_t len);
	/* START addr/W wbuf, repeated START addr/R rbuf STOP */
	int (*write_read)(void *ctx, uint8_t addr7, const uint8_t *wbuf, uint32_t wlen,
			  uint8_t *rbuf, uint32_t rlen);
	void *ctx;
};
int hm01b0_read(const struct cam_i2c *bus, uint16_t reg, uint8_t *val);
int hm01b0_write(const struct cam_i2c *bus, uint16_t reg, uint8_t val);
int hm01b0_model_id(const struct cam_i2c *bus, uint16_t *id);

/* ---- one whole frame into DDR through the DMA ----
 *
 * The frame buffer in this build is LINE-sized (CAPACITY = 512 beats), so the DMA must already
 * be draining when a frame starts, and a transfer ends at the first EOF it pops -- which after
 * enabling capture may be the end of a PARTIAL frame.  So this queues two transfers in hardware
 * before capture is enabled: the second start pulse lands while the first is busy and sets the
 * engine's pendingStart, and the second transfer begins on the very cycle the first finishes, at
 * a frame boundary, with no software latency in between.  The second overwrites the first at
 * the same address, so the buffer ends holding one whole frame.  If geometry or byte count is
 * still wrong (stale beats from an earlier session), the sequence is repeated.
 *
 * Preconditions: the sensor is streaming; `addr` is 8-byte aligned (the master issues 8-byte
 * Puts), inside a writable memory the system bus maps (ExtMem 0x8000_0000-0x8FFF_FFFF on this
 * SoC), and `cap` bytes long.  cap must hold the SENSOR's frame, not the expected one: a transfer
 * runs to the EOF whatever GEOM says.
 *
 * `wait` is called between polls (sleep on the board, nothing in simulation) and may return
 * nonzero to give up.  max_polls bounds each attempt.
 *
 * Returns 0 with a whole frame; -1 timeout (the DMA stays BUSY: this RTL has no abort, only a
 * SoC reset or more sensor data ends a transfer); -2 the transfer reported an error (DENIED or
 * CORRUPT on a Put); -3 geometry or byte count wrong after every attempt; -4 bad arguments.
 */
struct ospi_frame_result {
	uint32_t bytes, dma_status, flags, framecnt, width, height, attempts, polls;
};
int ospi_dma_capture_frame(uintptr_t base, uint32_t addr, uint32_t cap, uint16_t w, uint16_t h,
			   uint32_t max_polls, int (*wait)(void *ctx), void *ctx,
			   struct ospi_frame_result *res);

/* The same transfer with NO expectation about the frame's size: what does this sensor send?
 * DMA_LEN is set to `cap`, so the transfer stops at the end of the buffer whatever the sensor
 * does.  res->bytes is the byte count, DMA_STATUS.sawEof says whether it ended at a frame
 * boundary or on the cap, and res->width/height are the RTL's own measurement (LASTWIDTH is
 * 9 bits wide in the capture core, so a line longer than 511 bytes reads back modulo 512). */
int ospi_dma_capture_raw(uintptr_t base, uint32_t addr, uint32_t cap, uint32_t max_polls,
			 int (*wait)(void *ctx), void *ctx, struct ospi_frame_result *res);

/* Start one transfer of `len` bytes (0 = to EOF) without waiting.  -4 on bad arguments. */
int ospi_dma_start(uintptr_t base, uint32_t addr, uint32_t len);

#endif /* OSPI_CAM_H */
