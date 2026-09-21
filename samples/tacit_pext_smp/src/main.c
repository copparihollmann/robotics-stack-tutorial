/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * A HETEROGENEOUS TRACE: two harts, two TACIT encoders, one timeline, and the two harts
 * visibly executing DIFFERENT INSTRUCTION SETS inside it.
 *
 * samples/tacit_smp puts both harts on one timebase and proves it with a cross-hart
 * barrier that lands at the same cycle in both traces. It is the instrument, and this
 * sample is that instrument pointed at the thing the SoC exists to demonstrate:
 *
 *   hart 0 (BIG)    runs MB_PEXT_ROUNDS iterations of a loop built out of the four MBP
 *                   packed-SIMD instructions -- real custom-0 encodings, because this
 *                   image is CONFIG_MB_PEXT=y and the routed ALU on tile 0 has them.
 *
 *   hart 1 (LITTLE) runs the SAME loop, the same number of times, over pext.h's own
 *                   software model of those four instructions -- ordinary rv64imac. It
 *                   MUST NOT execute a custom-0 word: there is no MBP datapath on tile 1
 *                   and the encoding is illegal there (Lab B9 proves that separately).
 *
 * So the two decoded traces share an axis and do not share an instruction mix, which is
 * exactly the claim "heterogeneous" has to mean to be worth anything.
 *
 * THREE THINGS THIS PRINTS THAT THE RUNNER CHECKS AGAINST THE DECODED TRACE, rather than
 * the runner trusting the decoder:
 *
 *   PEXT_EXPECT   the number of times each MBP op executes inside the traced window,
 *                 computed from the loop's trip count -- which is a compile-time constant
 *                 and has no data-dependent exit. scripts/31 counts the `mbp.*` lines the
 *                 decoder emitted for hart 0 and they must be the same four numbers. A
 *                 decoder that dropped, duplicated or mis-split these would still produce
 *                 a plausible-looking trace.
 *
 *   PEXT_RESULT   the loop's answer on each hart. Hart 0 computed it with the hardware,
 *                 hart 1 with the software model, and PEXT_SPEC.md 3.5 makes the model
 *                 the normative definition -- so the two 64-bit words must be EQUAL. This
 *                 is a bit-exactness check on the routed ALU that costs nothing here and
 *                 is independent of ModelBlaster entirely.
 *
 *   TACIT_TIME    the barrier instant on each hart, read from mcycle in software, for the
 *                 same cross-check samples/tacit_smp uses.
 *
 * WHAT IS UNCHANGED FROM samples/tacit_smp, and deliberately so: the R0 / idle
 * differential / R1 / encoders-on / R2 structure, the buffer placement, the flush order,
 * the marker, and every comment's worth of reasoning about why the barrier is spun on an
 * atomic rather than on mtime. That sample is not modified; this one is a sibling because
 * its image is built CONFIG_MB_PEXT=y, which that one must never be.
 *
 * WHY THE PINNING IS LOAD-BEARING HERE TWICE OVER. In tacit_smp an unpinned worker makes
 * the measurement vacuous. Here it makes the image CRASH: the MBP body on hart 1 is an
 * illegal instruction. k_thread_cpu_pin() before k_thread_start() is what keeps the two
 * bodies on the two harts, and MB_PEXT_ASSERT_BIG_HART() names the cause if it ever does
 * not.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>

#include <tacit/tacit.h>

#include "pext.h"

#define WORKERS    2
#define STACK_SIZE 2048

/* Buffers in ROCKET's address space, one per hart, placed exactly the way
 * CONFIG_STARTUP_TACIT_SINK_DMA_ADDR / _SHIFT place them in reset.S:
 *
 *     buffer(hart) = TACIT_BUF_BASE + (hartid << TACIT_BUF_SHIFT)
 *
 * hart 0 owns 0x8800_0000 and hart 1 owns 0x8900_0000; the FPGA top folds Rocket's DRAM
 * window with {4'd1, addr[27:0]}, so those are PS physical 0x1800_0000 and 0x1900_0000.
 */
#ifndef TACIT_BUF_BASE
#define TACIT_BUF_BASE 0x88000000UL
#endif
#ifndef TACIT_BUF_SHIFT
#define TACIT_BUF_SHIFT 24
#endif
#define TACIT_BUF_SPAN (1UL << TACIT_BUF_SHIFT)

/*
 * The idle differential, as in samples/tacit_smp: same wall time on both harts, and only
 * hart 1 spends it in `wfi`. 200 ms is 6,896,600 core cycles at 34.4828 MHz -- three
 * orders of magnitude above any plausible barrier-release skew, so the patched and
 * unpatched RTL cannot be confused for one another by measurement noise.
 */
#ifndef IDLE_MS
#define IDLE_MS 200
#endif

/*
 * The traced MBP body. Each round executes exactly one of each op, so the dynamic counts
 * are 4 x MB_PEXT_ROUNDS and the runner can check them against the decoder without
 * knowing anything about the loop.
 *
 * 24 rounds: enough that a dropped or duplicated packet is unmistakable, small enough
 * that the whole traced window stays readable in Perfetto.
 */
#ifndef MB_PEXT_ROUNDS
#define MB_PEXT_ROUNDS 24
#endif

/*
 * THE SEED, AND WHY IT IS A CONSTANT RATHER THAN THE HART ID.
 *
 * The two bodies are compared against each other -- hart 0's routed MBP datapath against
 * hart 1's software model of it -- so they must be fed THE SAME INPUT.  The first version
 * of this sample seeded each hart with its own `mhartid`, which made the two harts compute
 * the same function on different arguments and report `equal=0` on correct hardware.  That
 * is a test that accuses the silicon of the exact defect it exists to detect, and it is
 * worth a named constant to make impossible.  See PEXT_VALIDATION.md section 4.
 *
 * The value is arbitrary but not degenerate.  Over the 24 traced rounds it puts 93 of the
 * 192 int8 lanes that reach DOT8 and MAX8 at a negative value, and saturates CLIP8 twice --
 * so a sign-extension or a saturation bug in the routed datapath changes the answer rather
 * than hiding in it.  (The instruction-level acceptance test is samples/pext_hart_proof's
 * 3,041 checks; this is a cheap end-to-end corroboration inside the traced window.)
 */
#define MB_PEXT_SEED 0x0123456789abcdefLL

/* Rendezvous deadlines. Ticks are mtime at 34.4828 kHz, so 34483 = 1 s. */
#define RV_TICKS      34483U
#define R2_SPIN_LIMIT 200000000U

/* SiFive InclusiveCache control node: cache-controller@2010000, reg-names "control". */
#define L2_CTRL_BASE 0x2010000UL
#define L2_CONFIG    (L2_CTRL_BASE + 0x000)
#define L2_FLUSH64   (L2_CTRL_BASE + 0x200)

K_THREAD_STACK_ARRAY_DEFINE(worker_stacks, WORKERS, STACK_SIZE);
static struct k_thread worker_threads[WORKERS];
static struct k_sem done_sem;

static atomic_t rv0_count;
static atomic_t rv1_count;
static atomic_t rv2_count;

struct hart_result {
	uint32_t cpu_id;
	uint32_t hartid;
	uint64_t buf;
	uint64_t bytes;
	uint64_t addr_rb;
	uint64_t c_rv0, c_rv1, c_rv2, c_marker;
	uint64_t c_body_start, c_body_end;   /* mcycle either side of the hot loop */
	uint32_t t_rv0, t_rv1, t_rv2;
	uint32_t marker_result;
	int64_t  body_result;                /* the hot loop's answer, HW vs SW model */
	bool     rv0_ok, rv1_ok, rv2_ok;
	bool     ran;
	bool     sink_ok;
	bool     used_mbp;                   /* which body this hart ran */
};

static struct hart_result results[WORKERS];

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/*
 * THE MARKER -- identical in name, shape and reasoning to samples/tacit_smp's, because
 * scripts/31 reuses scripts/26's correlation logic and looks it up by symbol. Called
 * exactly once inside each hart's traced window, immediately after the barrier releases.
 *
 * noinline AND noclone: gcc will happily produce tacit_sync_marker.constprop.0 given a
 * constant argument, which still traces but under a name the runner does not know.
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

/*
 * THE MBP BODY -- hart 0 only.
 *
 * Every operand is carried through `acc`, so nothing here can be hoisted, CSE'd or
 * constant-folded out of the loop: each round's inputs depend on the previous round's
 * output. That matters more than it looks. A loop whose MBP results are dead would be
 * deleted at -O2, the image would still contain the encodings statically (the ELF gate
 * would pass), and the trace would contain none of them.
 *
 * `mb_pext_*` with CONFIG_MB_PEXT=y are the real custom-0 encodings -- see
 * fpga/pynq-z2/sw/pext.h, which is the frozen contract and is not modified by this
 * sample. With the Kconfig off the identical source compiles to the software model, which
 * is what makes the equality check below meaningful rather than circular.
 */
__attribute__((noinline, noclone))
static int64_t mbp_body_hw(int64_t seed, int rounds)
{
	int64_t acc = seed;

	for (int i = 0; i < rounds; i++) {
		int64_t a = acc ^ 0x0102030405060708LL;
		int64_t b = (acc >> 3) | 0x0101010101010101LL;
		int64_t d = mb_pext_dot8(a, b);
		int64_t m = mb_pext_max8(a, b);
		int64_t q = mb_pext_qmul(d + (m & 0xffff), 0x40000000);
		int64_t c = mb_pext_clip8((q + MB_PEXT_ROUND(8)) >> 8);

		acc = acc * 6364136223846793005LL + d + m + (q >> 16) + c + 1;
	}
	return acc;
}

/*
 * THE SCALAR BODY -- hart 1 only. Bit-identical arithmetic through pext.h's software
 * model, which PEXT_SPEC.md 3.5 makes the normative definition of the four instructions.
 * The `_sw` entry points exist unconditionally in the header, so this compiles to
 * ordinary rv64imac even in an image built with CONFIG_MB_PEXT=y -- which is the whole
 * trick that lets one image carry both bodies.
 */
__attribute__((noinline, noclone))
static int64_t mbp_body_sw(int64_t seed, int rounds)
{
	int64_t acc = seed;

	for (int i = 0; i < rounds; i++) {
		int64_t a = acc ^ 0x0102030405060708LL;
		int64_t b = (acc >> 3) | 0x0101010101010101LL;
		int64_t d = mb_pext_dot8_sw(a, b);
		int64_t m = mb_pext_max8_sw(a, b);
		int64_t q = mb_pext_qmul_sw(d + (m & 0xffff), 0x40000000);
		int64_t c = mb_pext_clip8_sw((q + MB_PEXT_ROUND(8)) >> 8);

		acc = acc * 6364136223846793005LL + d + m + (q >> 16) + c + 1;
	}
	return acc;
}

/* mtime, one counter in the CLINT shared by both harts. */
static inline uint32_t now(void)
{
	return k_cycle_get_32();
}

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
	bool big = (hartid == MB_PEXT_BIG_HART);
	uint32_t spin;

	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	r->cpu_id = arch_curr_cpu()->id;
	r->hartid = hartid;
	r->buf = buf;
	r->ran = true;
	r->used_mbp = big;

	if (big) {
		/* Belt and braces on top of the pin: if the scheduler ever put this
		 * worker elsewhere, say so rather than leaving an illegal-instruction
		 * halt with no context. */
		MB_PEXT_ASSERT_BIG_HART();
	}

	r->rv0_ok = rendezvous(&rv0_count);
	r->c_rv0 = rdcycle();
	r->t_rv0 = now();

	/* The idle differential. k_busy_wait() spins against mtime (so it is not itself
	 * affected by patches/0004); k_msleep() parks the thread and CPU 1's idle thread
	 * executes `wfi`. */
	if (idx == 0) {
		k_busy_wait(IDLE_MS * 1000);
	} else {
		k_msleep(IDLE_MS);
	}

	r->rv1_ok = rendezvous(&rv1_count);
	r->c_rv1 = rdcycle();
	r->t_rv1 = now();

	/* Warm the marker AND this hart's body into the I-cache BEFORE the encoder is
	 * enabled. The little core has a 1-way 4 KB I-cache and the two bodies are not the
	 * same size; a cold miss would land in the skew as a few hundred cycles that have
	 * nothing to do with the timebase. The warm-up also executes MBP on hart 0 with
	 * tracing OFF, which is why the traced count is exactly 4 x MB_PEXT_ROUNDS and not
	 * twice that. */
	r->marker_result = tacit_sync_marker(hartid + 1U);
	r->body_result = big ? mbp_body_hw(MB_PEXT_SEED, MB_PEXT_ROUNDS)
			     : mbp_body_sw(MB_PEXT_SEED, MB_PEXT_ROUNDS);

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
	 * R2 -- THE EVENT. Spun on the shared atomic alone: no mtime read in the loop,
	 * because an uncached MMIO load to the CLINT is ~40 cycles and both harts would be
	 * contending for the same port, which would put bus arbitration straight into the
	 * quantity being measured.
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

	/*
	 * THE HETEROGENEOUS PART OF THE WINDOW. Same source shape on both harts, same trip
	 * count, different instructions -- and from here the two traces stop looking alike.
	 */
	r->c_body_start = rdcycle();
	r->body_result = big ? mbp_body_hw(r->body_result, MB_PEXT_ROUNDS)
			     : mbp_body_sw(r->body_result, MB_PEXT_ROUNDS);
	r->c_body_end = rdcycle();

	/* mtime AFTER the body, for the same reason tacit_smp reads it after the marker:
	 * it is an uncached MMIO load both harts are making at once and must not sit
	 * between the barrier and anything being measured. */
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

	printk("\n=== tacit_pext_smp on %s ===\n", CONFIG_BOARD_TARGET);
	printk("arch_num_cpus        = %u\n", ncpus);
	printk("sys_clock_hw_cycles  = %u Hz (mtime)\n", sys_clock_hw_cycles_per_sec());
	printk("MB_PEXT_HW           = %d   (big hart = %d)\n", MB_PEXT_HW, MB_PEXT_BIG_HART);
	printk("l2: banks=%u ways=%u lgSets=%u block=%u\n", l2cfg & 0xff,
	       (l2cfg >> 8) & 0xff, (l2cfg >> 16) & 0xff, l2_block);
	printk("idle differential    = %u ms (hart 0 busy-waits, hart 1 sleeps in wfi)\n",
	       IDLE_MS);

	if (!MB_PEXT_HW) {
		printk("TACIT_PEXT_FAIL built with MB_PEXT_HW=0 -- hart 0 would execute the "
		       "software model and the trace would contain no MBP at all\n");
		return 0;
	}
	if (ncpus < WORKERS) {
		printk("TACIT_PEXT_FAIL only %u CPU(s) -- CONFIG_MP_MAX_NUM_CPUS must be >= %d\n",
		       ncpus, WORKERS);
		return 0;
	}

	/*
	 * WHAT THE DECODED TRACE MUST CONTAIN, stated before the run rather than read off
	 * afterwards. One of each op per round, one traced body per hart, and the warm-up
	 * body ran with the encoder off.
	 */
	printk("PEXT_EXPECT rounds=%d dot8=%d max8=%d qmul=%d clip8=%d total=%d "
	       "on_hart=%d none_on_hart=%d seed=0x%016llx\n",
	       MB_PEXT_ROUNDS, MB_PEXT_ROUNDS, MB_PEXT_ROUNDS, MB_PEXT_ROUNDS,
	       MB_PEXT_ROUNDS, 4 * MB_PEXT_ROUNDS, MB_PEXT_BIG_HART,
	       1 - MB_PEXT_BIG_HART, (unsigned long long)MB_PEXT_SEED);

	k_sem_init(&done_sem, 0, WORKERS);

	/* Create suspended, pin, then start: k_thread_cpu_pin() needs a thread that has
	 * not begun running. Without the pin the MBP body could land on hart 1, where it
	 * is an illegal instruction. */
	for (i = 0; i < WORKERS; i++) {
		k_tid_t tid = k_thread_create(&worker_threads[i], worker_stacks[i],
					      STACK_SIZE, worker,
					      (void *)(intptr_t)i, NULL, NULL,
					      5, 0, K_FOREVER);
		int rc = k_thread_cpu_pin(tid, i);

		if (rc != 0) {
			printk("TACIT_PEXT_FAIL k_thread_cpu_pin(worker %d -> CPU %d) = %d\n",
			       i, i, rc);
			return 0;
		}
	}
	for (i = 0; i < WORKERS; i++) {
		k_thread_start(&worker_threads[i]);
	}

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
		printk("PEXT_BODY idx=%d hart=%u mbp=%d rounds=%d cycles=%llu "
		       "result=0x%016llx\n",
		       i, r->hartid, r->used_mbp, MB_PEXT_ROUNDS,
		       (unsigned long long)(r->c_body_end - r->c_body_start),
		       (unsigned long long)r->body_result);
	}

	/*
	 * THE BIT-EXACTNESS CHECK THAT COSTS NOTHING HERE. Both harts ran the same
	 * arithmetic over the same seeds -- hart 0 on the routed MBP datapath, hart 1 on
	 * pext.h's software model, which is the normative definition. If the two 64-bit
	 * words differ, the silicon disagrees with the contract and the trace is the least
	 * interesting thing in this run.
	 */
	{
		bool same = (results[0].body_result == results[1].body_result);
		bool split = (results[0].used_mbp != results[1].used_mbp);

		printk("PEXT_MATCH seed=0x%016llx hw=0x%016llx sw=0x%016llx equal=%d split=%d\n",
		       (unsigned long long)MB_PEXT_SEED,
		       (unsigned long long)results[0].body_result,
		       (unsigned long long)results[1].body_result, same, split);
		if (!same || !split) {
			ok = false;
			printk("FAIL: hart 0 (MBP hardware) and hart 1 (pext.h software "
			       "model) disagree, or both ran the same body\n");
		}
	}

	skew0 = (int64_t)results[1].c_rv0 - (int64_t)results[0].c_rv0;
	skew1 = (int64_t)results[1].c_rv1 - (int64_t)results[0].c_rv1;
	skew2 = (int64_t)results[1].c_rv2 - (int64_t)results[0].c_rv2;

	printk("\n-- mcycle skew, hart1 - hart0, measured in software\n");
	printk("   R0 (thread start)      : %lld cycles   (mtime %d ticks)\n",
	       (long long)skew0, (int)(results[1].t_rv0 - results[0].t_rv0));
	printk("   R1 (after %u ms idle)  : %lld cycles   (mtime %d ticks)\n",
	       IDLE_MS, (long long)skew1, (int)(results[1].t_rv1 - results[0].t_rv1));
	printk("   R2 (the barrier)       : %lld cycles\n", (long long)skew2);
	printk("   idle cost (R1 - R0)    : %lld cycles\n", (long long)(skew1 - skew0));
	printk("   body cost              : hart0 %llu cycles (MBP), hart1 %llu cycles (scalar)\n",
	       (unsigned long long)(results[0].c_body_end - results[0].c_body_start),
	       (unsigned long long)(results[1].c_body_end - results[1].c_body_start));

	printk("\nTACIT_SKEW sw_r0=%lld sw_r1=%lld sw_r2=%lld idle_cost=%lld\n",
	       (long long)skew0, (long long)skew1, (long long)skew2,
	       (long long)(skew1 - skew0));
	printk("TACIT_SMP_DONE harts=%d ok=%d\n", finished, ok);
	return 0;
}
