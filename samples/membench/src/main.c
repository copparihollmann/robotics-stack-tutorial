/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * membench -- a memory hierarchy characteriser for the dual-core big.LITTLE Rocket on a
 * PYNQ-Z1.  It measures, rather than computes, what each level of the hierarchy actually
 * delivers to each hart, and what happens when both harts want it at once.
 *
 * WHAT IT MEASURES, and why each piece is shaped the way it is
 * ------------------------------------------------------------
 *   1. BANDWIDTH vs WORKING-SET SIZE.  A sweep from 2 KiB to 16 MiB that crosses both
 *      cache boundaries.  Read and write are reported separately: the L1D is write-back
 *      with allocate, so a write miss costs a line fill now and a writeback later, and a
 *      read-only sweep would quietly miss that factor of two.
 *
 *   2. LOAD-TO-USE LATENCY, by pointer chase over a randomised cyclic permutation of the
 *      cache lines in the working set (Sattolo's algorithm -- see chase_build).  One node
 *      per 64-byte line, next-pointer at offset 0.  No stride, so nothing can predict it.
 *
 *   3. CONTENTION.  Both harts stream their own 16 MiB region at the same time, into
 *      one shared L2, one 64-bit AXI port and one DDR controller.
 *
 * THE GEOMETRY BEING CHARACTERISED (generated DTS, not assumed here)
 * -----------------------------------------------------------------
 *   hart 0 "big"     L1I/L1D 16 KiB, 4-way, 64 sets, 64 B lines, sv39 TLB 32 entries
 *   hart 1 "LITTLE"  L1I/L1D  4 KiB, 1-way, 64 sets, 64 B lines, no MMU
 *   L2 (shared)      64 KiB, 4-way, 256 sets, 64 B lines, 1 bank, 7 MSHRs, inclusive
 *   DRAM             256 MiB at 0x8000_0000, reached over one 64-bit 40 MHz AXI port
 *
 *   The two harts do NOT have the same L1.  A sweep that only crosses 16 KiB would miss
 *   hart 1's boundary entirely, which is why the sweep starts at 2 KiB.
 *
 * THE ONE MICROARCHITECTURAL FACT THAT DOMINATES EVERY DRAM NUMBER BELOW
 * ---------------------------------------------------------------------
 *   Both tiles instantiate rocket-chip's `DCache` (rocket/DCache.scala), not
 *   `NonBlockingDCache` -- verified in the generated Verilog, which contains DCache.sv and
 *   DCache_1.sv and no NonBlockingDCache at all.  That cache carries a single
 *   `cached_grant_wait` flag: ONE outstanding cached miss per hart.  So a single hart can
 *   never have more than one line in flight, the L2's seven MSHRs cannot be filled by one
 *   core, and streaming bandwidth from DRAM is bounded by 64 bytes per miss round trip --
 *   a latency number wearing a bandwidth costume.  The contention phase is the only part
 *   of this program that can put two misses in flight at once.
 *
 * HOW THE TIMING IS DONE
 * ----------------------
 *   rdcycle, 40 MHz, 25 ns per tick.  mtime is 40 kHz (25 us) and far too coarse.  Rocket
 *   stops mcycle in wfi, so no timed region is ever allowed to sleep: every measurement
 *   runs with interrupts locked on that hart -- arch_irq_lock(), NOT irq_lock(); see the
 *   comment on LOCAL_IRQ_LOCK -- which also keeps the 1 kHz Zephyr tick out of the window.
 *
 *   Each measurement runs for a fixed cycle window (WINDOW_CYCLES) *and* at least one
 *   complete traversal of the working set, whichever is longer, and reports bytes moved
 *   over cycles elapsed.  The "at least one traversal" half matters: with a fixed window
 *   and a 64 KiB chunk cursor, a 16 MiB working set would only ever have its first megabyte
 *   touched, and would silently be a 1 MiB measurement.
 *
 *   In the contention phase the two harts enter the window through a barrier, and whichever
 *   finishes first keeps streaming (untimed) until the other is done -- so both windows are
 *   contended end to end, rather than the slower hart measuring a quiet machine in its tail.
 *
 * FLUSHING
 * --------
 *   Between every repetition the working set is flushed out of the L2 through the SiFive
 *   InclusiveCache Flush64 register at cache-controller@2010000 + 0x200 (the same routine
 *   samples/tacit_dma uses).  The L2 is inclusive, so a flush there back-invalidates the
 *   L1s too -- one register does both levels.  flush_ws() bounds the cost for the big
 *   sizes; see the comment there for why that is still sound.
 *
 * Output lines beginning BW/LAT/CHK are machine-readable and are what
 * scripts/25_rocket_membench.sh parses into run.json.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>
#include <zephyr/linker/linker-defs.h>
#include <stdint.h>
#include <stdbool.h>

/* ------------------------------------------------------------------ the asm kernels */
uint64_t mb_read(const void *base, uint64_t bytes);
void     mb_write(void *base, uint64_t bytes, uint64_t val);
void    *mb_chase(void *p, uint64_t steps);

/* ------------------------------------------------------------------------- constants */

/* SiFive InclusiveCache control node: cache-controller@2010000, reg-names "control". */
#define L2_CTRL_BASE   0x2010000UL
#define L2_CONFIG      (L2_CTRL_BASE + 0x000)  /* banks | ways<<8 | lgSets<<16 | lgBlk<<24 */
#define L2_FLUSH64     (L2_CTRL_BASE + 0x200)  /* write a phys addr -> flush that block */

#define LINE           64UL

/*
 * Where the working sets live, in ROCKET's address space.
 *
 * The image, its BSS and every stack sit in the first few hundred KiB of 0x8000_0000;
 * main() prints _image_ram_end and refuses to run if these overlap it.  0x8800_0000 is
 * a TACIT trace buffer belonging to another workstream and is deliberately far above the
 * top of hart 1's region (0x8300_0000).
 */
#define BUF_HART0      0x81000000UL
#define BUF_HART1      0x82000000UL
#define BUF_SPAN       (16UL * 1024 * 1024)

/* The measurement window. 2,000,000 cycles = 50 ms at 40 MHz. */
#define WINDOW_CYCLES  2000000ULL
/* Deadline granularity: rdcycle is checked once per chunk, not once per access. */
#define CHUNK          (64UL * 1024)

#define REPS_SMALL     5
#define REPS_LARGE     3          /* >1 MiB: one traversal already takes ~0.5-1.5 s */
#define LARGE_SIZE     (1UL * 1024 * 1024)
#define MAX_REPS       REPS_SMALL

#define CHASE_STEPS    16384ULL   /* multiple of 8, see mb_chase */
#define FILLER_STEPS   1024ULL
#define CHASE_SUBS     8         /* overlap sample points inside one timed chase */

/*
 * Nominal core clock. CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC is mtime (40 kHz); the digital
 * top runs at that times the RTC divider. measure_core_clock() checks this against the
 * hardware rather than trusting it.
 */
#define CORE_HZ  ((uint64_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * CONFIG_RTC_CLOCK_DIVIDER_VALUE)

static const uint32_t SIZES[] = {
	2u << 10,  4u << 10,   8u << 10,  16u << 10, 32u << 10, 64u << 10,
	128u << 10, 256u << 10, 1u << 20, 4u << 20,  16u << 20,
};
#define NSIZES  ARRAY_SIZE(SIZES)
/*
 * The latency sweep stops at 4 MiB. 4 MiB is already 64x the L2 and 32x hart 0's TLB
 * reach, so a 16 MiB point would cost ~10 s of Sattolo shuffling to say the same thing.
 */
#define NLSIZES 10

#define OP_READ  0
#define OP_WRITE 1

#define PH_SOLO0 0
#define PH_SOLO1 1
#define PH_BOTH  2
#define NPHASES  3

static const char *const PHASE_NAME[NPHASES] = { "solo0", "solo1", "both" };
static const char *const OP_NAME[2] = { "rd", "wr" };

/* -------------------------------------------------------------------------- results */

struct bw_entry {
	uint32_t mbps100_lo, mbps100_med, mbps100_hi;  /* MB/s x100, min / median / max */
	uint32_t bpc1000;                              /* bytes/cycle x1000, median rep */
	uint32_t passes;                               /* traversals in the first rep  */
	uint32_t overlap_pct;                          /* % of the window the partner
							* was also streaming (0 when alone) */
	uint8_t  reps;
	bool     valid;
};

struct lat_entry {
	uint32_t cyc100_lo, cyc100_med, cyc100_hi;     /* cycles per step x100 */
	uint8_t  reps;
	uint32_t overlap_pct;                          /* as above */
	bool     cycle_ok;                             /* the chase really is one n-cycle */
	bool     valid;
};

static struct bw_entry  bw[NPHASES][2][2][NSIZES];    /* [phase][slot][op][size] */
static struct lat_entry lat[NPHASES][2][NLSIZES];     /* [phase][slot][size]     */

/*
 * Somewhere for the loaded values to go -- ONE PER HART, each on its own 64-byte line.
 *
 * A single shared sink is a bug, and a subtle one: the contended read measurements pick up
 * a coherence miss on that line every chunk, because two harts are writing it.  At a 2 KiB
 * working set the chunk is only ~290 cycles long, so one ~40-cycle ownership transfer per
 * chunk was costing 14% -- and it showed up in the results as two L1-resident harts
 * "contending", which they physically cannot do.
 */
struct padded_sink {
	volatile uint64_t v;
	uint8_t pad[LINE - sizeof(uint64_t)];
} __aligned(64);
static struct padded_sink sink[2];

/* ------------------------------------------------------------------------ primitives */

/*
 * NOT irq_lock().  This one cost a whole board run to find.
 *
 * Under CONFIG_SMP, zephyr/irq.h defines irq_lock() as z_smp_global_lock() -- a single
 * recursive spinlock shared by every CPU -- rather than as arch_irq_lock().  Wrapping a
 * 50 ms measurement window in it therefore does not just keep the tick out: it keeps the
 * OTHER HART out.  The contention phase ran with hart 1 spinning on the global lock for
 * the whole of hart 0's window and vice versa, and reported, very convincingly, that two
 * harts sharing one L2 and one DDR port cost each other nothing.  Every number was a
 * solo number wearing a contention label.
 *
 * arch_irq_lock() is the per-hart primitive: on RISC-V it clears mstatus.MIE on this hart
 * and nothing else.  That is all this benchmark wants -- no timer tick inside a timed
 * region -- and it leaves the other hart free to run.
 *
 * Nothing inside a locked region calls a kernel API; it is the assembly kernels, rdcycle,
 * and two volatile flags.
 */
#define LOCAL_IRQ_LOCK()      arch_irq_lock()
#define LOCAL_IRQ_UNLOCK(k)   arch_irq_unlock(k)

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/*
 * Flush a physical range out of the L2 (and, because the L2 is inclusive, out of both
 * L1s along with it).
 *
 * Flush64 is a write-only register whose TileLink write does not complete until the
 * scheduler has finished with that block, so the store itself is the handshake -- there
 * is nothing to poll. Blocks that are not resident answer immediately.
 */
static void l2_flush_range(uintptr_t base, uint64_t bytes)
{
	volatile uint64_t *flush = (volatile uint64_t *)L2_FLUSH64;
	uintptr_t a = base & ~(uintptr_t)(LINE - 1);
	uintptr_t end = base + bytes;

	__asm__ volatile("fence" ::: "memory");
	for (; a < end; a += LINE) {
		*flush = (uint64_t)a;
	}
	__asm__ volatile("fence" ::: "memory");
}

/*
 * Bound the flush cost without weakening it where it matters.
 *
 * Flush64 takes one uncached MMIO store per 64-byte block, and Rocket issues those one at
 * a time (nMMIOs = 1), so flushing 16 MiB is a quarter of a billion cycles of pure
 * overhead between every repetition.
 *
 * It is also unnecessary.  The whole L2 is 64 KiB, so at most 64 KiB of ANY working set
 * can still be resident when the previous repetition ends -- and a streaming pass leaves
 * that residue at the end of the buffer, which the next pass reaches last.  For a 4 MiB
 * working set that is under 1.6% of the traffic, and for 16 MiB under 0.4%.  Where the
 * residue would actually matter -- a 64 KiB or 128 KiB working set, which could otherwise
 * start half-warm -- the whole thing is flushed.
 */
#define FLUSH_EDGE  (512UL * 1024)

static void flush_ws(uintptr_t base, uint64_t bytes)
{
	if (bytes <= 2 * FLUSH_EDGE) {
		l2_flush_range(base, bytes);
	} else {
		l2_flush_range(base, FLUSH_EDGE);
		l2_flush_range(base + bytes - FLUSH_EDGE, FLUSH_EDGE);
	}
}

static void isort(uint32_t *a, int n)
{
	for (int i = 1; i < n; i++) {
		uint32_t v = a[i];
		int j = i - 1;

		while (j >= 0 && a[j] > v) {
			a[j + 1] = a[j];
			j--;
		}
		a[j + 1] = v;
	}
}

/* ------------------------------------------------------- two-hart rendezvous + filler */

/*
 * A sense-reversing barrier for exactly two harts, and one "still streaming" flag per
 * hart, each on its own 64-byte line so the two harts never share one.
 */
struct padded_flag {
	volatile uint32_t v;
	uint8_t pad[LINE - sizeof(uint32_t)];
} __aligned(64);

static atomic_t barrier_count;
static volatile uint32_t barrier_gen;

/*
 * Two flags per hart, and the difference between them matters.
 *
 *   traffic[]      this hart is putting load on the memory system RIGHT NOW -- inside its
 *                  timed window, or in the untimed tail it runs to keep the partner's
 *                  window contended.  This is what the partner samples: the question a
 *                  contention number has to answer is "was the memory system loaded",
 *                  not "was the partner's stopwatch running".
 *   window_open[]  this hart's TIMED window has not closed yet.  This is what the tail
 *                  waits on, so that neither hart's measurement ends in a quiet machine.
 *
 * Collapsing the two into one flag reports the contention as absent wherever the two
 * harts run at very different speeds -- which on a big.LITTLE pair is most of the sweep.
 */
static struct padded_flag traffic[2];
static struct padded_flag window_open[2];

static void barrier2(void)
{
	uint32_t g = barrier_gen;

	if (atomic_inc(&barrier_count) == 1) {       /* second arrival: release both */
		atomic_set(&barrier_count, 0);
		__asm__ volatile("fence" ::: "memory");
		barrier_gen = g + 1;
	} else {
		while (barrier_gen == g) {
			arch_nop();
		}
	}
	__asm__ volatile("fence" ::: "memory");
}

/* ----------------------------------------------------------------- the pointer chase */

static uint64_t rng_state;

static inline uint64_t xrand(void)
{
	uint64_t x = rng_state;

	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	rng_state = x;
	return x;
}

#define NEXT_AT(b, i)  (*(volatile uintptr_t *)((b) + (uintptr_t)(i) * LINE))
#define IDX_AT(b, i)   (*(volatile uint32_t  *)((b) + (uintptr_t)(i) * LINE + 8))

/*
 * Build a single cycle through every 64-byte line of [base, base+bytes).
 *
 * Sattolo's algorithm applied to the identity permutation yields a uniformly random
 * CYCLIC permutation -- one cycle covering all n elements, which is exactly what a pointer
 * chase needs (a general random permutation would decompose into several short cycles and
 * the chase would only ever visit one of them).
 *
 * The permutation is built in place, in the lines themselves: index at offset 8, final
 * next-pointer at offset 0.  Writing the pointer never clobbers the index that is still
 * needed, and no second array of up to 256 KiB has to exist.
 *
 * Returns true if chasing exactly n steps from node 0 comes back to node 0, i.e. if the
 * cycle really is a single n-cycle.  A false here invalidates every latency number for
 * that size, so it is reported rather than assumed.
 */
static bool chase_build(uintptr_t base, uint64_t bytes, uint64_t seed)
{
	uint32_t n = (uint32_t)(bytes / LINE);

	rng_state = seed ? seed : 0x9E3779B97F4A7C15ULL;

	for (uint32_t i = 0; i < n; i++) {
		IDX_AT(base, i) = i;
	}
	for (uint32_t i = n - 1; i > 0; i--) {
		uint32_t j = (uint32_t)(xrand() % i);     /* 0 <= j < i */
		uint32_t t = IDX_AT(base, i);

		IDX_AT(base, i) = IDX_AT(base, j);
		IDX_AT(base, j) = t;
	}
	for (uint32_t i = 0; i < n; i++) {
		NEXT_AT(base, i) = base + (uintptr_t)IDX_AT(base, i) * LINE;
	}
	__asm__ volatile("fence" ::: "memory");

	return mb_chase((void *)base, n) == (void *)base;
}

/* ----------------------------------------------------------------------- the measurer */

struct job {
	int      phase;
	int      slot;        /* 0 = hart 0, 1 = hart 1 */
	uintptr_t buf;
	int      nparts;      /* 1 = alone, 2 = contended */
	uint32_t hartid;      /* filled in by the worker, from the CSR */
	uint32_t t_start;     /* mtime tick at which this worker entered the phase */
	uint32_t t_end;       /* ... and left it */
};

static struct job jobs[2];

/*
 * One bandwidth measurement.
 *
 * Runs until BOTH the cycle window has expired AND the working set has been traversed at
 * least once, then -- if contended -- keeps streaming untimed until the partner's window
 * closes too.  Returns bytes moved; *cycles and *passes are the timed window.
 */
static uint64_t bw_window(uintptr_t buf, uint64_t size, int op, int nparts, int slot,
			  uint64_t *cycles, uint32_t *passes, uint32_t *overlap_pct)
{
	const uint64_t val = 0x0101010101010101ULL;
	uint64_t bytes = 0, c0, c1 = 0;
	uint64_t cur = 0;
	uint32_t np = 0;
	uint32_t chunks = 0, overlapped = 0;
	bool done = false;
	int other = slot ^ 1;

	traffic[slot].v = 1;
	window_open[slot].v = 1;
	__asm__ volatile("fence" ::: "memory");

	c0 = rdcycle();
	for (;;) {
		uint64_t chunk = size - cur;

		if (chunk > CHUNK) {
			chunk = CHUNK;
		}
		if (op == OP_READ) {
			sink[slot].v += mb_read((const void *)(buf + cur), chunk);
		} else {
			mb_write((void *)(buf + cur), chunk, val);
		}
		cur += chunk;
		if (cur >= size) {
			cur = 0;
			np++;
		}
		if (!done) {
			bytes += chunk;
			/*
			 * The contention witness.  "Both harts ran" is not the same claim as
			 * "both harts were streaming at the same instant", and only the
			 * second one makes a contention number mean anything.  One sample
			 * per chunk, inside the timed window, of whether the partner also
			 * had its streaming flag up.
			 */
			chunks++;
			if (nparts > 1 && traffic[other].v) {
				overlapped++;
			}
			if (np > 0 && rdcycle() - c0 >= WINDOW_CYCLES) {
				c1 = rdcycle();
				done = true;
				*passes = np;
				window_open[slot].v = 0;
				__asm__ volatile("fence" ::: "memory");
			}
		}
		if (done && (nparts == 1 || window_open[other].v == 0)) {
			break;
		}
		/* A partner that never clears its flag must not hang this hart with
		 * interrupts locked; give up after 100x the window and say so. */
		if (done && rdcycle() - c0 > 100ULL * WINDOW_CYCLES) {
			break;
		}
	}
	traffic[slot].v = 0;
	__asm__ volatile("fence" ::: "memory");
	*cycles = c1 - c0;
	*overlap_pct = chunks ? (overlapped * 100 / chunks) : 0;
	return bytes;
}

static void bandwidth_sweep(struct job *j)
{
	for (int si = 0; si < (int)NSIZES; si++) {
		uint64_t size = SIZES[si];
		int reps = (size > LARGE_SIZE) ? REPS_LARGE : REPS_SMALL;

		/*
		 * A progress line, so a 16 MiB write sweep does not look like a hang from
		 * the console side, and so the runner can stop reading the moment the run
		 * is over instead of waiting out a fixed timeout. Only one hart prints:
		 * in the contended phase both are inside the same barrier sequence and a
		 * second printer would just be noise on the same UART.
		 */
		if (j->slot == 0 || j->nparts == 1) {
			printk("PROG p=%s bw sz=%u\n", PHASE_NAME[j->phase],
			       (unsigned int)size);
		}

		for (int op = 0; op < 2; op++) {
			uint32_t s[MAX_REPS];
			uint32_t np0 = 0, ovl = 0;

			for (int r = 0; r < reps; r++) {
				uint64_t cyc = 0, by;
				uint32_t np = 0, ov = 0;
				unsigned int key;

				flush_ws(j->buf, size);
				if (j->nparts > 1) {
					barrier2();
				}
				key = LOCAL_IRQ_LOCK();
				by = bw_window(j->buf, size, op, j->nparts, j->slot,
					       &cyc, &np, &ov);
				LOCAL_IRQ_UNLOCK(key);

				/* MB/s x100 = bytes/cycle * CORE_HZ / 1e6 * 100 */
				s[r] = (uint32_t)(by * (CORE_HZ / 10000ULL) / cyc);
				if (r == 0) {
					np0 = np;
				}
				ovl += ov / reps;
			}
			isort(s, reps);
			bw[j->phase][j->slot][op][si].mbps100_lo  = s[0];
			bw[j->phase][j->slot][op][si].mbps100_med = s[reps / 2];
			bw[j->phase][j->slot][op][si].mbps100_hi  = s[reps - 1];
			/* bytes/cycle of the median repetition: MB/s x100 -> B/cyc x1000 */
			bw[j->phase][j->slot][op][si].bpc1000 =
				(uint32_t)((uint64_t)s[reps / 2] * 10000000ULL / CORE_HZ);
			bw[j->phase][j->slot][op][si].passes      = np0;
			bw[j->phase][j->slot][op][si].overlap_pct = ovl;
			bw[j->phase][j->slot][op][si].reps        = (uint8_t)reps;
			bw[j->phase][j->slot][op][si].valid       = true;
		}
	}
}

static void latency_sweep(struct job *j)
{
	for (int si = 0; si < NLSIZES; si++) {
		uint64_t size = SIZES[si];
		uint32_t s[MAX_REPS];
		uint32_t ovl = 0;
		int other = j->slot ^ 1;
		bool cycle_ok;
		void *p;

		if (j->slot == 0 || j->nparts == 1) {
			printk("PROG p=%s lat sz=%u\n", PHASE_NAME[j->phase],
			       (unsigned int)size);
		}

		/* A different seed per hart, so the two chases are not the same walk. */
		cycle_ok = chase_build(j->buf, size, 0xC0FFEEULL + j->slot * 7919ULL + si);
		p = (void *)j->buf;

		for (int r = 0; r < REPS_SMALL; r++) {
			uint64_t c0, c1;
			unsigned int key;
			flush_ws(j->buf, size);
			if (j->nparts > 1) {
				barrier2();
			}
			key = LOCAL_IRQ_LOCK();
			traffic[j->slot].v = 1;
			window_open[j->slot].v = 1;
			__asm__ volatile("fence" ::: "memory");
			c0 = rdcycle();
			/*
			 * Split into CHASE_SUBS pieces purely so the partner's streaming flag
			 * can be sampled inside the timed region.  The chain is unbroken
			 * across the pieces -- each call resumes from the pointer the last
			 * one returned -- so the latency is unaffected beyond one extra
			 * call/return per 2048 steps.
			 */
			for (int k = 0; k < CHASE_SUBS; k++) {
				p = mb_chase(p, CHASE_STEPS / CHASE_SUBS);
				if (j->nparts > 1 && traffic[other].v) {
					ovl++;
				}
			}
			c1 = rdcycle();
			window_open[j->slot].v = 0;
			__asm__ volatile("fence" ::: "memory");
			while (j->nparts > 1 && window_open[other].v &&
			       rdcycle() - c0 < 100ULL * WINDOW_CYCLES) {
				p = mb_chase(p, FILLER_STEPS);
			}
			traffic[j->slot].v = 0;
			__asm__ volatile("fence" ::: "memory");
			LOCAL_IRQ_UNLOCK(key);

			s[r] = (uint32_t)((c1 - c0) * 100ULL / CHASE_STEPS);
		}
		sink[j->slot].v += (uint64_t)(uintptr_t)p;
		isort(s, REPS_SMALL);
		lat[j->phase][j->slot][si].cyc100_lo  = s[0];
		lat[j->phase][j->slot][si].cyc100_med = s[REPS_SMALL / 2];
		lat[j->phase][j->slot][si].cyc100_hi  = s[REPS_SMALL - 1];
		lat[j->phase][j->slot][si].reps       = REPS_SMALL;
		lat[j->phase][j->slot][si].overlap_pct =
			ovl * 100 / (REPS_SMALL * CHASE_SUBS);
		lat[j->phase][j->slot][si].cycle_ok   = cycle_ok;
		lat[j->phase][j->slot][si].valid      = true;
	}
}

static void worker(void *p1, void *p2, void *p3)
{
	struct job *j = (struct job *)p1;

	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	j->hartid = (uint32_t)csr_read(mhartid);
	j->t_start = k_cycle_get_32();
	bandwidth_sweep(j);
	latency_sweep(j);
	j->t_end = k_cycle_get_32();
}

/* ----------------------------------------------------------------- orchestration */

#define STACK_SIZE 4096
K_THREAD_STACK_ARRAY_DEFINE(worker_stacks, 2, STACK_SIZE);
static struct k_thread worker_threads[2];

/* Run `phase` with the given set of slots, and do not return until they are done. */
static bool run_phase(int phase, bool use0, bool use1)
{
	int n = (use0 ? 1 : 0) + (use1 ? 1 : 0);
	int started = 0, finished = 0;
	k_tid_t tids[2] = { NULL, NULL };

	atomic_set(&barrier_count, 0);
	barrier_gen = 0;
	traffic[0].v = 0;
	traffic[1].v = 0;
	window_open[0].v = 0;
	window_open[1].v = 0;

	for (int slot = 0; slot < 2; slot++) {
		k_tid_t tid;

		if ((slot == 0 && !use0) || (slot == 1 && !use1)) {
			continue;
		}
		jobs[slot].phase  = phase;
		jobs[slot].slot   = slot;
		jobs[slot].buf    = (slot == 0) ? BUF_HART0 : BUF_HART1;
		jobs[slot].nparts = n;
		tid = k_thread_create(&worker_threads[slot], worker_stacks[slot], STACK_SIZE,
				      worker, &jobs[slot], NULL, NULL, 5, 0, K_FOREVER);
		if (k_thread_cpu_pin(tid, slot) != 0) {
			printk("CHK fatal=pin_failed slot=%d\n", slot);
			return false;
		}
		tids[slot] = tid;
		started++;
	}
	for (int slot = 0; slot < 2; slot++) {
		if (tids[slot] != NULL) {
			k_thread_start(tids[slot]);
		}
	}
	/*
	 * k_thread_join rather than a semaphore, and not K_FOREVER.  Joining is what makes
	 * the k_thread struct safe to reuse for the next phase -- a semaphore is given
	 * while the worker is still running, so the next k_thread_create could land on a
	 * thread that has not finished exiting.  The deadline is there because a worker
	 * pinned to a CPU that never came online would never run, and main() blocking
	 * forever would stop the console dead -- the least useful possible failure.
	 */
	for (int slot = 0; slot < 2; slot++) {
		if (tids[slot] != NULL && k_thread_join(tids[slot], K_SECONDS(900)) == 0) {
			finished++;
		}
	}
	if (finished != started) {
		printk("CHK fatal=worker_timeout started=%d finished=%d\n",
		       started, finished);
	}
	return finished == started;
}

/*
 * Check the 40 MHz assumption against the hardware, by counting rdcycle ticks across a
 * known number of mtime ticks.  mtime is one counter in the CLINT at 40 kHz; rdcycle is
 * the per-hart core clock.  Nothing sleeps here, so mcycle does not stop.
 */
static uint64_t measure_core_clock(void)
{
	const uint32_t ticks = 4000;    /* 100 ms at 40 kHz */
	unsigned int key = LOCAL_IRQ_LOCK();
	uint32_t t0 = k_cycle_get_32();
	uint64_t c0, c1;
	uint32_t t1;

	while (k_cycle_get_32() == t0) {
		arch_nop();
	}
	t0 = k_cycle_get_32();
	c0 = rdcycle();
	while ((k_cycle_get_32() - t0) < ticks) {
		arch_nop();
	}
	t1 = k_cycle_get_32();
	c1 = rdcycle();
	LOCAL_IRQ_UNLOCK(key);

	return (c1 - c0) * (uint64_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC / (t1 - t0);
}

/*
 * Prove the flush actually flushes.
 *
 * A single traversal straight after flush_ws() must be measurably slower than the same
 * traversal repeated immediately afterwards, because the first one is fetching from DRAM
 * and the second from cache.  If the two are the same, the sweep below is measuring warm
 * caches at every size and every plateau in it is fiction.
 */
static void flush_check(uintptr_t buf, uint64_t size, const char *tag)
{
	unsigned int key;
	uint64_t c0, cold, warm;

	key = LOCAL_IRQ_LOCK();
	flush_ws(buf, size);
	c0 = rdcycle();
	sink[0].v += mb_read((const void *)buf, size);
	cold = rdcycle() - c0;
	c0 = rdcycle();
	sink[0].v += mb_read((const void *)buf, size);
	warm = rdcycle() - c0;
	LOCAL_IRQ_UNLOCK(key);

	printk("CHK flush h=%lu tag=%s size=%u cold_cyc=%u warm_cyc=%u ratio100=%u\n",
	       (unsigned long)csr_read(mhartid), tag,
	       (unsigned int)size, (unsigned int)cold, (unsigned int)warm,
	       (unsigned int)(warm ? cold * 100 / warm : 0));
}

static void flush_cost(uintptr_t buf)
{
	unsigned int key = LOCAL_IRQ_LOCK();
	uint64_t c0 = rdcycle(), c1;

	l2_flush_range(buf, FLUSH_EDGE);
	c1 = rdcycle();
	LOCAL_IRQ_UNLOCK(key);
	printk("CHK flushcost h=%lu lines=%u cyc=%u cyc_per_line100=%u\n",
	       (unsigned long)csr_read(mhartid),
	       (unsigned int)(FLUSH_EDGE / LINE), (unsigned int)(c1 - c0),
	       (unsigned int)((c1 - c0) * 100 * LINE / FLUSH_EDGE));
}

/*
 * mtime is ONE counter in the CLINT shared by both harts, so the two workers' windows are
 * directly comparable; rdcycle is per-hart and cannot be used for this.  Overlapping
 * windows are the independent witness that the contention phase really was contended --
 * the per-measurement ovl= fields say the same thing from inside the timed regions.
 */
static void print_phase_window(int phase, bool use0, bool use1)
{
	uint32_t a0 = jobs[0].t_start, a1 = jobs[0].t_end;
	uint32_t b0 = jobs[1].t_start, b1 = jobs[1].t_end;
	uint32_t lo, hi, ov = 0, shorter;

	if (!use0 || !use1) {
		int s = use0 ? 0 : 1;

		printk("CHK phase p=%s harts=1 h%d=[%u..%u] dur=%u\n", PHASE_NAME[phase],
		       s, jobs[s].t_start, jobs[s].t_end,
		       jobs[s].t_end - jobs[s].t_start);
		return;
	}
	lo = MAX(a0, b0);
	hi = MIN(a1, b1);
	ov = (hi > lo) ? (hi - lo) : 0U;
	shorter = MIN(a1 - a0, b1 - b0);
	printk("CHK phase p=%s harts=2 h0=[%u..%u] h1=[%u..%u] overlap=%u pct=%u\n",
	       PHASE_NAME[phase], a0, a1, b0, b1, ov,
	       shorter ? (unsigned int)((uint64_t)ov * 100U / shorter) : 0U);
}

static void print_phase(int phase, bool use0, bool use1)
{
	print_phase_window(phase, use0, use1);
	for (int slot = 0; slot < 2; slot++) {
		if ((slot == 0 && !use0) || (slot == 1 && !use1)) {
			continue;
		}
		for (int op = 0; op < 2; op++) {
			for (int si = 0; si < (int)NSIZES; si++) {
				struct bw_entry *e = &bw[phase][slot][op][si];

				if (!e->valid) {
					continue;
				}
				printk("BW p=%s h=%u op=%s sz=%u n=%u mbps100=%u lo=%u hi=%u "
				       "bpc1000=%u pass=%u ovl=%u\n",
				       PHASE_NAME[phase], jobs[slot].hartid, OP_NAME[op],
				       (unsigned int)SIZES[si], e->reps, e->mbps100_med,
				       e->mbps100_lo, e->mbps100_hi, e->bpc1000, e->passes,
				       e->overlap_pct);
			}
		}
		for (int si = 0; si < NLSIZES; si++) {
			struct lat_entry *e = &lat[phase][slot][si];

			if (!e->valid) {
				continue;
			}
			printk("LAT p=%s h=%u sz=%u n=%u cyc100=%u lo=%u hi=%u ovl=%u "
			       "cycle_ok=%d\n",
			       PHASE_NAME[phase], jobs[slot].hartid, (unsigned int)SIZES[si],
			       e->reps, e->cyc100_med, e->cyc100_lo, e->cyc100_hi,
			       e->overlap_pct, e->cycle_ok ? 1 : 0);
		}
	}
}

int main(void)
{
	uint32_t l2cfg = *(volatile uint32_t *)L2_CONFIG;
	unsigned int ncpus = arch_num_cpus();
	uintptr_t image_end = (uintptr_t)_image_ram_end;
	uint64_t core_hz;
	bool ok = true;
	int ceiling_violations = 0;

	printk("\n=== membench on %s ===\n", CONFIG_BOARD_TARGET);
	printk("arch_num_cpus = %u   main mhartid = %lu\n",
	       ncpus, (unsigned long)csr_read(mhartid));

	if (ncpus < 2) {
		printk("CHK fatal=one_cpu ncpus=%u\n", ncpus);
		printk("RESULT: FAIL\n");
		return 0;
	}

	/* The L2 the board actually has, out of its own config register. */
	printk("CHK l2cfg raw=0x%08x banks=%u ways=%u lgSets=%u block=%u\n",
	       l2cfg, l2cfg & 0xff, (l2cfg >> 8) & 0xff,
	       (l2cfg >> 16) & 0xff, 1u << ((l2cfg >> 24) & 0xff));

	core_hz = measure_core_clock();
	printk("CHK clock nominal_hz=%llu measured_hz=%llu mtime_hz=%u\n",
	       (unsigned long long)CORE_HZ, (unsigned long long)core_hz,
	       sys_clock_hw_cycles_per_sec());

	printk("CHK layout image_ram_end=0x%08lx buf0=0x%08lx buf1=0x%08lx span=%lu\n",
	       (unsigned long)image_end, (unsigned long)BUF_HART0,
	       (unsigned long)BUF_HART1, (unsigned long)BUF_SPAN);
	if (image_end > BUF_HART0) {
		printk("CHK fatal=buffer_overlaps_image\n");
		printk("RESULT: FAIL\n");
		return 0;
	}

	printk("CHK window cycles=%llu chunk=%lu reps_small=%d reps_large=%d "
	       "chase_steps=%llu\n",
	       (unsigned long long)WINDOW_CYCLES, (unsigned long)CHUNK,
	       REPS_SMALL, REPS_LARGE, (unsigned long long)CHASE_STEPS);

	flush_cost(BUF_HART0);
	flush_check(BUF_HART0, 4u << 10, "l1fit");    /* fits hart 0's 16 KiB L1 */
	flush_check(BUF_HART0, 32u << 10, "l2fit");   /* exceeds L1, fits the 64 KiB L2 */

	printk("\n-- phase solo0: hart 0 alone\n");
	ok = run_phase(PH_SOLO0, true, false) && ok;
	print_phase(PH_SOLO0, true, false);

	printk("\n-- phase solo1: hart 1 alone\n");
	ok = run_phase(PH_SOLO1, false, true) && ok;
	print_phase(PH_SOLO1, false, true);

	printk("\n-- phase both: hart 0 and hart 1 concurrently\n");
	ok = run_phase(PH_BOTH, true, true) && ok;
	print_phase(PH_BOTH, true, true);

	/*
	 * Ceiling check.  The 64-bit datapath cannot move more than 8 B/cycle anywhere, so
	 * anything above that is a broken measurement, not fast hardware.
	 */
	for (int p = 0; p < NPHASES; p++) {
		for (int s = 0; s < 2; s++) {
			for (int o = 0; o < 2; o++) {
				for (int i = 0; i < (int)NSIZES; i++) {
					if (bw[p][s][o][i].valid &&
					    bw[p][s][o][i].bpc1000 > 8000) {
						ceiling_violations++;
						printk("CHK ceiling_violation p=%s h=%d op=%s "
						       "sz=%u bpc1000=%u\n",
						       PHASE_NAME[p], s, OP_NAME[o],
						       (unsigned int)SIZES[i],
						       bw[p][s][o][i].bpc1000);
					}
				}
			}
		}
	}
	printk("CHK ceiling violations=%d limit_bpc1000=8000\n", ceiling_violations);
	printk("CHK harts h0=%u h1=%u distinct=%d\n", jobs[0].hartid, jobs[1].hartid,
	       jobs[0].hartid != jobs[1].hartid);

	printk("RESULT: %s\n", (ok && ceiling_violations == 0) ? "PASS" : "FAIL");
	printk("MEMBENCH_DONE\n");
	return 0;
}
