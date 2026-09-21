/* accuracy_class: bit_exact
 *
 * cat2_c1_s8 on T4's LUT LANE -- Lab B73, rebuilt on B67's builder.
 *
 * ============================================================================================
 * WHY THIS FILE WAS REWRITTEN, AND WHAT THE OLD ONE MEASURED
 * ============================================================================================
 * Lab B44 (0b97844) wrote the first version of this kernel: the PRE-B67 curated kernel -- the
 * float builder and the seen[] marking pass -- with the gather moved to the lane.  It
 * predicted 15,727,562 cycles saved and measured 647,557 (1.3 %, a 24x miss), and the lane was
 * declined.  Its own counters say why: lut_lane=545, lut_tiles=545, lut_els_lane=969,024,
 * one table write and ONE tile per side, and cycles_h0 127,325,830 -> 132,112,568, which is
 * +4,786,738 over 1,090 hart-0/hart-1 posts -- 4,392 cycles each.
 *
 * ***THE LANE'S COST IS PER DISPATCH, NOT PER BYTE.***  The same lane runs the encoder's
 * gelu_s8 at 1.371 cycles/element, because that op is eight dispatches of 172,332 bytes and
 * amortises the handoff over about twenty-one tiles.  cat2's sides are 288*t and 288 bytes --
 * mean 1,843 -- so every side is a single tile and pays the handoff once for 1,843 bytes.
 *
 * B67 then took the builder from 303.08 to 18.8 instructions per entry and killed the marking
 * pass with it, so the op became 74.3 % GATHER (8,031,744 of 10,814,288 instructions).  That
 * makes B44's declination stale ON ITS SHARE and this file is what tests it.  Running B44's
 * version unchanged would not have tested anything: it would have put back 23.5 M instructions
 * of float build and 6.0 M of marking and regressed the op by about 25 M.
 *
 * WHAT CHANGES AGAINST B44'S VERSION, AND IT IS ONE THING WITH A PRICE.  B67's builder has no
 * seen[] mask -- that is the whole of why it is cheap -- so the lane is handed seen = NULL and
 * writes ALL 256 entries rather than the D that occur.  D is MEASURED at median 132 / mean 143
 * over the model's own 552 sides (B67's host census, test/b67_sides.h), so this is
 * (256 - 143) * 545 = 61,585 extra `lcfg` writes.  mbxr_rt.h prices that difference at
 * "0.7 M cycles" and B44's own cycles_h1 delta puts one `lcfg` at 11-12 cycles, which is where
 * that 0.7 M comes from.  B73 bands the arm at -0.37 M (a small REGRESSION), [-1.5 M, +1.0 M].
 *
 * ============================================================================================
 * BIT-EXACT BY CONSTRUCTION, AND THE TRANSCRIPTION IS CHECKED MECHANICALLY
 * ============================================================================================
 * The lane does not compute anything: it is a 256-entry int8 -> int8 map, so the arithmetic is
 * whatever software puts in the table.  The table here is built by B67's `pcat_build`, and
 * `pcat_build` and everything it calls are COPIED BYTE FOR BYTE out of
 * kernels/pext_nl/pext_nl_cat2_c1_s8_pext_memo_lut.c -- not re-derived, not re-typed.
 * test/b73_cat2_lane_gate.sh re-extracts the block from both files and diffs them, so
 * "transcribed" is a checked claim rather than a comment.  gelu_s8's lane kernel can CALL its
 * curated builder (int_gelu_s8_table is extern); cat2's is static, so a copy plus a diff is
 * the same guarantee by a different route.
 *
 * SO `max_abs_err` 0 IS NOT THE EVIDENCE HERE, and the two halves are checked separately:
 *   * the BUILDER, before the board: --golden-against the control image's host-C golden.
 *     The host build takes mbxr_lut_map_op's `#if defined(__ZEPHYR__)` fallback, so that gate
 *     exercises this file's builder and its scalar gather over the model's own 786,432 output
 *     bytes and says NOTHING about the lane.
 *   * the LANE, on the board: max_abs_err 0 WITH lut_fallback = 0 and lut_els_lane = 969,024.
 *     A fallback that produces correct results is indistinguishable from success by any
 *     correctness check -- the attention lane passed 117/117 entirely through its fallback
 *     (60bd85d) -- so only the counters separate them.
 *
 * THE SHAPE, READ FROM THE IR AND NOT FROM THE NAME.  276 calls over 23 distinct shapes,
 * C_inputs = (t, 1) for t = 1..23, twelve calls each: a KV APPEND, the cache growing by one
 * token per step.  Layout is [N, C, H*W], so each input is ONE CONTIGUOUS RUN in both source
 * and destination -- input 0 is output channels [0, c0), input 1 is [c0, c0+c1).  Two lane
 * dispatches per call, 552 in all, and the destination is the caller's own tensor.  The word
 * count is a multiple of 8 on every side (288 bytes = 36 words), which every lane on this
 * engine requires.
 *
 * THE IDENTITY FAST PATH IS KEPT, as memcpy, exactly as the curated kernel spells it: 7 of the
 * 552 sides take it (1.3 % of sides, 2.8 % of elements), and a lane dispatch that computes the
 * identity is a dispatch spent to achieve nothing.
 */
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "fexact32.h"

#include "roccmoon/mbxr_lut_map.h"

/* ============================================================================================
 * BEGIN the block copied byte for byte from
 *   fpga/pynq-z2/modelblaster/kernels/pext_nl/pext_nl_cat2_c1_s8_pext_memo_lut.c
 * from the opening `#ifndef MBP_CAT2_B67` through its matching `#endif`.  Do not edit it here:
 * edit it there and re-copy, and test/b73_cat2_lane_gate.sh will tell you if the two parted.
 * ============================================================================================ */
#ifndef MBP_CAT2_B67
#define MBP_CAT2_B67 1
#endif
/* Below this many elements a side evaluates each element directly instead of building a
 * 256-entry table.  MEASURED crossover 177 (b67_icount: the table arm is 4,703 + 8n retired
 * instructions, the per-element arm 458 + 32n).  Set just below it, on the side the cycle
 * crossover moves towards: the table arm is load-heavy on a 256-byte table hot in a 16 KB
 * L1D and the per-element arm is multiply-heavy on a core whose mul is multi-cycle, so the
 * crossover in CYCLES is lower than the crossover in instructions. */
#ifndef MBP_CAT2_MINN
#define MBP_CAT2_MINN 176
#endif

#if MBP_CAT2_B67

/* -DFX_STATS (host checks only): how many entries the guard sent to the reference. */
#ifdef FX_STATS
unsigned long pcat_slow_count, pcat_entry_count, pcat_sat_count, pcat_slowside_count;
unsigned long pcat_tbl_sides, pcat_el_sides;
#define PCAT_SLOW()  (pcat_slow_count++)
#define PCAT_SAT()   (pcat_sat_count++)
#define PCAT_ENT(n)  (pcat_entry_count += (unsigned long)(n))
#define PCAT_SIDE()  (pcat_slowside_count++)
#define PCAT_TBL()   (pcat_tbl_sides++)
#define PCAT_EL()    (pcat_el_sides++)
#else
#define PCAT_SLOW()  ((void)0)
#define PCAT_SAT()   ((void)0)
#define PCAT_ENT(n)  ((void)0)
#define PCAT_SIDE()  ((void)0)
#define PCAT_TBL()   ((void)0)
#define PCAT_EL()    ((void)0)
#endif

#define PCAT_F     30                              /* fractional bits of A */
#define PCAT_ONE   ((uint64_t)1 << PCAT_F)
#define PCAT_HALF  ((uint64_t)1 << (PCAT_F - 1))
#define PCAT_SAT_A ((uint64_t)1 << (PCAT_F + 8))   /* |value| >= 256: every clamp decided */

/* s_in / s_out as |k| * q2 >> nsh == |k| * s_in/s_out * 2^30.  ok = 0 means the side must
 * run the reference expression: a scale outside fexact32's domain, a clamp wider than the
 * saturation argument covers, or a ratio so extreme the fixed point cannot hold it. */
typedef struct {
	uint64_t q2;
	int nsh;
	int ok;
} pcat_lin_t;

static pcat_lin_t pcat_lin(float s_in, float s_out, int amin, int amax)
{
	pcat_lin_t L;
	fx32_t si = fx32_dec(s_in), so = fx32_dec(s_out);
	fx32_k_t k;
	int sft;

	L.q2 = 0;
	L.nsh = 0;
	L.ok = 0;
	if (!fx32_scale_ok(si) || !fx32_scale_ok(so)) {
		return L;
	}
	if (amin < -255 || amax > 255) {
		return L;                  /* PCAT_SAT_A's clamp argument needs this */
	}
	k = fx32_ratio(si, so);            /* one 64-bit divide, per side */
	sft = k.e + PCAT_F;
	if (sft > 16 || sft < -63) {
		return L;                  /* |k| * q2 would not fit, or the shift is UB */
	}
	if (sft >= 0) {
		L.q2 = k.q << sft;         /* k.q <= 2^40, sft <= 16, |k| <= 2^7: < 2^63 */
		L.nsh = 0;
	} else {
		L.q2 = k.q;
		L.nsh = -sft;
	}
	L.ok = 1;
	return L;
}

/* The reference expression, term for term and in the same order:
 * roundf(f / scale_out), not a multiply by a reciprocal, because in float those are not
 * the same number. */
static int32_t pcat_ref(int k, float s_in, float s_out)
{
	float f = (float)k * s_in;

	PCAT_SLOW();
	return (int32_t)roundf(f / s_out);
}

/* Round the magnitude A (value * 2^30) to an integer, half away from zero.
 * *st: 0 decided, 1 too close to a rounding boundary to decide, 2 saturating. */
static inline int32_t pcat_round(uint64_t A, int *st)
{
	uint64_t t, f, g;

	if (A >= PCAT_SAT_A) {
		*st = 2;
		PCAT_SAT();
		return 0;
	}
	t = A + PCAT_HALF;
	f = t & (PCAT_ONE - 1);
	g = (A >> 21) + 8;                 /* 4x the reference's 2^-23, plus this kernel's 2 */
	if (f < g || f > PCAT_ONE - g) {
		*st = 1;
		return 0;
	}
	*st = 0;
	return (int32_t)(t >> PCAT_F);
}

/* One entry, sign applied and clamped. */
static inline int32_t pcat_one(int k, uint64_t A,
			       float s_in, float s_out, int amin, int amax)
{
	int st;
	int32_t m = pcat_round(A, &st);
	int32_t q;

	if (st == 0) {
		q = k < 0 ? -m : m;
	} else if (st == 2) {
		q = k < 0 ? amin : amax;   /* |value| >= 255.9; |roundf| >= 256 > 255 */
	} else {
		q = pcat_ref(k, s_in, s_out);
	}
	if (q < amin) q = amin;
	if (q > amax) q = amax;
	return q;
}

/* All 256 entries.  One evaluation fills two, by the sign symmetry of the reference. */
static void pcat_build(int8_t tbl[256], float s_in, float s_out, int amin, int amax)
{
	pcat_lin_t L = pcat_lin(s_in, s_out, amin, amax);
	uint64_t acc = 0;
	int ka;

	PCAT_TBL();
	PCAT_ENT(256);
	if (!L.ok) {
		int v;

		PCAT_SIDE();
		for (v = 0; v < 256; v++) {
			int32_t q = pcat_ref(v - 128, s_in, s_out);

			if (q < amin) q = amin;
			if (q > amax) q = amax;
			tbl[v] = (int8_t)q;
		}
		return;
	}
	/* One rounding decision serves two entries: q(-k) == -q(k) before the clamp. */
	for (ka = 0; ka <= 128; ka++) {
		uint64_t A = acc >> L.nsh;
		int32_t qp, qn;
		int st;
		int32_t m = pcat_round(A, &st);

		if (st == 0) {
			qp = m;
			qn = -m;
		} else if (st == 2) {
			qp = amax;                 /* |value| >= 255.9; |roundf| >= 256 > 255 */
			qn = amin;
		} else {
			qp = pcat_ref(ka, s_in, s_out);
			qn = pcat_ref(-ka, s_in, s_out);
		}
		if (qp < amin) qp = amin;
		if (qp > amax) qp = amax;
		if (qn < amin) qn = amin;
		if (qn > amax) qn = amax;
		if (ka <= 127) {
			tbl[128 + ka] = (int8_t)qp;
		}
		tbl[128 - ka] = (int8_t)qn;
		acc += L.q2;
	}
}

#endif /* MBP_CAT2_B67 */

/* ============================================================================================
 * END of the copied block.
 * ============================================================================================ */

void kernel_cat2_c1_s8(const int8_t *in0, int c0, float scale0,
                       const int8_t *in1, int c1, float scale1,
                       int8_t *output, int N, int H, int W,
                       float scale_out, int activation_min, int activation_max) {
    const int stride = H * W;
    const int8_t *ins[2] = { in0, in1 };
    const int cs[2] = { c0, c1 };
    const float scales[2] = { scale0, scale1 };
    int8_t tbl[256];
    int n, i, c, hw;

    mbxr_lut_stats.calls++;
    for (n = 0; n < N; n++) {
        int out_c = 0;
        for (i = 0; i < 2; i++) {
            const float s_in = scales[i];
            const long cnt = (long)cs[i] * stride;
            const int8_t *src = ins[i] + (long)n * cs[i] * stride;
            int8_t *dst = output + ((long)n * (c0 + c1) + out_c) * stride;

            /* identity: the map is the identity byte for byte, so this is a copy */
            if (s_in == scale_out && activation_min <= -128 && activation_max >= 127) {
                memcpy(dst, src, (size_t)cnt);
                out_c += cs[i];
                continue;
            }
            if (cnt < MBP_CAT2_MINN) {
                /* Fewer elements than the table has entries: evaluate each element
                 * directly, through the same integer core and the same fallback. */
                pcat_lin_t L = pcat_lin(s_in, scale_out, activation_min, activation_max);

                PCAT_EL();
                for (c = 0; c < cs[i]; c++) {
                    const int8_t *s = src + (long)c * stride;
                    int8_t *d = dst + (long)c * stride;

                    for (hw = 0; hw < stride; hw++) {
                        int k = s[hw];
                        unsigned ka = (unsigned)(k < 0 ? -k : k);
                        int32_t q;

                        if (L.ok) {
                            q = pcat_one(k, ((uint64_t)ka * L.q2) >> L.nsh,
                                         s_in, scale_out,
                                         activation_min, activation_max);
                        } else {
                            q = pcat_ref(k, s_in, scale_out);
                            if (q < activation_min) q = activation_min;
                            if (q > activation_max) q = activation_max;
                        }
                        d[hw] = (int8_t)q;
                    }
                }
                out_c += cs[i];
                continue;
            }
            /* One table per input, all 256 entries: no seen[] mask, so no marking pass over
             * the elements and no memset -- and the lane is therefore handed seen = NULL and
             * writes every entry.  That is B73's one cost against B44's version. */
            pcat_build(tbl, s_in, scale_out, activation_min, activation_max);

            /* THE LANE.  One side is one contiguous run in both source and destination, so the
             * whole side is one map: head/tail on the core for the sub-block ends, the middle
             * in whole 64-byte blocks on mbxl_lut. */
            if (mbxr_lut_map_op(src, dst, (int)cnt, tbl)) {
                mbxr_lut_stats.calls_lane++;
                out_c += cs[i];
                continue;
            }
            /* THE FALLBACK IS THE CURATED KERNEL'S OWN GATHER over the same table, so a refused
             * dispatch costs a dispatch and not an answer. */
            mbxr_lut_stats.calls_fallback++;
            for (c = 0; c < cs[i]; c++) {
                const int8_t *s = src + (long)c * stride;
                int8_t *d = dst + (long)c * stride;
                for (hw = 0; hw < stride; hw++)
                    d[hw] = tbl[(unsigned char)((int)s[hw] + 128)];
            }
            out_c += cs[i];
        }
    }
}
