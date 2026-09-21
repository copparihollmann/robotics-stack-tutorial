/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Prove that a Zephyr SMP image is really executing on BOTH harts of the dual-core
 * big.LITTLE Rocket, rather than booting and quietly running everything on hart 0.
 *
 * "It booted" is not evidence. Four independent things are measured here, and each one
 * fails in a distinguishable way if the second hart never came out of the bootrom:
 *
 *   1. IDENTITY   Each pinned worker reads the mhartid CSR -- the hardware's own answer,
 *                 not a Zephyr variable -- and reports it alongside arch_curr_cpu()->id.
 *                 If both workers report mhartid 0, the pinning or the CPU-to-hart map is
 *                 wrong even though two "CPUs" exist.
 *
 *   2. BARRIER    Both workers atomically increment a shared counter and then spin until
 *                 it reaches 2. This CANNOT complete unless the two threads are running at
 *                 the same instant on different harts: they are pinned to different CPUs,
 *                 neither yields, and neither can be descheduled in favour of the other.
 *                 It also exercises RISC-V AMOs across two L1 caches, i.e. real coherence
 *                 through the inclusive L2. There is a deadline so a single-core failure
 *                 reports instead of hanging.
 *
 *   3. OVERLAP    Each worker busy-works for a fixed number of mtime ticks and records the
 *                 window it occupied. mtime is ONE counter in the CLINT shared by both
 *                 harts (mcycle is per-hart and Rocket stops it in wfi, so it is useless
 *                 for this), which makes the two windows directly comparable. Overlapping
 *                 windows plus a wall-clock time of ~1x the job, not ~2x, is concurrency.
 *
 *   4. PING-PONG  The two harts hand a sequence number back and forth through one shared
 *                 cache line. Every round trip is a store on one hart observed by a load
 *                 on the other. A single-core run cannot make progress here at all.
 *
 * Read the output bottom-up: the RESULT line is a conjunction of all four.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>

#define WORKERS         2
#define STACK_SIZE      2048
#define WORK_TICKS      20000U   /* mtime ticks; at 40 kHz that is 0.5 s */
#define BARRIER_TICKS   40000U   /* 1 s deadline for both harts to reach the barrier */
#define PINGPONG_ROUNDS 2000
#define PINGPONG_TICKS  40000U   /* 1 s deadline for the ping-pong phase */
#define CHUNK           256      /* ALU iterations between two mtime reads */
#define JOIN_TIMEOUT_S  15       /* how long main() waits for a worker before giving up */

K_THREAD_STACK_ARRAY_DEFINE(worker_stacks, WORKERS, STACK_SIZE);
static struct k_thread worker_threads[WORKERS];
static struct k_sem done_sem;

struct result {
	uint32_t cpu_id;
	uint32_t hartid;
	uint32_t t_start;     /* mtime tick at which the timed loop began */
	uint32_t t_end;       /* ... and ended */
	uint32_t barrier_t;   /* mtime tick at which this worker cleared the barrier */
	uint64_t iters;       /* iterations of the busy loop -- a rough per-core speed */
	bool     barrier_ok;
	bool     ran;         /* set the instant this worker gets a CPU at all */
};

static struct result results[WORKERS];

/* Shared state. `volatile` because the whole point is that another hart writes it. */
static atomic_t barrier_count;
static volatile uint32_t pingpong_cell;
static volatile uint32_t pingpong_rounds_done;
static volatile bool     pingpong_timeout;

/* Somewhere for the busy loop's result to go, so the compiler cannot delete it -- one per
 * worker, each on its own 64-byte cache block (the DTS reports d-cache-block-size = 64).
 * A single shared sink would put the two harts in a coherence ping-pong on one line for
 * the whole timed loop, which would still prove concurrency but would turn the
 * iteration counts into a measurement of the L2 rather than of the cores.
 */
struct padded_sink {
	volatile uint32_t v;
	uint8_t pad[64 - sizeof(uint32_t)];
} __aligned(64);
static struct padded_sink sink[WORKERS];

/* mtime, via Zephyr's cycle counter. One counter in the CLINT, shared by both harts. */
static inline uint32_t now(void)
{
	return k_cycle_get_32();
}

static void worker(void *p1, void *p2, void *p3)
{
	int idx = (int)(intptr_t)p1;
	struct result *r = &results[idx];
	uint64_t iters = 0;
	uint32_t t0;

	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	/* 1. identity, straight from the CSR */
	r->cpu_id = arch_curr_cpu()->id;
	r->hartid = csr_read(mhartid);
	r->ran = true;

	/* 2. barrier: cannot pass unless the other hart is executing right now */
	t0 = now();
	atomic_inc(&barrier_count);
	r->barrier_ok = false;
	while ((now() - t0) < BARRIER_TICKS) {
		if (atomic_get(&barrier_count) >= WORKERS) {
			r->barrier_ok = true;
			break;
		}
	}
	r->barrier_t = now();

	/* 3. timed busy-work, with the window recorded on the shared mtime base.
	 *
	 *    The inner chunk is pure ALU work. Reading mtime is an uncached MMIO load over
	 *    the periphery bus -- if the loop checked the clock every iteration it would be
	 *    measuring bus latency (and contention between the two harts on the CLINT),
	 *    not core throughput.
	 */
	r->t_start = now();
	while ((now() - r->t_start) < WORK_TICKS) {
		uint32_t x = (uint32_t)iters;

		for (int k = 0; k < CHUNK; k++) {
			x = x * 1664525U + 1013904223U;   /* LCG: 1 mul + 1 add, no memory */
			x ^= x >> 7;
		}
		sink[idx].v += x;
		iters++;
	}
	r->t_end = now();
	r->iters = iters;

	/* 4. ping-pong through one shared word.
	 *    worker 0 waits for an even value and makes it odd; worker 1 does the reverse.
	 *    Only forward progress on BOTH harts advances the count.
	 */
	t0 = now();
	while (pingpong_rounds_done < PINGPONG_ROUNDS && !pingpong_timeout) {
		uint32_t want = (uint32_t)idx;           /* 0 waits for even, 1 for odd */

		if ((pingpong_cell & 1U) == want) {
			pingpong_cell++;
			if (idx == 1) {
				pingpong_rounds_done++;
			}
		}
		if ((now() - t0) > PINGPONG_TICKS) {
			pingpong_timeout = true;
		}
	}

	k_sem_give(&done_sem);
}

/* Overlap of two closed intervals, in mtime ticks. */
static uint32_t overlap(uint32_t a0, uint32_t a1, uint32_t b0, uint32_t b1)
{
	uint32_t lo = MAX(a0, b0);
	uint32_t hi = MIN(a1, b1);

	return (hi > lo) ? (hi - lo) : 0U;
}

int main(void)
{
	uint32_t wall0, wall1, ov, shorter;
	unsigned int ncpus = arch_num_cpus();
	int finished;
	bool distinct_harts, both_barriers, overlapped, pingpong_ok, pass;
	int i;

	printk("\n=== smp_hart_proof on %s ===\n", CONFIG_BOARD_TARGET);
	printk("arch_num_cpus        = %u\n", ncpus);
	printk("main() cpu id        = %u   mhartid = %lu\n",
	       arch_curr_cpu()->id, (unsigned long)csr_read(mhartid));
	printk("sys_clock_hw_cycles  = %u Hz (mtime)\n", sys_clock_hw_cycles_per_sec());

	if (ncpus < WORKERS) {
		printk("FAIL: only %u CPU(s) configured -- "
		       "CONFIG_MP_MAX_NUM_CPUS must be >= %d\n", ncpus, WORKERS);
		return 0;
	}

	k_sem_init(&done_sem, 0, WORKERS);

	/* Create suspended, pin, then start: k_thread_cpu_pin() requires a thread that has
	 * not begun running yet.
	 */
	for (i = 0; i < WORKERS; i++) {
		k_tid_t tid = k_thread_create(&worker_threads[i], worker_stacks[i],
					      STACK_SIZE, worker,
					      (void *)(intptr_t)i, NULL, NULL,
					      5, 0, K_FOREVER);
		int rc = k_thread_cpu_pin(tid, i);

		if (rc != 0) {
			printk("FAIL: k_thread_cpu_pin(worker %d -> CPU %d) = %d\n", i, i, rc);
			return 0;
		}
	}

	wall0 = now();
	for (i = 0; i < WORKERS; i++) {
		k_thread_start(&worker_threads[i]);
	}
	/* NOT K_FOREVER. If hart 1 never left the bootrom, worker 1 is pinned to a CPU that
	 * does not exist and will never run, so main() would block here forever and the
	 * console would simply stop -- the least useful possible failure. Time out instead
	 * and print what did happen.
	 */
	finished = 0;
	for (i = 0; i < WORKERS; i++) {
		if (k_sem_take(&done_sem, K_SECONDS(JOIN_TIMEOUT_S)) == 0) {
			finished++;
		}
	}
	wall1 = now();
	if (finished < WORKERS) {
		printk("\nWARNING: only %d of %d workers finished within %d s -- "
		       "a worker pinned to a CPU that never came online never runs\n",
		       finished, WORKERS, JOIN_TIMEOUT_S);
	}

	printk("\n-- 1. identity (mhartid read from the CSR on each pinned worker)\n");
	for (i = 0; i < WORKERS; i++) {
		if (!results[i].ran) {
			printk("   worker pinned to CPU %d : NEVER RAN\n", i);
			continue;
		}
		printk("   worker pinned to CPU %d : arch_curr_cpu()->id = %u, mhartid = %u\n",
		       i, results[i].cpu_id, results[i].hartid);
	}

	printk("\n-- 2. cross-hart barrier (atomic_inc + spin, %u-tick deadline)\n",
	       BARRIER_TICKS);
	for (i = 0; i < WORKERS; i++) {
		printk("   hart %u : %s (at t=%u)\n", results[i].hartid,
		       results[i].barrier_ok ? "passed" : "TIMED OUT",
		       results[i].barrier_t);
	}

	printk("\n-- 3. execution windows on the shared mtime counter\n");
	for (i = 0; i < WORKERS; i++) {
		printk("   hart %u : [%u .. %u]  %u ticks, %llu iterations\n",
		       results[i].hartid, results[i].t_start, results[i].t_end,
		       results[i].t_end - results[i].t_start,
		       (unsigned long long)results[i].iters);
	}
	ov = overlap(results[0].t_start, results[0].t_end,
		     results[1].t_start, results[1].t_end);
	shorter = MIN(results[0].t_end - results[0].t_start,
		      results[1].t_end - results[1].t_start);
	printk("   overlap : %u ticks (%u%% of the shorter window)\n",
	       ov, shorter ? (unsigned int)((uint64_t)ov * 100U / shorter) : 0U);
	printk("   wall    : %u ticks for 2 x %u ticks of work "
	       "(serial would need >= %u)\n",
	       wall1 - wall0, WORK_TICKS, 2U * WORK_TICKS);

	printk("\n-- 4. ping-pong through one shared word\n");
	printk("   %u/%d round trips%s\n", pingpong_rounds_done, PINGPONG_ROUNDS,
	       pingpong_timeout ? "  (TIMED OUT)" : "");

	/* iterations/tick is a crude per-core speed. The two cores are deliberately not
	 * identical -- 16 KB vs 4 KB L1s -- so a difference here is the "big.LITTLE" part
	 * showing up, not an error.
	 */
	printk("\n-- 5. relative core speed (same loop, same duration)\n");
	for (i = 0; i < WORKERS; i++) {
		uint32_t w = results[i].t_end - results[i].t_start;

		printk("   hart %u : %llu iterations / %u ticks\n", results[i].hartid,
		       (unsigned long long)results[i].iters, w);
	}

	distinct_harts = results[0].ran && results[1].ran &&
			 (results[0].hartid != results[1].hartid);
	both_barriers  = results[0].barrier_ok && results[1].barrier_ok;
	overlapped     = shorter && (ov * 2U >= shorter);   /* >= 50% overlap */
	pingpong_ok    = (pingpong_rounds_done >= PINGPONG_ROUNDS);
	pass = distinct_harts && both_barriers && overlapped && pingpong_ok;

	printk("\nCHECKS  distinct_harts=%d barrier=%d overlap=%d pingpong=%d\n",
	       distinct_harts, both_barriers, overlapped, pingpong_ok);
	printk("RESULT: %s\n", pass ? "PASS -- work ran concurrently on hart 0 and hart 1"
				   : "FAIL -- see the checks above");
	return 0;
}
