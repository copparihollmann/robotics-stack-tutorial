/* SPDX-License-Identifier: Apache-2.0
 *
 * mbxr_b102 -- THE STAGING PIPELINE'S TWO WATERMARKS, as plain data and pure functions.
 *
 * Lab B102.  The convolution kernel gathers the whole [IC][IW] plane before mbxr_rt_run and
 * scatters the whole [OW][OC] plane after it (roccmoon_conv2d_s8_roccmoon_engine.c), and the
 * engine is idle for both -- 9,336,220 cycles of the encoder's steady 83,933,405 on
 * out/b101_lgpw8_0035_f40c (ATTNFUSE, 0x5A5A0035, 40 MHz, NCH = 8).  2,926,685 of that is
 * recoverable by overlapping hart 0's staging with hart 1's dispatch: 0.0183 of RTF_e2e,
 * PROJECTED.
 *
 *   * WHY THIS IS A SEPARATE FILE AND NOTHING INCLUDES IT YET.  The mechanism needs three
 *     hook sites in mbxr_rt.h (below).  mbxr_rt.h is being edited by other labs today, so the
 *     logic lives here where it can be built, tested and reviewed without touching a file
 *     somebody else is in.  THE HOST CHECK BUILDS THIS FILE, NOT A COPY OF IT
 *     (check/b102_pipeline_order.c), so what is gated is what would ship.
 *
 *   * NO NEW INSTRUCTION AND NO HARDWARE CHANGE, and the reason is that neither watermark
 *     reads engine state from the wrong hart:
 *       - the GATHER watermark runs hart 0 -> hart 1 ("staged through byte b") and touches no
 *         engine state at all;
 *       - the DRAIN watermark runs hart 1 -> hart 0 and only REPUBLISHES a fence hart 1
 *         already reads for itself (mbxr.c, `mbxr_wait(dev, MBXR_S_DRAIN | MBXR_S_PIPE, st)`
 *         before each strided `st` is armed).  custom-1 binds on who may ISSUE the fence and
 *         hart 1 is already the issuer.
 *     Coherence needs nothing either: activations and results are on SBUS, through the L2,
 *     which probes hart 0's L1 before serving the fill (ROCC_DECOUPLED.md s1088, s1120 -- and
 *     s1120 makes it an invariant, "stays on SBUS whatever happens").  So bytes hart 0 staged
 *     microseconds earlier are coherent to the fill with no flush and no barrier.
 *
 *   * THERE IS NO DEADLOCK CYCLE, BY ORDERING RATHER THAN BY BUDGET.  Hart 1 waits on the
 *     gather watermark; hart 0 must therefore never wait on hart 1 while it still owes hart 1
 *     staging.  So the kernel's order is: stage EVERYTHING (publishing as it goes, never
 *     blocking), THEN poll the drain watermark for the transpose, THEN mbxr_rt_run_wait().
 *     Hart 0's staging phase is unconditional and bounded; hart 1's wait therefore always
 *     terminates.  The poll budget below is a belt on top of that, not the argument.
 *
 *   * THE DRAIN WATERMARK DEGRADES TO CORRECT-AND-SLOW, NEVER TO WRONG.  It counts `st`
 *     descriptors, which is one per WEIGHT tile only while mbxr_run_to runs weights-outer and
 *     strided; with activations outer it is one per tile PAIR and the count would run ahead of
 *     what has drained.  mbxr_b102_on_st() therefore DISARMS itself the moment the count
 *     exceeds the weight-tile count the caller declared, and hart 0 then transposes everything
 *     after the dispatch -- exactly today's behaviour.  `disarmed` counts it so a run record
 *     shows which path was taken: a kernel that silently stopped pipelining and a kernel that
 *     pipelined are otherwise indistinguishable in any summary, which is the `attn_fallback`
 *     lesson (mbxr_rt.h s72-81) in a second coat.
 *
 * ---- THE THREE HOOK SITES, spelled out so landing this is a diff and not a design ---------
 *
 *   1. mbxr_rt.h, mbxr_rt_cmd(), before the switch:
 *          if (f == MBXR_SD) mbxr_b102_on_sd(&mbxr_b102, a, b);
 *          if (f == MBXR_LD) mbxr_b102_ld_wait(&mbxr_b102, mbxr_rt_cyc);
 *          if (f == MBXR_ST) mbxr_b102_on_st(&mbxr_b102);
 *      All three are no-ops unless a caller has armed the pipeline, so every other dispatch --
 *      every linear, every lane -- is byte-for-byte and cycle-for-cycle what it is today.
 *
 *   2. mbxr_rt.h: mbxr_rt_run_issue()/mbxr_rt_run_wait(), split out of mbxr_rt_run() exactly
 *      as B86d split mbxr_rt_attn_head() (mbxr_rt.h s723-745) -- one code path, the composed
 *      mbxr_rt_run() reimplemented in terms of them so no existing caller changes.  B86d's two
 *      rules apply unchanged and are the reason for the ordering above: mbxr_rt_job is ONE
 *      GLOBAL STRUCT, and hart 1's fill fence is invisible to hart 0.
 *
 *   3. roccmoon_conv2d_s8_roccmoon_engine.c: arm, stage in chunks publishing as it goes,
 *      issue, transpose completed columns while polling, wait, transpose the remainder.
 *
 * ---- THE STAGING EXTENT CONTRACT, FOUND BY THE GATE ON ITS FIRST RUN --------------------
 *
 * `bytes` handed to mbxr_b102_arm() is NOT the plane, and hart 0 must publish only extents it
 * has actually WRITTEN up to.  Two reasons, and the first one hung the gate:
 *
 *   1. THE FILL READS PAST THE PLANE.  act_extent() spans a FULL P-pixel window even on a
 *      short last activation tile -- it uses `pl->P - 1`, not the clamped pixel count -- so
 *      stem.conv1's last source descriptor asks for bytes up to
 *      `(first & ~63) + ceil((first + (P-1)*8*astride + K - (first & ~63)) / 64) * 64`,
 *      which is 64,576 against a 64,000-byte plane: 576 bytes past the end, where the kernel
 *      writes only a 64-byte zero tail.  That is harmless TODAY -- those pixels are past npix
 *      and their outputs are discarded -- but a watermark that stops at the plane makes hart 1
 *      wait for bytes that are never published, and the dispatch stalls out into a fallback.
 *      mbxr_b102_arena() below is the extent to arm with, and hart 0 must zero-fill from the
 *      end of the plane to it.
 *
 *   2. EVERY EXTENT IS BLOCK-ROUNDED.  The source descriptor counts 64-byte BLOCKS, so the
 *      fill's demand is rounded up while a pixel-tile boundary is not.  Hart 0 must therefore
 *      STAGE the rounded extent, never merely claim it -- claiming more than is written is
 *      exactly MBP_B102_POISON 1.
 *
 * ---- WHAT WOULD MAKE THE GATE FAIL -------------------------------------------------------
 *
 * Both hazards are an off-by-one on a watermark, so both poisons are an off-by-one -- the
 * shape the bug would actually take, deterministic on the first pass, and each breaking
 * exactly one of the two contracts:
 *
 *   MBP_B102_POISON 1  mbxr_b102_publish_stage() claims one activation tile more than is
 *                      staged.  Hart 1's fill then reads a tile hart 0 has not written.
 *   MBP_B102_POISON 2  mbxr_b102_tiles_done() claims one weight tile more than has drained.
 *                      Hart 0 then transposes output bytes the drain has not written.
 *
 * Both must read max_abs_err != 0 on the board, as MBP_B86D_POISON 1 and 2 do (142 and 102,
 * out/b86d_pois1 and out/b86d_pois2).  A poison arm that reads max_abs_err 0 is not a poison
 * that failed to bite -- it is an arm built without the poison, which is why the #error below
 * exists and why the arms carry their own configuration into the run record.
 */
#ifndef MBXR_B102_H
#define MBXR_B102_H

#include <stdint.h>

#ifndef MBP_B102
#define MBP_B102 0
#endif
#ifndef MBP_B102_POISON
#define MBP_B102_POISON 0
#endif
#if MBP_B102_POISON && !MBP_B102
#error "MBP_B102_POISON without MBP_B102: an arm named for a poison that is not in the build"
#endif

/* The engine's funct7 codes, repeated rather than included: this header is built on the host
 * by check/b102_pipeline_order.c, where mbxr.h's board types are not wanted.  The three values
 * are asserted against mbxr.h wherever both are in scope (mbxr_rt.h's hook site). */
#define MBXR_B102_F_SD 0
#define MBXR_B102_F_LD 1
#define MBXR_B102_F_ST 5

typedef struct {
	/* hart 0 -> hart 1.  Bytes of the staging arena hart 0 has written, from `in_lo`. */
	uint64_t stage_wm;   /* atomics only; not volatile -- __atomic_* on volatile warns */
	/* hart 1 -> hart 0.  Weight tiles whose drain has landed. */
	uint32_t drain_wm;
	uint64_t in_lo, in_hi;      /* the arena window this dispatch gates */
	uint64_t sd_end;            /* end byte of the last SD, 0 if it was outside the window */
	uint32_t st_seen, tiles_w;  /* `st` descriptors armed, and how many to expect */
	uint32_t npix;              /* rows a WEIGHT-outer strided descriptor must cover */
	uint32_t armed;             /* 1: gate the fill.  2: the drain watermark is live too. */
	uint32_t tile_bytes;        /* one activation tile, for POISON 1 */
	/* counters, because a path that silently stopped being taken must be visible */
	uint64_t ld_gated, ld_spins, st_published, disarmed, stalled;
	/* stalled is CUMULATIVE, for the run record.  stall_now is per dispatch and is what the
	 * kernel reads to decide whether to keep this dispatch's bytes: a convolution that stalled
	 * must fall back even if an EARLIER one did, and a cumulative counter cannot say which. */
	uint32_t stall_now;
} mbxr_b102_t;

/* The largest extent the fill will ever ask for: the last activation tile's full P-pixel
 * window, block-rounded.  `P`, `astride` and `K` are mbxr_run_to's own, and tiles_a is
 * ceil(npix/P).  Hart 0 arms with this and zero-fills the plane's tail up to it. */
static inline uint64_t mbxr_b102_arena(int npix, int P, int astride, int K)
{
	int last = (npix + P - 1) / P - 1;
	uint64_t first = (uint64_t)last * (uint64_t)P * 8ULL * (uint64_t)astride;
	uint64_t end = first + (uint64_t)(P - 1) * 8ULL * (uint64_t)astride + (uint64_t)K;
	uint64_t base = first & ~63ULL;
	return base + ((end - base + 63ULL) / 64ULL) * 64ULL;
}

/* A bound on hart 1's spin.  It is NOT the correctness argument -- the ordering above is --
 * so it is generous; expiry sets `stalled`, which the kernel turns into a fallback. */
#ifndef MBXR_B102_SPIN_CYCLES
#define MBXR_B102_SPIN_CYCLES 200000000ULL
#endif

static inline void mbxr_b102_disarm(mbxr_b102_t *s)
{
	s->armed = 0; s->sd_end = 0;
}

/* Hart 0, before the dispatch is issued.  `bytes` is the whole staged extent; nothing is
 * gated outside [in_pa, in_pa + bytes). */
static inline void mbxr_b102_arm(mbxr_b102_t *s, uint64_t in_pa, uint64_t bytes,
				 uint32_t tiles_w, uint32_t tile_bytes, uint32_t npix)
{
	s->stage_wm = 0; s->drain_wm = 0;
	s->in_lo = in_pa; s->in_hi = in_pa + bytes;
	s->sd_end = 0; s->st_seen = 0; s->tiles_w = tiles_w;
	s->tile_bytes = tile_bytes; s->npix = npix; s->stall_now = 0;
	s->armed = (bytes && tiles_w && npix) ? 2u : 0u;
}

/* Hart 0.  `nbytes` staged so far, from in_lo.  Monotone by construction at the call site. */
static inline void mbxr_b102_publish_stage(mbxr_b102_t *s, uint64_t nbytes)
{
#if MBP_B102_POISON == 1
	/* claim one activation tile more than is staged: hart 1's fill reads ahead of truth */
	nbytes += s->tile_bytes;
#endif
	__atomic_store_n(&s->stage_wm, nbytes, __ATOMIC_RELEASE);
}

/* Hart 0.  Weight tiles whose output columns are complete and safe to transpose. */
static inline uint32_t mbxr_b102_tiles_done(const mbxr_b102_t *s)
{
	uint32_t t = __atomic_load_n(&s->drain_wm, __ATOMIC_ACQUIRE);
#if MBP_B102_POISON == 2
	/* claim one weight tile more than has drained: hart 0 transposes undrained bytes */
	if (t < s->tiles_w) t++;
#endif
	return t;
}

/* Hart 1, inside mbxr_rt_cmd.  Remember the extent of a source descriptor that lands in the
 * gated window; anything else (the weight image, a lane's images) clears it. */
static inline void mbxr_b102_on_sd(mbxr_b102_t *s, uint64_t rs1, uint64_t rs2)
{
	if (!s->armed || rs1 < s->in_lo || rs1 >= s->in_hi) { s->sd_end = 0; return; }
	s->sd_end = rs1 + ((rs2 & 0xffffULL) * 64ULL);
}

/* Hart 1, inside mbxr_rt_cmd, immediately before the load is issued.  Returns 1 if the fill
 * may go, 0 if it stalled out (the kernel then falls back, which is bit-identical). */
static inline int mbxr_b102_ld_wait(mbxr_b102_t *s, uint64_t (*now)(void))
{
	uint64_t need, t0;

	if (!s->armed || !s->sd_end) return 1;
	need = s->sd_end - s->in_lo;
	s->ld_gated++;
	if (__atomic_load_n(&s->stage_wm, __ATOMIC_ACQUIRE) >= need) return 1;
	t0 = now ? now() : 0;
	for (;;) {
		if (__atomic_load_n(&s->stage_wm, __ATOMIC_ACQUIRE) >= need) return 1;
		s->ld_spins++;
		if (now && now() - t0 > MBXR_B102_SPIN_CYCLES) {
			s->stalled++; s->stall_now = 1; return 0;
		}
	}
}

/* Hart 1, inside mbxr_rt_cmd, as each `st` descriptor is armed.  mbxr_run_to arms the k-th one
 * only AFTER waiting out the (k-1)-th weight tile's drain, so k-1 tiles are complete then --
 * BUT ONLY WHEN THE WEIGHTS ARE THE OUTER LOOP.  With the activations outer, `st` is armed once
 * per tile PAIR and covers `pa_` rows rather than all `npix`, so "the k-th st implies k-1 whole
 * weight tiles" is FALSE and hart 0 would transpose rows the drain has not written.
 *
 * THE GUARD READS THE DESCRIPTOR RATHER THAN RE-DERIVING mbxr_run_to's CHOICE.  `st`'s rs2 is
 * {row_stride[63:32], row_bytes[31:16], nrows[15:0]} (mbxr.h), and mbxr_run_to passes
 * `nr = w_outer ? npix : pa_`.  So a descriptor that does not cover every pixel is not the
 * weight-outer case and the drain watermark disarms -- as does the flat drain, whose rs2[15:0]
 * is a BLOCK count and will not equal npix except by coincidence, and a coincidence there is
 * still only a claim that all npix rows are drained, which for the flat drain they are not.
 * Replicating `w_outer` in the kernel would have been the same number computed in two places,
 * which is how the loop order got away from me in the first place. */
static inline void mbxr_b102_on_st(mbxr_b102_t *s, uint64_t rs2)
{
	if (s->armed < 2u) return;
	if ((uint32_t)(rs2 & 0xffffULL) != s->npix) {   /* not a weight-outer full-column drain */
		s->disarmed++;
		s->armed = 1u;
		__atomic_store_n(&s->drain_wm, 0u, __ATOMIC_RELEASE);
		return;
	}
	s->st_seen++;
	if (s->st_seen > s->tiles_w) {      /* not one `st` per weight tile: stop trusting it */
		s->disarmed++;
		s->armed = 1u;                  /* the fill gate stays; the drain watermark does not */
		__atomic_store_n(&s->drain_wm, 0u, __ATOMIC_RELEASE);
		return;
	}
	__atomic_store_n(&s->drain_wm, s->st_seen - 1u, __ATOMIC_RELEASE);
	s->st_published++;
}

/* Hart 0, after mbxr_rt_run_wait returns MBXR_OK: every tile has drained. */
static inline void mbxr_b102_finish(mbxr_b102_t *s)
{
	__atomic_store_n(&s->drain_wm, s->tiles_w, __ATOMIC_RELEASE);
	mbxr_b102_disarm(s);
}

#endif /* MBXR_B102_H */
