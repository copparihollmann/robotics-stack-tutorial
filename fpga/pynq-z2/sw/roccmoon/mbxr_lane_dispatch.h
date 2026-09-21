/* SPDX-License-Identifier: Apache-2.0
 *
 * mbxr_lane_dispatch.h -- ONE dispatch path for every lane on this engine.
 *
 * WHY THIS EXISTS.  There are three lane dispatchers in this tree: mbxr_attn_dispatch,
 * mbxr_ln_dispatch, and the one samples/lut_lane_smoke wrote for T4.  Six hazards have now
 * been paid for two or three times each, every time because the first fix went into a KERNEL
 * or a BENCH rather than into a shared path:
 *
 *   1. the weight load is bit 17 SET, not bit 18 clear  (ld_mode_bad)   -- attention, 1 arm
 *   2. `cfg` must name the buffer the lane READS                        -- attention (err[2]),
 *      and independently the LayerNorm lane (max_abs_err 241, rc 0)
 *   3. a second `ld` while the first is in flight is dropped (ld_ok needs !l_busy)
 *   4. the per-stage refusal checks (MBXR_E_LANE_R_*)                   -- in exactly ONE of
 *      the three dispatchers, after costing nine board arms to establish
 *   5. `mbxr_st` has no ready: out_valid is a PULSE, out_hold throttles  -- T4 arm A, a hang
 *   6. the word count must be a multiple of 8                           -- checked NOWHERE
 *
 * Hazards 5 and 6 are new, from Lab B37 (T4_LANES.md s11-s12, EXPERIMENT_LOG L309-L310).
 * Hazard 6 is the worst polarity in the set: the lane returns ownership CLEANLY with rc = 0
 * and u_err = 0x0, the destination keeps its previous contents for the last block, and the
 * DRAIN STAYS BUSY FOREVER.  It bites the real shapes -- a 190,080-element GELU is 23 full
 * 1,024-word tiles plus 208 words, and 208 is not a multiple of 8.
 *
 * WHAT THIS FILE IS AND IS NOT, AND THE RULE IT WAS LANDED UNDER.  It is a REFACTOR: a new
 * header that nothing includes yet, written so the three existing dispatchers can delegate to
 * it and produce BYTE-IDENTICAL results.  It deliberately does NOT fix anything on the way
 * through -- not the attention unit's missing alignment check, not its `vtbase_w` guard.
 * Three workstreams depend on mbxr_lanes.h; a refactor that also fixes things cannot be
 * bisected.  Fixes go on top, as separate commits, once the delegation has landed.
 *
 * THE ONE THING THAT DECIDES WHETHER A LANE IS WORTH USING, and it is not the lane.  See
 * docs/LANE_DISPATCH_RULES.md s1.  Measured, same model, same clock, varying only where the
 * drain writes: drain into the caller's destination RTF_e2e 5.072; copy out 64 bits at a time
 * 5.166; copy out a byte at a time 5.836 -- against 5.533 for NOT USING THE LANE AT ALL.  So
 * this interface takes the caller's destination physical address as the NORMAL case, and a
 * caller that wants a scratch-and-copy-out path has to ask for it by name and say why.
 */
#ifndef MBXR_LANE_DISPATCH_H
#define MBXR_LANE_DISPATCH_H

#include "mbxr.h"
#include "mbxr_lanes.h"

/* ---- error codes for the preconditions that had none -----------------------------------------
 * Continuing mbxr_lanes.h's -64.. block.  Defined here rather than there only because that file
 * is shared with a workstream mid-flight; they belong in that block and should move into it when
 * this header is sequenced in.  Guarded so the move is a no-op. */
#ifndef MBXR_E_LANE_BLOCKS
#define MBXR_E_LANE_BLOCKS  (-76)   /* words is not a multiple of 8: the last 64-byte block is
                                     * never issued (mbxr_st.v:79 have_block = used >= 8), the
                                     * destination keeps its previous contents, rc reads 0 and
                                     * THE DRAIN STAYS BUSY FOREVER                            */
#endif
#ifndef MBXR_E_LANE_PRAM
#define MBXR_E_LANE_PRAM    (-77)   /* vtbase_w + qp*(gp+1) > PRAM depth                       */
#endif
#ifndef MBXR_E_LANE_NOLANE
#define MBXR_E_LANE_NOLANE  (-79)   /* the dispatch completed and the drain moved NOTHING: the
                                     * bitstream has no such lane, or it refused.  88af508's
                                     * failure was exactly this going unnoticed -- an armed and
                                     * unfed drain poisons every later dispatch in the stream,
                                     * and the run passes max_abs_err = 0 at 5x the RTF.       */
#endif
#ifndef MBXR_E_LANE_DRAIN
#define MBXR_E_LANE_DRAIN   (-78)   /* the drain blocks do not cover the words, or overshoot by
                                     * a whole block: an unfed drain poisons the whole stream   */
#endif

/* the engine's own constants, named so a caller never writes the literal */
#define MBXR_LD_BLOCK_B     64      /* mbxd_dma.v:71: the fill's source must be aligned to this */
#define MBXR_LD_BLOCK_W     8       /* ... and mbxr_st issues a burst only per whole block      */
#define MBXR_LANE_BUF_W     MBXR_BUF_WORDS   /* 1024: one activation buffer, 8 KB               */

/* =============================================================================================
 * THE PLAN.  Everything a dispatch needs, in one struct, so that checking it and issuing it are
 * separable -- a caller can refuse before it has issued a single instruction, which is the
 * difference between a return code and a hung board.
 * ============================================================================================= */
typedef struct {
	/* ---- what to read ------------------------------------------------------------------ */
	uint64_t src_pa;        /* the tile's source, 64-BYTE ALIGNED (precondition 1)          */
	int      src_blocks;    /* whole 64-byte blocks to fill: ceil(bytes/64), PADDED         */
	unsigned abuf;          /* which activation buffer to fill AND to point the lane at     */
	int      word0;         /* first scratchpad word the lane reads                         */
	int      words;         /* words the lane reads: EXACT, and a multiple of 8             */

	/* ---- where to write ----------------------------------------------------------------- */
	/* THE CALLER'S DESTINATION, not a scratch window.  docs/LANE_DISPATCH_RULES.md s1: a
	 * byte-wise copy-out of the result costs more than the lane saves.  64-byte aligned, with
	 * 64 bytes of slack past the end, because the drain writes whole blocks.  A caller whose
	 * tail block would overrun something it cares about stages THAT BLOCK, not the tile. */
	uint64_t dst_pa;
	int      dst_blocks;    /* whole blocks the drain will write: ceil(out_bytes/64)         */

	/* ---- which lane, and its budget ------------------------------------------------------ */
	unsigned which;         /* MBXR_GO_ATTN / MBXR_GO_LN / MBXR_GO_LUT                       */
	uint64_t budget;        /* poll budget: a lane that never returns must be a RETURN CODE   */
} mbxr_lane_plan;

/* ---- statistics, so "the lane ran" and "the fallback ran" are never the same zero ----------- */
typedef struct {
	uint32_t calls_lane;      /* dispatches that reached `lgo` and returned ownership        */
	uint32_t calls_refused;   /* refused before any instruction was issued                   */
	uint32_t calls_failed;    /* issued and did not complete                                 */
	int32_t  last_rc;
	uint32_t last_uerr, last_lerr, last_aerr;
	uint64_t polls;
} mbxr_lane_stats;

/* =============================================================================================
 * EVERY PRECONDITION THE HARDWARE REQUIRES AND DOES NOT ENFORCE, IN ONE FUNCTION.
 *
 * Issues nothing.  A caller that calls this first can fall back to software with a named
 * reason instead of discovering the rule from a transcript -- or, for four of these six, from
 * a board that has to be power-cycled.
 *
 * WHY EACH ONE IS HERE RATHER THAN IN A COMMENT: every one of them is satisfied BY ACCIDENT by
 * every harness in this tree.  tb_mbxr's LN_SRC is MEM_BASE + 8 MB and its LN_DST MEM_BASE +
 * 16 MB, both 64-byte aligned by construction, so 94 lane cases pass while the board fills
 * from an address 8, 24, 40 or 56 bytes into a block.  A suite that runs the board's SHAPES
 * and not its SEQUENCE cannot find any of this.
 * ============================================================================================= */
static inline int mbxr_lane_check(const mbxr_lane_plan *p)
{
	if (!p || p->words <= 0 || p->word0 < 0 || p->src_blocks <= 0 || p->dst_blocks <= 0)
		return MBXR_E_SHAPE;

	/* 1. THE FILL SOURCE AND THE DRAIN DESTINATION ARE 64-BYTE ALIGNED (mbxd_dma.v:71).
	 * Misaligned, the fill starts partway into a block and the lane reads the wrong bytes with
	 * no error anywhere.  mbxr_ln_dispatch checks this; mbxr_attn_dispatch does not. */
	if ((p->src_pa & (MBXR_LD_BLOCK_B - 1)) || (p->dst_pa & (MBXR_LD_BLOCK_B - 1)))
		return MBXR_E_ALIGN;

	/* 2. THE WORD COUNT IS A MULTIPLE OF 8, and this is the one nothing checked.  mbxr_st
	 * issues a burst only when a whole 64-byte block is in its FIFO (mbxr_st.v:79,
	 * have_block = (used >= 8)), so a 28-word dispatch leaves four words that are NEVER
	 * WRITTEN: the destination keeps its previous contents for that block, the lane goes idle
	 * and RETURNS OWNERSHIP CLEANLY with rc = 0 and u_err = 0x0, and the drain stays busy for
	 * the rest of the run.  That is 88af508's armed-and-unfed poison reached without arming
	 * anything wrong.  Zero-pad the tile to a whole block instead: `words` exact, `blocks`
	 * rounded up -- the two numbers mbxr_ln_dispatch already keeps separate. */
	if (p->words % MBXR_LD_BLOCK_W)
		return MBXR_E_LANE_BLOCKS;

	/* 3. THE WORD RANGE STAYS INSIDE ONE ACTIVATION BUFFER.  The streamer address is AW bits
	 * and a buffer is 2^AW words; past that it WRAPS and the lane reads the start of its own
	 * buffer as more data.  0x5A5A0029 and 002A ship that defect; mbxl_lut refuses it in
	 * hardware (err[2]).  Checked here so it is a return code on every lane. */
	if ((long)p->word0 + (long)p->words > (long)MBXR_LANE_BUF_W)
		return MBXR_E_LANE_SPAN;

	/* 4. THE FILL COVERS THE WORDS THE LANE WILL READ, and by less than a whole block -- a
	 * short fill means the lane reads whatever the previous dispatch left. */
	if ((long)p->src_blocks * MBXR_LD_BLOCK_W < (long)p->word0 + (long)p->words)
		return MBXR_E_SHAPE;

	/* 5. THE DRAIN DESCRIPTOR COVERS THE OUTPUT AND DOES NOT OVERSHOOT BY A WHOLE BLOCK.
	 * Short, and the lane stalls with words the drain will never take (a HANG, and it poisons
	 * every later dispatch).  Over by a whole block, and the drain waits forever for output
	 * that is never produced -- the same poison from the other side. */
	if ((long)p->dst_blocks * MBXR_LD_BLOCK_W < (long)p->words ||
	    (long)p->dst_blocks * MBXR_LD_BLOCK_W - (long)p->words >= MBXR_LD_BLOCK_W)
		return MBXR_E_LANE_DRAIN;

	if (p->abuf > 1u)
		return MBXR_E_SHAPE;
	if (p->which != MBXR_GO_ATTN && p->which != MBXR_GO_LN && p->which != MBXR_GO_LUT)
		return MBXR_E_SHAPE;
	if (!p->budget)
		return MBXR_E_SHAPE;
	return MBXR_OK;
}

/* the attention unit's P-RAM guard, kept with the others because it is the same class.
 * NOTE: the check in the tree today is one too permissive; this takes the depth as an argument
 * so correcting it is a caller change and not a behaviour change smuggled into a refactor. */
static inline int mbxr_lane_check_pram(int vtbase_w, int qp, int gp, int pram_words)
{
	if (vtbase_w < 0 || qp < 0 || gp < 0)
		return MBXR_E_SHAPE;
	return ((long)vtbase_w + (long)qp * ((long)gp + 1) > (long)pram_words)
	       ? MBXR_E_LANE_PRAM : MBXR_OK;
}

/* =============================================================================================
 * THE STAGES.  Each one asks the engine whether it was refused, because the engine has always
 * been able to say so and for a year nothing asked: mbxr_engine.v:394 ORs every refusal into
 * one sticky bit and `fence` returns it as MBXR_S_ERR.  Cleared at the top of each stage and
 * read at the bottom, "err[2], cause unknown" becomes "stage X was refused" the first time it
 * happens, whether or not it is what you were chasing.
 * ============================================================================================= */
static inline void mbxr_lane_err_clear(mbxr_lane_cmd_fn cmd, void *ctx)
{
	(void)cmd(ctx, MBXR_STAT, 0, 1, 1);
}
static inline int mbxr_lane_err_set(mbxr_lane_cmd_fn cmd, void *ctx)
{
	return (cmd(ctx, MBXR_FENCE, 0, 0, 1) & MBXR_S_ERR) != 0;
}

/* A FENCE IS A READ, NOT A WAIT.  funct 6 returns the status word and does not block, so
 * issuing it once proves nothing.  Loop with a budget. */
static inline int mbxr_lane_fence(mbxr_lane_cmd_fn cmd, void *ctx, uint64_t mask, uint64_t budget)
{
	for (uint64_t i = 0; i < budget; i++)
		if (!(cmd(ctx, MBXR_FENCE, 0, 0, 1) & mask))
			return MBXR_OK;
	return MBXR_E_LANE_HANG;
}

/* The ACTIVATION fill.  rs1[18] = 1 selects client A and rs1[17] MUST BE 0:
 * `ld_mode_bad = ld && (cmd_rs1[17] == ld_a)`, so a WEIGHT load is bit 17 SET, not bit 18
 * clear.  Getting it backwards is silently refused and leaves the previous dispatch's planes
 * in place.  Does not wait: a caller that wants to overlap the next tile's fill with this
 * tile's compute issues this and then dispatches, and `ld_ok` (which consults only the two load
 * DMAs, never the lanes' `own`) accepts it. */
static inline int mbxr_lane_fill_start(mbxr_lane_cmd_fn cmd, void *ctx,
				       uint64_t src_pa, int blocks, unsigned abuf)
{
	if (src_pa & (MBXR_LD_BLOCK_B - 1))
		return MBXR_E_ALIGN;
	mbxr_lane_err_clear(cmd, ctx);
	cmd(ctx, MBXR_SD, src_pa, ((uint64_t)blocks & 0xffffULL) | (1ULL << 16), 0);
	cmd(ctx, MBXR_LD, (1ULL << 18) | ((uint64_t)(abuf & 1u) << 16) | (10ULL << 8), 0, 0);
	return mbxr_lane_err_set(cmd, ctx) ? MBXR_E_LANE_R_ACTLD : MBXR_OK;
}

/* NAME THE BUFFER THE LANE READS.  This is a DIFFERENT REGISTER from the one the fill writes.
 * The fill's buffer is `ld` rs1[16] -> la_fbuf; the lane's is mbxr_lanes.v:312's `abuf`, which
 * is the engine's t_abuf, written ONLY by `cfg` (funct 2, rs2[40]/[41]).  Without this the lane
 * reads whichever buffer the last engine dispatch selected: the attention unit raised err[2] on
 * operands that cannot overflow, and the LayerNorm lane -- which has no accumulator wide enough
 * to overflow -- simply returned wrong bytes, max_abs_err 241 with last_rc 0.
 *
 * AND NEVER WHILE A LANE OWNS THE SCRATCHPAD.  `cfg && !t_busy` (mbxr_engine.v:195) is gated on
 * mbxr_tseq's busy, which a lane dispatch does not set, so a `cfg` issued during a dispatch
 * re-points that dispatch's reads mid-stream, silently.  Between dispatches only. */
static inline int mbxr_lane_name_buffers(mbxr_lane_cmd_fn cmd, void *ctx,
					 unsigned abuf, unsigned wbuf)
{
	mbxr_lane_err_clear(cmd, ctx);
	cmd(ctx, MBXR_CFG, 0, ((uint64_t)(wbuf & 1u) << 41) | ((uint64_t)(abuf & 1u) << 40), 0);
	return mbxr_lane_err_set(cmd, ctx) ? MBXR_E_LANE_R_CFG : MBXR_OK;
}

/* Arm the drain AT THE CALLER'S DESTINATION and start the lane.
 *
 * ORDER, AND IT IS NOT COSMETIC.  "st before lgo" is the precondition; "st before a REFUSAL" is
 * the poison.  An armed drain that never gets its blocks sticks almost_full, sticks out_hold,
 * and every later dispatch in the stream spins out -- 88af508 measured RTF 25.540 against a
 * usual 5.3, passing max_abs_err = 0.  So every condition `lgo` will check is checked FIRST,
 * with nothing else on this hart able to change the lane in between, and the descriptor is
 * issued only once the go cannot be refused. */
static inline int mbxr_lane_go_at(mbxr_lane_cmd_fn cmd, void *ctx, unsigned which,
				  uint64_t dst_pa, int blocks)
{
	int rc;

	if (dst_pa & (MBXR_LD_BLOCK_B - 1))
		return MBXR_E_ALIGN;
	if (!MBXR_L_IDLE_NOW(mbxr_lane_status()))
		return MBXR_E_LANE_BUSY;
	rc = mbxr_lane_arm(which);                 /* err[0] back through lst, before go */
	if (rc != MBXR_OK)
		return rc;

	mbxr_lane_err_clear(cmd, ctx);
	cmd(ctx, MBXR_ST, dst_pa, MBXR_ST_FLAT(blocks), 0);
	if (mbxr_lane_err_set(cmd, ctx))
		return MBXR_E_LANE_R_ST;

	mbxr_lane_err_clear(cmd, ctx);
	rc = mbxr_lane_go(which, 1);
	if (rc != MBXR_OK)
		return rc;
	return mbxr_lane_err_set(cmd, ctx) ? MBXR_E_LANE_R_GO : MBXR_OK;
}

/* =============================================================================================
 * ONE SYNCHRONOUS DISPATCH.  Check, fill, wait, name the buffer, arm at the caller's
 * destination, go, wait for ownership, wait for the drain.
 *
 * `cfg_lane` is the lane's OWN configuration -- its table, its K, its word range -- which only
 * the lane's owner can write, so it is a callback rather than a field.  It runs after the fill
 * has landed and before `lgo`, which is where every lane needs it.
 *
 * A CALLER THAT PIPELINES does not use this: it calls the stages, issuing tile N+1's
 * mbxr_lane_fill_start into `!abuf` before tile N's mbxr_lane_go_at, and waits on
 * MBXR_S_FILL at the top and MBXR_S_DRAIN at the bottom rather than MBXR_S_BUSY at both -- a
 * wait on BUSY at the bottom waits for the next tile's fill and un-pipelines the loop.
 * Measured: 3,488 cycles per 8,192-element tile sequential, 2,768 pipelined.
 * ============================================================================================= */
static inline int mbxr_lane_dispatch(mbxr_lane_cmd_fn cmd, void *ctx, const mbxr_lane_plan *p,
				     int (*cfg_lane)(void *), void *cfg_ctx,
				     mbxr_lane_stats *st)
{
	int rc;
	uint64_t np = 0;
	uint32_t s;

	rc = mbxr_lane_check(p);
	if (rc != MBXR_OK) {
		if (st) { st->calls_refused++; st->last_rc = rc; }
		return rc;
	}

	rc = mbxr_lane_fill_start(cmd, ctx, p->src_pa, p->src_blocks, p->abuf);
	if (rc == MBXR_OK)
		rc = mbxr_lane_fence(cmd, ctx, MBXR_S_BUSY, p->budget);
	if (rc == MBXR_OK)
		rc = mbxr_lane_name_buffers(cmd, ctx, p->abuf, 0u);
	if (rc == MBXR_OK && cfg_lane)
		rc = cfg_lane(cfg_ctx);
	if (rc != MBXR_OK) {
		/* NOTHING HAS BEEN ARMED YET.  Every failure above this line leaves the drain
		 * untouched, which is why the descriptor is issued inside mbxr_lane_go_at and not
		 * at the top of the function where "st before lgo" would tempt one to put it. */
		if (st) { st->calls_failed++; st->last_rc = rc; }
		return rc;
	}

	rc = mbxr_lane_go_at(cmd, ctx, p->which, p->dst_pa, p->dst_blocks);
	if (rc != MBXR_OK) {
		if (st) { st->calls_failed++; st->last_rc = rc; }
		return rc;
	}

	rc = mbxr_lane_wait_for(p->which, p->budget, &np, &s);
	if (st) {
		st->polls += np;
		st->last_uerr = MBXR_L_UERR(s);
		st->last_lerr = MBXR_L_LERR(s);
		st->last_aerr = MBXR_L_AERR(s);
	}
	if (rc == MBXR_OK)
		rc = mbxr_lane_fence(cmd, ctx, MBXR_S_BUSY, p->budget);
	/* MAKE A DISPATCH TO ABSENT HARDWARE FAIL LOUDLY.  `lgo` with a selector no lane answers is
	 * not refused -- `lane_go_ok` only checks that nothing is busy -- so ownership is never
	 * taken, `mbxr_lane_wait_for` sees own == 0 and returns OK immediately, and the drain that
	 * was armed for this dispatch never gets its blocks.  ONE ARMED AND UNFED DRAIN POISONS
	 * EVERY LATER DISPATCH IN THE STREAM: 88af508 measured RTF 25.540 against a usual 5.3, and
	 * it passed max_abs_err = 0 because the kernel had fallen back and the arithmetic was
	 * right.  The drain's own acked-block count settles it in one fence read: after a dispatch
	 * that actually ran it equals dst_blocks, and after one that did not it is 0. */
	if (rc == MBXR_OK) {
		uint64_t f = cmd(ctx, MBXR_FENCE, 0, 0, 1);
		if ((int)MBXR_S_ACKED(f) != p->dst_blocks)
			rc = MBXR_E_LANE_NOLANE;
	}
	if (st) {
		st->last_rc = rc;
		if (rc == MBXR_OK)
			st->calls_lane++;
		else
			st->calls_failed++;
	}
	return rc;
}

#endif /* MBXR_LANE_DISPATCH_H */
