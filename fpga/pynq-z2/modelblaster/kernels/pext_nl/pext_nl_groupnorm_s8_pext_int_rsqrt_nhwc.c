/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_rsqrt_nhwc */
/* act_layouts: nhwc */
/* accuracy_class: numeric_drift */
/* origin: patches/0100; pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c widened */
/* NHWC: pext_int_rsqrt with the activation read as [N, H, W, C] and written the same way.
 * GroupNorm(1, C) normalises over all C*H*W elements -- the sum and the sum of squares do not
 * care about order -- and applies a per-channel affine; only the index of that affine changes.
 * Every element's integer arithmetic is identical to pext_int_rsqrt's, so the output is the
 * NCHW kernel's bytes permuted.  T1 lever 2 (ROCC_DECOUPLED.md 8.14): Moonshine's stem as an
 * NHWC island, so the engine's convolutions read and write their own layout.
 *
 * THE LOOP ORDER IS THE LAYOUT'S.  The first version kept pext_int_rsqrt's channel-outer
 * affine loop and only changed the index, so each of the C passes strode C bytes per element
 * through the whole tensor.  On Moonshine's stem (C = 288, 287,712 elements, 281 KB in and 281
 * KB out) that is a new 64-byte cache block on every read and every write, against hart 0's
 * 16 KB L1 and the SoC's L2: measured on the board (Lab B26, 0x5A5A0010, 2026-09-17 08:57),
 * 169.4 cycles/element against the NCHW kernel's 89.4, +23.0 M cycles, which took two thirds
 * of the staging the island removed.  Here the affine loop is pixel-outer and channel-inner,
 * so both tensors are walked in memory order; the per-channel constants are decoded once into
 * tables first.  Each element still gets exactly the same integer expression with the same
 * constants, so the bytes do not change (checked against the first version and against the
 * NCHW kernel, permuted). */
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

/* One channel's affine, exactly as pext_int_rsqrt decodes it: gamma[c]/scale_out as a
 * multiply-shift and a sign, beta[c]/scale_out as a Q8 offset. */
static void pgn_channel(const float *gamma, const float *beta, int c, int32_t om, int om_s,
			int32_t *gm, int *gs, int *gneg, int64_t *b8)
{
	int32_t bm;
	int bs, bneg;

	*b8 = 0;
	if (gamma) {
		pgn_f2mss(gamma[c], gm, gs, gneg);
		pgn_msmul(*gm, *gs, om, om_s, gm, gs);
	} else {
		*gm = om; *gs = om_s; *gneg = 0;
	}
	if (beta) {
		pgn_f2mss(beta[c], &bm, &bs, &bneg);
		pgn_msmul(bm, bs, om, om_s, &bm, &bs);
		*b8 = nl_scale((int64_t)1 << 8, bm, bs);
		if (bneg) *b8 = -*b8;
	}
}

/* Per-channel tables for the pixel-outer loop.  Static: hart 0 runs one dispatch at a time,
 * and 4,096 channels x 20 bytes is more stack than a Zephyr thread should lend a kernel. */
#define PGN_NHWC_MAXC 4096
static int32_t pgn_gm[PGN_NHWC_MAXC];
static int     pgn_gs[PGN_NHWC_MAXC];
static int     pgn_gneg[PGN_NHWC_MAXC];
static int64_t pgn_b8[PGN_NHWC_MAXC];

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

		for (i = 0; i < CHW; i++) {
			s += x[i];
			ss += (int64_t)x[i] * x[i];
		}
		mean = (int32_t)((s * 256) / (int64_t)CHW);                    /* Q8 of mu_q */
		v = ((ss * 65536) / (int64_t)CHW) - (int64_t)mean * mean;     /* Q16 of var_q */
		if (v < 0) v = 0;
		v += eps_q16;
		if (v == 0) v = 1;
		rs = int_rsqrt_q31((uint64_t)v, &sh);           /* 1/sqrt(V) == rs * 2^-(23+sh) */

		if (C <= PGN_NHWC_MAXC) {
			/* per-channel constants first, then the elements in memory order */
			for (c = 0; c < C; c++)
				pgn_channel(gamma, beta, c, om, om_s, &pgn_gm[c], &pgn_gs[c], &pgn_gneg[c], &pgn_b8[c]);
			for (i = 0; i < HW; i++) {
				const int8_t *xp = x + i * (size_t)C;
				int8_t *yp = y + i * (size_t)C;
				for (c = 0; c < C; c++) {
					const int64_t d8 = (int64_t)xp[c] * 256 - mean;          /* Q8 */
					const int64_t xn = (d8 * (int64_t)rs) >> (15 + sh);       /* Q16 */
					int64_t v_q8 = nl_scale(xn, pgn_gm[c], pgn_gs[c] + 8);

					if (pgn_gneg[c]) v_q8 = -v_q8;
					yp[c] = nl_q8_to_s8(v_q8 + pgn_b8[c], activation_min, activation_max);
				}
			}
			continue;
		}
		for (c = 0; c < C; c++) {       /* more channels than the tables hold: channel-outer */
			int32_t gm;
			int gs, gneg;
			int64_t b8;

			pgn_channel(gamma, beta, c, om, om_s, &gm, &gs, &gneg, &b8);
			for (i = 0; i < HW; i++) {
				/* NHWC: element (pixel i, channel c) */
				const int64_t d8 = (int64_t)x[i * (size_t)C + (size_t)c] * 256 - mean;   /* Q8 */
				const int64_t xn = (d8 * (int64_t)rs) >> (15 + sh);       /* Q16; >> of a negative is implementation-defined (arithmetic in GCC), not UB */
				int64_t v_q8 = nl_scale(xn, gm, gs + 8);

				if (gneg) v_q8 = -v_q8;
				y[i * (size_t)C + (size_t)c] = nl_q8_to_s8(v_q8 + b8, activation_min, activation_max);
			}
		}
	}
}
