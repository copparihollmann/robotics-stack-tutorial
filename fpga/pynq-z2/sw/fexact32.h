/* SPDX-License-Identifier: Apache-2.0 */
/*
 * fexact32.h -- IEEE-754 binary32 arithmetic, EXACTLY, in integers.
 *
 * WHAT IT IS FOR.  ModelBlaster's elementwise int8 references (add_s8, mul_s8, rope_s8,
 * matmul's requantise tail) are written in float32:
 *
 *     output = clamp( (int32_t)roundf( fl(fl(a*sa) + fl(b*sb)) / so ), ... )
 *
 * with round-to-nearest-even after every operation and round-half-AWAY at the end.  An
 * integer kernel that computes the same REAL value, (a*sa + b*sb)/so, agrees with that
 * expression everywhere except where the float32 rounding errors -- a few parts in 2^24
 * of the value -- straddle a half-integer.  So the curated integer kernels do two things:
 *
 *   1. a FAST PATH in fixed point, and a GUARD: if the fixed-point value is further from
 *      every half-integer than a bound on the float32 chain's error plus the fixed-point
 *      error, the two round the same way and the fast path's answer IS the reference's;
 *   2. otherwise -- a few elements per ten thousand -- the SLOW PATH below, which is the
 *      reference expression evaluated in exact binary32 arithmetic on integers: the same
 *      operations, in the same order, each rounded to 24 significant bits
 *      round-half-to-even exactly as IEEE-754 specifies, then roundf.
 *
 * No floating-point instruction executes and no soft-float routine is called: a float
 * ARGUMENT is decoded from its bit pattern (it arrives in an integer register on lp64),
 * and everything else is uint64 / unsigned __int128 arithmetic.
 *
 * DOMAIN.  Finite, non-zero scales in [2^-40, 2^40] (every calibrated ModelBlaster scale
 * is in ~[2^-44, 2^8]; the kernels check and take the slow path otherwise), int8 operands,
 * and results that do not underflow to subnormal or overflow (both impossible inside that
 * domain for these expressions).  Where the reference itself is undefined -- a roundf
 * result outside int32, which the C cast makes UB -- the slow path saturates.
 *
 * CHECKED, NOT ASSERTED.  fpga/pynq-z2/modelblaster/moonshine/check_moonshine.py compares
 * fx32_mul / fx32_add / fx32_div bit for bit against the host FPU on random binary32
 * operands, and each kernel against its float reference over the full int8 operand
 * domain at the model's own scales and at random ones.
 */
#ifndef FEXACT32_H_
#define FEXACT32_H_

#include <stdint.h>

/* (-1)^neg * m * 2^e, exactly.  m == 0 is zero.  m is at most 24 bits after fx32_round. */
typedef struct {
	uint64_t m;
	int32_t e;
	int32_t neg;
} fx32_t;

static inline int fx32_bitlen64(uint64_t v)
{
	return v ? 64 - __builtin_clzll(v) : 0;
}

static inline int fx32_bitlen128(unsigned __int128 v)
{
	uint64_t hi = (uint64_t)(v >> 64);

	return hi ? 128 - __builtin_clzll(hi) : fx32_bitlen64((uint64_t)v);
}

/* Decode a binary32.  Subnormals decode exactly too; inf/NaN are outside the domain. */
static inline fx32_t fx32_dec(float f)
{
	uint32_t b;
	fx32_t r;
	uint32_t ex, fr;

	__builtin_memcpy(&b, &f, sizeof(b));
	r.neg = (int32_t)(b >> 31);
	ex = (b >> 23) & 0xffu;
	fr = b & 0x7fffffu;
	if (ex == 0) {
		r.m = fr;
		r.e = -149;
	} else {
		r.m = fr | 0x800000u;
		r.e = (int32_t)ex - 150;
	}
	return r;
}

static inline fx32_t fx32_int(int32_t v)
{
	fx32_t r;

	r.neg = v < 0;
	r.m = (uint64_t)(v < 0 ? -(int64_t)v : (int64_t)v);
	r.e = 0;
	return r;
}

/* Round the exact magnitude n * 2^e to 24 significant bits, round-half-to-even.
 * `sticky` says the true magnitude is STRICTLY greater than n * 2^e by less than one
 * unit of 2^e; callers that pass it supply at least 26 significant bits so the unit lies
 * below the rounding position. */
static inline fx32_t fx32_round(unsigned __int128 n, int32_t e, int32_t neg, int sticky)
{
	fx32_t r;
	int L, sh;
	unsigned __int128 q, rem, half;

	r.neg = neg;
	if (n == 0) {
		r.m = 0;
		r.e = 0;
		return r;
	}
	L = fx32_bitlen128(n);
	if (L <= 24) {
		r.m = (uint64_t)n;
		r.e = e;
		return r;
	}
	sh = L - 24;
	q = n >> sh;
	rem = n - (q << sh);
	half = (unsigned __int128)1 << (sh - 1);
	if (rem > half || (rem == half && (sticky || (q & 1u)))) {
		q++;
	}
	if (q >> 24) {
		q >>= 1;
		sh++;
	}
	r.m = (uint64_t)q;
	r.e = e + sh;
	return r;
}

static inline fx32_t fx32_mul(fx32_t a, fx32_t b)
{
	return fx32_round((unsigned __int128)a.m * b.m, a.e + b.e, a.neg ^ b.neg, 0);
}

static inline fx32_t fx32_neg(fx32_t a)
{
	a.neg = !a.neg;
	return a;
}

static inline fx32_t fx32_add(fx32_t a, fx32_t b)
{
	int32_t e;
	int da, db;
	unsigned __int128 na, nb, n;
	int32_t neg;

	if (a.m == 0) {
		return fx32_round(b.m, b.e, b.neg, 0);
	}
	if (b.m == 0) {
		return fx32_round(a.m, a.e, a.neg, 0);
	}
	e = a.e < b.e ? a.e : b.e;
	da = a.e - e;
	db = b.e - e;
	/* A term more than 64 binary orders below the other is below a quarter-ulp of it
	 * (both mantissas are <= 24 bits), so the sum rounds to the larger term.  Guard the
	 * shift so the 128-bit alignment below can never overflow. */
	if (da > 64) {
		return fx32_round(a.m, a.e, a.neg, 0);
	}
	if (db > 64) {
		return fx32_round(b.m, b.e, b.neg, 0);
	}
	na = (unsigned __int128)a.m << da;
	nb = (unsigned __int128)b.m << db;
	if (a.neg == b.neg) {
		n = na + nb;
		neg = a.neg;
	} else if (na >= nb) {
		n = na - nb;
		neg = a.neg;
	} else {
		n = nb - na;
		neg = b.neg;
	}
	if (n == 0) {
		neg = 0;
	}
	return fx32_round(n, e, neg, 0);
}

/* a / b, correctly rounded.  b != 0; both mantissas at most 24 bits (every fx32_t this
 * header produces, and every decoded binary32). */
static inline fx32_t fx32_div(fx32_t a, fx32_t b)
{
	uint64_t ma = a.m, mb = b.m, num, q, rm;
	int32_t ea = a.e, eb = b.e;
	int s;

	if (ma == 0) {
		fx32_t z = { 0, 0, 0 };
		return z;
	}
	s = 24 - fx32_bitlen64(ma);      /* normalise both to exactly 24 bits */
	ma <<= s;
	ea -= s;
	s = 24 - fx32_bitlen64(mb);
	mb <<= s;
	eb -= s;
	num = ma << 39;                  /* < 2^63 */
	q = num / mb;                    /* in (2^38, 2^40): >= 26 significant bits */
	rm = num - q * mb;
	return fx32_round(q, ea - 39 - eb, a.neg ^ b.neg, rm != 0);
}

/* (int32_t)roundf(v): round half away from zero, saturating where the C cast is UB. */
static inline int32_t fx32_roundf_i32(fx32_t v)
{
	uint64_t mag;

	if (v.m == 0) {
		return 0;
	}
	if (v.e >= 0) {
		if (v.e > 30 || fx32_bitlen64(v.m) + v.e > 31) {
			mag = 0x7fffffffu;
		} else {
			mag = v.m << v.e;
		}
	} else if (-v.e > 62) {
		mag = 0;
	} else {
		int sh = -v.e;

		mag = (v.m + ((uint64_t)1 << (sh - 1))) >> sh;
		if (mag > 0x7fffffffu) {
			mag = 0x7fffffffu;
		}
	}
	return v.neg ? -(int32_t)mag : (int32_t)mag;
}

/* K = num/den as a TRUNCATED fixed-point multiplier: the exact ratio lies in
 * [q, q + 1) * 2^e with q in (2^38, 2^40].  One integer divide, per dispatch. */
typedef struct {
	uint64_t q;
	int32_t e;
} fx32_k_t;

static inline fx32_k_t fx32_ratio(fx32_t num, fx32_t den)
{
	fx32_k_t k;
	uint64_t mn = num.m, md = den.m;
	int32_t en = num.e, ed = den.e;
	int s;

	s = 24 - fx32_bitlen64(mn);
	mn <<= s;
	en -= s;
	s = 24 - fx32_bitlen64(md);
	md <<= s;
	ed -= s;
	k.q = (mn << 39) / md;
	k.e = en - ed - 39;
	return k;
}

/* round(v * K * 2^F) as a signed int64, for v = (-1)^neg * m * 2^e with m <= 2^24.
 * |result - v*K_exact*2^F| <= (|result| >> 38) + 1.  *ok = 0 if |result| would need
 * more than 61 bits (the caller then takes its exact slow path). */
static inline int64_t fx32_apply(uint64_t m, int32_t e, int32_t neg, fx32_k_t k, int F, int *ok)
{
	unsigned __int128 p = (unsigned __int128)m * k.q;
	int sh = -(e + k.e + F);
	uint64_t r;

	*ok = 1;
	if (p == 0) {
		return 0;
	}
	if (sh <= 0) {
		if (fx32_bitlen128(p) - sh > 61) {
			*ok = 0;
			return 0;
		}
		r = (uint64_t)(p << -sh);
	} else if (sh > 120) {
		r = 0;
	} else {
		unsigned __int128 rr = (p + ((unsigned __int128)1 << (sh - 1))) >> sh;

		if (fx32_bitlen128(rr) > 61) {
			*ok = 0;
			return 0;
		}
		r = (uint64_t)rr;
	}
	return neg ? -(int64_t)r : (int64_t)r;
}

/* The same scale pair decoded and range-checked: positive, finite, in [2^-40, 2^40]. */
static inline int fx32_scale_ok(fx32_t s)
{
	int l;

	if (s.neg || s.m == 0) {
		return 0;
	}
	l = fx32_bitlen64(s.m) - 1 + s.e;          /* floor(log2 s) */
	return l >= -40 && l < 40;
}

#endif /* FEXACT32_H_ */
