/* SPDX-License-Identifier: Apache-2.0
 *
 * mbxr_lanes.h -- the software side of the lane dispatch interface (custom-1 functs 9, 10, 11).
 *
 * THIS IS THE LANES' INTERFACE, NOT LAYERNORM'S.  The attention unit, the normalisation lane and
 * T4's LUT/add/rotary lanes all reach the engine through the same three instructions and the same
 * {lane[2:0], local[12:0]} configuration space.  LayerNorm is merely the first caller, because its
 * IR mapping is 1:1 (13 ops, 13 dispatch_ids) and it needs no fused op -- see ROCC_DECOUPLED.md
 * s8.15.21.  Anything specific to one lane lives below a clearly marked heading.
 *
 * THE INSTRUCTIONS (mbxr_engine.v, merge revision, funct 9/10/11):
 *   lcfg  funct 9   rs1[15:0] = cfg_addr, rs2[31:0] = data.  No reply.  Legal while idle;
 *                   a write while that lane is busy sets its err[1] and is otherwise ignored.
 *   lgo   funct 10  rs1[1:0]: 1 = attention unit, 2 = normalisation lane.  REFUSED, and sets the
 *                   engine's err_sticky, if the engine or either lane is busy (`lane_go_ok =
 *                   lgc && !ln_busy && !t_busy`).  Starting is the caller's responsibility.
 *   lst   funct 11  replies with the 32-bit lane status.  No side effects.
 *
 * THE STATUS WORD (mbxr_lanes.v: {own, ln_drained, l_idle, a_idle, a_busy, l_err, a_err, r_left}):
 *   [31:30] own (0 engine, 1 attention, 2 normalisation)   [29] ln_drained   [28] l_idle
 *   [27] a_idle   [26] a_busy   [25:20] l_err   [19:16] a_err   [15:0] r_left
 *
 * FOUR PRECONDITIONS, AND THREE OF THEM ARE SILENT OR HANG.  They are checked here as return
 * codes before anything is issued, because the failure shapes are not survivable at the call site:
 *
 *   1. M*K MUST BE A WHOLE NUMBER OF SCRATCHPAD WORDS.  The streamer feeds 8 elements per 64-bit
 *      word (4 when in16), stops when its word count reaches zero, and returns ownership only
 *      when `ln_drained && l_idle`.  A leftover part-word feeds elements the lane is not
 *      expecting, `in_last` disagrees with K, and the lane can sit waiting for the rest of a row
 *      that will never arrive -- OWNERSHIP IS NEVER RETURNED.  That is a hang, not a fault, and
 *      no timeout inside the engine will end it.  MBXR_E_LANE_WORDS.
 *   2. THE INPUT IS A CONTIGUOUS ELEMENT STREAM ACROSS ROW BOUNDARIES; THE OUTPUT IS WORD-ALIGNED
 *      PER ROW.  The reader does not resynchronise at a row edge and the packer does: K must
 *      therefore be a whole number of OUTPUT elements per word, or rows land misaligned in the
 *      drain with no error raised anywhere.  The lane's own author got this asymmetry the wrong
 *      way round in the first harness, which is a direct warning about this call site.
 *      MBXR_E_LANE_KALIGN.
 *   3. THE DRAIN DESCRIPTOR MUST BE ISSUED BEFORE THE LANE STARTS.  The lane drives the engine's
 *      mbxr_st; with no descriptor waiting, output has nowhere to go.  Enforced by ordering in
 *      mbxr_ln_run() and asserted by mbxr_lane_go()'s `drain_ready` argument.
 *   4. THE CONFIGURATION MUST BE USABLE BEFORE lgo -- AND "WRITE K" IS NOT ENOUGH.  Measured,
 *      Lab B33: a dispatch configured with K, HW and flags but eps_q = 0 took ownership, read two
 *      words, and NEVER RETURNED IT.  mbxr_ln.v's condition is the whole of
 *          cfg_ok = c_kok & k_fits & (c_hw != 0) & (c_eps > 64'd262144) & ~c_eps[63]
 *      so a zero or too-small EPSILON is "config unusable" exactly as a missing K is, and the
 *      failure shape is the hang, not an error.  Checked twice here: the values are validated in
 *      software (MBXR_E_LANE_CFG), and mbxr_lane_arm() READS err[0] BACK through lst after
 *      configuring and refuses to start if it is still set.  That second check is the general
 *      rule for every lane -- both of them report "config unusable" from reset, so read the
 *      status between config and go rather than trusting the writes.
 *
 *   5. THE WORD RANGE MUST FIT ONE BUFFER -- A FIFTH PRECONDITION, AND IT IS SILENT.  Not in
 *      anyone's list, found by reading the RTL while writing this header.  The streamer drives
 *      `rd_addr[0] = {5'd0, abuf, r_word[AW-1:0]}` with AW = 10, so word0 + words > 1024
 *      TRUNCATES: the reader wraps to the start of the buffer and re-reads it, and the lane
 *      produces a confident wrong answer with no error bit anywhere.  The engine's own activation
 *      mapper checks the same condition and raises `pa_bad` (mbxr_engine.v: `pa_bad =
 *      (la_word >> AW) != 0`); the lane's streamer does not.  Checked here as
 *      MBXR_E_LANE_SPAN, which is why mbxr_ln_plan() exists: a 165 x 288 layernorm is 5,940
 *      words and must be issued as SIX dispatches of whole rows, not one.
 *
 * OVERLAPPING A FILL WITH A LANE DISPATCH: POSSIBLE, NOT AUTOMATIC, AND NOT GUARDED.  Three
 * separate facts, from mbxr_engine.v's own refusal logic, because a kernel author will meet all
 * three at once:
 *   * POSSIBLE.  `ld_ok = ld && !l_busy && !ld_mode_bad && !ld_buf_bad` consults the two load
 *     DMAs and the TILE SEQUENCER -- never the lanes' `own`.  So a load issued while a lane runs
 *     is accepted, and a driver CAN prefetch the next tile under the current dispatch.
 *   * NOT AUTOMATIC.  Nothing prefetches on the driver's behalf.  Overlap exists only if the
 *     caller issues the next `ld` BEFORE waiting on the current `lgo`; a loop that reads
 *     ld -> lgo -> wait measures fill and compute SERIALISED no matter what the hardware allows.
 *   * NOT GUARDED, AND THIS ONE CORRUPTS SILENTLY.  `ld_buf_bad = ld && t_busy && (buffer ==
 *     the tile's)` is gated on `t_busy`, and a lane dispatch does not set it.  So a load into the
 *     very buffer the lane is reading is ACCEPTED.  The lane reads buffer `t_abuf`
 *     (mbxr_lanes.v: `rd_addr[0] = {5'd0, abuf, r_word[AW-1:0]}`), so the rule is: while a lane
 *     runs on `t_abuf`, a prefetch must target `!t_abuf`, and `t_abuf` flips between dispatches.
 *     Nothing in hardware enforces it and no error bit reports it.
 *
 *   * AND cfg RE-POINTS A RUNNING LANE MID-STREAM (found by the T4 workstream, checking the
 *     above).  `t_abuf` is written by `cfg && !t_busy` (mbxr_engine.v :195) and reaches the lanes
 *     as a LIVE WIRE used directly in `rd_addr[0]` (mbxr_lanes.v :274).  A lane dispatch does not
 *     set `t_busy`, so a `cfg` issued while a lane owns the scratchpad moves its reads to the
 *     other buffer partway through, silently.  ORDERING RULE: `cfg` only AFTER the previous
 *     dispatch has returned ownership; the `ld` may go earlier, to the other buffer.  A harness
 *     that pipelines tiles meets this one by construction, because flipping buffers IS a `cfg`.
 *
 * ONE PATH OWNS THE SCRATCHPAD, THE MAC AND THE DRAIN AT A TIME (LAYERNORM_LANE.md s6.3), so a
 * lane dispatch is not concurrent with an engine dispatch and must not be issued inside one.
 * `lgo` is also refused while the ENGINE is busy (`!t_busy`), which the lane status word does not
 * report; mbxr_lane_go() can only check the lanes, so the caller must not be inside an engine
 * dispatch.  The existing driver is synchronous, so this holds by construction today.
 */
#ifndef MBXR_LANES_H
#define MBXR_LANES_H

#include <stdint.h>
#include "mbxr.h"

/* ---- the three instructions ---------------------------------------------------------------
 * Same shape as mbxr_rt.h's stubs: funct3 011 sends, 111 also replies into a0.
 */
#if defined(__riscv)
__asm__(".pushsection .text.mbxr_lanes, \"ax\", @progbits\n"
	".balign 4\n"
	"mbxr_l_cfg: .insn r 0x2B, 3, 9,  x0, a0, a1\n ret\n"
	"mbxr_l_go:  .insn r 0x2B, 3, 10, x0, a0, a1\n ret\n"
	"mbxr_l_st:  .insn r 0x2B, 7, 11, a0, a0, a1\n ret\n"
	".popsection\n");
extern void     mbxr_l_cfg(uint64_t addr, uint64_t data) __asm__("mbxr_l_cfg");
extern void     mbxr_l_go(uint64_t which, uint64_t unused) __asm__("mbxr_l_go");
extern uint64_t mbxr_l_st(uint64_t a, uint64_t b) __asm__("mbxr_l_st");
#else
/* ON THE HOST the three instructions do not exist, and that is deliberate rather than a
 * limitation: the shape checks, the address encodings and the kernel that calls them all have to
 * be provable off the board (the verification bar for the first lane dispatch is bit-exactness on
 * the host BEFORE any board time).  A host test provides these three symbols and thereby models
 * the lane; everything else in this header compiles and runs unchanged. */
void     mbxr_l_cfg(uint64_t addr, uint64_t data);
void     mbxr_l_go(uint64_t which, uint64_t unused);
uint64_t mbxr_l_st(uint64_t a, uint64_t b);
#endif

/* ---- the configuration space: {lane[2:0], local[12:0]} ------------------------------------- */
#define MBXR_LANE_ATTN    0u    /* mbxa_core's unit registers                                   */
#define MBXR_LANE_SMX     1u    /* mbxr_smx inside mbxa_core                                    */
#define MBXR_LANE_LN      2u    /* mbxr_ln                                                      */
#define MBXR_LANE_STREAM  3u    /* the LN streamer in mbxr_lanes.v                              */
#define MBXR_LANE_LUT     4u    /* mbxl_lut, T4's LUT lane (lut_lane/mbxl_lut.v)                */
/* lanes 4..7 are free: s8.14's T4 wants LUT, add and rotary lanes there                        */
#define MBXR_CFG(lane, local)  ((uint64_t)(((lane) << 13) | ((local) & 0x1fffu)))

/* what lgo's rs1 selects */
#define MBXR_GO_ATTN   1u
#define MBXR_GO_LN     2u
#define MBXR_GO_LUT    3u

/* ---- the status word -----------------------------------------------------------------------
 * THE COUPLING FLAGGED HERE HAS LANDED (merge `86b89cd`).  `r_left` is 11 bits, and bits
 * [15:11] carry the LUT lane's err and idle.  Nothing existing moved: own, ln_drained, l_idle,
 * a_idle, a_busy, l_err and a_err keep the exact positions they had, so every accessor below
 * except MBXR_L_LEFT_BITS is unchanged from before the patch.
 *
 * WHY THE WIDTH IS A NAMED CONSTANT.  11 bits is exact only BECAUSE `go_bad` refuses
 * `word0 + words > 2**AW`.  The RTL side of that coupling now fails loudly -- mbxr_lanes.v
 * writes `r_left[AW:0]` with an elaboration check that AW == 10.  THIS side would not: a wider
 * mask on a narrower field just reads the LUT lane's err as a huge `r_left`, silently.  So if
 * AW ever changes, this constant changes with it.
 *
 *   [31:30] own    [29] ln_drained  [28] l_idle  [27] a_idle  [26] a_busy
 *   [25:20] l_err  [19:16] a_err    [15:13] u_err  [12] u_idle  [11] reserved  [10:0] r_left
 */
#ifndef MBXR_L_LEFT_BITS
#define MBXR_L_LEFT_BITS    11
#endif
#define MBXR_L_LEFT_MASK    ((1u << MBXR_L_LEFT_BITS) - 1u)
#define MBXR_L_OWN(s)       (((s) >> 30) & 3u)
#define MBXR_L_DRAINED(s)   (((s) >> 29) & 1u)
#define MBXR_L_LN_IDLE(s)   (((s) >> 28) & 1u)
#define MBXR_L_A_IDLE(s)    (((s) >> 27) & 1u)
#define MBXR_L_A_BUSY(s)    (((s) >> 26) & 1u)
#define MBXR_L_LERR(s)      (((s) >> 20) & 0x3fu)
#define MBXR_L_AERR(s)      (((s) >> 16) & 0xfu)
#define MBXR_L_LEFT(s)      ((s) & MBXR_L_LEFT_MASK)
/* the LUT lane (mbxl_lut): err bit 0 config unusable (zero length), 1 written while busy,
 * 2 word range past the buffer.  All three are refused AT `start` -- the lane never sets `run`,
 * so a refused LUT dispatch returns ownership after the 15-cycle guard rather than hanging.
 * u_err reads 0 from reset, so unlike a_err it contributes no false positive to a poll loop
 * that reads the whole word. */
#define MBXR_L_UERR(s)      (((s) >> 13) & 7u)
#define MBXR_L_LUT_IDLE(s)  (((s) >> 12) & 1u)
/* a lane dispatch is finished when ownership is back with the engine */
#define MBXR_L_IDLE_NOW(s)  (MBXR_L_OWN(s) == 0u)

/* ---- error codes, continuing mbxr.h's ------------------------------------------------------- */
#define MBXR_E_LANE_WORDS   (-64)   /* M*K is not a whole number of scratchpad words (WOULD HANG) */
#define MBXR_E_LANE_KALIGN  (-65)   /* K is not a whole number of output elements per word        */
#define MBXR_E_LANE_CFG     (-66)   /* configuration incomplete: the lane reports err[0]          */
#define MBXR_E_LANE_BUSY    (-67)   /* the engine or a lane was busy: lgo would be refused        */
#define MBXR_E_LANE_HANG    (-68)   /* ownership was not returned inside the budget               */
#define MBXR_E_LANE_ERR     (-69)   /* the lane raised an error bit; read l_err for which         */
#define MBXR_E_LANE_SPAN    (-70)   /* word0 + words > MBXR_BUF_WORDS: the reader would WRAP      */
/* ---- ONE CODE PER SILENTLY-REFUSABLE OPERATION ---------------------------------------------
 * mbxr_engine.v:394 ORs EVERY refusal into one sticky bit -- wh_err, a TileLink error, pa_bad,
 * s_ovf, ld_mode_bad, ld_buf_bad, mm_buf_bad, lane_go_bad, ln_go_bad -- and `fence` returns it
 * as MBXR_S_ERR.  So the engine has always been able to say "that was refused"; nothing asked.
 *
 * Three of these bit this workstream in one session, each found by elimination and each costing
 * board arms: the weight load refused for using bit 18's absence instead of bit 17
 * (ld_mode_bad), the lane reading the wrong buffer because `cfg` was never issued, and the
 * second `ld` refused because the first was still in flight (ld_ok needs !l_busy).  All three
 * presented identically -- stale data, a stale bias word, err[2] on operands that cannot
 * overflow.  The class is not those three bugs; it is that THIS INTERFACE REFUSES SILENTLY.
 * Checking the sticky bit after each stage turns "err[2], cause unknown" into "stage X was
 * refused", the first time it happens, whether or not it is what you were chasing. */
#define MBXR_E_LANE_R_ACTLD  (-71)  /* the activation load was refused                          */
#define MBXR_E_LANE_R_WGTLD  (-72)  /* the weight load was refused (bit 17? still filling?)     */
#define MBXR_E_LANE_R_CFG    (-73)  /* the cfg naming the buffers was refused (t_busy?)         */
#define MBXR_E_LANE_R_ST     (-74)  /* the drain descriptor was refused                         */
#define MBXR_E_LANE_R_GO     (-75)  /* lgo was refused (lane_go_bad: busy, or a bad selector)   */

/* ---- mbxr_ln's own register map (lane 2; mbxr_ln.v's header) -------------------------------- */
/* cfg_addr[12] = 0: the affine table, {index[TL2-1:0], word[2:0]}; write words 0..4 IN ORDER,
 * because words 1..3 stage into a register and word 4 commits the entry. */
#define MBXR_LN_TAB(index, word)  MBXR_CFG(MBXR_LANE_LN, (((index) << 3) | ((word) & 7u)))
#define MBXR_LN_TAB_UMUL    0u      /* umul[24:0]   */
#define MBXR_LN_TAB_KUMUL_L 1u      /* kumul[31:0]  */
#define MBXR_LN_TAB_KUMUL_H 2u      /* kumul[39:32] */
#define MBXR_LN_TAB_GMUL    3u      /* gmul[31:0]   */
#define MBXR_LN_TAB_BADD    4u      /* badd[31:0] -- COMMITS the entry */
/* cfg_addr[12] = 1: the unit registers */
#define MBXR_LN_REG(r)      MBXR_CFG(MBXR_LANE_LN, (0x1000u | ((r) & 7u)))
#define MBXR_LN_R_K         0u      /* K[19:0]                                    */
#define MBXR_LN_R_HW        1u      /* HW[19:0]: elements per affine index        */
#define MBXR_LN_R_EPS_LO    2u      /* eps_q[31:0]                                */
#define MBXR_LN_R_EPS_HI    3u      /* eps_q[63:32]                               */
#define MBXR_LN_R_FLAGS     4u      /* {2: two_pass, 1: out16, 0: in16}           */
#define MBXR_LN_R_ERRCLR    5u      /* clear err[5:1]                             */

/* ---- the LN streamer's registers (lane 3; mbxr_lanes.v) ------------------------------------- */
#define MBXR_SR(r)          MBXR_CFG(MBXR_LANE_STREAM, (r) & 7u)
#define MBXR_SR_WORD0       0u      /* first scratchpad word   */
#define MBXR_SR_WORDS       1u      /* words to read           */
#define MBXR_SR_K           2u      /* K[19:0]                 */
#define MBXR_SR_FLAGS       3u      /* {2: two_pass, 1: out16, 0: in16} */

/* ---- flags, shared by both register files ---------------------------------------------------- */
#define MBXR_LN_F_IN16      1u
#define MBXR_LN_F_OUT16     2u
#define MBXR_LN_F_TWOPASS   4u

/* elements per 64-bit scratchpad word, in and out */
#define MBXR_LN_EPW_IN(flags)   (((flags) & MBXR_LN_F_IN16)  ? 4 : 8)
#define MBXR_LN_EPW_OUT(flags)  (((flags) & MBXR_LN_F_OUT16) ? 4 : 8)

/* =============================================================================================
 * The primitives.  Every caller -- LayerNorm today, the attention unit next, T4's lanes after --
 * goes through these three.
 * ============================================================================================= */

/* Write one configuration word.  Legal only while the target lane is idle. */
static inline void mbxr_lane_cfg(uint64_t addr, uint32_t data)
{
	mbxr_l_cfg(addr, (uint64_t)data);
}

static inline uint32_t mbxr_lane_status(void)
{
	return (uint32_t)mbxr_l_st(0, 0);
}

/* Read the lane's own verdict on its configuration, after writing it and before starting.
 * THE RULE FOR EVERY LANE: both of them report "config unusable" from reset, the bit is readable
 * through lst, and the cost of not reading it is that the lane takes ownership and never gives it
 * back.  Lab B33 paid that once so nothing else has to. */
static inline int mbxr_lane_arm(unsigned which)
{
	uint32_t s = mbxr_lane_status();

	if (which == MBXR_GO_LN && (MBXR_L_LERR(s) & 1u))
		return MBXR_E_LANE_CFG;
	if (which == MBXR_GO_LUT && (MBXR_L_UERR(s) & 1u))
		return MBXR_E_LANE_CFG;
	if (which == MBXR_GO_ATTN && (MBXR_L_AERR(s) & 1u))
		return MBXR_E_LANE_CFG;
	return MBXR_OK;
}

/* PRECONDITION 3 and the lgo guard, checked rather than commented.
 * `drain_ready` is the caller's assertion that the drain descriptor is already issued; passing 0
 * is a programming error and is refused here instead of producing output with nowhere to go. */
static inline int mbxr_lane_go(unsigned which, int drain_ready)
{
	uint32_t s;

	if (!drain_ready)
		return MBXR_E_LANE_CFG;
	s = mbxr_lane_status();
	/* lgo is REFUSED and sets the engine's err_sticky if anything is busy, so do not issue it */
	if (!MBXR_L_IDLE_NOW(s))
		return MBXR_E_LANE_BUSY;
	/* and the lane's own verdict on the configuration just written: err[0] still set means it
	 * would take ownership and never return it */
	if ((which == MBXR_GO_LN && (MBXR_L_LERR(s) & 1u)) ||
	    (which == MBXR_GO_LUT && (MBXR_L_UERR(s) & 1u)) ||
	    (which == MBXR_GO_ATTN && (MBXR_L_AERR(s) & 1u)))
		return MBXR_E_LANE_CFG;
	mbxr_l_go((uint64_t)which, 0);
	return MBXR_OK;
}

/* Wait for ownership to return to the engine.  A BUDGET, NOT A SPIN: precondition 1's failure
 * shape is that ownership never comes back, so the only way a caller can report it is to stop
 * asking.  Returns MBXR_E_LANE_HANG rather than hanging, and *polls is the poll count -- which is
 * what makes this loop a measurement of the wrapper as well as a wait. */
/* `which` matters: the OTHER lane's err bits are set from reset and stay set until somebody
 * configures it, so checking both reports a perfectly healthy dispatch as an error.  Lab B33's
 * first successful run did exactly that -- every dispatch completed, returned ownership and read
 * l_err = 0x00, and was classified LANE_ERR because the attention unit (never configured in that
 * bench) still had a_err = 0x9 from reset. */
static inline int mbxr_lane_wait_for(unsigned which, uint64_t budget_polls, uint64_t *polls,
				     uint32_t *last)
{
	uint64_t n = 0;
	uint32_t s;

	for (;;) {
		s = mbxr_lane_status();
		n++;
		if (MBXR_L_IDLE_NOW(s))
			break;
		if (n >= budget_polls) {
			if (polls) *polls = n;
			if (last) *last = s;
			return MBXR_E_LANE_HANG;
		}
	}
	if (polls) *polls = n;
	if (last) *last = s;
	if ((which == MBXR_GO_LN && MBXR_L_LERR(s)) ||
	    (which == MBXR_GO_LUT && MBXR_L_UERR(s)) ||
	    (which == MBXR_GO_ATTN && MBXR_L_AERR(s)))
		return MBXR_E_LANE_ERR;
	return MBXR_OK;
}

/* the old spelling, kept so a caller that only ever drives one lane need not name it */
static inline int mbxr_lane_wait(uint64_t budget_polls, uint64_t *polls, uint32_t *last)
{
	return mbxr_lane_wait_for(MBXR_GO_LN, budget_polls, polls, last);
}

/* =============================================================================================
 * LayerNorm-specific: shape checking, configuration and one dispatch.
 * ============================================================================================= */

/* PRECONDITIONS 1 and 2, checked before a single instruction is issued.
 * Returns MBXR_OK and writes the streamer's word count, or the code for what is wrong. */
static inline int mbxr_ln_check(int M, int K, unsigned flags, int word0, int *words_out)
{
	long els;
	int epw_in = MBXR_LN_EPW_IN(flags), epw_out = MBXR_LN_EPW_OUT(flags);

	if (M <= 0 || K <= 0 || K > (1 << 20) || word0 < 0)
		return MBXR_E_SHAPE;
	els = (long)M * (long)K;
	/* 1. a whole number of scratchpad words, or ownership never returns */
	if (els % epw_in)
		return MBXR_E_LANE_WORDS;
	/* 2. the output packer is word-aligned per row while the reader is not */
	if (K % epw_out)
		return MBXR_E_LANE_KALIGN;
	/* 5. the word range must fit one buffer, or r_word wraps and the answer is silently wrong */
	if ((long)word0 + els / epw_in > MBXR_BUF_WORDS)
		return MBXR_E_LANE_SPAN;
	if (words_out)
		*words_out = (int)(els / epw_in);
	return MBXR_OK;
}

/* How many ROWS one dispatch may carry, and therefore how many dispatches a shape needs.
 * A tile must be a whole number of rows: the lane reduces over K and resets its position counter
 * at each row end, so a dispatch that stops mid-row reduces over the wrong population.  This is
 * the function that turns "13 layernorms" into the number of lane dispatches actually issued --
 * 6 per layernorm for Moonshine's encoder (165 rows of 288, 28 rows per tile), 1 for a decoder's
 * single row.  The wrapper is paid per DISPATCH, so this is also the function that decides what
 * the wrapper costs. */
static inline int mbxr_ln_plan(int M, int K, unsigned flags, int word0,
			       int *rows_per_tile, int *tiles)
{
	int epw_in = MBXR_LN_EPW_IN(flags), rows;
	long avail;

	if (M <= 0 || K <= 0 || word0 < 0 || word0 >= MBXR_BUF_WORDS)
		return MBXR_E_SHAPE;
	if (K % MBXR_LN_EPW_OUT(flags))
		return MBXR_E_LANE_KALIGN;
	if ((long)K % epw_in)
		return MBXR_E_LANE_WORDS;     /* a row is not a whole number of words: no tiling helps */
	avail = (long)(MBXR_BUF_WORDS - word0) * epw_in;
	rows = (int)(avail / K);
	if (rows < 1)
		return MBXR_E_LANE_SPAN;
	if (rows > M)
		rows = M;
	if (rows_per_tile) *rows_per_tile = rows;
	if (tiles) *tiles = (M + rows - 1) / rows;
	return MBXR_OK;
}

/* mbxr_ln.v's own usability condition, in software, so a bad value is a return code and not a
 * hang.  KL2 = 9 unless the lane is parameterised otherwise, so a one-pass row is K <= 512. */
#define MBXR_LN_KL2      9
#define MBXR_LN_EPS_MIN  ((uint64_t)262144)   /* c_eps must be STRICTLY greater */

static inline int mbxr_ln_cfg_ok(int K, int HW, uint64_t eps_q, unsigned flags)
{
	if (K <= 0)
		return MBXR_E_LANE_CFG;
	if (!(flags & MBXR_LN_F_TWOPASS) && K > (1 << MBXR_LN_KL2))
		return MBXR_E_LANE_CFG;          /* k_fits: a one-pass row must fit the ring */
	if (HW <= 0)
		return MBXR_E_LANE_CFG;          /* c_hw != 0 */
	if (eps_q <= MBXR_LN_EPS_MIN || (eps_q >> 63))
		return MBXR_E_LANE_CFG;          /* the one that cost a board run */
	return MBXR_OK;
}

/* Configure both register files for one dispatch.  The affine table is written separately, by
 * mbxr_ln_table(), because it is per-model and not per-dispatch. */
static inline int mbxr_ln_config(int M, int K, int HW, uint64_t eps_q, unsigned flags,
				 int word0, int *words_out)
{
	int words, rc = mbxr_ln_check(M, K, flags, word0, &words);

	if (rc != MBXR_OK)
		return rc;
	rc = mbxr_ln_cfg_ok(K, HW, eps_q, flags);
	if (rc != MBXR_OK)
		return rc;
	/* the lane */
	mbxr_lane_cfg(MBXR_LN_REG(MBXR_LN_R_K), (uint32_t)K);        /* clears err[0] */
	mbxr_lane_cfg(MBXR_LN_REG(MBXR_LN_R_HW), (uint32_t)HW);
	mbxr_lane_cfg(MBXR_LN_REG(MBXR_LN_R_EPS_LO), (uint32_t)eps_q);
	mbxr_lane_cfg(MBXR_LN_REG(MBXR_LN_R_EPS_HI), (uint32_t)(eps_q >> 32));
	mbxr_lane_cfg(MBXR_LN_REG(MBXR_LN_R_FLAGS), flags & 7u);
	mbxr_lane_cfg(MBXR_LN_REG(MBXR_LN_R_ERRCLR), 1u);
	/* the streamer */
	mbxr_lane_cfg(MBXR_SR(MBXR_SR_WORD0), (uint32_t)word0);
	mbxr_lane_cfg(MBXR_SR(MBXR_SR_WORDS), (uint32_t)words);
	mbxr_lane_cfg(MBXR_SR(MBXR_SR_K), (uint32_t)K);
	mbxr_lane_cfg(MBXR_SR(MBXR_SR_FLAGS), flags & 7u);
	if (words_out)
		*words_out = words;
	return MBXR_OK;
}

/* One affine-table entry.  Words 1..3 stage and word 4 commits, so the order below is load-
 * bearing: writing badd before gmul commits the previous gmul. */
static inline void mbxr_ln_table(unsigned index, uint32_t umul, uint64_t kumul,
				 uint32_t gmul, uint32_t badd)
{
	mbxr_lane_cfg(MBXR_LN_TAB(index, MBXR_LN_TAB_UMUL), umul & 0x01ffffffu);
	mbxr_lane_cfg(MBXR_LN_TAB(index, MBXR_LN_TAB_KUMUL_L), (uint32_t)kumul);
	mbxr_lane_cfg(MBXR_LN_TAB(index, MBXR_LN_TAB_KUMUL_H), (uint32_t)(kumul >> 32) & 0xffu);
	mbxr_lane_cfg(MBXR_LN_TAB(index, MBXR_LN_TAB_GMUL), gmul);
	mbxr_lane_cfg(MBXR_LN_TAB(index, MBXR_LN_TAB_BADD), badd);   /* commits */
}

/* =============================================================================================
 * One LayerNorm dispatch, end to end.  RUNS ON HART 1 ONLY (custom-1 is in hart 1's tile).
 * =============================================================================================
 * The ordering below is not stylistic; each step is one of the preconditions above:
 *   fill  -> the input words must be resident, and in the buffer the lane will read (`abuf`)
 *   ST    -> the drain descriptor before the lane starts (precondition 3)
 *   lcfg  -> K, HW, eps, flags, and the streamer's word range
 *   arm   -> err[0] read back BEFORE lgo (precondition 4, the one that cost a board run)
 *   lgo   -> refused if anything is busy, so the status is checked first
 *   wait  -> a poll budget, because the failure shape is that ownership never returns
 * The caller supplies `cmd` so this header does not depend on which runtime issues the engine's
 * own commands -- mbxr_rt.h's stub or a bench's.
 */
typedef uint64_t (*mbxr_lane_cmd_fn)(void *ctx, unsigned funct, uint64_t a, uint64_t b, int xd);

/* Load `words` 64-bit words from `src_pa` into activation buffer `abuf`, then drain `blocks`
 * 64-byte blocks to `dst_pa`.  Both are whole-block counts by construction: the caller has
 * already been through mbxr_ln_plan(), which only returns tiles whose byte count is a multiple
 * of 64. */
/* =============================================================================================
 * mbxr_attn_dispatch -- ONE (layer, head) on the attention unit (mbxa_core, lane 0; its
 * softmax sub-lane is lane 1).  ATTENTION_UNIT.md s2.2 is the layout contract and s10 the
 * kernel that stages for it.
 *
 * THIS RUNS ON HART 1, like everything else here, and the reason is not style.  Every call
 * below reaches custom-1 -- `lcfg`, `lgo`, `lst` -- and CUSTOM-1 IS IN HART 1'S TILE.  Called
 * from hart 0 the first `lcfg` traps with mcause 2 at mtval 0x12b5302b, which is lcfg's own
 * encoding.  That is recorded in three places in this tree (mbxr_rt.h's MBXR_RT_CAP note, the
 * LayerNorm lane kernel's line 172, and mbxr_rt_job's own comment) and it was still walked
 * into afterwards, so it is repeated here at the call site rather than only in a document.
 *
 * WHAT STAYS ON HART 0, DELIBERATELY: building the q and weight images, and computing the
 * softmax table's 256 values.  None of that touches custom-1 -- it is plain arithmetic and
 * memory -- and it is the bulk of the work, so moving it here would serialise it behind the
 * lane instead of overlapping it.  Do not "tidy" it in.
 * ============================================================================================= */
static inline uint64_t mbxr_rt_cyc_lane(void)
{
	uint64_t c;
	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

static inline int mbxr_attn_dispatch(mbxr_lane_cmd_fn cmd, void *ctx,
				     uint64_t q_pa, int q_words,
				     uint64_t w_pa, int lgpw,
				     uint64_t dst_pa, int blocks,
				     int rows, int gs, int qs, int gp, int qp,
				     int kbase_w, int vtbase_w, int nsc, int nout,
				     uint32_t mt_s, int sh_s, uint32_t mt_p, int sh_p,
				     const uint32_t *smx_ex, int32_t smx_om, int smx_s,
				     int smx_K, int do_table,
				     uint64_t budget, uint64_t *polls, uint64_t *fence_polls,
				     uint32_t *aerr, uint64_t *fence_cyc, uint64_t *wait_cyc)
{
	uint64_t np = 0, fp = 0, fc0, wc0;
	uint32_t st = 0;
	int rc, k;

	/* Clear the sticky error first, exactly as mbxr.c:290 does, so what follows is OURS. */
	cmd(ctx, MBXR_STAT, 0, 1, 1);

	/* the softmax table, on THIS hart, once per fused op rather than once per head */
	if (do_table) {
		for (k = 0; k < 256; k++)
			mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_SMX, (unsigned)k), smx_ex[k]);
		mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_SMX, 0x100u), (uint32_t)smx_om);
		mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_SMX, 0x101u), (uint32_t)smx_s);
		mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_SMX, 0x102u), (uint32_t)smx_K);
	}

	/* the fill: activation image into buffer 0, weight image into the W half.
	 *
	 * ONE FENCE BETWEEN THE TWO LOADS, NOT ONE AFTER BOTH.  `ld_ok = ld && !l_busy && ...`
	 * (mbxr_engine.v:166) with `l_busy = lw_busy || la_busy` (:160) -- so a load issued
	 * while EITHER DMA is in flight is refused, silently, and mbxr.c's load_act opens with
	 * `wait_place(pl, MBXR_S_FILL)` for exactly this reason.  Issuing both back to back left
	 * the weight planes holding the previous dispatch's data, which is a fourth route to the
	 * same err[2]: stale planes carry a stale bias word, and mbxr_mac's `clr` step loads it
	 * into the accumulator.  The other three were the bit-17 encoding, the missing `cfg`,
	 * and -- unlike those two -- this one is a TIMING failure, which is why a modelled DMA
	 * could not see it and the fixes for the other two were each necessary and not
	 * sufficient. */
	cmd(ctx, MBXR_SD, q_pa, ((uint64_t)q_words & 0xffffULL) | (1ULL << 16), 0);
	cmd(ctx, MBXR_LD, (1ULL << 18) | (0ULL << 16) | (10ULL << 8), 0, 0);
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_ACTLD;
	for (uint64_t i = 0; i < budget; i++) {
		fp++;
		if (!(cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_FILL))
			break;
		if (i + 1 == budget) {
			if (fence_polls) *fence_polls = fp;
			return MBXR_E_LANE_HANG;
		}
	}
	/* THE WEIGHT LOAD IS BIT 17, NOT THE ABSENCE OF BIT 18.  `ld_mode_bad = ld &&
	 * (cmd_rs1[17] == ld_a)` (mbxr_engine.v:164) -- "weights must be on W" -- so a weight
	 * load with bit 17 clear is REFUSED, silently as far as this caller is concerned.  The
	 * planes then keep whatever the previous engine dispatch left in them, INCLUDING A
	 * NON-ZERO BIAS WORD, which mbxr_mac's `clr` step loads straight into the accumulator:
	 * a 32-bit value where the bound says int8 x int8 over 165 terms cannot exceed 2.7 M.
	 * That is how err[2] fires on data that cannot overflow.  The descriptor is MBXR_NCH rows
	 * of one plane each, exactly as mbxr.c's load_wgt issues it, not one flat 16 kB row.
	 *
	 * THE ROW COUNT IS MBXR_NCH, NOT 4.  It was the literal 4 until 2026-09-19, which is the
	 * engine driver's site written the one way the engine driver did not write it (mbxr.c:
	 * `(uint64_t)MBXR_NCH << 16`).  On an NCH = 8 engine a literal 4 fills planes 0..3 and
	 * leaves 4..7 holding THE PREVIOUS DISPATCH'S DATA -- stale planes with a stale bias word,
	 * which is precisely the err[2] route the paragraph above describes.  It is invisible at
	 * NCH = 4, where the literal and the constant are the same number. */
	{
		uint64_t plane_bytes = 8ULL << lgpw;
		cmd(ctx, MBXR_SD, w_pa,
		    (plane_bytes << 32) | ((uint64_t)MBXR_NCH << 16) | (plane_bytes / 64), 0);
		cmd(ctx, MBXR_LD, (1ULL << 17) | (0ULL << 16) | ((uint64_t)lgpw << 8), 0, 0);
		if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_WGTLD;
	}
	/* A FENCE IS A READ, NOT A WAIT (mbxr_ln_dispatch's note).  Counted, because the fence
	 * cost here is an ARITHMETIC BOUND (ATTENTION_UNIT.md s10.8: 5 polls per head) and a
	 * bound that is never measured is a bound nobody can falsify. */
	/* TIMED, because the per-poll cost is the quantity in dispute: simulation shows ~9
	 * cycles for a status read and the board showed 989 for the LayerNorm lane.  This is a
	 * direct measurement on a real dispatch pattern, not a model. */
	fc0 = mbxr_rt_cyc_lane();
	for (uint64_t i = 0; i < budget; i++) {
		fp++;
		if (!(cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_BUSY))
			break;
		if (i + 1 == budget) {
			if (fence_polls) *fence_polls = fp;
			if (fence_cyc) *fence_cyc = mbxr_rt_cyc_lane() - fc0;
			return MBXR_E_LANE_HANG;
		}
	}
	if (fence_cyc) *fence_cyc = mbxr_rt_cyc_lane() - fc0;

	/* NAME THE BUFFERS.  mbxr_lanes.v:312 addresses the lane's reads as {5'd0, abuf, word},
	 * and `abuf` is the engine's t_abuf -- a LIVE wire set only by `cfg` (mbxr_engine.v:198,
	 * from rs2[40]/[41]).  Without this the lane reads whichever buffer the PREVIOUS ENGINE
	 * DISPATCH selected, which is stale weights and a stale bias word, which is err[2] on
	 * data that cannot overflow.  Reproduced off-board by tb_attn.cpp's ATTN_STALEBUF.
	 * rs1's tile-sequencer fields are written too and are harmless: mbxr.c issues its own
	 * `cfg` before every `mm`, and `cfg` is refused while t_busy anyway. */
	cmd(ctx, MBXR_CFG, 0, (0ULL << 41) | (0ULL << 40), 0);
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_CFG;

	/* the drain descriptor BEFORE lgo -- s2.2b precondition 1: an unarmed or short drain
	 * sticks almost_full, sticks out_hold, and ownership is never returned.  A HANG. */
	cmd(ctx, MBXR_ST, dst_pa, MBXR_ST_FLAT(blocks), 0);
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_ST;

	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x200u), 0u);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x201u), (uint32_t)kbase_w);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x202u), (uint32_t)vtbase_w);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x203u), (uint32_t)gs);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x204u), (uint32_t)qs);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x205u), (uint32_t)gp);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x206u), (uint32_t)qp);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x207u), (uint32_t)rows);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x208u), (uint32_t)nsc);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x209u), (uint32_t)nout);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x20au), mt_s);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x20bu),
		      ((uint32_t)sh_s & 0x3fu) | (0x80u << 8) | (0x7fu << 16));
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x20cu), mt_p);
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_ATTN, 0x20du),
		      ((uint32_t)sh_p & 0x3fu) | (0x80u << 8) | (0x7fu << 16));

	rc = mbxr_lane_arm(MBXR_GO_ATTN);        /* err[0] back through lst, BEFORE go */
	if (rc != MBXR_OK) { if (fence_polls) *fence_polls = fp; return rc; }
	rc = mbxr_lane_go(MBXR_GO_ATTN, 1);
	if (rc != MBXR_OK) { if (fence_polls) *fence_polls = fp; return rc; }
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) {
		if (fence_polls) *fence_polls = fp;
		return MBXR_E_LANE_R_GO;
	}
	/* DO NOT POLL A DEVICE WHOSE FINISH TIME YOU ALREADY KNOW.  One cross-hart `lst` costs
	 * 989 cycles on the board against 9 in simulation, and one head is ~79 of them long, so
	 * spinning to the computed completion first turns ~79 reads into ~1.  The estimate is
	 * deliberately SHORT (the quad schedule without its tail), because overshooting the spin
	 * adds latency no poll can take back while undershooting costs one extra poll. */
	{
		uint64_t steps = (uint64_t)rows * ((uint64_t)qs * (gs + 1) + (uint64_t)qp * (gp + 1));
		uint64_t t0 = mbxr_rt_cyc_lane();
		while (mbxr_rt_cyc_lane() - t0 < steps) { }
	}
	wc0 = mbxr_rt_cyc_lane();
	rc = mbxr_lane_wait_for(MBXR_GO_ATTN, budget, &np, &st);
	/* THE LANE BEING IDLE IS NOT THE DRAIN BEING DONE, and the caller reads the destination
	 * the instant this returns.  mbxr_ln_dispatch has fenced MBXR_S_BUSY here since it was
	 * written; this dispatcher never did, and mbxr.c:350 does the same thing for the engine's
	 * own path.  Without it hart 0 reads `ob` -- and memcpys `tail` for the last head -- while
	 * the drain still has Puts in flight: max_abs_err 144 / 129 / 116 across three arms, two of
	 * them from a BYTE-IDENTICAL image (md5 7b678a0d).  A deterministic computation on
	 * deterministic hardware does not do that.  A partial read raises no error bit, so
	 * attn_last_rc, attn_aerr and every gate reported success.
	 * ENGINE/ATTENTION_FILL_DIFFERENTIAL.md s11. */
	for (uint64_t i = 0; i < budget; i++) {
		fp++;
		if (!(cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_BUSY))
			break;
		if (i + 1 == budget) {
			if (wait_cyc) *wait_cyc = mbxr_rt_cyc_lane() - wc0;
			if (polls) *polls = np;
			if (fence_polls) *fence_polls = fp;
			return MBXR_E_LANE_HANG;
		}
	}
	if (wait_cyc) *wait_cyc = mbxr_rt_cyc_lane() - wc0;
	if (polls) *polls = np;
	if (fence_polls) *fence_polls = fp;
	/* THE ERROR BITS THEMSELVES, not just the return code.  rc = -69 says "a bit is set";
	 * err[2] is |acc| >= 2^24 and err[3] is smx/dropped-score/ring.  Bounding both products
	 * (ATTENTION_UNIT.md s10.10) puts .qk 25.8x and .av 6.1x under the err[2] threshold, so
	 * err[2] firing would mean the accumulator is not carrying int8 x int8 -- a datapath
	 * misconfiguration, not an overflow.  Recording the value is what tells them apart. */
	if (aerr) *aerr = MBXR_L_AERR(st);
	return rc;
}

static inline int mbxr_ln_dispatch(mbxr_lane_cmd_fn cmd, void *ctx,
				   uint64_t src_pa, int words, unsigned abuf,
				   uint64_t dst_pa, int blocks,   /* blocks: padded; words: exact */
				   int rows, int K, int HW, uint64_t eps_q, unsigned flags,
				   uint64_t budget, uint64_t *polls)
{
	int rc, w;
	uint64_t np = 0;
	uint32_t st;

	rc = mbxr_ln_check(rows, K, flags, 0, &w);
	if (rc != MBXR_OK)
		return rc;
	if (w != words)
		return MBXR_E_SHAPE;                      /* `words` is the EXACT element count */
	if ((long)blocks * 8 < (long)words || (long)blocks * 8 - (long)words >= 8)
		return MBXR_E_SHAPE;                      /* and `blocks` covers it, by < one block */
	/* BOTH ENDS OF THE DMA ARE 64-BYTE ALIGNED, and this is a HARDWARE contract rather than a
	 * preference: rtl_study/rocc/mbxd_dma.v:71 declares src_base "byte address of the first
	 * block, 64-byte aligned", and :38 says there is NO BYTE FUNNEL -- "the scratchpad is a 1:1
	 * image of 64-byte-aligned memory".  mbxr.c:245 already refuses an unaligned drain with
	 * MBXR_E_ALIGN; nothing refused an unaligned FILL, so a misaligned source was read as
	 * whatever the block containing it holds -- a plausible wrong answer with rc = 0 and no
	 * error bit, which is the second half of Lab B39's residue (max_abs_err 96 after the
	 * stale-buffer cfg took it from 241).
	 *
	 * Refused here rather than checked in one kernel, because this is the third caller of this
	 * protocol and the first two hazards were each paid for twice.  A caller whose tensor is
	 * not 64-byte aligned must stage it, exactly as the linear kernel stages -- and now it
	 * finds out from a return code instead of from a transcript.
	 *
	 * Why no simulator caught it: tb_mbxr's LN_SRC is MEM_BASE + 8 MB and LN_DST MEM_BASE +
	 * 16 MB, both 64-byte aligned BY CONSTRUCTION, so 94 lane cases can pass while every
	 * unpadded tile on the board fills from an address 8, 24, 40 or 56 bytes into a block. */
	if ((src_pa & 63u) || (dst_pa & 63u))
		return MBXR_E_ALIGN;

	/* the fill: source descriptor, then the activation load into `abuf`.
	 * NOTE the buffer.  Nothing refuses a load into the buffer a running lane is reading --
	 * `ld_buf_bad` is gated on the TILE SEQUENCER, not on lane ownership -- so a caller that
	 * pipelines must target the other buffer.  This call is synchronous and does not. */
	/* THE FILL AND THE STREAMER COUNT DIFFERENT THINGS, and conflating them is a hang.
	 * The DMA moves whole 64-byte BLOCKS, so a tile that is not a whole number of them is
	 * filled from a zero-padded staging buffer and `blocks` covers the padding.  The streamer
	 * is told `words` -- the EXACT element count -- because feeding it the padded count makes
	 * `in_last` disagree with K (err[5]) and can leave a partial row the lane waits forever
	 * for.  One number is rounded up; the other must not be. */
	cmd(ctx, MBXR_SD, src_pa, ((uint64_t)blocks & 0xffffULL) | (1ULL << 16), 0);
	cmd(ctx, MBXR_LD, (1ULL << 18) | ((uint64_t)abuf << 16) | (10ULL << 8), 0, 0);
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_ACTLD;
	/* A FENCE IS A READ, NOT A WAIT.  funct 6 returns the status word; it does not block, so
	 * issuing it once proves nothing about whether the fill has landed.  Loop until the engine
	 * reports itself not busy, with the same budget discipline as everything else here. */
	for (uint64_t i = 0; i < budget; i++) {
		if (!(cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_BUSY))
			break;
		if (i + 1 == budget)
			return MBXR_E_LANE_HANG;
	}

	/* NAME THE BUFFER THE LANE READS.  `abuf` above is the buffer the DMA WRITES -- the fill's
	 * la_fbuf, cmd_rs1[16].  The buffer the lane READS is mbxr_lanes.v:313's `abuf`, which is
	 * the engine's t_abuf: a live wire set ONLY by `cfg` (mbxr_engine.v:198, from rs2[40]/[41]).
	 * This dispatcher issued no `cfg`, so it filled the buffer its caller named and read
	 * whichever buffer THE LAST ENGINE DISPATCH had left selected.
	 *
	 * That is the whole of Lab B38's max_abs_err = 241.  Reading a wrong-but-valid buffer is
	 * not an error condition, so it came back with last_rc 0, calls_fallback 0 and no error bit
	 * -- which is exactly what it should look like.  ONE defect, TWO symptoms: the attention
	 * unit's accumulator is wide enough to go out of range on a stale buffer and raises err[2];
	 * the LayerNorm lane has no accumulator wide enough to overflow, so it simply returns wrong
	 * bytes.  mbxr_attn_dispatch has carried this cfg since f94fd0d with the buffer hard-coded
	 * to 0.  Here it carries the CALLER's abuf, because a dispatcher that takes a buffer
	 * argument and then ignores it on the read side is the same bug restated.
	 *
	 * After the fill's !BUSY loop deliberately: `cfg` is refused while t_busy.  rs1's
	 * tile-sequencer fields are written too and are harmless -- mbxr.c issues its own `cfg`
	 * before every `mm`. */
	cmd(ctx, MBXR_CFG, 0, (0ULL << 41) | ((uint64_t)(abuf & 1u) << 40), 0);
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_CFG;

	/* the drain descriptor, BEFORE the lane starts */
	cmd(ctx, MBXR_ST, dst_pa, MBXR_ST_FLAT(blocks), 0);
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_ST;

	rc = mbxr_ln_config(rows, K, HW, eps_q, flags, 0, NULL);
	if (rc != MBXR_OK)
		return rc;
	rc = mbxr_lane_arm(MBXR_GO_LN);           /* err[0] back through lst, before go */
	if (rc != MBXR_OK)
		return rc;
	rc = mbxr_lane_go(MBXR_GO_LN, 1);
	if (rc != MBXR_OK)
		return rc;
	if (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) return MBXR_E_LANE_R_GO;
	rc = mbxr_lane_wait_for(MBXR_GO_LN, budget, &np, &st);
	if (polls)
		*polls = np;
	if (rc != MBXR_OK)
		return rc;
	for (uint64_t i = 0; i < budget; i++) {
		if (!(cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_BUSY))
			break;
		if (i + 1 == budget)
			return MBXR_E_LANE_HANG;
	}
	return MBXR_OK;
}

#endif /* MBXR_LANES_H */
