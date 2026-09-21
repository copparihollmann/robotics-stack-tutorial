/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_rsqrt */
/* accuracy_class: numeric_drift */
/* origin: fpga/pynq-z2/sw/int_nonlin.c, measured by Lab B20 */
/*
 * layernorm_s8 with no floating-point arithmetic.  The reference is `double` with a
 * `sqrt`, three passes per row, and it measured 1,152 cycles per element on this core.
 * This is one integer divide and one integer reciprocal square root per ROW, and a
 * multiply-shift per element.
 *
 * MEASURED RATES, EACH WITH THE ARGUMENTS IT WAS MEASURED WITH -- because this kernel's
 * previous header carried one number that was true and unrepresentative, and it cost 2.26x:
 *
 *   69 c/el   K = 512, M = 64,  gamma = NULL, beta = NULL   Lab B20, 0x5A5A0010
 *   136.48    K = 288, M = 165, gamma and beta NON-NULL     Lab B26, in-model, steady
 *   137.03    K = 288, M = 165, gamma and beta NON-NULL     Lab B28, QATU, in-model, steady
 *   160.80    K = 288, M = 165, gamma and beta NON-NULL     Lab B31, standalone bench
 *
 * The 69 was honest, on real silicon, and taken with `gamma = NULL, beta = NULL`
 * (samples/int_nonlin_bench/src/main.c:296), which takes both affine branches below and
 * SKIPS THE PER-ELEMENT DECODE ENTIRELY.  With real gamma and beta the decode dominates.
 * A rate here without its affine arguments is not a rate.  See docs/EXPERIMENT_LOG_RULES.md,
 * "A benchmark inherits the coverage of its arguments".
 *
 * THE ALGEBRA THAT MAKES scale_in DISAPPEAR.  The reference normalises in REAL units:
 * mu and var are computed on x*scale_in.  But normalisation divides by its own standard
 * deviation, so scale_in cancels everywhere except inside eps:
 *
 *     (x*s - mu) / sqrt(var + eps)  ==  (x - mu_q) / sqrt(var_q + eps/s^2)
 *
 * with mu_q and var_q the mean and variance of the raw int8 codes.  So the whole row
 * pass is integer and eps enters as one added constant, eps/scale_in^2, computed from
 * the two floats' IEEE-754 bit patterns with one integer divide.  Dropping eps entirely
 * would be the tempting simplification and it is wrong for a near-constant row, where
 * var_q is small and eps/s^2 is not.
 *
 * THE EXPONENT SIGN IS THE TRAP.  int_rsqrt_q31 returns a Q0.31 mantissa and a separate
 * binary exponent, and that exponent DIVIDES: v is large, so 1/sqrt(v) is small.  The
 * first version of int_layernorm_s8 applied it with the wrong sign, which produces an
 * output that scales WITH the variance instead of against it -- and still looks like a
 * normalised tensor to every range check.
 *
 * gamma and beta stay float32 in the SIGNATURE, because that is the reference's
 * contract, but no float instruction executes: each is decoded from its bits into a
 * (mantissa, exponent, sign) triple and folded with 1/scale_out by integer multiply.
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif

/*
 * B76 -- B66 KILLED ONE 128-BIT PRODUCT IN THIS KERNEL AND LEFT TWO STANDING PER ELEMENT.
 *
 * The note above LN_XN proves the `__int128` in the normalise step was dead by construction
 * and replaces it with a `mul` and an `sra`.  The SAME argument reaches `nl_scale`, which
 * this kernel calls TWICE on every element of the decoder's shape -- and which B66 did not
 * look at because it was asking about the hoist, not about the arithmetic.  Counted off the
 * shipping image (out/b73_dec_ship/dec_q16/dis.txt, <kernel_layernorm_s8_moonshine_dec>),
 * one `nl_scale((int64_t)1 << 8, bm, bs)` is
 *
 *     slli / add / sltu / slli / srli / or / beqz / addiw / addiw / bltz / sll / li /
 *     add / sltu / addiw / add / bltz / sra
 *
 * -- eighteen instructions and two taken-or-not branches to emulate a 128-bit add, shift
 * and variable right shift, on a product GCC has ALREADY strength-reduced to `bm << 8`.
 * The gamma site, `nl_scale(xn, gm, gs + 8)`, carries a real `mul`/`mulh` pair on top.
 *
 * THE BOUNDS, and they are bounds rather than measurements:
 *
 *   beta site   a is the literal 256, so |a| < 2^31 needs nothing checked at all.
 *   gamma site  a is xn = 2^16 * (x[k] - mu_q) / sqrt(var_q + eps/s^2).  The row's own
 *               variance bounds it: var_q >= (x[k] - mu_q)^2 / K for every k, so
 *               |xn| <= 2^16 * sqrt(K), which at MBP_LN_MAXK = 1024 is 2^21.
 *
 * That is ten binary orders of headroom, and it is still CHECKED rather than asserted:
 * ln_scale falls back to nl_scale itself whenever |a| >= 2^31 or the shift is out of range,
 * so the fast path is bit-identical to nl_scale on its whole domain BY CONSTRUCTION -- the
 * fallback IS nl_scale -- and no bound has to hold for the kernel to be right.
 *
 * SECOND: nl_q8_to_s8 clamps to [amin, amax] and then AGAIN to [-128, 127].  Every
 * layernorm_s8 dispatch in both halves of this graph has amin = -128, amax = 127, where the
 * whole tail is one mb_pext_clip8.  `full` is decided once per dispatch, as rope_s8 already
 * does with the same test, so neither arm carries the other's branch.
 *
 * -DMBP_B76=1 selects both.  At 0 this file is the shipped kernel.
 */
#ifndef MBP_B76
#define MBP_B76 0
#endif
/* LIVE-PATH PROOF.  Each value perturbs one new route visibly in the OUTPUT:
 *   6  ln_scale's int64 arm (and not the nl_scale fallback beside it)
 *   7  the mb_pext_clip8 output tail */
#ifndef MBP_B76_POISON
#define MBP_B76_POISON 0
#endif

#if MBP_B76
#include "pext.h"

/* nl_scale with the 128-bit intermediate removed where the operand cannot need it, and
 * nl_scale itself everywhere else.  Not an approximation and not a relaxation: the two
 * arms compute the same expression and the guard decides which spelling evaluates it. */
static inline int64_t ln_scale(int64_t a, int32_t mult, int s)
{
	uint64_t ua = (uint64_t)(a < 0 ? -a : a);
	int64_t p;

	if (s < 0) {
		if (s < -20 || (ua >> 31) != 0) {
			return nl_scale(a, mult, s);
		}
		a <<= -s;
		ua <<= -s;
		s = 0;
	}
	if ((ua >> 31) != 0 || s > 40) {
		return nl_scale(a, mult, s);
	}
	p = (a * (int64_t)mult + ((int64_t)1 << 30)) >> 31;
	if (s > 0) {
		p = (p + ((int64_t)1 << (s - 1))) >> s;
	}
#if MBP_B76_POISON == 6
	p += p >> 3;
#endif
	return p;
}

/* nl_q8_to_s8 with amin = -128, amax = 127 folded into one instruction.
 *
 * THE int32_t CAST IS LOAD-BEARING and the gate is what said so.  nl_q8_to_s8 rounds in
 * int64 and then TRUNCATES to int32 before clamping, so a v_q8 above 2^39 wraps and can
 * clamp to the opposite rail.  No scale this graph ships gets near it, and the first
 * version of this helper kept the value in int64 and was therefore MORE correct and NOT
 * THE SAME -- 29 of b66_ln_gate's random-scale cases caught it, all at scale_out ~ 1e-6.
 * Reproducing the wrap is the point: this arm must be the shipping kernel's answer, not a
 * better one.  Fixing the wrap is an accuracy-contract change and not this lab's. */
static inline int8_t ln_q8_full(int64_t v_q8)
{
	int32_t v = (int32_t)(v_q8 >= 0 ? ((v_q8 + 128) >> 8) : -((-v_q8 + 128) >> 8));

#if MBP_B76_POISON == 7
	return (int8_t)(mb_pext_clip8(v) ^ 1);
#else
	return (int8_t)mb_pext_clip8(v);
#endif
}
#define LN_SCALE(a_, m_, s_)   ln_scale((a_), (m_), (s_))
#define LN_OUT(v_, amin_, amax_, full_) \
	((full_) ? ln_q8_full(v_) : nl_q8_to_s8((v_), (amin_), (amax_)))
#else
#define LN_SCALE(a_, m_, s_)   nl_scale((a_), (m_), (s_))
#define LN_OUT(v_, amin_, amax_, full_) \
	nl_q8_to_s8((v_), (amin_), (amax_))
#endif

/* Per-channel folded affine, hoisted out of the element loop.  gamma[k] and beta[k] decode to
 * a value that depends ONLY on k, and folding it with 1/scale_out likewise -- so as originally
 * written every channel's decode ran once per ROW.  At Moonshine's shape (M = 165, K = 288)
 * that is 47,520 decodes per dispatch where 288 suffice.
 *
 * `static`, not stack: these are 20 KB at the bound below and this family's kernels keep such
 * tables in .bss for exactly that reason (see pext_nl_add_s8_pext_int_add.c's `ta`/`tb`, and
 * pext_nl_rope_s8_pext_int_rot.c's note that per-position arrays live on an 8 KB stack).
 * K above the bound falls back to the original per-element path rather than overflowing --
 * the same shape as pext_nl_conv2d_s16_pc_pext_split_dot8.c's MBP_C16_MAXOC guard. */
#ifndef MBP_LN_MAXK
#define MBP_LN_MAXK 1024
#endif

/*
 * B66 -- TWO QUESTIONS WERE CONFLATED IN ONE TEST, AND ONLY THE FIRST WAS ASKED.
 *
 * MBP_LN_MAXK above is a CAPACITY bound: the four tables are 20 KB at K = 1024 and a
 * larger K would overflow .bss.  That test answers "does the table fit?".  It does not
 * answer "is the table worth building?", and until B66 nothing did.
 *
 * The hoist saves (M-1)*K decodes and costs K.  Its profitability is therefore a
 * question about M, not about K: it pays when (M-1)*K*d > K*d + K*(st+ld), i.e. when
 * M > 2 + (st+ld)/d -- with d the decode (two bit-field extracts, a 64x64 multiply and
 * a renormalise) and (st+ld) the four stores and four loads the table interposes.
 *
 * MEASURED (test/b66_icount.sh, retired instructions on spike at the board's flags,
 * K = 288 throughout, out/b66_guard_quantity/icount/b66_icount.txt):
 *
 *     M      fallback      hoist
 *     1        37,787     40,666      <- the hoist LOSES 7.08 %
 *     2        75,408     61,933
 *     165   6,209,035  3,529,858
 *
 * Fitting both lines gives break-even at M = 1.176, against B63's predicted 1.15.  The
 * smallest integer M that pays is 2, so MBP_LN_MINM is 2.  At M = 1 the hoist builds 288
 * entries, reads each exactly once, and is pure loss:
 * a per-element decode and a per-row decode are THE SAME 288 DECODES when there is one
 * row, and only the hoist also pays to store and reload them.
 *
 * WHY THIS WAS NOT NOTICED.  Every one of the encoder's 13 layernorm_s8 dispatches is
 * M = 165; every one of the decoder's 456 is M = 1 (verified in out/b63_dec_on/ir_cse).
 * The optimisation is correct where it was written and was never guarded against the
 * shape it would meet in the other half.  BOTH tests are kept: dropping the K test to
 * "fix" this would overflow the 20 KB buffer.
 *
 * NOT GENERALISABLE TO groupnorm_s8, and B63 said so before B66 measured it: a group
 * norm's affine is indexed by CHANNEL and shared by HW elements, so its hoist amortises
 * at every shape this model has.  One fix does not serve both kernels; the two kernels
 * are profitable in different quantities and are guarded on different quantities.
 */
#ifndef MBP_LN_B66
#define MBP_LN_B66 1
#endif
#ifndef MBP_LN_MINM
#define MBP_LN_MINM 2
#endif

/*
 * B66 -- THE 128-BIT PRODUCT IS DEAD BY CONSTRUCTION, and the bound is not a measurement.
 *
 *   |d8| = |x[k]*256 - mean| with |x[k]| <= 128 and mean = (sum(x) << 8)/K, so
 *   |mean| <= 128*256 and |d8| <= 2^16.  rs is a uint32 from int_rsqrt_q31, so
 *   |d8 * rs| <= 2^16 * 2^32 = 2^48 -- FIFTEEN BITS of headroom inside int64.
 *
 * The shift count is in range for the same reason: v is Q16 of a variance of int8 codes
 * plus eps, so v <= 128^2 * 2^16 = 2^30, e = 63 - clz(v) <= 30 and sh = e/2 <= 15, while
 * v >= 1 gives sh >= 0.  15 + sh is therefore in [15, 30].
 *
 * So the __int128 never carried a bit the int64 does not, and on rv64imac it cost a
 * mulh/mul pair with sign fix-ups and a VARIABLE 128-bit shift where one `mul` and one
 * `sra` suffice.  pext_nl_groupnorm_s8_pext_int_rsqrt.c already writes it in int64 at the
 * same shape; this makes the two agree.  The right shift of a negative value is
 * implementation-defined (arithmetic in GCC) in both spellings, as it was before.
 */
#if MBP_LN_B66
#define LN_XN(d8_, rs_, sh_) \
	(((int64_t)(d8_) * (int64_t)(uint64_t)(rs_)) >> (15 + (sh_)))
#else
#define LN_XN(d8_, rs_, sh_) \
	((int64_t)(((__int128)(d8_) * (rs_)) >> (15 + (sh_))))
#endif

/*
 * B87LN -- THE DECODE DOES NOT BELONG TO THE DISPATCH.
 *
 * B66 asked "is the table worth BUILDING for this dispatch?", answered no at M = 1 with
 * measurements, and set MBP_LN_MINM = 2 on that answer.  Re-measured at the flags the
 * decoder actually ships (-DMBP_B76=1, which POSTDATES B66's published numbers -- its
 * 37,787 is 33 % high for the shipped build, caught because the implied CPI of 0.853 is
 * impossible on a single-issue in-order hart), the answer is unchanged: at M = 1, K = 288
 * forcing the hoist on costs +16.3 %, 28,349 -> 32,957 retired instructions.  B66 is right.
 *
 * THE UNASKED QUESTION IS WHETHER THE DECODE IS PER DISPATCH AT ALL.  The table is a pure
 * function of (gamma, beta, scale_out, K) -- and gamma and beta are WEIGHTS.  The decoder
 * issues 456 layernorm_s8 dispatches over 6 layers x 2 sites = 12 distinct weight pairs.
 * Every one of the 38 dispatches per site rebuilds the same 288 entries.
 *
 * A CACHE IS THE FOURTH PRICING CATEGORY -- it changes WHEN work happens, not what
 * executes -- so this campaign's cycles-per-removed-instruction rule is inapplicable to it
 * by construction, and its size is measured from the implementation rather than fitted.
 * (The two-point fit this lab first tried does not even hold: the shipped arm's I(M) is
 * +11.0 % off an affine model at M = 4 because its per-element decode carries
 * data-dependent branches.  A two-point fit on a line that is not straight is not a
 * measurement, and the build/row split it produced was withdrawn.)
 *
 * THE WORKING SET IS THE WHOLE POINT.  All 12 sites are touched once per decode step, so
 * the reuse distance is 12 and a one-entry cache would hit ZERO times.  The cache must
 * hold every site or it holds none usefully.  That is why the entry is packed to 12 bytes
 * -- gm int32, b8 int32, gs int16, gneg int8 -- giving 12 x 288 x 12 = 41.5 KB against a
 * 64 KiB L2, rather than the 69 KB the unpacked (int32,int,int,int64) layout would need.
 * The narrowing is CHECKED, not assumed: a site whose gs or b8 does not fit is marked
 * uncacheable and takes the shipped path unchanged.
 *
 * CARDINALITY -- the axis added to this campaign's instrument list tonight, after a
 * non-unique join key reported false disagreement on 1,840 ops.  A cache has the mirror
 * failure: a non-unique key reports false AGREEMENT, which is the direction that flatters,
 * and no arithmetic gate can see it because the arithmetic is right -- it is the question
 * that is wrong.
 *
 * THE FIRST VERSION OF THIS KEY WAS POINTER + FOUR CONTENT WITNESSES (gamma[0],
 * gamma[K-1], beta[0], beta[K-1]).  The gate rejected it.  Mutating gamma[K/2] under a
 * live pointer produced a FALSE HIT and a wrong output byte -- and I had written that case
 * into the gate as "a known, recorded limit", which is the wrong answer to a correctness
 * hazard.  A witness key is blind to a structured region (the interior); it is not a
 * content key and calling it one in a comment does not make it one.
 *
 * The key is now a 64-bit MULTIPLY-ACCUMULATE HASH over BOTH arrays, read 8 bytes at a
 * time: 2 * K/2 = 288 words at K = 288, about 900 instructions against a cached dispatch
 * of ~14,300.  That is 6 % of the saving spent to remove a structured blind spot, and it
 * is honestly a PROBABILISTIC content key rather than a proof -- a 2^-64 collision instead
 * of a guaranteed miss on any interior change.  The distinction is worth stating: what
 * changed is not "now it is safe" but "the blind spot is no longer a region of the input,
 * it is a measure-zero set".
 *
 * Ships behind -DMBP_B87LN=1 and is OFF by default: layernorm_s8 is built into both
 * halves' images and a default flip would move another workstream's control arm.
 */
#ifndef MBP_B87LN
#define MBP_B87LN 0
#endif
#ifndef MBP_B87LN_SITES
#define MBP_B87LN_SITES 12
#endif
#ifndef MBP_B87LN_K
#define MBP_B87LN_K 288
#endif
/* LIVE-PATH PROOF.  8 perturbs the cached read visibly in the OUTPUT; a cache that never
 * hits is byte-perfect and worth nothing, so the gate also counts hits. */
#ifndef MBP_B87LN_POISON
#define MBP_B87LN_POISON 0
#endif

#if MBP_B87LN
struct ln_cent {
	int32_t gm;
	int32_t b8;
	int16_t gs;
	int8_t  gneg;
	int8_t  pad_;
};

struct ln_ckey {
	const float *g, *b;
	uint32_t so;                  /* scale_out's own bit pattern, not its value */
	int K;
	uint64_t h;                   /* content hash over gamma[0..K) and beta[0..K) */
	int live;
};

static struct ln_cent ln_cc[MBP_B87LN_SITES][MBP_B87LN_K];
static struct ln_ckey ln_ck[MBP_B87LN_SITES];
static int ln_ck_rr;
unsigned long ln_cache_hits, ln_cache_misses;   /* the gate reads these */

static inline uint32_t ln_fbits(float f)
{
	uint32_t b;

	__builtin_memcpy(&b, &f, sizeof(b));
	return b;
}

/* 8 bytes at a time over an array of K floats.  Not a cryptographic hash and not claimed
 * to be one: a multiply-accumulate over the raw bit patterns, so any change to any element
 * changes the digest except on a 2^-64 collision. */
typedef const uint64_t ln_u64a __attribute__((may_alias, aligned(4)));
static uint64_t ln_hash2(const float *g, const float *b, int K, uint64_t h)
{
	int i;

	for (i = 0; i + 1 < K; i += 2) {
		h = h * 0x100000001B3ull + (uint64_t)ln_fbits(g[i]);
		h = h * 0x100000001B3ull + (uint64_t)ln_fbits(g[i + 1]);
	}
	if (i < K) {
		h = h * 0x100000001B3ull + (uint64_t)ln_fbits(g[i]);
	}
	for (i = 0; i + 1 < K; i += 2) {
		h = h * 0x100000001B3ull + (uint64_t)ln_fbits(b[i]);
		h = h * 0x100000001B3ull + (uint64_t)ln_fbits(b[i + 1]);
	}
	if (i < K) {
		h = h * 0x100000001B3ull + (uint64_t)ln_fbits(b[i]);
	}
	return h;
}

/* -1 when the dispatch cannot use the cache at all. */
static int ln_cache_find(const float *g, const float *b, float so, int K, uint64_t *ph)
{
	uint64_t h;
	int i;

	if (K > MBP_B87LN_K || g == 0 || b == 0) {
		return -1;
	}
	h = ln_hash2(g, b, K, 0xCBF29CE484222325ull ^ (uint64_t)ln_fbits(so));
	*ph = h;
	for (i = 0; i < MBP_B87LN_SITES; i++) {
		const struct ln_ckey *c = &ln_ck[i];

		if (c->live && c->g == g && c->b == b && c->K == K &&
		    c->so == ln_fbits(so) && c->h == h) {
			ln_cache_hits++;
			return i;
		}
	}
	ln_cache_misses++;
	return -2;                    /* -2: no entry yet, but the dispatch may fill one */
}
#endif /* MBP_B87LN */

static int32_t ln_pc_gm[MBP_LN_MAXK];
static int     ln_pc_gs[MBP_LN_MAXK];
static int     ln_pc_gneg[MBP_LN_MAXK];
static int64_t ln_pc_b8[MBP_LN_MAXK];

/* |f| == mult * 2^-31 * 2^-shift, plus the sign.  Bit-field extract, not a conversion. */
static void nlk_f2mss(float f, int32_t *m, int *s, int *neg)
{
    uint32_t b, ab;
    float af;

    __builtin_memcpy(&b, &f, sizeof(b));
    *neg = (int)((b >> 31) & 1u);
    ab = b & 0x7fffffffu;
    __builtin_memcpy(&af, &ab, sizeof(af));
    nl_f2ms(af, m, s);
}

/* (m1,s1) * (m2,s2), renormalised so the product mantissa stays in [2^30, 2^31). */
static void nlk_msmul(int32_t m1, int s1, int32_t m2, int s2, int32_t *m, int *s)
{
    uint64_t p = ((uint64_t)(uint32_t)m1 * (uint32_t)m2) >> 31;
    int sh = s1 + s2;

    if (p != 0 && p < 0x40000000ull) { p <<= 1; sh += 1; }
    *m = (int32_t)p;
    *s = sh;
}

void kernel_layernorm_s8(const int8_t *input, const float *gamma,
                         const float *beta, int8_t *output,
                         int M, int K, float scale_in, float scale_out,
                         float eps, int activation_min, int activation_max) {
    int32_t mi, me, om;
    int si, se, om_s, dummy;
    int64_t eps_q16 = 0;
    int m, k;

    nl_f2ms_recip(scale_out, &om, &om_s);
    nl_f2ms(scale_in, &mi, &si);
    nlk_f2mss(eps, &me, &se, &dummy);

    /* eps / scale_in^2, in the same Q16 units the row variance below is computed in. */
    if (me != 0 && mi != 0) {
        uint64_t p = ((uint64_t)(uint32_t)mi * (uint32_t)mi) >> 31;   /* scale_in^2 */
        int sq = 2 * si;
        uint64_t r;
        if (p < 0x40000000ull) { p <<= 1; sq += 1; }
        r = (((uint64_t)(uint32_t)me) << 31) / p;                     /* me / p */
        if (r > 0x7fffffffull) r = 0x7fffffffull;
        eps_q16 = nl_scale((int64_t)1 << 16, (int32_t)r, se - sq);
        if (eps_q16 < 0) eps_q16 = 0;
    }

    /* The hoist.  `hoist` is decided once, outside every loop, so the fast path carries no
     * per-element branch and the fallback is the original code unchanged.
     *
     * TWO tests, because there are two questions: MBP_LN_MAXK asks whether the table FITS
     * (a capacity bound on K), MBP_LN_MINM asks whether it is worth BUILDING (a
     * profitability bound on M).  See the note above MBP_LN_B66. */
#if MBP_LN_B66
    const int hoist = (K <= MBP_LN_MAXK) && (M >= MBP_LN_MINM);
#else
    const int hoist = (K <= MBP_LN_MAXK);
#endif
#if MBP_B76
    /* B76: the output tail's clamp mode, decided once outside every loop.  Every
     * layernorm_s8 dispatch this graph ships is (-128, 127). */
    const int full = (activation_min <= -128) && (activation_max >= 127);
#else
    enum { full = 0 };
#endif

#if MBP_B87LN
    /* THE CACHE.  A miss builds into a round-robin slot; a hit skips the build entirely.
     * Both produce the same table the hoist path above would, term for term, so the
     * element loop below is the hoist element loop with its loads redirected. */
    {
        uint64_t chash = 0;
        int slot = ln_cache_find(gamma, beta, scale_out, K, &chash);

        if (slot == -2) {
            struct ln_cent *e = ln_cc[ln_ck_rr];
            int ok = 1;

            for (k = 0; k < K && ok; k++) {
                int32_t gm, bm;
                int gs, bs, gneg, bneg;
                int64_t b8 = 0;

                nlk_f2mss(gamma[k], &gm, &gs, &gneg);
                nlk_msmul(gm, gs, om, om_s, &gm, &gs);
                nlk_f2mss(beta[k], &bm, &bs, &bneg);
                nlk_msmul(bm, bs, om, om_s, &bm, &bs);
                b8 = LN_SCALE((int64_t)1 << 8, bm, bs);
                if (bneg) b8 = -b8;
                /* THE NARROWING IS CHECKED.  A site that does not fit the packed entry
                 * is not cached and takes the shipped path, rather than being stored
                 * lossily -- which would be a wrong answer, not a slow one. */
                if (gs > 32767 || gs < -32768 ||
                    b8 > (int64_t)2147483647 || b8 < -(int64_t)2147483648) {
                    ok = 0;
                    break;
                }
                e[k].gm = gm;
                e[k].gs = (int16_t)gs;
                e[k].gneg = (int8_t)gneg;
                e[k].b8 = (int32_t)b8;
            }
            if (ok) {
                struct ln_ckey *c = &ln_ck[ln_ck_rr];

                c->g = gamma; c->b = beta; c->so = ln_fbits(scale_out); c->K = K;
                c->h = chash;
                c->live = 1;
                slot = ln_ck_rr;
                ln_ck_rr = (ln_ck_rr + 1) % MBP_B87LN_SITES;
            } else {
                slot = -1;
            }
        }
        if (slot >= 0) {
            const struct ln_cent *const e = ln_cc[slot];

            for (m = 0; m < M; m++) {
                const int8_t *x = input + (size_t)m * K;
                int8_t *y = output + (size_t)m * K;
                int64_t s = 0, ss = 0;
                int32_t mean;
                uint64_t var;
                uint32_t rs;
                int sh;

                for (k = 0; k < K; k++) { s += x[k]; ss += (int64_t)x[k] * x[k]; }
                mean = (int32_t)((s << 8) / K);
                {
                    int64_t v = ((ss << 16) / K) - (int64_t)mean * mean;
                    if (v < 0) v = 0;
                    v += eps_q16;
                    if (v == 0) v = 1;
                    var = (uint64_t)v;
                }
                rs = int_rsqrt_q31(var, &sh);
                for (k = 0; k < K; k++) {
                    int64_t d8 = ((int64_t)x[k] << 8) - mean;
                    int64_t xn = LN_XN(d8, rs, sh);
                    int64_t v_q8 = LN_SCALE(xn, e[k].gm, (int)e[k].gs + 8);

                    if (e[k].gneg) v_q8 = -v_q8;
                    v_q8 += e[k].b8;
#if MBP_B87LN_POISON == 8
                    v_q8 += 256;
#endif
                    y[k] = LN_OUT(v_q8, activation_min, activation_max, full);
                }
            }
            return;
        }
    }
#endif /* MBP_B87LN */

    if (hoist) {
        for (k = 0; k < K; k++) {
            int32_t gm, bm;
            int gs, bs, gneg, bneg;

            if (gamma) {
                nlk_f2mss(gamma[k], &gm, &gs, &gneg);
                nlk_msmul(gm, gs, om, om_s, &gm, &gs);
            } else {
                gm = om; gs = om_s; gneg = 0;
            }
            ln_pc_gm[k] = gm; ln_pc_gs[k] = gs; ln_pc_gneg[k] = gneg;
            if (beta) {
                int64_t b8;
                nlk_f2mss(beta[k], &bm, &bs, &bneg);
                nlk_msmul(bm, bs, om, om_s, &bm, &bs);
                b8 = LN_SCALE((int64_t)1 << 8, bm, bs);
                ln_pc_b8[k] = bneg ? -b8 : b8;
            } else {
                ln_pc_b8[k] = 0;
            }
        }
    }

    for (m = 0; m < M; m++) {
        const int8_t *x = input + (size_t)m * K;
        int8_t *y = output + (size_t)m * K;
        int64_t s = 0, ss = 0;
        int32_t mean;
        uint64_t var;
        uint32_t rs;
        int sh;

        for (k = 0; k < K; k++) { s += x[k]; ss += (int64_t)x[k] * x[k]; }
        mean = (int32_t)((s << 8) / K);                       /* Q8 of mu_q */
        {
            int64_t v = ((ss << 16) / K) - (int64_t)mean * mean;   /* Q16 of var_q */
            if (v < 0) v = 0;
            v += eps_q16;
            if (v == 0) v = 1;
            var = (uint64_t)v;
        }
        rs = int_rsqrt_q31(var, &sh);       /* 1/sqrt(V) == rs * 2^-(23+sh) */

        if (hoist) {
            for (k = 0; k < K; k++) {
                int64_t d8 = ((int64_t)x[k] << 8) - mean;      /* Q8 of (x - mu_q) */
                /* xn in Q16: d8 * rs * 2^-(15+sh), and 8 + 16 - 23 - sh == -(15 + sh). */
                int64_t xn = LN_XN(d8, rs, sh);
                int64_t v_q8 = LN_SCALE(xn, ln_pc_gm[k], ln_pc_gs[k] + 8);

                if (ln_pc_gneg[k]) v_q8 = -v_q8;
                v_q8 += ln_pc_b8[k];
                y[k] = LN_OUT(v_q8, activation_min, activation_max, full);
            }
            continue;
        }

        for (k = 0; k < K; k++) {
            int64_t d8 = ((int64_t)x[k] << 8) - mean;          /* Q8 of (x - mu_q) */
            int64_t xn = LN_XN(d8, rs, sh);
            int32_t gm, bm;
            int gs, bs, gneg, bneg;
            int64_t v_q8;

            if (gamma) {
                nlk_f2mss(gamma[k], &gm, &gs, &gneg);
                nlk_msmul(gm, gs, om, om_s, &gm, &gs);
            } else {
                gm = om; gs = om_s; gneg = 0;
            }
            v_q8 = LN_SCALE(xn, gm, gs + 8);
            if (gneg) v_q8 = -v_q8;
            if (beta) {
                nlk_f2mss(beta[k], &bm, &bs, &bneg);
                nlk_msmul(bm, bs, om, om_s, &bm, &bs);
                {
                    int64_t b8 = LN_SCALE((int64_t)1 << 8, bm, bs);
                    v_q8 += bneg ? -b8 : b8;
                }
            }
            y[k] = LN_OUT(v_q8, activation_min, activation_max, full);
        }
    }
}
