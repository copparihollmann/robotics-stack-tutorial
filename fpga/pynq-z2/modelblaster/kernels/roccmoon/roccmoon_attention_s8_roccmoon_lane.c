/* accuracy_class: bit_exact
 *
 * attention_s8 on the decoupled RoCC engine's ATTENTION LANE (`mbxa_core`, lane 0 and its
 * softmax sub-lane 1), HART 1 -- through mbxr_rt_attn_head(), never directly.
 *
 * WHY THAT SENTENCE IS THE FIRST ONE, as it is in every other kernel here.  An earlier version
 * of this file called mbxr_lane_cfg() from kernel_attention_s8(), which runs on hart 0, and
 * custom-1 is in HART 1's tile: the first `lcfg` traps with mcause 2 at mtval 0x12b5302b.
 * The board stalled at the dispatch before the first attention op with no console output, and
 * it took three board runs to localise.  THE HAZARD WAS ALREADY WRITTEN DOWN IN THREE PLACES
 * IN THIS TREE -- mbxr_rt.h's MBXR_RT_CAP note, the LayerNorm lane kernel's line 172 with this
 * exact mtval, and mbxr_rt_job's own comment -- and in this file's own design note. Writing a
 * hazard down is not the same as being unable to walk into it; what stops it is the code
 * shape, which is now: STAGING ON HART 0, DISPATCH THROUGH THE WORKER.  ATTENTION_UNIT.md is the unit; this is the software half of
 * its s2.2 contract and its s5.1 staging.
 *
 * BIT-EXACT AGAINST SOMETHING NOBODY BUILT TO MAKE IT PASS.  `attention_s8`'s reference is
 * defined as the composition of the three records the collapsing rewrite leaves in the IR --
 * `matmul_b_s8`, `softmax_s8`, `matmul_b_s8`, at the same intermediate scales and in the same
 * order.  Those three were written and measured for another purpose and are already bit-exact
 * on the board.
 *
 * AND `bit_exact` ABOVE MEANS AGAINST THE CURATED COMPOSITION -- THE KERNELS THE MODEL WOULD
 * RUN WITH THE FUSION OFF -- NOT AGAINST THE FLOAT REFERENCES.  The distinction is not
 * pedantry: `softmax_s8` on this target is `pext_int_memo2`, whose own header says
 * `accuracy_class: numeric_drift`, and for five board sessions the fallback below wrote that
 * term with expf/divide/roundf while the unit computed the integer pipeline.  The host-C
 * golden is baked FROM THE FALLBACK, so the board was compared against a reference the model
 * does not run and max_abs_err could not reach 0 (B58: 6 -> 0 when the fallback was corrected).
 * If the definition of this op's reference ever changes, this file is where it is written
 * down twice -- once in the lane's table and once in the fallback -- and both must move.  The unit computes that composition term for term (ATTENTION_UNIT.md s3:
 * 28,453,700 requantises and 210 dispatches / 441,695 bytes / 0 differ through the merged
 * engine's real path, on all four models' own activations).
 *
 * WHAT THE LANE TAKES, and everything else falls back to the three-kernel path below:
 *   D <= 8*GSMAX and a multiple of nothing (the image zero-pads), N <= 1032, T*nout <= the
 *   drain's 16-bit block count, gs >= 2 and gp >= 2 (s2.5: the serialiser needs a quad's
 *   finals at least two cycles apart), and one head's images inside one 8 KB buffer --
 *   which is the fact the whole design turns on (s1.1): q is 825 of 1,024 words and each
 *   weight plane 450 of 512 at Moonshine's shape.
 *
 * ON NOT POLLING A DEVICE WHOSE FINISH TIME YOU KNOW.  The LayerNorm lane measures 748x its
 * predicted cost, traced to a 989-cycle status poll on the board against 9 in simulation.
 * THE HAZARD IS REAL AND DOES NOT TRANSFER HERE, and the reason is a ratio rather than a
 * difference: one poll quantum against a dispatch's length.
 *
 *     LayerNorm, 28 rows x 288      8,064 cycles =  8.2 quanta   one quantum is 12.3 %
 *     attention, one head          78,216 cycles = 79.1 quanta   one quantum is  1.3 %
 *
 * So polling costs this unit 48 * 989/2 = 23,736 cycles, 0.004 % of a QATU steady encoder.
 * It is still not free and it still burns hart 0, so this kernel SPINS ON rdcycle TO THE
 * COMPUTED COMPLETION FIRST and only then polls -- turning ~79 cross-hart reads into ~1.
 * The estimate is deliberately SHORT (95 %), because overshooting the spin would add latency
 * that no poll can take back, while undershooting costs one extra poll.
 *
 * WHAT THIS KERNEL DOES NOT DO.  ATTENTION_UNIT.md s5.2's claim that the staging hides behind
 * the array (25 k cycles against 78 k) needs the NEXT head staged while this one runs.  This
 * kernel is synchronous: it stages, dispatches, waits, repeats.  The pipelined variant is a
 * real change and is not made here, so the staging in s5.2 is ADDITIVE in this version and
 * the measured number will show it.
 *
 * THE 12-BYTE DRAIN OVERRUN (s2.2b precondition 2, s8.3), handled without the codegen fix:
 * the drain writes whole 64-byte blocks, so head b writes up to 63 bytes into head b+1's
 * output -- which head b+1 then writes correctly.  Only the LAST head can overrun the tensor,
 * and only that one is drained into a scratch block and copied.  47 direct drains, 1 copy.
 */
#include <stddef.h>
#include <stdint.h>
#include <math.h>
#include "pext.h"

/* THE FALLBACK IS THE SPECIFICATION, WRITTEN OUT.  Not a call into the model's curated
 * matmul and softmax, and not an #include of them: ModelBlaster renames only the tokens of a
 * file's OWN op, so a literal `kernel_matmul_b_s8` here stays unrenamed and does not link,
 * while #including the sources compiles a second `pmmb_exact` / `mb_smx2_stats` / `smx2_out`
 * into a translation unit that already has the model's.  Both were found by compiling, and
 * both are the same lesson: a curated kernel is one file in a shared translation unit.
 *
 * So the fallback is the reference's own expression, term for term, per head -- which is what
 * `attention_s8` is DEFINED as.  It is the rare path (every Moonshine shape fits the unit),
 * and it holds M*S rather than B*M*S: 54 kB at the encoder's shape, not 436 kB. */

#define MBXA_GSMAX   64
#define MBXA_NMAX  1032
#define MBXA_BUFW  1024            /* words in one activation buffer: the 8 KB bound */

/* ---- the two image builders, which ARE the s2.2 contract ------------------------------- */

/*
 * B86 -- THE STAGING IS 76 % OF THIS OP AND IT MOVES ONE BYTE AT A TIME.
 *
 * Counted off the shipping encoder image's own disassembly (out/b81_enc_f40/enc_q16/dis.txt,
 * <kernel_attention_s8_moonshine_enc> 800087cc..80008f5a) against the run's own counters:
 *
 *     array (48 x steps = 48 x 74,250)      3,564,000   22.0 %   deterministic, s2.4
 *     attn_fence_cyc + attn_wait_cyc          294,115    1.8 %   MEASURED counters
 *     ------------------------------------------------------------------------------
 *     hart-0 staging, residual             12,321,015   76.2 %   at 9.53 cycles per BYTE
 *
 * The array is at 78,153 cycles/head against s2.4's simulated 78,216 -- 0.08 % -- so the UNIT
 * IS EXONERATED and the 5.82 MAC/cycle is a software number.  At the array floor the same
 * silicon does 26.4 MAC/cycle, 82 % of the 32 peak.
 *
 * WHERE THE 9.53 CYCLES PER BYTE GO.  Three innermost loops, all at 7-10 instructions per byte:
 *
 *   mbxa_build_q  80008aa4..80008aba   7 instr/byte  add,lb,add,addi,sb,sext.w,blt
 *                 -- a byte loop between two aligned(64) images, which -mtune=rocket will not
 *                    widen because it cannot prove the alignment.  B76's finding exactly.
 *   mbxa_build_w  80008b28..80008b4c  10 instr/byte  and TWO of them are `bge` bounds tests
 *      k quads                           on `row < N` (loop-INVARIANT) and `w < D` (a trip
 *                                        count split), re-evaluated per byte.
 *   mbxa_build_w  80008b78..80008b9a  10 instr/byte  the same two tests, plus `add a1,a1,s0`
 *      v^T quads                         with s0 = D: a byte-wise STRIDED TRANSPOSE.
 *
 * WHAT THIS FIXES, and each is value-preserving by construction:
 *   (1) the invariant bounds test is hoisted and the ranged one becomes a trip-count split,
 *       so the innermost body is a copy or a zero and never a test;
 *   (2) the two contiguous runs (q's D bytes, k's D bytes) are copied at a width PROVED ONCE
 *       PER CALL from the two bases, the strides and the length -- B76's pblk_align, for the
 *       same reason and with the same shapes: every pointer here is a gen/buffers.c
 *       intermediate or an mbxr image at aligned(64), and D = 36 proves 4;
 *   (3) v^T's four planes read COLUMNS 4j+0..4j+3 of v, which are four CONSECUTIVE bytes, so
 *       the four strided byte loads become ONE strided 4-byte load feeding four planes.
 *       That is the only one of the three that removes memory TRAFFIC rather than
 *       instructions, so it is the only one expected to compound with the clock.
 *
 * ATTENTION_UNIT.md s5.2 prices staging at ~25,250 cycles/head.  It measures 256,688 -- 10x.
 * s5.2's q line says "9 word copies + a zero store per row"; the shipped code is a byte loop.
 * s10.4 flagged that the staging is ADDITIVE in this synchronous kernel, which is true and is
 * a separate factor; it did not flag that the constant being added is 10x its quoted value.
 *
 * NOTE WHAT THIS IS NOT.  It is NOT the pipelined variant of s10.4.  Pipelining alone is worth
 * only 1.32x here (max(staging, array) barely beats their sum when staging is 3.3x the array);
 * the staging constant is worth 3.16x on its own and needs no second buffer and no schedule
 * change.  See test/B86_ATTN_BAND.md.  -DMBP_B86=1 selects it.
 */
#ifndef MBP_B86
#define MBP_B86 0
#endif
/* LIVE-PATH PROOF, not a feature.  Each value perturbs one of the new routes visibly in the
 * OUTPUT; a staged image has no arithmetic to absorb a flipped bit, so the poison is the byte:
 *   1  the q run copy        2  the k run copy        3  the v^T 4-plane gather */
#ifndef MBP_B86_POISON
#define MBP_B86_POISON 0
#endif

/*
 * B86d -- PIPELINE THE STAGING AGAINST THE LANE.  After B86 the per-head cost is staging
 * 114,429 on hart 0 and 80,361 on hart 1 (array 74,250 + fill/drain fences), and they run
 * STRICTLY IN SEQUENCE because mbxr_rt_attn_head issues and waits in one call.  With the
 * issue/wait split in mbxr_rt.h the next head can be staged inside the current head's wait,
 * making the cost max(staging, hart 1) instead of their sum.
 *
 * TWO BUFFER SETS, and the reason is not symmetry.  Hart 1's fill reads the DRAM images and
 * its fence is INSIDE hart 1's job, where hart 0 cannot see it -- so hart 0 must never stage
 * into the set it just handed over.  `tail` needs no second copy: the drain's copy-out for
 * head b sits between wait(b) and issue(b+1), so it is never live across a dispatch.
 *
 * ORDERING, and it is what makes the failure path safe: issue(b+1) happens only AFTER
 * wait(b) has returned MBXR_OK.  A failed wait therefore leaves head b+1 STAGED BUT NOT
 * ISSUED and nothing in flight, so `goto software` needs no unwind.  test/b86d_attn_gate.sh
 * has a forced-failure arm that exercises exactly that, because it is where a bug would go.
 */
#ifndef MBP_B86D
#define MBP_B86D 0
#endif
/* LIVE-PATH PROOF.  1 pins the buffer selector to set 0, which is exactly the race the
 * second set exists to prevent: hart 0 restages into the images hart 1 is still filling.
 * 2 issues head b+1 BEFORE wait(b) returns, racing the single global mbxr_rt_job. */
#ifndef MBP_B86D_POISON
#define MBP_B86D_POISON 0
#endif

/*
 * B86g -- RESIDENT CROSS-ATTENTION WEIGHT IMAGES.
 *
 * At M = 1 the lane's array does `M*(qs(gs+1) + qp(gp+1))` = 450 cycles per head, and
 * `mbxa_build_w` costs ~78,000 to feed it -- 173x.  That ratio is why the decoder fusion is
 * a 1.98x REGRESSION with naive staging (100,538,634 against an unfused 50,713,242) and a
 * 3.5x win with resident images (14,373,642).  These images are the PRECONDITION for the
 * fusion, not an optimisation on top of it.  B86G_RESIDENT_IMAGES_BAND.md has the arithmetic.
 *
 * WHAT IS RESIDENT AND WHY IT IS SAFE.  The decoder's cross-attention K and V ARE THE ENCODER
 * OUTPUT: computed once, unchanged across all 24 decode steps.  So the weight image built from
 * them is also unchanged, and 1,152 head-builds collapse to 48.  Self-attention's K/V grow
 * every step and are NOT resident -- and they do not need to be: `build_w` writes scale with
 * S, so self averages 1,536 B against cross's 14,400, 10.7 %.
 *
 * THE KEY IS (k, v, S, Dv, gs, qs, gp, qp) AND THAT IS WHAT MAKES IT CORRECT.  S is in the
 * key, and self-attention's S is the STEP INDEX -- it changes every step, so a self entry can
 * never be hit twice and a stale self image cannot be served.  Cross-attention's S is the
 * encoder length and is constant, so it hits.  A wrong hit would need two different tensors at
 * the same two addresses with all six dims equal; in this model each cross layer has its own
 * `buf_..._encoder_attn_{k,v}_proj`.
 *
 * MBXA_RES_MINS keeps self-attention OUT OF THE TABLE, which is a throughput guard rather
 * than a correctness one: without it 1,152 single-use self entries would fill all 48 slots
 * and evict the cross images that are the entire point.  At the decoder's shapes cross is
 * S = 165 and self is S <= 24, so 64 separates them with room on both sides.  A full table
 * falls back to the scratch image rather than evicting -- the cross entries are installed
 * first and must not be displaced.
 */
#ifndef MBP_B86G
#define MBP_B86G 0
#endif
#ifndef MBXA_RES_MINS
#define MBXA_RES_MINS 64
#endif
#ifndef MBXA_RESIDENT_N
#define MBXA_RESIDENT_N 48
#endif
/* LIVE-PATH PROOF.  1 makes the lookup match slot 0 whatever the key is -- i.e. serves
 * another head's weight image, which is exactly the bug residency introduces and exactly
 * what MBP_B86D_POISON=1 caught at max_abs_err 142 for the buffer selector. */
#ifndef MBP_B86G_POISON
#define MBP_B86G_POISON 0
#endif
/* One spelling at each dispatch site, so the two loops cannot drift apart on which image
 * they actually hand the lane. */
#if MBP_B86G
#define MBXA_W_USE            w_use
#define MBXA_WSET_USE(i)      wuse[i]
#else
#define MBXA_W_USE            w_img
#define MBXA_WSET_USE(i)      wset[i]
#endif
#if MBP_B86D_POISON == 1
#define MBXA_BSEL(x) 0
#else
#define MBXA_BSEL(x) ((x) & 1)
#endif


#if MBP_B86
/* may_alias because int8_t buffers are read and written through these; NOT aligned(1) -- the
 * whole point is that the caller has proved these ARE aligned. */
typedef uint32_t mbxa_u32 __attribute__((may_alias));
typedef uint64_t mbxa_u64 __attribute__((may_alias));

/* The width every (src, dst) pair in one call has in common.  A stride and a length are both
 * non-negative here (the lane's precondition test has already rejected the degenerate cases). */
static inline int mbxa_width(uintptr_t u)
{
	if ((u & 7u) == 0u)
		return 8;
	if ((u & 3u) == 0u)
		return 4;
	return 1;
}

/* One contiguous run at a width the CALLER proved.  The width test is per RUN (36 bytes at
 * Moonshine's shape), not per byte, so it costs 1 instruction per 36 against the 7 it saves. */
static inline __attribute__((always_inline))
void mbxa_run(int8_t *d, const int8_t *s, int n, int wid)
{
	int i;

	if (wid == 8) {
		mbxa_u64 *dw = (mbxa_u64 *)d;
		const mbxa_u64 *sw = (const mbxa_u64 *)s;

		for (i = 0; i < (n >> 3); i++)
			dw[i] = sw[i];
		for (i = (n >> 3) << 3; i < n; i++)
			d[i] = s[i];
	} else if (wid == 4) {
		mbxa_u32 *dw = (mbxa_u32 *)d;
		const mbxa_u32 *sw = (const mbxa_u32 *)s;

		for (i = 0; i < (n >> 2); i++)
			dw[i] = sw[i];
		for (i = (n >> 2) << 2; i < n; i++)
			d[i] = s[i];
	} else {
		for (i = 0; i < n; i++)
			d[i] = s[i];
	}
}

/* The zero tail.  Always 8-aligned in practice (a quad starts on a word and the bias word is
 * 8 bytes), but proved rather than assumed, the same way. */
static inline __attribute__((always_inline))
void mbxa_zrun(int8_t *d, int n, int wid)
{
	int i;

	if (wid == 8) {
		mbxa_u64 *dw = (mbxa_u64 *)d;

		for (i = 0; i < (n >> 3); i++)
			dw[i] = 0;
		for (i = (n >> 3) << 3; i < n; i++)
			d[i] = 0;
	} else if (wid == 4) {
		mbxa_u32 *dw = (mbxa_u32 *)d;

		for (i = 0; i < (n >> 2); i++)
			dw[i] = 0;
		for (i = (n >> 2) << 2; i < n; i++)
			d[i] = 0;
	} else {
		for (i = 0; i < n; i++)
			d[i] = 0;
	}
}
#endif /* MBP_B86 */


/* q image: T rows of `gs` words, row t at word t*gs, the bytes past D ZEROED.  The zeros are
 * load-bearing (s2.2): the array reads gs*8 bytes whatever D is, and they are what make the
 * weight planes' own padding harmless. */
static void mbxa_build_q(const int8_t *q, int T, int D, int gs, int8_t *img)
{
	int t, W = gs * 8;
#if MBP_B86
	/* Proved ONCE per call, outside every loop: both bases, both row strides and the run
	 * length.  D = 36 and W = 40 give 4 at Moonshine's shape. */
	const int wid = mbxa_width((uintptr_t)q | (uintptr_t)img |
				   (uintptr_t)(unsigned)D | (uintptr_t)(unsigned)W);

	for (t = 0; t < T; t++) {
		const int8_t *src = q + (size_t)t * D;
		int8_t *dst = img + (size_t)t * W;

		mbxa_run(dst, src, D, wid);
#if MBP_B86_POISON == 1
		dst[0] ^= 1;
#endif
		mbxa_zrun(dst + D, W - D, wid);
	}
#else
	int d;

	for (t = 0; t < T; t++) {
		const int8_t *src = q + (size_t)t * D;
		int8_t *dst = img + (size_t)t * W;
		for (d = 0; d < D; d++) dst[d] = src[d];
		for (d = D; d < W; d++) dst[d] = 0;
	}
#endif
}

/* THE ATTENTION IMAGE'S PLANE COUNT.  Defined HERE, immediately above the builder, because
 * ModelBlaster's codegen copies this region into gen/kernels.c and a definition further up the
 * file does not travel with it -- and because the HOST-C golden is compiled with MB_PEXT_HW=0,
 * where roccmoon/mbxr_rt.h is never included and MBXR_NCH therefore does not exist.  Both of
 * those bit on the first attempt.  It follows MBXR_NCH when that is visible (the target build,
 * where the engine's array width is what the lane consumes) and falls back to 4 otherwise. */
#ifndef MBXA_NCH
# ifdef MBXR_NCH
#  define MBXA_NCH MBXR_NCH
# else
#  define MBXA_NCH 4
# endif
#endif

/* Weight image, planar: plane c is a contiguous 2^lgpw-word region, and the MBXA_NCH planes
 * are consecutive.  Plane c holds `qs` quads of [ zero bias word | gs words of k row
 * MBXA_NCH*j+c ] at kbase, then `qp` quads of [ zero bias word | gp words of v^T row
 * MBXA_NCH*j+c ] at vtbase.
 *
 * THE PLANE COUNT IS A PARAMETER AND WAS A LITERAL FOUR UNTIL 2026-09-19.  mbxr.c has done
 * this correctly for the ENGINE's image at 23 of 23 sites (n = (t*Q + q)*NCH + r) since it
 * was written; the attention kernel was simply never brought along.  At NCH = 8 the lane
 * reads NCH planes and the array produces NCH finals a quad, so a four-plane 4j+c image
 * feeds it rows that were never written: |acc| passes 2^24 and mbxa_unit raises err[2] on
 * every dispatch.  On garden that read attn_lane 0, attn_fallback 6, 111x slow, and
 * max_abs_err 0 -- right answers from the software fallback, so nothing else could see it.
 * At MBXA_NCH = 4 every expression below folds to exactly what it folded to before.
 *
 * THE BIAS WORD MUST BE ZERO (s2.2b precondition 4): the block relies on mbxr_mac's `clr`
 * step loading acc[c] <= w[c][31:0], so a non-zero word there is added to every output of
 * that quad.  Rows past N or D need NOT be zeroed (s2.2b, the non-requirement): their
 * outputs are dropped before the softmax lane. */
/* Smallest plane (log2 words) that holds `used` words, clamped to mbxr_engine.v's 3..10. */
static inline int mbxa_lgpw_for(int used)
{
	int lg = 3;

	while (lg < 10 && (1 << lg) < used) {
		lg++;
	}
	return lg;
}

static void mbxa_build_w(const int8_t *k, const int8_t *v, int N, int D,
			 int gs, int qs, int gp, int qp, int lgpw,
			 int kbase_w, int vtbase_w, int8_t *img)
{
	const size_t plane = (size_t)1 << lgpw;          /* words per plane */
#if MBP_B86
	const int W = gs * 8, Wp = gp * 8;
	const int wid = mbxa_width((uintptr_t)k | (uintptr_t)img |
				   (uintptr_t)(unsigned)D | (uintptr_t)(unsigned)W |
				   (uintptr_t)(unsigned)Wp);
	int c, j, w;

	/* k quads.  `row < N` is loop-INVARIANT and `w < D` is a trip-count split, so the
	 * innermost body becomes a copy or a zero and never a test. */
	for (c = 0; c < MBXA_NCH; c++) {
		int8_t *P = img + (size_t)c * plane * 8;

		for (j = 0; j < qs; j++) {
			int8_t *quad = P + (size_t)(kbase_w + j * (gs + 1)) * 8;
			int row = MBXA_NCH * j + c;
			int ncp = (row < N) ? (D < W ? D : W) : 0;

			mbxa_zrun(quad, 8, 8);                          /* the bias word */
			if (ncp)
				mbxa_run(quad + 8, k + (size_t)row * D, ncp, wid);
#if MBP_B86_POISON == 2
			quad[8] ^= 1;
#endif
			mbxa_zrun(quad + 8 + ncp, W - ncp, wid);
		}
	}

	/* v^T quads, MBXA_NCH PLANES AT A TIME.  Plane c of quad j is column MBXA_NCH*j+c of v,
	 * so the planes read consecutive bytes of each row -- one strided read instead of one per
	 * plane, which is the only part of B86 that removes memory traffic rather than
	 * instructions.  Same bytes, same destinations, same order within each plane.  The
	 * four-byte word-load below is guarded at MBXA_NCH == 4: it unpacks exactly four columns
	 * from a uint32, so it is an NCH = 4 optimisation and not a layout rule. */
	for (j = 0; j < qp; j++) {
		int8_t *quad[MBXA_NCH];
		int ncol = D - MBXA_NCH * j;
		int nrow = (N < Wp) ? N : Wp;

		if (ncol > MBXA_NCH)
			ncol = MBXA_NCH;
		if (ncol < 0)
			ncol = 0;
		for (c = 0; c < MBXA_NCH; c++) {
			quad[c] = img + (size_t)c * plane * 8 +
				  (size_t)(vtbase_w + j * (gp + 1)) * 8;
			mbxa_zrun(quad[c], 8, 8);                       /* the bias word */
		}
#if MBXA_NCH == 4
		if (ncol == 4 && (((uintptr_t)v | (uintptr_t)(unsigned)D |
				   (uintptr_t)(unsigned)(4 * j)) & 3u) == 0u) {
			/* All four columns in range and the group 4-aligned: one word load per row.
			 * RISC-V is little-endian, so byte c of the word is column 4j+c. */
			for (w = 0; w < nrow; w++) {
				uint32_t x = *(const mbxa_u32 *)(v + (size_t)w * D + 4 * j);

				quad[0][8 + w] = (int8_t)(uint8_t)(x);
				quad[1][8 + w] = (int8_t)(uint8_t)(x >> 8);
				quad[2][8 + w] = (int8_t)(uint8_t)(x >> 16);
				quad[3][8 + w] = (int8_t)(uint8_t)(x >> 24);
			}
		} else
#endif
#if MBP_B101U && MBXA_NCH == 8
		/* TWO 32-BIT LOADS, NOT ONE 64-BIT ONE, AND THE SHAPE IS WHY.  The natural twin
		 * of B86's word load is a doubleword, and it is UNREACHABLE on this model: the row
		 * stride is D and Moonshine's head_dim is 36, so `D & 7 == 4` and consecutive rows
		 * are only 4-aligned.  Measured before it was believed -- the 8-wide guard never
		 * fired and the instruction count did not move.  Two ALIGNED words carry the same
		 * eight columns under the precondition that does hold, `D & 3 == 0`. */
		if (ncol == 8 && (((uintptr_t)v | (uintptr_t)(unsigned)D |
				   (uintptr_t)(unsigned)(8 * j)) & 3u) == 0u) {
			for (w = 0; w < nrow; w++) {
				const int8_t *s8 = v + (size_t)w * D + 8 * j;
				uint32_t lo = *(const mbxa_u32 *)s8;
				uint32_t hi = *(const mbxa_u32 *)(s8 + 4);

				quad[0][8 + w] = (int8_t)(uint8_t)(lo);
				quad[1][8 + w] = (int8_t)(uint8_t)(lo >> 8);
				quad[2][8 + w] = (int8_t)(uint8_t)(lo >> 16);
				quad[3][8 + w] = (int8_t)(uint8_t)(lo >> 24);
				quad[4][8 + w] = (int8_t)(uint8_t)(hi);
				quad[5][8 + w] = (int8_t)(uint8_t)(hi >> 8);
				quad[6][8 + w] = (int8_t)(uint8_t)(hi >> 16);
				quad[7][8 + w] = (int8_t)(uint8_t)(hi >> 24);
			}
		} else
#endif
		{
			for (w = 0; w < nrow; w++) {
				const int8_t *s = v + (size_t)w * D + MBXA_NCH * j;

				for (c = 0; c < ncol; c++)
					quad[c][8 + w] = s[c];
			}
		}
#if MBP_B86_POISON == 3
		quad[0][8] ^= 1;
#endif
		/* Rows past N are zero; a plane whose column is past D is zero throughout. */
		for (c = 0; c < MBXA_NCH; c++) {
			int kept = (c < ncol) ? nrow : 0;

			mbxa_zrun(quad[c] + 8 + kept, Wp - kept, wid);
		}
	}
#else
	int c, j, w, b;

	for (c = 0; c < MBXA_NCH; c++) {
		int8_t *P = img + (size_t)c * plane * 8;
		/* k quads: row MBXA_NCH*j+c of k, gs words, behind a zero bias word */
		for (j = 0; j < qs; j++) {
			int8_t *quad = P + (size_t)(kbase_w + j * (gs + 1)) * 8;
			int row = MBXA_NCH * j + c;
			for (b = 0; b < 8; b++) quad[b] = 0;             /* the bias word */
			for (w = 0; w < gs * 8; w++)
				quad[8 + w] = (row < N && w < D) ? k[(size_t)row * D + w] : 0;
		}
		/* v^T quads: row MBXA_NCH*j+c of v^T, i.e. that COLUMN of v, gp words */
		for (j = 0; j < qp; j++) {
			int8_t *quad = P + (size_t)(vtbase_w + j * (gp + 1)) * 8;
			int col = MBXA_NCH * j + c;
			for (b = 0; b < 8; b++) quad[b] = 0;
			for (w = 0; w < gp * 8; w++)
				quad[8 + w] = (col < D && w < N) ? v[(size_t)w * D + col] : 0;
		}
	}
#endif
}

#if MBP_B86G
/* ---- B86g: the resident weight-image table -------------------------------------------- */

struct mbxa_res_key {
	const int8_t *k, *v;
	int S, Dv, gs, qs, gp, qp;
};

static struct mbxa_res_key mbxa_res_key[MBXA_RESIDENT_N];
static int8_t mbxa_res_img[MBXA_RESIDENT_N][MBXA_NCH * 512 * 8] __attribute__((aligned(64)));
static int mbxa_res_n;

/*
 * B86g -- AN OPEN-ADDRESSED INDEX, because the linear scan was measured and it is not free.
 * The first version scanned all live entries: the i-th miss compares i keys, so the ENCODER's
 * 48 misses cost 0+1+...+47 = 1,128 key comparisons and measured +84,174 cycles on the
 * attention row (B86G_RESULT.md, P29 missed for exactly this reason -- I banded the row as
 * unchanged while holding an O(n) search in my own code).  The DECODER is worse: 48 misses
 * plus 1,104 hits at mean depth 24 is 27,624 comparisons, ~2.06 M cycles, 5.7 % of the win.
 *
 * A direct (layer, head) index is not available -- the kernel is not told either -- so this
 * is a power-of-two open-addressed table on the K pointer, which is what actually
 * distinguishes entries.  MBXA_RES_HASH must stay >= 2 * MBXA_RESIDENT_N so the load factor
 * stays under 1/2 and probing stays short; the table never evicts, so a slot once filled is
 * never cleared and probing terminates at the first empty.
 */
/* Default ON, but retained as a define so scan-vs-index is ONE DEFINE APART and therefore
 * measurable.  I replaced the scan outright first, which would have made the improvement I
 * had just argued for impossible to measure on silicon -- the same mistake as banding a
 * quantity nothing can read. */
#ifndef MBXA_RES_INDEX
#define MBXA_RES_INDEX 1
#endif
#define MBXA_RES_HASH 128
static short mbxa_res_ix[MBXA_RES_HASH];        /* entry index + 1; 0 = empty */
static unsigned mbxa_res_hinit;

static inline unsigned mbxa_res_h(const int8_t *k)
{
	/* the buffers are aligned(64), so the low 6 bits carry nothing */
	return (unsigned)((((uintptr_t)k >> 6) * 2654435761u) & (MBXA_RES_HASH - 1));
}
/* counted, because "48 builds not 1,152" is the whole claim and a claim nobody can count
 * is a claim nobody can check */
uint32_t mbxa_res_hit, mbxa_res_miss, mbxa_res_full, mbxa_res_bypass;

/* Returns the weight image to hand the lane, building it only if it is not already resident.
 * `scratch` is the caller's own w_img and is used whenever the entry is not cacheable. */
static int8_t *mbxa_w_resident(const int8_t *kb, const int8_t *vb, int S, int Dv,
			       int gs, int qs, int gp, int qp, int lgpw,
			       int kbase_w, int vtbase_w, int8_t *scratch)
{
	int i;
	unsigned hslot = 0;

	(void)hslot;

	/* self-attention shapes never enter the table -- see MBXA_RES_MINS above */
	if (S < MBXA_RES_MINS) {
		mbxa_res_bypass++;
		mbxa_build_w(kb, vb, S, Dv, gs, qs, gp, qp, lgpw, kbase_w, vtbase_w, scratch);
		return scratch;
	}
#if MBXA_RES_INDEX
	if (!mbxa_res_hinit) {
		for (i = 0; i < MBXA_RES_HASH; i++) mbxa_res_ix[i] = 0;
		mbxa_res_hinit = 1;
	}
	{
		unsigned h = mbxa_res_h(kb);

		while (mbxa_res_ix[h]) {
			const struct mbxa_res_key *e = &mbxa_res_key[mbxa_res_ix[h] - 1];

#if MBP_B86G_POISON == 1
			if (1) {               /* serve slot 0 whatever the key is */
				mbxa_res_hit++;
				return mbxa_res_img[0];
			}
#else
			if (e->k == kb && e->v == vb && e->S == S && e->Dv == Dv &&
			    e->gs == gs && e->qs == qs && e->gp == gp && e->qp == qp) {
				mbxa_res_hit++;
				return mbxa_res_img[mbxa_res_ix[h] - 1];
			}
#endif
			h = (h + 1) & (MBXA_RES_HASH - 1);
		}
		hslot = h;                     /* the empty slot this key hashes to */
	}
#else
	/* the original O(n) scan, kept so the index can be A/B'd against it */
	for (i = 0; i < mbxa_res_n; i++) {
		const struct mbxa_res_key *e = &mbxa_res_key[i];

#if MBP_B86G_POISON == 1
		if (1) {
#else
		if (e->k == kb && e->v == vb && e->S == S && e->Dv == Dv &&
		    e->gs == gs && e->qs == qs && e->gp == gp && e->qp == qp) {
#endif
			mbxa_res_hit++;
			return mbxa_res_img[i];
		}
	}
#endif
	if (mbxa_res_n >= MBXA_RESIDENT_N) {
		/* full: fall back rather than evict -- the cross images went in first */
		mbxa_res_full++;
		mbxa_build_w(kb, vb, S, Dv, gs, qs, gp, qp, lgpw, kbase_w, vtbase_w, scratch);
		return scratch;
	}
	i = mbxa_res_n++;
	mbxa_res_key[i].k = kb;   mbxa_res_key[i].v = vb;
	mbxa_res_key[i].S = S;    mbxa_res_key[i].Dv = Dv;
	mbxa_res_key[i].gs = gs;  mbxa_res_key[i].qs = qs;
	mbxa_res_key[i].gp = gp;  mbxa_res_key[i].qp = qp;
#if MBXA_RES_INDEX
	mbxa_res_ix[hslot] = (short)(i + 1);
#endif
	mbxa_build_w(kb, vb, S, Dv, gs, qs, gp, qp, lgpw, kbase_w, vtbase_w, mbxa_res_img[i]);
	mbxa_res_miss++;
	return mbxa_res_img[i];
}
#endif /* MBP_B86G */

/* ---- the softmax term of the reference, WHICH IS INTEGER AND WAS WRITTEN HERE IN FLOAT ---
 *
 * THE DEFECT THIS FIXES, measured (B55 arm A3, B57 arm C1).  With the drain's 64-byte phase
 * fixed the board still read max_abs_err = 6, and the per-head differential had already said
 * why: the twelve heads whose drain base was aligned all along differ from this fallback by
 * 15-237 bytes of 5,940 at max |diff| 1-16 -- small, scattered, numeric.
 *
 * `attention_s8` is DEFINED as the composition of the three records the collapsing rewrite
 * leaves in the IR, and the middle one is `softmax_s8`, which on this target is
 * `pext_nl_softmax_s8_pext_int_memo2.c` -- an INTEGER pipeline whose own header says
 * `accuracy_class: numeric_drift`, i.e. it is deliberately NOT the float expression.  The
 * unit reproduces it: mbxa_smx_table below builds `ex[]`, `om` and `s` with the same four
 * lines that kernel does (nl_f2ms, nl_f2ms_recip, the log2e Q31 fold, int_exp2_q31 o
 * nl_scale).  THE FALLBACK DID NOT: it computed expf / divide / roundf, so the host-C golden
 * baked from it was the FLOAT composition and the board was being compared against a
 * reference the model does not run.  Two of the three terms were the curated kernels'; the
 * softmax term was not.
 *
 * mbxa_smx_out is smx2_out's body under a different name ON PURPOSE: this file's own header
 * records that #including a curated kernel's source compiles a SECOND `smx2_out` into a
 * translation unit that already has the model's.  The memo/cutoff machinery around it is a
 * cost optimisation that changes no bit and is left out.
 *
 * -DMBXA_SOFT_SMX_INT=0 compiles the float expression back in for an A/B. */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif

#ifndef MBXA_SOFT_SMX_INT
#define MBXA_SOFT_SMX_INT 1
#endif

/* The softmax lane's 256 table values and two scalars, line for line as smx_lane's own
 * attn_smx_cfg builds them -- and line for line as kernel_softmax_s8 builds them.  OUTSIDE
 * the __ZEPHYR__ guard since B57, because the fallback needs it too and the host-C golden is
 * baked from the fallback. */
static void mbxa_smx_table(float scale_in, float scale_out,
			   uint32_t ex[256], int32_t *om_out, int *s_out)
{
	int32_t im, om;
	int is, os, k;

	nl_f2ms(scale_in, &im, &is);
	nl_f2ms_recip(scale_out, &om, &os);
	{
		uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
		while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
		im = (int32_t)p;
	}
	for (k = 0; k < 256; k++)
		ex[k] = int_exp2_q31((int32_t)nl_scale((int64_t)(-k) << 16, im, is));
	*om_out = om;
	*s_out = os + 32 - 8;
}

#if MBXA_SOFT_SMX_INT
static int8_t mbxa_smx_out(uint32_t ev, uint64_t q_hi, uint64_t q_lo, int32_t om, int s)
{
	uint64_t p32 = (uint64_t)ev * q_hi + (((uint64_t)ev * q_lo) >> 32);
	int64_t v_q8;

	if (s >= 0 && s < 62) {
		uint64_t p = (p32 * (uint64_t)(uint32_t)om + (1ull << 30)) >> 31;
		if (s > 0) p = (p + (1ull << (s - 1))) >> s;
		v_q8 = (int64_t)p;
	} else {
		v_q8 = nl_scale((int64_t)p32, om, s);
	}
	return nl_q8_to_s8(v_q8, -128, 127);
}
#endif

/* ---- the fallback: the reference's own composition, per head --------------------------- */
/* 320x320, not 1152x1152.  The first version sized this at the largest M*S it could imagine
 * and put 2.53 MB of .bss into every image that links this kernel -- for a path Moonshine
 * NEVER TAKES (every encoder shape fits the unit; M*S is 27,225).  It was not the cause of the
 * board stall (the map puts it at 0x807d7080, inside a 256 MB DRAM), but 2.53 MB of untaken
 * fallback is indefensible on a part whose whole model is 15 MB. 205 kB covers 7.5x the
 * encoder's need and refuses above it. */
#define MBXA_SCRATCH (320 * 320)
static int8_t mbxa_sc[MBXA_SCRATCH], mbxa_pr[MBXA_SCRATCH];

static void mbxa_software(const int8_t *q, const int8_t *k, const int8_t *v, int8_t *output,
			  int B, int M, int Dk, int S, int Dv,
			  float sq, float sk, float ssc, float sdiv, float spr, float sv,
			  float so, int amin, int amax)
{
	const float qk_total = (sq * sk) / (ssc * sdiv);
	const float av_total = (spr * sv) / so;
	int b, i, j, d;

	if ((long)M * S > MBXA_SCRATCH) return;          /* refuse rather than overrun */

	for (b = 0; b < B; b++) {
		const int8_t *qb = q + (size_t)b * M * Dk;
		const int8_t *kb = k + (size_t)b * S * Dk;
		const int8_t *vb = v + (size_t)b * S * Dv;
		int8_t *ob = output + (size_t)b * M * Dv;

		for (i = 0; i < M; i++)
			for (j = 0; j < S; j++) {
				int32_t acc = 0;
				float r;
				for (d = 0; d < Dk; d++)
					acc += (int32_t)qb[i * Dk + d] * (int32_t)kb[j * Dk + d];
				r = roundf((float)acc * qk_total);
				if (r < (float)amin) r = (float)amin;
				if (r > (float)amax) r = (float)amax;
				mbxa_sc[i * S + j] = (int8_t)r;
			}
#if MBXA_SOFT_SMX_INT
		{
			uint32_t ex[256];
			int32_t om;
			int sh;

			mbxa_smx_table(ssc, spr, ex, &om, &sh);
			for (i = 0; i < M; i++) {
				const int8_t *sr = mbxa_sc + (size_t)i * S;
				int8_t mx = sr[0];
				uint64_t sum = 0, inv, q_hi, q_lo;

				for (j = 1; j < S; j++) if (sr[j] > mx) mx = sr[j];
				for (j = 0; j < S; j++) sum += ex[(int)mx - (int)sr[j]];
				if (!sum) {
					for (j = 0; j < S; j++) mbxa_pr[i * S + j] = 0;
					continue;
				}
				inv = UINT64_MAX / sum;
				q_hi = inv >> 32;
				q_lo = inv & 0xffffffffull;
				for (j = 0; j < S; j++)
					mbxa_pr[i * S + j] =
						mbxa_smx_out(ex[(int)mx - (int)sr[j]], q_hi, q_lo, om, sh);
			}
		}
#else
		for (i = 0; i < M; i++) {
			const int8_t *sr = mbxa_sc + (size_t)i * S;
			int8_t mx = sr[0];
			float sum = 0.0f;
			for (j = 1; j < S; j++) if (sr[j] > mx) mx = sr[j];
			for (j = 0; j < S; j++) sum += expf(((float)sr[j] - (float)mx) * ssc);
			for (j = 0; j < S; j++) {
				float pj = expf(((float)sr[j] - (float)mx) * ssc) / sum;
				float r = roundf(pj / spr);
				if (r < 0.0f) r = 0.0f;
				if (r > 127.0f) r = 127.0f;
				mbxa_pr[i * S + j] = (int8_t)r;
			}
		}
#endif
		for (i = 0; i < M; i++)
			for (j = 0; j < Dv; j++) {
				int32_t acc = 0;
				float r;
				for (d = 0; d < S; d++)
					acc += (int32_t)mbxa_pr[i * S + d] * (int32_t)vb[d * Dv + j];
				r = roundf((float)acc * av_total);
				if (r < (float)amin) r = (float)amin;
				if (r > (float)amax) r = (float)amax;
				ob[i * Dv + j] = (int8_t)r;
			}
	}
}

#ifdef __ZEPHYR__
#include "roccmoon/mbxr_rt.h"
#include "roccmoon/mbxr_lanes.h"
#include "fexact32.h"

/* ---- MBP_B100_TAX: where a lane dispatch's fixed cost ACTUALLY goes --------------------
 *
 * B86j decomposed a head into array / fence+wait / staging and found a RESIDUAL of
 * 17,639 cyc/head at M = 1 against 19,032 at M = 165 -- fixed while the array moved 165x --
 * and correctly refused to name a component for it.  It proposed four counters
 * (t_issue/t_wake/t_lane/t_spin) splitting that residual inside `mbxr_rt_attn_head`.
 *
 * THOSE FOUR WOULD HAVE MISSED MOST OF IT, and the arms already on disk say so.  B86i's F8
 * and G8 ran the SAME 1,344 engine dispatches and differ only in 1,920 attention heads, so
 * differencing their counters prices the whole round trip WITHOUT board time:
 *
 *     cycles_h0 delta / head   9,851     <- the ENTIRE mbxr_rt_attn_head call
 *     cycles_h1 delta / head   6,876     <- hart 1, inside mbxr_attn_dispatch
 *     (h0 - h1)   / head       2,975     <- the cross-hart handoff, all four of B86j's terms
 *     attention_s8 row / head 24,461
 *
 * So 14,610 cyc/head -- 60 % of the row -- is hart-0 kernel work OUTSIDE the dispatch call
 * entirely, where B86j's instrument does not reach and its modelled `staging` term put only
 * 4,058.  The residual is not the handoff; the handoff is 12 % of the row.
 *
 * These counters therefore partition THE WHOLE ROW rather than the round trip:
 *
 *     t_table   per dispatch   mbxa_smx_table's 256 int_exp2_q31 evaluations
 *     t_stage   per head       mbxa_build_q + mbxa_build_w / the resident lookup
 *     t_round   per head       the whole mbxr_rt_attn_head call
 *     t_lane    per head       HART 1's own delta for that head (mbxr_rt_job.cycles)
 *     t_copy    per head       the drain copy-out
 *     t_issue   per head       PIPELINED PATH ONLY: hart 0's job fill + k_sem_give
 *
 * t_round - t_lane is the cross-hart term.  It is NOT split further into wake and spin:
 * doing so needs hart 1 to stamp its own start, and hart 0 and hart 1 keep INDEPENDENT
 * `rdcycle` counters whose offset nothing in this tree has ever calibrated.  A 12 % term
 * does not justify shipping an uncalibrated cross-hart subtraction, and B86j's own lesson
 * is that a number which cannot be checked should not be banked.  It is reported lumped
 * and labelled, not apportioned.
 *
 * GUARDED, for the reason MBXR_RT_LUT is guarded: with MBP_B100_TAX off this file compiles
 * to the bytes it compiled to before, so no arm mid-A/B on another workstream differs in
 * the code that dispatches its lane.  Nothing here touches mbxr_rt.h or mbxr.h.
 */
#ifndef MBP_B100_TAX
#define MBP_B100_TAX 0
#endif
#if MBP_B100_TAX
typedef struct {
	uint64_t heads, dispatches;
	uint64_t t_table, t_stage, t_issue, t_round, t_lane, t_copy;
} mbxa_tax_t;
mbxa_tax_t mbxa_tax;
#define MBXA_TAX_DECL(v)   uint64_t v = 0
#define MBXA_TAX_T0(v)     ((v) = mbxr_rt_cyc())
#define MBXA_TAX_T1(f, v)  (mbxa_tax.f += mbxr_rt_cyc() - (v))
#define MBXA_TAX_ADD(f, x) (mbxa_tax.f += (uint64_t)(x))
#else
#define MBXA_TAX_DECL(v)   ((void)0)
#define MBXA_TAX_T0(v)     ((void)0)
#define MBXA_TAX_T1(f, v)  ((void)0)
#define MBXA_TAX_ADD(f, x) ((void)0)
#endif

/* The board identity-maps these windows -- mbxr_rt_p2v is `(void *)(uintptr_t)pa` -- so a
 * static buffer's virtual address IS its physical address.  Named rather than open-coded
 * because it is the one assumption here that a different linker script would break. */
#define mbxa_pa(p) ((uint64_t)(uintptr_t)(p))

/* (mt, sh) for the unit's requantiser: the reference's own `total` in exact binary32, copied
 * from attn_unit/attn_golden.c's attn_rq_consts, which had the fexact32 API right when I did
 * not.  The unit reproduces kernel_matmul_b_s8's binary32 tail, NOT kernel_linear_s8's Q0.31
 * chain (s1.4) -- which is why it costs 10 DSP rather than reusing the engine's. */
static int mbxa_rq(float sa, float sb, float so, float sd, uint32_t *mt, int *sh)
{
	fx32_t fa = fx32_dec(sa), fb = fx32_dec(sb), fo = fx32_dec(so), fd = fx32_dec(sd);
	fx32_t total;

	if (!fx32_scale_ok(fa) || !fx32_scale_ok(fb) || !fx32_scale_ok(fo) ||
	    !fx32_scale_ok(fd))
		return 0;
	total = fx32_div(fx32_mul(fa, fb), fx32_mul(fo, fd));
	*mt = (uint32_t)total.m;
	*sh = -total.e;
	return total.m != 0 && *sh >= 2 && *sh <= 62;
}

/* mbxa_smx_table has moved ABOVE mbxa_software and outside this guard (B57): the fallback
 * needs the same table, because the softmax term of the reference is integer and the host-C
 * golden is baked from the fallback.  The 256 `lcfg` writes that deliver it to the lane are
 * still done by mbxr_attn_dispatch on hart 1; the table is still computed here on hart 0.
 * Same split as the LayerNorm lane's affine table. */

/* ---- THE DRAIN -> HART-0 SEAM (MBXA_SEAM) ---------------------------------------------
 *
 * WHAT THIS IS FOR.  Every off-board check of this unit ends at the lane's OUTPUT PORT and
 * every board check begins AFTER hart 0's load; no instrument in this campaign has ever
 * compared the two.  The unit is correct on that boundary's far side -- 48 dispatches at the
 * model's real shapes through these very builders, 445,756 bytes, 0 differ (ATTENTION_UNIT.md
 * s3, ATTENTION_FILL_DIFFERENTIAL.md s15) -- and the board still reports max_abs_err
 * 144/116/133, NONDETERMINISTIC ACROSS BYTE-IDENTICAL IMAGES.  Timing-dependence with correct
 * addresses, no error bit and a fenced completion is what a cache seam looks like.
 *
 * THE INSTRUMENT IS A REGISTER THIS SoC ALREADY HAS, AND FOUR SAMPLES IN THIS TREE ALREADY
 * DRIVE IT.  `cache-controller@2010000` is the SiFive InclusiveCache control node (it is in
 * the elaborated address map, alongside clint@2000000 and the PLIC); +0x200 is Flush64, and
 * writing a physical address there flushes that block.  THE L2 IS INCLUSIVE, so the flush
 * back-invalidates the L1s as well -- one register does both levels.  samples/membench,
 * samples/tacit_smp, samples/tacit_dma and samples/dmic_capture all use exactly this loop.
 *
 * WHY IT IS THE HOST PEEK'S JOB DONE FROM THE ONLY SIDE THAT CAN DO IT.  The /dev/mem peek
 * was declined because peek_ram.py reads DRAM *behind* Rocket's caches, so `peek == guest`
 * cannot distinguish "the drain wrote wrong" from "DRAM is stale" -- and the fourth part that
 * would have made it decisive is "write back the L2 for that range before the peek".  THE PS
 * CANNOT DO THAT: M_AXI_GP0 lands on soc_ctrl_regs (reset/boot/status) in
 * src/pynqz2_rocket_top.v and reaches no TileLink bus, so 0x0201_0000 is not addressable from
 * the PS at all.  The guest can, and once the guest can, it need not peek: after the flush,
 * hart 0's own re-read comes from DRAM and IS the cache-bypassing read.
 *
 *   MBXA_SEAM=1  post-flush + probe.  Read the destination as hart 0 sees it now, flush,
 *                read it again, count the bytes that MOVED.  Nonzero => hart 0's pre-flush
 *                view was stale, which is the seam, named.
 *   MBXA_SEAM=2  pre-flush (q_img, w_img, destination) + post-flush (destination), NO probe.
 *                The candidate FIX with no measurement overhead, so a run that passes is a
 *                run whose rtf_steady can be collected.  The pre-flush covers the OTHER
 *                polarity, which a post-flush cannot: a line of the destination still DIRTY
 *                in hart 0's L1 from an earlier op is written back ON TOP of the drain's
 *                bytes whenever it happens to be evicted -- timing-dependent, addresses
 *                right, no error bit.
 *   MBXA_SEAM=3  2 + the probe.
 *
 * COST, DELIBERATELY BOUNDED: 93 blocks of destination and 360 of images per head, 48 heads.
 * mbxa_seam_flush_cyc reports it so the arm never has to argue about it.
 */
#ifndef MBXA_SEAM
#define MBXA_SEAM 0
#endif

/* THE DRAIN'S BASE MUST BE 64-BYTE ALIGNED.  On by default because it is a correctness fix,
 * measured; -DMBXA_DRAIN_ALIGN=0 compiles the defect back in for an A/B. */
#ifndef MBXA_DRAIN_ALIGN
#define MBXA_DRAIN_ALIGN 1
#endif

/* B86d's preconditions, checked HERE because MBXA_SEAM and MBXA_DRAIN_ALIGN are defined
 * above this point and not at MBP_B86D's own gate -- where they would both read as 0. */
#if MBP_B86D && MBXA_SEAM
#error "MBP_B86D is incompatible with MBXA_SEAM: two of the seam blocks capture PER-HEAD \
state either side of the dispatch, and under pipelining the dispatch for head b no longer \
sits between them -- the differential would compare the wrong head and report nothing about \
it. MBXA_SEAM is a debug flag for a defect already fixed; turn it off, or turn MBP_B86D off."
#endif
#if MBP_B86D && !MBXA_DRAIN_ALIGN
#error "MBP_B86D requires MBXA_DRAIN_ALIGN: the pipelined loop copies every head out of \
`tail` between wait(b) and issue(b+1), which is what keeps `tail` single-buffered."
#endif
#if MBXA_DRAIN_ALIGN
#define MBXA_DRAIN_DST  tail
#else
#define MBXA_DRAIN_DST  (last ? tail : ob)
#endif

#if MBXA_SEAM
/* SiFive InclusiveCache control node: cache-controller@2010000, reg-names "control". */
#define MBXA_L2_FLUSH64 (0x2010000UL + 0x200)

static uint64_t mbxa_seam_heads, mbxa_seam_changed_heads, mbxa_seam_changed_bytes;
static uint64_t mbxa_seam_flush_cyc, mbxa_seam_flush_blocks;

static void mbxa_l2_flush(const void *base, size_t bytes)
{
	volatile uint64_t *flush = (volatile uint64_t *)MBXA_L2_FLUSH64;
	uintptr_t a = (uintptr_t)base & ~(uintptr_t)63;
	uintptr_t end = (uintptr_t)base + bytes;

	__asm__ volatile("fence" ::: "memory");
	for (; a < end; a += 64) {
		*flush = (uint64_t)a;
		mbxa_seam_flush_blocks++;
	}
	__asm__ volatile("fence" ::: "memory");
}
#endif

#if (MBXA_SEAM & 1)
/* The pre-flush snapshot.  8 KB of .bss, and only in a probe build. */
static int8_t mbxa_seam_before[MBXA_BUFW * 8] __attribute__((aligned(64)));
#endif

#if (MBXA_SEAM & 4)
/* ---- MBXA_SEAM=4: THE PER-HEAD DIFFERENTIAL, ON THE BOARD ------------------------------
 *
 * `max_abs_err` is one number over the encoder's FINAL tensor, 12 ops downstream of the lane.
 * It says the image is wrong and nothing about WHERE, and every arm of this workstream has had
 * to reason backwards from it.  This runs `mbxa_software` -- the fallback, which IS the
 * reference composition written out, and which the host-C golden is baked from -- for the SAME
 * head, on the SAME activations, on the SAME hart, immediately after the lane's own result
 * lands, and prints the difference per head.
 *
 * WHAT THE SHAPE OF THE ANSWER MEANS, committed before the run so it cannot be fitted after:
 *   nw = 0 on every head          the lane's output is right and the residual is downstream
 *   one 64-byte block per head    a dropped or duplicated Put -- the drain, not the array
 *   the last block only           the 12-byte overrun / the tail copy (s8.3)
 *   a whole suffix from `first`   the drain stopping early
 *   scattered, few bytes, small   the requantiser's rounding, not a transport fault
 *   scattered, many bytes, large  the array or the softmax lane, i.e. NOT the seam at all
 *   head 0 clean, 1..7 wrong      per-head state, which s13 eliminated -- it would reopen it
 *
 * IT IS EXPENSIVE AND DELIBERATELY SO: ~54 k expf per head in soft float.  This arm's cycle
 * counts are meaningless and no rtf_steady is read off it.
 */
static int8_t mbxa_seam_gold[MBXA_BUFW * 8] __attribute__((aligned(64)));
static uint64_t mbxa_diff_head;
#endif

#endif /* __ZEPHYR__ */

/*
 * B101 -- THE PLANE STRIDE IS A POWER OF TWO AND AT MBXA_NCH = 8 IT ALIASES THE L1D.
 *
 * `lgpw` was a literal 9 at all ten call sites below, so the plane stride is
 * (1 << 9) * 8 = 4,096 BYTES EXACTLY.  Hart 0's L1D, read off the generated RTL
 * (gen-collateral/rockettile_dcache_tag_array.sv: RW0_addr [5:0] = 64 sets,
 * RW0_wmask [3:0] = 4 ways, 64-byte blocks), has a WAY SIZE of 64 * 64 = 4,096 bytes --
 * so addresses one plane apart land in the SAME SET.  mbxa_build_w's v^T loop writes
 * MBXA_NCH planes per row:
 *
 *     MBXA_NCH = 4   4 lines in one 4-way set   -- an exact fit
 *     MBXA_NCH = 8   8 lines in one 4-way set   -- a conflict miss on every row
 *
 * MEASURED, encoder shape S=165 Dk=Dv=36, b98b_lnon pair, cflags differing by -DMBXR_NCH=8
 * alone: the attention_s8 row goes 5,870,369 -> 14,108,167 cycles (2.4033x) while
 * mbxa_build_w x48 goes 1,645,402 -> 2,812,232 INSTRUCTIONS (1.7091x) on spike at the
 * board's own flags.  CPI therefore rose 1.4059x and the instruction count explains only
 * ~17 % of the cycles.  The written bytes barely move (14,400 -> 15,104 per head); the
 * SPAN doubles and the associativity does not.
 *
 * THE PLANE IS 46 % EMPTY AT NCH = 8, which is what makes this a one-line fix rather than a
 * relayout.  Words actually used per plane are vtbase_w + qp*(gp+1):
 *
 *     NCH = 4   252 + 198 = 450  of 512   (mbxa_unit.v:20 says the same 450)
 *     NCH = 8   126 + 110 = 236  of 512
 *
 * so the smallest plane that holds the shape is lgpw = 9 at NCH = 4 -- unchanged, byte for
 * byte -- and lgpw = 8 at NCH = 8, whose 2,048-byte stride puts the eight planes in TWO
 * sets of four: an exact fit again.  mbxr_engine.v:60 documents the field as
 * `lgpw[11:8] (log2 words per plane, 3..10)`, so this needs NO RTL, and the one variable
 * feeds both mbxa_build_w and mbxr_attn_dispatch, so the image and the lane cannot disagree.
 *
 * NOT A LAW, AND THE LIMIT IS NAMED: "smallest that fits" lands on a non-aliasing stride for
 * THESE shapes.  A shape needing lgpw = 9 at NCH = 8 would alias again, and the robust fix
 * for that is an odd stride (one 64-byte line of padding between planes), which costs a
 * multiply instead of a shift in the plane index.  Not needed here; stated so the next
 * shape does not inherit a coincidence as a guarantee.
 *
 * OFF BY DEFAULT: this file is shared with B86/B86D/B86G arms and a default flip would move
 * another workstream's control under it.  -DMBP_B101L=1 selects it.  At MBXA_NCH = 4 the
 * computed value IS 9, so the arm is a no-op there by construction, not by intent.
 */
#ifndef MBP_B101L
#define MBP_B101L 0
#endif

/*
 * B101 -- THE 64-BIT TWIN OF B86's WORD LOAD, so MBXA_NCH = 8 keeps the optimisation.
 *
 * B86's v^T builder unpacks FOUR columns from one uint32 and is guarded `#if MBXA_NCH == 4`
 * -- its own comment says it "is an NCH = 4 optimisation and not a layout rule".  At
 * MBXA_NCH = 8 it compiles out and the generic per-column path runs, which B101f measured as
 * 3.141x of the instruction difference between the two widths.  This is the same trick carrying
 * EIGHT columns, in TWO aligned words rather than one doubleword -- because head_dim is 36,
 * `D & 7 == 4`, and a uint64 load is unreachable on this model.  See the note at the site.
 *
 * RISC-V is little-endian, so byte c of the doubleword is column 8j+c, exactly as byte c of
 * the word is column 4j+c.  Same bytes, same destinations, same order within each plane; the
 * only thing that changes is how many loads carry them.
 *
 * WHAT IT IS WORTH, RE-PRICED RATHER THAN CARRIED FORWARD.  B101h first estimated this at
 * ~0.0260 using the CPI of the CONFLICTED image (3.57).  Removing the lgpw = 9 aliasing
 * dropped build_w's CPI to a measured 1.540, and the same 1,166,830 instructions are now
 * worth 1,797,429 cycles -- 0.0112 of RTF_e2e, not 0.0260.  Fixing the lever ahead of it made
 * this one cheaper, which is the reason to re-price a queued item after the one in front
 * lands rather than carrying its old number.
 *
 * OFF BY DEFAULT: this file is shared with B86/B86D/B86G arms.  -DMBP_B101U=1 selects it, and
 * at MBXA_NCH = 4 it is unreachable by construction, not by intent.
 */
#ifndef MBP_B101U
#define MBP_B101U 0
#endif

void kernel_attention_s8(const int8_t *q, const int8_t *k, const int8_t *v, int8_t *output,
			 int B, int M, int Dk, int S, int Dv,
			 float scale_q, float scale_k, float scale_scores,
			 float scale_div_sqrt_dk, float scale_probs, float scale_v,
			 float scale_out, int activation_min, int activation_max)
{
	const int gs = (Dk + 7) / 8;          /* words per q row and per k row  */
	const int qs = (S + MBXA_NCH - 1) / MBXA_NCH;   /* quads of scores       */
	const int gp = (S + 7) / 8;           /* words per v^T row              */
	const int qp = (Dv + MBXA_NCH - 1) / MBXA_NCH; /* quads of outputs      */
	const int kbase_w = 0;
	const int vtbase_w = qs * (gs + 1);
#if MBP_B101L
	const int lgpw = mbxa_lgpw_for(vtbase_w + qp * (gp + 1));
#else
	const int lgpw = 9;
#endif

	/* s2.5, what the unit refuses -- checked HERE so the fallback is taken rather than a
	 * dispatch refused on the board.  gs >= 2 and gp >= 2 are the serialiser's, not the
	 * array's: a quad's finals must be at least two cycles apart.
	 *
	 * `MBXA_NCH * qs >= S` IS THE SOFTWARE MIRROR OF mbxa_unit.v's cfg_ok, and it was a
	 * literal 4 until 2026-09-19 -- the THIRD copy of that one comparison, after the RTL
	 * and the bench.  It is the reason 0x5A5A0035's first board arm read attn_lane 0 AND
	 * attn_fallback 0: with qs = ceil(S/8) this refused every head BEFORE the dispatch, so
	 * nothing reached the lane to be counted either way.  All-zero attention counters mean
	 * `fits` was false, not that the lane failed. */
	const int fits = (gs >= 2) && (gp >= 2) && (gs <= MBXA_GSMAX) && (S <= MBXA_NMAX) &&
			 (qs > 0) && (qp > 0) && (M > 0) && (Dv > 0) &&
			 (MBXA_NCH * qs >= S) && (MBXA_NCH * qp >= Dv) &&
			 (M * gs <= MBXA_BUFW) && (lgpw >= 3) && (lgpw <= 10) &&
			 (vtbase_w + qp * (gp + 1) <= (1 << lgpw));

#ifdef __ZEPHYR__
	/* 64-BYTE ALIGNED, and that is a HARDWARE PRECONDITION, not tidiness.  mbxd_dma
	 * documents src_base as "byte address of the first block, 64-byte aligned" and NOTHING
	 * refuses an unaligned one -- the same defect B39 found on the LayerNorm lane's fill.
	 * Measured without these attributes, in a built image: q_img at 0x807c63d8 and w_img at
	 * 0x807c23d8, both 24 mod 64.  A source at +24 makes EVERY word wrong (832 of 832
	 * activation words, 2,048 of 2,048 weight words, shifted by 3 words, driven against the
	 * real mbxd_dma) while leaving the scratchpad ADDRESSES correct -- which is why ten arms
	 * of address-checking found nothing.  A displaced weight plane puts data where the quad's
	 * zero bias word belongs, and mbxr_mac's `clr` step loads it into the accumulator:
	 * err[2] on operands that cannot overflow.  ENGINE/ATTENTION_FILL_DIFFERENTIAL.md s9. */
	static int8_t q_img[MBXA_BUFW * 8] __attribute__((aligned(64)));
	static int8_t w_img[MBXA_NCH * 512 * 8] __attribute__((aligned(64)));
#if MBP_B86G
	int8_t *w_use = w_img;          /* the image actually handed to the lane */
	int8_t *wuse[2] = { NULL, NULL };
	(void)w_use; (void)wuse;
#endif
#if MBP_B86D
	/* The second set.  +24,576 bytes of .bss against ~239 MB of headroom. */
	static int8_t q_img1[MBXA_BUFW * 8] __attribute__((aligned(64)));
	static int8_t w_img1[MBXA_NCH * 512 * 8] __attribute__((aligned(64)));
	int8_t *const qset[2] = { q_img, q_img1 };
	int8_t *const wset[2] = { w_img, w_img1 };
	mbxr_attn_tok tok;
	int nb;
#endif
	/* the last head's drain lands here: blocks*64 bytes, so the 12-byte overrun is inside
	 * this buffer instead of past the tensor.  M*Dv = 5,940 at Moonshine, 93 blocks. */
	static int8_t tail[(MBXA_BUFW * 8 + 63) & ~63] __attribute__((aligned(64)));
	static uint32_t smx_ex[256];
	uint32_t mt_s, mt_p;
	int32_t smx_om;
	int smx_s;
	int sh_s, sh_p, b, rc = 0;
	MBXA_TAX_DECL(tv);
	const int nout = Dv;
	const int bytes = M * Dv;
	const int blocks = (bytes + 63) / 64;

	/* the last head's scratch must hold the padded drain, not just the tensor */
	if (fits && blocks * 64 > (int)sizeof tail) goto software;

	if (fits && mbxa_rq(scale_q, scale_k, scale_scores, scale_div_sqrt_dk, &mt_s, &sh_s) &&
	    mbxa_rq(scale_probs, scale_v, scale_out, 1.0f, &mt_p, &sh_p) &&
	    mbxr_rt_available()) {
		/* PER LAYER, ONCE: the softmax lane's table and two scalars, built line for line
		 * as kernel_softmax_s8 builds them (smx_lane/smx_golden.c).  They depend only on
		 * (scale_scores, scale_probs), which is one pair for the whole fused op. */
		MBXA_TAX_T0(tv);
		mbxa_smx_table(scale_scores, scale_probs, smx_ex, &smx_om, &smx_s);
		MBXA_TAX_T1(t_table, tv);
		MBXA_TAX_ADD(dispatches, 1);
#if MBP_B86D
		/* PIPELINED.  Stage head b+1 inside head b's wait; see the MBP_B86D note above
		 * for why there are two image sets and why `tail` needs only one. */
		mbxa_build_q(q, M, Dk, gs, qset[0]);
#if MBP_B86G
		wuse[0] = mbxa_w_resident(k, v, S, Dv, gs, qs, gp, qp, lgpw,
					  kbase_w, vtbase_w, wset[0]);
#else
		mbxa_build_w(k, v, S, Dv, gs, qs, gp, qp, lgpw, kbase_w, vtbase_w, wset[0]);
#endif
		tok = mbxr_rt_attn_issue(mbxa_pa(qset[0]), (M * gs + 7) / 8,
						 mbxa_pa(MBXA_WSET_USE(0)), lgpw, mbxa_pa(tail), blocks,
						 M, gs, qs, gp, qp, kbase_w, vtbase_w, S,
						 nout, mt_s, sh_s, mt_p, sh_p, smx_ex,
						 smx_om, smx_s, S, 1);
		for (b = 0; b < B; b++) {
			int8_t *ob = output + (size_t)b * M * Dv;

			nb = b + 1;
			/* THE OVERLAP: hart 0 builds head b+1's images while hart 1 runs head b. */
			MBXA_TAX_T0(tv);
			if (nb < B) {
				mbxa_build_q(q + (size_t)nb * M * Dk, M, Dk, gs, qset[MBXA_BSEL(nb)]);
#if MBP_B86G
				wuse[MBXA_BSEL(nb)] = mbxa_w_resident(
					k + (size_t)nb * S * Dk, v + (size_t)nb * S * Dv, S, Dv,
					gs, qs, gp, qp, lgpw, kbase_w, vtbase_w, wset[MBXA_BSEL(nb)]);
#else
				mbxa_build_w(k + (size_t)nb * S * Dk, v + (size_t)nb * S * Dv, S, Dv,
					     gs, qs, gp, qp, lgpw, kbase_w, vtbase_w,
					     wset[MBXA_BSEL(nb)]);
#endif
			}
			MBXA_TAX_T1(t_stage, tv);
#if MBP_B86D_POISON == 2
			/* issue b+1 before wait(b): races the one global mbxr_rt_job */
			if (nb < B) tok = mbxr_rt_attn_issue(mbxa_pa(qset[MBXA_BSEL(nb)]), (M * gs + 7) / 8,
						 mbxa_pa(MBXA_WSET_USE(MBXA_BSEL(nb))), lgpw, mbxa_pa(tail), blocks,
						 M, gs, qs, gp, qp, kbase_w, vtbase_w, S,
						 nout, mt_s, sh_s, mt_p, sh_p, smx_ex,
						 smx_om, smx_s, S, 0);
#endif
			MBXA_TAX_T0(tv);
			rc = mbxr_rt_attn_wait(tok);
			MBXA_TAX_T1(t_round, tv);
			MBXA_TAX_ADD(t_lane, mbxr_rt_job.cycles);
			MBXA_TAX_ADD(heads, 1);
			/* head b+1 is STAGED BUT NOT ISSUED here and nothing is in flight, so the
			 * fallback needs no unwind -- the ordering is what makes that true. */
			if (rc != MBXR_OK) goto software;
			{
				const uint32_t *sw = (const uint32_t *)(const void *)tail;
				uint32_t *dw = (uint32_t *)(void *)ob;
				int w, nwds = bytes >> 2;

				MBXA_TAX_T0(tv);
				if ((((uintptr_t)ob | (uintptr_t)tail) & 3) == 0) {
					for (w = 0; w < nwds; w++) dw[w] = sw[w];
					for (w = nwds << 2; w < bytes; w++) ob[w] = tail[w];
				} else {
					for (w = 0; w < bytes; w++) ob[w] = tail[w];
				}
				MBXA_TAX_T1(t_copy, tv);
			}
			/* only now are `tail` and the job struct free */
#if MBP_B86D_POISON != 2
			MBXA_TAX_T0(tv);
			if (nb < B)
				tok = mbxr_rt_attn_issue(mbxa_pa(qset[MBXA_BSEL(nb)]), (M * gs + 7) / 8,
						 mbxa_pa(MBXA_WSET_USE(MBXA_BSEL(nb))), lgpw, mbxa_pa(tail), blocks,
						 M, gs, qs, gp, qp, kbase_w, vtbase_w, S,
						 nout, mt_s, sh_s, mt_p, sh_p, smx_ex,
						 smx_om, smx_s, S, 0);
			MBXA_TAX_T1(t_issue, tv);
#endif
		}
#else
		for (b = 0; b < B; b++) {
			const int8_t *qb = q + (size_t)b * M * Dk;
			const int8_t *kb = k + (size_t)b * S * Dk;
			const int8_t *vb = v + (size_t)b * S * Dv;
			int8_t *ob = output + (size_t)b * M * Dv;
			int last = (b == B - 1);

			(void)last;   /* unused when MBXA_DRAIN_ALIGN makes every head take `tail` */

			/* STAGING, ON HART 0 AND DELIBERATELY SO: no custom-1 in it, and it is the
			 * bulk of the work (s5.2, ~25 k cycles per head against 78 k of array). */
			MBXA_TAX_T0(tv);
			mbxa_build_q(qb, M, Dk, gs, q_img);
#if MBP_B86G
			w_use = mbxa_w_resident(kb, vb, S, Dv, gs, qs, gp, qp, lgpw,
						kbase_w, vtbase_w, w_img);
#else
			mbxa_build_w(kb, vb, S, Dv, gs, qs, gp, qp, lgpw, kbase_w, vtbase_w, w_img);
#endif
			MBXA_TAX_T1(t_stage, tv);

#if (MBXA_SEAM & 2)
			/* PRE-FLUSH.  Written by hart 0 with ordinary stores an instant ago, so
			 * every line of all three is dirty in hart 0's L1 right now.  Two things
			 * follow and only the first is documented as safe: the engine's Gets are
			 * served through the L2, which probes hart 0 (mbxr_rt.h:23) -- but the
			 * DESTINATION is not read by the engine, it is WRITTEN by the drain, and a
			 * dirty hart-0 line there is a store that has not happened yet. */
			{
				uint64_t f0 = mbxr_rt_cyc();
				mbxa_l2_flush(q_img, (size_t)((M * gs + 7) / 8) * 64);
				mbxa_l2_flush(w_img, sizeof w_img);
				mbxa_l2_flush(last ? (const void *)tail : (const void *)ob,
					      (size_t)blocks * 64);
				mbxa_seam_flush_cyc += mbxr_rt_cyc() - f0;
			}
#endif

			/* EVERY head drains into the 64-byte-aligned scratch, not only the last.
			 *
			 * MEASURED (B55 arm A3, MBXA_SEAM=4, the per-head differential on the
			 * board): with the drain pointed straight at `ob` the answer is wrong on
			 * EXACTLY the heads whose base is not 64-byte aligned, and right-ish on
			 * exactly those whose base is --
			 *
			 *   head 0   ob & 63 = 0     15 of 5,940 bytes differ, max 1
			 *   heads 1-6  52,40,28,16,4,56   ~5,890 of 5,940 differ, max 161-255
			 *   head 7   drained to `tail`, & 63 = 0     84 differ, max 5
			 *
			 * `ob` is `output + b*M*Dv` and M*Dv = 5,940, so consecutive heads sit at
			 * 52*b mod 64 -- aligned for b = 0 and for nothing else.  mbxd_dma/mbxr_st
			 * document a 64-byte-aligned base and NOTHING refuses an unaligned one:
			 * the same defect class as the misaligned FILL (`5530e94`), on the drain,
			 * and it hid because the arm that "eliminated the misaligned drain"
			 * (s11, b42b) turned on MB_BUF_ALIGN64 -- which aligns the TENSOR, not
			 * `tensor + b*5,940`.
			 *
			 * Draining every head here also retires the 12-byte overrun (s8.3): only
			 * `bytes` are copied out, so nothing is written past a head's own region
			 * and no head depends on the next one rewriting its spill. */
			MBXA_TAX_T0(tv);
			rc = mbxr_rt_attn_head(mbxa_pa(q_img), (M * gs + 7) / 8,
					       mbxa_pa(MBXA_W_USE), lgpw,
#if MBXA_DRAIN_ALIGN
					       mbxa_pa(tail), blocks,
#else
					       last ? mbxa_pa(tail) : mbxa_pa(ob), blocks,
#endif
					       M, gs, qs, gp, qp, kbase_w, vtbase_w, S, nout,
					       mt_s, sh_s, mt_p, sh_p,
					       smx_ex, smx_om, smx_s, S, b == 0);
			/* t_lane is HART 1's OWN delta for this head, not a subtraction: the
			 * worker stamps mbxr_rt_job.cycles around mbxr_attn_dispatch. */
			MBXA_TAX_T1(t_round, tv);
			MBXA_TAX_ADD(t_lane, mbxr_rt_job.cycles);
			MBXA_TAX_ADD(heads, 1);
			if (rc != MBXR_OK) goto software;

#if (MBXA_SEAM & 3)
			/* POST-FLUSH, and for the last head it must happen BEFORE the copy-out
			 * below, or a stale read is simply propagated into the tensor. */
			{
				int8_t *dst = MBXA_DRAIN_DST;
				uint64_t f0;
#if (MBXA_SEAM & 1)
				int i, nd = 0;

				/* hart 0's view AS IT STANDS -- the value the model would use */
				for (i = 0; i < bytes; i++) mbxa_seam_before[i] = dst[i];
#endif
				f0 = mbxr_rt_cyc();
				mbxa_l2_flush(dst, (size_t)blocks * 64);
				mbxa_seam_flush_cyc += mbxr_rt_cyc() - f0;
#if (MBXA_SEAM & 1)
				/* and now from DRAM: the cache-bypassing read, done by the only
				 * agent that can invalidate what stands in its way */
				for (i = 0; i < bytes; i++)
					if (dst[i] != mbxa_seam_before[i]) nd++;
				if (nd) mbxa_seam_changed_heads++;
				mbxa_seam_changed_bytes += (uint64_t)nd;
#endif
				mbxa_seam_heads++;
			}
#endif
#if (MBXA_SEAM & 4)
			/* BEFORE the tail copy, so what is compared is what the DRAIN left and not
			 * what a byte-wise memcpy carried out of it. */
			{
				const int8_t *dst = MBXA_DRAIN_DST;
				int i, nw = 0, mx = 0, first = -1, lastw = -1, blk = 0, pb = -1;

				mbxa_software(qb, kb, vb, mbxa_seam_gold, 1, M, Dk, S, Dv,
					      scale_q, scale_k, scale_scores, scale_div_sqrt_dk,
					      scale_probs, scale_v, scale_out,
					      activation_min, activation_max);
				for (i = 0; i < bytes; i++) {
					int d = (int)dst[i] - (int)mbxa_seam_gold[i];
					if (!d) continue;
					if (d < 0) d = -d;
					nw++;
					if (d > mx) mx = d;
					if (first < 0) first = i;
					lastw = i;
					if ((i >> 6) != pb) { pb = i >> 6; blk++; }
				}
				/* the destination's 64-byte phase, printed because `ob` is
				 * `output + b*M*Dv` and M*Dv = 5,940 is NOT a multiple of 64:
				 * seven of every eight heads drain to an UNALIGNED base, and
				 * mbxd_dma documents its base as "64-byte aligned". */
				printk("MBXA_DIFF %lu %d %d %d %d %d %d %d\n",
				       (unsigned long)mbxa_diff_head, bytes, nw, mx,
				       first, lastw, blk, (int)((uintptr_t)dst & 63));
				mbxa_diff_head++;
			}
#endif
#if MBXA_DRAIN_ALIGN
			/* 32-bit, because `ob` is `output + b*5,940` and 5,940 is a multiple of
			 * 4 but not of 8, while `tail` is 64-aligned.  48 copies of 5,940 bytes
			 * is the price of the alignment fix and it is reported, not buried. */
			{
				const uint32_t *sw = (const uint32_t *)(const void *)tail;
				uint32_t *dw = (uint32_t *)(void *)ob;
				int w, nwds = bytes >> 2;

				MBXA_TAX_T0(tv);
				if ((((uintptr_t)ob | (uintptr_t)tail) & 3) == 0) {
					for (w = 0; w < nwds; w++) dw[w] = sw[w];
					for (w = nwds << 2; w < bytes; w++) ob[w] = tail[w];
				} else {
					for (w = 0; w < bytes; w++) ob[w] = tail[w];
				}
				MBXA_TAX_T1(t_copy, tv);
			}
#else
			if (last)
				for (int i = 0; i < bytes; i++) ob[i] = tail[i];
#endif
		}
#endif /* MBP_B86D */
#if MBXA_SEAM
		/* ONE SHORT LINE PER CALL, and the brevity is a measurement decision: this printk
		 * is INSIDE the timed attention_s8 dispatch, so every character it emits at
		 * 115200 baud is ~3,000 cycles charged to the row this arm exists to price.
		 * Six calls x ~40 bytes is ~0.7 M cycles, 0.3 % of the projected steady; the
		 * long form was ~2 M. */
		printk("MBXA_SEAM %d %lu %lu %lu %lu %lu\n", MBXA_SEAM,
		       (unsigned long)mbxa_seam_heads, (unsigned long)mbxa_seam_changed_heads,
		       (unsigned long)mbxa_seam_changed_bytes,
		       (unsigned long)mbxa_seam_flush_blocks,
		       (unsigned long)mbxa_seam_flush_cyc);
#endif
		return;
	}
software:
#endif
	{
		/* the fallback IS the specification: the three curated kernels, composed */
		mbxa_software(q, k, v, output, B, M, Dk, S, Dv,
			      scale_q, scale_k, scale_scores, scale_div_sqrt_dk,
			      scale_probs, scale_v, scale_out,
			      activation_min, activation_max);
	}
	(void)fits;
}
