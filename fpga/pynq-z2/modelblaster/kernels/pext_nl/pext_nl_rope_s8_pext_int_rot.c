/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_rot */
/* accuracy_class: bit_exact */
/* origin: patches/0100, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * rope_s8 -- the rotary embedding, interleaved pairs -- in integer, and still bit-exact.
 *
 * The reference rotates each pair in float32:
 *     x0 = a0*si, x1 = a1*si;  y0 = x0*c + (-x1)*s;  y1 = x1*c + x0*s;  roundf(y/so)
 * which is ~6 soft-float operations per output element on this core.  Decomposed the way
 * HF writes it (two mul_s8, a negation and an add over q and k), ROCC_DECOUPLED.md 7.3
 * priced it at ~2 x 704 cycles per element.
 *
 * FAST PATH.  Once per position t: CK[i] = c[t,i]*si/so and SK[i] = s[t,i]*si/so in fixed
 * point (F fractional bits), each one integer multiply of the table entry's mantissa by a
 * truncated si/so; K = si/so costs the dispatch's only divide.  Per element:
 *     x0 = a0*CK[i] - a1*SK[i],   x1 = a1*CK[i] + a0*SK[i]
 * two int8-by-int64 multiplies, an add, a rounding shift, a clamp.  The head_dim - R
 * pass-through dimensions are one multiply by K each.
 *
 * WHY IT IS STILL THE REFERENCE.  The reference's float32 chain for y0 errs by at most
 * 4.001 * 2^-24 of U = (|a0*c| + |a1*s|)*si/so; the tables by (|CK| >> 38) + 1 units per
 * entry.  G[i] = 2^-21 * 128*(|CK| + |SK|) + 128*(both table bounds) + 4 bounds the sum
 * with an 8x margin on the float term; outside G of every half-integer x rounds as the
 * reference does, inside it the element takes the exact binary32 slow path
 * (fpga/pynq-z2/sw/fexact32.h), operand for operand the reference expression.
 *
 * No floating-point instruction executes.  check_moonshine.py compares it with the float
 * reference over every int8 (a0, a1) pair at every (t, i) of Moonshine's tables.
 */
#include <stddef.h>
#include <stdint.h>
#include "fexact32.h"
#include "pext.h"

#ifndef MBP_ROPE_R2MAX
#define MBP_ROPE_R2MAX 64         /* per-position arrays live on an 8 KB stack */
#endif

/*
 * B101 -- HEAD-GRANULARITY RE-ENTRY, for B102's rope_q/engine overlap.
 *
 * WHAT B102 NEEDS AND WHY THE GRAIN IS THE HEAD.  mbxr_rt.h has ONE global `mbxr_rt_job`, so
 * only one engine job is in flight at a time and `mbxr_rt_run` blocks hart 0 until it lands.
 * Overlapping rope_q with engine work therefore needs hart 0 to reach the driver between
 * units of rope, and the unit has to be small enough that the engine is not left idle: a
 * whole rope_s8 dispatch is ~1.16 M cycles against engine jobs far shorter than that, and
 * one head is ~145 k.
 *
 * WHY A HOOK RATHER THAN A RESUMABLE STATE MACHINE.  The natural reading of "re-entrant" is
 * begin()/next() with the cursor and the per-position table in a caller-owned context.  That
 * is correct and it is more expensive, for a reason B74 already measured on THIS FILE'S
 * sibling: `pint_add_lin_mark` written inline measured 20.19 instructions an element against
 * 16 in its own frame, "because the register allocator, holding both routes' live state at
 * once, spilled `mask`, `G - half` and `2G` and reloaded all three from the stack every
 * element".  A context struct makes that spill mandatory rather than incidental: KF, Gp,
 * half, mask, F, si, so and the E[] base would reload per head from memory instead of living
 * in registers across the nest, and `E[MBP_ROPE_R2MAX]` (1,024 B) plus `ptab[256]` would move
 * off the stack into it.
 *
 * The hook delivers the SAME interleaving at the SAME grain: the driver installs a callback,
 * rope calls it after every head, and the callback advances or reposts the engine job.  The
 * kernel does not return, so nothing spills: the cost is one load and one predictable branch
 * per head.
 *
 * BIT-EXACTNESS IS STRUCTURAL, NOT TESTED-INTO.  The hook is called AFTER a head's output is
 * written and takes no pointer into x, y or E; there is no path by which it can change a
 * byte.  With the hook NULL -- the default, and what every existing arm links -- the added
 * code is a load of a file-scope pointer and a branch not taken.  b101_rope_gate.sh checks it
 * anyway, against the pre-change file, over both halves' shapes.
 *
 * OFF BY DEFAULT: rope_s8 is built into both halves' images and a default flip would move
 * another workstream's control arm under it.  -DMBP_B101R=1 selects it.
 */
#ifndef MBP_B101R
#define MBP_B101R 0
#endif
#if MBP_B101R
typedef void (*mbp_rope_yield_fn)(void *);
static mbp_rope_yield_fn mbp_rope_yield_cb;
static void *mbp_rope_yield_arg;
/* Installed by the driver before a rope_s8 dispatch it wants to overlap; NULL restores the
 * unhooked behaviour exactly.  Not re-entrant into rope itself, and does not need to be. */
void mbp_rope_set_yield(mbp_rope_yield_fn fn, void *arg)
{
	mbp_rope_yield_cb = fn;
	mbp_rope_yield_arg = arg;
}
#define MBP_ROPE_YIELD() do { if (mbp_rope_yield_cb) mbp_rope_yield_cb(mbp_rope_yield_arg); } while (0)
#else
#define MBP_ROPE_YIELD() do { } while (0)
#endif

/*
 * B74 -- THE PER-POSITION BUILD IS 35.9 % OF THIS OPERATOR, AND IT IS THE ONE PIECE B63
 * DID NOT TOUCH.
 *
 * Measured, whole-dispatch, on spike at the board's own flags (b74_icount.sh) at the
 * encoder's shape T = 165, H = 8, D = 36, R = 32, and fitted against (T, H) so the terms
 * are separated rather than apportioned:
 *
 *     I(T, H) = S + T*BLD*R2 + T*H*(PAIR*R2 + PASS*(D-R))
 *     1,493,523 instructions = 47,520 elements x 31.43
 *       build   165 x 3,249   =  536,085   35.9 %      203.1 instructions per E[] entry
 *       pairs   1,320 x 581   =  766,920   51.3 %       36.3 per pair, 18.16 per element
 *       pass    1,320 x 145   =  191,400   12.8 %       36.25 per pass-through element
 *     reconstruction closes to 0.059 %.
 *
 * Against the board's 36.982 cyc/element that is 1.1767 cycles per retired instruction --
 * add_s8 on the same image measures 1.1646 -- so this loop nest is INSTRUCTION-bound and
 * its floor is its instruction count, not a copy rate.
 *
 * (1) THE BUILD.  Each entry calls fx32_apply twice.  fx32_apply is written for the
 * general fx32 domain: an `unsigned __int128` product and an fx32_bitlen128, which on
 * rv64imac with no Zbb lowers to an OUT-OF-LINE libgcc __clzdi2 call -- the same defect
 * B63 removed from add_s8's table and B67 from cat2's.  Neither is necessary here:
 *
 *     m is a binary32 mantissa, so m < 2^24; fx32_ratio's header pins k.q to (2^38, 2^40].
 *     Therefore p = m * k.q < 2^64 is EXACT in one 64-bit multiply, no __int128;
 *     and every bitlen test is a comparison against a power of two, which is a shift and
 *     a branch, no clz:
 *         bitlen(p) - sh > 61   <=>   sh <= -61  or  (p >> (61 + sh)) != 0
 *         bitlen(rr)     > 61   <=>   (rr >> 61) != 0
 *     and (p + 2^(sh-1)) >> sh, which needs 65 bits in general, is
 *         (p >> sh) + ((p >> (sh-1)) & 1)
 *     exactly, in 64 bits, for 1 <= sh <= 63 -- with sh = 64 giving p >> 63 and sh >= 65
 *     giving 0, because p < 2^64 <= 2^(sh-1) + 2^(sh-1).
 *
 * Same value, same *ok, same branch, for every input fx32_dec and fx32_ratio can produce
 * -- so max_abs_err = 0 is the right instrument.  The one case the identity needs and
 * fx32_ratio cannot emit, k.q > 2^40, keeps the generic fx32_apply rather than a bail, so
 * the property holds unconditionally and not only on the scales calibration happens to
 * produce.
 *
 * (2) THE PASS-THROUGH LOOP, 36.25 instructions an element for one multiply, a shift, a
 * clip and a store.  Off the run's own dis.txt, the body reloads KF, Gp, half/2 and F
 * from the stack EVERY element, tests the whole-dispatch `fast` flag every element, makes
 * the [-128, 127] clamp-mode decision every element with two taken branches
 * (`li -128 / beq / li 127 / bne`), and sign-extends with slliw/sraiw a value the next
 * instruction stores as a byte.  Eleven of the 36 depend on nothing in the element.  The
 * fix is the one B63 applied to the pair loop: an always_inline helper whose `full`
 * argument is a constant at both call sites, taking the invariants as parameters.
 *
 * (3) THE PAIR LOOP walks ct and st with two `addi ..,4` per pair that only the exact
 * fall-back reads.  The index is recovered from the running pointer in the cold branch
 * instead, which is where it is used.
 *
 * OFF BY DEFAULT: rope_s8 is built into both halves' images and a default flip would move
 * another workstream's control arm under it.  -DMBP_B74=1 selects it.
 */
#ifndef MBP_B74
#define MBP_B74 0
#endif
/* LIVE-PATH PROOF, not a feature -- see the same note in pext_nl_add_s8_pext_int_add.c.
 * Each value perturbs exactly one of the three changes, visibly in the OUTPUT:
 *   2  the restricted apply (and not the generic fx32_apply beside it)
 *   3  the pass-through helper
 *   4  the pair loop's recovered index, which only the exact fall-back reads -- so this
 *      one also proves the gate's adversarial tables drive elements down that path. */
#ifndef MBP_B74_POISON
#define MBP_B74_POISON 0
#endif
#if MBP_B74_POISON == 4
#define MBP_B74_POISON_IDX 1
#else
#define MBP_B74_POISON_IDX 0
#endif

/*
 * B87 -- WHAT IS LEFT AFTER B74, COUNTED OFF THE SHIPPED IMAGE.
 *
 * b74_icount.sh on today's tree, at the encoder's own T = 165, H = 8, D = 36, R = 32:
 * rope_b74 retires 1,126,222 instructions for 47,520 elements = 23.70 an element, and the
 * board (0x5A5A0032, out/b86_attn_on2) spends 1,341,018 cycles a dispatch -- 1.1907 cycles
 * per retired instruction.  THIS LOOP NEST IS INSTRUCTION-BOUND AND ITS FLOOR IS ITS
 * INSTRUCTION COUNT.  The split, from the same run's affine solve:
 *
 *     build   165 x 1,500 =   247,500   22.0 %    93.75 per E[] entry
 *     pairs 1,320 x   562 =   741,840   65.9 %    35.1 per pair, 17.6 an element
 *     pass  1,320 x   104 =   137,280   12.2 %    26.0 per pass-through element
 *
 * (1) THE PASS-THROUGH DIMENSIONS ARE A FUNCTION OF ONE BYTE.  d in [R, D) computes
 *     `(x[d]*KF + half) >> F` with a tie test and an exact fall-back -- and every operand
 *     of that expression except x[d] is fixed for the DISPATCH.  An int8 code has 256
 *     values, so 256 entries reproduce the map on its entire domain: 26 instructions an
 *     element over 5,280 elements becomes 256 builds plus a byte gather.  The entry for u
 *     is the shipped expression evaluated at x[d] == u, term for term, including the tie
 *     test and the exact fall-back -- so the output is bit-identical BY CONSTRUCTION.
 *     (This is B66's groupnorm argument, applied to the loop B74 left at 26.)
 *
 * (2) G IS PER-ENTRY WHERE IT ONLY HAS TO BE PER POSITION.  Half of the build's work is
 *     forming g, glo and ghi for each of the 16 entries, and the pair loop then RELOADS
 *     glo and ghi from memory on every pair -- 8 times over per position, once per head,
 *     for 16 values that do not depend on the head.  g is monotone non-decreasing in |ck|
 *     and |sk|, so one G formed from M = max_i(|ck_i|, |sk_i|) -- two compares an entry,
 *     against about twenty instructions of shifts and adds -- DOMINATES every g_i, and
 *     lives in a register for the whole position.
 *
 *     WIDENING THE BAND IS SAFE AND IT IS NOT A TOLERANCE.  A wider band sends MORE
 *     elements down the exact path, and the exact path is the reference expression
 *     evaluated in exact binary32 -- it returns the reference's own answer.  The narrow
 *     band's fast path returns the reference's answer too; that is this kernel's whole
 *     invariant.  So both routes agree with the reference and therefore with each other,
 *     and the only thing the width costs is instructions.  M <= 2 * min-case gives at most
 *     a 2x band, which b87_gate.sh MEASURES (FX_STATS) rather than assumes.
 *
 *     The per-entry `!ok` and `g >= half/2` marks become a whole-dispatch bail to the
 *     exact loop for the same reason: every element then takes the path that returns the
 *     reference, which is what the marked entries did.  Neither fires on any scale
 *     fx32_ratio can emit.
 *
 * OFF BY DEFAULT: rope_s8 is built into both halves' images and a default flip would move
 * another workstream's control arm under it.  -DMBP_B87=1 selects it.
 */
#ifndef MBP_B87
#define MBP_B87 0
#endif
/*
 * B87b -- THE PASS-THROUGH TABLE MUST BE GUARDED ON THE QUANTITY IT AMORTISES OVER, AND
 * THE FIRST VERSION OF IT WAS NOT.  This is the guard-on-the-wrong-quantity bug that B63
 * found twice and B66 a third time, committed again by the lab that quoted the rule.
 *
 * The table is 256 entries built once per dispatch and it is charged against the dispatch's
 * PASS-THROUGH ELEMENTS, T*H*(D-R) -- not against n, not against T, and not against the
 * kernel's identity.  The two halves are three orders of magnitude apart in that quantity:
 *
 *     encoder   T=165 H=8 D=36 R=32   ->  5,280 pass-through elements
 *     decoder   T=1   H=8 D=36 R=32   ->     32
 *
 * MEASURED on spike at the board's own flags (b87_icount.sh), retired instructions for a
 * whole dispatch:
 *
 *     shape                    control     unguarded B87
 *     T=165 H=8 D=36 R=32    1,126,219       952,410     -15.4 %
 *     T=1   H=8 D=36 R=32        6,765        11,323     +67.4 %   <-- REGRESSION
 *     T=1   H=8 D=32 R=32        5,917        11,099     +87.6 %   <-- and D == R has NO
 *                                                                      pass-through at all
 *
 * The build is ~5,180 instructions and it saves 26.00 - 7.25 = 18.75 an element, so the
 * CROSSOVER IS 276 PASS-THROUGH ELEMENTS.  The guard is set at 512, comfortably above it:
 * the count is instructions and the board spends cycles, so the guard sits on the side of
 * the uncertainty where being wrong costs a little of a saving rather than a lot of a
 * regression -- B66's rule, and the encoder is 10x above the guard either way.
 *
 * Found by measuring the other half's shape instead of carrying a ratio across to it.
 */
#ifndef MBP_B87_PASSTAB_MINEL
#define MBP_B87_PASSTAB_MINEL 512
#endif
#if MBP_B87 && !MBP_B74
/* B87 restructures B74's own build and pass-through routes; without MBP_B74 there is no
 * pint_rope_build and no pint_rope_pass to restructure, and the B63 build below writes
 * the two struct fields B87 removes.  The headline arm sets both. */
#error "MBP_B87 requires MBP_B74=1"
#endif
/* LIVE-PATH PROOF, not a feature.  Each value perturbs one new route, visibly in the
 * OUTPUT.  (Disjoint from the values the other two B87 kernels use: kernels.c
 * concatenates all three into ONE translation unit and they share this macro.)
 *   5  the pass-through table      6  the hoisted G
 */
#ifndef MBP_B87_POISON
#define MBP_B87_POISON 0
#endif

/*
 * B103 -- THE GUARD BAND BELONGS IN THE ROUNDING CONSTANT, NOT IN THE TEST.
 *
 * The decomposition first.  Retired instructions on spike at the board's own flags
 * (b103_icount.sh, control = the shipped -DMBP_B74=1 -DMBP_B87=1) against the board's own
 * cycles (out/b101_combined_0035_f40, 0x5A5A0035 at 40 MHz), T=165 H=8 D=36 R=32:
 *
 *     rope_s8   958,608 instr / 47,520 el = 20.173 an element;  24.477 cyc/el;  CPI 1.2134
 *       build  165 x 1,323 = 218,295   22.8 %
 *       pairs 1,320 x  535 = 706,200   73.7 %    16.72 an element over the rotated dims
 *       pass  1,320 x   20 =  26,400    2.8 %
 *
 * THE PAIR LOOP IS THE ROW.  Off the shipped image (out/b101_combined_0035_f40/enc_q16/
 * dis.txt, the loop at 0x8000cd84) it is 28 instructions for TWO elements: two lb, two ld
 * of the entry, four mul, two combining adds, two rounding adds, two shifts, two masks,
 * two band adds, two branches, two CLIP8, two sb, and three pointer bumps with a branch.
 * Gauss's three-multiply complex product does not help -- it trades one mul for three adds
 * and the loop is instruction-bound, so it is a net +2 -- and precomputing (ck+sk, sk-ck)
 * into the entry pays the saving straight back in a third `ld`.  What IS removable is the
 * same one instruction per element that add_s8 carries: `(x & mask) + (g - half) <= 2g` and
 * `(x + half) >> F` share a constant.
 *
 * Fold it: HG = half + g, q = x + HG, then `v = q >> F` and `(q & mask) <= 2g`.  The two
 * identities are the ones set out at length in pext_nl_add_s8_pext_int_add.c's B103 note --
 * the test selects the same elements because half + g < 2^F and g < half/2, and the value
 * is unchanged on every element the test does not take because adding g cannot carry out of
 * the low F bits there.  Under B87 g is ONE value for the whole position, so HG is formed
 * once per head and the loop loses two instructions a pair.
 *
 * THE g = half SENTINEL SURVIVES IT.  Without B87 a refused entry is marked by g = half,
 * which makes glo = 0 and ghi = 2^F so the test fires on every element.  In the folded form
 * HG = 2 * half = 2^F, (q & mask) == (x & mask) < 2^F <= ghi, and the test still fires on
 * every element -- the same whole-entry fall-back to the exact path.
 *
 * WHAT IT IS WORTH.  One instruction of 20.173, on the 42,240 rotated elements of each of
 * the twelve dispatches.  That is the honest size of it.
 *
 * OFF BY DEFAULT: rope_s8 is built into both halves' images and a default flip would move
 * another workstream's control arm under it.  -DMBP_B103=1 selects it; it requires MBP_B87.
 */
#ifndef MBP_B103
#define MBP_B103 0
#endif
#if MBP_B103 && !(MBP_B74 && MBP_B87)
#error "MBP_B103 restructures the B87 pair loop and requires MBP_B74=1 MBP_B87=1"
#endif
/* LIVE-PATH PROOF, not a feature.  8 perturbs the B103 pair store, visibly in the OUTPUT.
 * (Disjoint from the values the other kernels in this translation unit use.) */
#ifndef MBP_B103_POISON
#define MBP_B103_POISON 0
#endif

#ifdef FX_STATS
unsigned long pint_rope_slow_count, pint_rope_count;
#define PINT_ROPE_SLOW() (pint_rope_slow_count++)
#define PINT_ROPE_N(n) (pint_rope_count += (unsigned long)(n))
#else
#define PINT_ROPE_SLOW() ((void)0)
#define PINT_ROPE_N(n) ((void)0)
#endif

/* y0 (which = 0) or y1 (which = 1) of one pair, exactly as the reference evaluates it. */
static int32_t pint_rope_exact(int a0, int a1, float c, float s, fx32_t si, fx32_t so, int which)
{
	fx32_t x0 = fx32_mul(fx32_int(a0), si);
	fx32_t x1 = fx32_mul(fx32_int(a1), si);
	fx32_t fc = fx32_dec(c), fs = fx32_dec(s), y;

	PINT_ROPE_SLOW();
	if (which == 0) {
		y = fx32_add(fx32_mul(x0, fc), fx32_mul(fx32_neg(x1), fs));
	} else {
		y = fx32_add(fx32_mul(x1, fc), fx32_mul(x0, fs));
	}
	return fx32_roundf_i32(fx32_div(y, so));
}

static int32_t pint_rope_pass_exact(int a, fx32_t si, fx32_t so)
{
	PINT_ROPE_SLOW();
	return fx32_roundf_i32(fx32_div(fx32_mul(fx32_int(a), si), so));
}

static inline int64_t pint_rope_clamp(int64_t v, int amin, int amax)
{
	return v < amin ? amin : (v > amax ? amax : v);
}

static inline uint64_t pint_abs64(int64_t v)
{
	return v < 0 ? (uint64_t)-v : (uint64_t)v;
}

#if MBP_B74
/* fx32_apply restricted to m < 2^24 and kq <= 2^40, which is every argument this kernel
 * forms: no __int128, no __clzdi2, same value and same *ok.  See the note above. */
static inline int64_t pint_rope_apply(uint64_t m, int32_t e, int32_t neg,
				      uint64_t kq, int32_t kef, int *ok)
{
	const uint64_t p = m * kq;           /* exact in 64 bits */
	const int sh = -(e + kef);           /* kef == k.e + F, hoisted by the caller */
	uint64_t r;

	if (p == 0) {
		return 0;
	}
	if (sh <= 0) {
		if (sh <= -61 || (p >> (61 + sh)) != 0) {
			*ok = 0;
			return 0;
		}
		r = p << -sh;
	} else if (sh >= 65) {
		r = 0;
	} else if (sh == 64) {
		r = p >> 63;
	} else {
		r = (p >> sh) + ((p >> (sh - 1)) & 1);
		if ((r >> 61) != 0) {
			*ok = 0;
			return 0;
		}
	}
	return neg ? -(int64_t)r : (int64_t)r;
}

/* The pass-through dimensions d in [R, D).  `full` is a constant at every call site. */
#if MBP_B87
static inline __attribute__((always_inline)) void
pint_rope_pass_lut(const int8_t *x, int8_t *y, int nd, const int8_t *tab)
{
	const int8_t *const xe = x + nd;

	for (; x < xe; x++, y++) {
		*y = tab[(uint8_t)*x];
	}
}
#endif

static inline __attribute__((always_inline)) void
pint_rope_pass(const int8_t *x, int8_t *y, int nd, int64_t KF, uint64_t Gp,
	       uint64_t mask, uint64_t half, int F, fx32_t si, fx32_t so,
	       int amin, int amax, int full)
{
	const uint64_t hh = half / 2;
	const int8_t *const xe = x + nd;

	for (; x < xe; x++, y++) {
		const int64_t xp = (int64_t)*x * KF;
		const uint64_t g = (pint_abs64(xp) >> 21) + Gp;
		int64_t v;

		if (__builtin_expect(g >= hh ||
				     (((uint64_t)xp & mask) - half + g) <= 2 * g, 0)) {
			v = pint_rope_pass_exact(*x, si, so);
		} else {
			v = (xp + (int64_t)half) >> F;
		}
#if MBP_B74_POISON == 3
		*y = (int8_t)((full ? mb_pext_clip8(v) : pint_rope_clamp(v, amin, amax)) ^ 1);
#else
		if (full) {
			*y = (int8_t)mb_pext_clip8(v);
		} else {
			*y = (int8_t)pint_rope_clamp(v, amin, amax);
		}
#endif
	}
}
#endif /* MBP_B74 */


#ifndef MBP_ROPE_NO_FAST
struct rope_e {
	int64_t ck, sk;
#if !MBP_B87
	uint64_t glo;                 /* g - half, in the wrapping arithmetic the test uses */
	uint64_t ghi;                 /* 2g */
#endif
};

#if MBP_B74
/* One position's R2 entries.  `gen` is a constant at both call sites, so the dispatch
 * between the restricted and the generic apply is made ONCE per dispatch, not per entry,
 * and neither copy carries the other's branch. */
static inline __attribute__((always_inline)) void
pint_rope_build(struct rope_e *E, const float *ct, const float *st, int R2,
		fx32_k_t k, int F, uint64_t half, int gen
#if MBP_B87
		, uint64_t *pmax, int *pok
#endif
		)
{
	const int32_t kef = k.e + F;
	int i;
#if MBP_B87
	uint64_t mx = 0;
	int allok = 1;
#endif

	for (i = 0; i < R2; i++) {
		fx32_t c = fx32_dec(ct[i]), s = fx32_dec(st[i]);
		int ok1 = 1, ok2 = 1;
		int64_t ck, sk;
#if !MBP_B87
		uint64_t g;
#endif

		if (gen) {
			ck = fx32_apply(c.m, c.e, c.neg, k, F, &ok1);
			sk = fx32_apply(s.m, s.e, s.neg, k, F, &ok2);
		} else {
			ck = pint_rope_apply(c.m, c.e, c.neg, k.q, kef, &ok1);
			sk = pint_rope_apply(s.m, s.e, s.neg, k.q, kef, &ok2);
#if MBP_B74_POISON == 2
			ck >>= 1;
#endif
		}
#if MBP_B87
		/* B87 (2): the running maximum, two compares, in place of g's shifts. */
		if (pint_abs64(ck) > mx) {
			mx = pint_abs64(ck);
		}
		if (pint_abs64(sk) > mx) {
			mx = pint_abs64(sk);
		}
		allok &= ok1 & ok2;
		E[i].ck = ck;
		E[i].sk = sk;
#else
		g = ((128 * (pint_abs64(ck) + pint_abs64(sk))) >> 21)
		    + 128 * ((pint_abs64(ck) >> 38) + (pint_abs64(sk) >> 38) + 2) + 4;
		if (!(ok1 && ok2) || g >= half / 2) {
			g = half;
		}
		E[i].ck = ck;
		E[i].sk = sk;
		E[i].glo = g - half;
		E[i].ghi = 2 * g;
#endif
	}
#if MBP_B87
	*pmax = mx;
	*pok = allok;
#endif
}

#if MBP_B87
/* g evaluated at |ck| = |sk| = M.  g is monotone non-decreasing in both, so this
 * dominates every entry's own g -- see note (2). */
static inline uint64_t pint_rope_gmax(uint64_t mx)
{
	return ((128 * (mx + mx)) >> 21) + 128 * ((mx >> 38) + (mx >> 38) + 2) + 4;
}

/* B87 (1): the pass-through map on its entire domain.  The body is the shipped
 * pint_rope_pass body evaluated at *x == u, term for term, tie test and exact fall-back
 * included. */
static void pint_rope_pass_tab(int8_t *tab, int64_t KF, uint64_t Gp, uint64_t mask,
			       uint64_t half, int F, fx32_t si, fx32_t so,
			       int amin, int amax, int full)
{
	const uint64_t hh = half / 2;
	int u;

	for (u = 0; u < 256; u++) {
		const int xv = (int8_t)(uint8_t)u;
		const int64_t xp = (int64_t)xv * KF;
		const uint64_t g = (pint_abs64(xp) >> 21) + Gp;
		int64_t v;

		if (g >= hh || (((uint64_t)xp & mask) - half + g) <= 2 * g) {
			v = pint_rope_pass_exact(xv, si, so);
		} else {
			v = (xp + (int64_t)half) >> F;
		}
#if MBP_B87_POISON == 5
		v ^= 1;
#endif
		tab[u] = full ? (int8_t)mb_pext_clip8(v)
			      : (int8_t)pint_rope_clamp(v, amin, amax);
	}
}
#endif /* MBP_B87 */
#endif /* MBP_B74 */

/* One (t, h)'s R2 pairs.  `full` is a constant at every call site, so the clamp is either
 * two CLIP8s or two compare chains and never a branch inside the loop. */
static inline __attribute__((always_inline)) void
pint_rope_pairs(const int8_t *x, int8_t *y, const struct rope_e *e, int R2,
		uint64_t mask, uint64_t half, int F,
		const float *ct, const float *st, fx32_t si, fx32_t so,
		int amin, int amax, int full
#if MBP_B87
		, uint64_t glo_, uint64_t ghi_
#endif
		)
{
	const int8_t *xe = x + 2 * R2;
#if MBP_B103
	/* B103: half + g, formed once per head.  Under B87 ghi_ = 2g is invariant over the
	 * whole position, so this is two instructions per head against two a pair. */
	const int64_t HG = (int64_t)(half + (ghi_ >> 1));
#endif
#if MBP_B74
	const int8_t *const x0_ = x;
#else
	int i = 0;
#endif

#if MBP_B74
	for (; x < xe; x += 2, y += 2, e++) {
#else
	for (; x < xe; x += 2, y += 2, e++, i++) {
#endif
		const int a0 = x[0], a1 = x[1];
		const int64_t ck = e->ck, sk = e->sk;
#if MBP_B103
		const int64_t x0 = (int64_t)a0 * ck - (int64_t)a1 * sk + HG;
		const int64_t x1 = (int64_t)a1 * ck + (int64_t)a0 * sk + HG;
		const uint64_t glo = 0, ghi = ghi_;
#else
		const int64_t x0 = (int64_t)a0 * ck - (int64_t)a1 * sk;
		const int64_t x1 = (int64_t)a1 * ck + (int64_t)a0 * sk;
#if MBP_B87
		const uint64_t glo = glo_, ghi = ghi_;
#else
		const uint64_t glo = e->glo, ghi = e->ghi;
#endif
#endif
		int64_t v0, v1;

		if (__builtin_expect((((uint64_t)x0 & mask) + glo) <= ghi, 0)) {
#if MBP_B74
			const int i = (int)((x - x0_) >> 1) + MBP_B74_POISON_IDX;
#endif
			v0 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 0);
		} else {
#if MBP_B103
			v0 = x0 >> F;
#else
			v0 = (x0 + (int64_t)half) >> F;
#endif
		}
		if (__builtin_expect((((uint64_t)x1 & mask) + glo) <= ghi, 0)) {
#if MBP_B74
			const int i = (int)((x - x0_) >> 1) + MBP_B74_POISON_IDX;
#endif
			v1 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 1);
		} else {
#if MBP_B103
			v1 = x1 >> F;
#else
			v1 = (x1 + (int64_t)half) >> F;
#endif
		}
#if MBP_B103_POISON == 8
		v0 ^= 1;
#endif
		if (full) {
			y[0] = (int8_t)mb_pext_clip8(v0);
			y[1] = (int8_t)mb_pext_clip8(v1);
		} else {
			y[0] = (int8_t)pint_rope_clamp(v0, amin, amax);
			y[1] = (int8_t)pint_rope_clamp(v1, amin, amax);
		}
	}
}
#endif /* !MBP_ROPE_NO_FAST */

void kernel_rope_s8(const int8_t *input, const float *cos_tab,
		    const float *sin_tab, int8_t *output,
		    int T, int H, int D, int R,
		    float scale_in, float scale_out,
		    int activation_min, int activation_max)
{
	const fx32_t si = fx32_dec(scale_in), so = fx32_dec(scale_out);
	const int R2 = R / 2;
#ifdef MBP_ROPE_NO_FAST
	int64_t CK[MBP_ROPE_R2MAX], SK[MBP_ROPE_R2MAX];
	uint64_t G[MBP_ROPE_R2MAX];
	uint8_t slow[MBP_ROPE_R2MAX];
#else
	/*
	 * B63.  The control's pair loop is 61 instructions for TWO elements with SIX taken
	 * control transfers, and the arithmetic rope is defined as -- four multiplies, two
	 * adds, two rounding shifts, two clamps and two stores -- is 14 of them.  The other
	 * 47 are bookkeeping that does not depend on the element:
	 *
	 *   - `fast` is a whole-dispatch flag reloaded from the stack and branched on once
	 *     per PAIR (`ld a5,32(sp)` / `bnez`);
	 *   - `slow[i]` is a second per-i flag with its own `add sp,i` / `lbu` / `bnez`;
	 *   - CK[i], SK[i] and G[i] are three separate stack arrays, so one `slli` and three
	 *     `add sp` re-form three addresses for what is one index;
	 *   - `g - half` and `2g` are recomputed from G[i] on every (h, i) although they are
	 *     constant in h, and `half`, `mask`, `F` and R2 are reloaded from the stack;
	 *   - the clamp is two compares and three moves per element where this core has a
	 *     one-instruction CLIP8.
	 *
	 * So: ONE array of 32-byte entries walked by a running pointer, carrying the two
	 * multipliers and the tie test's two constants already folded; `slow[i]` folded INTO
	 * that test as g = half, which makes `(x & mask) - half + g <= 2g` true for every x
	 * and sends the element down the identical exact path; and `fast` hoisted out of the
	 * i loop entirely.  Same products, same tie decisions, same exact fallback -- a pure
	 * restructuring, so max_abs_err = 0 is the right instrument.
	 */
	struct rope_e E[MBP_ROPE_R2MAX];
#endif
	int64_t KF = 0;
	uint64_t Gp = 0, half = 0, mask = 0;
	fx32_k_t k;
	int F = 0, t, h, i, d, ok = 1, fast = 1;
#if MBP_B74
	int kq_small = 0;
#endif
#if MBP_B87
	int8_t ptab[256];             /* the pass-through map, built once per dispatch */
	uint64_t bglo = 0, bghi = 0;  /* the position's G, in the pair test's own form */
	int use_ptab = 0;             /* guarded on T*H*(D-R) -- see the note above */
#endif

	PINT_ROPE_N((long)T * H * D);
	if (!(fx32_scale_ok(si) && fx32_scale_ok(so)) || R2 > MBP_ROPE_R2MAX) {
		fast = 0;
	} else {
		/* |c|,|s| <= 1: |CK| <= si/so * 2^F ~ 2^50, so |x| <= 256 * 2^50 fits. */
		F = 50 - ((fx32_bitlen64(si.m) + si.e) - (fx32_bitlen64(so.m) + so.e));
		if (F < 16 || F > 55) {
			fast = 0;
		}
	}
	if (fast) {
		k = fx32_ratio(si, so);
#if MBP_B74
		/* The restricted apply needs m * k.q to be exact in 64 bits.  m is a binary32
		 * mantissa (< 2^24) at every call, and fx32_ratio's header pins k.q to
		 * (2^38, 2^40] -- but the identity is made unconditional by testing it rather
		 * than by trusting the header. */
		kq_small = (k.q != 0 && k.q <= ((uint64_t)1 << 40));
#endif
		KF = fx32_apply(1, 0, 0, k, F, &ok);
		if (!ok) {
			fast = 0;
		}
		half = (uint64_t)1 << (F - 1);
		mask = ((uint64_t)1 << F) - 1;
		/* pass-through: two float ops, 2.0001 * 2^-24 of |x|; the multiplier's bound x128 */
		Gp = 128 * ((pint_abs64(KF) >> 38) + 1) + 4;
#if MBP_B87
		/* D == R means there are no pass-through dimensions at all, and the table
		 * would be built for nobody; below the guard it is built for too few. */
		use_ptab = (D > R) &&
			   ((long)T * (long)H * (long)(D - R) >= MBP_B87_PASSTAB_MINEL);
		if (fast && use_ptab) {
			if (activation_min == -128 && activation_max == 127) {
				pint_rope_pass_tab(ptab, KF, Gp, mask, half, F, si, so,
						   -128, 127, 1);
			} else {
				pint_rope_pass_tab(ptab, KF, Gp, mask, half, F, si, so,
						   activation_min, activation_max, 0);
			}
		}
#endif
	}

	for (t = 0; t < T; t++) {
		const float *ct = cos_tab + (size_t)t * (size_t)R2;
		const float *st = sin_tab + (size_t)t * (size_t)R2;

		if (fast) {
#ifdef MBP_ROPE_NO_FAST
			for (i = 0; i < R2; i++) {
				fx32_t c = fx32_dec(ct[i]), s = fx32_dec(st[i]);
				int ok1 = 1, ok2 = 1;

				CK[i] = fx32_apply(c.m, c.e, c.neg, k, F, &ok1);
				SK[i] = fx32_apply(s.m, s.e, s.neg, k, F, &ok2);
				slow[i] = !(ok1 && ok2);
				G[i] = ((128 * (pint_abs64(CK[i]) + pint_abs64(SK[i]))) >> 21)
				       + 128 * ((pint_abs64(CK[i]) >> 38) + (pint_abs64(SK[i]) >> 38) + 2) + 4;
				if (G[i] >= half / 2) {
					slow[i] = 1;
				}
			}
#elif MBP_B87
			{
				uint64_t bmax = 0, gm;
				int bok = 1;

				if (kq_small) {
					pint_rope_build(E, ct, st, R2, k, F, half, 0,
							&bmax, &bok);
				} else {
					pint_rope_build(E, ct, st, R2, k, F, half, 1,
							&bmax, &bok);
				}
				gm = pint_rope_gmax(bmax);
#if MBP_B87_POISON == 6
				/* THE G HOIST CANNOT BE POISONED THROUGH THE OUTPUT, and that
				 * is the same fact that makes it safe: both sides of the tie
				 * band return the reference, so widening or narrowing it moves
				 * no byte.  B74's first poison failed for the analogous reason
				 * and was rejected "for the right reason and the wrong one".
				 * So this arm is a LIVENESS poison scored on a COUNTER, not on
				 * bytes: g = half sends EVERY element down the exact path, and
				 * b87_gate.sh requires the FX_STATS exact-path count to reach
				 * 100 % -- which it cannot if the hoisted G is dead. */
				gm = half;
#endif
				/* g = half makes the pair test hold for every x, which is what
				 * the per-entry marks asked for -- and the exact path is the
				 * reference. */
				if (!bok || gm >= half / 2) {
					gm = half;
				}
				bglo = gm - half;
				bghi = 2 * gm;
			}
#elif MBP_B74
			if (kq_small) {
				pint_rope_build(E, ct, st, R2, k, F, half, 0);
			} else {
				pint_rope_build(E, ct, st, R2, k, F, half, 1);
			}
#else
			for (i = 0; i < R2; i++) {
				fx32_t c = fx32_dec(ct[i]), s = fx32_dec(st[i]);
				int ok1 = 1, ok2 = 1;
				int64_t ck, sk;
				uint64_t g;

				ck = fx32_apply(c.m, c.e, c.neg, k, F, &ok1);
				sk = fx32_apply(s.m, s.e, s.neg, k, F, &ok2);
				g = ((128 * (pint_abs64(ck) + pint_abs64(sk))) >> 21)
				    + 128 * ((pint_abs64(ck) >> 38) + (pint_abs64(sk) >> 38) + 2) + 4;
				/* g = half makes (x & mask) - half + g <= 2g hold for every x, which
				 * is exactly what the control's slow[i] asked for. */
				if (!(ok1 && ok2) || g >= half / 2) {
					g = half;
				}
				E[i].ck = ck;
				E[i].sk = sk;
				E[i].glo = g - half;
				E[i].ghi = 2 * g;
			}
#endif
		}
		for (h = 0; h < H; h++) {
			/* B101: the head-granularity re-entry point.  BEFORE the head, so the
			 * driver can post engine work and rope covers it; and before the body's
			 * several `continue`s, so every head reaches it on every path. */
			MBP_ROPE_YIELD();
			const size_t base = ((size_t)t * (size_t)H + (size_t)h) * (size_t)D;
			const int8_t *x = input + base;
			int8_t *y = output + base;

#ifdef MBP_ROPE_NO_FAST
			for (i = 0; i < R2; i++) {
				const int a0 = x[2 * i], a1 = x[2 * i + 1];
				int64_t v0, v1;

				if (fast && !slow[i]) {
					const int64_t x0 = (int64_t)a0 * CK[i] - (int64_t)a1 * SK[i];
					const int64_t x1 = (int64_t)a1 * CK[i] + (int64_t)a0 * SK[i];
					const uint64_t g = G[i];

					if ((((uint64_t)x0 & mask) - half + g) <= 2 * g) {
						v0 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 0);
					} else {
						v0 = (x0 + (int64_t)half) >> F;
					}
					if ((((uint64_t)x1 & mask) - half + g) <= 2 * g) {
						v1 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 1);
					} else {
						v1 = (x1 + (int64_t)half) >> F;
					}
				} else {
					v0 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 0);
					v1 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 1);
				}
				y[2 * i] = (int8_t)pint_rope_clamp(v0, activation_min, activation_max);
				y[2 * i + 1] = (int8_t)pint_rope_clamp(v1, activation_min, activation_max);
			}
#else
			if (!fast) {
				for (i = 0; i < R2; i++) {
					const int a0 = x[2 * i], a1 = x[2 * i + 1];
					int64_t v0 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 0);
					int64_t v1 = pint_rope_exact(a0, a1, ct[i], st[i], si, so, 1);

					y[2 * i] = (int8_t)pint_rope_clamp(v0, activation_min,
									   activation_max);
					y[2 * i + 1] = (int8_t)pint_rope_clamp(v1, activation_min,
									       activation_max);
				}
#if MBP_B87
			} else if (activation_min == -128 && activation_max == 127) {
				pint_rope_pairs(x, y, E, R2, mask, half, F, ct, st, si, so,
						-128, 127, 1, bglo, bghi);
			} else {
				pint_rope_pairs(x, y, E, R2, mask, half, F, ct, st, si, so,
						activation_min, activation_max, 0, bglo, bghi);
			}
#else
			} else if (activation_min == -128 && activation_max == 127) {
				pint_rope_pairs(x, y, E, R2, mask, half, F, ct, st, si, so,
						-128, 127, 1);
			} else {
				pint_rope_pairs(x, y, E, R2, mask, half, F, ct, st, si, so,
						activation_min, activation_max, 0);
			}
#endif
#endif
#if MBP_B87
			if (fast && use_ptab) {
				pint_rope_pass_lut(x + R, y + R, D - R, ptab);
				continue;
			}
			if (fast && activation_min == -128 && activation_max == 127) {
				pint_rope_pass(x + R, y + R, D - R, KF, Gp, mask, half, F,
					       si, so, -128, 127, 1);
				continue;
			}
			if (fast) {
				pint_rope_pass(x + R, y + R, D - R, KF, Gp, mask, half, F,
					       si, so, activation_min, activation_max, 0);
				continue;
			}
#elif MBP_B74
			if (fast && activation_min == -128 && activation_max == 127) {
				pint_rope_pass(x + R, y + R, D - R, KF, Gp, mask, half, F,
					       si, so, -128, 127, 1);
				continue;
			}
			if (fast) {
				pint_rope_pass(x + R, y + R, D - R, KF, Gp, mask, half, F,
					       si, so, activation_min, activation_max, 0);
				continue;
			}
#endif
			for (d = R; d < D; d++) {
				int64_t v;

				if (fast) {
					const int64_t xp = (int64_t)x[d] * KF;
					const uint64_t g = (pint_abs64(xp) >> 21) + Gp;

#ifdef MBP_ROPE_NO_FAST
					if (g >= half / 2 || (((uint64_t)xp & mask) - half + g) <= 2 * g) {
#else
					if (__builtin_expect(g >= half / 2 ||
							     (((uint64_t)xp & mask) - half + g)
							     <= 2 * g, 0)) {
#endif
						v = pint_rope_pass_exact(x[d], si, so);
					} else {
						v = (xp + (int64_t)half) >> F;
					}
				} else {
					v = pint_rope_pass_exact(x[d], si, so);
				}
#ifdef MBP_ROPE_NO_FAST
				y[d] = (int8_t)pint_rope_clamp(v, activation_min, activation_max);
#else
				y[d] = (activation_min == -128 && activation_max == 127)
					? (int8_t)mb_pext_clip8(v)
					: (int8_t)pint_rope_clamp(v, activation_min, activation_max);
#endif
			}
		}
	}
}
