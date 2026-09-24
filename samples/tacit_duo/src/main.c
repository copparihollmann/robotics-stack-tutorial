/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * TWO REAL SENSOR WORKLOADS, ONE ON EACH HART, ON ONE TIMELINE -- and what they cost
 * each other through the shared L2.  Lab B151.
 *
 *   hart 0 (BIG, has the MBP datapath)
 *       camera -> sign_pre_rgb -> SignDetLite (real custom-0) -> OLED
 *       = samples/signdet_live's `demo`, linked here unmodified
 *
 *   hart 1 (LITTLE, no MBP datapath)
 *       PDM mic -> MFCC -> kws cnn_tiny through pext.h's SOFTWARE MODEL
 *       = samples/kws_live's `kws_body`, linked here unmodified, built MB_PEXT_HW=0
 *
 * NEITHER SAMPLE IS COPIED.  Both source files are compiled straight out of their own
 * directories with SD_NO_MAIN / KWS_NO_MAIN defined, which is a default-off hook that
 * suppresses only their main(). Every image scripts/38, scripts/83 and scripts/87 build
 * is unchanged, and there is no second copy of 35 KB of camera code to drift.
 *
 * WHY HART 1 MUST BE THE SOFTWARE MODEL, AND WHY THAT IS THE POINT.  RocketALU_1.sv
 * carries none of fn codes 5'h14..5'h17: a custom-0 word on tile 1 is an illegal
 * instruction, and samples/kws_live's own header says it is "one thread, pinned to hart 0
 * (the MBP encodings trap on hart 1)".  So the little hart runs pext.h's software model,
 * which PEXT_SPEC.md 3.5 makes the NORMATIVE definition of the four instructions, and
 * Lab B151 stage 1 showed the two builds agree on all twelve int8 logits of the baked
 * input.  Same arithmetic, two machines -- that is the heterogeneity story, not a
 * workaround.  samples/tacit_pext_smp establishes the pattern.
 *
 * ---------------------------------------------------------------------------------
 * THE THREE DESIGN DECISIONS THIS FILE MAKES, MADE OUT LOUD
 * ---------------------------------------------------------------------------------
 *
 * 1. THE OLED BELONGS TO HART 0 ALONE.  The display is one I2C bus behind
 *    oled_status_bus_lock(), a full refresh costs ~86 ms of transfer, and signdet_live
 *    holds that same mutex ACROSS the whole camera DMA capture (which is why its
 *    SD_FRAME line carries oled_draws_during=).  Letting the keyword spotter draw would
 *    add a SECOND contention mechanism -- mutex serialisation on a shared peripheral --
 *    on top of the L2 contention this lab exists to measure, and the two would be
 *    inseparable in the per-frame numbers.  So KWS reports to the console only.
 *    That is a deliberate scope cut, not an oversight: the bus-sharing question already
 *    has its own lab (B139 / scripts/83, which runs it as two arms), and mixing it in
 *    here would make both answers weaker.
 *
 * 2. THE TRACE IS THE WHOLE RUN, FROM THE RESET VECTOR.  (Lab B153 replaced the window
 *    this decision used to describe.)  arch/riscv/core/reset.S, under CONFIG_STARTUP_TACIT,
 *    programs each hart's sink address and TR_TE_TARGET and asserts enable BEFORE it hands
 *    control to z_prep_c -- so both encoders are running from the reset vector and the
 *    trace covers the boot, the SMP bring-up, thread creation, the pin, model init, the
 *    weight load and every inference.  main() only CLOSES it.
 *
 *    THE TARGET IS NOT A DON'T-CARE.  CONFIG_STARTUP_TACIT_TARGET defaults to 0 and
 *    TraceSinkArbiter drives ready for targets with no sink attached, so target 0 on this
 *    design accepts every byte at full rate and drops it -- a trace that looks like it is
 *    running and produces nothing.  This SoC's chain ends in tacit.WithTraceSinkDMA(1)
 *    (fpga/pynq-z2/chipyard/PynqZ2Configs.scala), so the target is 1, and trace_begin()
 *    proves it by requiring TR_SK_DMA_COUNT to be NON-ZERO by the time main() runs.
 *
 *    WHAT BOUNDS IT IS EITHER THE WORK OR ONE WALL CLOCK -- never a spin.  There is still
 *    no limit register, so the encoder runs from reset until software stops it and the
 *    stop is the ONLY thing keeping a lane inside its buffer.  Two bounds are offered and
 *    every run checks TR_SK_DMA_COUNT against the room the lane actually had either way:
 *    B153's COUNT OF COMPLETED WORK per hart (DUO_WINDOW_MS = 0), and B156's SHARED
 *    WALL-CLOCK WINDOW (DUO_WINDOW_MS > 0), which is the only one of the two that can make
 *    two workloads of different speeds stop together.  See DUO_WINDOW_MS below.
 *
 * 3. FREE-RUNNING, NOT LOCKSTEP.  Both workloads run at their own natural rate and the
 *    contention is whatever the two sensors' duty cycles actually produce -- because
 *    that is what an embedded pipeline does, and because lockstep rounds would measure a
 *    phase relationship chosen by the harness rather than one the system produces.  The
 *    cost is reproducibility: the overlap is not identical run to run, which is why the
 *    reported per-unit numbers are per-frame and per-inference CYCLE COUNTS (medians over
 *    many units) rather than wall-clock totals.  Lockstep would give tighter error bars
 *    on a quantity that is partly an artefact of the harness; this way the error bars are
 *    honest about the machine.  The Perfetto timeline is therefore a lockstep VIEW of a
 *    free-running system: both lanes share one mcycle origin (the reset vector), so the
 *    overlap it shows is the real one rather than one the harness imposed.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>

#include <tacit/tacit.h>

/* The two workloads, linked from their own samples. */
void demo(void *a1, void *a2, void *a3);     /* samples/signdet_live  -- hart 0 */
int  kws_body(void);                         /* samples/kws_live      -- hart 1 */

#ifndef DUO_SIGN
#define DUO_SIGN 1
#endif
#ifndef DUO_KWS
#define DUO_KWS 1
#endif
#ifndef DUO_TRACE
#define DUO_TRACE 1
#endif
/*
 * DUO_TRACE_MS / DUO_TRACE_DELAY_MS ARE DEAD, AND DELIBERATELY LEFT VISIBLE.  Lab B153.
 *
 * They described a trace that was a WINDOW in the middle of a free-running pair of
 * workloads: sleep DUO_TRACE_DELAY_MS, arm, spin DUO_TRACE_MS, disarm.  The spin is what
 * broke it -- see the long comment at the wait in main() -- and the DELAYED ARM is what
 * B153 removed, because a window that opens late cannot cover the boot.  Neither number
 * has anything left to select, and they are still printed on the DUO_BOOT line so a reader
 * comparing a B153 console against a B151 one sees the same fields and sees them zeroed.
 * B156's DUO_WINDOW_MS below is NOT these two revived: it never delays the arm, it only
 * closes a trace that has been running since the reset vector.
 *
 * WHAT THIS MEANS FOR scripts/88 (Lab B151), WHICH STILL BUILDS THIS FILE.  That lab runs
 * SD_FRAMES=450 and used to trace a 250 ms window inside it.  There is no window any more,
 * so an unmodified scripts/88 run now traces ALL 450 frames and hart 0 will run past the
 * 16 MiB its legacy 1 << 24 stride gives it.  That is not silent: trace_end() prints
 * fits=0 and DUO_FAIL, and scripts/88's own FSync check refuses the result.  To trace that
 * lab again, build it with samples/tacit_duo/from_reset.conf (which moves the sinks and
 * sizes them) and a frame count the measured rate supports -- scripts/89 is the worked
 * example.  B151's CONTENTION numbers are unaffected: they come from the per-frame cycle
 * counts on the console, not from the trace.
 */
#define DUO_TRACE_MS 0
#define DUO_TRACE_DELAY_MS 0

/*
 * ---------------------------------------------------------------------------------------
 * DUO_WINDOW_MS -- ONE WALL-CLOCK WINDOW THAT BOUNDS BOTH HARTS.  Lab B156.
 * ---------------------------------------------------------------------------------------
 *
 * WHAT B153's WORK BOUND PRODUCED, MEASURED ON ITS OWN ARTEFACT
 * (out/b153_duo/trace.merged.perfetto.json, 48.2 MB, 391,880 events):
 *
 *   hart 0  mb_pext_conv_* [hw]   2.16 s -> 11.09 s, then arch_spin_relax (13,635),
 *                                 uart_sifive_poll_out (8,521), console_out (8,437) to 55.04 s
 *   hart 1  fe_log2_q8 / mb_pext_conv_* [sw]   0.14 s -> 55.03 s
 *
 * The detector finished at 11.1 s and hart 0 then idled for 44 s -- 80 % of the trace, and
 * the centrepiece of the tutorial's TACIT unit shows one busy hart and one dead one.  The
 * cause is not a bad choice of counts: SD_FRAMES counts camera frames at ~0.97 s each and
 * KWS_SECONDS counts 32 ms audio blocks the little hart chews at ~0.22 s each, so making
 * the two counts agree means predicting two per-unit costs that change with every build.
 *
 * A WALL CLOCK IS THE ONE BOUND BOTH HARTS CAN SHARE.  With DUO_WINDOW_MS > 0:
 *
 *   * each workload is given MORE work than the window can consume (SD_FRAMES=0 and a
 *     KWS_SECONDS far beyond what the window can reach), so neither can run out early;
 *   * main() BLOCKS -- k_msleep(), never k_busy_wait(), which is the mistake B153 found --
 *     until the window's deadline, measured from the RESET VECTOR rather than from this
 *     call, so span_cycles is the window regardless of how long the boot took;
 *   * the encoders are stopped AT the deadline, with both workloads still running, so the
 *     two lanes end at the same cycle by construction rather than by luck; and
 *   * only then are the workloads asked to wind up their current unit, so every console
 *     count (the 8/8 replay gate, KWS_DUTY) is still reported for whole units of work.
 *
 * DUO_WINDOW_MS = 0 keeps B153's behaviour exactly -- bounded by completed work -- so
 * scripts/89 reproduces B153 unchanged.
 *
 * HOW THIS RELATES TO THE DEAD DUO_TRACE_MS ABOVE, AND TO THE B155 HAND-OFF.  It is not
 * the same mechanism and it does not revive it.  DUO_TRACE_MS described a window that
 * OPENED LATE (sleep, arm, spin, disarm) and so gave up the boot; this one opens in
 * reset.S and only ever CLOSES early.  A lab that needs a window positioned in the middle
 * of a run still has no delayed arm here -- what it gains is that the closing half of that
 * mechanism now exists and is exercised, and that the harness no longer spins.
 */
#ifndef DUO_WINDOW_MS
#define DUO_WINDOW_MS 0
#endif

/* mcycle's clock -- the CORE clock, not mtime's CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC. */
#ifndef DUO_CORE_HZ
#define DUO_CORE_HZ 40000000u
#endif

#ifndef DUO_RUN_TIMEOUT_S
/* A BACKSTOP, NOT THE BOUND.  The bound is SD_FRAMES live frames on hart 0 (after the 8
 * baked replay frames) and kws_live's audio budget on hart 1; this only stops the lab
 * hanging forever if a workload wedges.  If it fires, DUO_DONE reports got < want. */
#define DUO_RUN_TIMEOUT_S 1200
#endif

/*
 * ---------------------------------------------------------------------------------------
 * WHERE THE SINKS WRITE, AND WHY EACH HART GETS A DIFFERENT AMOUNT OF ROOM.  Lab B153.
 * ---------------------------------------------------------------------------------------
 *
 * THERE IS NO LIMIT REGISTER.  tacit.h exposes TR_SK_DMA_ADDR (base) and TR_SK_DMA_COUNT
 * (bytes written) and nothing else; l_trace_sink_dma_configure_addr()'s third argument is
 * `bypass`, not a size.  The sink writes linearly from its base and neither wraps nor
 * stops.  So the old TACIT_BUF_SPAN was never a bound the hardware enforced -- it was only
 * the SPACING between hart 0's buffer and hart 1's, and a hart 0 trace longer than the
 * stride silently overwrote hart 1's lane and kept going.  Two consequences run through
 * the rest of this file:
 *
 *   (a) a full trace is a memory-map problem, not a hardware limit -- give a hart more
 *       room and it records for longer; and
 *   (b) EVERY run must check TR_SK_DMA_COUNT against the room it actually had, because an
 *       overrun corrupts the other lane and reports no error at all.
 *
 * THE MEASURED MAP OF THIS IMAGE (B153, verified against the ELF and the linked sources,
 * not assumed):
 *
 *   0x8000_0000 .. 0x8018_3E38   the loaded image, to __kernel_ram_end.  bss ends at
 *                                0x8017_7E30 and noinit (which holds the interrupt
 *                                stacks) at 0x8018_3E38.
 *   0x8E00_0000 .. 0x8E40_0000   signdet_live's 4 MiB L2 eviction sweep, evict_l2_4mib().
 *                                READ-ONLY, but it is 4 MiB of L2 pressure we must not
 *                                also be DMAing into.
 *   0x9000_0000                  top of DRAM (ram0 = <0x80000000 0x10000000>, 256 MB).
 *
 * The engine runtime's 0x8800_0000 .. 0x8E00_0000 reservation that signdet_live's comment
 * mentions does NOT apply here: `nm` on this image finds no mbxr/roccmoon symbol, because
 * samples/tacit_duo does not link the engine runtime.  That whole range is free.
 *
 * FROM RESET, THE BASES COME FROM KCONFIG AND THE STRIDE IS A POWER OF TWO.  reset.S
 * computes buf = CONFIG_STARTUP_TACIT_SINK_DMA_ADDR + (mhartid << SHIFT) before it
 * asserts enable, so the two bases must be a power of two apart.  The SPANS need not be:
 * hart h's room runs to the next hart's base, and the last hart's runs to the sweep.  With
 * ADDR = 0x8100_0000 and SHIFT = 26 that is
 *
 *   hart 0   0x8100_0000 .. 0x8500_0000    64 MiB   (camera + SignDetLite)
 *   hart 1   0x8500_0000 .. 0x8E00_0000   144 MiB   (MFCC + kws cnn_tiny)
 *
 * 14.5 MiB clear of the top of the image and stopping exactly at the eviction sweep.
 *
 * THE BIG REGION GOES TO HART 1, WHICH IS NOT THE BUSY WORKLOAD.  Measured over a 70.5 s
 * run: hart 0 emitted 33,839,802 B (0.0120 B/core cycle), hart 1 emitted 77,509,164 B
 * (0.0275 B/core cycle).  Trace volume follows BRANCH density, not arithmetic: hart 0 runs
 * long straight-line ML kernels while hart 1 sits in short spin and scheduler loops, and
 * BRANCH_MODE_TARGET emits a packet per taken branch.  The first layout assumed the
 * opposite and hart 1 overran its region by 10.4 MB.
 */
#if defined(CONFIG_STARTUP_TACIT) && defined(CONFIG_STARTUP_TACIT_SINK_DMA_ADDR) && \
	(CONFIG_STARTUP_TACIT_SINK_DMA_ADDR != 0)
/* The encoders were armed in reset.S, before z_prep_c. This build traces from RESET. */
#define DUO_FROM_RESET  1
#define TACIT_BUF_BASE  ((uint64_t)CONFIG_STARTUP_TACIT_SINK_DMA_ADDR)
#define TACIT_BUF_SHIFT (CONFIG_STARTUP_TACIT_SINK_DMA_SHIFT)
#else
/* Legacy windowed mode: this file arms the encoders itself, from main(). */
#define DUO_FROM_RESET  0
#define TACIT_BUF_BASE  0x88000000ULL
#define TACIT_BUF_SHIFT 24
#endif
#define TACIT_BUF_STRIDE (1ULL << TACIT_BUF_SHIFT)

/* signdet_live's evict_l2_4mib() sweeps 0x8E00_0000 .. 0x8E40_0000 on every live frame.
 * The last hart's region stops here. */
#define TACIT_SINK_TOP   0x8E000000ULL

#define DUO_NHARTS 2

/* Linker-provided top of everything the image statically owns, so the sink placement can
 * be checked against the real image rather than against a remembered number. */
extern char _end[];

/* SiFive InclusiveCache control node, as samples/tacit_pext_smp uses it. */
#define L2_CTRL_BASE 0x2010000UL
#define L2_CONFIG    (L2_CTRL_BASE + 0x000)
#define L2_FLUSH64   (L2_CTRL_BASE + 0x200)

K_THREAD_STACK_DEFINE(sign_stack, 16384);
K_THREAD_STACK_DEFINE(kws_stack, 16384);
K_THREAD_STACK_DEFINE(trail_stack, 1024);
static struct k_thread sign_thread;
static struct k_thread kws_thread;
static struct k_thread trail_thread;
static struct k_sem done_sem;
static volatile int trail_ready, trail_stop;

static volatile uint32_t sign_running, kws_running;

/*
 * THE WINDOW FLAG, AND THE TWO HOOKS THE WORKLOADS ASK.  Lab B156.
 *
 * samples/signdet_live and samples/kws_live are compiled here out of their own directories
 * with SD_STOP_HOOK / KWS_STOP_HOOK -- default-off, exactly like SD_NO_MAIN / KWS_NO_MAIN,
 * so the standalone images those two samples build for scripts/37, 38, 83, 86 and 87 are
 * unchanged: without the define the predicate is a `static inline` returning 0 and the
 * loop condition folds away.
 *
 * `volatile` and nothing else: one writer (main, after the encoders are stopped), two
 * readers on two harts, and the flag only ever goes 0 -> 1.  A workload that reads it one
 * loop iteration late simply does one more unit of work outside the traced window.
 */
static volatile int duo_window_closed;

int sd_should_stop(void)
{
	return duo_window_closed;
}

int kws_should_stop(void)
{
	return duo_window_closed;
}

/*
 * THE ARM SELECTORS ARE RUNTIME VARIABLES, NOT #if, AND THAT IS THE POINT.
 *
 * The first version of this file guarded the two k_thread_create() calls with #if
 * DUO_SIGN / #if DUO_KWS. It built, and it produced three USELESS images: with
 * -ffunction-sections -fdata-sections and --gc-sections the linker collected the
 * workload that was compiled out, so the "sign alone" control was 1,010,184 bytes
 * against the duo's 1,096,504 and the "kws alone" control was 142,416. Three different
 * code layouts is three different I-cache behaviours, and a control that differs from
 * its treatment in layout cannot isolate a 1 % effect -- it IS a 1 % effect.
 *
 * As `volatile` globals both entry points stay referenced from reachable code, so every
 * arm links the same text in the same order and the images differ in two initialised
 * words. The solo/contended comparison is then a comparison of RUNS, not of binaries.
 */
static volatile int duo_sign = DUO_SIGN;
static volatile int duo_kws = DUO_KWS;

static inline uint64_t rdcycle(void)
{
	uint64_t c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
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

static void sign_entry(void *a, void *b, void *c)
{
	sign_running = 1;
	demo(a, b, c);
	sign_running = 0;
	k_sem_give(&done_sem);
}

/*
 * ---------------------------------------------------------------------------------------
 * WHY HART 1 NEEDS A THREAD THAT DOES NOTHING.  Lab B153.
 * ---------------------------------------------------------------------------------------
 *
 * The encoder emits its closing FSync packet when enable falls, but it is driven by its
 * OWN TILE'S RETIRE PORT: the packet needs retired instructions behind it to be clocked
 * out.  Hart 0 always has them -- main() is the thread doing the stopping.  Hart 1 does
 * not: by the time both workloads have finished, the keyword spotter has returned and hart
 * 1 is in the idle thread, which is `wfi`.  Stopping its encoder there leaves the closing
 * packet stuck in the encoder and the decoder reports "no FSync", which the runner reads --
 * correctly, for its usual cause -- as a TRUNCATED lane.
 *
 * MEASURED: the first B153 calibration run stopped hart 1's encoder while hart 1 was
 * idle. Its region was 14 % full, so nothing had overrun, and the decoder still consumed
 * all 5,456,448 packets -- but it never saw the terminator, and the run failed the FSync
 * gate for a reason that had nothing to do with the buffer.
 *
 * So: before the stop, put ONE pinned thread on hart 1 whose whole job is to retire
 * instructions, and take it away afterwards.  It runs for the couple of ticks it takes
 * main() to notice it is up plus the length of trace_end(), which at the rate this lab
 * measures is ~100 KB against a 64 MiB region.
 */
static void trail_entry(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	trail_ready = 1;
	while (!trail_stop) {
		__asm__ volatile("nop");
	}
}

static void kws_entry(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);
	kws_running = 1;
	(void)kws_body();
	kws_running = 0;
	k_sem_give(&done_sem);
}

/*
 * THE TRACE WINDOW.
 *
 * Both encoders are configured and started from this thread. The encoder is an ordinary
 * MMIO block attached to its own tile's retire port -- l_trace_encoder_get(h) selects the
 * tile, not the writer -- so one controller can bracket both harts at one instant, which
 * is exactly what putting them on ONE timeline requires. samples/tacit_pext_smp arms each
 * encoder from its own hart because there each hart is also the thing being measured;
 * here the two workloads must not be edited to know about tracing at all.
 */
#if DUO_TRACE
static uint64_t trace_bytes[DUO_NHARTS];
static uint64_t trace_buf[DUO_NHARTS];
static uint64_t trace_span[DUO_NHARTS];
static uint64_t trace_seen0[DUO_NHARTS];
static int      trace_armed[DUO_NHARTS];
static uint64_t trace_c0, trace_c1;

/* Hart h's base is fixed by reset.S's arithmetic; its SPAN runs to the next hart's base,
 * and the last hart's to the eviction sweep. This is the only bound there is. */
static uint64_t hart_base(int h)
{
	return TACIT_BUF_BASE + ((uint64_t)h << TACIT_BUF_SHIFT);
}

static uint64_t hart_span(int h)
{
	return (h + 1 < DUO_NHARTS) ? TACIT_BUF_STRIDE
				    : (TACIT_SINK_TOP - hart_base(h));
}

/*
 * trace_begin() -- called BEFORE k_thread_start() on either workload, in both modes.
 *
 * FROM RESET (DUO_FROM_RESET): there is nothing to arm.  reset.S programmed each hart's
 * sink address and TR_TE_TARGET and asserted enable before z_prep_c, so both encoders have
 * been running since the reset vector.  Touching them here would DESTROY the boot trace:
 * l_trace_encoder_stop() followed by a reconfigure and restart throws away everything from
 * reset to this call, and TR_TE_TARGET is a live mux -- re-targeting a running encoder
 * hands the sink a stream that begins mid-packet with no sync packet to lock onto.  So
 * this function only READS, and what it reads is the proof the setup is right:
 *
 *   TR_SK_DMA_ADDR must read back as the base reset.S computed, and
 *   TR_SK_DMA_COUNT must already be NON-ZERO.
 *
 * The count is the load-bearing check.  CONFIG_STARTUP_TACIT_TARGET defaults to 0, and
 * TraceSinkArbiter drives ready for targets that have no sink attached -- so target 0 on
 * this design accepts every byte at full rate and discards it.  An encoder that "is
 * running" proves nothing; a count that has moved proves the bytes are landing.
 */
static void trace_begin(void)
{
	int h;

	for (h = 0; h < DUO_NHARTS; h++) {
		LTraceSinkDmaType *sink = l_trace_sink_dma_get(h);
		uint64_t buf = hart_base(h);

		trace_buf[h] = buf;
		trace_span[h] = hart_span(h);

#if !DUO_FROM_RESET
		{
			LTraceEncoderType *enc = l_trace_encoder_get(h);

			l_trace_encoder_stop(enc);
			l_trace_sink_dma_configure_addr(sink, buf, 0);
			l_trace_encoder_configure_target(enc, TARGET_DMA);
			l_trace_encoder_configure_branch_mode(enc, BRANCH_MODE_TARGET);
		}
#endif
		trace_seen0[h] = sink->TR_SK_DMA_COUNT;
		/* Read the address back: a sink that did not take its base would still
		 * "work" and would write over whatever is at its power-on default. */
		trace_armed[h] = (sink->TR_SK_DMA_ADDR == buf)
#if DUO_FROM_RESET
				 && (trace_seen0[h] > 0)
#endif
				 ;
		printk("DUO_TRACE_ARM hart=%d from_reset=%d buf=0x%08x addr_rb=0x%08x "
		       "span=%llu count_at_main=%llu ok=%d\n",
		       h, DUO_FROM_RESET, (unsigned int)buf,
		       (unsigned int)sink->TR_SK_DMA_ADDR,
		       (unsigned long long)trace_span[h],
		       (unsigned long long)trace_seen0[h], trace_armed[h]);
	}

#if DUO_FROM_RESET
	/* mcycle is counted from reset and so is this trace, so the window opens at 0.
	 * Nothing is started here -- see the comment above. */
	trace_c0 = 0;
#else
	trace_c0 = rdcycle();
	for (h = 0; h < DUO_NHARTS; h++) {
		if (trace_armed[h]) {
			l_trace_encoder_start(l_trace_encoder_get(h));
		}
	}
#endif
}

/* trace_end() -- stop both encoders, push the trailing packet out, flush, read the count.
 * Identical in both modes: from reset or from a window, the way a trace is CLOSED is the
 * same, and closing it is the only thing that keeps a lane inside its buffer. */
static void trace_end(void)
{
	int h;

	for (h = 0; h < DUO_NHARTS; h++) {
		if (trace_armed[h]) {
			l_trace_encoder_stop(l_trace_encoder_get(h));
		}
	}
	trace_c1 = rdcycle();
	/* The trailing sync packet needs retired instructions behind it to push it out. */
	for (volatile int i = 0; i < 4000; i++) {
		__asm__ volatile("nop");
	}
	for (h = 0; h < DUO_NHARTS; h++) {
		LTraceSinkDmaType *sink = l_trace_sink_dma_get(h);

		if (!trace_armed[h]) {
			continue;
		}
		sink->TR_SK_DMA_FLUSH = 1;
		while (sink->TR_SK_DMA_FLUSH_DONE == 0) {
		}
		trace_bytes[h] = sink->TR_SK_DMA_COUNT;
	}
}
#endif /* DUO_TRACE */

/*
 * duo_collect() -- take the completion semaphore until every started workload has given it.
 *
 * THIS MUST BLOCK, AND THAT IS THE WHOLE OF LAB B153's FIX.  What used to be here was
 * `k_busy_wait(DUO_TRACE_MS * 1000)`, which SPINS and never yields: the main thread runs on
 * hart 0 at priority 0, the same hart and priority as the pinned `signdet` thread, so for
 * the entire traced window hart 0 executed the harness's own delay loop and B151's hart 0
 * lane came back with 419,102 calls to sys_clock_cycle_get_32 inside one z_impl_k_busy_wait,
 * two distinct functions, and not one signdet frame.  k_sem_take() leaves the run queue.
 *
 * THE TIMEOUT IS A BACKSTOP, NOT THE BOUND.  If it fires, got < want and DUO_DONE says so;
 * the trace is closed and gated either way.
 */
static void duo_collect(int *got, int want)
{
	while (*got < want) {
		if (k_sem_take(&done_sem, K_SECONDS(DUO_RUN_TIMEOUT_S)) != 0) {
			printk("DUO_WARN sem timeout after %d of %d workload(s)\n", *got, want);
			break;
		}
		(*got)++;
	}
}

#if DUO_WINDOW_MS > 0
/*
 * duo_wait_window() -- block until the window closes, counted from the RESET VECTOR.
 *
 * The deadline is measured against mcycle, not against this call, because mcycle's zero is
 * the trace's zero: the encoders have been running since reset.S.  Sleeping DUO_WINDOW_MS
 * from HERE would make span_cycles = window + however long the boot took, and the boot is
 * not a constant (it moves with console volume and with the other hart's contention).
 * Subtracting the elapsed time makes span_cycles the window, run to run.
 *
 * k_msleep(), not k_busy_wait(): see duo_collect() above.  The main thread must be off hart
 * 0's run queue for the whole window or it starves the detector it is supposed to be
 * tracing -- which is the exact defect this lab's window replaces.
 */
static void duo_wait_window(void)
{
	uint64_t at_ms = rdcycle() / (uint64_t)(DUO_CORE_HZ / 1000u);
	int64_t left = (int64_t)DUO_WINDOW_MS - (int64_t)at_ms;

	printk("DUO_WINDOW ms=%d reached_wait_at_ms=%llu sleep_ms=%lld\n",
	       DUO_WINDOW_MS, (unsigned long long)at_ms,
	       (long long)(left > 0 ? left : 0));
	if (left <= 0) {
		printk("DUO_WARN the window had already closed before main() could wait -- "
		       "DUO_WINDOW_MS is shorter than this image's boot\n");
		return;
	}
	k_msleep((int32_t)left);
}
#endif

int main(void)
{
	uint32_t l2cfg = *(volatile uint32_t *)L2_CONFIG;
	uint32_t l2_block = 1u << ((l2cfg >> 24) & 0xff);
	unsigned int ncpus = arch_num_cpus();
	int want = 0, got = 0, rc;

	printk("\nDUO_BOOT sample=tacit_duo board=%s sign=%d kws=%d trace=%d "
	       "trace_ms=%d delay_ms=%d ncpus=%u clock=%d from_reset=%d timeout_s=%d "
	       "window_ms=%d core_hz=%u\n",
	       CONFIG_BOARD_TARGET, duo_sign, duo_kws, DUO_TRACE, DUO_TRACE_MS,
	       DUO_TRACE_DELAY_MS, ncpus, CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC,
	       DUO_FROM_RESET, DUO_RUN_TIMEOUT_S, DUO_WINDOW_MS, DUO_CORE_HZ);
	printk("DUO_L2 banks=%u ways=%u lgSets=%u block=%u\n", l2cfg & 0xff,
	       (l2cfg >> 8) & 0xff, (l2cfg >> 16) & 0xff, l2_block);

	if (ncpus < 2) {
		printk("DUO_FAIL only %u CPU(s) -- CONFIG_MP_MAX_NUM_CPUS must be 2\n", ncpus);
		return 0;
	}

	k_sem_init(&done_sem, 0, 2);

#if DUO_TRACE
	/*
	 * THE TRACE IS OPENED BEFORE EITHER WORKLOAD THREAD STARTS.  In DUO_FROM_RESET
	 * builds it was opened earlier still -- in reset.S, before z_prep_c -- and this call
	 * only reads back what reset.S programmed.  Either way nothing that follows,
	 * including k_thread_create(), the pin, the model init and the weight load, happens
	 * outside the traced window.
	 */
	printk("DUO_TRACE_MAP image_end=0x%08lx base0=0x%08x span0=%llu base1=0x%08x "
	       "span1=%llu sweep=0x%08x from_reset=%d\n",
	       (unsigned long)(uintptr_t)_end,
	       (unsigned int)hart_base(0), (unsigned long long)hart_span(0),
	       (unsigned int)hart_base(1), (unsigned long long)hart_span(1),
	       (unsigned int)TACIT_SINK_TOP, DUO_FROM_RESET);
	/* A sink placed inside the image would be overwritten by BSS zeroing and by the
	 * interrupt stacks, both of which run inside the traced window. */
	if (hart_base(0) < (uint64_t)(uintptr_t)_end) {
		printk("DUO_FAIL sink base 0x%08x is below the top of the image 0x%08lx\n",
		       (unsigned int)hart_base(0), (unsigned long)(uintptr_t)_end);
		return 0;
	}
	trace_begin();
#endif

	if (duo_sign) {
		/* Create K_FOREVER, pin, then start. k_thread_cpu_pin() binds only a
		 * thread that has not begun running -- Lab B151 stage 1 watched the
		 * in-place variant silently do nothing and report hart 0 for a build
		 * that had asked for hart 1. */
		k_tid_t tid = k_thread_create(&sign_thread, sign_stack,
					      K_THREAD_STACK_SIZEOF(sign_stack),
					      sign_entry, NULL, NULL, NULL,
					      0, 0, K_FOREVER);

		rc = k_thread_cpu_pin(tid, 0);
		k_thread_name_set(tid, "signdet");
		printk("DUO_PIN who=sign cpu=0 rc=%d\n", rc);
		if (rc != 0) {
			printk("DUO_FAIL sign not pinned to CPU 0 -- its curated kernels "
			       "emit custom-0 and hart 1 would trap\n");
			return 0;
		}
		k_thread_start(tid);
		want++;
	}
	if (duo_kws) {
		k_tid_t tid = k_thread_create(&kws_thread, kws_stack,
					      K_THREAD_STACK_SIZEOF(kws_stack),
					      kws_entry, NULL, NULL, NULL,
					      5, 0, K_FOREVER);

		rc = k_thread_cpu_pin(tid, 1);
		k_thread_name_set(tid, "kws");
		printk("DUO_PIN who=kws cpu=1 rc=%d\n", rc);
		if (rc != 0) {
			printk("DUO_FAIL kws not pinned to CPU 1 -- it would report the "
			       "big hart's cycles as the little hart's\n");
			return 0;
		}
		k_thread_start(tid);
		want++;
	}

	/*
	 * ---------------------------------------------------------------------------------
	 * WHAT BOUNDS THE RUN -- AND WHICHEVER IT IS, THIS WAIT MUST BLOCK.  B153, then B156.
	 * ---------------------------------------------------------------------------------
	 *
	 * What used to be here was
	 *
	 *     arm_trace(); k_busy_wait(DUO_TRACE_MS * 1000); disarm_trace();
	 *
	 * and it produced a 250 ms trace of ITSELF.  k_busy_wait() SPINS -- it never yields
	 * -- and the main thread runs on hart 0 at priority 0, the same hart and the same
	 * priority as the pinned `signdet` thread.  So for the whole traced window hart 0
	 * executed the tracing harness's own delay loop and the detector never got the CPU:
	 * B151's hart 0 lane came back with 419,102 calls to sys_clock_cycle_get_32 nested
	 * inside one z_impl_k_busy_wait, TWO distinct functions, and not one signdet frame.
	 * Hart 1 is a different CPU, so the keyword spotter was unaffected -- which is why
	 * the artefact looked half-plausible instead of obviously broken.
	 *
	 * BOTH bounds below therefore BLOCK -- k_sem_take() and k_msleep(), never a spin --
	 * so the main thread leaves the run queue and hart 0 belongs to `signdet`.  That is
	 * the invariant; the choice between them is a choice about what ENDS the run:
	 *
	 *   DUO_WINDOW_MS = 0   COMPLETED WORK (B153).  Each workload runs its own count of
	 *                       units and the trace ends when the slower one is done.  Whole
	 *                       units on both lanes -- and two counts that cannot be made to
	 *                       agree, which is how B153's artefact came to be 80 % a
	 *                       recording of an idle hart 0.
	 *   DUO_WINDOW_MS > 0   ONE WALL CLOCK (B156).  Both lanes are over-fed and the
	 *                       deadline stops them together.  The last unit on each lane is
	 *                       cut mid-flight in the TRACE -- the workload itself still
	 *                       finishes it, outside the window, so every console count is
	 *                       still a whole unit.
	 *
	 * THE SEMAPHORE TIMEOUT IS A BACKSTOP, NOT THE BOUND.  If it ever fires, `got < want`
	 * and the DUO_DONE line below says so; the trace is still closed and still gated.
	 */
#if DUO_WINDOW_MS > 0
	/*
	 * TIME-BOUNDED (Lab B156).  Both workloads were given more work than this window can
	 * consume, so neither runs out: SD_FRAMES=0 makes the detector's live loop unbounded
	 * and KWS_SECONDS is set past what the little hart can chew.  The window is what ends
	 * them, and it ends them TOGETHER -- the encoders are stopped below while both are
	 * still mid-workload, and only then is duo_window_closed raised.
	 */
	duo_wait_window();
#else
	/*
	 * WORK-BOUNDED (Lab B153, and what scripts/89 reproduces).  The run ends when both
	 * workloads have completed their own COUNT of work -- SD_FRAMES live frames after the
	 * 8 baked replay frames, and kws_live's block budget.  Whole units, but two counts
	 * that cannot be made to agree: B153 measured 11.09 s against 55.03 s.
	 */
	duo_collect(&got, want);
#endif

#if DUO_TRACE
	/* Put a retiring thread on hart 1 across the stop -- see trail_entry(). */
	{
		k_tid_t t = k_thread_create(&trail_thread, trail_stack,
					    K_THREAD_STACK_SIZEOF(trail_stack),
					    trail_entry, NULL, NULL, NULL,
					    0, 0, K_FOREVER);
		int trc = k_thread_cpu_pin(t, 1);
		int spins = 0;

		k_thread_name_set(t, "trail");
		if (trc == 0) {
			k_thread_start(t);
			/* Bounded: a trail thread that never reaches hart 1 must not hang
			 * the lab, it must be reported and the stop must still happen. */
			while (!trail_ready && spins < 200) {
				k_msleep(1);
				spins++;
			}
		}
		printk("DUO_TRAIL pin_rc=%d ready=%d spins=%d\n", trc, trail_ready, spins);
	}
	trace_end();
	trail_stop = 1;
#endif

#if DUO_WINDOW_MS > 0
	/*
	 * THE ENCODERS ARE ALREADY STOPPED.  Everything from here on is outside the trace, so
	 * winding the workloads down costs the artefact nothing -- which is why the flag is
	 * raised HERE and not before trace_end(): both lanes are busy right up to the cut and
	 * both lanes stop at the same cycle.  Each workload leaves after at most one more unit
	 * (a camera frame, ~0.97 s; an inference, ~1.4 s), so SD_RESULT, the 8/8 replay gate
	 * and KWS_DUTY are all still reported over whole units.
	 */
	duo_window_closed = 1;
	duo_collect(&got, want);
#endif

#if DUO_TRACE
	{
		uint64_t span = trace_c1 - trace_c0;
		int h, overrun = 0, overlap = 0;

		for (h = 0; h < DUO_NHARTS; h++) {
			/* bytes per second, integer: bytes * clock / span. The clock here
			 * is mcycle's, which is the core clock, not mtime's. */
			uint64_t bps = span ? (trace_bytes[h] * (uint64_t)DUO_CORE_HZ) / span : 0;
			/* ... and the number that actually sizes a buffer: bytes per CORE
			 * CYCLE, scaled by 1e6 because there is no FPU in this image. */
			uint64_t bpc6 = span ? (trace_bytes[h] * 1000000ull) / span : 0;
			int fits = (trace_bytes[h] <= trace_span[h]);

			if (!fits) {
				overrun = 1;
			}
			printk("DUO_TRACE_HART hart=%d buf=0x%08x bytes=%llu span_cycles=%llu "
			       "bytes_per_s=%llu buf_span=%llu full_pct=%llu armed=%d "
			       "bytes_per_cycle_x1e6=%llu fits=%d\n",
			       h, (unsigned int)trace_buf[h],
			       (unsigned long long)trace_bytes[h],
			       (unsigned long long)span, (unsigned long long)bps,
			       (unsigned long long)trace_span[h],
			       (unsigned long long)(trace_span[h]
						    ? trace_bytes[h] * 100ull / trace_span[h]
						    : 0),
			       trace_armed[h], (unsigned long long)bpc6, fits);
		}

		/*
		 * THE TWO GATES THAT CANNOT BE SKIPPED.  There is no limit register, so an
		 * overrun is not reported by the hardware in any way: the sink simply keeps
		 * writing into the next hart's lane, and both traces still decode.
		 */
		if (trace_buf[1] < trace_buf[0] + trace_bytes[0]) {
			overlap = 1;
		}
		printk("DUO_TRACE_GATE overrun=%d overlap=%d base0=0x%08x end0=0x%08llx "
		       "base1=0x%08x end1=0x%08llx\n", overrun, overlap,
		       (unsigned int)trace_buf[0],
		       (unsigned long long)(trace_buf[0] + trace_bytes[0]),
		       (unsigned int)trace_buf[1],
		       (unsigned long long)(trace_buf[1] + trace_bytes[1]));
		if (overrun || overlap) {
			printk("DUO_FAIL a sink wrote past its region -- the other lane is "
			       "CORRUPT and both traces will still decode. Do not use them.\n");
		}
		printk("DUO_TRACE_END span_cycles=%llu from_reset=%d\n",
		       (unsigned long long)span, DUO_FROM_RESET);
	}
	/* The sinks are bus masters, so their writes sit in the inclusive L2 while the PS
	 * reads DRAM. Flush both, once, now that both sinks are idle. */
	{
		int h;

		for (h = 0; h < DUO_NHARTS; h++) {
			if (trace_bytes[h] > 0 && trace_bytes[h] <= trace_span[h]) {
				l2_flush_range((uintptr_t)trace_buf[h], trace_bytes[h],
					       l2_block);
			}
		}
	}
#endif

	printk("DUO_DONE want=%d got=%d sign=%d kws=%d\n", want, got, duo_sign, duo_kws);
	return 0;
}
