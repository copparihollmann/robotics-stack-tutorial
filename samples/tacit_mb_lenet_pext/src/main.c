/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ONE LeNet int8 inference, through the curated MBP kernels, with a TACIT encoder
 * bracketed exactly around it.
 *
 * WHAT THIS IS FOR.  PEXT_VALIDATION.md section 6 records the gap this closes: the MBP
 * instructions had been traced and checked on hardware, but only over a 96-instruction
 * synthetic loop (samples/tacit_pext_smp), and only on a Spike trace of a self-test
 * (samples/pext_selftest).  Neither is a curated kernel.
 * fpga/pynq-z2/modelblaster/kernels/pext/ is where MBP actually sits next to branches, at
 * basic-block boundaries, and interleaved with byte loads at high density -- 53,122 MBP
 * executions in 419,490 kernel instructions -- and that is what a decoder gets tested by.
 *
 * WHAT IS BRACKETED, AND WHY IT IS THE WHOLE INFERENCE.  samples/tacit_dma brackets its
 * workload rather than tracing from reset because a trace has to fit in a buffer.  It
 * does here with room to spare: samples/tacit_pext_smp encoded 19,017 instructions into
 * 6,202 bytes (2.6 bits per instruction), so 419,490 kernel instructions is ~140 KB
 * against the 128 MB between TACIT_BUF_ADDR and the top of Rocket's DRAM window.  Two
 * orders of magnitude of headroom is not a reason to trace half an inference, and half an
 * inference would answer a smaller question: the point is the WHOLE graph -- two
 * convolutions, two pools and three fully-connected layers, in the order the network runs
 * them.  The guest reports the byte count and the buffer size so the runner can check the
 * buffer was not wrapped rather than assume it.
 *
 * WHAT IS *NOT* IN THE WINDOW, deliberately:
 *
 *   - The first two inferences.  Both run before the encoder is enabled: the first warms
 *     the caches so the traced one is not a trace of the cache hierarchy, and the second
 *     is the untraced reference the traced one is priced against.  See the comment on
 *     them in big_worker() -- the encoder is free, the SINK is not.
 *
 *   - Interrupts.  irq_lock() spans the traced inference, the same way
 *     samples/modelblaster_pext brackets its timed ones.  The decoder handles trap packets
 *     perfectly well (Lab A traces a whole boot through them), but the point here is the
 *     KERNELS: with the tick masked, the decoded MBP counts are exactly one inference's
 *     worth and can be checked against a closed-form derivation from the LeNet shapes.
 *
 *   - The output check and every printk.  They run after the encoder stops.
 *
 * ONE SOURCE, TWO TARGETS.  CONFIG_TACIT_MB_SINK_DMA=y streams into DRAM through
 * TraceSinkDMA on the FPGA; =n points the same encoder at spike's file sink, which also
 * writes tacit.debug -- spike's own per-instruction record of exactly this window.  That
 * is the ground truth the decoded PC sequence is diffed against.  See the Kconfig.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>
#include <zephyr/sys/reboot.h>

#include <tacit/tacit.h>

#include "pext.h"
#include "model.h"
#include "test_io.h"

/* k_thread_cpu_pin() exists only with CONFIG_SCHED_CPU_MASK, which needs CONFIG_SMP.
 * On the FPGA both are on and pinning to hart 0 is mandatory -- MBP is an illegal
 * instruction on hart 1.  On spike neither is on and none is needed: patches/0006 gives
 * every hart the four instructions. */
#if defined(CONFIG_SMP) && defined(CONFIG_SCHED_CPU_MASK)
#define TACIT_MB_PIN 1
#else
#define TACIT_MB_PIN 0
#endif

#define BIG_CPU        0
#define WORKER_STACK   16384
#define JOIN_TIMEOUT_S 200

/*
 * Where the DMA sink parks the trace, in ROCKET's address space.  The FPGA top folds
 * Rocket's DRAM window with {4'd1, addr[27:0]}, so 0x8800_0000 is PS physical
 * 0x1800_0000 -- 128 MB into a 256 MB window, far above Zephyr's image, heap and stacks,
 * and above the weights (44 KB of .rodata) and the intermediate tensors.
 */
#ifndef TACIT_BUF_ADDR
#define TACIT_BUF_ADDR 0x88000000UL
#endif
/* Only used to bound the L2 flush and to answer "did it wrap?" with a number. */
#ifndef TACIT_BUF_SIZE
#define TACIT_BUF_SIZE (64UL * 1024 * 1024)
#endif

/* SiFive InclusiveCache control node: cache-controller@2010000, reg-names "control". */
#define L2_CTRL_BASE 0x2010000UL
#define L2_CONFIG    (L2_CTRL_BASE + 0x000) /* banks | ways<<8 | lgSets<<16 | lgBlk<<24 */
#define L2_FLUSH64   (L2_CTRL_BASE + 0x200) /* write a phys addr -> flush that block */

K_THREAD_STACK_DEFINE(big_stack, WORKER_STACK);
static struct k_thread big_thread;
static struct k_sem done_sem;

static model_output_t model_output[MODEL_OUTPUT_SIZE];

static struct {
	bool          ran;
	uint32_t      cpu_id;
	unsigned long hartid;
	unsigned long cold_cycles;      /* the first inference, untraced */
	unsigned long warm_cycles;      /* the second, warm and STILL untraced */
	unsigned long traced_cycles;    /* rdcycle around the third, traced */
	unsigned long wall_ticks;
	unsigned long flush_cycles;
	uint64_t      buf;
	uint64_t      bytes;
	uint64_t      addr_rb;
	bool          sink_ok;
	int           max_abs_err;
	uint32_t      marker_result;    /* keeps the two marker calls alive; see below */
	int8_t        out[MODEL_TEST_OUTPUT_LEN];
	int           n_ops;
	int           op_id[MODEL_OP_COUNT];
	const char   *op_name[MODEL_OP_COUNT];
	const char   *op_kind[MODEL_OP_COUNT];
	const char   *op_shape[MODEL_OP_COUNT];
	unsigned long op_cycles[MODEL_OP_COUNT];
} big;

static inline unsigned long rdcycle(void)
{
	unsigned long c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/*
 * THE WINDOW MARKER.  Called once immediately after the encoder is enabled and once
 * immediately before it is disabled, so the decoded trace opens and closes on a name the
 * runner knows.  Two slices, not one: a trace that lost its head (a sink pointed at a
 * running encoder, a dropped sync packet) or its tail (a stop with no retired
 * instructions behind it) shows up as a missing marker rather than as a slightly short
 * instruction count that nobody notices.
 *
 * noinline AND noclone: gcc will produce tacit_mb_marker.constprop.0 given a constant
 * argument, which still traces but under a name the runner does not look for.  The
 * returned value is carried into the next call so neither can be folded away.
 */
__attribute__((noinline, noclone))
uint32_t tacit_mb_marker(uint32_t seed)
{
	uint32_t x = seed;
	int i;

	for (i = 0; i < 8; i++) {
		x = x * 1664525U + 1013904223U;
		x ^= x >> 7;
	}
	return x;
}

#ifdef CONFIG_TACIT_MB_SINK_DMA
/*
 * Flush a physical range out of the L2.
 *
 * TraceSinkDMA's TileLink client hangs off the system bus, so its Puts go through the
 * inclusive L2 on the way to DRAM -- and the PS reads DRAM.  Flush64 is a write-only
 * register whose TileLink write does not complete until the scheduler has finished with
 * that block, so the store is the handshake and there is nothing to poll.  Blocks that
 * are not resident answer immediately.  TACIT_ON_FPGA.md section 3 has the measurement of
 * what happens without this: 825 of 2,116 blocks never reached DRAM.
 */
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
#endif /* CONFIG_TACIT_MB_SINK_DMA */

static void big_worker(void *p1, void *p2, void *p3)
{
	unsigned long hartid = (unsigned long)csr_read(mhartid);
	LTraceEncoderType *enc = l_trace_encoder_get((uint32_t)hartid);
	unsigned long a, b;
	int i;
#ifdef CONFIG_TACIT_MB_SINK_DMA
	LTraceSinkDmaType *sink = l_trace_sink_dma_get((uint32_t)hartid);
	uint32_t l2cfg = *(volatile uint32_t *)L2_CONFIG;
	uint32_t l2_block = 1u << ((l2cfg >> 24) & 0xff);
#endif

	ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

	big.cpu_id = arch_curr_cpu()->id;
	big.hartid = hartid;
	big.buf = (uint64_t)TACIT_BUF_ADDR;
	big.ran = true;

	/* Belt and braces on top of the pin: name the cause if the scheduler ever put
	 * this thread on a hart without the datapath, instead of leaving an
	 * illegal-instruction halt inside a traced window with no context. */
	MB_PEXT_ASSERT_BIG_HART();

	/*
	 * --- TWO UNTRACED INFERENCES FIRST, AND THE SECOND ONE IS THE MEASUREMENT ---
	 *
	 * The first warms the I-cache, the weights and the branch predictor, so the traced
	 * inference is not a trace of the cache hierarchy.
	 *
	 * The second exists so that the cost of TRACING can be stated as a number measured
	 * in this image rather than inferred by comparing against Lab B10's separately
	 * built one.  The encoder itself is a tap on the retirement stream and cannot cost
	 * a cycle -- but TraceSinkDMA is a master on the SYSTEM BUS, so every beat it Puts
	 * goes through the same inclusive 64 KB L2 the core's data does, and the core's
	 * working set here (fc1's weight tensor alone is 30 KB) has to share it with ~50 KB
	 * of trace streaming past.  warm_cycles and traced_cycles are the same inference in
	 * the same binary with and without that traffic, which is the only honest way to
	 * price it.
	 */
	{
		unsigned int key = irq_lock();

		a = rdcycle();
		model_run_test(model_output, NULL);
		b = rdcycle();
		irq_unlock(key);
		big.cold_cycles = b - a;
	}
	{
		unsigned int key = irq_lock();

		a = rdcycle();
		model_run_test(model_output, NULL);
		b = rdcycle();
		irq_unlock(key);
		big.warm_cycles = b - a;
	}

	/* --- program the encoder.  Order is fixed; TACIT_ON_FPGA.md section 2. --- */
	l_trace_encoder_stop(enc);                                    /* 1 */
#ifdef CONFIG_TACIT_MB_SINK_DMA
	l_trace_sink_dma_configure_addr(sink, TACIT_BUF_ADDR, 0);     /* 2 */
	l_trace_encoder_configure_target(enc, TARGET_DMA);            /* 3 */
#else
	l_trace_encoder_configure_target(enc, TARGET_PRINT);          /* 3, spike */
#endif
	l_trace_encoder_configure_branch_mode(enc, BRANCH_MODE_TARGET);
#ifdef CONFIG_TACIT_MB_SINK_DMA
	/* traceSinkDMARegWrite only commits while the write FSM is idle, and acks either
	 * way -- so the register is read back rather than trusted. */
	big.addr_rb = sink->TR_SK_DMA_ADDR;
	big.sink_ok = (big.addr_rb == (uint64_t)TACIT_BUF_ADDR);
	if (!big.sink_ok) {
		goto out;
	}
#else
	big.addr_rb = 0;
	big.sink_ok = true;
#endif

	/* --- THE TRACED WINDOW -------------------------------------------------- */
	{
		unsigned int key = irq_lock();

		a = rdcycle();
		l_trace_encoder_start(enc);                           /* 4 */
		/* THE RESULT IS STORED, AND THAT IS WHAT KEEPS THE CALLS.  noinline and
		 * noclone stop gcc inlining the marker; they do not stop it DELETING a
		 * call whose result is unused, because the body has no side effects and
		 * gcc infers `const` for it.  The first version of this sample dropped
		 * both calls and --gc-sections then dropped the symbol, which stage 4
		 * caught.  Threading the value through `big` is the fix: the store is
		 * observable, so neither call can go. */
		big.marker_result = tacit_mb_marker((uint32_t)hartid + 1U);
		model_run_test(model_output, NULL);                   /* 5 */
		big.marker_result = tacit_mb_marker(big.marker_result);
		l_trace_encoder_stop(enc);                            /* 6 */
		b = rdcycle();
		irq_unlock(key);
		big.traced_cycles = b - a;
	}
	big.wall_ticks = model_wall_cycles();

	/* On `enable` falling the encoder goes sData -> sSync and emits a TRAILING sync
	 * packet, and sSync only advances on retired instructions.  Halt here and that
	 * packet never leaves; the decoder's clean "detected FSync packet, trace ending!"
	 * is the evidence it did. */
	for (volatile int n = 0; n < 2000; n++) {
		__asm__ volatile("nop");
	}

#ifdef CONFIG_TACIT_MB_SINK_DMA
	/* 7. The sink writes whole 8-byte beats; flush pushes the partial tail out and
	 * freezes addr_counter. `done` is sticky, so polling it is safe. */
	sink->TR_SK_DMA_FLUSH = 1;
	while (sink->TR_SK_DMA_FLUSH_DONE == 0) {
	}
	big.bytes = sink->TR_SK_DMA_COUNT;

	/* 8. The sink's writes are in the inclusive L2 and the PS reads DRAM. */
	if (big.bytes > 0 && big.bytes <= TACIT_BUF_SIZE) {
		a = rdcycle();
		l2_flush_range((uintptr_t)TACIT_BUF_ADDR, big.bytes, l2_block);
		big.flush_cycles = rdcycle() - a;
	}
#else
	/* spike's sink writes tacit.out itself; there is no counter to read. */
	big.bytes = 0;
#endif

	/* --- the answer, outside the window ------------------------------------- */
	{
		int n = 0;
		const model_op_record_t *rec = model_profile_records(&n);

		if (n > MODEL_OP_COUNT) {
			n = MODEL_OP_COUNT;
		}
		big.n_ops = n;
		for (i = 0; i < n; i++) {
			big.op_id[i]    = rec[i].dispatch_id;
			big.op_name[i]  = rec[i].name;
			big.op_kind[i]  = rec[i].op;
			big.op_shape[i] = rec[i].shape;
			big.op_cycles[i] = rec[i].cycles;
		}
	}

	big.max_abs_err = 0;
	for (i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
		int d = (int)model_output[i] - (int)model_test_golden[i];

		if (d < 0) {
			d = -d;
		}
		if (d > big.max_abs_err) {
			big.max_abs_err = d;
		}
		big.out[i] = (int8_t)model_output[i];
	}

out:
	k_sem_give(&done_sem);
}

int main(void)
{
	bool ok = true;
	int i;
#ifdef CONFIG_TACIT_MB_SINK_DMA
	uint32_t l2cfg = *(volatile uint32_t *)L2_CONFIG;
#endif

	k_sem_init(&done_sem, 0, 1);

	printk("\n=== tacit_mb_lenet_pext on %s ===\n", CONFIG_BOARD_TARGET);
	printk("TACIT_MB_BUILD model=%s quant=%s ops=%d hw=%d sink_dma=%d pinned=%d "
	       "cpus=%d main_cpu=%u main_hartid=%lu\n",
	       MODEL_NAME, MODEL_QUANT, MODEL_OP_COUNT, MB_PEXT_HW,
	       IS_ENABLED(CONFIG_TACIT_MB_SINK_DMA), TACIT_MB_PIN,
	       CONFIG_MP_MAX_NUM_CPUS, arch_curr_cpu()->id,
	       (unsigned long)csr_read(mhartid));
#ifdef CONFIG_TACIT_MB_SINK_DMA
	printk("l2: banks=%u ways=%u lgSets=%u block=%u\n", l2cfg & 0xff,
	       (l2cfg >> 8) & 0xff, (l2cfg >> 16) & 0xff,
	       1u << ((l2cfg >> 24) & 0xff));
#endif

	if (!MB_PEXT_HW) {
		printk("TACIT_MB_FAIL built with MB_PEXT_HW=0 -- the traced window would "
		       "contain pext.h's software model and not one custom-0 encoding\n");
		return 0;
	}

	/*
	 * WHAT THE DECODED TRACE MUST CONTAIN, stated before the run.  The counts
	 * themselves are NOT declared here: they are derived on the host from the LeNet
	 * shapes in graph.json and the weight alignments in this ELF (scripts/32 stage 9),
	 * which is a stronger statement than a constant the guest also computes.  What the
	 * guest pins down is the only thing the host cannot see: how many inferences ran
	 * inside the window, and how many times the marker was called.
	 */
	printk("TACIT_MB_EXPECT traced_inferences=1 marker_calls=2 buf_size=%u\n",
	       (unsigned int)TACIT_BUF_SIZE);

#if TACIT_MB_PIN
	{
		k_tid_t tid = k_thread_create(&big_thread, big_stack, WORKER_STACK,
					      big_worker, NULL, NULL, NULL,
					      5, 0, K_FOREVER);
		int rc = k_thread_cpu_pin(tid, BIG_CPU);

		if (rc != 0) {
			printk("TACIT_MB_FAIL k_thread_cpu_pin(-> CPU %d) = %d\n",
			       BIG_CPU, rc);
			return 0;
		}
		k_thread_start(tid);
		/* NOT K_FOREVER: a worker pinned to a CPU that never came online would
		 * never run, and main() would stop with no explanation. */
		if (k_sem_take(&done_sem, K_SECONDS(JOIN_TIMEOUT_S)) != 0) {
			printk("TACIT_MB_FAIL the traced worker did not finish within "
			       "%d s\n", JOIN_TIMEOUT_S);
			return 0;
		}
	}
#else
	big_worker(NULL, NULL, NULL);
	(void)k_sem_take(&done_sem, K_NO_WAIT);
#endif

	if (!big.ran) {
		printk("TACIT_MB_FAIL the traced worker never ran\n");
		return 0;
	}
	if (!big.sink_ok) {
		printk("TACIT_MB_FAIL sink address did not latch: wrote 0x%08x, read "
		       "back 0x%08x%08x\n", (unsigned int)TACIT_BUF_ADDR,
		       (unsigned int)(big.addr_rb >> 32), (unsigned int)big.addr_rb);
		return 0;
	}

	printk("TACIT_MB_RUN cpu=%u hartid=%lu cold=%lu warm=%lu traced=%lu wall=%lu "
	       "max_abs_err=%d marker=0x%08x\n",
	       big.cpu_id, big.hartid, big.cold_cycles, big.warm_cycles,
	       big.traced_cycles, big.wall_ticks, big.max_abs_err, big.marker_result);
	for (i = 0; i < big.n_ops; i++) {
		printk("TACIT_MB_OP id=%d name=%s op=%s shape=%s cycles=%lu\n",
		       big.op_id[i], big.op_name[i], big.op_kind[i],
		       big.op_shape[i], big.op_cycles[i]);
	}
	printk("TACIT_MB_OUT");
	for (i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
		printk(" %d", (int)big.out[i]);
	}
	printk("\n");

	if (big.max_abs_err != 0) {
		printk("TACIT_MB_FAIL max_abs_err=%d against the baked int8 golden -- the "
		       "traced inference computed the wrong answer, so nothing measured "
		       "about it means anything\n", big.max_abs_err);
		ok = false;
	}

	printk("TACIT_MB_TRACE addr=0x%08x bytes=%u buf_size=%u wrapped=%d "
	       "flush_cycles=%lu\n",
	       (unsigned int)big.buf, (unsigned int)big.bytes,
	       (unsigned int)TACIT_BUF_SIZE,
	       (int)(big.bytes > TACIT_BUF_SIZE), big.flush_cycles);
#ifdef CONFIG_TACIT_MB_SINK_DMA
	if (big.bytes == 0) {
		printk("TACIT_MB_FAIL the sink wrote 0 bytes -- encoder target or sink "
		       "address wrong\n");
		ok = false;
	}
	if (big.bytes > TACIT_BUF_SIZE) {
		printk("TACIT_MB_FAIL the trace is %u bytes against a %u byte buffer -- "
		       "it ran off the end and the decode would be of two different "
		       "windows spliced together\n",
		       (unsigned int)big.bytes, (unsigned int)TACIT_BUF_SIZE);
		ok = false;
	}
#endif

	printk("TACIT_MB_DONE ok=%d\n", ok ? 1 : 0);

#ifndef CONFIG_TACIT_MB_SINK_DMA
	/*
	 * SPIKE ONLY, AND IT IS NOT COSMETIC.  trace_encoder_l holds tacit.out,
	 * tacit.log and tacit.debug open with ordinary stdio buffering and closes them
	 * when the simulator exits.  Returning from main() on a MULTITHREADING build
	 * leaves the idle thread spinning in wfi forever, so spike never exits, the last
	 * few KB never reach the files, and the decode stops short of the trailing sync
	 * packet.  sys_reboot() drives HTIF's exit, which is what samples/pext_selftest
	 * does for the same reason.
	 *
	 * The FPGA build must NOT do this: the PS reads the trace out of DRAM after the
	 * guest has finished, and a reboot would re-run the whole image and stream a
	 * second trace over the first.
	 */
	k_msleep(10);
	sys_reboot(SYS_REBOOT_COLD);
#endif
	return 0;
}
