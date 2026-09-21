/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * THE FIRST LANE DISPATCH EVER ISSUED ON SILICON, and what it is for.
 *
 * ROCC_DECOUPLED.md s8.15.21/22.  Nothing has ever dispatched to a lane: functs 9/10/11 are
 * decoded in the merged engine and no software has issued one.  The number that decides three
 * workstreams' interface designs -- what a lane dispatch costs in software -- is currently a
 * BOUND carried from the GEMM path (eng_h0_cycles - eng_cycles = 4,701-5,190 cycles, flat), and
 * a GEMM dispatch pays for a weight-image cache walk, mbxr_wimage_plan and mbxr_run's tiling
 * planner that a lane dispatch never executes.
 *
 * PREDICTION, COMMITTED BEFORE THIS RAN (s8.15.21): the lane wrapper is 300-1,200 cycles, point
 * estimate ~600.  FALSIFIED above 1,200, in which case the decoder's 26.6 % wrapper tax on T3 is
 * real and structural rather than an artefact of the wrong analogue.
 *
 * NO KERNEL EXISTS YET, AND THAT IS THE POINT.  This measures the wrapper before anyone writes
 * 500 lines against the optimistic assumption.  It needs no correct data either: mbxr_ln.v's own
 * header guarantees the stream length never depends on the data ("a row that raises err[2..4]
 * still produces K outputs"), so an unfilled scratchpad gives exactly the right TIMING and
 * meaningless values.  Correctness is the kernel's job, next.
 *
 * WHAT IT MEASURES
 *   1. Two-point: the same dispatch at R = 2 and R = 28 rows of K = 288.  The difference gives
 *      the lane's cycles per element ON SILICON (LAYERNORM_LANE.md's 1.000 is Verilator), and
 *      the intercept is the wrapper -- the same two-point method the GEMM number came from.
 *   2. The three phases separately: configuration (10 lcfg writes), lgo, and the poll loop.
 *   3. A DELIBERATE PROBE of the one thing reading the RTL could not settle: R = 1 is 36 words,
 *      4.5 drain blocks of 64 bytes, and nothing in mbxr_lnpk pads to a block boundary.  Run
 *      under a poll budget so the answer is a RETURN CODE and not a hung board.
 *   4. That the software preconditions refuse what they must, issuing nothing.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>
#include <string.h>
#include "mbxr.h"
#include "mbxr_lanes.h"

#ifndef LS_K
#define LS_K 288                 /* Moonshine's model dimension */
#endif
/* mbxr_ln.v: cfg_ok requires c_eps > 64'd262144 and bit 63 clear.  A zero epsilon is "config
 * unusable" exactly as a missing K is, and its failure shape is that the lane takes ownership and
 * never returns it -- which is what the first run of this bench measured. */
#ifndef LS_EPS
#define LS_EPS (1ULL << 20)
#endif
#ifndef LS_POLL_BUDGET
#define LS_POLL_BUDGET 2000000ULL
#endif

#define DRAIN_PA  0x8C800000UL   /* MBXR_RT_SCRATCH: the drain's destination */

static inline uint64_t cyc(void)
{
	uint64_t c;
	__asm__ volatile("csrr %0, mcycle" : "=r"(c));
	return c;
}

/* the engine's own commands, the same stubs mbxr_rt.h uses */
__asm__(".pushsection .text.ls_cmd, \"ax\", @progbits\n"
	".balign 4\n"
	"ls_c0: .insn r 0x2B, 3, 0, x0, a0, a1\n ret\n"
	"ls_c5: .insn r 0x2B, 3, 5, x0, a0, a1\n ret\n"
	"ls_c6: .insn r 0x2B, 7, 6, a0, a0, a1\n ret\n"
	"ls_c7: .insn r 0x2B, 7, 7, a0, a0, a1\n ret\n"
	".popsection\n");
extern void     ls_c0(uint64_t, uint64_t) __asm__("ls_c0");
extern void     ls_c5(uint64_t, uint64_t) __asm__("ls_c5");

/* `st`'s rs2 since the drain's descriptor became 2-D (rtl_study/roccmoon/STRIDED_DRAIN.md):
 * {row_stride[63:32], row_bytes[31:16], nrows[15:0]}.  A FLAT drain of `blocks` 64-byte blocks
 * is `blocks` rows of 64 bytes, 64 bytes apart.  THE ROW COUNT IS IN THE LOW SIXTEEN BITS ON
 * PURPOSE: a pre-0x5A5A002E engine reads exactly those bits as `nblocks` and ignores the rest,
 * so this one word is correct on either engine. */
#define ST_RS2_FLAT(blocks)  ((64ULL << 32) | (64ULL << 16) | ((uint64_t)(blocks) & 0xffffULL))

extern uint64_t ls_c6(uint64_t, uint64_t) __asm__("ls_c6");
extern uint64_t ls_c7(uint64_t, uint64_t) __asm__("ls_c7");

/* one dispatch, timed in three phases.  Returns the lane return code. */
static int dispatch(int rows, int k, unsigned flags, uint64_t dst,
		    uint64_t *t_cfg, uint64_t *t_go, uint64_t *t_poll,
		    uint64_t *polls, uint32_t *st_end, int *words)
{
	uint64_t a, b, c, d;
	uint32_t s;
	int rc, w = 0;
	long bytes = (long)rows * k;              /* out8 */
	uint64_t blocks = (uint64_t)((bytes + 63) / 64);

	rc = mbxr_ln_check(rows, k, flags, 0, &w);
	if (rc != MBXR_OK)
		return rc;
	if (words)
		*words = w;

	/* PRECONDITION 3: the drain descriptor is issued and started BEFORE the lane runs. */
	ls_c5(dst, ST_RS2_FLAT(blocks));

	a = cyc();
	rc = mbxr_ln_config(rows, k, k, LS_EPS, flags, 0, NULL);
	b = cyc();
	if (rc != MBXR_OK) {
		*t_cfg = b - a; *t_go = 0; *t_poll = 0; *polls = 0;
		*st_end = mbxr_lane_status();
		return rc;
	}
	rc = mbxr_lane_go(MBXR_GO_LN, 1);
	c = cyc();
	if (rc != MBXR_OK) {
		*t_cfg = b - a; *t_go = c - b; *t_poll = 0; *polls = 0;
		*st_end = mbxr_lane_status();
		return rc;
	}
	rc = mbxr_lane_wait_for(MBXR_GO_LN, LS_POLL_BUDGET, polls, &s);
	d = cyc();
	*t_cfg = b - a; *t_go = c - b; *t_poll = d - c; *st_end = s;
	return rc;
}

static const char *rcname(int rc)
{
	switch (rc) {
	case MBXR_OK:             return "OK";
	case MBXR_E_LANE_WORDS:   return "WORDS(would hang)";
	case MBXR_E_LANE_KALIGN:  return "KALIGN";
	case MBXR_E_LANE_SPAN:    return "SPAN(would wrap)";
	case MBXR_E_LANE_BUSY:    return "BUSY";
	case MBXR_E_LANE_HANG:    return "HANG(budget)";
	case MBXR_E_LANE_ERR:     return "LANE_ERR";
	case MBXR_E_LANE_CFG:     return "CFG";
	case MBXR_E_SHAPE:        return "SHAPE";
	}
	return "?";
}

/* ---- EVERY CUSTOM-1 INSTRUCTION RUNS ON HART 1 ---------------------------------------------
 * The engine, and therefore both lanes, is a RoCC in hart 1's tile: the same instruction on hart 0
 * TRAPS (samples/roccmoon_bench/src/main.c s1 states it and tests it).  The first run of this
 * bench issued `lst` from main() on hart 0 and took an illegal-instruction trap at exactly
 * mbxr_l_st's address -- correct behaviour, my bug, one board load to find.  Everything that
 * touches the lane now runs on a thread pinned to hart 1. */
#define STK 8192
K_THREAD_STACK_DEFINE(h1_stack, STK);
static struct k_thread h1_thread;
static struct k_sem h1_go;
static atomic_t h1_done;

static void h1_entry(void *a, void *b, void *c);

static void lane_body(void);

static void h1_entry(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	k_sem_take(&h1_go, K_FOREVER);
	printk("LS_HART hart=%lu\n", (unsigned long)csr_read(mhartid));
	lane_body();
	atomic_set(&h1_done, 1);
	for (;;)
		k_sleep(K_FOREVER);
}

int main(void)
{
	k_tid_t h1;

	printk("LS_START k=%d\n", LS_K);
	k_sem_init(&h1_go, 0, 1);
	atomic_set(&h1_done, 0);
	h1 = k_thread_create(&h1_thread, h1_stack, STK, h1_entry, NULL, NULL, NULL, 5, 0, K_FOREVER);
	k_thread_cpu_pin(h1, 1);
	k_thread_start(h1);
	k_sem_give(&h1_go);
	while (!atomic_get(&h1_done))
		k_busy_wait(1000);
	printk("LS_DONE\n");
	return 0;
}

static void lane_body(void)
{
	uint64_t tc, tg, tp, np;
	uint32_t s0, s;
	int rc, w;

	/* ---- 0. the lane from reset: ownership with the engine, config unusable ------------- */
	s0 = mbxr_lane_status();
	printk("LS_RESET status=0x%08x own=%u ln_idle=%u drained=%u l_err=0x%02x a_err=0x%x left=%u\n",
	       s0, MBXR_L_OWN(s0), MBXR_L_LN_IDLE(s0), MBXR_L_DRAINED(s0),
	       MBXR_L_LERR(s0), MBXR_L_AERR(s0), MBXR_L_LEFT(s0));

	/* ---- 1. the software preconditions refuse, issuing nothing --------------------------- */
	{
		static const struct { int M, K; unsigned f; const char *what; } bad[] = {
			{ 3, 5, 0, "M*K not a whole word -- would never return ownership" },
			{ 2, 4, 0, "K not word-aligned out -- would land rows misaligned" },
			{ 165, 288, 0, "whole shape in one dispatch -- reader would wrap" },
			{ 1, 16384, 0, "row wider than one buffer -- no tiling helps" },
		};
		for (unsigned i = 0; i < ARRAY_SIZE(bad); i++) {
			rc = mbxr_ln_check(bad[i].M, bad[i].K, bad[i].f, 0, &w);
			printk("LS_GUARD M=%d K=%d rc=%d %-18s %s\n", bad[i].M, bad[i].K, rc,
			       rcname(rc), bad[i].what);
		}
	}

	/* ---- 1b. one affine entry, so the apply side reads something defined ----------------- */
	/* HW = K puts every element of a row at affine index 0, so index 0 is the only one used.
	 * These are not a model's values -- this bench measures timing, not arithmetic -- but an
	 * all-zero table would make every output degenerate and hide a real fault behind a
	 * plausible-looking zero. */
	mbxr_ln_table(0, 1u << 24, 1ULL << 24, 1u << 16, 0u);

	/* ---- 2. the two-point measurement ---------------------------------------------------- */
	/* R = 2 and R = 28 are both whole numbers of 64-byte drain blocks at K = 288 (576 B = 9,
	 * 8,064 B = 126), so neither can stall on a partial block and the difference is clean. */
	{
		static const int rows[] = { 2, 28, 2, 28 };   /* A/B/A/B against drift */
		for (unsigned i = 0; i < ARRAY_SIZE(rows); i++) {
			rc = dispatch(rows[i], LS_K, 0, DRAIN_PA, &tc, &tg, &tp, &np, &s, &w);
			printk("LS_DISP rows=%-3d k=%d words=%-5d rc=%d %-10s cfg=%llu go=%llu "
			       "poll=%llu polls=%llu total=%llu status=0x%08x l_err=0x%02x\n",
			       rows[i], LS_K, w, rc, rcname(rc),
			       (unsigned long long)tc, (unsigned long long)tg,
			       (unsigned long long)tp, (unsigned long long)np,
			       (unsigned long long)(tc + tg + tp), s, MBXR_L_LERR(s));
			(void)ls_c6(0, 0);      /* fence: let the drain finish before the next */
		}
	}

	/* ---- 3. the probe: one row is 4.5 drain blocks and nothing pads to a block ----------- */
	/* Under the poll budget, so an answer of "it never returns" is a LINE OF OUTPUT rather
	 * than a board that has to be power-cycled.  This is the question reading the RTL could
	 * not settle: mbxr_lnpk flushes a partial WORD at each row end, but no stage pads to a
	 * 64-byte BLOCK, and a decoder's layernorm is exactly this shape. */
	rc = dispatch(1, LS_K, 0, DRAIN_PA, &tc, &tg, &tp, &np, &s, &w);
	printk("LS_PROBE rows=1 k=%d words=%d rc=%d %-16s cfg=%llu go=%llu poll=%llu polls=%llu "
	       "status=0x%08x own=%u drained=%u ln_idle=%u l_err=0x%02x\n",
	       LS_K, w, rc, rcname(rc), (unsigned long long)tc, (unsigned long long)tg,
	       (unsigned long long)tp, (unsigned long long)np, s, MBXR_L_OWN(s),
	       MBXR_L_DRAINED(s), MBXR_L_LN_IDLE(s), MBXR_L_LERR(s));
	(void)ls_c6(0, 0);

	/* ---- 4. the engine still works afterwards -------------------------------------------- */
	/* A refused lgo sets the engine's err_sticky, and a lane that kept ownership would show
	 * here.  Reading the engine's own status is the check that the lane has given everything
	 * back -- the lane status word cannot see the engine's side. */
	printk("LS_ENGINE status=0x%016llx\n", (unsigned long long)ls_c6(0, 0));
}
