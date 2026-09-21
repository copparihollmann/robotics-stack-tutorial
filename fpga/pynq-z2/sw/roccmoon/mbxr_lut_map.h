/* SPDX-License-Identifier: Apache-2.0
 *
 * mbxr_lut_map.h -- the plan, the counters and the tile loop shared by every kernel that
 * is a 256-entry int8 -> int8 POINTWISE MAP on T4's LUT lane.
 *
 * ONE KERNEL CANNOT SERVE BOTH `gelu_s8` AND `tanh_s8`, AND THE REASON IS THE TABLE, NOT THE
 * LANE.  ModelBlaster selects a kernel per op and each entry point has the op's own name, so
 * there are two files; and their table builders are genuinely different arithmetic --
 * `gelu_s8`'s curated kernel is `pext_int_lut`, integer throughout, with a public builder
 * (`int_gelu_s8_table`), while `tanh_s8`'s is `pext_memo_lut` and evaluates `tanhf`/`roundf`
 * in float.  Each lane kernel must match ITS OWN curated kernel bit for bit, so the builders
 * cannot be shared.  EVERYTHING ELSE CAN, and everything else is what this file is: the plan,
 * the dispatch, the counters, the fallback structure.  `silu_s8` on the decoder is the same
 * shape again and needs only a third builder.
 *
 * Everything about WHY the plan is shaped this way is in the gelu kernel's header and in
 * docs/LANE_DISPATCH_RULES.md; this file is the mechanism.
 *
 * IT LIVES IN sw/roccmoon/ RATHER THAN BESIDE THE KERNELS, and that is a build fact rather
 * than a taxonomy one: ModelBlaster's codegen COPIES a curated kernel's text into the
 * generated kernels.c and compiles that from the gen directory, so a `#include` relative to
 * the kernel's own directory does not resolve.  Everything a curated kernel includes has to
 * be reachable as `roccmoon/...` under -I sw, which is where mbxr_lanes.h and
 * mbxr_lane_dispatch.h already are.
 */
#ifndef MBXR_LUT_MAP_H
#define MBXR_LUT_MAP_H

#include <stddef.h>
#include <stdint.h>

/* mbxr_lanes.h and the shared dispatch path compile on the HOST too, and that is deliberate
 * rather than incidental: the plan below and the precondition matrix it is checked against are
 * the two things that stand between these kernels and a hang, and a predicate compiled only
 * for the target is a predicate nobody tests.  Only the hart-1 worker is target-only. */
#include "roccmoon/mbxr_lanes.h"
#include "roccmoon/mbxr_lane_dispatch.h"
#if defined(__ZEPHYR__)
#include "roccmoon/mbxr_rt.h"
#endif

/* THE A/B SWITCH.  -DMBXR_LUT_LANE=0 forces the fallback, so the two arms of a board
 * comparison differ in exactly one define and in nothing else, and the lane-off arm is the
 * known-answer control: it runs the curated kernel, which is what Lab B30 measured for this op
 * at 19.34 cycles/element, so it must reproduce that rate.  Two arms wrong in the same way is
 * the failure a control exists to catch.
 *
 * DEFAULT 1, AND THE POLARITY IS DELIBERATE.  88af508 recorded that "the safe configuration
 * must be requested and the dangerous one is free" was the wrong way round -- but that was
 * dangerous only because a dispatch to absent hardware was SILENT.  It is not silent here:
 * mbxr_lane_dispatch checks the drain's own acked-block count after every dispatch and returns
 * MBXR_E_LANE_NOLANE when the drain moved nothing, which is exactly what `lgo` to a bitstream
 * without this lane produces.  The first tile fails, the counter records it, and the operator
 * falls back -- instead of one armed and unfed drain poisoning the rest of the run. */
#ifndef MBXR_LUT_LANE
#define MBXR_LUT_LANE 1
#endif

/* ---- the counters, and they exist BEFORE the first board run ---------------------------------
 * A fallback that produces correct results is indistinguishable from success by any correctness
 * check, because the fallback IS the specification: the attention lane passed 117/117 with
 * max_abs_err = 0 entirely through its fallback (60bd85d).  Only a counter of which path
 * executed can tell them apart.  External so a harness can read them without this file knowing
 * about the harness. */
typedef struct {
	uint32_t calls;             /* kernel entries                                  */
	uint32_t calls_lane;        /* operators served by the lane, end to end                */
	uint32_t calls_fallback;    /* operators that fell back, for any reason                */
	uint32_t tiles_lane;        /* lane dispatches that completed                          */
	uint32_t elems_lane;        /* elements the lane produced                              */
	uint32_t elems_scalar;      /* elements the head/tail produced on the core             */
	uint32_t tiles_copied;      /* tiles that needed a copy-out.  MUST STAY 0: see s1 above */
	int32_t  last_rc;
	uint32_t last_uerr;
} mbxr_lut_stats_t;
mbxr_lut_stats_t mbxr_lut_stats;

/* ---- the plan, computed without issuing anything ---------------------------------------------
 * Exposed and host-testable, because the refusals are what stand between a kernel and a hang. */
typedef struct {
	int ok;            /* 0 => fall back, and `why` says which rule                        */
	int why;           /* an MBXR_E_* code, or MBXR_OK                                     */
	int head;          /* elements done on the core before the first tile                  */
	int tail;          /* elements done on the core after the last                         */
	int skew_w;        /* words the fill's first block is ahead of the tile's first byte    */
	int tile_w_max;    /* the largest tile this alignment allows, in words                  */
	int tiles;         /* lane dispatches the middle will take                              */
	long mid_bytes;    /* elements the lane will produce                                    */
} mbxr_lut_plan_t;

#define MBXR_LUT_BLK   64            /* the drain's block, and the fill's alignment           */
#define MBXR_LUT_BUF_W 1024          /* one activation buffer                                 */

static mbxr_lut_plan_t mbxr_lut_plan(const int8_t *in, const int8_t *out, int n)
{
	mbxr_lut_plan_t p;
	long rem;

	p.ok = 0; p.why = MBXR_OK; p.head = 0; p.tail = 0;
	p.skew_w = 0; p.tile_w_max = 0; p.tiles = 0; p.mid_bytes = 0;

	if (n <= 0 || !in || !out) { p.why = MBXR_E_SHAPE; return p; }

	/* THE FILL HAS NO BYTE FUNNEL, so the tile's first byte must sit a whole number of WORDS
	 * into its 64-byte block.  Every intermediate this generator emits is 8-byte aligned; one
	 * that is not falls back rather than reading its neighbours' bytes as data. */
	if (((uintptr_t)in & 7u) || ((uintptr_t)out & 7u)) { p.why = MBXR_E_ALIGN; return p; }

	p.head = (int)((-(uintptr_t)out) & (MBXR_LUT_BLK - 1));
	if (p.head > n) p.head = n;

	/* the skew is constant across tiles: the stride is a multiple of 64 */
	p.skew_w = (int)(((uintptr_t)in + (uintptr_t)p.head) & (MBXR_LUT_BLK - 1)) / 8;
	p.tile_w_max = (MBXR_LUT_BUF_W - p.skew_w) & ~7;      /* and a multiple of 8 words */
	if (p.tile_w_max <= 0) { p.why = MBXR_E_SHAPE; return p; }

	rem = (long)n - (long)p.head;
	p.mid_bytes = (rem / MBXR_LUT_BLK) * MBXR_LUT_BLK;    /* whole blocks only */
	p.tail = (int)(rem - p.mid_bytes);
	if (p.mid_bytes <= 0) { p.why = MBXR_E_SHAPE; return p; }   /* not worth a dispatch */

	{
		long left = p.mid_bytes;
		long step = (long)p.tile_w_max * 8;

		while (left > 0) { long t = left < step ? left : step; left -= t; p.tiles++; }
	}
	p.ok = 1;
	return p;
}

/* the scalar ends, and they use THE SAME TABLE the lane does -- not a re-derivation */
__attribute__((unused))
static void mbxr_lut_scalar(const int8_t *in, int8_t *out, int n, const int8_t tbl[256])
{
	for (int i = 0; i < n; i++)
		out[i] = tbl[(uint8_t)((int)in[i] + 128)];
}

/* the per-tile `lcfg` callback lives in mbxr_rt.h beside the worker that issues it: it is
 * custom-1, so only hart 1 may run it, and that file owns that hart. */

/* ONE OPERATOR ON THE LANE, given a table somebody else built.  Returns 1 if the whole tensor
 * was produced, 0 if the caller must run its fallback over the WHOLE tensor -- a partial
 * operator is not a result, and a tensor that is right in its first tiles and stale in the rest
 * reads downstream as a model-accuracy problem rather than as a dispatch failure. */
__attribute__((unused))
static int mbxr_lut_map_op_seen(const int8_t *in, int8_t *out, int n, const int8_t tbl[256],
				const uint8_t *seen)
{
#if defined(__ZEPHYR__) && MBXR_LUT_LANE && defined(MBXR_RT_OP_LUT)
	mbxr_lut_plan_t pl = mbxr_lut_plan(in, out, n);
	long off, left;

	if (!pl.ok || !mbxr_rt_available())
		return 0;

	mbxr_lut_scalar(in, out, pl.head, tbl);
	mbxr_lut_stats.elems_scalar += (uint32_t)pl.head;

	/* ============================================================================
	 * THE TABLE IS REORDERED FOR THE LANE, AND THIS COST A BOARD ARM.
	 *
	 * Software and hardware index the same 256 entries DIFFERENTLY and neither is
	 * wrong.  int_nonlin.c stores the table +128-BIASED -- `tbl[(uint8_t)(q + 128)]`
	 * at :378, read back as `tbl[(uint8_t)(x + 128)]` at :419 -- so entry 0 is the
	 * value for x = -128.  `mbxl_lut` indexes by the RAW BYTE: `tbl[rd_data[8*g +:
	 * 8]]` (mbxl_lut.v:125), so its entry 0 is the value for x = 0.  The two orders
	 * differ by XOR 0x80 on the index.
	 *
	 * Lab B42 arm B dispatched with the software order and the lane ran perfectly
	 * over the wrong entries: gelu_s8 19.34 -> 2.02 cycles/element, tanh_s8 22.83 ->
	 * 15.32, 129 of 129 dispatches profiled, engine 0 fallbacks -- and
	 * max_abs_err = 80.  A plausible number over rotated data.
	 *
	 * WHY NOTHING CAUGHT IT.  tb_lut.cpp and tb_lutint.cpp build their table with
	 * raw-byte indexing on BOTH sides, so the convention cancels and 187,904 byte
	 * checks agree.  The host check compared the table's CONTENTS against the
	 * curated kernel's and never modelled the hardware's INDEXING.  That is arm A's
	 * lesson one layer up: a gate that models its sink passes against the model.
	 * gelu_lane_check.c now applies the table the way the RTL applies it.
	 * ============================================================================ */
	{
		int8_t hw[256];

		for (int i = 0; i < 256; i++)
			hw[i] = tbl[(uint8_t)(i ^ 0x80)];
		if (mbxr_rt_lut_table(hw, seen) != MBXR_OK)
			return 0;
	}

	off = pl.head; left = pl.mid_bytes;
	while (left > 0) {
		long t = left < (long)pl.tile_w_max * 8 ? left : (long)pl.tile_w_max * 8;
		/* THE FILL'S SOURCE IS THE CONTAINING 64-BYTE BLOCK, and `skew_w` is how far into
		 * it the tile starts.  Handing the unmasked address AND the skew would count the
		 * skew twice; mbxr_lane_check refuses a misaligned src_pa, so it showed up as a
		 * silent fallback rather than as wrong data -- but it is still wrong. */
		int rc = mbxr_rt_lut_tile(((uint64_t)(uintptr_t)(in + off)) & ~(uint64_t)63,
					  pl.skew_w, (int)(t / 8),
					  (uint64_t)(uintptr_t)(out + off));

		mbxr_lut_stats.last_rc = rc;
		if (rc != MBXR_OK)
			return 0;
		mbxr_lut_stats.tiles_lane++;
		mbxr_lut_stats.elems_lane += (uint32_t)t;
		off += t; left -= t;
	}
	mbxr_lut_scalar(in + off, out + off, pl.tail, tbl);
	mbxr_lut_stats.elems_scalar += (uint32_t)pl.tail;
	return 1;
#else
	(void)in; (void)out; (void)n; (void)tbl; (void)seen;
	return 0;
#endif
}

/* the whole-table spelling, for callers that build all 256 (gelu_s8, tanh_s8) */
__attribute__((unused))
static int mbxr_lut_map_op(const int8_t *in, int8_t *out, int n, const int8_t tbl[256])
{
	return mbxr_lut_map_op_seen(in, out, n, tbl, NULL);
}

#endif /* MBXR_LUT_MAP_H */
