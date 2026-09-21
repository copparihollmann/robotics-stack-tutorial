/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Two harts, two TACIT encoders, two DMA sinks, ONE timeline.
 *
 * samples/tacit_dma traces one hart. Two harts is not just that twice: TACIT stamps every
 * packet with a delta in `mcycle`, `mcycle` is per-hart, and stock Rocket STOPS it while
 * the hart sits in `wfi` (rocket/CSR.scala gates the counter on `!io.csr_stall`, and
 * `io.csr_stall = reg_wfi || io.status.cease`). Two harts that idle for different amounts
 * of time therefore hold two different timebases, and their traces cannot be placed on a
 * common axis. patches/0004-rocketchip-mcycle-free-run.patch removes `reg_wfi` from that
 * enable. This sample is the instrument that measures whether it worked.
 *
 * THE EXPERIMENT
 *
 *   R0  both workers rendezvous the instant they get a CPU, and each records mcycle.
 *       Skew here is whatever hart 1 accumulated idling between coming online and this
 *       thread starting.
 *
 *   IDLE DIFFERENTIAL -- the part that makes the defect visible and controllable.
 *       hart 0 spins in k_busy_wait() (executing: mcycle counts either way)
 *       hart 1 sleeps in k_msleep()   (its idle thread executes `wfi`: mcycle stops,
 *                                      unpatched)
 *       Same wall-clock duration, deliberately different mcycle cost.
 *
 *   R1  rendezvous again, record mcycle. The difference between the R1 skew and the R0
 *       skew is the idle differential's cost, and is the number that must collapse.
 *
 *   ENCODERS ON -- each worker programs ITS OWN encoder and sink and enables tracing.
 *       Done after R1 so the traced window is short: the barrier below is the subject,
 *       not the idle.
 *
 *   R2  THE EVENT. A cross-hart barrier, the same construction samples/smp_hart_proof
 *       uses: both workers atomic_inc a shared counter and spin until it reaches 2. It
 *       cannot complete unless both harts are executing at that instant, so both harts
 *       leave it at the same physical time, to within the coherence latency of one
 *       shared line. Each worker reads rdcycle the moment it leaves, and then calls
 *       tacit_sync_marker() -- a noinline function called exactly once inside the traced
 *       window, so it appears exactly once in each hart's decoded trace.
 *
 * So there are two independent measurements of the same skew:
 *
 *   software  : barrier_cycle[1] - barrier_cycle[0], read from the mcycle CSR
 *   trace     : the timestamp of the tacit_sync_marker slice in each decoded trace
 *
 * They must agree, and after the patch both must be small. Before the patch both are
 * large and grow with IDLE_MS. scripts/26_rocket_tacit_smp.sh does the trace half.
 *
 * WHY THE ORDER OF THE TACIT CALLS IS WHAT IT IS -- see samples/tacit_dma/src/main.c;
 * the same eight steps apply per hart. The two differences here are that step 8 (the L2
 * flush) is done once, by main(), for both buffers after both workers have stopped --
 * the Flush64 register is a single shared MMIO location and there is no reason to have
 * two harts writing it concurrently -- and that the buffers are placed with the scheme
 * patches/0003 introduced for the boot trace: base + (hartid << shift).
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>

#include <tacit/tacit.h>

#define WORKERS    2
#define STACK_SIZE 2048

/*
 * Trace buffers, in ROCKET's address space, one per hart, placed exactly the way
 * CONFIG_STARTUP_TACIT_SINK_DMA_ADDR / _SHIFT place them in reset.S:
 *
 *     buffer(hart) = TACIT_BUF_BASE + (hartid << TACIT_BUF_SHIFT)
 *
 * 0x8800_0000 is 128 MB into the 256 MB window; the shift of 24 gives each hart 16 MB, so
 * hart 0 owns 0x8800_0000 and hart 1 owns 0x8900_0000, and the pair ends at 0x8A00_0000 --
 * well clear of the top of DRAM and 128 MB clear of the guest, whose image, heap and
 * stacks live in the first few hundred KB of 0x8000_0000.
 *
 * The FPGA top folds Rocket's DRAM window with {4'd1, addr[27:0]}, so hart 0's buffer is
 * PS physical 0x1800_0000 and hart 1's is 0x1900_0000.
 */
#ifndef TACIT_BUF_BASE
#define TACIT_BUF_BASE 0x88000000UL
#endif
#ifndef TACIT_BUF_SHIFT
#define TACIT_BUF_SHIFT 24
#endif
#define TACIT_BUF_SPAN (1UL << TACIT_BUF_SHIFT)

/*
 * The idle differential. 200 ms is 8,000,000 core cycles at 40 MHz -- three orders of
 * magnitude above any plausible barrier-release skew, so "before" and "after" cannot be
 * confused for one another by any amount of measurement noise.
 */
#ifndef IDLE_MS
#define IDLE_MS 200
#endif

/* Rendezvous deadlines. Ticks are mtime at 40 kHz, so 40000 = 1 s. */
#define RV_TICKS      40000U
/* R2 is spun without touching mtime (see below), so its deadline is an iteration count. */
#define R2_SPIN_LIMIT 200000000U

/* SiFive InclusiveCache control node: cache-controller@2010000, reg-names "control". */
#define L2_CTRL_BASE 0x2010000UL
#define L2_CONFIG    (L2_CTRL_BASE + 0x000) /* banks | ways<<8 | lgSets<<16 | lgBlk<<24 */
#define L2_FLUSH64   (L2_CTRL_BASE + 0x200) /* write a phys addr -> flush that block */

K_THREAD_STACK_ARRAY_DEFINE(worker_stacks, WORKERS, STACK_SIZE);
static struct k_thread worker_threads[WORKERS];
static struct k_sem done_sem;

static atomic_t rv0_count;
static atomic_t rv1_count;
static atomic_t rv2_count;

struct hart_result {
	uint32_t cpu_id;
	uint32_t hartid;
	uint64_t buf;           /* Rocket-side address of this hart's trace buffer */
	uint64_t bytes;         /* what the sink's addr_counter reported after its flush */
	uint64_t addr_rb;       /* TR_SK_DMA_ADDR read back, to prove the write latched */
	uint64_t c_rv0;         /* mcycle at R0  */
	uint64_t c_rv1;         /* mcycle at R1  */
	uint64_t c_rv2;         /* mcycle at R2 -- THE synchronisation event */
	uint64_t c_marker;      /* mcycle just before the call to tacit_sync_marker() */
	uint32_t t_rv0;         /* mtime at R0, the shared reference */
	uint32_t t_rv1;
	uint32_t t_rv2;         /* mtime just after the marker (see the worker) */
	uint32_t marker_result; /* keeps the marker's work alive */
	bool     rv0_ok, rv1_ok, rv2_ok;
	bool     ran;
	bool     sink_ok;
};

static struct hart_result results[WORKERS];

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/*
 * THE MARKER. Called exactly once inside each hart's traced window, immediately after the
 * barrier releases, so it lands in both decoded traces as a single slice whose timestamp
 * is the barrier instant on that hart's timebase.
 *
 * Not static and not inlinable, because the decoder resolves slice names out of the ELF's
 * symbol table: a function that gcc inlines, clones or tail-merges has no call to observe
 * and no name to report. `noclone` matters as much as `noinline` -- gcc will happily
 * produce tacit_sync_marker.constprop.0 given a constant argument, which would still
 * trace but under a name the runner does not know to look for.
 *
 * The body is a short integer chain rather than a single `ret`: the encoder emits packets
 * on control-flow events, so a function containing no branch at all would be visible only
 * as the call and the return. The loop gives the call site an unambiguous shape in
 * trace.txt as well as in the Perfetto slice list.
 */
__attribute__((noinline, noclone))
uint32_t tacit_sync_marker(uint32_t seed)
{
	uint32_t x = seed;

	for (int i = 0; i < 8; i++) {
		x = x * 1664525U + 1013904223U;
		x ^= x >> 7;
	}
	return x;
}

/* Body of the traced window after the marker: enough control flow that the trace has
 * shape, small enough that it does not bury the marker. */
__attribute__((noinline, noclone))
uint32_t tacit_post_barrier_work(uint32_t seed)
{
	uint32_t x = seed;

	for (int i = 0; i < 64; i++) {
		x = x * 1103515245U + 12345U;
		if (x & 0x10000U) {
			x ^= 0xA5A5A5A5U;
		}
	}
	return x;
}

/* mtime, one counter in the CLINT shared by both harts. */
static inline uint32_t now(void)
{
	return k_cycle_get_32();
}

/*
 * Rendezvous on mtime, for the two points where a few microseconds do not matter. Reading
 * mtime is an uncached MMIO load, so this is NOT how R2 is spun.
 */
static bool rendezvous(atomic_t *ctr)
{
	uint32_t t0 = now();

	atomic_inc(ctr);
	while ((now() - t0) < RV_TICKS) {
		if (atomic_get(ctr) >= WORKERS) {
			return true;
		}
	}
	return false;
}

static void l2_flush_range(uintptr_t base, uint64_t bytes, uint32_t block)
{
	volatile uint64_t *flush = (volatile uint64_t *)L2_FLUSH64;
	uintptr_t a = base & ~(uintptr_t)(block - 1);
	uintptr_t end = base + bytes;

	__asm__ volatile("fence" ::: "memory");
	for (; a < end; a += block) {
		*flush = (uint64_t)a;
	}
	__asm__ volatile("fence" ::: "memory");
}

static void worker(void *p1, void *p2, void *p3)
{
	int idx = (int)(intptr_t)p1;
	struct hart_result *r = &results[idx];
	uint32_t hartid = (uint32_t)csr_read(mhartid);
	LTraceEncoderType *enc = l_trace_encoder_get(hartid);
	LTraceSinkDmaType *sink = l_trace_sink_dma_get(hartid);
	uint64_t buf = TACIT_BUF_BASE + ((uint64_t)hartid << TACIT_BUF_SHIFT);
	uint32_t spin;

	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	r->cpu_id = arch_curr_cpu()->id;
	r->hartid = hartid;
	r->buf = buf;
	r->ran = true;

	/* R0 -- as early as this thread can get a timestamp that the other hart also has. */
	r->rv0_ok = rendezvous(&rv0_count);
	r->c_rv0 = rdcycle();
	r->t_rv0 = now();

	/*
	 * The idle differential. Same wall-clock duration on both harts; only hart 1
	 * spends it in `wfi`.
	 *
	 * k_busy_wait() spins against mtime, not against mcycle, so it is not itself
	 * affected by the patch under test -- it measures the same wall time either way.
	 * k_msleep() parks this thread; with nothing else runnable on CPU 1 the idle
	 * thread takes over and executes `wfi`.
	 */
	if (idx == 0) {
		k_busy_wait(IDLE_MS * 1000);
	} else {
		k_msleep(IDLE_MS);
	}

	/* R1 -- the idle differential is now behind both harts. */
	r->rv1_ok = rendezvous(&rv1_count);
	r->c_rv1 = rdcycle();
	r->t_rv1 = now();

	/* Warm the marker and the post-barrier body into this core's I-cache BEFORE the
	 * encoder is enabled. The little core has a 1-way 4 KB I-cache; a cold miss on the
	 * marker would show up as a few hundred cycles of skew that has nothing to do with
	 * the timebase. */
	r->marker_result = tacit_post_barrier_work(tacit_sync_marker(hartid + 1U));

	/* --- TACIT, this hart's encoder and this hart's sink only --- */
	l_trace_encoder_stop(enc);                              /* 1 */
	l_trace_sink_dma_configure_addr(sink, buf, 0);          /* 2 */
	l_trace_encoder_configure_target(enc, TARGET_DMA);      /* 3 */
	l_trace_encoder_configure_branch_mode(enc, BRANCH_MODE_TARGET);
	r->addr_rb = sink->TR_SK_DMA_ADDR;
	r->sink_ok = (r->addr_rb == buf);
	if (!r->sink_ok) {
		goto out;
	}
	l_trace_encoder_start(enc);                             /* 4 */

	/*
	 * R2 -- THE EVENT.
	 *
	 * Spun on the shared atomic alone: no mtime read in the loop, because an uncached
	 * MMIO load to the CLINT is ~40 cycles and both harts would be contending for the
	 * same port, which would put bus arbitration straight into the quantity being
	 * measured. The deadline is an iteration count instead.
	 *
	 * rdcycle immediately after the loop is a CSR read -- no bus, no cache -- so the
	 * gap between "this hart observed the barrier" and "this hart's mcycle was
	 * sampled" is a handful of cycles and is the same code on both harts.
	 */
	atomic_inc(&rv2_count);
	r->rv2_ok = false;
	for (spin = 0; spin < R2_SPIN_LIMIT; spin++) {
		if (atomic_get(&rv2_count) >= WORKERS) {
			r->rv2_ok = true;
			break;
		}
	}
	r->c_rv2 = rdcycle();

	r->c_marker = rdcycle();
	r->marker_result = tacit_sync_marker(r->marker_result);   /* 5 -- THE marker */
	r->marker_result = tacit_post_barrier_work(r->marker_result);
	/* mtime, AFTER the marker on purpose. It is the independent confirmation that the
	 * two harts really were at the same wall-clock instant here -- but reading it is an
	 * uncached MMIO load to a CLINT both harts are hitting at once, so it must not sit
	 * between the barrier and the marker, where its latency would land straight in the
	 * quantity being measured. */
	r->t_rv2 = now();

	l_trace_encoder_stop(enc);                              /* 6 */
	/* The trailing sync packet needs retired instructions to push it through. */
	for (volatile int i = 0; i < 2000; i++) {
		__asm__ volatile("nop");
	}

	sink->TR_SK_DMA_FLUSH = 1;                              /* 7 */
	while (sink->TR_SK_DMA_FLUSH_DONE == 0) {
	}
	r->bytes = sink->TR_SK_DMA_COUNT;

out:
	/* 8 (the L2 flush) is main()'s job, once, for both buffers. */
	k_sem_give(&done_sem);
}

int main(void)
{
	uint32_t l2cfg = *(volatile uint32_t *)L2_CONFIG;
	uint32_t l2_block = 1u << ((l2cfg >> 24) & 0xff);
	unsigned int ncpus = arch_num_cpus();
	int finished, i;
	int64_t skew0, skew1, skew2;
	bool ok;

	printk("\n=== tacit_smp on %s ===\n", CONFIG_BOARD_TARGET);
	printk("arch_num_cpus        = %u\n", ncpus);
	printk("sys_clock_hw_cycles  = %u Hz (mtime)\n", sys_clock_hw_cycles_per_sec());
	printk("l2: banks=%u ways=%u lgSets=%u block=%u\n", l2cfg & 0xff,
	       (l2cfg >> 8) & 0xff, (l2cfg >> 16) & 0xff, l2_block);
	printk("idle differential    = %u ms (hart 0 busy-waits, hart 1 sleeps in wfi)\n",
	       IDLE_MS);

	if (ncpus < WORKERS) {
		printk("TACIT_SMP_FAIL only %u CPU(s) -- CONFIG_MP_MAX_NUM_CPUS must be >= %d\n",
		       ncpus, WORKERS);
		return 0;
	}

	k_sem_init(&done_sem, 0, WORKERS);

	/* Create suspended, pin, then start: k_thread_cpu_pin() needs a thread that has
	 * not begun running. Without the pin there is no guarantee that the two workers
	 * land on two different harts, and the whole measurement is vacuous. */
	for (i = 0; i < WORKERS; i++) {
		k_tid_t tid = k_thread_create(&worker_threads[i], worker_stacks[i],
					      STACK_SIZE, worker,
					      (void *)(intptr_t)i, NULL, NULL,
					      5, 0, K_FOREVER);
		int rc = k_thread_cpu_pin(tid, i);

		if (rc != 0) {
			printk("TACIT_SMP_FAIL k_thread_cpu_pin(worker %d -> CPU %d) = %d\n",
			       i, i, rc);
			return 0;
		}
	}
	for (i = 0; i < WORKERS; i++) {
		k_thread_start(&worker_threads[i]);
	}

	/* NOT K_FOREVER: a worker pinned to a hart that never came online never runs, and
	 * a console that simply stops is the least useful possible failure. */
	finished = 0;
	for (i = 0; i < WORKERS; i++) {
		if (k_sem_take(&done_sem, K_SECONDS(30)) == 0) {
			finished++;
		}
	}

	/* 8. The sinks are masters on the system bus, so their writes are sitting in the
	 * inclusive L2 and the PS reads DRAM. Both buffers, now that both sinks are idle. */
	for (i = 0; i < WORKERS; i++) {
		if (results[i].bytes > 0 && results[i].bytes <= TACIT_BUF_SPAN) {
			l2_flush_range((uintptr_t)results[i].buf, results[i].bytes, l2_block);
		}
	}

	ok = (finished == WORKERS);
	for (i = 0; i < WORKERS; i++) {
		struct hart_result *r = &results[i];

		if (!r->ran) {
			printk("TACIT_HART idx=%d NEVER_RAN\n", i);
			ok = false;
			continue;
		}
		if (!r->rv0_ok || !r->rv1_ok || !r->rv2_ok || !r->sink_ok || r->bytes == 0) {
			ok = false;
		}
		/* One line per hart, everything the runner needs to drain and check. */
		printk("TACIT_HART idx=%d cpu=%u hart=%u buf=0x%08x bytes=%u "
		       "addr_rb=0x%08x rv=%d%d%d\n",
		       i, r->cpu_id, r->hartid, (unsigned int)r->buf,
		       (unsigned int)r->bytes, (unsigned int)r->addr_rb,
		       r->rv0_ok, r->rv1_ok, r->rv2_ok);
		printk("TACIT_TIME idx=%d hart=%u c_rv0=%llu c_rv1=%llu c_rv2=%llu "
		       "c_marker=%llu t_rv0=%u t_rv1=%u t_rv2=%u\n",
		       i, r->hartid,
		       (unsigned long long)r->c_rv0, (unsigned long long)r->c_rv1,
		       (unsigned long long)r->c_rv2, (unsigned long long)r->c_marker,
		       r->t_rv0, r->t_rv1, r->t_rv2);
	}

	/*
	 * The software half of the answer. mcycle is 64-bit and both harts left reset
	 * together, so these differences are signed but small in magnitude compared with
	 * either counter -- a plain int64 subtraction is exact.
	 */
	skew0 = (int64_t)results[1].c_rv0 - (int64_t)results[0].c_rv0;
	skew1 = (int64_t)results[1].c_rv1 - (int64_t)results[0].c_rv1;
	skew2 = (int64_t)results[1].c_rv2 - (int64_t)results[0].c_rv2;

	printk("\n-- mcycle skew, hart1 - hart0, measured in software\n");
	printk("   R0 (thread start)      : %lld cycles   (mtime %d ticks)\n",
	       (long long)skew0, (int)(results[1].t_rv0 - results[0].t_rv0));
	printk("   R1 (after %u ms idle)  : %lld cycles   (mtime %d ticks)\n",
	       IDLE_MS, (long long)skew1, (int)(results[1].t_rv1 - results[0].t_rv1));
	printk("   R2 (the barrier)       : %lld cycles   (mtime %d ticks, sampled after the marker)\n",
	       (long long)skew2, (int)(results[1].t_rv2 - results[0].t_rv2));
	printk("   idle cost (R1 - R0)    : %lld cycles\n",
	       (long long)(skew1 - skew0));
	printk("   marker call gap        : hart0 %llu, hart1 %llu cycles after R2\n",
	       (unsigned long long)(results[0].c_marker - results[0].c_rv2),
	       (unsigned long long)(results[1].c_marker - results[1].c_rv2));

	printk("\nTACIT_SKEW sw_r0=%lld sw_r1=%lld sw_r2=%lld idle_cost=%lld\n",
	       (long long)skew0, (long long)skew1, (long long)skew2,
	       (long long)(skew1 - skew0));
	printk("TACIT_SMP_DONE harts=%d ok=%d\n", finished, ok);
	return 0;
}
