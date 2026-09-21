/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Inference latency of a ModelBlaster-generated, scalar-integer network on each
 * hart of the dual-core big.LITTLE Rocket -- ONE HART AT A TIME.
 *
 * WHY ONE AT A TIME. The two harts share an inclusive L2 and a single AXI path to
 * DDR. Running both inferences concurrently would make each one's latency a
 * function of the other's memory traffic, which is a different (and much harder
 * to interpret) measurement than "how long does this network take on this core".
 * So: a worker is created, pinned to CPU h, started, and joined before the next
 * one is created. While it runs, main() is blocked on a semaphore and the other
 * hart has nothing runnable -- it is in Zephyr's idle thread, i.e. wfi.
 *
 * WHAT THE CLOCK IS. Two counters are read, both already cross-checked against
 * each other on this board (samples/timer, FPGA_END_TO_END.md 5.2):
 *
 *   rdcycle  per-hart mcycle CSR, 40 MHz -> 25 ns/tick. This is the measurement.
 *   mtime    one CLINT counter shared by both harts, 40 kHz -> 25 us/tick. Read
 *            alongside as a coarse independent witness; it cannot resolve a
 *            single layer but it catches a wrong core-clock assumption.
 *
 * Rocket stops mcycle during wfi, so nothing here sleeps inside a timed region.
 *
 * WHY IRQs ARE MASKED PER ITERATION. CONFIG_SYS_CLOCK_TICKS_PER_SEC=1000, so an
 * unmasked run takes one timer interrupt per millisecond and folds the ISR into
 * the number. Masking is safe because exactly one thread is runnable during a
 * timed region. The mask is inside the loop, not around it, so the console and
 * the tick recover between iterations.
 *
 * WHAT IS PRINTED. Machine-readable MB_* lines for the host-side runner, plus a
 * human summary. Everything is integer: no float appears anywhere in this image
 * (see prj.conf).
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>

#include "model.h"
#include "test_io.h"

/* Timed iterations per hart. Odd, so the median is a measured sample rather than
 * an average of two. One extra warm-up run happens first and is reported
 * separately -- on the LITTLE core, with its 4 KB 1-way L1s, the cold run is a
 * real number rather than noise to be hidden. */
#ifndef MB_ITERS
#define MB_ITERS 11
#endif

#define HARTS            2
#define WORKER_STACK     8192
#define JOIN_TIMEOUT_S   200

/* Core clock, derived rather than hard-coded: mtime ticks at the core clock
 * divided by CONFIG_RTC_CLOCK_DIVIDER_VALUE, so the product is the core clock.
 * 40000 * 1000 = 40 MHz here. */
#define CORE_HZ     ((uint64_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * \
		     CONFIG_RTC_CLOCK_DIVIDER_VALUE)
#define CYC_PER_MS  ((uint32_t)(CORE_HZ / 1000U))

K_THREAD_STACK_ARRAY_DEFINE(worker_stacks, HARTS, WORKER_STACK);
static struct k_thread worker_threads[HARTS];
static struct k_sem done_sem;

/* The model writes here. One buffer, reused: the two harts never run together,
 * and reusing it is also what makes the cross-hart output comparison below a
 * comparison of two computations rather than of two buffers. */
static model_output_t model_output[MODEL_OUTPUT_SIZE];

struct hart_result {
	bool     ran;
	uint32_t cpu_id;
	uint32_t hartid;
	uint32_t rdcycle_probe;        /* nonzero => the cycle CSR reads on this hart */
	unsigned long warm_cycles;     /* the discarded cold-cache run */
	unsigned long cyc[MB_ITERS];   /* rdcycle delta per timed iteration */
	unsigned long mtime_ticks;     /* mtime delta of the LAST timed iteration */
	unsigned long median, min, max;
	unsigned long long sum;
	int      max_abs_err;          /* vs the baked PyTorch/int8 golden */
	int8_t   out[MODEL_TEST_OUTPUT_LEN];
	/* Per-kernel rdcycle deltas from the last timed iteration. */
	int           n_ops;
	unsigned long op_cycles[MODEL_OP_COUNT];
	const char   *op_name[MODEL_OP_COUNT];
	const char   *op_kind[MODEL_OP_COUNT];
	const char   *op_shape[MODEL_OP_COUNT];
	int           op_id[MODEL_OP_COUNT];
};

static struct hart_result results[HARTS];

/* Per-hart cycle counter. Reading `cycle` (0xC00) from M-mode is unconditional,
 * so this needs no mcounteren setup; the LITTLE core implements it too, which
 * the probe below records rather than assumes. */
static inline unsigned long rdcycle(void)
{
	unsigned long c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

static void sort_ul(unsigned long *a, int n)
{
	for (int i = 1; i < n; i++) {
		unsigned long v = a[i];
		int j = i - 1;

		while (j >= 0 && a[j] > v) {
			a[j + 1] = a[j];
			j--;
		}
		a[j + 1] = v;
	}
}

static void worker(void *p1, void *p2, void *p3)
{
	int idx = (int)(intptr_t)p1;
	struct hart_result *r = &results[idx];
	unsigned long a, b;

	ARG_UNUSED(p2);
	ARG_UNUSED(p3);

	r->cpu_id = arch_curr_cpu()->id;
	r->hartid = csr_read(mhartid);
	r->ran = true;

	/* Probe the cycle CSR before leaning on it. If `rdcycle` were not
	 * implemented on this hart the instruction would trap here, in one line
	 * of code, rather than somewhere inside the model. */
	a = rdcycle();
	for (volatile int k = 0; k < 64; k++) {
	}
	b = rdcycle();
	r->rdcycle_probe = (uint32_t)(b - a);

	/* Warm-up: not counted. Fills the L1s and the branch predictor with the
	 * model's own working set so the timed runs measure steady state. */
	{
		unsigned int key = irq_lock();

		a = rdcycle();
		model_run_test(model_output, NULL);
		b = rdcycle();
		irq_unlock(key);
		r->warm_cycles = b - a;
	}

	for (int i = 0; i < MB_ITERS; i++) {
		unsigned int key = irq_lock();

		a = rdcycle();
		model_run_test(model_output, NULL);
		b = rdcycle();
		irq_unlock(key);
		r->cyc[i] = b - a;
		r->mtime_ticks = model_wall_cycles();
	}

	/* Per-kernel breakdown, from the last timed iteration. The records array
	 * lives in the generated model.c and is overwritten by every run, so it
	 * is copied out here before the other hart's worker touches it. */
	{
		int n = 0;
		const model_op_record_t *rec = model_profile_records(&n);

		if (n > MODEL_OP_COUNT) {
			n = MODEL_OP_COUNT;
		}
		r->n_ops = n;
		for (int i = 0; i < n; i++) {
			r->op_id[i]    = rec[i].dispatch_id;
			r->op_name[i]  = rec[i].name;
			r->op_kind[i]  = rec[i].op;
			r->op_shape[i] = rec[i].shape;
			r->op_cycles[i] = rec[i].cycles;
		}
	}

	/* In-binary golden compare, integer-exact. The golden is the int8 output
	 * of the quantized reference pipeline, baked into rodata by test_io.S. */
	r->max_abs_err = 0;
	for (int i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
		int d = (int)model_output[i] - (int)model_test_golden[i];

		if (d < 0) {
			d = -d;
		}
		if (d > r->max_abs_err) {
			r->max_abs_err = d;
		}
		r->out[i] = (int8_t)model_output[i];
	}

	{
		unsigned long tmp[MB_ITERS];

		for (int i = 0; i < MB_ITERS; i++) {
			tmp[i] = r->cyc[i];
			r->sum += r->cyc[i];
		}
		sort_ul(tmp, MB_ITERS);
		r->min = tmp[0];
		r->max = tmp[MB_ITERS - 1];
		r->median = tmp[MB_ITERS / 2];
	}

	k_sem_give(&done_sem);
}

/* cycles -> "<ms>.<us within ms>", integer only. */
static void print_ms(unsigned long c)
{
	printk("%lu.%03lu ms", c / CYC_PER_MS, (c % CYC_PER_MS) / (CYC_PER_MS / 1000U));
}

static void run_on(int cpu)
{
	k_tid_t tid = k_thread_create(&worker_threads[cpu], worker_stacks[cpu],
				      WORKER_STACK, worker,
				      (void *)(intptr_t)cpu, NULL, NULL,
				      5, 0, K_FOREVER);
	int rc = k_thread_cpu_pin(tid, cpu);

	if (rc != 0) {
		printk("FAIL: k_thread_cpu_pin(worker -> CPU %d) = %d\n", cpu, rc);
		return;
	}
	k_thread_start(tid);
	/* NOT K_FOREVER: a worker pinned to a CPU that never came online would
	 * never run, and main() would stop mid-run with no explanation. */
	if (k_sem_take(&done_sem, K_SECONDS(JOIN_TIMEOUT_S)) != 0) {
		printk("FAIL: worker on CPU %d did not finish within %d s\n",
		       cpu, JOIN_TIMEOUT_S);
	}
}

int main(void)
{
	unsigned int ncpus = arch_num_cpus();
	bool outputs_match = true;
	bool pass;
	unsigned long ratio_x100 = 0;

	/* Keep main() on the boot hart so "which hart is idle" is not a scheduler
	 * decision. It is blocked on the join semaphore for every timed region
	 * anyway, so it costs the measurement nothing. */
	(void)k_thread_cpu_pin(k_current_get(), 0);

	printk("\n=== modelblaster_hart_latency on %s ===\n", CONFIG_BOARD_TARGET);
	printk("MB_MODEL name=%s quant=%s in=%d out=%d ops=%d\n",
	       MODEL_NAME, MODEL_QUANT, MODEL_INPUT_SIZE, MODEL_OUTPUT_SIZE,
	       MODEL_OP_COUNT);
	printk("MB_CLOCK mtime_hz=%u core_hz=%llu iters=%d\n",
	       sys_clock_hw_cycles_per_sec(), (unsigned long long)CORE_HZ, MB_ITERS);
	printk("MB_CPUS arch_num_cpus=%u main_cpu=%u main_mhartid=%lu\n",
	       ncpus, arch_curr_cpu()->id, (unsigned long)csr_read(mhartid));

	if (ncpus < HARTS) {
		printk("FAIL: only %u CPU(s) -- CONFIG_MP_MAX_NUM_CPUS must be >= %d\n",
		       ncpus, HARTS);
		return 0;
	}

	k_sem_init(&done_sem, 0, 1);

	/* Sequential by construction: nothing is created for CPU 1 until CPU 0's
	 * worker has given the semaphore back. */
	for (int cpu = 0; cpu < HARTS; cpu++) {
		printk("\n-- running %d+1 inferences on CPU %d (the other hart is idle) --\n",
		       MB_ITERS, cpu);
		run_on(cpu);
	}

	printk("\n-- per-hart inference latency (rdcycle, %d timed iterations) --\n",
	       MB_ITERS);
	for (int h = 0; h < HARTS; h++) {
		struct hart_result *r = &results[h];

		if (!r->ran) {
			printk("MB_HART cpu=%d NEVER_RAN\n", h);
			continue;
		}
		printk("MB_HART cpu=%u mhartid=%u rdcycle_probe=%u "
		       "median=%lu min=%lu max=%lu mean=%lu warm=%lu mtime_ticks=%lu "
		       "max_abs_err=%d\n",
		       r->cpu_id, r->hartid, r->rdcycle_probe,
		       r->median, r->min, r->max,
		       (unsigned long)(r->sum / MB_ITERS), r->warm_cycles,
		       r->mtime_ticks, r->max_abs_err);
		printk("   hart %u : median ", r->hartid);
		print_ms(r->median);
		{
			/* Hundredths of a percent, integer: on this core the spread is
			 * a few parts in 10,000 and plain % rounds it to 0, which reads
			 * as "not measured" rather than "flat". */
			unsigned long pm = r->median
				? (unsigned long)(((uint64_t)(r->max - r->min) * 10000U) / r->median)
				: 0U;

			printk("   spread (max-min) %lu cycles = %lu.%02lu%% of median\n",
			       r->max - r->min, pm / 100U, pm % 100U);
		}
		printk("   hart %u : cold (warm-up) run ", r->hartid);
		print_ms(r->warm_cycles);
		printk("\n");
		printk("   hart %u : mtime cross-check %lu ticks = %lu.%03lu ms\n",
		       r->hartid, r->mtime_ticks,
		       r->mtime_ticks / (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC / 1000U),
		       ((r->mtime_ticks % (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC / 1000U))
			* 1000U) / (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC / 1000U));
		for (int i = 0; i < MB_ITERS; i++) {
			printk("MB_ITER cpu=%u i=%d cycles=%lu\n", r->cpu_id, i, r->cyc[i]);
		}
	}

	printk("\n-- per-kernel cycles (rdcycle, last timed iteration) --\n");
	for (int h = 0; h < HARTS; h++) {
		struct hart_result *r = &results[h];

		for (int i = 0; i < r->n_ops; i++) {
			printk("MB_OP cpu=%u id=%d name=%s op=%s shape=%s cycles=%lu\n",
			       r->cpu_id, r->op_id[i], r->op_name[i], r->op_kind[i],
			       r->op_shape[i], r->op_cycles[i]);
		}
	}
	if (results[0].ran && results[1].ran) {
		printk("\n-- per-kernel big/LITTLE ratio (x100) --\n");
		for (int i = 0; i < results[0].n_ops && i < results[1].n_ops; i++) {
			unsigned long b = results[0].op_cycles[i];
			unsigned long l = results[1].op_cycles[i];

			printk("MB_OPRATIO id=%d name=%s op=%s big=%lu little=%lu "
			       "ratio_x100=%lu\n",
			       results[0].op_id[i], results[0].op_name[i],
			       results[0].op_kind[i], b, l, b ? (l * 100U) / b : 0U);
		}
	}

	/* The two harts ran the same integer code on the same input. If the
	 * outputs differ at all, one of them is wrong and no latency number from
	 * this run means anything. */
	for (int i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
		if (results[0].out[i] != results[1].out[i]) {
			outputs_match = false;
		}
	}

	if (results[0].ran && results[1].ran && results[0].median) {
		ratio_x100 = (results[1].median * 100U) / results[0].median;
	}
	printk("\nMB_RATIO big_median=%lu little_median=%lu little_over_big_x100=%lu\n",
	       results[0].median, results[1].median, ratio_x100);
	printk("MB_VERIFY hart0_max_abs_err=%d hart1_max_abs_err=%d outputs_identical=%d\n",
	       results[0].max_abs_err, results[1].max_abs_err, outputs_match ? 1 : 0);

	pass = results[0].ran && results[1].ran &&
	       results[0].hartid == 0 && results[1].hartid == 1 &&
	       results[0].max_abs_err == 0 && results[1].max_abs_err == 0 &&
	       outputs_match && results[0].median > 0 && results[1].median > 0;

	printk("CHECKS  both_harts=%d distinct_harts=%d golden=%d identical=%d\n",
	       (results[0].ran && results[1].ran) ? 1 : 0,
	       (results[0].hartid != results[1].hartid) ? 1 : 0,
	       (results[0].max_abs_err == 0 && results[1].max_abs_err == 0) ? 1 : 0,
	       outputs_match ? 1 : 0);
	printk("RESULT: %s\n",
	       pass ? "PASS -- the network ran on hart 0 and on hart 1, "
		      "bit-identical, one at a time"
		    : "FAIL -- see the checks above");
	return 0;
}
