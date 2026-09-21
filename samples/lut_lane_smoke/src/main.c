/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * THE FIRST DISPATCH EVER ISSUED TO T4's LUT LANE.  M1, M2 and M3 of T4_LANES.md s8.4-8.5
 * and s10.  `0x5A5A002C` has carried `mbxl_lut` since 2026-09-17 and nothing has ever
 * dispatched to it: 73,936 Verilator byte checks and 11 dead mutants say the lane computes,
 * and Verilator has no timing.  MAGIC_REGISTRY.md's row says in its own words that until
 * these run it records "a closed build and not a function".
 *
 * WHAT IS PREDICTED, COMMITTED IN T4_LANES.md s10 BEFORE THIS WAS BUILT:
 *   M1  slope 0.125 cycles/element [0.118, 0.140] -- one 64-bit word in and one out per
 *       cycle -- and an intercept of 150 cycles [110, 400].
 *   M2  1,300-2,900 cycles per 8,192-element tile PIPELINED, against a 3,100-4,400
 *       SEQUENTIAL control.  The control is what makes the test readable: a sequential
 *       harness measures fill+compute+drain serialised WHATEVER the hardware permits, and
 *       s8.5 shows that outcome is indistinguishable by cycle count from an engine that
 *       genuinely does not overlap.
 *   M3  the placement rate, 14-16 cycles/byte byte-wise and 2.0-3.0 word-wise.  s10.1's
 *       sensitivity table says this decides the answer and M1 does not: at 1 element per
 *       cycle instead of 8 the projection moves 0.012 of RTF_e2e, and if every output byte
 *       needs a place-style copy it moves 0.38.
 *
 * WHY A SEPARATE SAMPLE FROM `lane_smoke`.  Four workstreams are live in this tree this
 * round and `samples/lane_smoke` is Lab B33's, whose fitted wrapper every other workstream
 * quotes.  Nothing here edits `sw/roccmoon/mbxr_lanes.h` either: that header already carries
 * MBXR_LANE_LUT, MBXR_GO_LUT, MBXR_L_UERR, MBXR_L_LUT_IDLE and the GO_LUT arms of
 * mbxr_lane_arm / mbxr_lane_go / mbxr_lane_wait_for, so a LUT dispatch needs no new
 * primitive -- only a caller.  The attention workstream is mid-flight in that file.
 *
 * EVERY CUSTOM-1 INSTRUCTION RUNS ON HART 1.  The engine is a RoCC in hart 1's tile; the
 * same instruction on hart 0 takes an illegal-instruction trap and, inside a model thread,
 * faults unhandled with no records and no console output (`60bd85d`: max_abs_err = 0 meaning
 * nothing ran).  Everything that touches the lane is on a thread pinned to hart 1.
 *
 * AND A ZERO THAT MEANS "NOTHING RAN" MUST NOT READ AS "MATCHED" (`438eb27`).  Every stage
 * carries lut_attempted / lut_ok / lut_refused / last_rc / last_uerr, and every byte check
 * carries `checked` alongside `differ` so a check that never executed is a distinct value
 * from a check that passed.  There is no software fallback in this bench, so "the lane did
 * not run" is the only way to get a clean-looking zero, and it is counted.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>
#include <string.h>
#include "mbxr.h"
#include "mbxr_lanes.h"

/* ---- the physical windows, the same ones mbxr_rt.h uses (p2v is the identity here) ------- */
#define IN_PA    0x8C000000UL        /* MBXR_RT_IN_STAGE:  the tiles the lane reads     */
#define DR_PA    0x8C800000UL        /* MBXR_RT_SCRATCH:   where the drain writes       */
#define OUT_PA   0x8D000000UL        /* MBXR_RT_OUT_STAGE: M3's FAR destination         */
#define M3_SRC   0x8D800000UL        /* MBXR_RT_ROW_STAGE: M3 works entirely inside this
                                      * window, so its source and near destinations are 16
                                      * and 24 KB apart and cannot collide in the L1D     */

#define WORDS_MAX   1024             /* mbxl_lut's hard reach: err[2] past this         */
#define TILE_B      (WORDS_MAX * 8)  /* 8,192 int8 = 8 KB = 128 drain blocks            */
#define NTILES      8                /* M2: enough tiles that the per-tile fit is clean */

#ifndef LL_POLL_BUDGET
#define LL_POLL_BUDGET 2000000ULL
#endif
#ifndef LL_FENCE_BUDGET
#define LL_FENCE_BUDGET 2000000ULL
#endif

/* ---- the engine's own commands, the same stubs mbxr_rt.h and lane_smoke use -------------- */
__asm__(".pushsection .text.ll_cmd, \"ax\", @progbits\n"
	".balign 4\n"
	"ll_c0: .insn r 0x2B, 3, 0, x0, a0, a1\n ret\n"   /* sd    source descriptor  */
	"ll_c1: .insn r 0x2B, 3, 1, x0, a0, a1\n ret\n"   /* ld    start a fill       */
	"ll_c2: .insn r 0x2B, 3, 2, x0, a0, a1\n ret\n"   /* cfg   names t_abuf       */
	"ll_c5: .insn r 0x2B, 3, 5, x0, a0, a1\n ret\n"   /* st    drain descriptor   */
	"ll_c6: .insn r 0x2B, 7, 6, a0, a0, a1\n ret\n"   /* fence rd = status        */
	"ll_c7: .insn r 0x2B, 7, 7, a0, a0, a1\n ret\n"   /* stat  rd = counter, rs2[0] clears */
	".popsection\n");
extern void     ll_c0(uint64_t, uint64_t) __asm__("ll_c0");
extern void     ll_c1(uint64_t, uint64_t) __asm__("ll_c1");
extern void     ll_c2(uint64_t, uint64_t) __asm__("ll_c2");
extern void     ll_c5(uint64_t, uint64_t) __asm__("ll_c5");

/* `st`'s rs2 since the drain's descriptor became 2-D (rtl_study/roccmoon/STRIDED_DRAIN.md):
 * {row_stride[63:32], row_bytes[31:16], nrows[15:0]}.  A FLAT drain of `blocks` 64-byte blocks
 * is `blocks` rows of 64 bytes, 64 bytes apart.  THE ROW COUNT IS IN THE LOW SIXTEEN BITS ON
 * PURPOSE: a pre-0x5A5A002E engine reads exactly those bits as `nblocks` and ignores the rest,
 * so this one word is correct on either engine. */
#define ST_RS2_FLAT(blocks)  ((64ULL << 32) | (64ULL << 16) | ((uint64_t)(blocks) & 0xffffULL))

extern uint64_t ll_c6(uint64_t, uint64_t) __asm__("ll_c6");
extern uint64_t ll_c7(uint64_t, uint64_t) __asm__("ll_c7");

static inline uint64_t cyc(void)
{
	uint64_t c;
	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

/* ---- THE ENGINE HAS ALWAYS BEEN ABLE TO SAY "THAT WAS REFUSED", AND NOTHING ASKED ----------
 * mbxr_engine.v:394 ORs every refusal into one sticky bit -- wh_err, a TileLink error, pa_bad,
 * s_ovf, ld_mode_bad, ld_buf_bad, mm_buf_bad, lane_go_bad, ln_go_bad -- and `fence` returns it
 * as MBXR_S_ERR.  Cleared at the top of each dispatch (`sta` with rs2[0]) and read after each
 * stage, it turns "err[2], cause unknown" into "stage X was refused", the first time it
 * happens.  The codes are mbxr_lanes.h's MBXR_E_LANE_R_* and this bench uses them as the
 * attention workstream defined them rather than inventing a second numbering.
 *
 * ARM A DID NOT HAVE THIS, and it is what the diagnosis cost: the sticky bit was set and the
 * OVF bit beside it named the mechanism, but only in the ONE fence read at the very end of the
 * run, by which time it could have come from any of twenty-eight dispatches. */
static inline void err_clear(void) { (void)ll_c7(0, 1); }
static inline int err_set(void)    { return (ll_c6(0, 0) & MBXR_S_ERR) != 0; }

/* ---- the counters that make "nothing ran" visible (438eb27, 60bd85d) --------------------- */
static struct {
	uint32_t attempted, ok, refused;
	int32_t  last_rc;
	uint32_t last_uerr;
	uint32_t bytes_checked, bytes_differ;
	uint32_t fence_timeouts;
} C;

/* ---- the primitives, spelled out because each one is a silent failure if it is missed ----- */

/* An ACTIVATION load.  rs1[18] = 1 selects client A; rs1[17] MUST BE 0, because
 * `ld_mode_bad = ld && (cmd_rs1[17] == ld_a)` -- the weight load is bit 17 SET, not bit 18
 * clear, and getting it backwards leaves the PREVIOUS dispatch's data in the buffer with no
 * error bit anywhere (the attention workstream lost an arm to exactly this).  rs1[16] is the
 * destination buffer.  rs1[11:8] is lgpw and is a weight-path field; 10 is what mbxr.c and
 * mbxr_lanes.h both pass on the activation path. */
static inline int fill_start(uint64_t src_pa, unsigned blocks, unsigned buf)
{
	err_clear();
	ll_c0(src_pa, ((uint64_t)blocks & 0xffffULL) | (1ULL << 16));   /* one row of `blocks` */
	ll_c1((1ULL << 18) | ((uint64_t)buf << 16) | (10ULL << 8), 0);
	/* ld_mode_bad and ld_buf_bad are BOTH silent: a refused load leaves the previous
	 * dispatch's data in the buffer and nothing anywhere says so.  This is the one place the
	 * sticky bit can distinguish that from a lane fault. */
	return err_set() ? MBXR_E_LANE_R_ACTLD : MBXR_OK;
}

/* NAME THE BUFFER.  mbxr_lanes.v:312 addresses the lane's reads as {5'd0, abuf, word} and
 * `abuf` is the engine's t_abuf -- a LIVE wire written only by `cfg` from rs2[40].  Without
 * this the lane reads whichever buffer the previous dispatch selected.  And it must NEVER be
 * issued while a lane owns the scratchpad: `cfg && !t_busy` (mbxr_engine.v:195) is gated on
 * the TILE SEQUENCER's busy, which a lane dispatch does not set, so a `cfg` during a
 * dispatch re-points that dispatch's reads mid-stream, silently.  Every call site below is
 * between dispatches for that reason. */
static inline int name_abuf(unsigned abuf)
{
	err_clear();
	ll_c2(0, ((uint64_t)(abuf & 1u) << 40));
	return err_set() ? MBXR_E_LANE_R_CFG : MBXR_OK;
}

/* A FENCE IS A READ, NOT A WAIT (funct 6 returns the status word and does not block).  Loop
 * with a budget, so an engine that never finishes is a return code and not a hung board. */
static int fence_wait(uint64_t mask)
{
	for (uint64_t i = 0; i < LL_FENCE_BUDGET; i++)
		if (!(ll_c6(0, 0) & mask))
			return MBXR_OK;
	C.fence_timeouts++;
	return MBXR_E_TIMEOUT;
}

#define U_TAB(i)   MBXR_CFG(MBXR_LANE_LUT, (i) & 0xffu)
#define U_WORD0    MBXR_CFG(MBXR_LANE_LUT, 0x100u)
#define U_WORDS    MBXR_CFG(MBXR_LANE_LUT, 0x101u)
#define U_ERRCLR   MBXR_CFG(MBXR_LANE_LUT, 0x102u)

/* the table under test.  x -> 181x + 71 mod 256 is a BIJECTION (181 is odd), so a dropped,
 * duplicated or transposed byte cannot alias onto a correct answer -- which a table with
 * repeated values would allow.  s6.2's testbench decorrelates value from lane position for
 * the same reason. */
static inline uint8_t tbl_of(uint8_t x) { return (uint8_t)((x * 181u + 71u) & 0xffu); }

static void table_load(void)
{
	for (unsigned i = 0; i < 256; i++)
		mbxr_lane_cfg(U_TAB(i), tbl_of((uint8_t)i));
}

/* the input stream: every byte value occurs in every lane position across a tile */
static inline uint8_t in_of(uint32_t i) { return (uint8_t)((i * 97u + (i >> 8) * 13u) & 0xffu); }

static void stage_input(unsigned tiles)
{
	volatile uint8_t *p = (volatile uint8_t *)IN_PA;
	volatile uint8_t *m = (volatile uint8_t *)M3_SRC;

	for (uint32_t i = 0; i < tiles * TILE_B; i++)
		p[i] = in_of(i);
	/* M3's own window, written once here so its source is defined and, by the time M3 reads
	 * it, long out of hart 1's L1 -- the same condition the engine's placement reads under. */
	for (uint32_t i = 0; i < 5 * TILE_B; i++)
		m[i] = in_of(i * 7u + 3u);
}

/* Byte-check one drained tile against the table applied to its input.  REMOVES s8.5's
 * outcome 3: a `cfg` that re-points the lane mid-stream produces plausible cycle counts over
 * another buffer's data, and no timing fit can see it.  Returns the number of differing
 * bytes and counts what was actually compared, so zero-differ over zero-checked is a
 * distinct reading from zero-differ over 8,192-checked. */
static uint32_t check_tile(uint32_t tile, uint32_t bytes)
{
	const volatile uint8_t *d = (const volatile uint8_t *)(DR_PA + (uint64_t)tile * TILE_B);
	uint32_t bad = 0;

	for (uint32_t i = 0; i < bytes; i++) {
		if (d[i] != tbl_of(in_of(tile * TILE_B + i)))
			bad++;
	}
	C.bytes_checked += bytes;
	C.bytes_differ += bad;
	return bad;
}

/* ONE LUT DISPATCH over data already resident in `abuf`, timed in three phases.
 * Preconditions, each of which is a silent failure or a hang if missed:
 *   - word0 + words <= 1,024, checked here as well as by err[2], so the refusal is a return
 *     code rather than a discovery (s6.1: 0029/002A WRAP silently at this boundary);
 *   - the `st` drain descriptor is armed BEFORE `lgo` and covers ceil(words/8) blocks -- an
 *     armed-and-unfed drain sticks almost_full, sticks out_hold and never returns ownership,
 *     and one of them poisons every later dispatch in the stream (`88af508`);
 *   - err[0] is read back through `lst` between configuring and starting.
 * `arm_drain = 0` is for the deliberate refusals ONLY: a refused dispatch produces no output,
 * so arming a drain for one would BE the 88af508 poison. */
static int dispatch(unsigned word0, unsigned words, uint64_t dst_pa, int arm_drain,
		    uint64_t *t_cfg, uint64_t *t_go, uint64_t *t_poll,
		    uint64_t *polls, uint32_t *st_end)
{
	uint64_t a, b, c, d, np = 0;
	uint32_t s;
	int rc;

	C.attempted++;
	if (word0 + words > WORDS_MAX) {
		C.refused++;
		C.last_rc = MBXR_E_LANE_SPAN;
		return MBXR_E_LANE_SPAN;
	}
	/* THE DRAIN IS ARMED LAST, AND THAT ORDER IS NOT COSMETIC.  "st before lgo" is the
	 * precondition, but "st before a refusal" is the 88af508 poison: an armed drain that
	 * never gets its blocks sticks s_busy and every later dispatch in the stream spins out.
	 * So every condition mbxr_lane_go will check is checked HERE first, with nothing else
	 * on this hart able to change the lane in between, and the descriptor is issued only
	 * once the go cannot be refused.  If it is refused anyway, that is reported as POISONED
	 * rather than left to show up as a hang three stages later. */
	s = mbxr_lane_status();
	if (!MBXR_L_IDLE_NOW(s)) {
		*t_cfg = 0; *t_go = 0; *t_poll = 0; *polls = 0; *st_end = s;
		C.refused++; C.last_rc = MBXR_E_LANE_BUSY; C.last_uerr = MBXR_L_UERR(s);
		return MBXR_E_LANE_BUSY;
	}
	err_clear();

	a = cyc();
	mbxr_lane_cfg(U_WORD0, word0);
	mbxr_lane_cfg(U_WORDS, words);
	b = cyc();
	rc = mbxr_lane_arm(MBXR_GO_LUT);          /* err[0] back through lst, before go */
	if (rc == MBXR_OK) {
		if (arm_drain)
			ll_c5(dst_pa, ST_RS2_FLAT((words + 7u) / 8u));
		if (arm_drain && err_set())
			rc = MBXR_E_LANE_R_ST;          /* the drain descriptor was refused */
		if (rc == MBXR_OK) {
			rc = mbxr_lane_go(MBXR_GO_LUT, 1);
			if (rc != MBXR_OK && arm_drain)
				printk("LL_POISON lgo refused with the drain already armed: rc=%d\n",
				       rc);
			if (rc == MBXR_OK && err_set())
				rc = MBXR_E_LANE_R_GO;      /* lane_go_bad: busy, or a bad selector */
		}
	}
	c = cyc();
	if (rc != MBXR_OK) {
		*t_cfg = b - a; *t_go = c - b; *t_poll = 0; *polls = 0;
		s = mbxr_lane_status();
		*st_end = s;
		C.refused++; C.last_rc = rc; C.last_uerr = MBXR_L_UERR(s);
		return rc;
	}
	rc = mbxr_lane_wait_for(MBXR_GO_LUT, LL_POLL_BUDGET, &np, &s);
	d = cyc();
	*t_cfg = b - a; *t_go = c - b; *t_poll = d - c; *polls = np; *st_end = s;
	C.last_rc = rc; C.last_uerr = MBXR_L_UERR(s);
	if (rc == MBXR_OK)
		C.ok++;
	else
		C.refused++;
	return rc;
}

static const char *rcname(int rc)
{
	switch (rc) {
	case MBXR_OK:           return "OK";
	case MBXR_E_LANE_CFG:   return "CFG";
	case MBXR_E_LANE_BUSY:  return "BUSY";
	case MBXR_E_LANE_HANG:  return "HANG";
	case MBXR_E_LANE_ERR:   return "LANE_ERR";
	case MBXR_E_LANE_SPAN:  return "SPAN(sw)";
	case MBXR_E_TIMEOUT:    return "FENCE_TO";
	case MBXR_E_LANE_R_ACTLD: return "R_ACTLD";
	case MBXR_E_LANE_R_CFG: return "R_CFG";
	case MBXR_E_LANE_R_ST:  return "R_ST";
	case MBXR_E_LANE_R_GO:  return "R_GO";
	}
	return "?";
}

/* ============================================================================================
 * hart 1
 * ============================================================================================ */
#define STK 8192
K_THREAD_STACK_DEFINE(h1_stack, STK);
static struct k_thread h1_thread;
static struct k_sem h1_go;
static atomic_t h1_done;

static void lane_body(void);
static int stage_m1(void);

static void h1_entry(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	k_sem_take(&h1_go, K_FOREVER);
	printk("LL_HART hart=%lu\n", (unsigned long)csr_read(mhartid));
	lane_body();
	atomic_set(&h1_done, 1);
	for (;;)
		k_sleep(K_FOREVER);
}

int main(void)
{
	k_tid_t h1;

	printk("LL_START tile_bytes=%d ntiles=%d\n", TILE_B, NTILES);
	k_sem_init(&h1_go, 0, 1);
	atomic_set(&h1_done, 0);
	h1 = k_thread_create(&h1_thread, h1_stack, STK, h1_entry, NULL, NULL, NULL, 5, 0, K_FOREVER);
	k_thread_cpu_pin(h1, 1);
	k_thread_start(h1);
	k_sem_give(&h1_go);
	while (!atomic_get(&h1_done))
		k_busy_wait(1000);
	printk("LL_DONE\n");
	return 0;
}

/* ---- 0. the lane from reset ---------------------------------------------------------------- */
static void stage_reset(void)
{
	uint32_t s = mbxr_lane_status();

	/* s8.2 finding 2: the attention unit reads a_err = 0x9 from reset and makes a healthy
	 * dispatch look like an error to a poll loop that reads the whole word.  THIS lane
	 * resets e_cfg/e_busy/e_range all to 0, so u_err must read 0x0 here -- and if it does
	 * not, every later rc in this run is suspect. */
	printk("LL_RESET status=0x%08x own=%u u_err=0x%x u_idle=%u a_err=0x%x l_err=0x%02x\n",
	       s, MBXR_L_OWN(s), MBXR_L_UERR(s), MBXR_L_LUT_IDLE(s),
	       MBXR_L_AERR(s), MBXR_L_LERR(s));
}

/* ---- 1. the three refusals, which must be return codes and not hangs ------------------------
 * s8.2 finding 1: this lane's refusals happen AT `start`, in the same cycle, and `run` is
 * never set -- so ownership comes back after the 15-cycle guard with nothing read and nothing
 * drained.  That is what makes it safe to put these FIRST.  Each one is followed by a clear
 * through local 0x102 and a read-back, because a sticky err[] would refuse every later
 * dispatch and look like a broken lane. */
static void stage_refusals(void)
{
	static const struct { unsigned w0, n; const char *want; const char *what; } t[] = {
		{ 0,    0,    "err0", "zero length: would return ownership with the drain never written" },
		{ 0,    1025, "err2", "one word past the buffer: 0029/002A WRAP here silently" },
		{ 1017, 8,    "err2", "the last word crosses the end, checked AT the limit not at half of it" },
	};

	for (unsigned i = 0; i < ARRAY_SIZE(t); i++) {
		uint32_t s;

		C.attempted++;
		mbxr_lane_cfg(U_WORD0, t[i].w0);
		mbxr_lane_cfg(U_WORDS, t[i].n);
		s = mbxr_lane_status();
		/* NO DRAIN IS ARMED, deliberately: a refused dispatch produces no output, so an
		 * armed drain here would be exactly 88af508's armed-and-unfed poison.  That is
		 * why mbxr_lane_go's drain_ready guard is bypassed for these three only. */
		if (MBXR_L_IDLE_NOW(s))
			mbxr_l_go(MBXR_GO_LUT, 0);
		{
			uint64_t n = 0;
			for (; n < LL_POLL_BUDGET; n++) {
				s = mbxr_lane_status();
				if (MBXR_L_IDLE_NOW(s))
					break;
			}
			C.refused++;
			C.last_uerr = MBXR_L_UERR(s);
			printk("LL_REFUSE w0=%-5u n=%-5u u_err=0x%x want=%s polls=%llu own=%u  %s\n",
			       t[i].w0, t[i].n, MBXR_L_UERR(s), t[i].want,
			       (unsigned long long)n, MBXR_L_OWN(s), t[i].what);
		}
		mbxr_lane_cfg(U_ERRCLR, 1);
		s = mbxr_lane_status();
		printk("LL_CLEAR u_err=0x%x (must be 0x0, or every later rc in this run is suspect)\n",
		       MBXR_L_UERR(s));
	}
}

/* the fourth refusal: a config write while the lane is running.  One of the five lane
 * operations that can be refused or misdirected with no counter and no console line.  It
 * needs a RUNNING dispatch to land in, so it goes after the table and the fill. *//* THE FOURTH REFUSAL -- a config write while the lane is running -- IS DELIBERATELY NOT HERE.
 * Arm A ran it, and it armed a 128-block drain before discovering the lane was already stuck:
 * 88af508's armed-and-unfed poison, created by the very test meant to find a silent refusal.
 * err[1] is covered where it costs nothing -- lut_lane/run_tb.sh step 5 and mutants.sh's
 * `cfg-while-busy-allowed`, both in Verilator.  A board arm is the wrong place to spend a
 * hazard a simulator can hold safely. */

/* ---- M1: the slope, over RESIDENT data, AS A SWEEP THAT STOPS AT THE FIRST HANG -------------
 * s8.4: the naive two-point fit over tiled dispatches measures max(compute, fill), and 1/8 per
 * element cannot appear even if the lane is perfect.  The fix is not a workaround, it is the
 * more correct experiment -- one `ld`, then several `lgo` over the same resident words with no
 * refill between them.  The lane is a pure map with no state that carries, so the second
 * dispatch is the lane in isolation from the memory system.  M1 is also immune to s8.5's
 * buffer collision: it issues no second load.
 *
 * WHY IT IS A SWEEP AND WHY IT STOPS.  Arm A's first dispatch was 256 words and it hung, and a
 * hung lane never returns ownership, so EVERY LATER DISPATCH IN THE IMAGE READ BUSY -- one
 * fault reported as twenty-seven.  Verilator on the merged engine puts the boundary between 48
 * and 64 words on the unfixed lane (lut_lane/tb_lutint.cpp), so this climbs from 8 and stops
 * the moment ownership does not come back.  WHERE it stops is then the measurement: on the
 * fixed lane it reaches 1,024 and M2 runs after it; on the unfixed one it names the size, on
 * silicon rather than only in simulation.
 *
 * Returns the largest word count that completed byte-clean. */
static int stage_m1(void)
{
	static const unsigned sizes[] = { 8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512,
					  768, 1024 };
	uint64_t tc, tg, tp, np;
	uint32_t s;
	int rc, max_ok = 0;

	if (fill_start(IN_PA, TILE_B / 64, 0) != MBXR_OK) {
		printk("LL_M1 the activation load was REFUSED (rc %d)\n", MBXR_E_LANE_R_ACTLD);
		return 0;
	}
	if (fence_wait(MBXR_S_BUSY) != MBXR_OK) {
		printk("LL_M1 FENCE_TIMEOUT on the one fill\n");
		return 0;
	}
	if (name_abuf(0) != MBXR_OK)
		printk("LL_M1 the cfg naming abuf was REFUSED (rc %d)\n", MBXR_E_LANE_R_CFG);

	for (unsigned pass = 0; pass < 2; pass++) {
		for (unsigned i = 0; i < ARRAY_SIZE(sizes); i++) {
			unsigned w = sizes[i];
			uint32_t bad = 0xffffffffu;

			rc = dispatch(0, w, DR_PA, 1, &tc, &tg, &tp, &np, &s);
			if (rc == MBXR_OK && fence_wait(MBXR_S_BUSY) == MBXR_OK)
				bad = check_tile(0, w * 8);
			printk("LL_M1 words=%-5u els=%-6u rc=%d %-9s cfg=%llu go=%llu poll=%llu "
			       "polls=%llu total=%llu u_err=0x%x differ=%u\n",
			       w, w * 8, rc, rcname(rc), (unsigned long long)tc,
			       (unsigned long long)tg, (unsigned long long)tp,
			       (unsigned long long)np,
			       (unsigned long long)(tc + tg + tp), MBXR_L_UERR(s), bad);
			if (rc != MBXR_OK) {
				printk("LL_STOP ownership did not come back at %u words (%u "
				       "elements): every later dispatch would read BUSY, so the "
				       "sweep stops here\n", w, w * 8);
				return max_ok;
			}
			if (bad != 0 && bad != 0xffffffffu)
				printk("LL_DIFFER %u of %u bytes differ at %u words WITH rc=0 AND "
				       "u_err=0x0 -- a clean return over wrong data\n",
				       bad, w * 8, w);
			if (bad == 0 && (int)w > max_ok)
				max_ok = (int)w;
		}
	}
	return max_ok;
}

static void stage_m2_seq(void)
{
	for (unsigned i = 0; i < NTILES; i++) {
		uint64_t t0, t1, tc, tg, tp, np;
		uint32_t s, bad = 0xffffffffu;
		unsigned b = i & 1u;
		int rc;

		t0 = cyc();
		rc = fill_start(IN_PA + (uint64_t)i * TILE_B, TILE_B / 64, b);
		if (rc != MBXR_OK) {
			printk("LL_M2SEQ tile=%u the activation load was REFUSED rc=%d\n", i, rc);
			return;
		}
		if (fence_wait(MBXR_S_BUSY) != MBXR_OK) {
			printk("LL_M2SEQ tile=%u FENCE_TIMEOUT on the fill\n", i);
			return;
		}
		rc = name_abuf(b);
		if (rc != MBXR_OK)
			printk("LL_M2SEQ tile=%u the cfg naming abuf was REFUSED rc=%d\n", i, rc);
		rc = dispatch(0, WORDS_MAX, DR_PA + (uint64_t)i * TILE_B, 1,
			      &tc, &tg, &tp, &np, &s);
		if (rc == MBXR_OK && fence_wait(MBXR_S_BUSY) != MBXR_OK)
			rc = MBXR_E_TIMEOUT;
		t1 = cyc();
		if (rc == MBXR_OK)
			bad = check_tile(i, TILE_B);
		printk("LL_M2SEQ tile=%-2u buf=%u rc=%d %-9s tile_cycles=%llu cfg=%llu go=%llu "
		       "poll=%llu polls=%llu u_err=0x%x differ=%u\n",
		       i, b, rc, rcname(rc), (unsigned long long)(t1 - t0),
		       (unsigned long long)tc, (unsigned long long)tg, (unsigned long long)tp,
		       (unsigned long long)np, MBXR_L_UERR(s), bad);
	}
}

/* ---- M2-pipe: the test ----------------------------------------------------------------------
 * Tile N+1's fill is issued into `!abuf` BEFORE tile N's `lgo`, so the two overlap if the
 * engine permits it.  `ld_ok = ld && !l_busy && !ld_mode_bad && !ld_buf_bad` consults only
 * the two load DMAs -- nothing consults the lanes' `own` -- so a load issued while a lane
 * runs is accepted.  It is also accepted INTO THE BUFFER THE LANE IS READING, silently:
 * `ld_buf_bad` is gated on `t_busy`, mbxr_tseq's busy, which a lane dispatch does not set.
 * Hence the buffer alternation, stated here as a precondition rather than discovered as a
 * corruption -- and the byte check below is what proves it held.
 *
 * The waits are deliberately NOT the same mask at both ends: the top waits only for FILL (the
 * data this tile reads must have landed) and the bottom only for DRAIN (this tile's output
 * must have landed) -- a wait on MBXR_S_BUSY at the bottom would wait for the next tile's
 * fill and un-pipeline the loop, which is the harness bug s8.5 point 2 describes. */
static void stage_m2_pipe(void)
{
	uint64_t total = 0;
	unsigned done = 0;

	if (fill_start(IN_PA, TILE_B / 64, 0) != MBXR_OK) {
		printk("LL_M2PIPE the prologue load was REFUSED\n");
		return;
	}

	for (unsigned i = 0; i < NTILES; i++) {
		uint64_t t0, t1, tc, tg, tp, np;
		uint32_t s, bad = 0xffffffffu;
		unsigned b = i & 1u;
		int rc;

		t0 = cyc();
		if (fence_wait(MBXR_S_FILL) != MBXR_OK) {
			printk("LL_M2PIPE tile=%u FENCE_TIMEOUT waiting for its fill\n", i);
			return;
		}
		if (i + 1 < NTILES &&
		    fill_start(IN_PA + (uint64_t)(i + 1) * TILE_B, TILE_B / 64, b ^ 1u) != MBXR_OK)
			printk("LL_M2PIPE tile=%u the PREFETCH load was REFUSED -- ld_ok needs !l_busy, so this is the overlap being denied\n", i + 1);
		if (name_abuf(b) != MBXR_OK)
			printk("LL_M2PIPE tile=%u the cfg naming abuf was REFUSED\n", i);
		rc = dispatch(0, WORDS_MAX, DR_PA + (uint64_t)(NTILES + i) * TILE_B, 1,
			      &tc, &tg, &tp, &np, &s);
		if (rc == MBXR_OK && fence_wait(MBXR_S_DRAIN) != MBXR_OK)
			rc = MBXR_E_TIMEOUT;
		t1 = cyc();
		if (rc == MBXR_OK) {
			/* the drained tile is at DR_PA + (NTILES+i)*TILE_B but its INPUT was
			 * tile i, so the check must name the input tile.  Inline rather than
			 * through check_tile() for that reason. */
			const volatile uint8_t *d =
				(const volatile uint8_t *)(DR_PA + (uint64_t)(NTILES + i) * TILE_B);
			uint32_t n = 0;
			for (uint32_t k = 0; k < TILE_B; k++)
				if (d[k] != tbl_of(in_of(i * TILE_B + k)))
					n++;
			C.bytes_checked += TILE_B;
			C.bytes_differ += n;
			bad = n;
			total += t1 - t0;
			done++;
		}
		printk("LL_M2PIPE tile=%-2u buf=%u rc=%d %-9s tile_cycles=%llu cfg=%llu go=%llu "
		       "poll=%llu polls=%llu u_err=0x%x differ=%u\n",
		       i, b, rc, rcname(rc), (unsigned long long)(t1 - t0),
		       (unsigned long long)tc, (unsigned long long)tg, (unsigned long long)tp,
		       (unsigned long long)np, MBXR_L_UERR(s), bad);
	}
	(void)fence_wait(MBXR_S_BUSY);
	if (done)
		printk("LL_M2PIPE_MEAN tiles=%u mean_tile_cycles=%llu\n", done,
		       (unsigned long long)(total / done));
}

/* ---- M3: the placement rate ------------------------------------------------------------------
 * s10.1's sensitivity table: the 8x is worth 0.012 of RTF_e2e and this is worth 0.38.
 * ENGINE_WAIT_ANATOMY.md s2 measures the engine's own placement at 14.9 cycles per output
 * byte (encoder) and 15.5 (decoder) for the byte-at-a-time scalar loop in mbxr.c:117/:361.
 * If a LUT-lane driver must pay that, two thirds of the encoder lever is gone; if a 64-bit
 * copy removes it, the right driver drains 64-byte-aligned tiles straight into the
 * destination tensor and pays nothing.  Three loops, no extra board time.
 *
 * The source of every variant is a window the ENGINE just wrote, which is the real case: the
 * bytes are in DRAM and the L2, not in hart 1's L1.
 *
 * AND THE SOURCE IS NOW IN ITS OWN 8 MB WINDOW so a near destination two tiles away
 * cannot alias it in the L1D.  Arm A put src and dst 8 MB apart, which maps every
 * offset to the same set, and measured a per-ACCESS cost it read as a per-byte one. */
static void m3_bytes(uint64_t src, uint64_t dst, uint32_t n, const char *tag, const char *why)
{
	const int8_t *s = (const int8_t *)src;
	int8_t *d = (int8_t *)dst;
	uint64_t t0 = cyc();

	for (uint32_t i = 0; i < n; i++)
		d[i] = s[i];
	{
		uint64_t t = cyc() - t0;
		printk("LL_M3 %-10s bytes=%u cycles=%llu  %s\n", tag, n,
		       (unsigned long long)t, why);
	}
}

static void m3_vbytes(uint64_t src, uint64_t dst, uint32_t n, const char *tag, const char *why)
{
	const volatile int8_t *s = (const volatile int8_t *)src;
	volatile int8_t *d = (volatile int8_t *)dst;
	uint64_t t0 = cyc();

	for (uint32_t i = 0; i < n; i++)
		d[i] = s[i];
	{
		uint64_t t = cyc() - t0;
		printk("LL_M3 %-10s bytes=%u cycles=%llu  %s\n", tag, n,
		       (unsigned long long)t, why);
	}
}

static void m3_words(uint64_t src, uint64_t dst, uint32_t n, const char *tag, const char *why)
{
	const volatile uint64_t *s = (const volatile uint64_t *)src;
	volatile uint64_t *d = (volatile uint64_t *)dst;
	uint64_t t0 = cyc();

	for (uint32_t i = 0; i < n / 8; i++)
		d[i] = s[i];
	{
		uint64_t t = cyc() - t0;
		printk("LL_M3 %-10s bytes=%u cycles=%llu  %s\n", tag, n,
		       (unsigned long long)t, why);
	}
}
static void stage_m3(void)
{
	/* ARM A MEASURED 60.5 CYCLES/BYTE HERE AND THE ENGINE'S OWN RECORD SAYS 14.9, AND THE
	 * DIFFERENCE WAS MY ADDRESSES.  DR_PA and OUT_PA are 8 MB apart, so at every offset they
	 * land in the SAME L1D set: each load evicts the line the store just filled, and back
	 * again -- one miss per access.  The tell was that the 64-bit loop came out 7.65x cheaper
	 * than the byte loop, almost exactly 8, so the cost was per ACCESS and not per byte, which
	 * is what thrashing looks like and what a loop-bound copy does not.
	 *
	 * So both are measured now.  `near` puts the destination two tiles after the source, so
	 * the two occupy disjoint sets; `far` reproduces arm A at 8 MB.  THE PAIR IS THE
	 * MEASUREMENT -- either alone is a number with a hidden variable in it, which is exactly
	 * what arm A published to itself. */
	m3_bytes(M3_SRC, M3_SRC + 2 * TILE_B, TILE_B, "a_byte_near",
		 "mbxr.c:361's loop shape; dst 16 KB after src, disjoint L1D sets");
	m3_words(M3_SRC, M3_SRC + 3 * TILE_B, TILE_B, "b_word_near",
		 "eight times fewer iterations over the same bytes, same disjoint sets");
	m3_vbytes(M3_SRC, M3_SRC + 4 * TILE_B, TILE_B, "d_vbyte_near",
		  "volatile: if a matches b, the compiler widened a and mbxr.c's 14.9 is not this");
	m3_bytes(M3_SRC, OUT_PA, TILE_B, "a_byte_far",
		 "THE SAME COPY 8 MB away: arm A's number, and the set collision behind it");
	m3_words(M3_SRC, OUT_PA + TILE_B, TILE_B, "b_word_far",
		 "and the 64-bit loop at the same distance, for the ratio");
	m3_bytes(M3_SRC, M3_SRC + 2 * TILE_B, TILE_B, "c_byte_warm",
		 "a_byte_near repeated: the source is warm now, separating the loop from the misses");
}

static void lane_body(void)
{
	int max_ok;

	stage_reset();
	stage_refusals();

	printk("LL_STAGE staging %d bytes of input\n", NTILES * TILE_B);
	stage_input(NTILES);

	/* M3 NEEDS NO LANE AND RUNS FIRST, because a hung lane cannot poison it and arm A proved
	 * the lane can hang.  s10.1's sensitivity table makes this the measurement worth 0.38 of
	 * RTF_e2e against the 8x's 0.012, so it must not be the one that gets skipped. */
	stage_m3();

	{
		uint64_t t0 = cyc();
		uint64_t t;

		table_load();
		t = cyc() - t0;
		printk("LL_TABLE entries=256 cycles=%llu per_lcfg=%llu -- the table changes once "
		       "per LAYER, not per dispatch\n",
		       (unsigned long long)t, (unsigned long long)(t / 256));
	}

	max_ok = stage_m1();
	printk("LL_SWEEP max_clean_words=%d max_clean_elements=%d\n", max_ok, max_ok * 8);

	if (max_ok >= WORDS_MAX) {
		stage_m2_seq();
		stage_m2_pipe();
	} else {
		/* NOT A SILENT SKIP.  A missing M2 must be a stated refusal with its reason, or the
		 * record reads as a run that chose not to measure. */
		printk("LL_SKIP M2 not run: the lane completed only %d of %d words cleanly, so a "
		       "full-tile dispatch would hang and every number after it would be a "
		       "measurement of a stuck lane\n", max_ok, WORDS_MAX);
	}

	/* THE COUNTERS, LAST AND ALWAYS PRINTED.  lut_ok = 0 is a FAIL whatever bytes_differ
	 * reads, and bytes_checked = 0 makes a zero that means "nothing was compared" a distinct
	 * value from a zero that means "matched" (438eb27). */
	printk("LL_COUNT attempted=%u ok=%u refused=%u last_rc=%d last_uerr=0x%x "
	       "bytes_checked=%u bytes_differ=%u fence_timeouts=%u\n",
	       C.attempted, C.ok, C.refused, C.last_rc, C.last_uerr,
	       C.bytes_checked, C.bytes_differ, C.fence_timeouts);
	printk("LL_ENGINE status=0x%016llx\n", (unsigned long long)ll_c6(0, 0));
}
