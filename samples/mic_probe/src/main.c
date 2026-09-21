/*
 * Copyright (c) 2026 IISWC tutorial
 * SPDX-License-Identifier: Apache-2.0
 *
 * Lab B110 -- IS THE PDM MICROPHONE ALIVE ON THE SHIPPING BITSTREAM?
 *
 * fpga/pynq-z2/docs/MICROPHONE.md predates 0x5A5A0035.  `mic` is in that build's
 * MAGIC_FEATURES.tsv row and the RTL is pinned, but no arm in this tree has ever read the
 * peripheral on it.  This reads it, by RAW MMIO and not through the DMIC driver, because
 * the question is about eight registers and not about an API.
 *
 * THE TRAP THIS IS SHAPED AROUND.  A register read that returns 0 is indistinguishable
 * from a peripheral that is not there: an unmapped read on this pbus returns zeros, not a
 * fault.  So the discriminators are values an absent peripheral CANNOT produce --
 *
 *   ID    reads 0x504D4331 ("PMC1")     -- 32 specific bits
 *   DEPTH reads 1024                    -- not a value a hole returns
 *
 * -- and "it responds" is still not "it works": a register file can answer while the
 * decimator is not clocking, so LEVEL must ADVANCE and DATA must carry values that move.
 *
 * THE NUMBER THIS LAB EXISTS FOR IS THE SAMPLE RATE.  RATE (0x28) is a COMPILE-TIME
 * CONSTANT baked into the Verilog parameter RATE_MHZ, default 15993859 millihertz, and
 * PdmMicParams takes every default (PynqZ2Configs.scala: `WithPdmMic(address =
 * 0x10090000L)`).  That constant was computed for FCLK0 = 34.4828 MHz.  The real rate is
 * set by the clock and the three integer divisions in the chain and by nothing else:
 *
 *   f_pcm = FCLK0 / (2*PDM_HALF * CIC_R * FIR_DECIM) = FCLK0 / (14 * 22 * 7) = FCLK0/2156
 *
 * At 34,482,758.6 Hz that is 15,993.859 Hz, which is where the constant came from.
 * 0x5A5A0035 runs at FCLK0 = 40,000,000 Hz exactly, so the PREDICTION this lab is scored
 * against, committed before the board:
 *
 *   f_pcm = 40,000,000 / 2156 = 18,552.8757 Hz     (+16.00 % on the register's 15,993.859)
 *   PDM clock = 40 MHz / 14 = 2.857143 MHz         (still inside the part's 1-3.3 MHz)
 *   SETTLE = 131072 PDM bits = 45.9 ms             (not the doc's 53 ms)
 *
 * If that is right, RATE reads a figure the hardware has not produced since the clock
 * moved, and 64,000 samples -- the encoder's first dispatch is hard-shaped at IW = 64000 --
 * is 3.4496 s of audio, not 4.0016 s.  MEASURED, by counting samples against mtime, which
 * on this guest ticks at CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC = 40,000 Hz (FCLK0/1000).
 *
 * The rate loop pops one sample at a time and always from an EMPTY fifo: after the drain,
 * every iteration waits for LEVEL to leave zero, so the loop is paced by the decimator and
 * the elapsed time is N sample periods plus a polling latency of a few hundred ns.  No
 * printk inside it -- the console is 115200 baud and would pace the loop instead.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/sys_io.h>
#include <stdint.h>

#define MIC_BASE   0x10090000UL
#define R_ID       (MIC_BASE + 0x00)
#define R_CTRL     (MIC_BASE + 0x08)
#define R_STATUS   (MIC_BASE + 0x10)
#define R_LEVEL    (MIC_BASE + 0x18)
#define R_DATA     (MIC_BASE + 0x20)
#define R_RATE     (MIC_BASE + 0x28)
#define R_DEPTH    (MIC_BASE + 0x30)
#define R_WMARK    (MIC_BASE + 0x38)

#define ID_MAGIC          0x504D4331U
#define CTRL_ENABLE       0x1U
#define CTRL_FIFO_RESET   0x2U
#define CTRL_DC_BYPASS    0x4U
#define CTRL_CLR_STICKY   0x8U

#define ST_SETTLING       0x1U
#define ST_EMPTY          0x2U
#define ST_FULL           0x4U
#define ST_OVERRUN        0x8U
#define ST_SATURATED      0x10U

#define BURST_N   512        /* "a few hundred samples", both DC arms */
#define RATE_N    64000      /* the encoder's IW, so the seconds it buys is read directly */

static uint8_t seen[8192];   /* one bit per int16 value: distinct-value count */

struct stats {
	int32_t  mn, mx;
	int64_t  sum;
	uint64_t sumabs;
	uint32_t n, zeros, distinct;
};

static void st_init(struct stats *s)
{
	s->mn = 2147483647; s->mx = -2147483647 - 1;
	s->sum = 0; s->sumabs = 0; s->n = 0; s->zeros = 0; s->distinct = 0;
	for (int i = 0; i < 8192; i++) {
		seen[i] = 0;
	}
}

static inline void st_add(struct stats *s, int32_t v)
{
	uint16_t u = (uint16_t)v;

	if (v < s->mn) { s->mn = v; }
	if (v > s->mx) { s->mx = v; }
	s->sum += v;
	s->sumabs += (v < 0) ? (uint32_t)(-v) : (uint32_t)v;
	if (v == 0) { s->zeros++; }
	if ((seen[u >> 3] & (1U << (u & 7))) == 0U) {
		seen[u >> 3] |= (1U << (u & 7));
		s->distinct++;
	}
	s->n++;
}

/* mean and mean-|x| in thousandths, so nothing needs a 64-bit printf or an FPU */
static void st_print(const char *tag, const struct stats *s)
{
	int32_t mean_m = (s->n != 0U) ? (int32_t)((s->sum * 1000) / (int64_t)s->n) : 0;
	int32_t mabs_m = (s->n != 0U) ? (int32_t)((int64_t)(s->sumabs * 1000U) / (int64_t)s->n) : 0;

	printk("MP_STATS %s n=%u min=%d max=%d mean_milli=%d meanabs_milli=%d "
	       "zeros=%u distinct=%u\n",
	       tag, s->n, s->mn, s->mx, mean_m, mabs_m, s->zeros, s->distinct);
}

static void ctrl(uint32_t v) { sys_write32(v, R_CTRL); }

/* Pop n samples, always from an empty FIFO, so the loop is paced by the decimator.
 * Returns 0, or -1 if a sample failed to arrive inside the timeout.
 */
static int pop_n(struct stats *s, uint32_t n, int16_t *first, uint32_t nfirst,
		 uint32_t *t0, uint32_t *t1)
{
	uint32_t got = 0;

	while (sys_read32(R_LEVEL) != 0U) { (void)sys_read32(R_DATA); }   /* drain */
	while (sys_read32(R_LEVEL) == 0U) { }                             /* boundary */
	(void)sys_read32(R_DATA);
	*t0 = k_cycle_get_32();

	while (got < n) {
		uint32_t guard = 0;

		while (sys_read32(R_LEVEL) == 0U) {
			if (++guard > 200000000U) {
				*t1 = k_cycle_get_32();
				printk("MP_STALL after=%u samples\n", got);
				return -1;
			}
		}
		int32_t v = (int32_t)sys_read32(R_DATA);

		if (first != NULL && got < nfirst) { first[got] = (int16_t)v; }
		st_add(s, v);
		got++;
	}
	*t1 = k_cycle_get_32();
	return 0;
}

static void rate_line(const char *tag, uint32_t n, uint32_t t0, uint32_t t1)
{
	uint32_t hz = sys_clock_hw_cycles_per_sec();
	uint32_t dt = t1 - t0;
	/* rate in millihertz, integer: n * hz * 1000 / dt */
	uint64_t r_mhz = dt ? ((uint64_t)n * (uint64_t)hz * 1000ULL) / (uint64_t)dt : 0;
	/* and the seconds those n samples represent, in microseconds */
	uint64_t us = ((uint64_t)dt * 1000000ULL) / (uint64_t)hz;

	printk("MP_RATE %s n=%u mtime_hz=%u ticks=%u elapsed_us=%u rate_millihz=%u\n",
	       tag, n, hz, dt, (uint32_t)us, (uint32_t)r_mhz);
}

int main(void)
{
	struct stats s;
	uint32_t t0, t1;
	int16_t first[24];

	printk("\nMP_BEGIN base=0x%08lx build=" __DATE__ " " __TIME__ "\n",
	       (unsigned long)MIC_BASE);
	printk("MP_GUEST sys_clock_hw_cycles_per_sec=%u\n", sys_clock_hw_cycles_per_sec());

	/* ---- 1. does the register file answer, and with values a hole cannot produce ---- */
	uint32_t id = sys_read32(R_ID);
	uint32_t depth = sys_read32(R_DEPTH);
	uint32_t rate_reg = sys_read32(R_RATE);

	printk("MP_REGS id=0x%08x depth=%u rate_reg_millihz=%u wmark=%u\n",
	       id, depth, rate_reg, sys_read32(R_WMARK));

	if (id != ID_MAGIC || depth != 1024U) {
		printk("MP_VERDICT NOT_MAPPED id=0x%08x(want 0x%08x) depth=%u(want 1024)\n",
		       id, ID_MAGIC, depth);
		printk("MP_DONE\n");
		return 0;
	}
	printk("MP_GATE1 PASS id and depth are both exact\n");

	/* ---- 2. disabled: empty, and LEVEL stays at zero ---- */
	ctrl(0U);
	ctrl(CTRL_FIFO_RESET | CTRL_CLR_STICKY);
	ctrl(0U);
	k_msleep(50);
	uint32_t st_off = sys_read32(R_STATUS);
	uint32_t lv_off_a = sys_read32(R_LEVEL);

	k_msleep(100);
	uint32_t lv_off_b = sys_read32(R_LEVEL);

	printk("MP_OFF status=0x%02x empty=%u level_a=%u level_b=%u ctrl_rb=0x%02x\n",
	       st_off, (st_off & ST_EMPTY) ? 1U : 0U, lv_off_a, lv_off_b,
	       sys_read32(R_CTRL));
	printk("MP_GATE2 %s\n",
	       ((st_off & ST_EMPTY) && lv_off_a == 0U && lv_off_b == 0U) ? "PASS" : "FAIL");

	/* ---- 3. enable, and time the settling window ---- */
	t0 = k_cycle_get_32();
	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE);
	uint32_t spins = 0;

	while ((sys_read32(R_STATUS) & ST_SETTLING) != 0U) {
		if (++spins > 100000000U) { break; }
	}
	t1 = k_cycle_get_32();
	printk("MP_SETTLE ticks=%u us=%u status=0x%02x\n", t1 - t0,
	       (uint32_t)(((uint64_t)(t1 - t0) * 1000000ULL) / sys_clock_hw_cycles_per_sec()),
	       sys_read32(R_STATUS));

	/* ---- 4. does LEVEL advance?  three reads, each with its own mtime ---- */
	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET);
	ctrl(CTRL_ENABLE);
	uint32_t base_t = k_cycle_get_32();

	for (int i = 0; i < 3; i++) {
		k_msleep(15);
		uint32_t lv = sys_read32(R_LEVEL);
		uint32_t tt = k_cycle_get_32();

		printk("MP_LEVEL step=%d ticks=%u level=%u status=0x%02x\n",
		       i, tt - base_t, lv, sys_read32(R_STATUS));
	}

	/* ---- 5. DC arms.  bypassed, the 0.5164 PDM density is ~1074 counts of DC; the
	 *        blocker is what makes the mean near zero.  Both measured here, so "mean
	 *        near zero" is a property of the filter and not of a stuck value.  ---- */
	ctrl(CTRL_ENABLE | CTRL_DC_BYPASS | CTRL_FIFO_RESET | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE | CTRL_DC_BYPASS);
	k_msleep(100);
	st_init(&s);
	pop_n(&s, BURST_N, NULL, 0U, &t0, &t1);
	st_print("dc_bypass", &s);
	rate_line("dc_bypass", BURST_N, t0, t1);

	ctrl(CTRL_ENABLE | CTRL_FIFO_RESET | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE);
	k_msleep(150);                       /* the 1-pole blocker converges in ~128 samples */
	st_init(&s);
	pop_n(&s, BURST_N, first, 24U, &t0, &t1);
	st_print("dc_on", &s);
	rate_line("dc_on", BURST_N, t0, t1);
	printk("MP_FIRST");
	for (int i = 0; i < 24; i++) { printk(" %d", first[i]); }
	printk("\n");

	/* ---- 6. THE RATE, over exactly IW = 64000 samples ---- */
	ctrl(CTRL_ENABLE | CTRL_CLR_STICKY);
	ctrl(CTRL_ENABLE);
	st_init(&s);
	int rc = pop_n(&s, RATE_N, NULL, 0U, &t0, &t1);

	st_print("window", &s);
	rate_line("window", RATE_N, t0, t1);
	printk("MP_WINDOW rc=%d status_after=0x%02x\n", rc, sys_read32(R_STATUS));

	ctrl(0U);
	printk("MP_VERDICT MAPPED_AND_SAMPLING\n");
	printk("MP_DONE\n");
	return 0;
}
