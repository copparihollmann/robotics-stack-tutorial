/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_add */
/* accuracy_class: bit_exact */
/* origin: patches/0100, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * add_s8 -- the residual add -- with no floating-point arithmetic, and still bit-exact.
 *
 * The reference is `(int32_t)roundf(((float)a*sa + (float)b*sb) / so)`: two float32
 * multiplies, an add, a divide and a roundf per element, 706 cycles/element measured on
 * this WithoutFPU core (ROCC_DECOUPLED.md 2.2), 19 % of a transformer MLP block.
 *
 * FAST PATH.  Two 256-entry int64 tables built once per dispatch, ta[a] = a*sa/so and
 * tb[b] = b*sb/so in fixed point with F fractional bits, so an element is two loads, an
 * add, a rounding shift and a clamp.
 *
 * WHY IT IS STILL THE REFERENCE.  The fixed-point sum x differs from the reference's
 * float32 value only by (i) the float32 chain's rounding, at most 3.0001 * 2^-24 of
 * U = (|a|*sa + |b|*sb)/so, and (ii) the tables' own truncation, at most 128*(eA + eB)
 * units.  If x is further than G = both bounds from every half-integer, x and the
 * reference round to the same integer -- so the fast path's answer IS the reference's.
 * Otherwise the element takes the SLOW path: the reference expression evaluated in exact
 * IEEE-754 binary32 arithmetic on integers (fpga/pynq-z2/sw/fexact32.h), same operations,
 * same order, round-half-even after each, roundf at the end.  At Moonshine's scales that
 * is a few elements in ten thousand.
 *
 * Nothing here is a floating-point instruction: the float arguments are decoded from
 * their bit patterns.  G is taken per dispatch with a 4x margin over (i) (2^-22 against
 * 3.0001 * 2^-24).  Scales outside [2^-40, 2^40] -- none that calibration produces --
 * send every element down the exact slow path rather than trusting the bound.
 *
 * ACCURACY IS CHECKED OVER THE WHOLE OPERAND DOMAIN, not sampled:
 * check_moonshine.py compares this kernel with the reference compiled for the host over
 * all 65,536 (a, b) pairs at every scale triple Moonshine's encoder uses, and at random
 * and adversarial (tie-heavy) triples.
 */
#include <stddef.h>
#include <stdint.h>
#include "fexact32.h"
#include "pext.h"

/* -DFX_STATS (host checks only): count the elements that took the exact slow path. */
#ifdef FX_STATS
unsigned long pint_add_slow_count, pint_add_count;
#define PINT_ADD_SLOW() (pint_add_slow_count++)
#define PINT_ADD_N(n) (pint_add_count += (unsigned long)(n))
#else
#define PINT_ADD_SLOW() ((void)0)
#define PINT_ADD_N(n) ((void)0)
#endif

static int32_t pint_add_exact(int a, int b, fx32_t sa, fx32_t sb, fx32_t so)
{
	PINT_ADD_SLOW();
	fx32_t fa = fx32_mul(fx32_int(a), sa);
	fx32_t fb = fx32_mul(fx32_int(b), sb);

	return fx32_roundf_i32(fx32_div(fx32_add(fa, fb), so));
}


#ifndef MBP_ADD_NO_FAST
/*
 * B63 -- THE TABLE BUILD, WHICH IS THE WHOLE COST AT THE DECODER'S SHAPE.
 *
 * At n = 288 (every decoder dispatch) the two 256-entry tables are charged against 288
 * elements instead of 47,520, and they dominate: 512 fx32_apply calls, each doing a
 * 128-bit multiply and an fx32_bitlen128 that this core -- rv64imac, no Zbb -- lowers to
 * an OUT-OF-LINE libgcc __clzdi2 call.  Counted off the run's own dis.txt that is ~136
 * instructions per (ta, tb) entry pair, ~34,800 per dispatch.
 *
 * None of it is necessary at this argument range.  fx32_ratio's header pins k.q to
 * (2^38, 2^40], and the table's arguments are m = |v| <= 128 with e = 0, so
 *
 *     p = m * k.q <= 2^47   is EXACT in 64 bits, and is monotone in m.
 *
 * Therefore (a) no __int128 and no clz; (b) p is carried by repeated addition of k.q,
 * one add per entry; (c) fx32_apply's *ok test is monotone in m, so the single m = 128
 * entry decides it for the whole table -- the same `goto slow_all` on the same
 * dispatches; (d) |t| is monotone in m too, so the control's entry-by-entry maximum
 * ea = max_i(|t[i]| >> 38) is exactly |t[0x80]| >> 38.
 *
 * Same values, same control flow: the tables are BIT-IDENTICAL to fx32_apply's, which is
 * why max_abs_err = 0 means something here.  The one branch fx32_ratio cannot produce --
 * k.q above 2^40 -- keeps the generic path rather than a bail, so the identity holds
 * unconditionally and not only on the scales calibration happens to emit.
 */
static int pint_add_table(int64_t *t, fx32_k_t k, int F, uint64_t *emax)
{
	const int sh = -(k.e + F);
	uint64_t p = 0, r, hi;
	int m;

	if (k.q == 0 || k.q > ((uint64_t)1 << 40)) {
		int ok = 1;
		uint64_t e = 0;

		for (m = 0; m < 256; m++) {
			int v = (int8_t)(uint8_t)m;

			t[m] = fx32_apply((uint64_t)(v < 0 ? -v : v), 0, v < 0, k, F, &ok);
			if (!ok) {
				return 0;
			}
			if ((uint64_t)(t[m] < 0 ? -t[m] : t[m]) >> 38 > e) {
				e = (uint64_t)(t[m] < 0 ? -t[m] : t[m]) >> 38;
			}
		}
		*emax = e;
		return 1;
	}
	/* (c): p is monotone in m, so the m = 128 entry decides *ok for all 256. */
	hi = (uint64_t)128 * k.q;
	if (sh <= 0) {
		if (fx32_bitlen64(hi) - sh > 61) {
			return 0;
		}
	} else if (sh <= 48) {
		if (fx32_bitlen64((hi + ((uint64_t)1 << (sh - 1))) >> sh) > 61) {
			return 0;
		}
	}
	/* sh >= 49: p <= 2^47 < 2^(sh-1), so the rounded sum cannot reach 2^sh and every
	 * entry is 0 -- which is also what fx32_apply's sh > 120 arm returns. */
	t[0] = 0;
	if (sh <= 0) {
		const int l = -sh;

		for (m = 1; m <= 128; m++) {
			p += k.q;
			r = p << l;
			if (m < 128) {
				t[m] = (int64_t)r;
			}
			t[256 - m] = -(int64_t)r;
		}
	} else if (sh <= 48) {
		const uint64_t rnd = (uint64_t)1 << (sh - 1);

		for (m = 1; m <= 128; m++) {
			p += k.q;
			r = (p + rnd) >> sh;
			if (m < 128) {
				t[m] = (int64_t)r;
			}
			t[256 - m] = -(int64_t)r;
		}
	} else {
		for (m = 1; m < 256; m++) {
			t[m] = 0;
		}
	}
	*emax = (uint64_t)(-t[0x80]) >> 38;
	return 1;
}

/*
 * B66 -- THE GUARD IS RIGHT, THE CROSSOVER IS NOT WHERE IT WAS PRICED, AND ON THIS MODEL
 * THIS ROUTE IS NEVER TAKEN.  Read that before reading the code, because the code below is
 * worth zero cycles on Moonshine and is kept for what it states rather than what it saves.
 *
 * B63 made the BUILD cheap and did not ask whether the build is worth doing.  That question
 * is about n and nothing else, so B63 predicted a crossover at n ~ 1,320 from a fixed cost
 * of ~6,600 cycles and a per-element delta of ~5.  MEASURED (test/b66_icount.sh, retired
 * instructions on spike at the board's own flags):
 *
 *     n        table    no table
 *     64       4,279       2,975     <- no table wins
 *     128      5,754       5,529     <- no table wins, by 4 %
 *     256      8,707      10,650     <- the table wins
 *     288      9,463      11,933     <- the decoder's own shape: the table wins by 26 %
 *     47,520 1,105,261   1,903,946
 *
 * Fitting both lines over 1,024..2,048: the table is 2,809 + 23.12n and the no-table route
 * is 434 + 39.98n.  So the fixed cost is ~2,800 instructions (not the ~4,800 that ~6,600
 * cycles implies) and the per-element delta is 16.85 (not ~5): THE CROSSOVER IS n = 141,
 * not 1,320 -- wrong by 9.4x, and in the direction that matters.  The 1,320 was priced
 * against the builder's cost BEFORE B63's own change removed it; B63's fix moved the
 * crossover below the decoder's n and so retired the second half of its own finding
 * without noticing.  The decoder's 432
 * dispatches are n = 288 and the encoder's 12 are n = 47,520: BOTH ARE ABOVE 141, so unlike
 * layernorm_s8 this op does NOT want opposite implementations in the two halves, and the
 * table B63 landed is the right choice at every shape this graph contains.
 *
 * The guard is kept anyway, at 128, because the rule B63's two bugs established is that a
 * kernel shared between the halves must STATE which quantity its fast path is profitable in
 * and guard on that one.  This one states n, and 128 sits just below the measured 141 so
 * the route fires only where it is measured to win.  It costs one compare per dispatch and
 * fires on nothing this model dispatches.
 *
 * The value is the SAME VALUE: pint_add_t1(v) is entry v of the table pint_add_table
 * would have written, term for term, so the element's x is bit-identical and the tie test,
 * G, the exact fall-back and the clamp all behave exactly as they do above the guard.
 *
 * Restricted to the regime fx32_ratio's header pins (k.q in (2^38, 2^40]) and to sh <= 0,
 * which is pint_add_table's LEFT-SHIFT arm: there the entry is m * k.q << l with no
 * rounding constant, so it is one multiply and one shift.  That arm is not a guess about
 * the model -- a sweep of the 444 scale triples this graph ships puts every one of them at
 * sh in [-5, 0] (b66_add_gate.c section 0 counts it, and it is the first thing that gate
 * prints, because a no-build route that silently never fires would pass a byte-for-byte
 * gate perfectly).  Outside the regime the table route is taken rather than growing a
 * second copy of the element loop; being wrong there costs the build, which is the thing
 * this guard is about.
 */
static inline int64_t pint_add_t1(int v, uint64_t kq, int l)
{
	const int64_t r = (int64_t)(((uint64_t)(unsigned)(v < 0 ? -v : v) * kq) << l);

	return v < 0 ? -r : r;
}
#endif /* !MBP_ADD_NO_FAST */

/* Below this n the two tables cost more than they save.  MEASURED at 141 (see above); set
 * below it, and above nothing this model dispatches.  0 disables the route entirely, which
 * is the control arm and is also what this model gets in practice. */
#ifndef MBP_ADD_MINN
#define MBP_ADD_MINN 128
#endif

/*
 * B74 -- THE TABLE IS A LINEAR MAP, SO AT EVERY n THE TWO LOADS ARE TWO MULTIPLIES.
 *
 * B63 made the BUILD cheap.  B66 asked whether the build is worth doing and answered in n,
 * measuring the crossover at 141 and concluding that both shipped shapes sit above it so
 * "the table B63 landed is the right choice at every shape this graph contains".  That
 * conclusion was drawn against a no-table route written the expensive way, and it is the
 * ROUTE that was wrong, not the answer: B66's fit puts the table at 23.12 instructions an
 * element and the no-table route at 39.98, because `pint_add_t1` takes the absolute value,
 * multiplies, shifts and conditionally negates -- eight instructions an operand -- where
 * the table takes two (an index scale and a load).
 *
 * But on pint_add_table's LEFT-SHIFT arm (sh <= 0, which is where every one of the 444
 * scale triples this graph ships lands, sh in [-5, 0], counted by b66_add_gate.c section 0)
 * the entry is
 *
 *     t[v] = v * (k.q << l)        exactly, for every v in [-128, 127],
 *
 * with no rounding constant and no abs/negate: pint_add_table accumulates p = m * k.q by
 * repeated addition and writes t[m] = p << l and t[256-m] = -(p << l), which IS the signed
 * product.  Hoist `A = k.q << l` out of the loop and one SIGNED multiply replaces the
 * index scale, the address add and the load, for each operand -- and the two 2 KB tables,
 * their build and their L1D footprint go with them.
 *
 * MEASURED off the run's own dis.txt and on spike at the board's flags (b74_icount.sh):
 * the shipped element loop is 20 instructions for two loads, two table reads, an add, a
 * rounding shift, a tie test, a clip and a store; this one is 16 for the same answer.
 * The whole dispatch at the encoder's n = 47,520 is 959,158 instructions of which 3,980
 * are the build -- so the build was never the cost at this shape and B66's crossover is
 * not what re-opens here.  THE ELEMENT LOOP IS.
 *
 * BIT-IDENTITY, not a tolerance.  x is the same int64 as `ta[(uint8_t)a[i]] + tb[...]`
 * term for term, so `half`, `mask`, G, the half-integer tie test, the exact fall-back and
 * the clamp all behave exactly as they do on the table route; `ea`/`eb`/G are formed from
 * the m = 128 entry, which pint_add_table's own notes (c) and (d) prove decides them for
 * all 256.  The overflow test is pint_add_table's own, evaluated before A is formed, so
 * the shift is defined and the `goto slow_all` fires on exactly the same dispatches.
 * Outside the regime -- k.q = 0 or above 2^40 (which fx32_ratio cannot produce), or
 * sh > 0 -- the table route is taken unchanged rather than growing a second element loop.
 *
 * Ships behind -DMBP_B74=1 and is OFF by default, because add_s8 is shared with the
 * decoder and a default flip would change another workstream's control arm mid-run.
 */
#ifndef MBP_B74
#define MBP_B74 0
#endif
/* LIVE-PATH PROOF, not a feature.  A byte-for-byte gate is passed perfectly by a route
 * that never fires (B66 found its first guard testing the wrong branch while passing all
 * 6,462 comparisons), so b74_gate.sh builds one arm with this set and REQUIRES the gate to
 * FAIL.  It perturbs only the linear route's STORE, so a failure proves that route ran.
 * (An earlier poison, A += 1, was rejected by the gate for the right reason and the wrong
 * one: at F ~ 44 a unit change in the multiplier moves x by at most 128 and cannot survive
 * the >> F, so the arm was byte-identical while the route was demonstrably live -- an
 * instrumented build counts it firing once per dispatch.  A poison must be visible in the
 * OUTPUT, not merely in an intermediate.) */
#ifndef MBP_B74_POISON
#define MBP_B74_POISON 0
#endif

/*
 * B87 -- B74's OWN DECISION DID NOT SURVIVE INLINING, AND THE LOOP STILL CARRIES ITS
 * BOOKKEEPING.
 *
 * B74 gave pint_add_lin_mark its own function *because* holding both routes' live state
 * at once made the register allocator spill `mask`, `G - half` and `2G`, and recorded the
 * result as "16 instructions an element" against the table route's 20.  Counted off the
 * SHIPPED image (out/b86_attn_on2/enc_q16/dis.txt, kernel_add_s8_moonshine_enc, the loop
 * at 0x80006102) and on spike at the board's flags (b74_icount.sh: add_b74_E_x23760 =
 * 407,769, i.e. 17.163 an element), the shipped loop is SEVENTEEN, and the seventeenth is
 *
 *     8000610a:  ld  a0,32(sp)          <- F, reloaded from the stack every element
 *
 * -- exactly the spill the separate frame was supposed to prevent.  There is no separate
 * frame: GCC inlines pint_add_lin_mark into kernel_add_s8 at -O2, and no `pint_add_lin`
 * symbol exists in the shipped ELF at all.  The documented price and the measured one
 * differ by 6.9 % on the loop body, and the cause is that the mechanism B74 described was
 * never the mechanism that shipped.
 *
 * TWO CHANGES, both bookkeeping, neither arithmetic:
 *
 * (1) noinline, so the frame B74 designed is actually built and F stays in a register.
 * (2) FOUR ELEMENTS an iteration.  Three pointer updates and a branch serve one element
 *     in the shipped loop; a `lb`/`sb` displacement is free on this ISA, so four elements
 *     share them.  16 -> 12 for the body and 4 -> 1 for the bookkeeping: 13 an element.
 *
 * The marks are appended in element order, exactly as the one-at-a-time loop appends
 * them, and each fix-up writes a distinct element -- so the output is unchanged element
 * for element and `max_abs_err = 0` is the right instrument.
 *
 * Ships behind -DMBP_B87=1 and is OFF by default: add_s8 is shared with the decoder and a
 * default flip would change another workstream's control arm mid-run.
 */
#ifndef MBP_B87
#define MBP_B87 0
#endif
/* LIVE-PATH PROOF, not a feature.  4 perturbs the unrolled store, visibly in the OUTPUT.
 * (The values are disjoint across the three kernels B87 touches, because kernels.c
 * concatenates all three into ONE translation unit and they share this macro.) */
#ifndef MBP_B87_POISON
#define MBP_B87_POISON 0
#endif

/*
 * B103 -- THE GUARD BAND BELONGS IN THE ROUNDING CONSTANT, NOT IN THE TEST.
 *
 * The decomposition first, because it is what makes this worth doing and it is also what
 * makes it the LAST thing worth doing to this loop.  Retired instructions on spike at the
 * board's own flags (b103_icount.sh, control = the shipped -DMBP_B74=1 -DMBP_B87=1) against
 * the board's own cycles (out/b101_combined_0035_f40, 0x5A5A0035 at 40 MHz):
 *
 *     add_s8   637,042 instr / 47,520 el = 13.406 an element;  15.715 cyc/el;  CPI 1.1723
 *
 * THE LOOP IS INSTRUCTION-BOUND, and its twelve element instructions are: two lb, two mul,
 * an add, the rounding add, the shift, the mask, the band add, the branch, CLIP8, the store.
 * There is no packed route to take instead -- MBP is DOT8 (a reduction), MAX8 (byte maxima),
 * QMUL (one 32x32) and CLIP8 (one clamp); none of them is a per-lane multiply, which is what
 * `a*A + b*B` per byte needs.  So the only thing left to remove is bookkeeping, and there is
 * exactly ONE instruction of it left.
 *
 * THE BAND TEST AND THE ROUNDING SHIFT SHARE A CONSTANT.  The shipped body computes
 *
 *     v = (x + half) >> F                            and         (x & mask) + (G - half) <= 2G
 *
 * -- five instructions for what is one addition and one comparison.  Fold G into the
 * rounding constant once per dispatch, HG = half + G, and form q = x + HG:
 *
 *     v = q >> F                                     and         (q & mask) <= 2G
 *
 * -- four.  BOTH HALVES ARE IDENTITIES, not approximations:
 *
 *   THE TEST.  Let u = x & mask.  The shipped test is exactly u in [half - G, half + G]
 *   (below that the uint64 subtraction wraps past 2G; above it the sum exceeds 2G; and
 *   half + G < 2^F so no wrap at the top).  With q = x + HG, (q & mask) = u + G - half when
 *   u >= half - G and u + half + G otherwise, so `(q & mask) <= 2G` selects u <= half + G in
 *   the first case and nothing in the second (half + G > 2G because G < half/2 is already
 *   required before the loop is entered).  The SAME elements are marked, in the same order.
 *
 *   THE VALUE.  (s + G) >> F == s >> F exactly when (s & mask) + G < 2^F, and for every
 *   element the test does NOT mark, s = x + half has (s & mask) either u + half < 2^F - G
 *   (when u < half - G) or u - half (when u > half + G), both below 2^F - G.  So the fast
 *   value is bit-identical on every element that keeps it, and on the elements that do not
 *   the exact fall-back overwrites it, exactly as it does today.  Two's complement makes
 *   the carry argument sign-agnostic: `x & mask` is the low F bits whatever x's sign.
 *
 *   NO OVERFLOW.  The caller already refuses the route unless bitlen(128*ka.q) + la_ <= 61,
 *   so |x| < 2^62, and half < 2^54, G < half/2.
 *
 * WHAT IT IS WORTH.  One instruction of 13.406, on 570,240 elements an iteration.  That is
 * the honest size of it: this loop's floor is its instruction count and the count is nearly
 * all arithmetic the operator is defined by.
 *
 * OFF BY DEFAULT: add_s8 is shared with the decoder and a default flip would move another
 * workstream's control arm under it.  -DMBP_B103=1 selects it; it requires MBP_B87.
 */
#ifndef MBP_B103
#define MBP_B103 0
#endif
#if MBP_B103 && !(MBP_B74 && MBP_B87)
#error "MBP_B103 restructures the B87 element loop and requires MBP_B74=1 MBP_B87=1"
#endif
/* LIVE-PATH PROOF, not a feature.  7 perturbs the B103 store, visibly in the OUTPUT, so a
 * byte-for-byte gate that passes with it set would prove the route never ran.  (Disjoint
 * from the values the other kernels in this translation unit use.) */
#ifndef MBP_B103_POISON
#define MBP_B103_POISON 0
#endif

#if MBP_B74 && !defined(MBP_ADD_NO_FAST)
/*
 * Its OWN function, and that is a measured decision, not a style one.  Written inline in
 * kernel_add_s8 the same loop measured 20.19 instructions an element -- no better than the
 * table it replaces -- because the register allocator, holding both routes' live state at
 * once, spilled `mask`, `G - half` and `2G` and reloaded all three from the stack every
 * element, giving back exactly the four instructions the multiplies had saved.  Given its
 * own frame it keeps them in registers.  (b74_icount.sh prints both.)
 */
/* The marking pass alone.  sa/sb/so and the fix-up live in the caller, so this frame
 * holds only what the fast path reads and nothing spills: measured 18 instructions an
 * element when the fix-up shared the frame, 16 when it did not. */
struct pint_add_c {
	int64_t A, B;
	uint64_t half, mask, Gmh, G2;
#if MBP_B103
	uint64_t HG;                  /* half + G -- B103's folded rounding constant */
#endif
	int F;
};

#if MBP_B87
/* B87 (1): the frame B74 designed, actually built.  Inlined, this loop reloads F from the
 * stack on every element -- see the note above. */
__attribute__((noinline))
#endif
static int pint_add_lin_mark(const int8_t *pa, const int8_t *pb, int8_t *po, int lim,
			     const struct pint_add_c *c, uint8_t *mk)
{
	/* Twelve arguments put four of them past a0-a7, and `F` stayed in its stack slot
	 * and was reloaded every element.  Six arguments, read once into locals here. */
	const int64_t A = c->A, B = c->B;
	const uint64_t half = c->half, mask = c->mask, Gmh = c->Gmh, G2 = c->G2;
#if MBP_B103
	/* B103: half + G, folded once per dispatch.  `half` and `Gmh` stay referenced by the
	 * tail loop below and by the non-B87 body, so nothing is orphaned. */
	const int64_t HG = (int64_t)c->HG;
#endif
	const int F = c->F;
	const int8_t *const pa0 = pa, *const paE = pa + lim;
	int nm = 0;

#if MBP_B87
	/* B87 (2): four elements an iteration.  Same products, same tie tests, same marks
	 * in the same order. */
	{
		const int8_t *const paU = pa + (lim & ~3);

		while (pa < paU) {
#if MBP_B103
			/* B103: q = x + half + G.  `q >> F` is the shipped rounding shift on
			 * every element the test does not mark, and `(q & mask) <= 2G` marks
			 * exactly the elements `(x & mask) + (G - half) <= 2G` marks. */
			const int64_t q0 = (int64_t)pa[0] * A + (int64_t)pb[0] * B + HG;
			const int64_t q1 = (int64_t)pa[1] * A + (int64_t)pb[1] * B + HG;
			const int64_t q2 = (int64_t)pa[2] * A + (int64_t)pb[2] * B + HG;
			const int64_t q3 = (int64_t)pa[3] * A + (int64_t)pb[3] * B + HG;
#if MBP_B103_POISON == 7
			const int8_t pz = 1;
#elif MBP_B87_POISON == 4
			const int8_t pz = 1;
#else
			const int8_t pz = 0;
#endif

			po[0] = (int8_t)(mb_pext_clip8(q0 >> F) ^ pz);
			po[1] = (int8_t)(mb_pext_clip8(q1 >> F) ^ pz);
			po[2] = (int8_t)(mb_pext_clip8(q2 >> F) ^ pz);
			po[3] = (int8_t)(mb_pext_clip8(q3 >> F) ^ pz);
			if (__builtin_expect(((uint64_t)q0 & mask) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0);
			}
			if (__builtin_expect(((uint64_t)q1 & mask) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0 + 1);
			}
			if (__builtin_expect(((uint64_t)q2 & mask) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0 + 2);
			}
			if (__builtin_expect(((uint64_t)q3 & mask) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0 + 3);
			}
#else
			const int64_t x0 = (int64_t)pa[0] * A + (int64_t)pb[0] * B;
			const int64_t x1 = (int64_t)pa[1] * A + (int64_t)pb[1] * B;
			const int64_t x2 = (int64_t)pa[2] * A + (int64_t)pb[2] * B;
			const int64_t x3 = (int64_t)pa[3] * A + (int64_t)pb[3] * B;
#if MBP_B87_POISON == 4
			const int8_t pz = 1;
#else
			const int8_t pz = 0;
#endif

			po[0] = (int8_t)(mb_pext_clip8((x0 + (int64_t)half) >> F) ^ pz);
			po[1] = (int8_t)(mb_pext_clip8((x1 + (int64_t)half) >> F) ^ pz);
			po[2] = (int8_t)(mb_pext_clip8((x2 + (int64_t)half) >> F) ^ pz);
			po[3] = (int8_t)(mb_pext_clip8((x3 + (int64_t)half) >> F) ^ pz);
			if (__builtin_expect((((uint64_t)x0 & mask) + Gmh) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0);
			}
			if (__builtin_expect((((uint64_t)x1 & mask) + Gmh) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0 + 1);
			}
			if (__builtin_expect((((uint64_t)x2 & mask) + Gmh) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0 + 2);
			}
			if (__builtin_expect((((uint64_t)x3 & mask) + Gmh) <= G2, 0)) {
				mk[nm++] = (uint8_t)(pa - pa0 + 3);
			}
#endif
			pa += 4;
			pb += 4;
			po += 4;
		}
	}
	for (; pa < paE; pa++, pb++, po++) {
		const int64_t x = (int64_t)*pa * A + (int64_t)*pb * B;

		*po = (int8_t)mb_pext_clip8((x + (int64_t)half) >> F);
		if (__builtin_expect((((uint64_t)x & mask) + Gmh) <= G2, 0)) {
			mk[nm++] = (uint8_t)(pa - pa0);
		}
	}
	return nm;
#else
	do {
		const int64_t x = (int64_t)*pa * A + (int64_t)*pb * B;

#if MBP_B74_POISON == 1
		*po = (int8_t)(mb_pext_clip8((x + (int64_t)half) >> F) ^ 1);
#else
		*po = (int8_t)mb_pext_clip8((x + (int64_t)half) >> F);
#endif
		if (__builtin_expect((((uint64_t)x & mask) + Gmh) <= G2, 0)) {
			mk[nm++] = (uint8_t)(pa - pa0);
		}
		pa++;
		pb++;
		po++;
	} while (pa < paE);
	return nm;
#endif
}

static void pint_add_lin(const int8_t *a, const int8_t *b, int8_t *output, int n,
			 int64_t A, int64_t B, uint64_t half, uint64_t mask, uint64_t G,
			 int F, fx32_t sa, fx32_t sb, fx32_t so)
{
	struct pint_add_c c;
	int i0;

	c.A = A;
	c.B = B;
	c.half = half;
	c.mask = mask;
	c.Gmh = G - half;
	c.G2 = 2 * G;
#if MBP_B103
	c.HG = half + G;
#endif
	c.F = F;

	for (i0 = 0; i0 < n; i0 += 256) {
		const int lim = (n - i0) < 256 ? (n - i0) : 256;
		const int8_t *pa = a + i0, *pb = b + i0;
		int8_t *po = output + i0;
		uint8_t mk[256];
		int nm, j;

		nm = pint_add_lin_mark(pa, pb, po, lim, &c, mk);
		for (j = 0; j < nm; j++) {
			const int q = mk[j];

			po[q] = (int8_t)mb_pext_clip8(pint_add_exact(pa[q], pb[q], sa, sb, so));
		}
	}
}
#endif

void kernel_add_s8(const int8_t *a, const int8_t *b, int8_t *output, int n,
		   float scale_a, float scale_b, float scale_out,
		   int activation_min, int activation_max)
{
	const fx32_t sa = fx32_dec(scale_a), sb = fx32_dec(scale_b), so = fx32_dec(scale_out);
	/* static, not stack-local: 4 KB against the harness's 8 KB worker stack.  Safe because
	 * pext_nl kernels run on hart 0 only (MBP traps on hart 1), so no second caller. */
	static int64_t ta[256], tb[256];
	fx32_k_t ka, kb;
	int F, la, lb, lo, ok = 1, i;
	uint64_t G, half, mask, ea = 0, eb = 0;

	PINT_ADD_N(n);
	if (!(fx32_scale_ok(sa) && fx32_scale_ok(sb) && fx32_scale_ok(so))) {
		goto slow_all;
	}
	/* F so that 128 * max(sa, sb)/so * 2^F ~ 2^52: headroom for the sum and the round. */
	la = fx32_bitlen64(sa.m) + sa.e;
	lb = fx32_bitlen64(sb.m) + sb.e;
	lo = fx32_bitlen64(so.m) + so.e;
	F = 44 - ((la > lb ? la : lb) - lo);
	if (F < 16 || F > 55) {
		goto slow_all;
	}
	ka = fx32_ratio(sa, so);
	kb = fx32_ratio(sb, so);
#if MBP_B74 && !defined(MBP_ADD_NO_FAST)
	/* THE LINEAR-MAP ROUTE.  No n guard: it is cheaper than the table at every n. */
	if (ka.q != 0 && kb.q != 0 &&
	    ka.q <= ((uint64_t)1 << 40) && kb.q <= ((uint64_t)1 << 40)) {
		const int la_ = ka.e + F, lb_ = kb.e + F;   /* == -sh for each table */

		if (la_ >= 0 && lb_ >= 0 && la_ <= 16 && lb_ <= 16) {
			const uint64_t ha = (uint64_t)128 * ka.q, hb = (uint64_t)128 * kb.q;
			int64_t A, B, a128, b128;

			/* pint_add_table's own *ok test, from the m = 128 entry alone (note
			 * (c)) -- and it is what bounds la_ so the shifts below are defined. */
			if (fx32_bitlen64(ha) + la_ > 61 || fx32_bitlen64(hb) + lb_ > 61) {
				goto slow_all;
			}
			A = (int64_t)(ka.q << la_);
			B = (int64_t)(kb.q << lb_);
			a128 = 128 * A;                 /* == -ta[0x80] */
			b128 = 128 * B;                 /* == -tb[0x80] */
			ea = (uint64_t)a128 >> 38;
			eb = (uint64_t)b128 >> 38;
			G = (((uint64_t)a128 + (uint64_t)b128) >> 22) + ea + eb + 4;
			half = (uint64_t)1 << (F - 1);
			mask = ((uint64_t)1 << F) - 1;
			if (G >= half / 2) {
				goto slow_all;
			}
			if (activation_min == -128 && activation_max == 127) {
				pint_add_lin(a, b, output, n, A, B, half, mask, G, F,
					     sa, sb, so);
			} else {
				for (i = 0; i < n; i++) {
					const int64_t x = (int64_t)a[i] * A + (int64_t)b[i] * B;
					int64_t v;

					if ((((uint64_t)x & mask) - half + G) <= 2 * G) {
						v = pint_add_exact(a[i], b[i], sa, sb, so);
					} else {
						v = (x + (int64_t)half) >> F;
					}
					if (v < activation_min) v = activation_min;
					if (v > activation_max) v = activation_max;
					output[i] = (int8_t)v;
				}
			}
			(void)ok;
			return;
		}
	}
#endif
#ifndef MBP_ADD_NO_FAST
	/* THE GUARD IS ON n.  Everything below reproduces the table route's own decisions --
	 * the *ok test, ea/eb, G -- from the m = 128 entry alone, because p = m * k.q is
	 * monotone in m (pint_add_table's note (c) and (d)), so they cost O(1) rather than a
	 * build. */
	if (n < MBP_ADD_MINN && ka.q != 0 && kb.q != 0 &&
	    ka.q <= ((uint64_t)1 << 40) && kb.q <= ((uint64_t)1 << 40)) {
		const int la_ = ka.e + F, lb_ = kb.e + F;   /* == -sh for each table */

		if (la_ >= 0 && lb_ >= 0 && la_ <= 16 && lb_ <= 16) {
			const uint64_t ha = (uint64_t)128 * ka.q, hb = (uint64_t)128 * kb.q;
			int64_t a128, b128;

			/* pint_add_table's own *ok test, from the m = 128 entry alone: p is
			 * monotone in m, so that entry decides it for all 256 (note (c)). */
			if (fx32_bitlen64(ha) + la_ > 61 || fx32_bitlen64(hb) + lb_ > 61) {
				goto slow_all;
			}
			a128 = -pint_add_t1(-128, ka.q, la_);
			b128 = -pint_add_t1(-128, kb.q, lb_);
			ea = (uint64_t)a128 >> 38;
			eb = (uint64_t)b128 >> 38;
			G = (((uint64_t)a128 + (uint64_t)b128) >> 22) + ea + eb + 4;
			half = (uint64_t)1 << (F - 1);
			mask = ((uint64_t)1 << F) - 1;
			if (G >= half / 2) {
				goto slow_all;
			}
			for (i = 0; i < n; i++) {
				const int64_t x = pint_add_t1(a[i], ka.q, la_) +
						  pint_add_t1(b[i], kb.q, lb_);
				int64_t v;

				if (__builtin_expect((((uint64_t)x & mask) - half + G)
						     <= 2 * G, 0)) {
					v = pint_add_exact(a[i], b[i], sa, sb, so);
				} else {
					v = (x + (int64_t)half) >> F;
				}
				if (v < activation_min) v = activation_min;
				if (v > activation_max) v = activation_max;
				output[i] = (int8_t)v;
			}
			(void)ok;
			return;
		}
	}
#endif
#ifdef MBP_ADD_NO_FAST
	for (i = 0; i < 256; i++) {
		int v = (int8_t)(uint8_t)i;
		int64_t t;

		t = fx32_apply((uint64_t)(v < 0 ? -v : v), 0, v < 0, ka, F, &ok);
		if (!ok) {
			goto slow_all;
		}
		ta[i] = t;
		if ((uint64_t)(t < 0 ? -t : t) >> 38 > ea) {
			ea = (uint64_t)(t < 0 ? -t : t) >> 38;
		}
		t = fx32_apply((uint64_t)(v < 0 ? -v : v), 0, v < 0, kb, F, &ok);
		if (!ok) {
			goto slow_all;
		}
		tb[i] = t;
		if ((uint64_t)(t < 0 ? -t : t) >> 38 > eb) {
			eb = (uint64_t)(t < 0 ? -t : t) >> 38;
		}
	}
	(void)ok;
#else
	if (!pint_add_table(ta, ka, F, &ea) || !pint_add_table(tb, kb, F, &eb)) {
		goto slow_all;
	}
	(void)ok;
#endif
	/* (i) 4 * 2^-24 * U_max, U_max * 2^F = |ta[-128]| + |tb[-128]|;  (ii) the tables. */
	G = (((uint64_t)(-ta[0x80]) + (uint64_t)(-tb[0x80])) >> 22) + ea + eb + 4;
	half = (uint64_t)1 << (F - 1);
	mask = ((uint64_t)1 << F) - 1;
	if (G >= half / 2) {
		goto slow_all;
	}

	if (activation_min == -128 && activation_max == 127) {
#ifndef MBP_ADD_NO_FAST
		/*
		 * B63 -- THE ELEMENT LOOP.  The control's body is 34 instructions on the fast
		 * path for two loads, an add, a shift, a clip and a store, and eleven of them
		 * exist only because the exact fallback is INSIDE the loop: two auipc/addi pairs
		 * rematerialising ta and tb every element (medany has no cheap static base), two
		 * spill reloads and three register moves staging pint_add_exact's six arguments
		 * UNCONDITIONALLY, and a slliw/sraiw sign-extension of a value the next
		 * instruction stores as a byte.
		 *
		 * So: write the fast value for every element, record the few that land in the
		 * tie band, and fix those up after the block.  The fast value is overwritten
		 * where it was not the answer, so the result is unchanged element for element;
		 * this is a pure restructuring, not a different rule.  One block of 256 keeps
		 * the mark list at 256 bytes of stack and the fixed-up store hot in L1.
		 */
		int i0;

		for (i0 = 0; i0 < n; i0 += 256) {
			const int lim = (n - i0) < 256 ? (n - i0) : 256;
			const int8_t *pa = a + i0, *pb = b + i0;
			int8_t *po = output + i0;
			uint8_t mk[256];
			int nm = 0, j;

			const int8_t *const pa0 = pa, *const paE = pa + lim;
			const int8_t *qa = pa, *qb = pb;
			int8_t *qo = po;

			/* running pointers, not base + i: an index would cost three adds an
			 * element to re-form the same three addresses. */
			for (; qa < paE; qa++, qb++, qo++) {
				int64_t x = ta[(uint8_t)*qa] + tb[(uint8_t)*qb];

				*qo = (int8_t)mb_pext_clip8((x + (int64_t)half) >> F);
				if (__builtin_expect((((uint64_t)x & mask) - half + G) <= 2 * G, 0)) {
					mk[nm++] = (uint8_t)(qa - pa0);
				}
			}
			for (j = 0; j < nm; j++) {
				const int q = mk[j];

				po[q] = (int8_t)mb_pext_clip8(pint_add_exact(pa[q], pb[q], sa, sb, so));
			}
		}
#else
		for (i = 0; i < n; i++) {
			int64_t x = ta[(uint8_t)a[i]] + tb[(uint8_t)b[i]];

			if ((((uint64_t)x & mask) - half + G) <= 2 * G) {
				output[i] = (int8_t)mb_pext_clip8(pint_add_exact(a[i], b[i], sa, sb, so));
			} else {
				output[i] = (int8_t)mb_pext_clip8((x + (int64_t)half) >> F);
			}
		}
#endif
	} else {
		for (i = 0; i < n; i++) {
			int64_t x = ta[(uint8_t)a[i]] + tb[(uint8_t)b[i]];
			int64_t v;

			if ((((uint64_t)x & mask) - half + G) <= 2 * G) {
				v = pint_add_exact(a[i], b[i], sa, sb, so);
			} else {
				v = (x + (int64_t)half) >> F;
			}
			if (v < activation_min) v = activation_min;
			if (v > activation_max) v = activation_max;
			output[i] = (int8_t)v;
		}
	}
	return;

slow_all:
	for (i = 0; i < n; i++) {
		int32_t v = pint_add_exact(a[i], b[i], sa, sb, so);

		if (v < activation_min) v = activation_min;
		if (v > activation_max) v = activation_max;
		output[i] = (int8_t)v;
	}
}
