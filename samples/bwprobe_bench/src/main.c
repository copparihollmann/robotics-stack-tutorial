/* SPDX-License-Identifier: Apache-2.0
 *
 * The memory port, measured two ways on one bitstream in one session.
 *
 * WHY BOTH HALVES ARE IN ONE IMAGE.  The claim this lab exists to test is that a TileLink
 * client issuing cache-block Gets with several in flight beats what a hart can do, on the
 * same memory system.  Quoting Lab B6's 1.34 B/cycle -- measured on a different bitstream,
 * at a different clock, months of edits ago -- and comparing it with a number from this
 * one would be comparing two machines.  So this image measures BOTH:
 *
 *   (a) the CORE's streaming read, using samples/membench's own `mb_read` assembly
 *       kernel, unchanged, so the method is the one that produced the 1.34;
 *   (b) the INSTRUMENT's read of the same buffer, at 1..8 transactions in flight.
 *
 * and the falsification test is the bottom of the sweep, not the top: at ONE transaction
 * in flight the instrument should land near the core's own DRAM figure, because a
 * single-outstanding 64-byte read is what a blocking D-cache already does.  If it does
 * not, the model in ROCC_DECOUPLED.md section 4.4 is wrong and nothing above one
 * outstanding means anything.
 *
 * THE CHECKSUM IS THE POINT OF THE EXERCISE, NOT DECORATION.  An engine that returns
 * beats quickly without returning the right bytes is not a bandwidth measurement.  The
 * hardware XORs every 64-bit word the D channel delivers; this code XORs the same region
 * with ordinary loads and compares.  Every reported row carries that verdict.
 *
 * WHAT THE INSTRUMENT CANNOT MEASURE.  It has no L1, so its fastest reachable level is
 * the L2.  The core half covers L1, L2 and DRAM; the instrument half covers L2 and DRAM.
 * That asymmetry is real and is reported rather than papered over.
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <string.h>

/* samples/membench/src/kernels.S -- the same unrolled loop Lab B6 measured with. */
uint64_t mb_read(const void *base, uint64_t bytes);

/* ---- the instrument, at 0x100A_0000 (chipyard.bwprobe, SubsystemInjector) ---------- */
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
/* Only on a build whose system bus is wider than 64 bits (MEMORY_BANDWIDTH.md section 5).
 * Unmapped offsets of the register node read as 0, so every other bitstream answers
 * BEAT_BYTES = 0 and this image prints exactly what it always did there. */
#define BW_DBEATS      (BW_BASE + 0x68)
#define BW_BEATBYTES   (BW_BASE + 0x70)

/* SiFive InclusiveCache control node, as samples/membench uses it. */
#define L2_CTRL_BASE   0x2010000UL
#define L2_FLUSH64     (L2_CTRL_BASE + 0x200)

/* Where the working set lives, in Rocket's address space.  Same choice membench makes
 * and for the same reason: far above the image, its BSS and every stack. */
#define BUF            0x81000000UL
#define BUF_SPAN       (4UL * 1024 * 1024)
#define LINE           64UL

static inline void mmio_w(uintptr_t a, uint64_t v)
{
	*(volatile uint64_t *)a = v;
}

static inline uint64_t mmio_r(uintptr_t a)
{
	return *(volatile uint64_t *)a;
}

static inline void fence(void)
{
	__asm__ volatile("fence" ::: "memory");
}

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/* The one thing that must not be irq_lock(): under CONFIG_SMP that is a GLOBAL lock and
 * it stops the other hart too, which is how Lab B6's first version measured a flawless
 * 100 % scaling of two harts politely taking turns. */
#define LOCAL_IRQ_LOCK()       arch_irq_lock()
#define LOCAL_IRQ_UNLOCK(k)    arch_irq_unlock(k)

static void l2_flush(uintptr_t base, uint64_t bytes)
{
	for (uint64_t off = 0; off < bytes; off += LINE) {
		mmio_w(L2_FLUSH64, (uint64_t)(base + off));
	}
	fence();
}

/* ---- the core's own streaming read, Lab B6's method ------------------------------- */
static uint64_t core_read_bpc_x1000(uintptr_t buf, uint64_t size, uint64_t *bytes_out,
				    uint64_t *cycles_out)
{
	/* Enough passes that the window is tens of milliseconds at any size. */
	const uint64_t target = 8UL * 1024 * 1024;
	uint64_t passes = target / size;
	uint64_t c0, c1, moved = 0;
	volatile uint64_t sink = 0;
	unsigned int key;

	if (passes < 1) {
		passes = 1;
	}
	/* One untimed pass so the measurement is of the steady state, not of the first
	 * touch: for the L1 and L2 points the first pass is all misses. */
	sink += mb_read((const void *)buf, size);

	key = LOCAL_IRQ_LOCK();
	c0 = rdcycle();
	for (uint64_t i = 0; i < passes; i++) {
		sink += mb_read((const void *)buf, size);
		moved += size;
	}
	c1 = rdcycle();
	LOCAL_IRQ_UNLOCK(key);

	*bytes_out = moved;
	*cycles_out = c1 - c0;
	return (moved * 1000ULL) / (c1 - c0);
}

/* ---- one instrument run ------------------------------------------------------------ */
struct bwrun {
	uint64_t cycles, beats, reqs, cksum, peak, denied;
	uint64_t dbeats, beat_bytes;      /* 0 unless the system bus is wide */
};

/* The width proof, on a wide build only.  BEATS counts 64-bit WORDS on every bitstream,
 * so bytes = 8 * BEATS everywhere; DBEATS counts TileLink D beats and REQS counts 64-byte
 * Gets, independently, so REQS * 64 / DBEATS is the bytes each beat carried -- and the
 * checksum says they were the right bytes. */
static void probe_width(const char *lvl, uint64_t size, int out, const struct bwrun *r)
{
	if (r->beat_bytes == 0) {
		return;
	}
	printk("PROBEW level=%s bytes=%llu out=%d dbeats=%llu beat_bytes=%llu\n",
	       lvl, (unsigned long long)size, out, (unsigned long long)r->dbeats,
	       (unsigned long long)r->beat_bytes);
}

/* `reps` re-reads the SAME region, by leaving row_stride at zero and letting the engine's
 * own 2-D descriptor walk nrows rows that all start at the same address.
 *
 * It exists because a 32 KiB L2-resident run is only 4,096 beats -- a few hundred cycles
 * -- and the fixed cost of starting and draining the engine would be a visible fraction
 * of that.  Repeating to about 4 MiB of traffic puts the start-up cost below a tenth of a
 * percent, and an L2-resident region stays L2-resident however many times it is read.
 *
 * REPS MUST BE ODD.  The hardware checksum is an XOR, which is self-inverse, so an even
 * number of passes over the same data checksums to ZERO -- which would look exactly like
 * a bus returning nothing, and would look like it CONSISTENTLY.  That is the sort of
 * self-check that silently stops checking. */
static void probe_go(uintptr_t buf, uint64_t row_blocks, uint64_t nrows, uint64_t stride,
		     int maxout, struct bwrun *r)
{
	uint64_t st;

	mmio_w(BW_SRC, (uint64_t)buf);
	mmio_w(BW_ROW_BLOCKS, row_blocks);
	mmio_w(BW_NROWS, nrows);
	mmio_w(BW_ROW_STRIDE, stride);
	mmio_w(BW_MAXOUT, (uint64_t)maxout);
	fence();
	mmio_w(BW_GO, 1);
	fence();
	do {
		st = mmio_r(BW_STATUS);
	} while (st & 1ULL);
	fence();

	r->cycles = mmio_r(BW_CYCLES);
	r->beats  = mmio_r(BW_BEATS);
	r->reqs   = mmio_r(BW_REQS);
	r->cksum  = mmio_r(BW_CKSUM);
	r->peak   = (mmio_r(BW_STATUS) >> 9) & 0xffULL;
	r->denied = mmio_r(BW_DENIED);
	r->dbeats = mmio_r(BW_DBEATS);
	r->beat_bytes = mmio_r(BW_BEATBYTES) & 0xffULL;
}

static void probe_run(uintptr_t buf, uint64_t bytes, uint64_t reps, int maxout,
		      struct bwrun *r)
{
	uint64_t row_blocks = bytes / LINE;
	uint64_t nrows = reps;
	uint64_t stride = 0;

	/* row_blocks is 16 bits, so a single pass longer than ~61,000 blocks is expressed
	 * as rows with a stride equal to the row length -- the same contiguous stream. */
	while (row_blocks > 0xf000UL) {
		row_blocks /= 2;
		nrows *= 2;
		stride = row_blocks * LINE;
	}
	probe_go(buf, row_blocks, nrows, stride, maxout, r);
}

#ifdef BWLAB_CHANNELS
/* ---- the same DRAM, read so that the CHANNEL is the only thing that changes ------------
 *
 * WithNMemoryChannels(2) does not split ExtMem into halves.  rocket-chip's Ports.scala
 * gives channel c the address set AddressSet(c * blockBytes, ~((n-1) * blockBytes)), and
 * the mbus blockBytes is CacheBlockBytes = 64.  The elaborated crossbar says the same
 * thing in gates (TLXbar_mbus_i1_o3: requestAIO_0_0 is address[31] & ~address[6]):
 * channel 0 owns every 64-byte block whose bit 6 is 0, channel 1 every block whose bit 6
 * is 1.  So the sequential DRAM read above ALREADY alternates channels on every refill.
 *
 * What it cannot do is say whether a difference at two ports is the second port or
 * something else about the bitstream.  These two shapes can, because they differ only in
 * which channels they touch:
 *
 *   DRAM_1CH  one block every 128 bytes: bit 6 of every address is 0 -> channel 0 only
 *   DRAM_2CH  one block every 192 bytes: bit 6 is the row's parity  -> alternating
 *
 * Both skip blocks, both are all L2 misses (flushed first, every block distinct, and the
 * 1,000-block L2 fills and evicts as it does for the sequential read).  On a one-port
 * bitstream both land on the same channel and should measure the same; if the port binds,
 * DRAM_2CH pulls away from DRAM_1CH on the two-port bitstream and DRAM_1CH does not move. */
struct chshape {
	const char *name;
	uint64_t stride;
	uint64_t sw;
};

static struct chshape chshapes[] = {
	{ "DRAM_1CH", 128, 0 },
	{ "DRAM_2CH", 192, 0 },
};

static uint64_t chshape_rows(const struct chshape *c)
{
	return (BUF_SPAN - LINE) / c->stride + 1;   /* the last block ends inside BUF_SPAN */
}

static void chshape_checksums(void)
{
	for (unsigned i = 0; i < ARRAY_SIZE(chshapes); i++) {
		uint64_t sw = 0;

		for (uint64_t row = 0; row < chshape_rows(&chshapes[i]); row++) {
			volatile uint64_t *q = (volatile uint64_t *)
				(BUF + row * chshapes[i].stride);

			for (uint64_t w = 0; w < LINE / 8; w++) {
				sw ^= q[w];
			}
		}
		chshapes[i].sw = sw;
	}
}
#endif

#ifdef BWLAB_BYPASS
/* ---- THE BYPASS (MEMORY_BANDWIDTH.md section 8): the instrument on the MEMORY bus ---------
 *
 * chipyard/BwBypass.scala at 0x100B_0000: LANES independent TileLink clients on the mbus,
 * each an mbxd_dma engine with its own D channel, started by one GO, no L2 in the path.  The
 * bitstream has as many memory channels as the instrument has lanes, and channel c owns the
 * 64-byte blocks whose address bits [log2(LANES)+5 : 6] equal c.  A lane that reads one
 * block every 64*LANES bytes starting at BYP_BUF + c*64 therefore talks to one channel: c.
 * Which ports are in use is this code's choice, per point.
 *
 * LEVELS NAME LANES, NOT PORTS.  Which HP port channel c reaches is a property of the
 * bitstream's top level, not of this code: on 0x5A5A0015 channel 1 is S_AXI_HP2, on
 * 0x5A5A0016 it is S_AXI_HP1.  scripts/48_rocket_bwbypass_lab.sh maps lanes to ports per
 * variant and records the port set on every row.
 *
 * TWO lanes:  BYP_L0 (lane 0 alone), BYP_L1 (lane 1 alone), BYP_L01 (both),
 *             BYP_SEQ (lane 0 reading contiguous blocks: both channels behind ONE D channel)
 * FOUR lanes: BYP_L0, BYP_L2, BYP_L01, BYP_L02, BYP_L0123, BYP_SEQ
 *
 * CYCLES is the union of the lanes' busy windows in MEMORY-BUS cycles (FCLK1 on this
 * config): bytes/CYCLES is the lanes' bandwidth together, and MB/s needs the READ-BACK
 * FCLK1, which the lab records.
 *
 * COHERENCE.  The region is written by the core THROUGH the L2 and then flushed through the
 * L2's control node, so every block is in DDR before a lane reads it.  The per-lane software
 * checksums are core reads, which leave clean copies in the L2 and change nothing in DDR. */
#define BYP_BASE        0x100b0000UL
#define BYP_GO          (BYP_BASE + 0x000)
#define BYP_LANE_EN     (BYP_BASE + 0x008)
#define BYP_MAXOUT      (BYP_BASE + 0x010)
#define BYP_STATUS      (BYP_BASE + 0x018)
#define BYP_CYCLES      (BYP_BASE + 0x020)
#define BYP_BEATS       (BYP_BASE + 0x028)
#define BYP_REQS        (BYP_BASE + 0x030)
#define BYP_CKSUM       (BYP_BASE + 0x038)
#define BYP_DENIED      (BYP_BASE + 0x040)
#define BYP_PEAK        (BYP_BASE + 0x048)
#define BYP_GEOMETRY    (BYP_BASE + 0x050)
#define BYP_LANE(i)     (BYP_BASE + 0x100 + (uintptr_t)(i) * 0x40)

#define BYP_BUF         0x82000000UL
#define BYP_SPAN        (16UL * 1024 * 1024)
#define BYP_ROWS        65535UL               /* nrows is 16 bits; 65535 x 256 < BYP_SPAN */
#define BYP_SEQ_BLOCKS  32768UL               /* row_blocks is 16 bits: 2 MiB rows ... */
#define BYP_SEQ_ROWS    8UL                   /* ... x 8 = the whole 16 MiB, contiguous */

static uint64_t byp_lane_sw[8];
static uint64_t byp_seq_sw;

static void bypass_prepare(unsigned lanes, uint64_t stride)
{
	volatile uint64_t *q = (volatile uint64_t *)BYP_BUF;
	uint64_t lcg = 0x9e3779b97f4a7c15ULL;

	for (uint64_t i = 0; i < BYP_SPAN / 8; i++) {
		lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
		q[i] = lcg;
	}
	fence();
	/* Every dirty block to DDR before anything reads DDR directly. */
	l2_flush(BYP_BUF, BYP_SPAN);

	for (unsigned l = 0; l < lanes && l < ARRAY_SIZE(byp_lane_sw); l++) {
		uint64_t sw = 0;

		for (uint64_t row = 0; row < BYP_ROWS; row++) {
			volatile uint64_t *b = (volatile uint64_t *)(BYP_BUF + l * LINE + row * stride);

			for (uint64_t w = 0; w < LINE / 8; w++) {
				sw ^= b[w];
			}
		}
		byp_lane_sw[l] = sw;
	}
	byp_seq_sw = 0;
	for (uint64_t i = 0; i < BYP_SPAN / 8; i++) {
		byp_seq_sw ^= q[i];
	}
}

static void bypass_point(const char *name, uint64_t mask, int seq, int maxout, unsigned lanes,
			 uint64_t stride)
{
	uint64_t sw = 0, st, cycles, beats, reqs, cksum, denied, peak;

	for (unsigned l = 0; l < lanes; l++) {
		if (seq && l == 0) {
			mmio_w(BYP_LANE(l) + 0x00, BYP_BUF);
			mmio_w(BYP_LANE(l) + 0x08, BYP_SEQ_BLOCKS);
			mmio_w(BYP_LANE(l) + 0x10, BYP_SEQ_ROWS);
			mmio_w(BYP_LANE(l) + 0x18, BYP_SEQ_BLOCKS * LINE);
		} else {
			mmio_w(BYP_LANE(l) + 0x00, BYP_BUF + l * LINE);
			mmio_w(BYP_LANE(l) + 0x08, 1);
			mmio_w(BYP_LANE(l) + 0x10, BYP_ROWS);
			mmio_w(BYP_LANE(l) + 0x18, stride);
		}
		if (mask & (1ULL << l)) {
			sw ^= seq ? byp_seq_sw : byp_lane_sw[l];
		}
	}
	mmio_w(BYP_MAXOUT, (uint64_t)maxout);
	mmio_w(BYP_LANE_EN, mask);
	fence();
	mmio_w(BYP_GO, 1);
	fence();
	do {
		st = mmio_r(BYP_STATUS);
	} while (st & 1ULL);
	fence();

	cycles = mmio_r(BYP_CYCLES);
	beats  = mmio_r(BYP_BEATS);
	reqs   = mmio_r(BYP_REQS);
	cksum  = mmio_r(BYP_CKSUM);
	denied = mmio_r(BYP_DENIED) & 0xffffffffULL;
	peak   = mmio_r(BYP_PEAK) & 0xffULL;

	printk("PROBE level=%s bytes=%llu out=%d cycles=%llu beats=%llu reqs=%llu peak=%llu "
	       "denied=%llu cksum_ok=%d\n",
	       name, (unsigned long long)BYP_SPAN, maxout, (unsigned long long)cycles,
	       (unsigned long long)beats, (unsigned long long)reqs, (unsigned long long)peak,
	       (unsigned long long)denied, (cksum == sw) ? 1 : 0);
	for (unsigned l = 0; l < lanes; l++) {
		if (!(mask & (1ULL << l))) {
			continue;
		}
		printk("BYPLANE level=%s out=%d lane=%u cycles=%llu beats=%llu reqs=%llu peak=%llu\n",
		       name, maxout, l,
		       (unsigned long long)mmio_r(BYP_LANE(l) + 0x20),
		       (unsigned long long)mmio_r(BYP_LANE(l) + 0x28),
		       (unsigned long long)mmio_r(BYP_LANE(l) + 0x30),
		       (unsigned long long)(mmio_r(BYP_LANE(l) + 0x38) & 0xffULL));
	}
}

struct byp_set {
	const char *name;
	uint64_t mask;
	int seq;
};

static void bypass_sweep(void)
{
	static const int bouts[] = { 1, 2, 3, 4, 6, 8, 12, 16 };
	static const struct byp_set sets2[] = {
		{ "BYP_L0",    0x1, 0 },
		{ "BYP_L1",    0x2, 0 },
		{ "BYP_L01",   0x3, 0 },
		{ "BYP_SEQ",   0x1, 1 },
	};
	/* Four lanes: single, pairs on one and on two DDR controller ports, three lanes both ways
	 * round (2+1 and 1+2 across the controller ports), all four (MEMORY_BANDWIDTH.md s8.9). */
	static const struct byp_set sets4[] = {
		{ "BYP_L0",    0x1, 0 },
		{ "BYP_L2",    0x4, 0 },
		{ "BYP_L01",   0x3, 0 },
		{ "BYP_L23",   0xc, 0 },
		{ "BYP_L02",   0x5, 0 },
		{ "BYP_L012",  0x7, 0 },
		{ "BYP_L023",  0xd, 0 },
		{ "BYP_L0123", 0xf, 0 },
		{ "BYP_SEQ",   0x1, 1 },
	};
	uint64_t geo = mmio_r(BYP_GEOMETRY);
	unsigned depth = geo & 0xff, lanes = (geo >> 8) & 0xff;
	unsigned get = (geo >> 16) & 0xffff;
	const struct byp_set *sets = (lanes == 4) ? sets4 : sets2;
	unsigned nsets = (lanes == 4) ? ARRAY_SIZE(sets4) : ARRAY_SIZE(sets2);
	const uint64_t stride = LINE * lanes;

	printk("BYPASS geometry=0x%llx depth=%u lanes=%u get_bytes=%u stride=%llu\n",
	       (unsigned long long)geo, depth, lanes, get, (unsigned long long)stride);
	if (((geo >> 32) & 0xff) != 0xB1 || !(lanes == 2 || lanes == 4) || get != 64) {
		printk("BWLAB FAIL: no 2- or 4-lane 64-byte bypass instrument at 0x%lx\n",
		       (unsigned long)BYP_BASE);
		return;
	}
	bypass_prepare(lanes, stride);
	for (unsigned si = 0; si < nsets; si++) {
		for (unsigned oi = 0; oi < ARRAY_SIZE(bouts); oi++) {
			if ((unsigned)bouts[oi] > depth) {
				continue;
			}
			bypass_point(sets[si].name, sets[si].mask, sets[si].seq, bouts[oi], lanes,
				     stride);
		}
	}
}
#endif

#ifdef BWLAB_WRITER
/* ---- WRITE AND VERIFY THROUGH THE L2 WHILE THE MISS STREAM SATURATES ------------------
 *
 * MEMORY_BANDWIDTH.md section 6.8.  A model of the L2 showed that changing how the L2 and its
 * cork schedule evictions can starve a CORE's write -- the ReleaseAck-first cork stalled a
 * Put for 6,640 cycles behind a saturating miss stream -- so a fix that only reads well is
 * not yet a fix.  This is the silicon counterpart of that test:
 *
 *   hart 1: an endless write-and-verify loop over WSPAN of DRAM in 64-byte lines, with a
 *           pattern that changes every pass.  WSPAN is 16x the 64 KiB L2, so nearly every
 *           eviction the writes cause is DIRTY (ReleaseData -> Put).  Each line's eight
 *           stores are timed with rdcycle; every pass is read back and compared.
 *   hart 0: a QUIET window (the writer alone), then the instrument's DRAM read at 4 and 8
 *           in flight while the writer keeps running.
 *
 * Per window the writer reports lines, the max and a log2 histogram of per-line cycles (so a
 * p99.9 bound can be read), how many lines took over 1,000 cycles, and every mismatch.
 * Built only with EXTRA_CFLAGS=-DBWLAB_WRITER=1 (scripts/45_rocket_bwl2lab.sh --writer); every
 * other build of this sample is unchanged. */
#define WBUF   0x82000000UL
#define WSPAN  (1024UL * 1024UL)
#define WBINS  24

struct wstats {
	uint64_t lines, max, over1k, bad, passes;
	uint64_t hist[WBINS];
};

static struct wstats wst;
static volatile int writer_stop;
static volatile int writer_reset;

K_THREAD_STACK_DEFINE(writer_stack, 2048);
static struct k_thread writer_thread;

static void writer_fn(void *a, void *b, void *c)
{
	uint64_t pass = 0;

	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);
	while (!writer_stop) {
		uint64_t key = 0x9e3779b97f4a7c15ULL * (pass + 1);

		for (uint64_t off = 0; off < WSPAN && !writer_stop; off += LINE) {
			volatile uint64_t *q = (volatile uint64_t *)(WBUF + off);
			uint64_t t0 = rdcycle(), lat;
			unsigned int bin = 0;

			for (unsigned int k = 0; k < 8; k++) {
				q[k] = key ^ (off + k);
			}
			lat = rdcycle() - t0;
			if (writer_reset) {
				memset(&wst, 0, sizeof(wst));
				writer_reset = 0;
			}
			while ((bin + 1) < WBINS && (1ULL << (bin + 1)) <= lat) {
				bin++;
			}
			wst.hist[bin]++;
			wst.lines++;
			if (lat > wst.max) {
				wst.max = lat;
			}
			if (lat > 1000) {
				wst.over1k++;
			}
		}
		if (writer_stop) {
			break;
		}
		for (uint64_t off = 0; off < WSPAN; off += LINE) {
			volatile uint64_t *q = (volatile uint64_t *)(WBUF + off);

			for (unsigned int k = 0; k < 8; k++) {
				if (q[k] != (key ^ (off + k))) {
					wst.bad++;
				}
			}
		}
		wst.passes++;
		pass++;
	}
}

static void writer_report(const char *phase)
{
	struct wstats s = wst;   /* a snapshot; the writer keeps running */
	uint64_t acc = 0, p999 = 0;

	for (unsigned int i = 0; i < WBINS; i++) {
		acc += s.hist[i];
		if (p999 == 0 && s.lines && acc * 1000 >= s.lines * 999) {
			p999 = 1ULL << (i + 1);   /* upper edge of the bin */
		}
	}
	printk("WRITER phase=%s lines=%llu passes=%llu max=%llu p999_le=%llu over1k=%llu bad=%llu\n",
	       phase, (unsigned long long)s.lines, (unsigned long long)s.passes,
	       (unsigned long long)s.max, (unsigned long long)p999,
	       (unsigned long long)s.over1k, (unsigned long long)s.bad);
}

int main(void)
{
	volatile uint64_t *p = (volatile uint64_t *)BUF;
	uint64_t lcg = 0x12345678u, sw = 0, depth;
	static const int wouts[] = { 4, 8 };
	k_tid_t tid;

	printk("BWLAB start clock=%d writer=1\n", CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
	depth = mmio_r(BW_DEPTH) & 0xffULL;
	if (depth == 0 || depth > 16) {
		printk("BWLAB FAIL: no bandwidth instrument\nBWLAB done fails=1\n");
		return 0;
	}
	for (uint64_t i = 0; i < BUF_SPAN / 8; i++) {
		lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
		p[i] = lcg;
		sw ^= lcg;
	}
	fence();

	/* CALIBRATION FIRST, as on every image of this sample: the core's own L1/L2/DRAM reads
	 * (Lab B6), before the writer starts.  scripts/43 refuses a console without them, and the
	 * first 001A writer run (2026-09-17 07:21) was refused for exactly that. */
	{
		static const uint64_t csizes[] = { 4UL * 1024, 32UL * 1024, 4UL * 1024 * 1024 };
		static const char *clevels[] = { "L1", "L2", "DRAM" };

		for (unsigned si = 0; si < ARRAY_SIZE(csizes); si++) {
			uint64_t bytes = 0, cycles = 0;
			uint64_t bpc = core_read_bpc_x1000(BUF, csizes[si], &bytes, &cycles);

			printk("CORE level=%s bytes=%llu moved=%llu cycles=%llu bpc_x1000=%llu\n",
			       clevels[si], (unsigned long long)csizes[si], (unsigned long long)bytes,
			       (unsigned long long)cycles, (unsigned long long)bpc);
		}
	}

	tid = k_thread_create(&writer_thread, writer_stack, K_THREAD_STACK_SIZEOF(writer_stack),
			      writer_fn, NULL, NULL, NULL, 5, 0, K_FOREVER);
	if (k_thread_cpu_pin(tid, 1) != 0) {
		printk("BWLAB FAIL: could not pin the writer to hart 1\nBWLAB done fails=1\n");
		return 0;
	}
	k_thread_start(tid);

	/* QUIET: the writer alone, for about as long as one instrument run takes. */
	writer_reset = 1;
	for (uint64_t t0 = rdcycle(); rdcycle() - t0 < 700000ULL;) {
	}
	writer_report("quiet");

	for (unsigned int oi = 0; oi < ARRAY_SIZE(wouts); oi++) {
		struct bwrun r;

		l2_flush(BUF, BUF_SPAN);
		writer_reset = 1;
		probe_run(BUF, BUF_SPAN, 1, wouts[oi], &r);
		printk("PROBE level=DRAMW bytes=%llu out=%d cycles=%llu beats=%llu reqs=%llu peak=%llu "
		       "denied=%llu cksum_ok=%d\n",
		       (unsigned long long)BUF_SPAN, wouts[oi], (unsigned long long)r.cycles,
		       (unsigned long long)r.beats, (unsigned long long)r.reqs,
		       (unsigned long long)r.peak, (unsigned long long)r.denied,
		       (r.cksum == sw) ? 1 : 0);
		writer_report(wouts[oi] == 4 ? "probe4" : "probe8");
	}

	writer_stop = 1;
	k_thread_join(tid, K_SECONDS(60));
	writer_report("final");
	printk("BWLAB done fails=%d\n", wst.bad ? 1 : 0);
	return 0;
}
#else
int main(void)
{
	volatile uint64_t *p = (volatile uint64_t *)BUF;
	uint64_t depth, lcg = 0x12345678u;
	static const uint64_t sizes[] = {
		4UL * 1024, 32UL * 1024, 4UL * 1024 * 1024
	};
	static const char *levels[] = { "L1", "L2", "DRAM" };
	static const int outs[] = { 1, 2, 3, 4, 6, 8 };

	printk("BWLAB start clock=%d\n", CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);

	depth = mmio_r(BW_DEPTH) & 0xffULL;
	printk("BWLAB probe depth=%llu\n", (unsigned long long)depth);
	if (depth == 0 || depth > 16) {
		printk("BWLAB FAIL: no bandwidth instrument at 0x%lx (read %llu)\n",
		       (unsigned long)BW_BASE, (unsigned long long)depth);
		printk("BWLAB done fails=1\n");
		return 0;
	}

	/* A pattern the checksum can distinguish from zeros, from the previous run's
	 * pattern, and from a stuck bus. */
	for (uint64_t i = 0; i < BUF_SPAN / 8; i++) {
		lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
		p[i] = lcg;
	}
	fence();

	printk("%-6s %10s %6s %12s %12s %10s %8s %8s %6s %s\n",
	       "level", "bytes", "out", "cycles", "beats", "B/cycle", "reqs", "peak",
	       "denied", "cksum");

	for (unsigned si = 0; si < ARRAY_SIZE(sizes); si++) {
		const uint64_t size = sizes[si];
		uint64_t sw = 0, bytes = 0, cycles = 0, bpc;

		/* The software checksum of exactly the region the instrument will read. */
		for (uint64_t i = 0; i < size / 8; i++) {
			sw ^= p[i];
		}

		/* ---- the core, for calibration -------------------------------------- */
		bpc = core_read_bpc_x1000(BUF, size, &bytes, &cycles);
		printk("CORE level=%s bytes=%llu moved=%llu cycles=%llu bpc_x1000=%llu\n",
		       levels[si], (unsigned long long)size,
		       (unsigned long long)bytes, (unsigned long long)cycles,
		       (unsigned long long)bpc);

		/* ---- the instrument -------------------------------------------------- */
		/* Enough repeats to move about 4 MiB however small the region is, and an ODD
		 * count so the XOR checksum still equals the software one. */
		uint64_t reps = (4UL * 1024 * 1024) / size;

		if (reps < 1) {
			reps = 1;
		}
		if ((reps & 1) == 0) {
			reps += 1;
		}

		for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
			struct bwrun r;
			const char *lvl;

			/* For the two small sizes the core pass above has just pulled the
			 * region into the L2, and one untimed instrument pass makes sure of
			 * it; those points are L2 hits.  4 MiB is 64x the L2, so it is DRAM
			 * however it is warmed, and the flush only makes that explicit. */
			if (size > 64UL * 1024) {
				l2_flush(BUF, size);
				lvl = "DRAM";
			} else {
				probe_run(BUF, size, reps, outs[oi], &r);
				lvl = "L2";
			}

			probe_run(BUF, size, reps, outs[oi], &r);

			printk("%-6s %10llu %6d %12llu %12llu %6llu.%03llu %8llu %8llu "
			       "%6llu %s\n",
			       lvl, (unsigned long long)size, outs[oi],
			       (unsigned long long)r.cycles, (unsigned long long)r.beats,
			       (unsigned long long)((r.beats * 8ULL) / r.cycles),
			       (unsigned long long)(((r.beats * 8000ULL) / r.cycles) % 1000),
			       (unsigned long long)r.reqs, (unsigned long long)r.peak,
			       (unsigned long long)r.denied,
			       (r.cksum == sw) ? "ok" : "MISMATCH");
			printk("PROBE level=%s bytes=%llu out=%d cycles=%llu beats=%llu "
			       "reqs=%llu peak=%llu denied=%llu cksum_ok=%d\n",
			       lvl, (unsigned long long)size, outs[oi],
			       (unsigned long long)r.cycles, (unsigned long long)r.beats,
			       (unsigned long long)r.reqs, (unsigned long long)r.peak,
			       (unsigned long long)r.denied, (r.cksum == sw) ? 1 : 0);
			probe_width(lvl, size, outs[oi], &r);
		}
	}

#ifdef BWLAB_MID_KB
	/* L2 CAPACITY (MEMORY_BANDWIDTH.md section 6).  One more working set, BWLAB_MID_KB KiB,
	 * chosen to sit BETWEEN the lever-1 L2 (64 KiB) and a larger one: on a 64 KiB L2 it
	 * thrashes, on a 256 KiB L2 it is resident.  Every point flushes the region, gives it
	 * one untimed pass to pull it in, and then times reps passes -- so a cache that holds
	 * it reports hits and one that does not reports its miss path.  Level L2MID.
	 *
	 * Built only with EXTRA_CFLAGS=-DBWLAB_MID_KB=<n> (scripts/45_rocket_bwl2lab.sh
	 * --mid-kb): every other run of this lab produces exactly the rows it did. */
	{
		const uint64_t size = (uint64_t)BWLAB_MID_KB * 1024UL;
		uint64_t sw = 0, bytes = 0, cycles = 0, bpc;
		uint64_t reps = (4UL * 1024 * 1024) / size;

		if (reps < 1) {
			reps = 1;
		}
		if ((reps & 1) == 0) {
			reps += 1;
		}
		for (uint64_t i = 0; i < size / 8; i++) {
			sw ^= p[i];
		}
		bpc = core_read_bpc_x1000(BUF, size, &bytes, &cycles);
		printk("CORE level=L2MID bytes=%llu moved=%llu cycles=%llu bpc_x1000=%llu\n",
		       (unsigned long long)size, (unsigned long long)bytes,
		       (unsigned long long)cycles, (unsigned long long)bpc);
		for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
			struct bwrun r;
			/* The warm pass is ONE pass, which is odd, so its checksum is also sw. */
			l2_flush(BUF, size);
			probe_run(BUF, size, 1, outs[oi], &r);
			probe_run(BUF, size, reps, outs[oi], &r);
			printk("PROBE level=L2MID bytes=%llu out=%d cycles=%llu beats=%llu "
			       "reqs=%llu peak=%llu denied=%llu cksum_ok=%d\n",
			       (unsigned long long)size, outs[oi],
			       (unsigned long long)r.cycles, (unsigned long long)r.beats,
			       (unsigned long long)r.reqs, (unsigned long long)r.peak,
			       (unsigned long long)r.denied, (r.cksum == sw) ? 1 : 0);
			probe_width("L2MID", size, outs[oi], &r);
		}
	}
#endif

#ifdef BWLAB_CHANNELS
	/* After the core's calibration pass and the sequential sweep, not before: the software
	 * checksum is a core read, and a core read warms the L2.  Every point flushes the whole
	 * region first. */
	chshape_checksums();
	for (unsigned ci = 0; ci < ARRAY_SIZE(chshapes); ci++) {
		const struct chshape *c = &chshapes[ci];

		for (unsigned oi = 0; oi < ARRAY_SIZE(outs); oi++) {
			struct bwrun r;
			int ok;

			l2_flush(BUF, BUF_SPAN);
			probe_go(BUF, 1, chshape_rows(c), c->stride, outs[oi], &r);
			ok = (r.cksum == c->sw);
			printk("%-8s %10llu %6d %12llu %12llu %6llu.%03llu %8llu %8llu %6llu %s\n",
			       c->name, (unsigned long long)BUF_SPAN, outs[oi],
			       (unsigned long long)r.cycles, (unsigned long long)r.beats,
			       (unsigned long long)((r.beats * 8ULL) / r.cycles),
			       (unsigned long long)(((r.beats * 8000ULL) / r.cycles) % 1000),
			       (unsigned long long)r.reqs, (unsigned long long)r.peak,
			       (unsigned long long)r.denied, ok ? "ok" : "MISMATCH");
			printk("PROBE level=%s bytes=%llu out=%d cycles=%llu beats=%llu "
			       "reqs=%llu peak=%llu denied=%llu cksum_ok=%d\n",
			       c->name, (unsigned long long)BUF_SPAN, outs[oi],
			       (unsigned long long)r.cycles, (unsigned long long)r.beats,
			       (unsigned long long)r.reqs, (unsigned long long)r.peak,
			       (unsigned long long)r.denied, ok);
			probe_width(c->name, BUF_SPAN, outs[oi], &r);
		}
	}
#endif

#ifdef BWLAB_BYPASS
	bypass_sweep();
#endif

	printk("BWLAB done fails=0\n");
	return 0;
}
#endif /* BWLAB_WRITER */
