/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_rsqrt */
/* accuracy_class: numeric_drift */
/* origin: patches/0100; pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c widened */
/*
 * groupnorm_s8, ONE group, with no floating-point arithmetic: pext_nl's integer layer norm
 * with the row widened to C*H*W and the affine indexed by CHANNEL.
 *
 * The reference is double with a sqrt, three passes over all C*H*W elements; on Moonshine's
 * stem that is 287,712 elements per 4 s of audio.  This is:
 *   - one pass of int64 sums (sum and sum of squares) over the raw codes,
 *   - one integer reciprocal square root per SAMPLE (int_rsqrt_q31),
 *   - gamma[c]/scale_out and beta[c]/scale_out decoded from their IEEE-754 bits ONCE PER
 *     CHANNEL (pext_nl's layer norm decodes gamma per element; here the channel's value is
 *     shared by H*W elements, so it is hoisted),
 *   - a multiply-shift per element.
 *
 * scale_in cancels out of the normalisation -- (x*s - mu)/sqrt(var + eps) equals
 * (x - mu_q)/sqrt(var_q + eps/s^2) with mu_q, var_q the statistics of the codes -- and
 * enters only as eps/scale_in^2, computed from the floats' bit patterns.
 *
 * NUMERIC_DRIFT, not bit-exact: the reference's double mean, variance and reciprocal square
 * root are replaced by Q8/Q16/Q0.31 integers.  The measured difference is reported by
 * check_moonshine.py on Moonshine's own stem activation and on random ones.
 */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif
#include "pext.h"

/*
 * B66 -- THE PER-CHANNEL TABLE, AND WHY IT IS AN IDENTITY RATHER THAN A TOLERANCE.
 *
 * Inside one channel the map this kernel applies is a function of the INPUT BYTE ALONE:
 * mean, rs and sh are fixed for the sample, and gm/gs/gneg/b8 are fixed for the channel.
 * An int8 code has exactly 256 possible values, so 256 entries REPRODUCE THE FUNCTION ON
 * ITS ENTIRE DOMAIN.  The entry for v is the shipped expression evaluated at xc[i] == v,
 * instruction for instruction, so the output is bit-identical BY CONSTRUCTION -- there is
 * no sampled input, no interpolation and no tolerance to widen.  That is what makes
 * `max_abs_err = 0` evidence here, rather than the tautology it is for a kernel whose
 * accuracy_class is numeric_drift in the first place: this change does not touch the
 * numeric_drift the file's own header declares against the `double` reference, it only
 * stops recomputing the same 256 values HW times.
 *
 * THE QUANTITY THE TRADE DEPENDS ON IS HW, AND NOTHING ELSE.  The build is 256 entries
 * per channel and pays for itself over that channel's HW elements; C and N multiply both
 * sides equally and cancel.  A guard on CHW, on C, or on the kernel's identity would be
 * the guard-on-the-wrong-quantity bug that B63 found twice (layernorm_s8's hoist testing
 * K where it must test M; add_s8's table built at every n).
 *
 * THE CROSSOVER IS MEASURED, NOT ASSUMED.  test/b66_icount.sh counts retired instructions
 * for both arms on spike at the board's own flags, sweeping HW at fixed C so nothing else
 * moves (out/b66_guard_quantity/icount/b66_icount.txt):
 *
 *     HW      per-element      table     table/per-element
 *     256         123,215     137,595        1.117
 *     288         138,445     140,923        1.018
 *     320         153,667     144,244        0.939
 *     999         476,825     214,861        0.451
 *
 * so the arms cross at HW = 295.  MBP_GN_MINHW is set ABOVE it, at 320, deliberately: the
 * count is instructions and the board spends cycles, and the two arms' mixes differ (the
 * per-element arm is multiply-heavy, the table arm load-heavy), so the guard sits on the
 * side of the uncertainty where being wrong costs nothing.  Moonshine's encoder stem is
 * HW = 999, 3.1x the crossover; a decoder-shaped groupnorm below 320 takes the original
 * per-element path unchanged.
 */
#ifndef MBP_GN_MINHW
#define MBP_GN_MINHW 320
#endif

/*
 * B87 -- WHERE groupnorm_s8's CYCLES ACTUALLY GO, counted rather than estimated.
 *
 * Off the shipped image's own disassembly (out/b86_attn_on2/enc_q16/dis.txt,
 * kernel_groupnorm_s8_moonshine_enc) and on spike at the board's flags
 * (test/b87_icount.sh), at this graph's only groupnorm shape -- N = 1, C = 288, H = 1,
 * W = 999, CHW = 287,712:
 *
 *     term                              instructions      per element
 *     reduction  s / ss                 6 x 287,712           6.00
 *     per-channel LUT build       288 x 256 x ~43            ~9.56
 *     LUT apply                        7 x 287,712            7.00
 *
 * THE BUILD IS THE LARGEST TERM AND IT IS NOT THE ALGORITHM: 73,728 table entries are
 * computed to serve 287,712 elements -- ONE ENTRY FOR EVERY 3.9 ELEMENTS.  Four defects,
 * each of them bookkeeping:
 *
 * (1) THE REDUCTION IS A DOT PRODUCT AND THIS CORE HAS ONE.  Eight elements at a time,
 *     `s += x[i]` is MBP.DOT8 against the all-ones word and `ss += x[i]*x[i]` is MBP.DOT8
 *     of the word against itself.  pext.h specifies DOT8 as exact and unsaturating
 *     (|r| <= 8*128*128 = 131,072, never near an int64), and the bitstream's feature gate
 *     declares `pext`.  Six instructions an element becomes seven per EIGHT.  Integer
 *     addition is associative and both DOT8s are exact, so s and ss are the same two
 *     int64 values bit for bit -- not approximations of them.
 *
 * (2) THE BUILD RECOMPUTES A PER-SAMPLE QUANTITY PER CHANNEL.  xn(q) is a function of q,
 *     `mean`, `rs` and `sh` -- all of them fixed for the SAMPLE -- and of nothing in the
 *     channel, yet it is evaluated inside the c loop, 288 times over for the same 256
 *     values.  Hoisted to one table per sample it is computed 256 times, not 73,728.
 *
 * (3) nl_scale IS AN __int128 ROUTINE APPLIED TO A 21-BIT OPERAND.  xn is a Q16
 *     normalised code and `mult` is an int32, so `a * mult + 2^30` is exact in int64:
 *     one `mul` and two shifts, where the generic form spends a mul, a mulh, an sltu,
 *     four shifts and a two-limb add -- about fifteen instructions per entry.  The
 *     condition is TESTED, per channel, against the largest |xn| the sample's own table
 *     contains, and the generic nl_scale is kept for the arm where the test fails, so the
 *     identity holds for every input and not only for the scales calibration emits.
 *
 * (4) THE APPLY LOOP spends three pointer updates and a branch on one byte.  Unrolled
 *     eight ways the loads and stores use their own displacements.
 *
 * Every table entry is the shipped expression evaluated at the same argument, in the same
 * order, with the same implementation-defined right shifts -- so this is a RESTRUCTURING,
 * `max_abs_err = 0` is the right instrument, and it does not touch the numeric_drift this
 * file's header declares against the `double` reference.
 *
 * OFF BY DEFAULT: groupnorm_s8 is built into both halves' images and a default flip would
 * move another workstream's control arm under it.  -DMBP_B87=1 selects it.
 */
#ifndef MBP_B87
#define MBP_B87 0
#endif
/* LIVE-PATH PROOF, not a feature -- the same rule B66 and B74 established here.  A
 * byte-for-byte gate is passed perfectly by a route that never fires, so b87_gate.sh
 * builds one arm per value and REQUIRES the gate to FAIL.  Each perturbs exactly one of
 * the new routes, visibly in the OUTPUT:
 *   1  the DOT8 reduction        2  the hoisted LUT build      3  the unrolled apply
 */
#ifndef MBP_B87_POISON
#define MBP_B87_POISON 0
#endif

/*
 * B87b -- THE CROSSTALK ISOLATION PAD.  Not a feature, and it does NOT enable MBP_B87.
 *
 * B87 measured +306,779 cycles of movement in rows it does not claim, 88x the run-to-run
 * floor and 0.25 % of encoder steady, POSITIVE where B86's equivalent was negative, on the
 * same three rows both times (two LUT-lane kernels and the LN lane).  Reading the two
 * ELFs settles what moved and what did not, and it refutes the candidate B87 registered:
 *
 *   every activation buffer moved by EXACTLY +1,280 bytes -- the .text growth, rounded to
 *   alignment -- so their offsets RELATIVE TO EACH OTHER did not change at all;
 *   xnt[256] lands in .bss AFTER every one of them, and the only symbols it displaces are
 *   the roccmoon runtime and lane scratch -- mb_pext_lin_x, mb_pext_conv_rows,
 *   mb_pext_conv_wpack, mbxr_rt_cache, mbxa_pr, mbxa_sc -- and the four stacks, which move
 *   +3,328 = +1,280 + 2,048.
 *
 * So the scratch moves +2,048 RELATIVE to the activation buffers.  Hart 0's L1D is 16 KiB,
 * 4-way, 64 sets, 64 B lines (MEMORY_HIERARCHY.md:43), so 2,048 bytes is 32 sets -- exactly
 * half the cache, the MAXIMAL relative shift.  And every large mover is a LANE kernel that
 * touches that scratch: layernorm_s8 +41,449 and attention_s8 -13,063 (the only negative
 * row) use mbxa_pr/mbxa_sc and mbxr_rt_cache directly; gelu_s8 +8,089 and tanh_s8 +7,716 go
 * through the same runtime.  permute4_s8, which is CPU-only and touches no lane, moved
 * +3,098 -- below the floor.
 *
 * This pad reproduces that displacement AND NOTHING ELSE: 2,048 bytes of dead .bss in the
 * same translation unit and the same link position as xnt, with MBP_B87 left OFF so not one
 * instruction of the lever is compiled in.  If the pad arm reproduces the crosstalk, the
 * effect is a property of THIS IMAGE'S LAYOUT that MBP_B87 merely triggered, and B87's P5
 * is restated as a measured property of the image rather than a miss on the lever.
 *
 * MEASURED, NOT ASSUMED, AND IT CAUGHT ITSELF.  The first version of this used
 * `__attribute__((used))` alone.  `used` stops the COMPILER discarding the object; the
 * image is linked with -ffunction-sections -fdata-sections -Wl,--gc-sections, and the
 * LINKER discarded it anyway -- nm on the built ELF showed the symbol absent, zero of 275
 * symbols displaced, and an image byte-identical in size to the control.  The arm had
 * silently become a second copy of the control, which is the exact failure this comment
 * was written to warn about.  `retain` is what survives --gc-sections, and the placement
 * is VERIFIED with nm against the control before any board time is spent, not argued for.
 */
#ifndef MBP_B87_BSSPAD
#define MBP_B87_BSSPAD 0
#endif
#if MBP_B87_BSSPAD
static char pgn_bsspad[2048] __attribute__((used, retain));
#endif

#if MBP_B87
/* (1) sum and sum-of-squares of the raw codes, eight at a time.  The scalar tail is the
 * shipped loop verbatim, and it is also the whole loop when the buffer is not 8-aligned:
 * Rocket takes an exception on a misaligned `ld` rather than emulating it, so the
 * alignment is guaranteed and not asserted (PEXT_SPEC.md section 6). */
static void pgn_sums(const int8_t *x, size_t n, int64_t *ps, int64_t *pss)
{
	int64_t s = 0, ss = 0;
	size_t i = 0;

	if (MB_PEXT_ALIGNED8(x)) {
		const int64_t ones = (int64_t)0x0101010101010101ll;
		const size_t n8 = n & ~(size_t)7;
		const int8_t *p = x, *const pe = x + n8;

		/* a running pointer, not x + i: an index costs an `add` an iteration to
		 * re-form the address the load already has. */
		for (; p < pe; p += 8) {
			const int64_t w = MB_PEXT_LD8(p);

			s += mb_pext_dot8(w, ones);
			ss += mb_pext_dot8(w, w);
#if MBP_B87_POISON == 1
			/* inside the DOT8 loop, so it proves THAT route ran and not the
			 * scalar tail; +8 per word is +n over the pass, which moves the Q8
			 * mean by exactly 256 -- one whole code -- and so every output. */
			s += 8;
#endif
		}
		i = n8;
	}
	for (; i < n; i++) {
		s += x[i];
		ss += (int64_t)x[i] * x[i];
	}
	*ps = s;
	*pss = ss;
}

/* (3) nl_scale's value computed in 64 bits.  Identical to nl_scale whenever
 * pgn_s64_ok() holds for the operand, which the caller tests once per channel. */
static inline int64_t pgn_scale64(int64_t a, int32_t mult, int s)
{
	int64_t p;

	if (s < 0) {
		/* nl_scale writes `a <<= -s`, which UBSan flags on a negative a (int_nonlin.c
		 * 269, and it flags the CONTROL arm too).  Same bit pattern, no UB. */
		a = (int64_t)((uint64_t)a << -s);
		s = 0;
	}
	p = (a * (int64_t)mult + ((int64_t)1 << 30)) >> 31;
	if (s > 0) {
		p = (p + ((int64_t)1 << (s - 1))) >> s;
	}
	return p;
}

/* |a| < 2^31 and |mult| <= 2^31 - 1 give |a * mult| < 2^62, so the + 2^30 and both
 * rounded shifts are exact in int64 and pgn_scale64 IS nl_scale.  `m` is the largest
 * |xn| the sample's table contains, so one test covers all 256 entries. */
static int pgn_s64_ok(uint64_t m, int s)
{
	if (s < 0) {
		if (-s >= 31 || m > (((uint64_t)1 << 31) >> -s)) {
			return 0;
		}
		m <<= -s;
	}
	return m < ((uint64_t)1 << 31);
}

/* (2) one channel's 256 entries.  `full` and `f64` are constants at every call site, so
 * neither copy of this loop carries the other's branch. */
static inline __attribute__((always_inline)) void
pgn_lut(int8_t *lut, const int64_t *xnt, int32_t gm, int gs8, int gneg, int64_t b8,
	int amin, int amax, int full, int f64)
{
	int q;

	for (q = 0; q < 256; q++) {
		int64_t v = f64 ? pgn_scale64(xnt[q], gm, gs8)
				: nl_scale(xnt[q], gm, gs8);

		if (gneg) {
			v = -v;
		}
		v += b8;
#if MBP_B87_POISON == 2
		v += 256;
#endif
		if (full) {
			/* nl_q8_to_s8 with amin = -128, amax = 127: the two runtime clamps
			 * are the int8 range itself, which is what CLIP8 does in one op. */
			const int64_t r = v >= 0 ? ((v + 128) >> 8) : -((-v + 128) >> 8);

			lut[q] = (int8_t)mb_pext_clip8((int32_t)r);
		} else {
			lut[q] = nl_q8_to_s8(v, amin, amax);
		}
	}
}

/* (4) the apply pass.  Read before write within each group of four, so it behaves
 * identically if the caller ever passes yc == xc. */
static void pgn_apply(const int8_t *xc, int8_t *yc, size_t n, const int8_t *lut)
{
	size_t i = 0;

	for (; i + 8 <= n; i += 8) {
		const int8_t a = lut[(uint8_t)xc[i]];
		const int8_t b = lut[(uint8_t)xc[i + 1]];
		const int8_t c = lut[(uint8_t)xc[i + 2]];
		const int8_t d = lut[(uint8_t)xc[i + 3]];
		const int8_t e = lut[(uint8_t)xc[i + 4]];
		const int8_t f = lut[(uint8_t)xc[i + 5]];
		const int8_t g = lut[(uint8_t)xc[i + 6]];
		const int8_t h = lut[(uint8_t)xc[i + 7]];

		yc[i] = a;
		yc[i + 1] = b;
		yc[i + 2] = c;
		yc[i + 3] = d;
		yc[i + 4] = e;
		yc[i + 5] = f;
		yc[i + 6] = g;
		yc[i + 7] = h;
	}
	for (; i < n; i++) {
		yc[i] = lut[(uint8_t)xc[i]];
	}
#if MBP_B87_POISON == 3
	yc[0] = (int8_t)(yc[0] ^ 1);
#endif
}
#endif /* MBP_B87 */

/* |f| == mult * 2^-31 * 2^-shift, plus the sign.  (Own name: kernels.c concatenates the
 * layer norm kernel's static helpers into the same translation unit.) */
static void pgn_f2mss(float f, int32_t *m, int *s, int *neg)
{
	uint32_t b, ab;
	float af;

	__builtin_memcpy(&b, &f, sizeof(b));
	*neg = (int)((b >> 31) & 1u);
	ab = b & 0x7fffffffu;
	__builtin_memcpy(&af, &ab, sizeof(af));
	nl_f2ms(af, m, s);
}

static void pgn_msmul(int32_t m1, int s1, int32_t m2, int s2, int32_t *m, int *s)
{
	uint64_t p = ((uint64_t)(uint32_t)m1 * (uint32_t)m2) >> 31;
	int sh = s1 + s2;

	if (p != 0 && p < 0x40000000ull) { p <<= 1; sh += 1; }
	*m = (int32_t)p;
	*s = sh;
}

void kernel_groupnorm_s8(const int8_t *input, const float *gamma,
			 const float *beta, int8_t *output,
			 int N, int C, int H, int W,
			 float scale_in, float scale_out, float eps,
			 int activation_min, int activation_max)
{
	const size_t HW = (size_t)H * (size_t)W;
	const size_t CHW = (size_t)C * HW;
	int32_t mi, me, om;
	int si, se, om_s, dummy;
	int64_t eps_q16 = 0;
	int n, c;
	size_t i;

	nl_f2ms_recip(scale_out, &om, &om_s);
	nl_f2ms(scale_in, &mi, &si);
	pgn_f2mss(eps, &me, &se, &dummy);
	if (me != 0 && mi != 0) {
		uint64_t p = ((uint64_t)(uint32_t)mi * (uint32_t)mi) >> 31;   /* scale_in^2 */
		int sq = 2 * si;
		uint64_t r;

		if (p < 0x40000000ull) { p <<= 1; sq += 1; }
		r = (((uint64_t)(uint32_t)me) << 31) / p;
		if (r > 0x7fffffffull) r = 0x7fffffffull;
		eps_q16 = nl_scale((int64_t)1 << 16, (int32_t)r, se - sq);
		if (eps_q16 < 0) eps_q16 = 0;
	}

	for (n = 0; n < N; n++) {
		const int8_t *x = input + (size_t)n * CHW;
		int8_t *y = output + (size_t)n * CHW;
		int64_t s = 0, ss = 0, v;
		int32_t mean;
		uint32_t rs;
		int sh;
#if MBP_B87
		/* static, not stack-local: 2 KB against the harness's 8 KB worker stack, and
		 * function-scoped so a second instantiation of this kernel in the same
		 * translation unit gets its own.  Safe because pext_nl kernels run on hart 0
		 * only (MBP traps on hart 1), so there is no second caller. */
		static int64_t xnt[256];
		uint64_t xnmax = 0;
#endif

#if MBP_B87
		pgn_sums(x, CHW, &s, &ss);
#else
		for (i = 0; i < CHW; i++) {
			s += x[i];
			ss += (int64_t)x[i] * x[i];
		}
#endif
		mean = (int32_t)((s * 256) / (int64_t)CHW);                    /* Q8 of mu_q */
		v = ((ss * 65536) / (int64_t)CHW) - (int64_t)mean * mean;     /* Q16 of var_q */
		if (v < 0) v = 0;
		v += eps_q16;
		if (v == 0) v = 1;
		rs = int_rsqrt_q31((uint64_t)v, &sh);           /* 1/sqrt(V) == rs * 2^-(23+sh) */

#if MBP_B87
		/* (2) xn(q), the SAMPLE's half of the map, once instead of once per channel.
		 * The expression is the shipped one, term for term and shift for shift. */
		for (i = 0; i < 256; i++) {
			const int8_t qv = (int8_t)(uint8_t)i;
			const int64_t d8 = (int64_t)qv * 256 - mean;
			const int64_t xn = (d8 * (int64_t)rs) >> (15 + sh);
			const uint64_t a = (uint64_t)(xn < 0 ? -xn : xn);

			xnt[i] = xn;
			if (a > xnmax) {
				xnmax = a;
			}
		}
#endif
		for (c = 0; c < C; c++) {
			const int8_t *xc = x + (size_t)c * HW;
			int8_t *yc = y + (size_t)c * HW;
			int32_t gm, bm;
			int gs, bs, gneg, bneg;
			int64_t b8 = 0;

			if (gamma) {
				pgn_f2mss(gamma[c], &gm, &gs, &gneg);
				pgn_msmul(gm, gs, om, om_s, &gm, &gs);
			} else {
				gm = om; gs = om_s; gneg = 0;
			}
			if (beta) {
				pgn_f2mss(beta[c], &bm, &bs, &bneg);
				pgn_msmul(bm, bs, om, om_s, &bm, &bs);
				b8 = nl_scale((int64_t)1 << 8, bm, bs);
				if (bneg) b8 = -b8;
			}
			if (HW >= (size_t)MBP_GN_MINHW) {
				int8_t lut[256];
#if !MBP_B87
				int q;
#endif
#if MBP_B87
				const int full = (activation_min == -128 &&
						  activation_max == 127);
				const int f64 = pgn_s64_ok(xnmax, gs + 8);

				/* Four constant-folded copies, one branch per CHANNEL. */
				if (full && f64) {
					pgn_lut(lut, xnt, gm, gs + 8, gneg, b8,
						activation_min, activation_max, 1, 1);
				} else if (full) {
					pgn_lut(lut, xnt, gm, gs + 8, gneg, b8,
						activation_min, activation_max, 1, 0);
				} else if (f64) {
					pgn_lut(lut, xnt, gm, gs + 8, gneg, b8,
						activation_min, activation_max, 0, 1);
				} else {
					pgn_lut(lut, xnt, gm, gs + 8, gneg, b8,
						activation_min, activation_max, 0, 0);
				}
				pgn_apply(xc, yc, HW, lut);
				continue;
#else

				/* The table IS the element body, evaluated at every byte the
				 * domain contains -- same expression, same order, same
				 * implementation-defined right shift. */
				for (q = 0; q < 256; q++) {
					const int8_t qv = (int8_t)(uint8_t)q;
					const int64_t d8 = (int64_t)qv * 256 - mean;              /* Q8 */
					const int64_t xn = (d8 * (int64_t)rs) >> (15 + sh);       /* Q16 */
					int64_t v_q8 = nl_scale(xn, gm, gs + 8);

					if (gneg) v_q8 = -v_q8;
					lut[q] = nl_q8_to_s8(v_q8 + b8, activation_min, activation_max);
				}
				for (i = 0; i < HW; i++) {
					yc[i] = lut[(uint8_t)xc[i]];
				}
				continue;
#endif
			}
			for (i = 0; i < HW; i++) {
				const int64_t d8 = (int64_t)xc[i] * 256 - mean;           /* Q8 */
				const int64_t xn = (d8 * (int64_t)rs) >> (15 + sh);       /* Q16; >> of a negative is implementation-defined (arithmetic in GCC), not UB */
				int64_t v_q8 = nl_scale(xn, gm, gs + 8);

				if (gneg) v_q8 = -v_q8;
				yc[i] = nl_q8_to_s8(v_q8 + b8, activation_min, activation_max);
			}
		}
	}
}
