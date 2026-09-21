/* SPDX-License-Identifier: Apache-2.0
 *
 * The system-bus side of the memory architecture, on 0x5A5A001C (bwwin).  MEMORY_BANDWIDTH.md s9.
 *
 * ONE LADDER STEP PER BOARD SESSION (BWWIN_STEP, set by scripts/49_rocket_bwwin_lab.sh).  The core-clock
 * lanes put a traffic shape on the HP ports that no measured build produced from a lane: a port that
 * supplies 800 MB/s feeding a 552 MB/s consumer, so RREADY is held low part of the time.  The steps widen
 * that one dimension at a time, each in its own session with a health check after it:
 *
 *   1  one lane (HP0), 1 in flight, 64 KiB                        the least backpressure
 *   2  one lane (HP0), 1/2/4/8 in flight, 16 MiB                   one port under sustained backpressure
 *   3  every lane set x 1..8 in flight, SEQ included; L2 flush cost; BwProbe through the L2
 *   4  the DMA aperture: BwProbe through it, then the harts' loads and stores through it, the harts'
 *      coherent write, and the coherence contract's checks
 *   5  two lanes on ONE DDR controller port (HP0+HP1): striped over one region, against the same two
 *      lanes reading regions 64 MiB apart (the raw instrument's pairloc result, MEMORY_BANDWIDTH.md s7/s9)
 *
 * Every step first runs the harts' calibration (samples/membench's mb_read over L1, L2 and DRAM, through
 * the L2 -- the traffic every Rocket lab makes), so every session is gated on the same machine.
 *
 * WHAT IS PRINTED.  `CORE level=...` and `PROBE level=...` in scripts/43_rocket_bwlab.sh's formats;
 * `PROBEW` for the width proof; `WINLANE` per lane; `FLUSH` and `CONTRACT` lines this bench adds.
 * Checksums are XORs of 64-bit words.  An XOR over an EVEN number of passes of the same data is zero,
 * so every repeated read here is one pass.
 *
 * REGIONS (physical, behind 0x8000_0000; the aperture's alias of X is X - 0x4000_0000):
 *   BUF      0x8100_0000  4 MiB   calibration, BwProbe (through the L2, and through the aperture)
 *   WIN_BUF  0x8200_0000 16 MiB   BwWindow lanes
 *   AP_WBUF  0x8300_0000  4 MiB   the harts' writes through the aperture
 *   COH_WBUF 0x8400_0000  4 MiB   the harts' coherent writes
 *   CON_BUF  0x8500_0000 256 KiB  the contract checks
 *   SPL_BUF  0x8600_0000 16 MiB   step 5's second region, 64 MiB from WIN_BUF
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

#ifndef BWWIN_STEP
#define BWWIN_STEP 1
#endif

uint64_t mb_read(const void *base, uint64_t bytes);
void mb_write(void *base, uint64_t bytes, uint64_t val);

/* ---- BwProbe at 0x100A_0000 -------------------------------------------------------------- */
#define BW_BASE        0x100a0000UL
#define BW_SRC         (BW_BASE + 0x00)
#define BW_ROW_BLOCKS  (BW_BASE + 0x08)
#define BW_NROWS       (BW_BASE + 0x10)
#define BW_ROW_STRIDE  (BW_BASE + 0x18)
#define BW_MAXOUT      (BW_BASE + 0x20)
#define BW_GO          (BW_BASE + 0x28)
#define BW_STATUS      (BW_BASE + 0x30)
#define BW_CYCLES      (BW_BASE + 0x38)
#define BW_BEATS       (BW_BASE + 0x40)
#define BW_REQS        (BW_BASE + 0x48)
#define BW_CKSUM       (BW_BASE + 0x50)
#define BW_DENIED      (BW_BASE + 0x58)
#define BW_DEPTH       (BW_BASE + 0x60)

/* ---- BwWindow at 0x100C_0000 (chipyard/BwWindow.scala) ------------------------------------ */
#define WN_BASE        0x100c0000UL
#define WN_GO          (WN_BASE + 0x000)
#define WN_LANE_EN     (WN_BASE + 0x008)
#define WN_MAXOUT      (WN_BASE + 0x010)
#define WN_STATUS      (WN_BASE + 0x018)
#define WN_CYCLES      (WN_BASE + 0x020)
#define WN_BEATS       (WN_BASE + 0x028)
#define WN_REQS        (WN_BASE + 0x030)
#define WN_CKSUM       (WN_BASE + 0x038)
#define WN_DENIED      (WN_BASE + 0x040)
#define WN_PEAK        (WN_BASE + 0x048)
#define WN_GEOMETRY    (WN_BASE + 0x050)
#define WN_DBEATS      (WN_BASE + 0x058)
#define WN_LANE(i)     (WN_BASE + 0x100 + (uintptr_t)(i) * 0x40)

/* ---- the L2's control node --------------------------------------------------------------- */
#define L2_FLUSH64     (0x2010000UL + 0x200)

#define APERTURE_OFF   0x40000000UL       /* alias = physical - APERTURE_OFF */
#define BUF            0x81000000UL
#define BUF_SPAN       (4UL * 1024 * 1024)
#define WIN_BUF        0x82000000UL
#define WIN_SPAN       (16UL * 1024 * 1024)
#define AP_WBUF        0x83000000UL
#define COH_WBUF       0x84000000UL
#define CON_BUF        0x85000000UL
#define CON_SPAN       (256UL * 1024)
#define SPL_BUF        0x86000000UL
#define LINE           64UL

static inline void mmio_w(uintptr_t a, uint64_t v) { *(volatile uint64_t *)a = v; }
static inline uint64_t mmio_r(uintptr_t a) { return *(volatile uint64_t *)a; }
static inline void fence(void) { __asm__ volatile("fence" ::: "memory"); }
static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}
#define LOCAL_IRQ_LOCK()       arch_irq_lock()
#define LOCAL_IRQ_UNLOCK(k)    arch_irq_unlock(k)

static int fails;

static void l2_flush(uintptr_t base, uint64_t bytes)
{
	for (uint64_t off = 0; off < bytes; off += LINE) {
		mmio_w(L2_FLUSH64, (uint64_t)(base + off));
	}
	fence();
}

/* ---- the harts, Lab B6's method --------------------------------------------------------- */
static void core_rw(const char *level, uintptr_t buf, uint64_t size, int write, uint64_t target)
{
	uint64_t passes = target / size, c0, c1, moved = 0;
	volatile uint64_t sink = 0;
	unsigned int key;

	if (passes < 1) {
		passes = 1;
	}
	/* One untimed pass: the steady state, not the first touch. */
	if (write) {
		mb_write((void *)buf, size, 0x5a5a5a5a5a5a5a5aULL);
	} else {
		sink += mb_read((const void *)buf, size);
	}
	key = LOCAL_IRQ_LOCK();
	c0 = rdcycle();
	for (uint64_t i = 0; i < passes; i++) {
		if (write) {
			mb_write((void *)buf, size, 0xa5a5a5a5a5a5a5a5ULL ^ i);
		} else {
			sink += mb_read((const void *)buf, size);
		}
		moved += size;
	}
	c1 = rdcycle();
	LOCAL_IRQ_UNLOCK(key);
	printk("CORE level=%s bytes=%llu moved=%llu cycles=%llu bpc_x1000=%llu\n", level,
	       (unsigned long long)size, (unsigned long long)moved, (unsigned long long)(c1 - c0),
	       (unsigned long long)((moved * 1000ULL) / (c1 - c0)));
}

/* ---- BwProbe ------------------------------------------------------------------------------ */
static void probe_point(const char *level, uintptr_t src, uint64_t bytes, uint64_t reps, int out, uint64_t sw)
{
	uint64_t row_blocks = bytes / LINE, nrows = reps, stride = 0, st;

	while (row_blocks > 0xf000UL) {
		row_blocks /= 2;
		nrows *= 2;
		stride = row_blocks * LINE;
	}
	mmio_w(BW_SRC, src);
	mmio_w(BW_ROW_BLOCKS, row_blocks);
	mmio_w(BW_NROWS, nrows);
	mmio_w(BW_ROW_STRIDE, stride);
	mmio_w(BW_MAXOUT, (uint64_t)out);
	fence();
	mmio_w(BW_GO, 1);
	fence();
	do {
		st = mmio_r(BW_STATUS);
	} while (st & 1ULL);
	fence();
	uint64_t ck = mmio_r(BW_CKSUM);
	if (ck != sw) {
		fails++;
	}
	printk("PROBE level=%s bytes=%llu out=%d cycles=%llu beats=%llu reqs=%llu peak=%llu denied=%llu cksum_ok=%d\n",
	       level, (unsigned long long)bytes, out, (unsigned long long)mmio_r(BW_CYCLES),
	       (unsigned long long)mmio_r(BW_BEATS), (unsigned long long)mmio_r(BW_REQS),
	       (unsigned long long)((mmio_r(BW_STATUS) >> 9) & 0xffULL),
	       (unsigned long long)mmio_r(BW_DENIED), ck == sw ? 1 : 0);
}

static uint64_t xor_words(uintptr_t base, uint64_t bytes)
{
	uint64_t sw = 0;

	for (uint64_t i = 0; i < bytes / 8; i++) {
		sw ^= ((volatile uint64_t *)base)[i];
	}
	return sw;
}

static void calibration_and_l2(int with_probe)
{
	static const uint64_t sizes[] = { 4UL * 1024, 32UL * 1024, 4UL * 1024 * 1024 };
	static const char *levels[] = { "L1", "L2", "DRAM" };
	static const int outs[] = { 1, 2, 3, 4, 6, 8 };
	volatile uint64_t *p = (volatile uint64_t *)BUF;
	uint64_t lcg = 0x12345678u;

	for (uint64_t i = 0; i < BUF_SPAN / 8; i++) {
		lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
		p[i] = lcg;
	}
	fence();
	for (unsigned si = 0; si < ARRAY_SIZE(sizes); si++) {
		uint64_t size = sizes[si];
		uint64_t sw = xor_words(BUF, size);

		core_rw(levels[si], BUF, size, 0, 8UL * 1024 * 1024);
		if (!with_probe) {
			continue;
		}
		uint64_t reps = (4UL * 1024 * 1024) / size;

		if ((reps & 1) == 0) {
			reps += 1;
		}
		for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
			if (size > 64UL * 1024) {
				l2_flush(BUF, size);
				probe_point("DRAM", BUF, size, 1, outs[oi], sw);
			} else {
				probe_point("L2", BUF, size, 1, outs[oi], sw);    /* warm pass, then timed */
				probe_point("L2", BUF, size, reps, outs[oi], sw);
			}
		}
	}
}

/* ---- BwWindow ----------------------------------------------------------------------------- */
static uint64_t win_lane_sw[4], win_seq_sw;

static void win_prepare(uint64_t span, uint64_t rows)
{
	volatile uint64_t *q = (volatile uint64_t *)WIN_BUF;
	uint64_t lcg = 0x9e3779b97f4a7c15ULL ^ rdcycle();
	uint64_t c0, c1;

	for (uint64_t i = 0; i < span / 8; i++) {
		lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
		q[i] = lcg;
	}
	fence();
	/* The coherent write above left up to 64 KiB dirty in the L2: this is the hand-off (s9.4 rule 1). */
	c0 = rdcycle();
	l2_flush(WIN_BUF, span);
	c1 = rdcycle();
	printk("FLUSH level=FLUSH_AFTER_WRITE bytes=%llu blocks=%llu cycles=%llu\n", (unsigned long long)span,
	       (unsigned long long)(span / LINE), (unsigned long long)(c1 - c0));
	c0 = rdcycle();
	l2_flush(WIN_BUF, span);
	c1 = rdcycle();
	printk("FLUSH level=FLUSH_IDLE bytes=%llu blocks=%llu cycles=%llu\n", (unsigned long long)span,
	       (unsigned long long)(span / LINE), (unsigned long long)(c1 - c0));
	for (unsigned l = 0; l < 4; l++) {
		uint64_t sw = 0;

		for (uint64_t r = 0; r < rows; r++) {
			sw ^= xor_words(WIN_BUF + l * LINE + r * 4 * LINE, LINE);
		}
		win_lane_sw[l] = sw;
	}
	win_seq_sw = xor_words(WIN_BUF, span);
}

static void win_program_lane(unsigned l, uintptr_t src, uint64_t row_blocks, uint64_t nrows, uint64_t stride)
{
	mmio_w(WN_LANE(l) + 0x00, src);
	mmio_w(WN_LANE(l) + 0x08, row_blocks);
	mmio_w(WN_LANE(l) + 0x10, nrows);
	mmio_w(WN_LANE(l) + 0x18, stride);
}

/* Run the enabled lanes; returns 1 when the hardware checksum equals `sw`. */
static int win_run(const char *level, uint64_t bytes, uint64_t mask, int out, uint64_t sw, int print)
{
	uint64_t st;

	mmio_w(WN_MAXOUT, (uint64_t)out);
	mmio_w(WN_LANE_EN, mask);
	fence();
	mmio_w(WN_GO, 1);
	fence();
	do {
		st = mmio_r(WN_STATUS);
	} while (st & 1ULL);
	fence();
	uint64_t ck = mmio_r(WN_CKSUM);

	if (!print) {
		return ck == sw;
	}
	printk("PROBE level=%s bytes=%llu out=%d cycles=%llu beats=%llu reqs=%llu peak=%llu denied=%llu cksum_ok=%d\n",
	       level, (unsigned long long)bytes, out, (unsigned long long)mmio_r(WN_CYCLES),
	       (unsigned long long)mmio_r(WN_BEATS), (unsigned long long)mmio_r(WN_REQS),
	       (unsigned long long)(mmio_r(WN_PEAK) & 0xffULL), (unsigned long long)(mmio_r(WN_DENIED) & 0xffffffffULL),
	       ck == sw ? 1 : 0);
	printk("PROBEW level=%s bytes=%llu out=%d dbeats=%llu beat_bytes=%llu\n", level, (unsigned long long)bytes,
	       out, (unsigned long long)mmio_r(WN_DBEATS), (unsigned long long)((mmio_r(WN_GEOMETRY) >> 40) & 0xffULL));
	for (unsigned l = 0; l < 4; l++) {
		if (!(mask & (1ULL << l))) {
			continue;
		}
		printk("WINLANE level=%s out=%d lane=%u cycles=%llu beats=%llu reqs=%llu peak=%llu\n", level, out, l,
		       (unsigned long long)mmio_r(WN_LANE(l) + 0x20), (unsigned long long)mmio_r(WN_LANE(l) + 0x28),
		       (unsigned long long)mmio_r(WN_LANE(l) + 0x30),
		       (unsigned long long)(mmio_r(WN_LANE(l) + 0x38) & 0xffULL));
	}
	if (ck != sw) {
		fails++;
	}
	return ck == sw;
}

struct wset {
	const char *name;
	uint64_t mask;
	int seq;
};

static void win_point(const struct wset *s, int out, uint64_t span, uint64_t rows)
{
	uint64_t sw = 0, bytes = 0;

	for (unsigned l = 0; l < 4; l++) {
		if (s->seq && l == 0) {
			win_program_lane(0, WIN_BUF, 32768, span / (32768 * LINE), 32768 * LINE);
		} else {
			win_program_lane(l, WIN_BUF + l * LINE, 1, rows, 4 * LINE);
		}
		if (s->mask & (1ULL << l)) {
			sw ^= s->seq ? win_seq_sw : win_lane_sw[l];
			bytes += s->seq ? span : rows * LINE;
		}
	}
	win_run(s->name, bytes, s->mask, out, sw, 1);
}

/* ---- step 5: two lanes on one controller port, one region or two ------------------------------ */
static uint64_t spl_lane1_sw;

static void split_prepare(void)
{
	volatile uint64_t *q = (volatile uint64_t *)SPL_BUF;
	uint64_t lcg = 0x5851f42d4c957f2dULL ^ rdcycle(), sw = 0;

	for (uint64_t i = 0; i < WIN_SPAN / 8; i++) {
		lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
		q[i] = lcg;
	}
	fence();
	l2_flush(SPL_BUF, WIN_SPAN);
	for (uint64_t r = 0; r < 65535; r++) {
		sw ^= xor_words(SPL_BUF + 1 * LINE + r * 4 * LINE, LINE);
	}
	spl_lane1_sw = sw;
}

/* Lane 0 on WIN_BUF, lane 1 on WIN_BUF (striped) or on SPL_BUF (split).  Both lanes are channel 0 and 1:
 * HP0 and HP1, DDR controller port 3. */
static void split_point(const char *level, int split, int out)
{
	win_program_lane(0, WIN_BUF, 1, 65535, 4 * LINE);
	win_program_lane(1, (split ? SPL_BUF : WIN_BUF) + LINE, 1, 65535, 4 * LINE);
	win_run(level, 2 * 65535 * LINE, 0x3, out, win_lane_sw[0] ^ (split ? spl_lane1_sw : win_lane_sw[1]), 1);
}

/* ---- the coherence contract (s9.4) -------------------------------------------------------- */
static uint64_t pat(uint64_t seed, uint64_t i) { return seed ^ (i * 0x9E3779B97F4A7C15ULL) ^ (i << 32); }

static void con_write(uintptr_t base, uint64_t seed)
{
	volatile uint64_t *q = (volatile uint64_t *)base;

	for (uint64_t i = 0; i < CON_SPAN / 8; i++) {
		q[i] = pat(seed, i);
	}
	fence();
}

static uint64_t con_expect(uint64_t seed)
{
	uint64_t sw = 0;

	for (uint64_t i = 0; i < CON_SPAN / 8; i++) {
		sw ^= pat(seed, i);
	}
	return sw;
}

static void contract(const char *test, int expect_match, int got_match)
{
	int ok = expect_match == got_match;

	if (!ok) {
		fails++;
	}
	printk("CONTRACT test=%s expect=%s got=%s ok=%d\n", test, expect_match ? "match" : "mismatch",
	       got_match ? "match" : "mismatch", ok);
}

/* A DMA read of CON_BUF: lane 0, contiguous over all four channels, 8 in flight. */
static int con_lane_read(uint64_t seed)
{
	win_program_lane(0, CON_BUF, CON_SPAN / LINE, 1, 0);
	return win_run("CON", CON_SPAN, 1, 8, con_expect(seed), 0);
}

static void contract_checks(void)
{
	uint64_t s0 = rdcycle() * 0x2545F4914F6CDD1DULL, s1 = s0 ^ 0x1111, s2 = s0 ^ 0x2222, s3 = s0 ^ 0x3333;
	uintptr_t ap = CON_BUF - APERTURE_OFF;

	/* A run-unique baseline in DDR, written uncached, so no earlier run's bytes can pass for this run's. */
	l2_flush(CON_BUF, CON_SPAN);
	con_write(ap, s0);
	contract("C0_ap_write_dma_read", 1, con_lane_read(s0));
	/* Rule 1: a coherent write is not in DDR until it is flushed. */
	con_write(CON_BUF, s1);
	contract("C1_coh_write_noflush_dma_read", 0, con_lane_read(s1));
	l2_flush(CON_BUF, CON_SPAN);
	contract("C2_coh_write_flush_dma_read", 1, con_lane_read(s1));
	/* Partition: a write through the aperture is in DDR at once. */
	con_write(ap, s2);
	contract("C3_ap_write_dma_read", 1, con_lane_read(s2));
	contract("C3b_ap_write_coh_read", 1, xor_words(CON_BUF, CON_SPAN) == con_expect(s2));
	/* Rule 2: the caches now hold copies of s2; a DMA write does not reach them. */
	con_write(ap, s3);
	contract("C4_coh_cached_ap_write_noflush_coh_read", 0, xor_words(CON_BUF, CON_SPAN) == con_expect(s3));
	l2_flush(CON_BUF, CON_SPAN);
	contract("C5_coh_cached_ap_write_flush_coh_read", 1, xor_words(CON_BUF, CON_SPAN) == con_expect(s3));
}

int main(void)
{
	uint64_t depth, geo;

	printk("BWLAB start clock=%d\n", CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
	printk("BWWIN step=%d\n", BWWIN_STEP);
	depth = mmio_r(BW_DEPTH) & 0xffULL;
	geo = mmio_r(WN_GEOMETRY);
	printk("BWLAB probe depth=%llu window geometry=0x%llx\n", (unsigned long long)depth, (unsigned long long)geo);
	if (depth == 0 || depth > 16 || ((geo >> 32) & 0xff) != 0xB2 || ((geo >> 40) & 0xff) != 16 ||
	    ((geo >> 8) & 0xff) != 4) {
		printk("BWLAB FAIL: this is not the bwwin bitstream (BwProbe + a 4-lane 128-bit BwWindow)\n");
		printk("BWLAB done fails=1\n");
		return 0;
	}

	calibration_and_l2(BWWIN_STEP == 3);

	if (BWWIN_STEP == 1) {
		static const struct wset l0 = { "WIN_L0", 0x1, 0 };

		win_prepare(64UL * 1024, 256);
		win_point(&l0, 1, 64UL * 1024, 256);
	} else if (BWWIN_STEP == 2) {
		static const struct wset l0 = { "WIN_L0", 0x1, 0 };
		static const int outs[] = { 1, 2, 4, 8 };

		win_prepare(WIN_SPAN, 65535);
		for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
			win_point(&l0, outs[oi], WIN_SPAN, 65535);
		}
	} else if (BWWIN_STEP == 3) {
		static const struct wset sets[] = {
			{ "WIN_L0", 0x1, 0 }, { "WIN_L2", 0x4, 0 }, { "WIN_L01", 0x3, 0 },
			{ "WIN_L012", 0x7, 0 }, { "WIN_L0123", 0xf, 0 }, { "WIN_SEQ", 0x1, 1 },
		};
		static const int outs[] = { 1, 2, 3, 4, 5, 6, 8 };

		win_prepare(WIN_SPAN, 65535);
		for (unsigned si = 0; si < ARRAY_SIZE(sets); si++) {
			for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
				win_point(&sets[si], outs[oi], WIN_SPAN, 65535);
			}
		}
	} else if (BWWIN_STEP == 4) {
		static const int outs[] = { 1, 2, 3, 4, 6, 8 };
		uint64_t sw = xor_words(BUF, BUF_SPAN);

		/* BwProbe through the aperture first, then the harts. */
		l2_flush(BUF, BUF_SPAN);
		for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
			probe_point("AP_PROBE", BUF - APERTURE_OFF, BUF_SPAN, 1, outs[oi], sw);
		}
		core_rw("AP_DRAM", BUF - APERTURE_OFF, BUF_SPAN, 0, BUF_SPAN);
		core_rw("AP_DRAMW", AP_WBUF - APERTURE_OFF, BUF_SPAN, 1, BUF_SPAN);
		core_rw("DRAMW", COH_WBUF, BUF_SPAN, 1, 8UL * 1024 * 1024);
		contract_checks();
	} else if (BWWIN_STEP == 5) {
		static const int outs[] = { 1, 2, 4, 8 };

		win_prepare(WIN_SPAN, 65535);
		split_prepare();
		for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
			split_point("WIN_L01", 0, outs[oi]);
			split_point("WIN_L01_SPLIT", 1, outs[oi]);
		}
	}
	printk("BWLAB done fails=%d\n", fails);
	return 0;
}
