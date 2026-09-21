/* SPDX-License-Identifier: Apache-2.0
 *
 * cam_capture -- the HM01B0 camera on 0x5A5A001E (fpga/pynq-z2/docs/CAMERA_Z1.md), for Lab 66.
 *
 * Every line the lab parses starts with CAM_ and is key=value.  In order:
 *
 *   CAM_BOOT                 build identity
 *   CAM_REGS                 every ospi register except DATA (which pops), at reset
 *   CAM_REGS_CHECK           CAPACITY 512, GEOM 324x244, CTRL/DMA idle
 *   CAM_DIAG                 PCLKCNT/FVLDCNT/LVLDCNT twice, 500 ms apart
 *   CAM_I2C_PROBE            MODEL_ID read at 0x24: rc 0 means a sensor answered, -EIO a NACK
 *   CAM_SHIELD present=0|1   the verdict everything after this branches on
 *
 * Without the shield (present=0):
 *   CAM_NOSHIELD             the diagnostics read 0 and did not move, and 0x24 NACKed
 *   CAM_DMA_TIMEOUT          a DMA transfer armed with no PCLK stays BUSY in COLLECT with 0 bytes.
 *                            It stays that way until SoC reset: this RTL has no abort.
 *   CAM_LEFT_ARMED           what that leaves for whoever uses the board next, and that it is
 *                            nothing: every program load resets the SoC, and loading any
 *                            bitstream clears it outright.
 *
 * With the shield (present=1):
 *   CAM_SENSOR               MODEL_ID (expect 0x01B0)
 *   CAM_MCLK                 MCLKDIV and the frequency it gives
 *   CAM_SREG                 the sensor's own control registers, read back over I2C, BEFORE
 *                            anything writes to it: geometry, sub-sampling, bit width, clocks
 *   CAM_STREAM               MODE_SELECT = 1, then PCLK Hz, frames/s and lines per frame as the
 *                            diagnostic counters measure them over one second of k_uptime
 *   CAM_PROBE                one frame with NO expectation about its size, bounded by DMA_LEN:
 *                            how many bytes the sensor actually sends, and the RTL's own
 *                            LASTWIDTH/LASTHEIGHT
 *   CAM_GEOM                 the geometry this run then uses, and where it came from
 *   CAM_STATS                min/max/mean plus the numbers that separate a picture from a
 *                            stuck bus, a constant fill or uniform noise (see frame_stats)
 *   CAM_MOVE                 the same scene captured with the sensor's IMAGE_ORIENTATION
 *                            flipped, and with its analogue gain changed: evidence that the
 *                            bytes follow the sensor
 *   CAM_FRAME                one whole frame through the DMA: address (SoC and PS physical),
 *                            geometry, bytes, attempts, min/max/mean, and a checksum the lab
 *                            compares with the bytes it reads over /dev/mem
 *   CAM_PREVIEW              a coarse ASCII rendering, so the console alone shows a picture
 *
 *   CAM_RESULT shield=0|1 ok=0|1
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/sys/printk.h>
#include <errno.h>
#include "ospi_cam.h"

#ifndef CAM_MCLKDIV
#define CAM_MCLKDIV 2          /* 34.4828 MHz / 6 = 5.747 MHz: the datasheet's 8-bit QVGA@60fps point is 6 MHz */
#endif
#ifndef CAM_STREAM_MS
#define CAM_STREAM_MS 1000
#endif

#define OSPI      ((uintptr_t)DT_REG_ADDR(DT_ALIAS(camera0)))
/* mtime runs at the SoC clock / 1000 on every chipyard board in this tree, so this follows
 * the board rather than nailing 0x5A5A001E's 34.4828 MHz into the source: 0x5A5A0038 is
 * 40 MHz and its MCLK would otherwise be reported wrong. */
#define FCLK0_HZ  ((uint32_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * 1000u)

static const struct device *const i2c = DEVICE_DT_GET(DT_ALIAS(camera_i2c));

/*
 * THE FRAME BUFFER, AND WHY IT IS THIS BIG AND WHY THERE ARE TWO.
 *
 * The first run with a sensor attached (2026-09-21, garden, out/cam_bringup_garden.log)
 * printed CAM_STREAM and then nothing at all for 40 s.  The DMA was armed with DMA_LEN = 0
 * -- "run to the EOF marker" -- into a 324*324+64 = 105,040-byte array, and the HM01B0 does
 * not send 324*324 bytes from its reset defaults (its own LVLD counter said ~338 lines).
 * From that image's own zephyr_final.map, `frame` sat at 0x8000b780 and the SIXTEEN BYTES
 * AFTER IT are printk's spinlock, with the main thread's stack 7,840 bytes further on.  An
 * oversized frame therefore overwrites the console's lock, and then kernel .bss, while the
 * thread that would report it is asleep in the poll loop.  That is the silence.
 *
 * The fix that matters is in the driver: ospi_dma_capture_frame() and ospi_dma_capture_raw()
 * now program DMA_LEN = cap, so the hardware stops at the end of the array whatever the
 * sensor does.  The size here comes from a bound the sensor cannot exceed rather than from a
 * guess: the capture core takes at most ONE BYTE PER PCLK (CaptureFrontend: pixelValid =
 * fvld && lvld && enable, 8-bit parallel, and CaptureParams requires dataWidth == 8), and
 * CAM_STREAM measures PCLK-per-frame directly (~218,000 on garden at MCLKDIV 2), so 256 KiB
 * holds any frame this part can send here.
 *
 * TWO buffers, because the cheapest strong evidence that the bytes are an image is that they
 * follow the sensor: the second capture is taken with the sensor's IMAGE_ORIENTATION or
 * analogue gain changed, kept beside the first, and both are read back from the PS.
 */
#ifndef CAM_CAP_BYTES
#define CAM_CAP_BYTES (256u * 1024u)
#endif
#define MAX_W 4096u

static uint8_t frame[2][CAM_CAP_BYTES] __aligned(64);

#define ABS_DIFF(a, b) ((uint32_t)((a) > (b) ? (a) - (b) : (b) - (a)))

/* HM01B0 registers this sample touches beyond the two named in ospi_cam.h. */
#define HM_IMAGE_ORIENT  0x0101
#define HM_INTEG_H       0x0202
#define HM_INTEG_L       0x0203
#define HM_ANA_GAIN      0x0205
#define HM_AE_CTRL       0x2100
#define HM_AE_TARGET     0x2101
#define HM_GRP_HOLD      0x0104

static int z_write(void *ctx, uint8_t addr, const uint8_t *buf, uint32_t len)
{
	ARG_UNUSED(ctx);
	return i2c_write(i2c, buf, len, addr);
}
static int z_write_read(void *ctx, uint8_t addr, const uint8_t *w, uint32_t wl, uint8_t *r, uint32_t rl)
{
	ARG_UNUSED(ctx);
	return i2c_write_read(i2c, addr, w, wl, r, rl);
}
static const struct cam_i2c bus = { z_write, z_write_read, NULL };

static int sleep_1ms(void *ctx)
{
	ARG_UNUSED(ctx);
	k_msleep(1);
	return 0;
}

static void print_regs(const char *tag, const struct ospi_regs *r)
{
	printk("%s ctrl=0x%x geom=0x%08x mclkdiv=%u fifocount=%u framecnt=%u lastwidth=%u lastheight=%u "
	       "flags=0x%02x capacity=%u pixtarget=%u capcount=%u pclkcnt=%u fvldcnt=%u lvldcnt=%u "
	       "lastpix=%u capstat=0x%x dma_addr_lo=0x%08x dma_addr_hi=0x%08x dma_len=%u dma_ctrl=0x%x "
	       "dma_status=0x%02x dma_bytes=%u\n", tag,
	       r->ctrl, r->geom, r->mclkdiv, r->fifocount, r->framecnt, r->lastwidth, r->lastheight,
	       r->flags, r->capacity, r->pixtarget, r->capcount, r->pclkcnt, r->fvldcnt, r->lvldcnt,
	       r->lastpix, r->capstat, r->dma_addr_lo, r->dma_addr_hi, r->dma_len, r->dma_ctrl,
	       r->dma_status, r->dma_bytes);
}

static int no_shield(void)
{
	uint32_t addr = (uint32_t)(uintptr_t)frame[0];

	ospi_wr(OSPI, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
	ospi_wr(OSPI, OSPI_GEOM, (244u << 16) | 324u);
	if (ospi_dma_start(OSPI, addr, 0) != 0) {
		printk("CAM_DMA_TIMEOUT ok=0 reason=bad_address addr=0x%08x\n", addr);
		return 0;
	}
	ospi_wr(OSPI, OSPI_CTRL, OSPI_CTRL_ENABLE);
	int64_t t0 = k_uptime_get();
	uint32_t st = 0, polls = 0;
	while (k_uptime_get() - t0 < 1000) {
		st = ospi_rd(OSPI, OSPI_DMA_STATUS);
		if (st & OSPI_DMA_ST_DONE) {
			break;
		}
		polls++;
		k_msleep(10);
	}
	uint32_t bytes = ospi_rd(OSPI, OSPI_DMA_BYTES);
	uint32_t pclk = ospi_rd(OSPI, OSPI_PCLKCNT);
	int ok = (st & OSPI_DMA_ST_BUSY) && OSPI_DMA_STATE(st) == 1 && bytes == 0 && pclk == 0;
	ospi_wr(OSPI, OSPI_CTRL, OSPI_CTRL_CLEAR);       /* capture off; the transfer stays armed */
	printk("CAM_DMA_TIMEOUT ok=%d waited_ms=%lld polls=%u dma_status=0x%02x busy=%u state=%u bytes=%u "
	       "pclkcnt=%u\n", ok, k_uptime_get() - t0, polls, st,
	       st & OSPI_DMA_ST_BUSY, OSPI_DMA_STATE(st), bytes, pclk);
	/* What the next user of this board is left holding, in one line, because this RTL has no
	 * abort: the transfer stays in COLLECT until sensor data arrives or the SoC is reset.  Every
	 * program load resets the SoC (host/run_rocket.py holds reset, writes the image, releases it),
	 * and loading any bitstream clears it outright, so no lab after this one has to do anything. */
	printk("CAM_LEFT_ARMED transfer=busy cleared_by=soc_reset|pl_reload next_lab_action=none "
	       "note=every_program_load_resets_the_soc\n");
	return ok;
}

/* ---------------------------------------------------------------------------------------
 * THE SENSOR'S OWN REGISTERS, read back over I2C before anything writes to it.
 *
 * The geometry this build assumed (GEOM = 324x244) is a reset default written into the RTL,
 * not something the part was asked.  CAM_STREAM's counter ratios can only give the geometry
 * to within one frame of quantisation, so the answer has to come from the sensor.  Names are
 * the HM01B0 datasheet's; registers this build has no name for are dumped anyway, because
 * the point of the table is to record the part's state AS FOUND.
 * ------------------------------------------------------------------------------------ */
static const struct { uint16_t reg; const char *name; } sregs[] = {
	{ 0x0000, "MODEL_ID_H" },   { 0x0001, "MODEL_ID_L" },   { 0x0002, "SILICON_REV" },
	{ 0x0003, "FRAME_COUNT" },  { 0x0004, "PIXEL_ORDER" },
	{ 0x0100, "MODE_SELECT" },  { 0x0101, "IMAGE_ORIENT" }, { 0x0104, "GRP_HOLD" },
	{ 0x0202, "INTEG_H" },      { 0x0203, "INTEG_L" },      { 0x0205, "ANA_GAIN" },
	{ 0x020E, "DIG_GAIN_H" },   { 0x020F, "DIG_GAIN_L" },
	{ 0x0340, "FRAME_LEN_H" },  { 0x0341, "FRAME_LEN_L" },
	{ 0x0342, "LINE_LEN_H" },   { 0x0343, "LINE_LEN_L" },
	{ 0x0383, "X_ODD_INC" },    { 0x0387, "Y_ODD_INC" },    { 0x0390, "BINNING_MODE" },
	{ 0x0601, "TEST_PATTERN" }, { 0x0602, "TEST_DATA" },
	{ 0x1000, "BLC_CFG" },      { 0x1001, "BLC_TGT" },      { 0x1003, "BLC2_TGT" },
	{ 0x1008, "DPC_CTRL" },
	{ 0x2000, "AE_CTRL0" },     { 0x2100, "AE_CTRL" },      { 0x2101, "AE_TARGET" },
	{ 0x2105, "MAX_INTG_H" },   { 0x2106, "MAX_INTG_L" },   { 0x2108, "MAX_AGAIN" },
	{ 0x3044, "R3044" },        { 0x3050, "R3050" },        { 0x3059, "BIT_CONTROL" },
	{ 0x305A, "R305A" },        { 0x305B, "R305B" },        { 0x305C, "R305C" },
	{ 0x3060, "OSC_CLK_DIV" },  { 0x3061, "R3061" },        { 0x3062, "R3062" },
	{ 0x3064, "R3064" },        { 0x3065, "R3065" },        { 0x3070, "R3070" },
	{ 0x3086, "R3086" },
};

static void dump_sensor_regs(const char *tag)
{
	for (unsigned i = 0; i < ARRAY_SIZE(sregs); i += 4) {
		char line[192];
		int n = 0;

		for (unsigned j = i; j < i + 4 && j < ARRAY_SIZE(sregs); j++) {
			uint8_t v = 0;
			int rc = hm01b0_read(&bus, sregs[j].reg, &v);

			if (rc) {
				n += snprintk(line + n, sizeof line - n, " %s@%04x=ERR%d",
					      sregs[j].name, sregs[j].reg, rc);
			} else {
				n += snprintk(line + n, sizeof line - n, " %s@%04x=0x%02x",
					      sregs[j].name, sregs[j].reg, v);
			}
		}
		printk("CAM_SREG %s%s\n", tag, line);
	}
}

/* ---------------------------------------------------------------------------------------
 * IS IT A PICTURE, OR IS IT A BUS?
 *
 * A checksum that matches between the guest and the PS proves the bytes travelled; it says
 * nothing about whether they are an image.  These are integer statistics chosen so that the
 * failure modes that produce a plausible-looking checksum are each excluded by a different
 * number:
 *
 *   zeros / ffs      a bus stuck low or high, or a buffer the DMA never wrote, puts almost
 *                    every byte in one of these two bins
 *   distinct         how many of the 256 codes appear at all.  A constant fill gives 1, a
 *                    few stuck bits give a power of two, a real 8-bit sensor gives most of
 *                    the range it is exposed across
 *   d1h/d2h, d1v/d2v mean |difference| between neighbours at lag 1 and lag 2, along a row
 *                    and down a column, x100.  THIS IS THE ONE THAT DISCRIMINATES.  A BAYER
 *                    MOSAIC of a real scene has d1 > d2 in BOTH directions: neighbours are
 *                    different colour channels, next-but-one neighbours are the same channel
 *                    on an image that is smooth at that scale.  Uniform noise gives
 *                    d1 == d2 == ~8500 (the mean |a-b| of two uniform bytes is 85.3); a
 *                    constant or a stuck bus gives d1 == d2 == 0; a smooth mono image gives
 *                    d1 < d2.  No failure of the bus produces d1 > d2 > 0.
 *   q00..q11         the mean of each of the four Bayer positions (even/odd row x even/odd
 *                    column), x100.  On a COLOUR part with a CFA these are R, Gr, Gb and B
 *                    and they differ; on a mono part they do not.  This is the test of the
 *                    claim that the part on the shield is the colour variant.
 * ------------------------------------------------------------------------------------ */
struct fstats {
	uint32_t mn, mx, zeros, ffs, distinct;
	uint64_t mean_x100, d1h_x100, d2h_x100, d1v_x100, d2v_x100;
	uint32_t q_x100[4];
};

static uint32_t hist[256];

static void frame_stats(const uint8_t *p, uint32_t w, uint32_t h, struct fstats *s)
{
	uint64_t sum = 0, d1h = 0, d2h = 0, d1v = 0, d2v = 0;
	uint64_t qs[4] = { 0, 0, 0, 0 };
	uint32_t qn[4] = { 0, 0, 0, 0 };
	uint32_t n1h = 0, n2h = 0, n1v = 0, n2v = 0;

	for (uint32_t i = 0; i < 256; i++) {
		hist[i] = 0;
	}
	s->mn = 255;
	s->mx = 0;
	for (uint32_t y = 0; y < h; y++) {
		const uint8_t *r = p + (uint32_t)(y * w);

		for (uint32_t x = 0; x < w; x++) {
			uint8_t v = r[x];

			sum += v;
			hist[v]++;
			if (v < s->mn) {
				s->mn = v;
			}
			if (v > s->mx) {
				s->mx = v;
			}
			unsigned q = ((y & 1u) << 1) | (x & 1u);

			qs[q] += v;
			qn[q]++;
			if (x + 1 < w) {
				d1h += ABS_DIFF(r[x], r[x + 1]);
				n1h++;
			}
			if (x + 2 < w) {
				d2h += ABS_DIFF(r[x], r[x + 2]);
				n2h++;
			}
			if (y + 1 < h) {
				d1v += ABS_DIFF(r[x], r[x + w]);
				n1v++;
			}
			if (y + 2 < h) {
				d2v += ABS_DIFF(r[x], r[x + 2 * w]);
				n2v++;
			}
		}
	}
	uint32_t n = w * h;

	s->zeros = hist[0];
	s->ffs = hist[255];
	s->distinct = 0;
	for (uint32_t i = 0; i < 256; i++) {
		if (hist[i]) {
			s->distinct++;
		}
	}
	s->mean_x100 = n ? sum * 100u / n : 0;
	s->d1h_x100 = n1h ? d1h * 100u / n1h : 0;
	s->d2h_x100 = n2h ? d2h * 100u / n2h : 0;
	s->d1v_x100 = n1v ? d1v * 100u / n1v : 0;
	s->d2v_x100 = n2v ? d2v * 100u / n2v : 0;
	for (unsigned q = 0; q < 4; q++) {
		s->q_x100[q] = qn[q] ? (uint32_t)(qs[q] * 100u / qn[q]) : 0;
	}
}

static void print_stats(const char *tag, const struct fstats *s)
{
	printk("CAM_STATS %s min=%u max=%u mean_x100=%llu zeros=%u ffs=%u distinct=%u "
	       "d1h_x100=%llu d2h_x100=%llu d1v_x100=%llu d2v_x100=%llu "
	       "q00_x100=%u q01_x100=%u q10_x100=%u q11_x100=%u\n", tag,
	       s->mn, s->mx, s->mean_x100, s->zeros, s->ffs, s->distinct,
	       s->d1h_x100, s->d2h_x100, s->d1v_x100, s->d2v_x100,
	       s->q_x100[0], s->q_x100[1], s->q_x100[2], s->q_x100[3]);
}

/* mean |a - b| x100, straight, against b rotated 180 degrees, and against b mirrored left to
 * right.  Asking the sensor to flip IMAGE_ORIENTATION and then finding that the new bytes
 * match the old ones ROTATED is evidence no stuck bus, frozen buffer or noise source can
 * imitate: the bytes follow a register write into the sensor's own readout order. */
static void compare_frames(const uint8_t *a, const uint8_t *b, uint32_t w, uint32_t h,
			   uint64_t *straight, uint64_t *rot180, uint64_t *mirror)
{
	uint64_t ds = 0, dr = 0, dm = 0;
	uint32_t n = w * h;

	for (uint32_t y = 0; y < h; y++) {
		for (uint32_t x = 0; x < w; x++) {
			uint32_t i = y * w + x;

			ds += ABS_DIFF(a[i], b[i]);
			dr += ABS_DIFF(a[i], b[n - 1 - i]);
			dm += ABS_DIFF(a[i], b[y * w + (w - 1 - x)]);
		}
	}
	*straight = n ? ds * 100u / n : 0;
	*rot180 = n ? dr * 100u / n : 0;
	*mirror = n ? dm * 100u / n : 0;
}

/*
 * WRITING A REGISTER THAT ACTUALLY TAKES EFFECT.
 *
 * Run 1 on garden wrote IMAGE_ORIENTATION and ANALOG_GAIN, both writes were ACKed (rc = 0),
 * and NEITHER changed the image.  The reason is in that run's own register dump:
 * GRP_HOLD (0x0104) READ BACK AS 0x01.  Grouped parameter hold was engaged -- the part
 * buffers writes to readout-affecting registers and applies them only when the hold is
 * released -- and nothing in this repo had ever written 0x0104, so it had been sitting
 * held since power-on.  So: hold, write, release, then read back and say what came back.
 */
static int hm_set(uint16_t reg, uint8_t val, uint8_t *readback)
{
	int rc = hm01b0_write(&bus, HM_GRP_HOLD, 1);

	if (rc == 0) {
		rc = hm01b0_write(&bus, reg, val);
	}
	int rel = hm01b0_write(&bus, HM_GRP_HOLD, 0);

	if (rc == 0) {
		rc = rel;
	}
	*readback = 0xff;
	int rrc = hm01b0_read(&bus, reg, readback);

	printk("CAM_SET reg=0x%04x wrote=0x%02x rc=%d readback=0x%02x read_rc=%d\n", reg, val, rc,
	       *readback, rrc);
	return rc ? rc : rrc;
}

/*
 * MAKE DDR AGREE WITH WHAT THE DMA WROTE, before the PS reads it over /dev/mem.
 *
 * The capture DMA is a TileLink master on the front bus, so its Puts land in the L2
 * InclusiveCache (CAMERA_Z1.md 1.3) -- which is what makes both harts see the frame
 * coherently, and is exactly why the ARM does NOT: the PS reads physical DRAM from outside
 * that cache, and a line the L2 still holds dirty has not reached DRAM.  Run 1 saw this on
 * the SECOND frame (`matches_guest_sum: false`, 21,906 counts of difference over 105,624
 * bytes) and not on the first, because by then the first had been evicted by three later
 * captures.  There is no cache-control node in this SoC's devicetree, so the eviction is
 * done the only way software here can: read enough other memory to push the dirty lines out.
 * 4 MiB at the top of ExtMem, which Zephyr does not use.
 */
static void l2_evict(void)
{
	volatile const uint64_t *p = (const uint64_t *)0x88000000UL;
	uint64_t acc = 0;

	for (uint32_t i = 0; i < (4u * 1024u * 1024u) / 8u; i += 8) {
		acc += p[i];
	}
	printk("CAM_EVICT read_mib=4 from=0x88000000 acc_low=%u "
	       "why=the_dma_writes_through_the_l2_and_the_ps_reads_dram\n", (uint32_t)acc);
}

/* One frame into buffer `idx`, bounded by DMA_LEN.  Returns the driver's rc. */
static int capture_into(unsigned idx, struct ospi_frame_result *fr)
{
	return ospi_dma_capture_raw(OSPI, (uint32_t)(uintptr_t)frame[idx], sizeof frame[idx],
				    3000, sleep_1ms, NULL, fr);
}

static uint32_t phys_of(unsigned idx)
{
	uint32_t a = (uint32_t)(uintptr_t)frame[idx];

	return 0x10000000u | (a & 0x0fffffffu);
}

static void print_frame_line(const char *tag, unsigned idx, uint32_t w, uint32_t h, int rc,
			     const struct ospi_frame_result *fr, const struct fstats *st)
{
	uint64_t sum = (uint64_t)st->mean_x100 * (uint64_t)(w * h) / 100u;
	uint64_t s2 = 0;

	/* the exact sum, not the one recovered from the rounded mean: the lab compares it with
	 * the bytes it reads back over /dev/mem and a rounding error would break that gate */
	for (uint32_t i = 0; i < w * h; i++) {
		s2 += frame[idx][i];
	}
	(void)sum;
	printk("%s ok=%d rc=%d addr=0x%08x phys=0x%08x width=%u height=%u bytes=%u attempts=%u "
	       "polls=%u dma_status=0x%02x flags=0x%02x framecnt=%u min=%u max=%u mean_x100=%llu "
	       "sum=%llu saweof=%u\n", tag, rc == 0, rc, (uint32_t)(uintptr_t)frame[idx],
	       phys_of(idx), w, h, fr->bytes, fr->attempts, fr->polls, fr->dma_status, fr->flags,
	       fr->framecnt, st->mn, st->mx, st->mean_x100, s2,
	       !!(fr->dma_status & OSPI_DMA_ST_SAWEOF));
}

static int with_shield(void)
{
	uint16_t id = 0;
	int rc = hm01b0_model_id(&bus, &id);
	int ok = (rc == 0 && id == HM01B0_MODEL_ID);

	printk("CAM_SENSOR rc=%d model_id=0x%04x ok=%d\n", rc, id, ok);

	ospi_wr(OSPI, OSPI_MCLKDIV, CAM_MCLKDIV);
	printk("CAM_MCLK mclkdiv=%u readback=%u hz=%u\n", CAM_MCLKDIV, ospi_rd(OSPI, OSPI_MCLKDIV),
	       FCLK0_HZ / (2u * (CAM_MCLKDIV + 1u)));

	dump_sensor_regs("asfound");

	/*
	 * PUT THE SENSOR IN A KNOWN STATE BEFORE MEASURING ANYTHING.
	 *
	 * Run 2 on garden showed why this is not optional.  Grouped parameter hold (0x0104) was
	 * found ENGAGED at 0x01 -- it had never been written by anything in this repo -- so run
	 * 1's writes to AE_CTRL and ANALOG_GAIN sat pending in the sensor, and the FIRST
	 * hold-release run 2 performed applied them, in the middle of run 2's orientation test.
	 * The frame mean jumped 59.96 -> 112.11 and the saturated-pixel count 2,941 -> 31,863
	 * for a reason that had nothing to do with the test being run.  A measurement whose
	 * baseline is "whatever the last session left pending" is not a measurement.
	 *
	 * So: release the hold, turn auto-exposure OFF (it was holding the frame mean at its own
	 * target and would otherwise undo every exposure change below), and set a known gain,
	 * integration time and orientation.  Then everything after this is a controlled change
	 * from a stated starting point.
	 */
	uint8_t rb0 = 0;

	(void)hm01b0_write(&bus, HM_GRP_HOLD, 0);        /* apply anything left pending */
	k_msleep(200);
	(void)hm_set(HM_AE_CTRL, 0x00, &rb0);
	(void)hm_set(HM_ANA_GAIN, 0x00, &rb0);
	(void)hm_set(HM_INTEG_H, 0x00, &rb0);
	(void)hm_set(HM_INTEG_L, 0x78, &rb0);
	(void)hm_set(HM_IMAGE_ORIENT, 0x00, &rb0);
	k_msleep(500);

	rc = hm01b0_write(&bus, HM01B0_REG_MODE_SELECT, 1);
	uint8_t mode = 0xff;
	int rc2 = hm01b0_read(&bus, HM01B0_REG_MODE_SELECT, &mode);

	k_msleep(200);
	uint32_t p0 = ospi_rd(OSPI, OSPI_PCLKCNT), f0 = ospi_rd(OSPI, OSPI_FVLDCNT),
		 l0 = ospi_rd(OSPI, OSPI_LVLDCNT);
	int64_t t0 = k_uptime_get();

	k_msleep(CAM_STREAM_MS);
	uint32_t p1 = ospi_rd(OSPI, OSPI_PCLKCNT), f1 = ospi_rd(OSPI, OSPI_FVLDCNT),
		 l1 = ospi_rd(OSPI, OSPI_LVLDCNT);
	int64_t ms = k_uptime_get() - t0;
	uint32_t df = f1 - f0;
	uint32_t lines_pf = df ? (l1 - l0) / df : 0;
	uint32_t pclk_pf = df ? (p1 - p0) / df : 0;

	printk("CAM_STREAM mode_rc=%d mode_select=%u readback_rc=%d ms=%lld pclk=%u fvld=%u lvld=%u "
	       "pclk_hz=%llu fps_x1000=%llu lines_per_frame=%u pclk_per_frame=%u "
	       "pclk_per_line=%u flags=0x%02x\n",
	       rc, mode, rc2, ms, p1 - p0, df, l1 - l0,
	       ms ? (uint64_t)(p1 - p0) * 1000u / (uint64_t)ms : 0,
	       ms ? (uint64_t)df * 1000000u / (uint64_t)ms : 0,
	       lines_pf, pclk_pf, (l1 - l0) ? (p1 - p0) / (l1 - l0) : 0,
	       ospi_rd(OSPI, OSPI_FLAGS));
	if (p1 == p0) {
		printk("CAM_FRAME ok=0 reason=no_pclk_after_mode_select\n");
		return 0;
	}

	/*
	 * THE PROBE.  No geometry is asserted: DMA_LEN bounds the transfer at the end of the
	 * buffer and the transfer ends at the sensor's own EOF.  DMA_BYTES is then the number of
	 * bytes in one frame, measured, and LASTWIDTH/LASTHEIGHT are the capture core's own
	 * count of bytes in the last line and lines in the frame.  LASTWIDTH and LASTHEIGHT are
	 * NINE BITS WIDE in the RTL (pixCol/rowCnt are UInt(9.W)), so anything above 511 reads
	 * back modulo 512 -- which is why DMA_BYTES, a 32-bit count, is the primary number here.
	 */
	struct ospi_frame_result pr;
	int prc = capture_into(0, &pr);

	printk("CAM_PROBE rc=%d bytes=%u saweof=%u dma_status=0x%02x lastwidth_mod512=%u "
	       "lastheight_mod512=%u framecnt=%u flags=0x%02x capcount=%u lastpix=%u polls=%u "
	       "cap=%u\n", prc, pr.bytes, !!(pr.dma_status & OSPI_DMA_ST_SAWEOF), pr.dma_status,
	       pr.width, pr.height, pr.framecnt, pr.flags, ospi_rd(OSPI, OSPI_CAPCOUNT),
	       ospi_rd(OSPI, OSPI_LASTPIX), pr.polls, (unsigned)sizeof frame[0]);

	/* Rows from the RTL's own LASTHEIGHT when it divides the byte count, else from the LVLD
	 * counter, else give up and say so rather than invent a width. */
	uint32_t bytes = pr.bytes, rows = 0, w = 0, h = 0;
	const char *src = "none";

	if (prc == 0 && (pr.dma_status & OSPI_DMA_ST_SAWEOF) && bytes) {
		if (pr.height && bytes % pr.height == 0 && bytes / pr.height <= MAX_W) {
			rows = pr.height;
			src = "lastheight";
		} else if (lines_pf && bytes % lines_pf == 0 && bytes / lines_pf <= MAX_W) {
			rows = lines_pf;
			src = "lvldcnt";
		}
	}
	if (rows) {
		h = rows;
		w = bytes / rows;
	}
	printk("CAM_GEOM src=%s width=%u height=%u bytes=%u lines_per_frame=%u "
	       "lastheight_mod512=%u lastwidth_mod512=%u width_mod512=%u bytes_per_pclk_x100=%u\n",
	       src, w, h, bytes, lines_pf, pr.height, pr.width, w % 512u,
	       pclk_pf ? (uint32_t)((uint64_t)bytes * 100u / pclk_pf) : 0);
	if (!rows) {
		printk("CAM_FRAME ok=0 rc=%d reason=geometry_not_resolved bytes=%u saweof=%u\n",
		       prc, bytes, !!(pr.dma_status & OSPI_DMA_ST_SAWEOF));
		(void)hm01b0_write(&bus, HM01B0_REG_MODE_SELECT, 0);
		return 0;
	}

	/* The frame the lab checksums and turns into frame.pgm is the one just captured. */
	struct fstats s0;

	frame_stats(frame[0], w, h, &s0);
	print_frame_line("CAM_FRAME", 0, w, h, prc, &pr, &s0);
	print_stats("base", &s0);
	ok = ok && prc == 0 && (pr.dma_status & OSPI_DMA_ST_SAWEOF) && bytes == w * h;

	/*
	 * DO THE BYTES FOLLOW THE SENSOR?  Two controlled changes, in an order that keeps them
	 * from confounding each other, with auto-exposure OFF so nothing quietly compensates.
	 *
	 * (1) ANALOGUE GAIN, swept.  The mean of the captured bytes must rise monotonically with
	 *     a number written over I2C.  A stuck bus, a frozen buffer or a noise source cannot
	 *     track it.  Gain is restored before the geometry test so the two do not mix.
	 * (2) IMAGE_ORIENTATION.  Ask the part to mirror AND flip its readout.  If the new bytes
	 *     match the baseline ROTATED 180 degrees far better than they match it as-is, the
	 *     bytes came out of the sensor's own readout order -- the strongest evidence
	 *     available without anybody at the bench to move the lens.
	 */
	struct ospi_frame_result fr1;
	struct fstats s1;
	static const uint8_t gains[] = { 0x10, 0x20, 0x30, 0x00 };
	int rc3 = -1;
	struct fstats s3 = { 0 };
	uint64_t prev_mean = s0.mean_x100;
	unsigned monotone = 1;

	for (unsigned g = 0; g < ARRAY_SIZE(gains); g++) {
		uint8_t got = 0;
		int ws = hm_set(HM_ANA_GAIN, gains[g], &got);

		k_msleep(800);
		rc3 = capture_into(1, &fr1);
		frame_stats(frame[1], w, h, &s3);
		if (gains[g] != 0x00 && s3.mean_x100 <= prev_mean) {
			monotone = 0;
		}
		printk("CAM_MOVE kind=gain wr=%d ae_ctrl_off=1 gain=0x%02x readback=0x%02x rc=%d "
		       "mean_x100=%llu prev_mean_x100=%llu ffs=%u max=%u verdict=%s\n", ws, gains[g],
		       got, rc3, s3.mean_x100, prev_mean, s3.ffs, s3.mx,
		       rc3 ? "capture_failed" :
		       (gains[g] == 0x00) ? "restored" :
		       (s3.mean_x100 > prev_mean) ? "brighter" : "NOT_brighter");
		if (gains[g] != 0x00) {
			prev_mean = s3.mean_x100;
		}
	}
	printk("CAM_MOVE kind=gain_sweep monotone=%u base_mean_x100=%llu top_mean_x100=%llu\n",
	       monotone, s0.mean_x100, prev_mean);
	k_msleep(800);

	uint8_t orient0 = 0, rb = 0;

	(void)hm01b0_read(&bus, HM_IMAGE_ORIENT, &orient0);
	int wr = hm_set(HM_IMAGE_ORIENT, (uint8_t)(orient0 ^ 0x03u), &rb);

	k_msleep(800);
	int rc1 = capture_into(1, &fr1);

	frame_stats(frame[1], w, h, &s1);
	print_stats("flip", &s1);
	if (rc1 == 0 && fr1.bytes == bytes) {
		uint64_t ds, dr, dm;

		compare_frames(frame[0], frame[1], w, h, &ds, &dr, &dm);
		printk("CAM_MOVE kind=orient wr=%d orient=0x%02x->0x%02x readback=0x%02x "
		       "mad_x100=%llu mad_rot180_x100=%llu mad_mirror_x100=%llu "
		       "mean_base_x100=%llu mean_flip_x100=%llu verdict=%s\n", wr, orient0,
		       (uint8_t)(orient0 ^ 0x03u), rb, ds, dr, dm, s0.mean_x100, s1.mean_x100,
		       (dr * 2u < ds) ? "rotated" : (ds * 2u < dr) ? "unchanged" : "inconclusive");
	} else {
		printk("CAM_MOVE kind=orient wr=%d rc=%d bytes=%u verdict=capture_failed\n", wr, rc1,
		       fr1.bytes);
	}
	/* frame[1] is left holding the FLIPPED frame, so the PS reads both and can check the
	 * rotation itself rather than taking the guest's arithmetic for it. */
	print_frame_line("CAM_FRAME2", 1, w, h, rc1, &fr1, &s1);
	(void)hm_set(HM_IMAGE_ORIENT, orient0, &rb);

	if (ok) {
		static const char ramp[] = " .:-=+*#%@";
		uint32_t cols = 54, rws = 27;

		for (uint32_t ry = 0; ry < rws; ry++) {
			char line[64];

			for (uint32_t rx = 0; rx < cols; rx++) {
				uint32_t v = frame[0][(ry * h / rws) * w + (rx * w / cols)];

				line[rx] = ramp[v * 10u / 256u];
			}
			line[cols] = 0;
			printk("CAM_PREVIEW %s\n", line);
		}
	}
	dump_sensor_regs("after");
	(void)hm01b0_write(&bus, HM01B0_REG_MODE_SELECT, 0);
	l2_evict();
	return ok;
}

int main(void)
{
	struct ospi_regs r;

	printk("CAM_BOOT sample=cam_capture board=%s ospi=0x%08lx mclkdiv=%u\n", CONFIG_BOARD,
	       (unsigned long)OSPI, CAM_MCLKDIV);

	ospi_read_regs(OSPI, &r);
	print_regs("CAM_REGS", &r);
	int regs_ok = r.capacity == 512 && r.geom == ((244u << 16) | 324u) && r.ctrl == 0 &&
		      r.dma_ctrl == 0 && r.dma_status == 0 && r.mclkdiv == 0;
	printk("CAM_REGS_CHECK ok=%d capacity=%u geom=0x%08x dma_status=0x%02x\n", regs_ok, r.capacity,
	       r.geom, r.dma_status);

	if (!device_is_ready(i2c)) {
		printk("CAM_RESULT shield=unknown ok=0 reason=i2c_not_ready\n");
		return 0;
	}

	uint32_t p0 = ospi_rd(OSPI, OSPI_PCLKCNT), f0 = ospi_rd(OSPI, OSPI_FVLDCNT), l0 = ospi_rd(OSPI, OSPI_LVLDCNT);
	k_msleep(500);
	uint32_t p1 = ospi_rd(OSPI, OSPI_PCLKCNT), f1 = ospi_rd(OSPI, OSPI_FVLDCNT), l1 = ospi_rd(OSPI, OSPI_LVLDCNT);
	printk("CAM_DIAG pclkcnt0=%u fvldcnt0=%u lvldcnt0=%u pclkcnt1=%u fvldcnt1=%u lvldcnt1=%u sensor_int=%u\n",
	       p0, f0, l0, p1, f1, l1, !!(ospi_rd(OSPI, OSPI_FLAGS) & OSPI_FLAG_SENSORINT));

	uint8_t id_h = 0;
	int64_t t0 = k_uptime_get();
	int prc = hm01b0_read(&bus, HM01B0_REG_MODEL_ID_H, &id_h);
	printk("CAM_I2C_PROBE addr=0x24 rc=%d nack=%d model_id_h=0x%02x ms=%lld\n", prc, prc == -EIO, id_h,
	       k_uptime_get() - t0);

	int present = (prc == 0);
	printk("CAM_SHIELD present=%d\n", present);

	int ok;
	if (!present) {
		int idle = (p0 == 0 && p1 == 0 && f1 == 0 && l1 == 0);
		printk("CAM_NOSHIELD diag_zero=%d i2c_nack=%d\n", idle, prc == -EIO);
		ok = regs_ok && idle && prc == -EIO && no_shield();
	} else {
		ok = regs_ok && with_shield();
	}
	printk("CAM_RESULT shield=%d ok=%d\n", present, ok);
	return 0;
}
