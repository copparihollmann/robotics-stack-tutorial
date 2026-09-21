/* SPDX-License-Identifier: Apache-2.0
 *
 * mbxr_rt -- what a ModelBlaster kernel on hart 0 needs to use the engine on hart 1.
 *
 * Header-only and include-guarded, because ModelBlaster concatenates every picked kernel
 * into one kernels.c: the linear and the convolution kernel both include this, and it lands
 * in that translation unit once.
 *
 *   * THE HAND-OFF.  The engine is a RoCC in hart 1's tile, so its commands can only be issued
 *     from hart 1.  A kernel on hart 0 fills a job, gives a semaphore to a worker pinned to
 *     CPU 1, and SPINS on an atomic flag until the worker is done.  Spinning rather than
 *     blocking is deliberate: the board harness runs each inference under irq_lock, and a
 *     wall-clock cycle count on hart 0 then includes the whole hand-off and nothing else.
 *
 *   * THE WEIGHT IMAGE, built once per layer on first use and cached by (the address of the
 *     model's own weight array, kind, N, padded K): planar, bias word first, rows padded to a
 *     multiple of 8.  The harness's warm-up inference pays for it; the measured ones do not,
 *     and the cost is counted separately (mbxr_rt_stats.image_cycles).  A model's weights are
 *     const, so the address names them; a caller that rewrites weights in place (a test)
 *     calls mbxr_rt_forget() first.  Lab B25 run 7 keyed on (address, kind) alone, reused
 *     one weight buffer for three convolutions, and got stem_conv1's image for stem_conv2.
 *
 *     COHERENCE.  The image is written by hart 0 through its L1, so it is dirty in the L1 and
 *     L2 until they write it back.  The weight client reads it through SBUS -- through the L2,
 *     which probes hart 0's L1 for any line it holds -- so this is correct as built.  It is
 *     NOT correct for an MBUS weight client (TODO.md item 13): that client bypasses the L2 and
 *     would read stale DRAM.  An MBUS build needs the image produced offline (baked into
 *     weights.c, loaded by the PS before reset) or flushed through the L2 first.
 *
 *   * STAGING.  Inputs that are not 8-byte aligned, or whose rows are not a multiple of 8
 *     bytes, and convolution inputs that are NCHW rather than window-contiguous, are copied
 *     into an aligned staging buffer first; outputs of a convolution are transposed back.
 *     Every such copy is on hart 0, inside the measured window, and counted.
 *
 * On anything but the board (no __ZEPHYR__) mbxr_rt_available() is 0 and the kernels take
 * their fallback, which is the curated MBP kernel -- so ModelBlaster's host verification
 * checks the fallback, and tb_mbxr.cpp and the board check the engine.
 */
#ifndef MBXR_RT_H
#define MBXR_RT_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
	uint64_t calls_engine, calls_fallback;
	uint64_t cycles_h0;        /* hart-0 wall cycles inside engine calls, hand-off included */
	uint64_t cycles_h1;        /* hart-1 cycles inside mbxr_run                            */
	uint64_t cycles_stage;     /* hart-0 cycles spent staging and transposing              */
	uint64_t cycles_stage_in;  /* of cycles_stage, the INPUT gather half.  Strictly additive:
	                              cycles_stage keeps its meaning, so nothing that reads it
	                              changes.  Split because Lab B30 priced a gather-reuse lever
	                              on the ASSUMPTION that a gather element costs the same as a
	                              scatter element, and that assumption is worth a measurement
	                              rather than a range (Q16_BOARD_PROFILE.md s3.3).          */
	uint64_t image_cycles;     /* one-time image builds                                    */
	uint64_t image_bytes;
	uint64_t loads_act, loads_wgt, bytes_act, bytes_wgt, pairs, polls;
	uint64_t fill_beats, cyc_fill;
	/* THE ENGINE'S OWN COMPUTE AND OVERLAP COUNTERS.  cyc_fill alone cannot say whether the
	 * fill and the tile sequencer ran at the same time, so `compute` was a MODELLED quantity
	 * in the anatomy that priced this engine (ENGINE_WAIT_ANATOMY.md).  These three make it
	 * measured: serialisation reads cyc_busy == cyc_fill + cyc_tseq, overlap reads
	 * cyc_busy == max(cyc_fill, cyc_tseq).  Three extra STAT reads per dispatch. */
	uint64_t cyc_tseq, cyc_busy, steps;
	uint64_t cyc_wait, cyc_place;  /* hart-1 cycles polling the fence, and placing results  */
	uint64_t placed_early;     /* result bytes placed while the engine ran (MBXR_RT_PLACE_EARLY) */
	uint64_t kicks;            /* hand-offs the worker had not picked up after ~1 s, re-given */
	uint64_t giveups;          /* hand-offs abandoned after ~60 s: the runtime then disables  */
	uint64_t last_status;      /* the engine's last fence word, from the worker               */
	int      last_rc;
	/* THE ATTENTION LANE'S OWN COUNTERS.  A kernel that falls back silently is
	 * indistinguishable in every summary from one that ran fast -- the same polarity
	 * problem as `max_abs_err = 0` meaning "nothing was compared".  Lab B30 measured an
	 * attention_s8 at the reference's own cost and only the cycle count said it had never
	 * reached the lane.  attn_lane counts dispatches that DID, attn_fallback those that did
	 * not, and attn_last_rc says why. */
	uint64_t attn_lane, attn_fallback, attn_fence_polls, attn_lane_polls;
	uint64_t attn_fence_cyc, attn_wait_cyc;
	int      attn_last_rc;
	uint32_t attn_aerr;
	int      cap_asked;        /* outstanding-Get cap this image asked for (MBXR_RT_CAP)      */
	/* WHAT THE SILICON SAYS IT IS.  The engine publishes its own geometry in MBXR_C_ID
	 * (mbxr.h, MBXR_ID_NCH).  Until 2026-09-19 the runtime parsed that word for its
	 * signature only and discarded the width, so an NCH = 8 bitstream was indistinguishable
	 * from an NCH = 4 one to the software -- and the mismatch could only present as
	 * MBXR_E_TIMEOUT after 20 M polls, which is what 0x5A5A0033 did for 4,125 consecutive
	 * dispatches on garden.  engine_nch is read ONCE on hart 1 and compared with MBXR_NCH;
	 * engine_id is kept raw so a run record can show the whole word. */
	uint64_t engine_id;
	uint32_t engine_nch;       /* the engine's NCH; 0 until the worker has started          */
	int      width_ok;         /* 1 engine_nch == MBXR_NCH, 0 not checked yet, -1 MISMATCH  */
	/* THE SUB-BYTE WEIGHT GRID.  wpack_rows counts weight rows written as 6-bit codes;
	 * wpack_clipped counts CODES that did not fit [-31, 31] and were therefore truncated.
	 * It exists so the two ways an int6 arm can be wrong stay distinguishable: a guest built
	 * -DMBXR_RT_WBITS=6 against an int8 IR clips and reads non-zero here, and an unpacker
	 * defect reads ZERO here and still gets the wrong bytes.  Without it both look the same
	 * in a summary, which is the `max_abs_err = 0 means nothing was compared` failure in a
	 * different coat. */
	uint64_t wpack_rows, wpack_clipped;
} mbxr_rt_stats_t;

/* MBXR_RT_TYPES_ONLY: a caller that only reads mbxr_rt_stats (a harness printing it) gets the
 * type without a second copy of the runtime. */
#if defined(MBXR_RT_TYPES_ONLY)
extern mbxr_rt_stats_t mbxr_rt_stats;
void mbxr_rt_forget(void);
#elif defined(__ZEPHYR__)

#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>
#include "roccmoon/mbxr.h"
#include "roccmoon/mbxr.c"
#include "roccmoon/mbxr_lanes.h"
#include "roccmoon/mbxr_b102.h"
/* header-only `static inline`s; with MBXR_RT_LUT off nothing references them and the
 * compiler emits none, which the byte-identity check below confirms. */
#include "roccmoon/mbxr_lane_dispatch.h"

/* The same bound the fence uses, for the same reason: a lane that never returns ownership must
 * come back as a return code rather than spin hart 1 forever. */
#ifndef MBXR_RT_LANE_POLLS
#define MBXR_RT_LANE_POLLS 20000000ULL
#endif

mbxr_rt_stats_t mbxr_rt_stats;

/* ---- physical windows, far above any ModelBlaster image (256 MB of DRAM at 0x8000_0000) --- */
#define MBXR_RT_IMG_BASE   0x88000000UL   /* 64 MB of cached planar weight images */
#define MBXR_RT_IMG_END    0x8C000000UL
#define MBXR_RT_IN_STAGE   0x8C000000UL   /* 8 MB */
#define MBXR_RT_SCRATCH    0x8C800000UL   /* 8 MB: the drain's destination */
#define MBXR_RT_OUT_STAGE  0x8D000000UL   /* 8 MB */
#define MBXR_RT_ROW_STAGE  0x8D800000UL   /* 8 MB: padded weight rows while an image is built */
#define MBXR_RT_MIN_MACS   16384          /* below this the hand-off costs more than it saves */

/* custom-1 stubs: rs1 = a0, rs2 = a1; funct3 011 sends, 111 also replies into a0 */
__asm__(".pushsection .text.mbxr_rt, \"ax\", @progbits\n"
	".balign 4\n"
	"mbxr_rt_c0: .insn r 0x2B, 3, 0, x0, a0, a1\n ret\n"
	"mbxr_rt_c1: .insn r 0x2B, 3, 1, x0, a0, a1\n ret\n"
	"mbxr_rt_c2: .insn r 0x2B, 3, 2, x0, a0, a1\n ret\n"
	"mbxr_rt_c3: .insn r 0x2B, 3, 3, x0, a0, a1\n ret\n"
	"mbxr_rt_c4: .insn r 0x2B, 3, 4, x0, a0, a1\n ret\n"
	"mbxr_rt_c5: .insn r 0x2B, 3, 5, x0, a0, a1\n ret\n"
	"mbxr_rt_c6: .insn r 0x2B, 7, 6, a0, a0, a1\n ret\n"
	"mbxr_rt_c7: .insn r 0x2B, 7, 7, a0, a0, a1\n ret\n"
	"mbxr_rt_c8: .insn r 0x2B, 3, 8, x0, a0, a1\n ret\n"
	".popsection\n");
extern uint64_t mbxr_rt_c0(uint64_t, uint64_t) __asm__("mbxr_rt_c0");
extern uint64_t mbxr_rt_c1(uint64_t, uint64_t) __asm__("mbxr_rt_c1");
extern uint64_t mbxr_rt_c2(uint64_t, uint64_t) __asm__("mbxr_rt_c2");
extern uint64_t mbxr_rt_c3(uint64_t, uint64_t) __asm__("mbxr_rt_c3");
extern uint64_t mbxr_rt_c4(uint64_t, uint64_t) __asm__("mbxr_rt_c4");
extern uint64_t mbxr_rt_c5(uint64_t, uint64_t) __asm__("mbxr_rt_c5");
extern uint64_t mbxr_rt_c6(uint64_t, uint64_t) __asm__("mbxr_rt_c6");
extern uint64_t mbxr_rt_c7(uint64_t, uint64_t) __asm__("mbxr_rt_c7");
extern uint64_t mbxr_rt_c8(uint64_t, uint64_t) __asm__("mbxr_rt_c8");

/* B102 -- THE STAGING PIPELINE'S TWO WATERMARKS.  Every RoCC command hart 1 issues passes
 * through mbxr_rt_cmd(), which makes it the one place a gather watermark can gate a fill and a
 * drain watermark can be published, WITHOUT touching mbxr.h or mbxr.c: run_compat_tb.sh's exact
 * Gets/Puts/cycles are therefore untouched by construction, not by argument.  All three hooks
 * are no-ops until a caller arms the pipeline, so every linear and every lane dispatch is the
 * machine it is today.  See mbxr_b102.h for the contract and the two poison arms. */
#if MBP_B102
static inline uint64_t mbxr_rt_cyc(void);          /* defined below; the spin's bound */
static mbxr_b102_t mbxr_b102;
static uint64_t mbxr_b102_now(void) { return mbxr_rt_cyc(); }
/* The funct7 codes mbxr_b102.h repeats for the host build must be mbxr.h's own. */
_Static_assert(MBXR_B102_F_SD == MBXR_SD, "B102 SD code drifted from mbxr.h");
_Static_assert(MBXR_B102_F_LD == MBXR_LD, "B102 LD code drifted from mbxr.h");
_Static_assert(MBXR_B102_F_ST == MBXR_ST, "B102 ST code drifted from mbxr.h");
_Static_assert(MBXR_E_TIMEOUT < 0, "mbxr_rt_run_poll returns 1/0/MBXR_E_TIMEOUT: it must not collide");
#endif

static uint64_t mbxr_rt_cmd(void *ctx, unsigned f, uint64_t a, uint64_t b, int xd)
{
	(void)ctx; (void)xd;
#if MBP_B102
	if (mbxr_b102.armed) {
		if (f == MBXR_SD) mbxr_b102_on_sd(&mbxr_b102, a, b);
		else if (f == MBXR_LD) {
			if (!mbxr_b102_ld_wait(&mbxr_b102, mbxr_b102_now)) {
				/* hart 0 never published the bytes this fill needs.  Refusing the
				 * load would leave the engine mid-dispatch, so the load goes and
				 * `stalled` is what the kernel reads afterwards to fall back --
				 * bit-identically, through the curated convolution. */
				mbxr_b102_disarm(&mbxr_b102);
			}
		} else if (f == MBXR_ST) mbxr_b102_on_st(&mbxr_b102, b);
	}
#endif
	switch (f) {
	case 0: return mbxr_rt_c0(a, b);
	case 1: return mbxr_rt_c1(a, b);
	case 2: return mbxr_rt_c2(a, b);
	case 3: return mbxr_rt_c3(a, b);
	case 4: return mbxr_rt_c4(a, b);
	case 5: return mbxr_rt_c5(a, b);
	case 6: return mbxr_rt_c6(a, b);
	case 7: return mbxr_rt_c7(a, b);
	case 8: return mbxr_rt_c8(a, b);
	}
	return ~0ULL;
}
static void *mbxr_rt_p2v(void *ctx, uint64_t pa) { (void)ctx; return (void *)(uintptr_t)pa; }
/* A bound on fence polls, so an engine that never finishes returns MBXR_E_TIMEOUT to the
 * kernel (which then falls back) instead of spinning both harts forever.  The longest dispatch
 * Moonshine makes is about 5 M cycles; 20 M polls is several hundred million. */
static uint64_t mbxr_rt_now(void *ctx);
/* MBXR_RT_PLACE_EARLY=1 (a kernel cflag): incremental placement, mbxr.c.  Default off, as
 * Labs B25 and B26 measured the runtime. */
#ifndef MBXR_RT_PLACE_EARLY
#define MBXR_RT_PLACE_EARLY 0
#endif
#ifndef MBXR_RT_LANE_WAIT
#define MBXR_RT_LANE_WAIT 0        /* revision 2b builds: e.g. 2000000 fence polls */
#endif
/* MBXR_RT_DRAIN_STRIDED=1 (a kernel cflag): THE 2-D DRAIN.  The engine Puts each weight tile's
 * results straight into their rows of out[npix][N] and hart 1 does no placement at all --
 * `cyc_place` goes to zero and `place_chunk`/`place_early` become dead.  It needs an engine
 * whose id word reads 'MS' (mbxr.h, MBXR_ID_STRIDE); on an older engine mbxr_rt_drain_strided()
 * reads 0 and every dispatch takes the flat drain and places, exactly as measured.  Weight
 * images are planned to match (quads per tile rounded down to even), so this flag must be set
 * before the first image is built -- it is a compile-time constant for that reason. */
#ifndef MBXR_RT_DRAIN_STRIDED
#define MBXR_RT_DRAIN_STRIDED 0
#endif
/* MBXR_RT_CAP: the engine's outstanding-Get cap, asked for once on hart 1 before the first job
 * (custom-1 exists only there).  The engine's RESET default is 3.
 *
 *   4 on a build that carries patch 0092 (skip clean Release).  Lab B25's port sweep on
 *     0x5A5A0028: 2.152 / 4.281 / 6.300 / 7.342 / 7.346 / 7.344 B per cycle at caps
 *     1 / 2 / 3 / 4 / 6 / 8.  Four is +16.5 % over the reset default and is the plateau.
 *   3 on a build WITHOUT 0092 -- 0x5A5A0010, 0011, 0012, 001E.  There the same sweep DIPS at
 *     four in flight (MEMORY_BANDWIDTH.md s6: the cork answers Releases on the data channel,
 *     so ReleaseAcks starve and Acquires bunch).  Build those images with -DMBXR_RT_CAP=3.
 *
 * Nothing in the fence or the id word reports the cap back, so software cannot check it; what
 * checks it is tb_mbxr's cap case, which samples every cycle of a real dispatch and fails if the
 * fill ever exceeds the cap or never reaches it.  That case runs in every build's gate. */
#ifndef MBXR_RT_CAP
#define MBXR_RT_CAP 4
#endif
#if MBXR_RT_CAP < 1 || MBXR_RT_CAP > 4
#error "MBXR_RT_CAP must be 1..4: the fill has LDEPTH = 4 source IDs"
#endif
/* What this image speaks, where scripts/lib/mbxr_abi.sh can find it without running anything. */
MBXR_ABI_STAMP(mbxr_rt_abi_stamp, MBXR_RT_DRAIN_STRIDED);

static const mbxr_dev mbxr_rt_dev = { mbxr_rt_cmd, mbxr_rt_p2v, NULL, 20000000, mbxr_rt_now, 1,
				      MBXR_RT_PLACE_EARLY, MBXR_RT_LANE_WAIT,
				      MBXR_RT_DRAIN_STRIDED };

/* The same device with the 2-D drain switched off, for a build whose flag says strided but
 * whose SILICON does not have the descriptor.  Rounding the quads per tile down to even is a
 * legal plan for the flat drain too -- it is a different tiling, not a different answer -- so
 * falling back here is safe with images already built.  The id is asked ON HART 1, once,
 * because a `stat` is a custom-1 instruction and hart 0 would trap on it. */
static const mbxr_dev mbxr_rt_dev_flat = { mbxr_rt_cmd, mbxr_rt_p2v, NULL, 20000000, mbxr_rt_now,
					   1, MBXR_RT_PLACE_EARLY, MBXR_RT_LANE_WAIT, 0 };
static int mbxr_rt_strided_ok = -1;
static const mbxr_dev *mbxr_rt_pick(void)
{
	if (!MBXR_RT_DRAIN_STRIDED) return &mbxr_rt_dev;
	if (mbxr_rt_strided_ok < 0)
		mbxr_rt_strided_ok =
			MBXR_ID_SIG(mbxr_rt_cmd(NULL, MBXR_STAT, MBXR_C_ID, 0, 1)) == MBXR_ID_STRIDE;
	return mbxr_rt_strided_ok ? &mbxr_rt_dev : &mbxr_rt_dev_flat;
}

static inline uint64_t mbxr_rt_cyc(void)
{
	uint64_t c;
	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}
static uint64_t mbxr_rt_now(void *ctx) { (void)ctx; return mbxr_rt_cyc(); }

/* ---- the worker ------------------------------------------------------------------------- */
#define MBXR_RT_STACK 4096
K_THREAD_STACK_DEFINE(mbxr_rt_stack, MBXR_RT_STACK);
static struct k_thread mbxr_rt_thread;
static struct k_sem mbxr_rt_go;
static atomic_t mbxr_rt_done;
static atomic_t mbxr_rt_seq, mbxr_rt_started_seq;    /* job numbers: posted, and picked up */
static int mbxr_rt_state;    /* 0 = not started, 1 = running, -1 = unavailable */
#define MBXR_RT_KICK_CYCLES    35000000ULL      /* ~1 s at 34.48 MHz */
#define MBXR_RT_GIVEUP_CYCLES  2000000000ULL    /* ~58 s */

/* op 0 is the engine dispatch this runtime was written for; op 1 is a LANE dispatch, which
 * needs the same hart-1 hand-off for the same reason (custom-1 is in hart 1's tile) and none of
 * the weight-image machinery. */
#define MBXR_RT_OP_ENGINE  0
#define MBXR_RT_OP_LANE    1
#define MBXR_RT_OP_ATTN    2
/* op 3: one tile on T4's LUT lane (`mbxl_lut`).  The same hart-1 hand-off for the same reason
 * -- custom-1 is in hart 1's tile -- and, like the LayerNorm lane's affine table and the
 * attention unit's softmax table, THE 256-ENTRY TABLE TRAVELS WITH THE JOB because its `lcfg`
 * writes are custom-1 too.  It is written ONCE PER OPERATOR rather than per tile: 256 writes
 * at a measured 20-22 cycles is 1.9x a tile's own cost and 0.02 % of the operator's. */
/* GUARDED, AND THE GUARD IS THE POINT.  Measured while landing this: adding the arm below to
 * `mbxr_rt_worker` unguarded grew that function from 863 to 1,120 instructions and made the
 * compiler re-allocate registers across ALL of it -- so every image in the tree, including one
 * mid-A/B on another workstream, would have differed in the code that dispatches its lane.
 * Behaviourally additive is not the same as byte-identical, and an A/B whose two sides were
 * built across that boundary is not that A/B.  With the guard off, an image that does not ask
 * for this lane compiles to exactly the bytes it did before -- verified by diffing the whole
 * .text of the attention workstream's own A-side image before and after.
 * Kernels that want the lane build with -DMBXR_RT_LUT=1. */
#ifndef MBXR_RT_LUT
#define MBXR_RT_LUT 0
#endif
#if MBXR_RT_LUT
#define MBXR_RT_OP_LUT     3
#endif

static struct {
	int op;
	const mbxr_wimage *img;
	uint64_t in_pa;
	int npix, astride;
	mbxr_quant q;
	int8_t *out;
	mbxr_stats st;
	int rc;
	uint64_t cycles, fill_beats, cyc_fill, cyc_tseq, cyc_busy, steps;
	/* op 1 (lane): one tile of a LayerNorm dispatch.
	 * THE AFFINE TABLE TRAVELS WITH THE JOB, and that is not a convenience: `lcfg` is
	 * custom-1 and custom-1 is in HART 1's tile, so a table written from hart 0 traps with
	 * mcause 2 at the instruction word.  Writing the tile through this worker and the table
	 * from the caller is the same mistake Lab B33 made with `lst`, one layer up. */
	uint64_t ln_src_pa, ln_dst_pa, ln_eps;
	int ln_words, ln_blocks, ln_rows, ln_K, ln_HW;
	unsigned ln_abuf, ln_flags;
	uint64_t ln_polls;
	const int32_t *ln_umul;
	const int64_t *ln_gmul, *ln_badd;
	/* op 2 (attention): one (layer, head) on mbxa_core.  Same rule as the affine table
	 * above and for the same reason -- the softmax table's 256 `lcfg` writes are custom-1,
	 * so the VALUES are computed by the caller on hart 0 and WRITTEN here.  The images are
	 * staged by the caller too and travel as physical addresses; staging touches no
	 * custom-1 and is the bulk of the work, so it stays off this hart on purpose. */
	uint64_t at_q_pa, at_w_pa, at_dst_pa;
	int at_q_words, at_lgpw, at_blocks, at_rows, at_gs, at_qs, at_gp, at_qp;
	int at_kbase, at_vtbase, at_nsc, at_nout, at_sh_s, at_sh_p;
	uint32_t at_mt_s, at_mt_p;
	const uint32_t *at_smx_ex;
	int32_t at_smx_om;
	int at_smx_s, at_smx_K, at_do_table;
	uint64_t at_polls, at_fence_polls, at_fence_cyc, at_wait_cyc;
	uint32_t at_aerr;
	int ln_table_K;                 /* > 0: write the affine table before this tile */
#if MBXR_RT_LUT
	/* op 3 (LUT lane).  APPENDED, so no existing field's offset moves -- and compiled out
	 * entirely unless an image asks for the lane, so the struct's SIZE does not move either. */
	uint64_t lu_src_pa, lu_dst_pa;
	int lu_word0, lu_words;
	const int8_t *lu_tbl;           /* non-NULL: write the table and return              */
	const uint8_t *lu_seen;         /* non-NULL: write ONLY the entries it marks          */
#endif
} mbxr_rt_job;

#if MBXR_RT_LUT
/* the LUT lane's per-tile configuration: its word range.  Here rather than in the kernel
 * because the kernel's include comes after this file, and because `lcfg` is custom-1 and this
 * is the file that owns the hart which may issue it. */
static int mbxr_rt_lut_cfg(void *ctx)
{
	const int *wv = (const int *)ctx;

	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_LUT, 0x100u), (uint32_t)wv[0]);   /* word0 */
	mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_LUT, 0x101u), (uint32_t)wv[1]);   /* words */
	return MBXR_OK;
}
#endif

/* ---- B126: THE REPAIR AT THE POINT OF USE -------------------------------------------------
 *
 * WHAT B124 MEASURED, AND THEREFORE WHAT THIS IS.  The engine and the attention lane are ONE
 * RoCC unit.  A run of engine dispatches with NO intervening attention dispatch makes the NEXT
 * attention dispatch return a wrong answer -- silently, `rc = 0`, no error bit, no fallback:
 *
 *     engine dispatches immediately before the pass   0     256     640    1,395
 *     the pass                                      exact   exact   exact   WRONG (twice)
 *
 * and ***THE DAMAGE DOES NOT PERSIST***: B124 arm C's pass after the broken one is bit-exact
 * again with no repair action at all.  So there is no latch to clear and no state to restore
 * across a pass; what has to be prevented is exactly one thing -- a LONG ENGINE RUN
 * IMMEDIATELY PRECEDING AN ATTENTION DISPATCH.  That is why the counter below is reset by an
 * attention dispatch and by nothing else, and why the repair is issued AT THE POINT OF USE
 * rather than every N dispatches: one action per pass instead of two, and it is triggered by
 * the condition that was measured rather than by a schedule.
 *
 * TWO CANDIDATE REPAIRS, AND THE SECOND IS NOT A GUESS ABOUT A REGISTER.
 *
 *   MBXR_RT_B126_CAP   re-assert MBXR_CAP -- the engine's outstanding-Get cap, which
 *                      mbxr_rt_worker asks for ONCE before the dispatch loop and which no
 *                      dispatch re-asserts (see MBXR_RT_CAP above).  B124 named it as the
 *                      prime suspect and was explicit that it did not test it.  Asserted
 *                      before EVERY attention dispatch, not only long ones, so the test
 *                      cannot fail for want of a trigger.  One custom-1 per dispatch.
 *   MBXR_RT_B126_REDO  issue the attention dispatch TWICE and keep the second answer.  This
 *                      assumes nothing about WHICH state is disturbed: B124 arm C showed an
 *                      ordinary pass repairs the unit, and the first attention dispatch after
 *                      the run is the one that is wrong, so the cheapest sufficient action is
 *                      to spend that dispatch.  It is idempotent by construction -- the same
 *                      q and weight images in, the same destination written twice -- and it
 *                      needs no synthetic shape, no staging and no new opcode.
 *
 * COST, IN THE MERGED IMAGE.  The decoder issues 1,356 engine dispatches and no attention ones
 * between one pass's last attention dispatch and the next pass's first, so REDO fires ONCE per
 * inference: one extra head of ~195 k cycles against ~705 M.  CAP costs one custom-1 per
 * attention dispatch, 48 per inference.
 *
 * GUARDED, FOR THE REASON MBP_B124 AND MBXR_RT_LUT ARE GUARDED.  With MBP_B126 off this file
 * compiles to the bytes it did before, which is checkable against B124's own reference build
 * and is checked.
 */
#ifndef MBP_B126
#define MBP_B126 0
#endif
#if MBP_B126
#define MBXR_RT_B126_OFF   0
#define MBXR_RT_B126_CAP   1
#define MBXR_RT_B126_REDO  2
/* The run length at which a repair is issued.
 *
 * ***640 WAS TOO LARGE, AND B126's OWN RTF ARM IS WHAT SAYS SO.***  B124 bracketed the
 * threshold at 640 < T <= 1,395 using bursts of `npix = 1` dispatches -- the smallest whole
 * dispatch there is -- and named what it had not measured: "whether the relevant count is
 * dispatches, `pairs` or `bytes_wgt`".  On the 32-utterance autoregressive arm, whose decoder
 * issues REAL dispatches, the separation is exact and it is at 640:
 *
 *     preceding engine run   >= 640      ALL 14 utterances correct in tokens AND values
 *     preceding engine run    < 640      8 of 18 still wrong -- the repair never fired
 *
 * So the threshold in real dispatches is BELOW 640, and the cap must be set from what is known
 * to be safe rather than from what was measured broken.  What is known safe is the ENCODER'S
 * OWN longest run between two attention dispatches: `maxrun = 6`, in an encoder that four labs
 * and this one have certified bit-exact against the host, dispatch by dispatch.
 *
 * 8 IS THAT NUMBER WITH MARGIN 2, AND IT COSTS NOTHING.  The decoder has no attention dispatch
 * at all, so the run reaching an encoder's first attention dispatch is hundreds long and the
 * repair fires EXACTLY ONCE PER INFERENCE -- one extra head, ~195 k cycles.  Inside the encoder
 * no run reaches 8, so nothing fires there.  Raising it buys no cycles and risks the defect;
 * lowering it below 7 would fire inside an encoder region that is already exact. */
#ifndef MBXR_RT_B126_N
#define MBXR_RT_B126_N 8
#endif
/* The mode this image boots with.  A harness may move it per pass (mbxr_rt_b126_mode_set) --
 * that is how B126's arm puts a control and two candidate repairs in ONE image on ONE board
 * round -- but a shipped image never has to. */
#ifndef MBXR_RT_B126_MODE
#define MBXR_RT_B126_MODE MBXR_RT_B126_REDO
#endif
static int mbxr_rt_b126_mode = MBXR_RT_B126_MODE;
/* Written by hart 0 in mbxr_rt_attn_issue before the job is posted, read by hart 1 in the
 * worker -- the same publication the job struct itself relies on (fields, then atomic_inc,
 * then k_sem_give).  volatile because, unlike the job struct, hart 1 reads it in the same
 * basic block it writes it back in. */
static volatile int mbxr_rt_b126_redo_now;
static unsigned long mbxr_rt_b126_run;      /* engine dispatches since the last attention one */
static unsigned long mbxr_rt_b126_maxrun;   /* the longest such run this image has seen       */
static unsigned long mbxr_rt_b126_fired;    /* repairs issued (REDO)                          */
static unsigned long mbxr_rt_b126_caps;     /* MBXR_CAP re-assertions issued                  */
static unsigned long mbxr_rt_b126_attn;     /* attention dispatches seen                      */
void mbxr_rt_b126_mode_set(int m);
void mbxr_rt_b126_mode_set(int m) { mbxr_rt_b126_mode = m; }
void mbxr_rt_b126_report(unsigned long *o);
void mbxr_rt_b126_report(unsigned long *o)
{
	o[0] = (unsigned long)mbxr_rt_b126_mode;
	o[1] = mbxr_rt_b126_fired;
	o[2] = mbxr_rt_b126_maxrun;
	o[3] = mbxr_rt_b126_run;
	o[4] = mbxr_rt_b126_attn;
	o[5] = mbxr_rt_b126_caps;
	o[6] = (unsigned long)MBXR_RT_B126_N;
	o[7] = (unsigned long)MBXR_RT_CAP;
}
#endif

static void mbxr_rt_worker(void *a, void *b, void *c)
{
	(void)a; (void)b; (void)c;
	atomic_val_t ran = 0;
	/* THE WIDTH CONTRACT, CHECKED BEFORE THE FIRST DISPATCH IS ARMED.  `stat` is custom-1 and
	 * legal only on this hart, which is why the check lives here and not beside the image
	 * builds on hart 0.  MBXR_NCH lays out every weight plane (mbxr.h); the engine addresses
	 * MBXR_ID_NCH(id) of them.  Disagree, and the drain descriptor is the wrong size for what
	 * the packer emits, the store never reaches terminal, and the fence never clears: 20 M
	 * polls, MBXR_E_TIMEOUT, no error bit, nothing on the console.  Refuse instead, with a
	 * code that names the reason, and let the kernel fall back from the first call. */
	uint64_t id = mbxr_rt_cmd(NULL, MBXR_STAT, MBXR_C_ID, 0, 1);
	mbxr_rt_stats.engine_id = id;
	mbxr_rt_stats.engine_nch = MBXR_ID_NCH(id);
	mbxr_rt_stats.width_ok = (MBXR_ID_NCH(id) == (uint32_t)MBXR_NCH) ? 1 : -1;
	/* The cap, once, on this hart.  See MBXR_RT_CAP: 4 needs 0092 in the L2. */
	mbxr_rt_cmd(NULL, MBXR_CAP, 0, MBXR_RT_CAP, 0);
	mbxr_rt_stats.cap_asked = MBXR_RT_CAP;
	for (;;) {
		k_sem_take(&mbxr_rt_go, K_FOREVER);
		/* A re-given token (a kick) can outlive the job it was for: run only a new job. */
		atomic_val_t seq = atomic_get(&mbxr_rt_seq);
		if (seq == ran) continue;
		atomic_set(&mbxr_rt_started_seq, seq);
		for (size_t i = 0; i < sizeof mbxr_rt_job.st; i++) ((uint8_t *)&mbxr_rt_job.st)[i] = 0;
		uint64_t c0 = mbxr_rt_cyc();
		if (mbxr_rt_stats.width_ok < 0) {
			/* Not a shape this dispatch happens not to suit -- the whole plane layout
			 * is wrong for this silicon, for every op, engine and lanes alike.  Answer
			 * at once rather than arming anything. */
			mbxr_rt_job.rc = MBXR_E_WIDTH;
			mbxr_rt_job.cycles = mbxr_rt_cyc() - c0;
			ran = seq;
			atomic_set(&mbxr_rt_done, 1);
			continue;
		}
		if (mbxr_rt_job.op == MBXR_RT_OP_LANE) {
			/* the table first, on this hart, once per dispatch rather than per tile */
			for (int k = 0; k < mbxr_rt_job.ln_table_K; k++)
				mbxr_ln_table((unsigned)k, (uint32_t)mbxr_rt_job.ln_umul[k],
					      (uint64_t)((int64_t)mbxr_rt_job.ln_K *
							 (int64_t)mbxr_rt_job.ln_umul[k]),
					      (uint32_t)mbxr_rt_job.ln_gmul[k],
					      (uint32_t)mbxr_rt_job.ln_badd[k]);
			mbxr_rt_job.rc = mbxr_ln_dispatch(mbxr_rt_cmd, NULL,
							  mbxr_rt_job.ln_src_pa, mbxr_rt_job.ln_words,
							  mbxr_rt_job.ln_abuf, mbxr_rt_job.ln_dst_pa,
							  mbxr_rt_job.ln_blocks, mbxr_rt_job.ln_rows,
							  mbxr_rt_job.ln_K, mbxr_rt_job.ln_HW,
							  mbxr_rt_job.ln_eps, mbxr_rt_job.ln_flags,
							  MBXR_RT_LANE_POLLS, &mbxr_rt_job.ln_polls);
			mbxr_rt_job.cycles = mbxr_rt_cyc() - c0;
		} else if (mbxr_rt_job.op == MBXR_RT_OP_ATTN) {
#if MBP_B126
			/* BOTH REPAIRS ARE HART 1's, because both reach custom-1 and custom-1 is
			 * in hart 1's tile.  The redo runs the SAME dispatch twice and keeps the
			 * second rc: same q and weight images, same destination, so it is
			 * idempotent and the caller's contract is untouched. */
			int b126_n = 1;

			if (mbxr_rt_b126_mode == MBXR_RT_B126_CAP) {
				mbxr_rt_cmd(NULL, MBXR_CAP, 0, MBXR_RT_CAP, 0);
				mbxr_rt_b126_caps++;
			}
			if (mbxr_rt_b126_redo_now) {
				mbxr_rt_b126_redo_now = 0;
				mbxr_rt_b126_fired++;
				b126_n = 2;
				/* ONCE PER BOOT, and only the first.  The autoregressive harness
				 * has no big_worker and therefore no MB_B126 report, so without
				 * this an image could carry the repair and never say it ran.  One
				 * line is ~5 ms of UART inside one utterance's bracket; a line per
				 * fire would be 32 of them and would show up in the RTF. */
				/* maxrun, not run: hart 0 has already cleared `run` in
				 * mbxr_rt_attn_issue, and on the FIRST fire the run that
				 * triggered it IS the largest seen so far. */
				if (mbxr_rt_b126_fired == 1)
					printk("MB_B126 FIRST REPAIR: run=%lu n=%d attn=%lu\n",
					       mbxr_rt_b126_maxrun, (int)MBXR_RT_B126_N,
					       mbxr_rt_b126_attn);
			}
			while (b126_n--)
#endif
			mbxr_rt_job.rc = mbxr_attn_dispatch(
				mbxr_rt_cmd, NULL,
				mbxr_rt_job.at_q_pa, mbxr_rt_job.at_q_words,
				mbxr_rt_job.at_w_pa, mbxr_rt_job.at_lgpw,
				mbxr_rt_job.at_dst_pa, mbxr_rt_job.at_blocks,
				mbxr_rt_job.at_rows, mbxr_rt_job.at_gs, mbxr_rt_job.at_qs,
				mbxr_rt_job.at_gp, mbxr_rt_job.at_qp,
				mbxr_rt_job.at_kbase, mbxr_rt_job.at_vtbase,
				mbxr_rt_job.at_nsc, mbxr_rt_job.at_nout,
				mbxr_rt_job.at_mt_s, mbxr_rt_job.at_sh_s,
				mbxr_rt_job.at_mt_p, mbxr_rt_job.at_sh_p,
				mbxr_rt_job.at_smx_ex, mbxr_rt_job.at_smx_om,
				mbxr_rt_job.at_smx_s, mbxr_rt_job.at_smx_K,
				mbxr_rt_job.at_do_table,
				MBXR_RT_LANE_POLLS, &mbxr_rt_job.at_polls,
				&mbxr_rt_job.at_fence_polls, &mbxr_rt_job.at_aerr,
				&mbxr_rt_job.at_fence_cyc, &mbxr_rt_job.at_wait_cyc);
			mbxr_rt_job.cycles = mbxr_rt_cyc() - c0;
#if MBXR_RT_LUT
		} else if (mbxr_rt_job.op == MBXR_RT_OP_LUT) {
			if (mbxr_rt_job.lu_tbl) {
				/* WRITE ONLY THE ENTRIES THE STREAM CAN REACH.  A byte value that
				 * does not occur is never indexed, so its entry costs 22 cycles to
				 * write and buys nothing.  On cat2_c1_s8 -- 552 dispatches, two
				 * tables per call -- the difference between writing D and writing
				 * 256 is 0.7 M cycles of a 15.7 M saving, which is why the caller
				 * is given somewhere to say which entries matter. */
				const uint8_t *sn = mbxr_rt_job.lu_seen;

				for (unsigned i = 0; i < 256u; i++)
					if (!sn || sn[i ^ 0x80u])
						mbxr_lane_cfg(MBXR_CFG(MBXR_LANE_LUT, i),
							      (uint32_t)(uint8_t)mbxr_rt_job.lu_tbl[i]);
				mbxr_rt_job.rc = MBXR_OK;
			} else {
				mbxr_lane_plan p;
				int wv[2];

				wv[0] = mbxr_rt_job.lu_word0;
				wv[1] = mbxr_rt_job.lu_words;
				p.src_pa = mbxr_rt_job.lu_src_pa;
				p.src_blocks = (mbxr_rt_job.lu_word0 + mbxr_rt_job.lu_words + 7) / 8;
				p.abuf = 0u;
				p.word0 = mbxr_rt_job.lu_word0;
				p.words = mbxr_rt_job.lu_words;
				p.dst_pa = mbxr_rt_job.lu_dst_pa;
				p.dst_blocks = mbxr_rt_job.lu_words / 8;
				p.which = MBXR_GO_LUT;
				p.budget = MBXR_RT_LANE_POLLS;
				mbxr_rt_job.rc = mbxr_lane_dispatch(mbxr_rt_cmd, NULL, &p,
								    mbxr_rt_lut_cfg, wv, NULL);
			}
			mbxr_rt_job.cycles = mbxr_rt_cyc() - c0;
#endif
		} else {
		/* Zephyr runs in M-mode with no MMU, so out's virtual address IS its physical one;
		 * that is the same identity mbxr_rt_p2v relies on.  The engine's Puts go through the
		 * L2, which probes and invalidates both harts' L1 copies of those lines. */
		mbxr_rt_job.rc = mbxr_run_to(mbxr_rt_pick(), mbxr_rt_job.img, mbxr_rt_job.in_pa,
					     mbxr_rt_job.npix, mbxr_rt_job.astride, &mbxr_rt_job.q,
					     MBXR_RT_SCRATCH, mbxr_rt_job.out,
					     (uint64_t)(uintptr_t)mbxr_rt_job.out, &mbxr_rt_job.st);
		mbxr_rt_job.cycles = mbxr_rt_cyc() - c0;
		mbxr_rt_job.fill_beats = mbxr_rt_cmd(NULL, MBXR_STAT, MBXR_C_FILL_BEATS, 0, 1);
		mbxr_rt_job.cyc_fill = mbxr_rt_cmd(NULL, MBXR_STAT, MBXR_C_CYC_FILL, 0, 1);
		mbxr_rt_job.cyc_tseq = mbxr_rt_cmd(NULL, MBXR_STAT, MBXR_C_CYC_TSEQ, 0, 1);
		mbxr_rt_job.cyc_busy = mbxr_rt_cmd(NULL, MBXR_STAT, MBXR_C_CYC_BUSY, 0, 1);
		mbxr_rt_job.steps    = mbxr_rt_cmd(NULL, MBXR_STAT, MBXR_C_STEPS,    0, 1);
		}
		ran = seq;
		atomic_set(&mbxr_rt_done, 1);
	}
}

static int mbxr_rt_available(void)
{
	if (mbxr_rt_state == 0) {
		k_sem_init(&mbxr_rt_go, 0, 1);
		k_tid_t t = k_thread_create(&mbxr_rt_thread, mbxr_rt_stack, MBXR_RT_STACK,
					    mbxr_rt_worker, NULL, NULL, NULL, 2, 0, K_FOREVER);
		if (k_thread_cpu_pin(t, 1) != 0) {
			mbxr_rt_state = -1;
			return 0;
		}
		k_thread_start(t);
		mbxr_rt_state = 1;
	}
	return mbxr_rt_state == 1;
}

/* ---- the image cache ------------------------------------------------------------------- */
#define MBXR_RT_MAX_LAYERS 256
static struct { const void *key; int kind, N, Kp, wbits; mbxr_wimage img; } mbxr_rt_cache[MBXR_RT_MAX_LAYERS];
static int mbxr_rt_ncache;
static uint64_t mbxr_rt_img_next = MBXR_RT_IMG_BASE;

/* rows_fn writes padded row n of the layer into dst -- Kp bytes at wbits = 8, and the PACKED
 * Kp * wbits / 8 bytes at wbits = 6.  It writes the IMAGE row, which is what mbxr.c's
 * mbxr_wimage_build_fn asks of it at every grid. */
typedef void (*mbxr_rt_row_fn)(void *ctx, int n, int8_t *dst);

static const mbxr_wimage *mbxr_rt_image_bits(const void *key, int kind, int N, int Kp, int wbits,
					     const int32_t *bias, mbxr_rt_row_fn rows, void *ctx)
{
	for (int i = 0; i < mbxr_rt_ncache; i++)
		if (mbxr_rt_cache[i].key == key && mbxr_rt_cache[i].kind == kind &&
		    mbxr_rt_cache[i].N == N && mbxr_rt_cache[i].Kp == Kp &&
		    mbxr_rt_cache[i].wbits == wbits)
			return &mbxr_rt_cache[i].img;
	if (mbxr_rt_ncache == MBXR_RT_MAX_LAYERS) return NULL;
	mbxr_wimage img;
	/* MBXR_RT_DRAIN_STRIDED and not mbxr_rt_pick(): images are built on hart 0, which may not
	 * issue a `stat`, and an even quad count is a legal plan on either engine. */
	size_t bytes = mbxr_wimage_plan_bits(&img, N, Kp, wbits, MBXR_RT_DRAIN_STRIDED);
	if (bytes == 0 || mbxr_rt_img_next + bytes > MBXR_RT_IMG_END) return NULL;
	/* the staging limit is on what is WRITTEN -- the packed row -- not on the code count */
	if ((size_t)N * img.Kw > (8UL << 20)) return NULL;
	uint64_t c0 = mbxr_rt_cyc();
	/* ONE PASS.  The staging buffer existed because the tiled layout consumes rows out of
	 * order; n = (t*Q + q)*NCH + r inverts in closed form, so `rows` can write straight into
	 * the image and the read-back pass and full-plane zeroing both disappear.  4.01x fewer
	 * byte-operations, gated by building every Moonshine image BOTH ways into differently
	 * poisoned arenas and comparing byte for byte.  ENGINE_WAIT_ANATOMY.md 18-20.
	 * MBXR_RT_ROW_STAGE is now unused by this path and stays only for the kernels' own
	 * input staging. */
	if (mbxr_wimage_build_fn(&mbxr_rt_dev, &img, mbxr_rt_img_next, rows, ctx, bias) != MBXR_OK)
		return NULL;
	mbxr_rt_img_next += bytes;
	mbxr_rt_stats.image_cycles += mbxr_rt_cyc() - c0;
	mbxr_rt_stats.image_bytes += bytes;
	mbxr_rt_cache[mbxr_rt_ncache].key = key;
	mbxr_rt_cache[mbxr_rt_ncache].kind = kind;
	mbxr_rt_cache[mbxr_rt_ncache].N = N;
	mbxr_rt_cache[mbxr_rt_ncache].Kp = Kp;
	mbxr_rt_cache[mbxr_rt_ncache].wbits = wbits;
	mbxr_rt_cache[mbxr_rt_ncache].img = img;
	return &mbxr_rt_cache[mbxr_rt_ncache++].img;
}

static const mbxr_wimage *mbxr_rt_image(const void *key, int kind, int N, int Kp,
					const int32_t *bias, mbxr_rt_row_fn rows, void *ctx)
{
	return mbxr_rt_image_bits(key, kind, N, Kp, 8, bias, rows, ctx);
}

/* Drop every cached image (and reuse their memory): for a caller that rewrites weights in
 * place under the same address.  External, like mbxr_rt_stats, so a harness that includes
 * this header with MBXR_RT_TYPES_ONLY can call it. */
void mbxr_rt_forget(void);
void mbxr_rt_forget(void)
{
	mbxr_rt_ncache = 0;
	mbxr_rt_img_next = MBXR_RT_IMG_BASE;
}

/* B102 -- THE ISSUE/WAIT SPLIT FOR THE ENGINE OP, PURELY ADDITIVE.
 *
 * Exactly the shape B86d gave the attention lane (mbxr_rt.h, `mbxr_rt_attn_issue`): both halves
 * are exposed and `mbxr_rt_run` IS REIMPLEMENTED IN TERMS OF THEM, so there is one code path
 * rather than two that can drift, and every existing caller sees an unchanged surface.
 *
 * `issue` hands back a TOKEN rather than leaving its live values in file-scope state, for
 * B86d's measured reason: with statics GCC must spill and reload them and the composed function
 * stops being opcode-identical to the one it replaced.  THE EQUIVALENCE IS CHECKABLE AND MUST
 * BE CHECKED: with MBP_B102 = 0 the composed `mbxr_rt_run` must disassemble to the pre-split
 * function byte for byte, which is what commit 4fd1d22 did for `mbxr_rt_attn_head`.
 *
 * B86d's TWO RULES APPLY UNCHANGED, and they are why the convolution stages everything before
 * it polls:
 *   1. `mbxr_rt_job` is ONE GLOBAL STRUCT.  Do not issue a second dispatch before wait() has
 *      returned for the first.
 *   2. Hart 1's fill fence is INVISIBLE to hart 0.  Work overlapped into the wait window must
 *      not touch the bytes the fill is reading -- which for B102 is the whole point, and is
 *      what the gather watermark makes safe rather than hoped-for.
 */
typedef struct { uint64_t c0; atomic_val_t seq; uint64_t kick_at; } mbxr_rt_tok;

static mbxr_rt_tok mbxr_rt_run_issue(const mbxr_wimage *img, uint64_t in_pa, int npix,
				     int astride, int mult, int shift, int amin, int amax,
				     int8_t *out)
{
	mbxr_rt_tok tk;

	tk.c0 = mbxr_rt_cyc();
	mbxr_rt_job.op = MBXR_RT_OP_ENGINE;
	mbxr_rt_job.img = img; mbxr_rt_job.in_pa = in_pa; mbxr_rt_job.npix = npix;
	mbxr_rt_job.astride = astride; mbxr_rt_job.out = out;
	mbxr_rt_job.q.mult = mult; mbxr_rt_job.q.shift = shift;
	mbxr_rt_job.q.amin = amin; mbxr_rt_job.q.amax = amax;
	atomic_set(&mbxr_rt_done, 0);
	/* after the job is whole, before the give; atomic_inc returns the previous value */
	tk.seq = atomic_inc(&mbxr_rt_seq) + 1;
	k_sem_give(&mbxr_rt_go);
	tk.kick_at = tk.c0 + MBXR_RT_KICK_CYCLES;
	return tk;
}

/* Non-blocking.  1: the worker is done.  0: still running.  MBXR_E_TIMEOUT: gave up.
 * A caller doing work in the wait window must call this rather than read `mbxr_rt_done`
 * directly, or the lost-wake-up kick never fires while it works. */
static int mbxr_rt_run_poll(mbxr_rt_tok *tk)
{
	uint64_t now;

	if (atomic_get(&mbxr_rt_done)) return 1;
	now = mbxr_rt_cyc();
	if (now < tk->kick_at) return 0;
	tk->kick_at = now + MBXR_RT_KICK_CYCLES;
	if (atomic_get(&mbxr_rt_started_seq) != tk->seq) {
		/* Not picked up.  A lost wake-up of CPU 1 would look exactly like this;
		 * giving again is idempotent (the semaphore's limit is 1). */
		mbxr_rt_stats.kicks++;
		k_sem_give(&mbxr_rt_go);
	}
	if (now - tk->c0 > MBXR_RT_GIVEUP_CYCLES) {
		/* The worker (or the engine behind it) is gone.  Stop using it: the
		 * kernel falls back, and so does every later call.  A job that does
		 * finish later writes the same bytes the fallback does, if it is right. */
		mbxr_rt_stats.giveups++;
		mbxr_rt_stats.last_rc = MBXR_E_TIMEOUT;
		mbxr_rt_state = -1;
		return MBXR_E_TIMEOUT;
	}
	return 0;
}

static int mbxr_rt_run_wait(mbxr_rt_tok *tk)
{
	for (;;) {
		int p = mbxr_rt_run_poll(tk);
		if (p == 1) break;
		if (p == MBXR_E_TIMEOUT) return MBXR_E_TIMEOUT;
	}
	mbxr_rt_stats.cycles_h0 += mbxr_rt_cyc() - tk->c0;
	mbxr_rt_stats.cycles_h1 += mbxr_rt_job.cycles;
	mbxr_rt_stats.loads_act += mbxr_rt_job.st.loads_act;
	mbxr_rt_stats.loads_wgt += mbxr_rt_job.st.loads_wgt;
	mbxr_rt_stats.bytes_act += mbxr_rt_job.st.bytes_act;
	mbxr_rt_stats.bytes_wgt += mbxr_rt_job.st.bytes_wgt;
	mbxr_rt_stats.pairs += mbxr_rt_job.st.pairs;
	mbxr_rt_stats.polls += mbxr_rt_job.st.polls;
	mbxr_rt_stats.fill_beats += mbxr_rt_job.fill_beats;
	mbxr_rt_stats.cyc_fill += mbxr_rt_job.cyc_fill;
	mbxr_rt_stats.cyc_tseq += mbxr_rt_job.cyc_tseq;
	mbxr_rt_stats.cyc_busy += mbxr_rt_job.cyc_busy;
	mbxr_rt_stats.steps    += mbxr_rt_job.steps;
	mbxr_rt_stats.cyc_wait += mbxr_rt_job.st.cyc_wait;
	mbxr_rt_stats.cyc_place += mbxr_rt_job.st.cyc_place;
	mbxr_rt_stats.placed_early += mbxr_rt_job.st.placed_early;
	mbxr_rt_stats.last_rc = mbxr_rt_job.rc;
	mbxr_rt_stats.last_status = mbxr_rt_job.st.last_status;
	if (mbxr_rt_job.rc == MBXR_E_TIMEOUT) mbxr_rt_state = -1;    /* the engine never finished */
	/* A width mismatch is permanent: the bitstream will not change under a running image. */
	if (mbxr_rt_job.rc == MBXR_E_WIDTH) mbxr_rt_state = -1;
	if (mbxr_rt_job.rc == MBXR_OK) mbxr_rt_stats.calls_engine++;
#if MBP_B126
	/* THE RUN.  Every engine dispatch lengthens it; only an attention dispatch clears it
	 * (mbxr_rt_attn_issue).  A LayerNorm or LUT dispatch deliberately does NOT clear it:
	 * nothing measured says those repair the unit, and over-counting the run costs at most
	 * one extra repair while under-counting it costs a wrong answer. */
	mbxr_rt_b126_run++;
#endif
	return mbxr_rt_job.rc;
}

/* One engine dispatch from hart 0.  Returns MBXR_OK or the driver's error. */
static int mbxr_rt_run(const mbxr_wimage *img, uint64_t in_pa, int npix, int astride,
		       int mult, int shift, int amin, int amax, int8_t *out)
{
	mbxr_rt_tok tk = mbxr_rt_run_issue(img, in_pa, npix, astride, mult, shift, amin, amax,
					   out);
	return mbxr_rt_run_wait(&tk);
}

/* ---- B124: N ENGINE DISPATCHES ON DEMAND, FROM HART 0 ------------------------------------
 *
 * WHAT THIS IS FOR.  B123 eliminated the cache (an 80 MB flush between passes leaves the
 * merged image's wrong answer bit-identical), free DRAM (96 MB swept) and the engine's four
 * staging windows (rewritten byte for byte).  What it could not reach is the accelerator's
 * OWN state: between the two executions of the encoder's first attention dispatch the MERGED
 * image runs 1,395 engine dispatches and no attention ones, the STANDALONE runs 39 -- and the
 * engine and the attention lane are ONE RoCC unit.  No store from hart 0 can perturb that, so
 * the only instrument that can is more dispatches.  This is that instrument: it hands the
 * harness a way to put an arbitrary number of REAL engine dispatches between two inferences
 * of an image that is otherwise proven bit-exact across them.
 *
 * WHAT IT DELIBERATELY DOES NOT DO.
 *   - IT BUILDS NO IMAGE.  It runs only images the model itself has already cached, so
 *     mbxr_rt_img_next does not move and the weight arena -- candidate (a), the only
 *     first-pass/later-pass asymmetry in the memory map -- is not touched.  The caller is
 *     given the image_bytes delta so it can CHECK that rather than trust it.
 *   - IT ALLOCATES NOTHING.  Its input and output live in MBXR_RT_IN_STAGE and
 *     MBXR_RT_OUT_STAGE, the windows B123's arm T rewrote byte for byte between passes with
 *     no effect on the model, so a divergence cannot be blamed on where these bytes went.
 *   - IT ROUND-ROBINS the cache rather than picking one layer, so the burst spans every
 *     weight SHAPE the model owns and the dispatch immediately before the next inference is
 *     not always the same one.
 *
 * GUARDED, FOR THE REASON MBXR_RT_LUT IS GUARDED.  With MBP_B124 off this file compiles to
 * the bytes it did before, which is checkable and is checked.
 */
#ifndef MBP_B124
#define MBP_B124 0
#endif
#if MBP_B124
#define MBXR_RT_B124_OUT 12
void mbxr_rt_b124_burst(int n, unsigned long *o);
void mbxr_rt_b124_burst(int n, unsigned long *o)
{
	volatile int8_t *in = (volatile int8_t *)(uintptr_t)MBXR_RT_IN_STAGE;
	int8_t *out = (int8_t *)(uintptr_t)MBXR_RT_OUT_STAGE;
	unsigned long fold = 2166136261UL;
	uint64_t ce0, ib0, bw0, pr0, c0;
	int i, k, done = 0, rc = MBXR_OK, kmax = 0;

	for (i = 0; i < MBXR_RT_B124_OUT; i++) o[i] = 0;
	o[7] = (unsigned long)mbxr_rt_ncache;
	if (n <= 0)                { o[9] = 1; return; }   /* the null arm: nothing to issue  */
	if (mbxr_rt_state != 1)    { o[9] = 2; return; }   /* no worker: say so, do not spin  */
	if (mbxr_rt_ncache == 0)   { o[9] = 3; return; }   /* nothing cached yet to re-run    */

	/* The widest activation row any cached image asks for, so one fill serves them all. */
	for (i = 0; i < mbxr_rt_ncache; i++)
		if (mbxr_rt_cache[i].img.K > kmax) kmax = mbxr_rt_cache[i].img.K;
	for (k = 0; k < kmax; k++) in[k] = (int8_t)((k * 31 + 7) & 0x7f);
	o[11] = (unsigned long)kmax;

	ce0 = mbxr_rt_stats.calls_engine;
	ib0 = mbxr_rt_stats.image_bytes;
	bw0 = mbxr_rt_stats.bytes_wgt;
	pr0 = mbxr_rt_stats.pairs;
	c0  = mbxr_rt_cyc();
	for (i = 0; i < n; i++) {
		const mbxr_wimage *img = &mbxr_rt_cache[i % mbxr_rt_ncache].img;

		/* npix = 1: one activation row.  The point of this arm is the NUMBER of RoCC
		 * dispatches, not the bytes, and a one-pixel dispatch is a whole one -- the
		 * same cfg/ld/mm/fence/drain sequence the model issues. */
		rc = mbxr_rt_run(img, (uint64_t)(uintptr_t)in, 1, (img->K + 7) / 8,
				 1, 0, -128, 127, out);
		if (rc != MBXR_OK) break;
		done++;
		for (k = 0; k < img->N; k++) {
			fold ^= (unsigned long)(uint8_t)out[k];
			fold = (fold * 16777619UL) & 0xffffffffUL;
		}
	}
	o[0] = (unsigned long)done;
	o[1] = (unsigned long)(mbxr_rt_cyc() - c0);
	o[2] = (unsigned long)(mbxr_rt_stats.calls_engine - ce0);
	o[3] = (unsigned long)(mbxr_rt_stats.image_bytes  - ib0);
	o[4] = (unsigned long)(mbxr_rt_stats.bytes_wgt    - bw0);
	o[5] = (unsigned long)(long)rc;
	o[6] = fold;
	o[10] = (unsigned long)(mbxr_rt_stats.pairs - pr0);
}
#endif

/* ---- one LayerNorm tile, from hart 0 -------------------------------------------------------
 * Hands the tile to the hart-1 worker and waits, reusing mbxr_rt_run's kick and give-up loop by
 * duplicating only the wait (the job fields differ; the loop does not).  Returns MBXR_OK, or the
 * lane's own code -- MBXR_E_LANE_* -- which the caller turns into a fallback. */
static int mbxr_rt_ln_tile(uint64_t src_pa, int words, unsigned abuf, uint64_t dst_pa,
			   int blocks, int rows, int K, int HW, uint64_t eps_q, unsigned flags,
			   const int32_t *umul, const int64_t *gmul, const int64_t *badd,
			   int table_K)
{
	uint64_t c0 = mbxr_rt_cyc();

	mbxr_rt_job.op = MBXR_RT_OP_LANE;
	mbxr_rt_job.ln_umul = umul; mbxr_rt_job.ln_gmul = gmul; mbxr_rt_job.ln_badd = badd;
	mbxr_rt_job.ln_table_K = table_K;
	mbxr_rt_job.ln_src_pa = src_pa; mbxr_rt_job.ln_words = words; mbxr_rt_job.ln_abuf = abuf;
	mbxr_rt_job.ln_dst_pa = dst_pa; mbxr_rt_job.ln_blocks = blocks; mbxr_rt_job.ln_rows = rows;
	mbxr_rt_job.ln_K = K; mbxr_rt_job.ln_HW = HW; mbxr_rt_job.ln_eps = eps_q;
	mbxr_rt_job.ln_flags = flags; mbxr_rt_job.ln_polls = 0;
	atomic_set(&mbxr_rt_done, 0);
	atomic_val_t seq = atomic_inc(&mbxr_rt_seq) + 1;
	k_sem_give(&mbxr_rt_go);
	uint64_t kick_at = c0 + MBXR_RT_KICK_CYCLES;
	while (!atomic_get(&mbxr_rt_done)) {
		uint64_t now = mbxr_rt_cyc();
		if (now < kick_at) continue;
		kick_at = now + MBXR_RT_KICK_CYCLES;
		if (atomic_get(&mbxr_rt_started_seq) != seq) {
			mbxr_rt_stats.kicks++;
			k_sem_give(&mbxr_rt_go);
		}
		if (now - c0 > MBXR_RT_GIVEUP_CYCLES) {
			mbxr_rt_stats.giveups++;
			mbxr_rt_stats.last_rc = MBXR_E_TIMEOUT;
			mbxr_rt_state = -1;
			return MBXR_E_TIMEOUT;
		}
	}
	mbxr_rt_stats.cycles_h0 += mbxr_rt_cyc() - c0;
	mbxr_rt_stats.cycles_h1 += mbxr_rt_job.cycles;
	mbxr_rt_stats.polls += mbxr_rt_job.ln_polls;
	mbxr_rt_stats.last_rc = mbxr_rt_job.rc;
	if (mbxr_rt_job.rc == MBXR_OK) mbxr_rt_stats.calls_engine++;
	return mbxr_rt_job.rc;
}

#if MBXR_RT_LUT
/* ---- T4's LUT lane, from hart 0 -------------------------------------------------------------
 * Two entry points on one job, because the table and the tiles have different lifetimes: the
 * table is written ONCE PER OPERATOR and each tile is a dispatch.  Both go through the worker
 * for the same reason everything else does -- `lcfg` and `lgo` are custom-1 and custom-1 is in
 * hart 1's tile; the same instruction on hart 0 traps, and inside a model thread it faults
 * unhandled with no records and no console output (`60bd85d`).
 *
 * The wait is `mbxr_rt_ln_tile`'s, duplicated for the same reason it duplicates `mbxr_rt_run`'s:
 * the job fields differ and the loop does not. */
static int mbxr_rt_lut_post(void)
{
	uint64_t c0 = mbxr_rt_cyc();

	atomic_set(&mbxr_rt_done, 0);
	atomic_val_t seq = atomic_inc(&mbxr_rt_seq) + 1;
	k_sem_give(&mbxr_rt_go);
	uint64_t kick_at = c0 + MBXR_RT_KICK_CYCLES;
	while (!atomic_get(&mbxr_rt_done)) {
		uint64_t now = mbxr_rt_cyc();
		if (now < kick_at) continue;
		kick_at = now + MBXR_RT_KICK_CYCLES;
		if (atomic_get(&mbxr_rt_started_seq) != seq) {
			mbxr_rt_stats.kicks++;
			k_sem_give(&mbxr_rt_go);
		}
		if (now - c0 > MBXR_RT_GIVEUP_CYCLES) {
			mbxr_rt_stats.giveups++;
			mbxr_rt_stats.last_rc = MBXR_E_TIMEOUT;
			mbxr_rt_state = -1;
			return MBXR_E_TIMEOUT;
		}
	}
	mbxr_rt_stats.cycles_h0 += mbxr_rt_cyc() - c0;
	mbxr_rt_stats.cycles_h1 += mbxr_rt_job.cycles;
	mbxr_rt_stats.last_rc = mbxr_rt_job.rc;
	return mbxr_rt_job.rc;
}

__attribute__((unused))
static int mbxr_rt_lut_table(const int8_t *tbl, const uint8_t *seen)
{
	mbxr_rt_job.op = MBXR_RT_OP_LUT;
	mbxr_rt_job.lu_tbl = tbl;
	mbxr_rt_job.lu_seen = seen;        /* NULL: write all 256 */
	return mbxr_rt_lut_post();
}

__attribute__((unused))
static int mbxr_rt_lut_tile(uint64_t src_pa, int word0, int words, uint64_t dst_pa)
{
	mbxr_rt_job.op = MBXR_RT_OP_LUT;
	mbxr_rt_job.lu_tbl = NULL;
	mbxr_rt_job.lu_src_pa = src_pa; mbxr_rt_job.lu_word0 = word0;
	mbxr_rt_job.lu_words = words;   mbxr_rt_job.lu_dst_pa = dst_pa;
	return mbxr_rt_lut_post();
}
#endif /* MBXR_RT_LUT */

/* One (layer, head) on the attention unit.  Hart 0 calls this; it posts the job and SPINS ON
 * AN ATOMIC -- no custom-1 on this side, which is the whole point (ATTENTION_UNIT.md s10.7).
 * `fence_polls` is returned rather than swallowed: s10.8 predicts 5 per head from arithmetic,
 * and an unmeasured bound is one nobody can falsify. */
/*
 * B86d -- THE ISSUE/WAIT SPLIT, PURELY ADDITIVE.
 *
 * `mbxr_rt_attn_head` is a CROSS-HART job dispatch: hart 0 fills `mbxr_rt_job`, gives
 * `mbxr_rt_go`, then SPINS on `mbxr_rt_done` while HART 1 performs the whole
 * fill -> cfg -> st -> lgo -> wait sequence.  That spin is pure hart-0 idle, and at
 * Moonshine's shape it is 80,361 of a head's 195,047 cycles (B86_RESULT.md).  A caller with
 * work to do -- staging the NEXT head's images -- can do it in that window, but only if it
 * can reach the two halves separately.
 *
 * So both halves are exposed and `mbxr_rt_attn_head` IS REIMPLEMENTED IN TERMS OF THEM:
 * one code path, not two that can drift.  Every existing caller sees an unchanged surface.
 *
 * `issue` hands back a TOKEN rather than leaving its two live values in file-scope state.
 * That is not style: with statics GCC must spill and reload them and the composed `head`
 * stops being opcode-identical to the function it replaced (+8 instructions, measured).
 * With the token it inlines to the same code, so the equivalence is checkable rather than
 * argued -- and a caller holding a token cannot accidentally wait on the wrong dispatch.
 *
 * WHAT A CALLER MUST OBEY.  Neither is guarded, and neither is reported:
 *   1. `mbxr_rt_job` is ONE GLOBAL STRUCT.  Do not issue head n+1 before wait() has
 *      returned for head n -- it would overwrite the job hart 1 is reading.
 *   2. The DRAM images (`q_pa`, `w_pa`) are read by HART 1's fill, whose fence HART 0
 *      CANNOT OBSERVE.  A caller overlapping work into the wait window must stage into a
 *      DIFFERENT buffer, never the one it just passed.
 * Both are why the pipelined kernel double-buffers rather than reusing one set.
 *
 * THIS IS NOT A FILL PREFETCH.  `mbxr_lanes.h`'s header records that a load into the buffer
 * a lane is reading is ACCEPTED and reported by nothing (`ld_buf_bad` is gated on `t_busy`,
 * which a lane dispatch does not set).  Overlapping STAGING touches no engine state at all
 * and meets none of that; overlapping the FILL would, and needs `t_abuf` alternation first.
 */
typedef struct { uint64_t c0; atomic_val_t seq; } mbxr_attn_tok;

static mbxr_attn_tok mbxr_rt_attn_issue(uint64_t q_pa, int q_words, uint64_t w_pa, int lgpw,
			     uint64_t dst_pa, int blocks, int rows,
			     int gs, int qs, int gp, int qp, int kbase, int vtbase,
			     int nsc, int nout, uint32_t mt_s, int sh_s,
			     uint32_t mt_p, int sh_p, const uint32_t *smx_ex,
			     int32_t smx_om, int smx_s, int smx_K, int do_table)
{
	mbxr_attn_tok tk;

	tk.c0 = mbxr_rt_cyc();

	mbxr_rt_job.op = MBXR_RT_OP_ATTN;
	mbxr_rt_job.at_q_pa = q_pa; mbxr_rt_job.at_q_words = q_words;
	mbxr_rt_job.at_w_pa = w_pa; mbxr_rt_job.at_lgpw = lgpw;
	mbxr_rt_job.at_dst_pa = dst_pa; mbxr_rt_job.at_blocks = blocks;
	mbxr_rt_job.at_rows = rows; mbxr_rt_job.at_gs = gs; mbxr_rt_job.at_qs = qs;
	mbxr_rt_job.at_gp = gp; mbxr_rt_job.at_qp = qp;
	mbxr_rt_job.at_kbase = kbase; mbxr_rt_job.at_vtbase = vtbase;
	mbxr_rt_job.at_nsc = nsc; mbxr_rt_job.at_nout = nout;
	mbxr_rt_job.at_mt_s = mt_s; mbxr_rt_job.at_sh_s = sh_s;
	mbxr_rt_job.at_mt_p = mt_p; mbxr_rt_job.at_sh_p = sh_p;
	mbxr_rt_job.at_smx_ex = smx_ex; mbxr_rt_job.at_smx_om = smx_om;
	mbxr_rt_job.at_smx_s = smx_s; mbxr_rt_job.at_smx_K = smx_K;
	mbxr_rt_job.at_do_table = do_table;
	mbxr_rt_job.at_polls = 0; mbxr_rt_job.at_fence_polls = 0;
	mbxr_rt_job.at_fence_cyc = 0; mbxr_rt_job.at_wait_cyc = 0; mbxr_rt_job.at_aerr = 0;
#if MBP_B126
	/* THE ONE DECISION, taken where the run length is known and before the job is published:
	 * this dispatch is the one B124 measured wrong if and only if a long engine run
	 * immediately precedes it. */
	if (mbxr_rt_b126_run > mbxr_rt_b126_maxrun) mbxr_rt_b126_maxrun = mbxr_rt_b126_run;
	mbxr_rt_b126_redo_now = (mbxr_rt_b126_mode == MBXR_RT_B126_REDO &&
				 mbxr_rt_b126_run >= (unsigned long)MBXR_RT_B126_N) ? 1 : 0;
	mbxr_rt_b126_run = 0;
	mbxr_rt_b126_attn++;
#endif
	atomic_set(&mbxr_rt_done, 0);
	tk.seq = atomic_inc(&mbxr_rt_seq) + 1;
	k_sem_give(&mbxr_rt_go);
	return tk;
}

static int mbxr_rt_attn_wait(mbxr_attn_tok tk)
{
	const uint64_t c0 = tk.c0;
	const atomic_val_t seq = tk.seq;

	uint64_t kick_at = c0 + MBXR_RT_KICK_CYCLES;
	while (!atomic_get(&mbxr_rt_done)) {
		uint64_t now = mbxr_rt_cyc();
		if (now < kick_at) continue;
		kick_at = now + MBXR_RT_KICK_CYCLES;
		if (atomic_get(&mbxr_rt_started_seq) != seq) {
			mbxr_rt_stats.kicks++;
			k_sem_give(&mbxr_rt_go);
		}
		if (now - c0 > MBXR_RT_GIVEUP_CYCLES) {
			mbxr_rt_stats.giveups++;
			mbxr_rt_stats.last_rc = MBXR_E_TIMEOUT;
			mbxr_rt_state = -1;
			return MBXR_E_TIMEOUT;
		}
	}
	mbxr_rt_stats.cycles_h0 += mbxr_rt_cyc() - c0;
	mbxr_rt_stats.cycles_h1 += mbxr_rt_job.cycles;
	mbxr_rt_stats.polls += mbxr_rt_job.at_polls + mbxr_rt_job.at_fence_polls;
	mbxr_rt_stats.attn_fence_polls += mbxr_rt_job.at_fence_polls;
	mbxr_rt_stats.attn_lane_polls  += mbxr_rt_job.at_polls;
	mbxr_rt_stats.attn_fence_cyc   += mbxr_rt_job.at_fence_cyc;
	mbxr_rt_stats.attn_wait_cyc    += mbxr_rt_job.at_wait_cyc;
	mbxr_rt_stats.attn_aerr        |= mbxr_rt_job.at_aerr;
	mbxr_rt_stats.last_rc = mbxr_rt_job.rc;
	mbxr_rt_stats.attn_last_rc = mbxr_rt_job.rc;
	if (mbxr_rt_job.rc == MBXR_OK) mbxr_rt_stats.attn_lane++;
	else                           mbxr_rt_stats.attn_fallback++;
	return mbxr_rt_job.rc;
}

static int mbxr_rt_attn_head(uint64_t q_pa, int q_words, uint64_t w_pa, int lgpw,
			     uint64_t dst_pa, int blocks, int rows,
			     int gs, int qs, int gp, int qp, int kbase, int vtbase,
			     int nsc, int nout, uint32_t mt_s, int sh_s,
			     uint32_t mt_p, int sh_p, const uint32_t *smx_ex,
			     int32_t smx_om, int smx_s, int smx_K, int do_table)
{
	return mbxr_rt_attn_wait(
		mbxr_rt_attn_issue(q_pa, q_words, w_pa, lgpw, dst_pa, blocks, rows, gs, qs,
				   gp, qp, kbase, vtbase, nsc, nout, mt_s, sh_s, mt_p, sh_p,
				   smx_ex, smx_om, smx_s, smx_K, do_table));
}

#else  /* !__ZEPHYR__: host verification takes the fallback */
static inline int mbxr_rt_available(void) { return 0; }
#endif

#define MBXR_RT_CAT_(a, b) a##b
#define MBXR_RT_CAT(a, b)  MBXR_RT_CAT_(a, b)

#endif /* MBXR_RT_H */
