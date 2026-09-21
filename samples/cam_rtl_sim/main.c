/* SPDX-License-Identifier: Apache-2.0
 *
 * The HM01B0 capture peripheral, its DMA and the I2C bus, in 0x5A5A001E's own RTL in Verilator,
 * before any bitstream.
 *
 * PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig's TestHarness puts a model sensor on
 * ChipTop's ospi_sensor_* and i2c_0_* ports (fpga/pynq-z2/sim/hm01b0_sim_model.v: I2C slave at
 * 0x24, 32 x 24 frames on PCLK = MCLK/2 once MODE_SELECT is set, pixel (x,y) of frame f =
 * (x*7) ^ (y*13) ^ f).  Everything between the software and the model is the real SoC: the
 * TLI2C, the capture core, the line buffer, the DMA master on the front bus, the system bus, the
 * 64 KB InclusiveCache, the memory bus and DRAMSim.
 *
 *   A  idle: reset values, and PCLKCNT = FVLDCNT = LVLDCNT = 0 with the sensor in standby
 *   B  I2C with the register sequence Zephyr's i2c_sifive.c issues: a released-bus NACK at 0x3C,
 *      MODEL_ID = 0x01B0 at 0x24, a NACK then a transfer again, a write; MCLK and TRIG reach
 *      the model's pins; SCL period measured
 *   C  idle diagnostics still zero after I2C traffic
 *   D  DMA armed with no sensor clock: stays BUSY in COLLECT with 0 bytes -- the no-shield path
 *   E  MODE_SELECT = 1: the armed transfer completes with one whole frame
 *   F  sw/cam/ospi_cam.c's ospi_dma_capture_frame, three times: a whole frame each, byte exact,
 *      the bytes after the frame untouched, and hart 1 reads every frame back through its own
 *      L1 and the L2 and checks it independently
 *   G  DMA_LEN = 13: PutPartialData's mask leaves bytes 13..15 alone
 *   H  a transfer at the error device (0x3000): DMA_STATUS.error, transfer still finishes
 *   I  MMIO DATA path with DMA disabled; overflow flag and its clear
 *   J  MODE_SELECT = 0: PCLK stops
 *
 * Expect CAM_RTL_SIM: PASS.
 */
#include <stdint.h>
#include <stddef.h>
#include "ospi_cam.h"

void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }

volatile uint64_t tohost   __attribute__((section(".htif"), aligned(64)));
volatile uint64_t fromhost __attribute__((section(".htif"), aligned(64)));
static volatile uint64_t magic_mem[8] __attribute__((aligned(64)));

static void htif_syscall(uint64_t n, uint64_t a0, uint64_t a1, uint64_t a2)
{
	magic_mem[0] = n; magic_mem[1] = a0; magic_mem[2] = a1; magic_mem[3] = a2;
	__asm__ volatile ("fence" ::: "memory");
	tohost = (uint64_t)(uintptr_t)magic_mem;
	while (fromhost == 0) {
	}
	fromhost = 0;
	__asm__ volatile ("fence" ::: "memory");
}
static void hputs(const char *s) { size_t n = 0; while (s[n]) n++; if (n) htif_syscall(64, 1, (uint64_t)(uintptr_t)s, n); }
static void put_hex(uint64_t v, int digits)
{
	char b[20]; int i = 0; b[i++] = '0'; b[i++] = 'x';
	for (int k = digits - 1; k >= 0; k--) { unsigned d = (unsigned)((v >> (4 * k)) & 0xf); b[i++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); }
	b[i] = 0; hputs(b);
}
static void put_u(uint64_t u)
{
	char b[24]; int i = 23; b[i--] = 0;
	if (!u) b[i--] = '0';
	while (u) { b[i--] = (char)('0' + u % 10); u /= 10; }
	hputs(&b[i + 1]);
}
static void put_i(int64_t v) { if (v < 0) { hputs("-"); put_u((uint64_t)(-v)); } else put_u((uint64_t)v); }
__attribute__((noreturn)) static void htif_exit(int code)
{
	__asm__ volatile ("fence" ::: "memory");
	tohost = ((uint64_t)(unsigned)code << 1) | 1u;
	for (;;) {
	}
}

/* crt.S's trap bookkeeping (samples/pext_rtl_selftest/crt.S); no traps are expected here */
volatile uint64_t mbp_trap_cause[2], mbp_trap_epc[2], mbp_trap_tval[2], mbp_trap_count[2];

__asm__(".pushsection .text\n.balign 4\n.globl rd_mcycle\nrd_mcycle:\n csrr a0, mcycle\n ret\n.popsection\n");
uint64_t rd_mcycle(void);

static int fails;
static void check(int ok, const char *what)
{
	hputs(ok ? "  pass  " : "  FAIL  "); hputs(what); hputs("\n");
	if (!ok) fails++;
}
static void kv(const char *k, uint64_t v) { hputs("    "); hputs(k); hputs(" = "); put_u(v); hputs(" ("); put_hex(v, 8); hputs(")\n"); }

/* ------------------------------------------------------------------------------------------
 * TLI2C, register level, issuing exactly the commands Zephyr's drivers/i2c/i2c_sifive.c
 * issues for i2c_write() and i2c_write_read().  The one addition is a bound on the TIP busy-wait,
 * so a stuck bus ends the simulation with a message instead of at max-cycles.
 * ------------------------------------------------------------------------------------------ */
#define I2C_PRESCALE_LO 0x00
#define I2C_PRESCALE_HI 0x04
#define I2C_CONTROL     0x08
#define I2C_TXRX        0x0c
#define I2C_CMDSTAT     0x10
#define SF_CONTROL_EN   (1 << 7)
#define SF_CMD_START    (1 << 7)
#define SF_CMD_STOP     (1 << 6)
#define SF_CMD_READ     (1 << 5)
#define SF_CMD_WRITE    (1 << 4)
#define SF_CMD_ACK      (1 << 3)
#define SF_STATUS_RXACK (1 << 7)
#define SF_STATUS_TIP   (1 << 1)
#define F_SYS           34483000u   /* SIFIVE_PERIPHERAL_CLOCK_FREQUENCY on the board */

static uint8_t i2c_rd8(uint32_t off) { return *(volatile uint8_t *)(TLI2C_BASE + off); }
static void i2c_wr8(uint32_t off, uint8_t v) { *(volatile uint8_t *)(TLI2C_BASE + off) = v; }
static int i2c_wait(void)
{
	for (uint32_t n = 0; n < 2000000u; n++) {
		if (!(i2c_rd8(I2C_CMDSTAT) & SF_STATUS_TIP)) return 0;
	}
	hputs("  (TLI2C TIP never cleared)\n");
	return -110;
}
static uint16_t i2c_prescale;
static void tli2c_configure(uint32_t bus_hz)
{
	i2c_wr8(I2C_CONTROL, 0);
	i2c_prescale = (uint16_t)(F_SYS / (bus_hz * 5u) - 1u);
	i2c_wr8(I2C_PRESCALE_LO, (uint8_t)i2c_prescale);
	i2c_wr8(I2C_PRESCALE_HI, (uint8_t)(i2c_prescale >> 8));
	i2c_wr8(I2C_CONTROL, SF_CONTROL_EN);
}
static int tli2c_send_addr(uint8_t addr, uint8_t rw)
{
	if (i2c_wait()) return -110;
	i2c_wr8(I2C_TXRX, (uint8_t)((addr << 1) | rw));
	i2c_wr8(I2C_CMDSTAT, SF_CMD_WRITE | SF_CMD_START);
	if (i2c_wait()) return -110;
	return (i2c_rd8(I2C_CMDSTAT) & SF_STATUS_RXACK) ? -5 : 0;
}
static int tli2c_write_msg(uint8_t addr, const uint8_t *buf, uint32_t len, int stop)
{
	int rc = tli2c_send_addr(addr, 0);
	if (rc) return rc;
	for (uint32_t i = 0; i < len; i++) {
		if (i2c_wait()) return -110;
		i2c_wr8(I2C_TXRX, buf[i]);
		i2c_wr8(I2C_CMDSTAT, (uint8_t)(SF_CMD_WRITE | ((i == len - 1 && stop) ? SF_CMD_STOP : 0)));
		if (i2c_wait()) return -110;
		if (i2c_rd8(I2C_CMDSTAT) & SF_STATUS_RXACK) return -5;
	}
	return 0;
}
static int tli2c_read_msg(uint8_t addr, uint8_t *buf, uint32_t len, int stop)
{
	int rc = tli2c_send_addr(addr, 1);
	if (rc) return rc;
	if (i2c_wait()) return -110;
	for (uint32_t i = 0; i < len; i++) {
		uint8_t cmd = SF_CMD_READ;
		if (i == len - 1) cmd |= SF_CMD_ACK | (stop ? SF_CMD_STOP : 0);
		i2c_wr8(I2C_CMDSTAT, cmd);
		if (i2c_wait()) return -110;
		buf[i] = i2c_rd8(I2C_TXRX);
	}
	return 0;
}
static int bm_write(void *ctx, uint8_t a, const uint8_t *b, uint32_t n)
{ (void)ctx; return tli2c_write_msg(a, b, n, 1); }
static int bm_write_read(void *ctx, uint8_t a, const uint8_t *w, uint32_t wl, uint8_t *r, uint32_t rl)
{ (void)ctx; int rc = tli2c_write_msg(a, w, wl, 0); return rc ? rc : tli2c_read_msg(a, r, rl, 1); }
static const struct cam_i2c bus = { bm_write, bm_write_read, 0 };

/* ------------------------------------------------------------------------------------------ */
#define W 32
#define H 24
static uint8_t frame_a[1024] __attribute__((aligned(64)));
static uint8_t frame_b[1024] __attribute__((aligned(64)));
static uint8_t part_c[64]    __attribute__((aligned(64)));

static uint32_t frame_bad(const uint8_t *b, uint8_t *f_out)
{
	uint8_t f = b[0];
	uint32_t bad = 0;
	for (unsigned y = 0; y < H; y++)
		for (unsigned x = 0; x < W; x++)
			if (b[y * W + x] != (uint8_t)((x * 7u) ^ (y * 13u) ^ f)) bad++;
	*f_out = f;
	return bad;
}
static uint32_t count_not(const uint8_t *b, uint32_t from, uint32_t to, uint8_t v)
{
	uint32_t n = 0;
	for (uint32_t i = from; i < to; i++) if (b[i] != v) n++;
	return n;
}

/* hart 1: reads a frame through its own L1 and the L2, independently of hart 0 */
static volatile uint64_t h1_addr, h1_req, h1_ack, h1_bad, h1_f, h1_sum;
static void hart1_loop(void)
{
	for (;;) {
		if (h1_req != h1_ack) {
			const uint8_t *b = (const uint8_t *)(uintptr_t)h1_addr;
			uint8_t f;
			uint64_t sum = 0;
			h1_bad = frame_bad(b, &f);
			for (unsigned i = 0; i < W * H; i++) sum += b[i];
			h1_f = f; h1_sum = sum;
			h1_ack = h1_req;
		}
	}
}
static void hart1_check(const uint8_t *b, const char *what)
{
	h1_addr = (uint64_t)(uintptr_t)b;
	h1_req++;
	for (uint64_t n = 0; h1_ack != h1_req; n++) {
		if (n > 50000000u) { check(0, "hart 1 never answered"); return; }
	}
	uint64_t sum = 0; uint8_t f;
	uint32_t bad0 = frame_bad(b, &f);
	for (unsigned i = 0; i < W * H; i++) sum += b[i];
	hputs("    hart 1: frame "); put_u(h1_f); hputs(", "); put_u(h1_bad); hputs(" bad bytes, sum "); put_u(h1_sum);
	hputs("; hart 0: frame "); put_u(f); hputs(", "); put_u(bad0); hputs(" bad, sum "); put_u(sum); hputs("\n");
	check(h1_bad == 0 && h1_f == f && h1_sum == sum, what);
}

static uint32_t wait_dma_idle(uint32_t max)
{
	uint32_t st = 0;
	for (uint32_t n = 0; n < max; n++) {
		st = ospi_rd(OSPI_BASE, OSPI_DMA_STATUS);
		if ((st & OSPI_DMA_ST_DONE) && !(st & OSPI_DMA_ST_BUSY)) break;
	}
	return st;
}

static int hm_rd(uint16_t reg, uint8_t *v) { return hm01b0_read(&bus, reg, v); }

void hart_main(unsigned long hartid)
{
	if (hartid != 0) hart1_loop();

	struct ospi_regs r;
	const uintptr_t B = OSPI_BASE;
	hputs("CAM_RTL_SIM: 0x5A5A001E ospi + DMA + TLI2C against hm01b0_sim_model.v\n");

	/* ---------------- A ---------------- */
	hputs("A. reset values, sensor in standby\n");
	ospi_read_regs(B, &r);
	kv("CAPACITY", r.capacity); kv("GEOM", r.geom); kv("FLAGS", r.flags); kv("DMA_STATUS", r.dma_status);
	check(r.capacity == 512, "CAPACITY = 512 (line-sized frame buffer)");
	check(r.geom == ((244u << 16) | 324u), "GEOM resets to 324 x 244");
	check(r.ctrl == 0 && r.mclkdiv == 0 && r.dma_ctrl == 0, "CTRL, MCLKDIV, DMA_CTRL reset to 0");
	check(r.pclkcnt == 0 && r.fvldcnt == 0 && r.lvldcnt == 0, "PCLKCNT = FVLDCNT = LVLDCNT = 0 in standby");
	check(r.framecnt == 0 && r.flags == 0 && r.dma_status == 0 && r.dma_bytes == 0, "FRAMECNT, FLAGS, DMA_STATUS, DMA_BYTES = 0");
	ospi_wr(B, OSPI_MCLKDIV, 2);
	check(ospi_rd(B, OSPI_MCLKDIV) == 2, "MCLKDIV reads back");
	ospi_wr(B, OSPI_MCLKDIV, 0);

	/* ---------------- B ---------------- */
	hputs("B. I2C (TLI2C at 0x10040000, Zephyr i2c_sifive command sequence)\n");
	tli2c_configure(100000u);
	kv("prescale (F_SYS / (5 * 100 kHz) - 1)", i2c_prescale);
	int rc = bus.write(0, 0x3C, 0, 0);
	hputs("    probe 0x3C: rc "); put_i(rc); hputs("\n");
	check(rc == -5, "no device at 0x3C: NACK, the bus released (SDA high through the ACK bit)");

	uint16_t id = 0;
	uint8_t hi = 0, lo = 0;
	/* SCL rising edges seen by the model, sampled before and after MODEL_ID (0xFF04/0xFF05) */
	{
		uint8_t w[2] = { 0xFF, 0x04 }, rb[2];
		rc = bus.write_read(0, HM01B0_I2C_ADDR, w, 2, rb, 2);
		hi = rb[0]; lo = rb[1];
	}
	uint64_t t1 = rd_mcycle(); uint32_t s1 = ((uint32_t)hi << 8) | lo;
	rc = hm01b0_model_id(&bus, &id);
	hputs("    MODEL_ID rc "); put_i(rc); hputs(" id "); put_hex(id, 4); hputs("\n");
	check(rc == 0 && id == HM01B0_MODEL_ID, "MODEL_ID at 0x24 = 0x01B0 (register 0x0000/0x0001)");
	{
		uint8_t w[2] = { 0xFF, 0x04 }, rb[2];
		bus.write_read(0, HM01B0_I2C_ADDR, w, 2, rb, 2);
		hi = rb[0]; lo = rb[1];
	}
	uint64_t t2 = rd_mcycle(); uint32_t s2 = ((uint32_t)hi << 8) | lo;
	if (s2 > s1) {
		uint64_t per = (t2 - t1) / (s2 - s1);
		hputs("    SCL: "); put_u(s2 - s1); hputs(" rising edges in "); put_u(t2 - t1);
		hputs(" cycles, "); put_u(per); hputs(" per edge on average INCLUDING software between bytes\n");
	}
	{
		uint8_t w[2] = { 0xFF, 0x06 }, rb[2];
		bus.write_read(0, HM01B0_I2C_ADDR, w, 2, rb, 2);
		uint32_t m = ((uint32_t)rb[0] << 8) | rb[1];
		hputs("    SCL bit period within a byte: "); put_u(m); hputs(" MCLK periods = ~"); put_u(2u * m);
		hputs(" SoC clock cycles (MCLKDIV 0); 5*(prescale+1) = "); put_u(5u * (i2c_prescale + 1u));
		hputs(", 4*(prescale+1) = "); put_u(4u * (i2c_prescale + 1u));
		if (m) { hputs("; at 34.4828 MHz: "); put_u(34482759u / (2u * m)); hputs(" Hz"); }
		hputs("\n");
		check(m > 0 && m < 0xFFFF, "SCL bit period measured at the model's pin");
	}
	check(s2 > s1, "SCL toggles at the model's pin");

	uint8_t v = 0;
	rc = hm_rd(0xFF01, &v);
	check(rc == 0 && v == 1, "MCLK toggles at the model's pin (model register 0xFF01)");

	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_TRIG);                          /* one pulse */
	rc = hm_rd(0xFF00, &v);
	kv("TRIG edges after CTRL.trig", v);
	check(rc == 0 && v == 1, "TRIG pulse reaches the model's pin");
	/* continuous gates TRIG from the cycle AFTER the write that sets it, so set it first */
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CONTINUOUS);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CONTINUOUS | OSPI_CTRL_TRIG);
	rc = hm_rd(0xFF00, &v);
	check(rc == 0 && v == 1, "TRIG is held low in continuous mode");
	ospi_wr(B, OSPI_CTRL, 0);

	rc = bus.write(0, 0x3C, 0, 0);
	uint8_t idl = 0;
	int rc2 = hm_rd(HM01B0_REG_MODEL_ID_L, &idl);
	check(rc == -5 && rc2 == 0 && idl == 0xB0, "a NACK without STOP, then 0x24 answers again");
	rc = hm01b0_write(&bus, 0x3060, 0x0A);
	int rc3 = hm_rd(0xFF03, &v);
	check(rc == 0 && rc3 == 0 && v == 1, "a register write is ACKed and seen by the sensor (0xFF03 = 1)");

	/* ---------------- C ---------------- */
	hputs("C. diagnostics after I2C traffic, sensor still in standby\n");
	ospi_read_regs(B, &r);
	check(r.pclkcnt == 0 && r.fvldcnt == 0 && r.lvldcnt == 0, "PCLKCNT = FVLDCNT = LVLDCNT = 0");

	/* ---------------- D ---------------- */
	hputs("D. DMA armed with no sensor clock (what the board does without a shield)\n");
	memset(frame_a, 0xA5, sizeof frame_a);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
	ospi_wr(B, OSPI_GEOM, (H << 16) | W);
	check(ospi_dma_start(B, (uint32_t)(uintptr_t)frame_a, 0) == 0, "transfer started");
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_ENABLE);
	for (unsigned n = 0; n < 3000; n++) (void)ospi_rd(B, OSPI_DMA_STATUS);
	ospi_read_regs(B, &r);
	kv("DMA_STATUS", r.dma_status); kv("DMA_BYTES", r.dma_bytes); kv("PCLKCNT", r.pclkcnt);
	check((r.dma_status & OSPI_DMA_ST_BUSY) && OSPI_DMA_STATE(r.dma_status) == 1 && r.dma_bytes == 0,
	      "timeout path: BUSY, state COLLECT, 0 bytes, PCLKCNT 0");
	{
		struct ospi_frame_result fr;
		rc = ospi_dma_capture_frame(B, (uint32_t)(uintptr_t)frame_b, sizeof frame_b, W, H, 10, 0, 0, &fr);
		check(rc == -1, "ospi_dma_capture_frame refuses while a transfer is pending (-1)");
	}

	/* ---------------- E ---------------- */
	hputs("E. MODE_SELECT = 1: the pending transfer gets its frame\n");
	rc = hm01b0_write(&bus, HM01B0_REG_MODE_SELECT, 1);
	check(rc == 0, "MODE_SELECT = 1 written");
	uint32_t st = wait_dma_idle(2000000u);
	ospi_read_regs(B, &r);
	kv("DMA_STATUS", st); kv("DMA_BYTES", r.dma_bytes); kv("FRAMECNT", r.framecnt);
	kv("LASTWIDTH", r.lastwidth); kv("LASTHEIGHT", r.lastheight); kv("FLAGS", r.flags);
	kv("PCLKCNT", r.pclkcnt); kv("FVLDCNT", r.fvldcnt); kv("LVLDCNT", r.lvldcnt);
	check((st & OSPI_DMA_ST_DONE) && !(st & OSPI_DMA_ST_BUSY) && !(st & OSPI_DMA_ST_ERROR) && (st & OSPI_DMA_ST_SAWEOF),
	      "DMA_STATUS: done, not busy, no error, saw EOF");
	check(r.dma_bytes == W * H, "DMA_BYTES = 768");
	check(r.framecnt >= 1 && r.lastwidth == W && r.lastheight == H && !(r.flags & OSPI_FLAG_GEOMERR),
	      "FRAMECNT >= 1, LASTWIDTH 32, LASTHEIGHT 24, no geomErr");
	check(r.flags & OSPI_FLAG_IRQPEND, "FLAGS.irqPending set by DMA done");
	uint8_t fa;
	uint32_t bad = frame_bad(frame_a, &fa);
	hputs("    frame "); put_u(fa); hputs(": "); put_u(bad); hputs(" bad bytes\n");
	check(bad == 0, "hart 0 reads the frame back exactly");
	check(count_not(frame_a, W * H, sizeof frame_a, 0xA5) == 0, "bytes after the frame untouched");
	hart1_check(frame_a, "hart 1 reads the same frame through its L1 and the L2");
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR);
	check(!(ospi_rd(B, OSPI_FLAGS) & OSPI_FLAG_IRQPEND), "CTRL.clear drops irqPending");

	/* ---------------- F ---------------- */
	hputs("F. ospi_dma_capture_frame (sw/cam/ospi_cam.c), three frames\n");
	uint8_t last_f = fa;
	for (int k = 0; k < 3; k++) {
		struct ospi_frame_result fr;
		memset(frame_b, 0x5A, sizeof frame_b);
		uint64_t cs = rd_mcycle();
		rc = ospi_dma_capture_frame(B, (uint32_t)(uintptr_t)frame_b, sizeof frame_b, W, H, 2000000u, 0, 0, &fr);
		uint64_t ce = rd_mcycle();
		uint8_t fb;
		bad = frame_bad(frame_b, &fb);
		hputs("    rc "); put_i(rc); hputs(" attempts "); put_u(fr.attempts); hputs(" bytes "); put_u(fr.bytes);
		hputs(" status "); put_hex(fr.dma_status, 2); hputs(" flags "); put_hex(fr.flags, 2);
		hputs(" FRAMECNT "); put_u(fr.framecnt); hputs(" frame "); put_u(fb); hputs(" bad "); put_u(bad);
		hputs(" cycles "); put_u(ce - cs); hputs("\n");
		check(rc == 0 && fr.bytes == W * H && fr.width == W && fr.height == H, "whole frame, geometry and DMA_BYTES");
		check(bad == 0, "hart 0 reads it back exactly");
		check(fb != last_f, "a newer frame than the previous capture");
		check(count_not(frame_b, W * H, sizeof frame_b, 0x5A) == 0, "bytes after the frame untouched");
		hart1_check(frame_b, "hart 1 reads it back exactly");
		last_f = fb;
	}
	ospi_read_regs(B, &r);
	kv("PCLKCNT", r.pclkcnt); kv("FVLDCNT", r.fvldcnt); kv("LVLDCNT", r.lvldcnt); kv("FRAMECNT", r.framecnt);
	check(r.lvldcnt >= H * (r.fvldcnt - 1) && r.lvldcnt <= H * r.fvldcnt, "LVLDCNT = 24 per FVLDCNT (one frame may be in flight)");
	check(r.pclkcnt >= 1440u * (r.fvldcnt - 1) && r.pclkcnt <= 1440u * (r.fvldcnt + 1), "PCLKCNT = 1440 per frame (48 x 30)");
	check(r.fvldcnt >= r.framecnt, "FVLDCNT >= FRAMECNT (frames seen while capture was off are not counted)");

	/* ---------------- G ---------------- */
	hputs("G. DMA_LEN = 13: a masked tail beat\n");
	memset(part_c, 0xEE, sizeof part_c);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
	ospi_dma_start(B, (uint32_t)(uintptr_t)part_c, 13);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_ENABLE);
	st = wait_dma_idle(2000000u);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR);
	kv("DMA_STATUS", st); kv("DMA_BYTES", ospi_rd(B, OSPI_DMA_BYTES));
	check((st & OSPI_DMA_ST_DONE) && !(st & OSPI_DMA_ST_ERROR) && ospi_rd(B, OSPI_DMA_BYTES) == 13, "done, 13 bytes");
	check(count_not(part_c, 13, sizeof part_c, 0xEE) == 0, "bytes 13..63 untouched (PutPartialData mask)");

	/* ---------------- H ---------------- */
	hputs("H. a transfer aimed at the error device (0x3000)\n");
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
	ospi_dma_start(B, 0x3000, 16);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_ENABLE);
	st = wait_dma_idle(2000000u);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR);
	kv("DMA_STATUS", st);
	check((st & OSPI_DMA_ST_DONE) && (st & OSPI_DMA_ST_ERROR), "done with DMA_STATUS.error (DENIED)");
	ospi_wr(B, OSPI_DMA_CTRL, OSPI_DMA_EN | OSPI_DMA_CLEAR);
	check(!(ospi_rd(B, OSPI_DMA_STATUS) & (OSPI_DMA_ST_ERROR | OSPI_DMA_ST_DONE)), "DMA_CTRL.clear drops done and error");

	/* ---------------- I ---------------- */
	hputs("I. MMIO DATA path (DMA disabled), overflow and its clear\n");
	ospi_wr(B, OSPI_DMA_CTRL, 0);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_ENABLE);
	uint32_t d = 0;
	for (uint32_t n = 0; n < 2000000u && !(d & 0x80000000u); n++) d = ospi_rd(B, OSPI_DATA);
	kv("DATA", d);
	check(d & 0x80000000u, "DATA returns a valid beat with DMA disabled");
	uint32_t fl = 0;
	for (uint32_t n = 0; n < 4000000u && !(fl & OSPI_FLAG_OVERFLOW); n++) fl = ospi_rd(B, OSPI_FLAGS);
	kv("FLAGS with nobody draining", fl);
	check((fl & OSPI_FLAG_OVERFLOW) && (fl & OSPI_FLAG_FBFULL), "overflow and frameBufferFull set when nothing drains");
	ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR | OSPI_CTRL_FLUSH);     /* capture off, one clear pulse */
	uint32_t clears = 1;
	for (; clears < 64 && (ospi_rd(B, OSPI_FLAGS) & OSPI_FLAG_OVERFLOW); clears++) {
		for (unsigned n = 0; n < 200; n++) (void)ospi_rd(B, OSPI_FLAGS);
		ospi_wr(B, OSPI_CTRL, OSPI_CTRL_CLEAR);
	}
	hputs("    overflow cleared after "); put_u(clears); hputs(" CTRL.clear pulse(s)"); hputs(
	      (ospi_rd(B, OSPI_FLAGS) & OSPI_FLAG_OVERFLOW) ? " -- STILL SET\n" : "\n");
	/* informational: the clear is a one-cycle SoC-clock pulse resampled on PCLK */

	/* ---------------- J ---------------- */
	hputs("J. MODE_SELECT = 0: PCLK stops\n");
	rc = hm01b0_write(&bus, HM01B0_REG_MODE_SELECT, 0);
	for (unsigned n = 0; n < 20000; n++) (void)ospi_rd(B, OSPI_PCLKCNT);
	uint32_t p1 = ospi_rd(B, OSPI_PCLKCNT);
	for (unsigned n = 0; n < 5000; n++) (void)ospi_rd(B, OSPI_PCLKCNT);
	uint32_t p2 = ospi_rd(B, OSPI_PCLKCNT);
	kv("PCLKCNT", p1); kv("PCLKCNT later", p2);
	check(rc == 0 && p1 == p2 && p1 > 0, "PCLKCNT holds once the sensor is in standby");

	hputs(fails ? "CAM_RTL_SIM: FAIL (" : "CAM_RTL_SIM: PASS (");
	put_u((uint64_t)fails); hputs(" failures)\n");
	htif_exit(fails ? 1 : 0);
}
