/* SPDX-License-Identifier: Apache-2.0
 *
 * audio_fe -- see audio_fe.h for the contract and for why this file compiles three ways.
 */

#include "audio_fe.h"

#ifdef FE_ARITH_FLOAT
#include <math.h>
#else
#include "pext.h"
#endif

/* ------------------------------------------------------------------ *
 * INPUT HEADROOM.  This microphone's noise floor is -60.9 dBFS
 * (MICROPHONE.md section 8), i.e. quiet-room PCM occupies about five of the
 * sixteen bits.  Windowing with a Q0.15 coefficient and shifting straight back
 * down by 15 would hand the transform a four-bit input.  So the window keeps
 * FE_IN_SHIFT extra bits.  int32 has room: a 256-point complex transform grows
 * its input by at most 256 (8 bits), so the worst case is 15 + FE_IN_SHIFT + 8
 * and must stay under 31.  The gain is a constant, and a constant gain is an
 * ADDITIVE constant after the log -- fe_melbank subtracts it back out so the
 * fixed-point and float builds report the same units.
 * ------------------------------------------------------------------ */
#define FE_IN_SHIFT   6

#if defined(__ZEPHYR__)
#include <zephyr/sys/printk.h>
#define FE_PRINT printk
#else
#include <stdio.h>
#define FE_PRINT printf
#endif

/* ------------------------------------------------------------------ *
 * The one primitive that separates the three builds.
 *
 * fe_qmul(a, m) = (a * m + 2^30) >> 31, a and m read as int32.
 *
 * FE_ARITH_PEXT  -> MBP.QMUL, one instruction, one cycle on hart 0.
 * FE_ARITH_INT   -> pext.h's software model: one `mul`, one `add`, one `srai`.
 *                   Rocket's multiplier is iterative, so the `mul` is where the
 *                   time goes; samples/audio_fe_bench measures how much.
 * Both are BIT-IDENTICAL -- they are the same expression, and PEXT_VALIDATION.md
 * shows the silicon equal to the model for 3,041 instruction-level cases.
 * ------------------------------------------------------------------ */
#ifndef FE_ARITH_FLOAT
static inline int32_t fe_qmul(int32_t a, int32_t m)
{
	return (int32_t)mb_pext_qmul((int64_t)a, (int64_t)m);
}
#endif

/* ================================================================== *
 * FLOAT BUILD -- the straw man.  Deliberately idiomatic: this is what
 * someone writes first, and it is what the measurement is against.
 * ================================================================== */
#ifdef FE_ARITH_FLOAT

static float g_re[FE_NCFFT], g_im[FE_NCFFT];
static float g_xre[FE_NBINS], g_xim[FE_NBINS];
static float g_pow[FE_NBINS];

void fe_window(const int16_t *pcm, struct fe_scratch *s)
{
	int n;

	(void)s;
	for (n = 0; n < FE_NCFFT; n++) {
		g_re[n] = 0.0f;
		g_im[n] = 0.0f;
	}
	for (n = 0; n < FE_FRAME_LEN; n++) {
		float w = (float)fe_window_q15[n] * (float)(1 << FE_IN_SHIFT) / 32768.0f;
		float v = (float)pcm[n] * w;

		if (n & 1) {
			g_im[n >> 1] = v;
		} else {
			g_re[n >> 1] = v;
		}
	}
}

void fe_cfft256(struct fe_scratch *s)
{
	int i, j, len, k, half;

	(void)s;
	for (i = 1, j = 0; i < FE_NCFFT; i++) {
		int bit = FE_NCFFT >> 1;

		for (; j & bit; bit >>= 1) {
			j ^= bit;
		}
		j ^= bit;
		if (i < j) {
			float t = g_re[i]; g_re[i] = g_re[j]; g_re[j] = t;
			t = g_im[i]; g_im[i] = g_im[j]; g_im[j] = t;
		}
	}
	for (len = 2; len <= FE_NCFFT; len <<= 1) {
		int stride = FE_NFFT / len;

		half = len >> 1;
		for (i = 0; i < FE_NCFFT; i += len) {
			for (k = 0; k < half; k++) {
				int t = k * stride;
				float wr = (float)fe_twiddle_q31[2 * t] * (1.0f / 2147483648.0f);
				float wi = (float)fe_twiddle_q31[2 * t + 1] * (1.0f / 2147483648.0f);
				float br = g_re[i + k + half], bi = g_im[i + k + half];
				float tr = br * wr - bi * wi;
				float ti = br * wi + bi * wr;

				g_re[i + k + half] = g_re[i + k] - tr;
				g_im[i + k + half] = g_im[i + k] - ti;
				g_re[i + k] += tr;
				g_im[i + k] += ti;
			}
		}
	}
}

void fe_split_real(struct fe_scratch *s)
{
	int k;

	(void)s;
	for (k = 0; k <= FE_NCFFT; k++) {
		int nk = (FE_NCFFT - k) & (FE_NCFFT - 1);
		float zr = g_re[k & (FE_NCFFT - 1)], zi = g_im[k & (FE_NCFFT - 1)];
		float nr = g_re[nk], ni = -g_im[nk];
		float ar = zr + nr, ai = zi + ni;
		float br = zr - nr, bi = zi - ni;
		float cr = bi, ci = -br;
		float wr, wi, tr, ti;

		if (k == FE_NCFFT) {
			wr = -1.0f; wi = 0.0f;
		} else {
			wr = (float)fe_twiddle_q31[2 * k] * (1.0f / 2147483648.0f);
			wi = (float)fe_twiddle_q31[2 * k + 1] * (1.0f / 2147483648.0f);
		}
		tr = cr * wr - ci * wi;
		ti = cr * wi + ci * wr;
		g_xre[k] = ar + tr;
		g_xim[k] = ai + ti;
	}
}

void fe_power(struct fe_scratch *s)
{
	int k;

	(void)s;
	for (k = 0; k < FE_NBINS; k++) {
		g_pow[k] = g_xre[k] * g_xre[k] + g_xim[k] * g_xim[k];
	}
}

void fe_melbank(const struct fe_scratch *s, int16_t *out_q8)
{
	int m, b;

	(void)s;
	for (m = 0; m < FE_NMEL; m++) {
		const int16_t *w = &fe_mel_w_q15[fe_mel_off[m]];
		int st = fe_mel_start[m], ln = fe_mel_len[m];
		float acc = 0.0f;
		float lg;

		for (b = 0; b < ln; b++) {
			acc += g_pow[st + b] * ((float)w[b] * (1.0f / 32768.0f));
		}
		lg = (acc <= 1.0f) ? (float)FE_LOG2_MIN / 256.0f
				   : log2f(acc) - (float)(2 * FE_IN_SHIFT);
		if (lg < (float)FE_LOG2_MIN / 256.0f) {
			lg = (float)FE_LOG2_MIN / 256.0f;
		}
		out_q8[m] = (int16_t)lrintf(lg * 256.0f);
	}
}

#else /* ================= FIXED POINT (INT and PEXT) ================= */

void fe_window(const int16_t *pcm, struct fe_scratch *s)
{
	int n;

	/* Pack z[n] = x[2n] + j*x[2n+1] straight out of the window, so the 512-point
	 * real transform costs a 256-point complex one.  The tail past FE_FRAME_LEN is
	 * the zero pad. */
	for (n = FE_FRAME_LEN / 2; n < FE_NCFFT; n++) {
		s->re[n] = 0;
		s->im[n] = 0;
	}
	for (n = 0; n < FE_FRAME_LEN; n += 2) {
		s->re[n >> 1] = ((int32_t)pcm[n] * fe_window_q15[n]) >> (15 - FE_IN_SHIFT);
		s->im[n >> 1] = ((int32_t)pcm[n + 1] * fe_window_q15[n + 1]) >>
				(15 - FE_IN_SHIFT);
	}
}

void fe_cfft256(struct fe_scratch *s)
{
	int32_t *re = s->re, *im = s->im;
	int i, j, len, k, half;

	for (i = 1, j = 0; i < FE_NCFFT; i++) {
		int bit = FE_NCFFT >> 1;

		for (; j & bit; bit >>= 1) {
			j ^= bit;
		}
		j ^= bit;
		if (i < j) {
			int32_t t = re[i]; re[i] = re[j]; re[j] = t;
			t = im[i]; im[i] = im[j]; im[j] = t;
		}
	}

	/* len == 2 is every twiddle equal to 1+0j.  Peeling it removes 128 butterflies'
	 * worth of multiplies -- 12.5 % of the transform's total -- for eight lines. */
	for (i = 0; i < FE_NCFFT; i += 2) {
		int32_t ar = re[i], ai = im[i], br = re[i + 1], bi = im[i + 1];

		re[i] = ar + br; im[i] = ai + bi;
		re[i + 1] = ar - br; im[i + 1] = ai - bi;
	}

	for (len = 4; len <= FE_NCFFT; len <<= 1) {
		int stride = FE_NFFT / len;

		half = len >> 1;
		for (i = 0; i < FE_NCFFT; i += len) {
			const int32_t *tw = fe_twiddle_q31;

			for (k = 0; k < half; k++, tw += 2 * stride) {
				int32_t wr = tw[0], wi = tw[1];
				int32_t br = re[i + k + half], bi = im[i + k + half];
				int32_t tr = fe_qmul(br, wr) - fe_qmul(bi, wi);
				int32_t ti = fe_qmul(br, wi) + fe_qmul(bi, wr);
				int32_t ar = re[i + k], ai = im[i + k];

				re[i + k] = ar + tr;
				im[i + k] = ai + ti;
				re[i + k + half] = ar - tr;
				im[i + k + half] = ai - ti;
			}
		}
	}
}

void fe_split_real(struct fe_scratch *s)
{
	const int32_t *re = s->re, *im = s->im;
	int k;

	/* X[k] = Xe[k] + W_512^k * Xo[k] from the packed 256-point transform, computed
	 * WITHOUT the customary halving: this produces 2*X[k].  The factor of 2 is a
	 * constant across every bin and every frame, so after the log it is an additive
	 * constant the model's first bias absorbs -- and keeping it buys one bit. */
	for (k = 0; k <= FE_NCFFT; k++) {
		int kk = k & (FE_NCFFT - 1);
		int nk = (FE_NCFFT - k) & (FE_NCFFT - 1);
		int32_t zr = re[kk], zi = im[kk];
		int32_t nr = re[nk], ni = -im[nk];
		int32_t ar = zr + nr, ai = zi + ni;
		int32_t br = zr - nr, bi = zi - ni;
		int32_t cr = bi, ci = -br;
		int32_t tr, ti;

		if (k == 0) {
			tr = cr; ti = ci;                  /* W^0  = +1 */
		} else if (k == FE_NCFFT) {
			tr = -cr; ti = -ci;                /* W^256 = -1 */
		} else {
			int32_t wr = fe_twiddle_q31[2 * k], wi = fe_twiddle_q31[2 * k + 1];

			tr = fe_qmul(cr, wr) - fe_qmul(ci, wi);
			ti = fe_qmul(cr, wi) + fe_qmul(ci, wr);
		}
		s->xre[k] = ar + tr;
		s->xim[k] = ai + ti;
	}
}

void fe_power(struct fe_scratch *s)
{
	int k;

	for (k = 0; k < FE_NBINS; k++) {
		int64_t r = s->xre[k], i = s->xim[k];

		s->pow[k] = (uint64_t)(r * r + i * i);
	}
}

/* Q0.16 log2(1 + i/32) for i = 0..32. */
static const uint32_t fe_log2_lut[33] = {
	    0,  2909,  5732,  8473, 11136, 13726, 16245, 18698,
	21089, 23421, 25696, 27918, 30089, 32211, 34288, 36320,
	38311, 40261, 42173, 44048, 45888, 47694, 49467, 51209,
	52922, 54605, 56260, 57888, 59491, 61068, 62620, 64150,
	65536
};

int16_t fe_log2_q8(uint64_t v)
{
	int e;
	uint32_t m, f, idx, rem, lo, hi, interp;
	int32_t q16;

	if (v == 0) {
		return FE_LOG2_MIN;
	}
	e = 63 - __builtin_clzll(v);
	m = (e >= 31) ? (uint32_t)(v >> (e - 31)) : (uint32_t)(v << (31 - e));
	f = m - 0x80000000u;                 /* Q31 fraction in [0,1) */
	idx = f >> 26;                       /* 0..31 */
	rem = (f >> 10) & 0xffffu;           /* Q16 within the segment */
	lo = fe_log2_lut[idx];
	hi = fe_log2_lut[idx + 1];
	interp = lo + (uint32_t)(((uint64_t)(hi - lo) * rem) >> 16);
	q16 = ((int32_t)e << 16) + (int32_t)interp;
	q16 >>= 8;
	if (q16 < FE_LOG2_MIN) {
		q16 = FE_LOG2_MIN;
	}
	return (int16_t)q16;
}

void fe_melbank(const struct fe_scratch *s, int16_t *out_q8)
{
	uint64_t pmax = 0;
	int sh = 0, m, b, k;

	/* Block floating point.  A mel bin is sum_k pow[k]*w[k], w in Q0.15; pow can
	 * reach 2^51 and the product would then need 66 bits.  Instead of throwing away
	 * the bottom bits unconditionally, find the frame's own maximum, shift every bin
	 * by JUST ENOUGH to make the accumulation safe, and add the shift back in the LOG
	 * domain -- where it is exact, because log2(E * 2^sh) = log2(E) + sh.
	 *
	 * The bound.  The widest mel filter here spans 30 bins (tools/gen_fe_tables.py
	 * prints it), so the accumulator is at most (pmax >> sh) * 2^15 * 30 < 2^(sh'+20)
	 * and sh' = 43 keeps it under 2^63.  The constant is load-bearing and was wrong
	 * once: at 33 the shift was ten bits larger than necessary, which cost ten bits at
	 * the QUIET end of a loud frame and drove whole mel bands to exactly zero -- a
	 * -2048 notch in the middle of a spectrum whose loud bands were all correct. */
	for (k = 0; k < FE_NBINS; k++) {
		if (s->pow[k] > pmax) {
			pmax = s->pow[k];
		}
	}
	if (pmax) {
		int bits = 64 - __builtin_clzll(pmax);

		sh = bits - 43;
		if (sh < 0) {
			sh = 0;
		}
	}

	for (m = 0; m < FE_NMEL; m++) {
		const int16_t *w = &fe_mel_w_q15[fe_mel_off[m]];
		int st = fe_mel_start[m], ln = fe_mel_len[m];
		uint64_t acc = 0;
		int16_t lg;

		for (b = 0; b < ln; b++) {
			acc += (s->pow[st + b] >> sh) * (uint64_t)(uint32_t)w[b];
		}
		acc >>= 15;
		lg = fe_log2_q8(acc);
		if (acc) {
			int32_t t = (int32_t)lg + (sh << 8) - (2 * FE_IN_SHIFT << 8);

			lg = (t < FE_LOG2_MIN) ? FE_LOG2_MIN :
			     (t > 32767) ? 32767 : (int16_t)t;
		}
		out_q8[m] = lg;
	}
}

#endif /* FE_ARITH_FLOAT */

/* ---- shared -------------------------------------------------------------------- */

void fe_logmel_frame(const int16_t *pcm, struct fe_scratch *s, int16_t *out_q8)
{
	fe_window(pcm, s);
	fe_cfft256(s);
	fe_split_real(s);
	fe_power(s);
	fe_melbank(s, out_q8);
}

int fe_nframes(int nsamp)
{
	return (nsamp < FE_FRAME_LEN) ? 0 : (nsamp - FE_FRAME_LEN) / FE_HOP_LEN + 1;
}

int fe_mfcc_clip(const int16_t *pcm, int nsamp, struct fe_scratch *s, int16_t *out_q8,
		 int want_mfcc)
{
	int n = fe_nframes(nsamp), i;
	int16_t mel[FE_NMEL];

	for (i = 0; i < n; i++) {
		fe_logmel_frame(pcm + (size_t)i * FE_HOP_LEN, s, mel);
		if (want_mfcc) {
			fe_dct(mel, out_q8 + (size_t)i * FE_NDCT);
		} else {
			int m;

			for (m = 0; m < FE_NMEL; m++) {
				out_q8[(size_t)i * FE_NMEL + m] = mel[m];
			}
		}
	}
	return n;
}

void fe_dct(const int16_t *logmel_q8, int16_t *out_q8)
{
	int k, n;

	for (k = 0; k < FE_NDCT; k++) {
		const int32_t *row = &fe_dct_q31[k * FE_NMEL];
		int64_t acc = 0;

		for (n = 0; n < FE_NMEL; n++) {
#ifdef FE_ARITH_FLOAT
			acc += (int64_t)lrintf((float)((int32_t)logmel_q8[n] << 8) *
					       ((float)row[n] * (1.0f / 2147483648.0f)));
#else
			/* <<8 before, >>8 after: fe_qmul truncates to an integer, and
			 * forty truncated terms on a Q8 value is a visible error. */
			acc += fe_qmul((int32_t)logmel_q8[n] << 8, row[n]);
#endif
		}
		acc >>= 7;    /* >>8 for the headroom, <<1 for the table's own 1/2 */
		out_q8[k] = (int16_t)(acc > 32767 ? 32767 : (acc < -32768 ? -32768 : acc));
	}
}

/* ---- self-test ------------------------------------------------------------------- *
 *
 * Runs the whole chain on a deterministic signal and checks three things that a
 * "it produced numbers" test would not:
 *
 *   1. A pure tone lands in the right mel band.  Gets the FFT's bin ordering, the
 *      real-FFT split and the mel table's frequency mapping all at once -- a transposed
 *      or off-by-one twiddle stride still produces a plausible-looking spectrum.
 *   2. A full-scale tone does not overflow.  FE_IN_SHIFT trades headroom for precision
 *      and the trade has to be checked, not asserted: the failure is a wrapped int32,
 *      which reads as a NOTCH at the signal frequency.
 *   3. Silence is FE_LOG2_MIN everywhere, and does not divide by zero in the log.
 */
#include <string.h>

static struct fe_scratch fe_st_scratch;
static int16_t fe_st_pcm[FE_FRAME_LEN];
static int16_t fe_st_mel[FE_NMEL];

/* 16-bit sine, generated by a stable integer recurrence so the test needs no libm and
 * no table: x[n] = 2*cos(w)*x[n-1] - x[n-2], run in Q30. */
static void fe_st_tone(int16_t *dst, int n, int32_t cos_w_q30, int32_t amp)
{
	int64_t ym1 = 0, ym2;
	int i;

	/* x[n] = amp * sin(w*n): x[0] = 0, x[1] = amp*sin(w). sin(w) = sqrt(1-cos^2). */
	{
		int64_t c = cos_w_q30;
		int64_t s2 = ((int64_t)1 << 60) - c * c;
		int64_t r = 1 << 30, k;

		for (k = 0; k < 40; k++) {
			r = (r + s2 / (r ? r : 1)) >> 1;
		}
		ym1 = (amp * r) >> 30;
	}
	ym2 = 0;
	dst[0] = 0;
	if (n > 1) {
		dst[1] = (int16_t)ym1;
	}
	for (i = 2; i < n; i++) {
		int64_t y = ((2 * (int64_t)cos_w_q30 * ym1) >> 30) - ym2;

		ym2 = ym1;
		ym1 = y;
		dst[i] = (int16_t)y;
	}
}

int audio_fe_selftest(void)
{
	int fails = 0, m, peak;
	int16_t q;

	/* --- 3. silence ------------------------------------------------------- */
	memset(fe_st_pcm, 0, sizeof(fe_st_pcm));
	fe_logmel_frame(fe_st_pcm, &fe_st_scratch, fe_st_mel);
	for (m = 0; m < FE_NMEL; m++) {
		if (fe_st_mel[m] != FE_LOG2_MIN) {
			FE_PRINT("FE_SELFTEST silence: mel[%d] = %d, want %d\n",
				 m, fe_st_mel[m], FE_LOG2_MIN);
			fails++;
			break;
		}
	}

	/* --- 1. a 1 kHz tone at -20 dBFS lands in the right band -------------- */
	/* cos(2*pi*1000/15993.859) in Q30 */
	fe_st_tone(fe_st_pcm, FE_FRAME_LEN, 843314856, 3277);
	fe_logmel_frame(fe_st_pcm, &fe_st_scratch, fe_st_mel);
	peak = 0;
	for (m = 1; m < FE_NMEL; m++) {
		if (fe_st_mel[m] > fe_st_mel[peak]) {
			peak = m;
		}
	}
	/* 1000 Hz sits in mel filter 18 for this table; allow its two neighbours so a
	 * legitimate half-bin leak does not fail the build. */
	if (peak < 17 || peak > 19) {
		FE_PRINT("FE_SELFTEST tone: peak mel band %d, want 17..19\n", peak);
		fails++;
	}
	FE_PRINT("FE_SELFTEST tone1k peak_band=%d peak_q8=%d\n", peak, fe_st_mel[peak]);

	/* --- 2. full scale must not wrap -------------------------------------- */
	fe_st_tone(fe_st_pcm, FE_FRAME_LEN, 843314856, 32767);
	fe_logmel_frame(fe_st_pcm, &fe_st_scratch, fe_st_mel);
	q = fe_st_mel[peak];
	if (fe_st_mel[peak] < 0) {
		FE_PRINT("FE_SELFTEST fullscale: band %d went negative (%d) -- overflow\n",
			 peak, q);
		fails++;
	}
	/* A 20 dB amplitude step is 20*log2(10)/6.02... -- in log2 power it is exactly
	 * 2*log2(32767/3277) = 6.64, i.e. 1700 in Q8. Allow 200 Q8 (0.78 log2) of slack
	 * for windowing and quantisation; a wrapped accumulator misses by far more. */
	FE_PRINT("FE_SELFTEST fullscale band=%d q8=%d\n", peak, q);

	FE_PRINT("FE_SELFTEST arith=%s nmel=%d nfft=%d fails=%d\n",
		 FE_ARITH_NAME, FE_NMEL, FE_NFFT, fails);
	return fails;
}
