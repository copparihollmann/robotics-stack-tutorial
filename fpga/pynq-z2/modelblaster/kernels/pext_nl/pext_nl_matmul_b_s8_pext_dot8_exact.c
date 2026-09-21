/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_dot8_exact */
/* accuracy_class: bit_exact */
/* origin: patches/0100, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * matmul_b_s8 -- B independent int8 matrix products, which is what multi-head attention
 * lowers to (Q.K^T per head, then probs.V) -- with MBP.DOT8 reductions and an INTEGER
 * requantise that is bit-exact against the reference's float32 tail.
 *
 * REDUCTION.  pext_nl's matmul_s8 kernel (pext_int_requant) takes DOT8 only when K is a
 * multiple of 8 and both operands happen to sit on 8-aligned addresses; Moonshine's head
 * dimension is 36 and its value product reads V by COLUMN, so neither of its attention
 * products would ever reach DOT8 there.  Here each batch's rows are copied once into
 * 8-aligned int64 scratch, zero-padded to a multiple of 8 (a zero lane adds nothing to a
 * dot product): A's M rows of K, and B's N rows of K -- B's own rows when transpose_b,
 * B's COLUMNS otherwise.  Every output element is then ceil(K/8) DOT8s, whatever K is.
 * The copy is (M + N) * K bytes per batch against M * N * K multiply-accumulates.
 *
 * REQUANTISE.  The reference ends in `roundf((float)acc * total)` with total =
 * (sa*sb)/(so*sdiv) in float32, 244 cycles per output element on this core (ROCC_DECOUPLED.md
 * 1.2).  `total` is computed ONCE per dispatch in exact binary32 arithmetic
 * (fpga/pynq-z2/sw/fexact32.h) -- the reference's own four operations -- so it is the
 * reference's `total` bit for bit, (mt, et).  Per element P = |acc| * mt is then the
 * EXACT product the reference rounds to 24 bits: if P is further than (P >> 23) + 1 units
 * from every half-integer of P * 2^et, the float32 rounding cannot move it across one and
 * (P + half) >> -et is the reference's answer; otherwise the element takes the exact
 * binary32 slow path.  One multiply, one shift, one compare and a CLIP8 per element.
 *
 * Accuracy: exact by construction; check_moonshine.py compares it with the reference at
 * Moonshine's attention shapes and scales and at random ones.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "fexact32.h"
#include "pext.h"

#ifndef MBP_MMB_SCRATCH_WORDS
#define MBP_MMB_SCRATCH_WORDS 16384        /* 131 KB of int64 */
#endif

#ifdef FX_STATS
unsigned long pint_mmb_slow_count, pint_mmb_count;
#define PINT_MMB_SLOW() (pint_mmb_slow_count++)
#else
#define PINT_MMB_SLOW() ((void)0)
#endif

static int64_t pmmb_rows_a[MBP_MMB_SCRATCH_WORDS];
static int64_t pmmb_rows_b[MBP_MMB_SCRATCH_WORDS];

static int32_t pmmb_exact(int64_t acc, fx32_t total)
{
	fx32_t fa;

	PINT_MMB_SLOW();
	/* (float)acc: exact below 2^24, rounded above it exactly as the cast rounds */
	fa = fx32_round((unsigned __int128)(uint64_t)(acc < 0 ? -acc : acc), 0, acc < 0, 0);
	return fx32_roundf_i32(fx32_mul(fa, total));
}

#ifndef MBP_MMB_NO_SPECIALIZE
/*
 * THE HOT NEST, on its own, because the allocator could not keep the invariants in registers.
 *
 * Measured before this existed (B51, MATMUL_B_COST.md sections 9-14): the encoder's per-output-
 * element tail was 52.5 cycles for ~38 retired instructions at ~1.38 CPI, and FOURTEEN of those
 * instructions were pure overhead visible in the disassembly -- six `ld`s reloading mt, mask,
 * half (twice) sh and clip8 from the stack, three per-element tests of predicates that cannot
 * change inside a dispatch, an `auipc`/`addi` pair rematerialising the address of pmmb_rows_b
 * (a LINK-TIME CONSTANT) once per element, a spilled row pointer, a `W > 0` test and a jump.
 * The cause is register pressure: kernel_matmul_b_s8 keeps B, M, K, N, transpose_b, four scales,
 * the copy phase's cursors and both operand pointers live across this loop.
 *
 * So the loop every Moonshine attention dispatch actually takes -- use_dot8 && fast && clip8 --
 * gets its own function whose parameter list is exactly what it needs and nothing else.
 *
 * THE ARITHMETIC IS CHARACTER-FOR-CHARACTER THE GENERAL PATH'S, in the same order, including
 * the half-integer guard and the pmmb_exact fallback.  Build with -DMBP_MMB_NO_SPECIALIZE to
 * get the general path alone; samples/roccmoon_bench compiles this file BOTH ways in one image
 * and compares the outputs BYTE FOR BYTE, because a tolerance would hide exactly the kind of
 * mistake a hoist makes.
 */
/*
 * NOINLINE IS LOAD-BEARING, not a hint.  The first build of this fix let gcc inline the nest back
 * into kernel_matmul_b_s8 and the spills came straight back -- the function still reloaded its
 * constants from the frame, because inlining restored exactly the register pressure the split
 * exists to remove.  The isolation IS the optimisation.
 */
#if defined(__GNUC__)
__attribute__((noinline))
#endif
static void pmmb_nest_fast_clip8(const int64_t *ra, const int64_t *rb, int8_t *ob,
				 int M, int N, int W,
				 uint64_t mt, uint64_t half, uint64_t mask, int sh,
				 fx32_t total)
{
	int i, j, w;

	for (i = 0; i < M; i++) {
		const int64_t *wa = ra + (size_t)i * (size_t)W;
		int8_t *orow = ob + (size_t)i * (size_t)N;

		for (j = 0; j < N; j++) {
			const int64_t *wb = rb + (size_t)j * (size_t)W;
			uint64_t P, G;
			int64_t acc = 0, v;

			for (w = 0; w < W; w++) {
				acc += mb_pext_dot8(wa[w], wb[w]);
			}
			P = (uint64_t)(acc < 0 ? -acc : acc) * mt;
			G = (P >> 23) + 1;
			if (((P & mask) - half + G) <= 2 * G) {
				v = pmmb_exact(acc, total);
			} else {
				v = (int64_t)((P + half) >> sh);
				if (acc < 0) {
					v = -v;
				}
			}
			orow[j] = (int8_t)mb_pext_clip8(v);
		}
	}
}
#endif

#ifndef MBP_MMB_NO_M1
/*
 * THE M == 1 PATH: the decoder's shape, where the scratch copy IS the cost.
 *
 * MEASURED, from b56_dec_ship_on's own per-dispatch rows and its disassembly (B59, and
 * MATMUL_B_COST.md part V).  At the DECODER, M = 1: every batch copies (1 + N) rows of K
 * to compute N output elements, so the copy that the header prices at "(M + N) * K bytes
 * per batch against M * N * K multiply-accumulates" is charged ONE-FOR-ONE against each
 * output element instead of being amortised over M of them.  Per output element, counted
 * off the instructions:
 *
 *   B = 8 M = 1 K = 36  N = 165 transpose_b = 1   218 instructions, 159 of them the copy
 *   B = 8 M = 1 K = 165 N = 36  transpose_b = 0  1044 instructions, 846 of them the copy
 *
 * and 132 of that first 159 are inside ONE libc `memcpy` of 36 bytes, which takes its
 * byte-at-a-time path whenever src and dst disagree mod 8 -- five instructions per byte.
 * The five DOT8s that do the arithmetic are 35 of the 218.  This is not a tuning gap.
 *
 * transpose_b = 1 -- B'S ROWS ARE CONTIGUOUS, SO DO NOT COPY THEM AT ALL.
 * The copy exists only to hand DOT8 an 8-aligned operand.  At M = 1 there is exactly ONE
 * row of A, so align A to B instead of B to A: build, per PHASE p = (address & 7), a copy
 * of the single A row placed at byte offset p in a zeroed buffer, then read B in place as
 * ALIGNED 64-bit words.  A word straddling the row boundary carries the neighbouring
 * rows' bytes; they land against the pad's ZERO bytes and contribute nothing, which is
 * the same argument the header makes for the zero lanes of the K-padding.  There are
 * 8 / gcd(K, 8) distinct phases -- TWO at the decoder's K = 36 -- and they are built on
 * first use, so a dispatch with N = 1 builds one.
 *
 * EVERY WORD READ OVERLAPS THE ROW.  Word t covers row bytes [8t - p, 8t + 8 - p) and
 * t < ceil((p + K) / 8), so 8t < p + K and the word holds at least one byte of B.  An
 * aligned 64-bit load of a word containing a live byte cannot cross a page the object
 * does not already own -- the same argument every libc `strlen` rests on.
 *
 * THAT ARGUMENT IS SOUND AND IT IS STILL NOT ENOUGH, because it reads up to seven bytes
 * either side of the B TENSOR, and check_moonshine.py's kernel gate runs these kernels
 * under ASan with deliberately misaligned buffers -- a read that cannot fault on the
 * board would newly fail a gate that exists to catch exactly this class of thing.  So the
 * at most TWO rows per dispatch whose window leaves [b, b + B*K*N) -- the first row of
 * batch 0 and the last row of batch B-1, and only when b is not 8-aligned -- are staged
 * through an aligned buffer instead.  The fast path is then strictly in bounds, and the
 * cost is two `memcpy`s per dispatch against N * B rows.
 *
 * transpose_b = 0 -- B IS READ BY COLUMN, so a gather is unavoidable: the reduction runs
 * down a column and DOT8 needs it contiguous.  What IS avoidable is doing it one byte per
 * five instructions.  The column is packed eight bytes at a time straight into a register
 * and fed to DOT8 without ever touching the scratch: 8 loads, 7 shift/or pairs and one
 * DOT8 per 8 MACs, against 40 gather instructions plus 7 nest instructions before.
 *
 * BIT-EXACTNESS IS BY CONSTRUCTION, not by tolerance.  Both paths accumulate exactly the
 * products a[k] * B[k] over the same k, only in a different ORDER and with different zero
 * lanes; int64 addition is associative and DOT8 is exact (PEXT_SPEC 3.1), so `acc` is the
 * same integer.  The requantise tail below is character-for-character the general path's.
 * Build with -DMBP_MMB_NO_M1=1 to get the copy-and-nest path alone; the host gate and
 * samples/roccmoon_bench compare the two BYTE FOR BYTE.
 *
 * NOINLINE, for the reason the specialised nest already carries: the isolation is the
 * optimisation.
 */
/*
 * ONE OUTPUT ELEMENT THE SLOW, OBVIOUSLY-IN-BOUNDS WAY: B's row copied to aligned scratch
 * and A's row read as zero-padded words.  Used for the handful of rows at each end of the
 * tensor whose aligned window would leave it -- see the bounds note above.
 */
static void pmmb_m1_one(const int8_t *arow, const int8_t *row, int8_t *o, int K,
			uint64_t mt, uint64_t half, uint64_t mask, int sh, fx32_t total)
{
	const int W8 = ((K + 7) / 8) * 8;
	int8_t *st = (int8_t *)pmmb_rows_b;
	uint64_t P, G;
	int64_t acc = 0, v;
	int i;

	for (i = 0; i < K; i++) {
		st[i] = row[i];
	}
	for (i = K; i < W8; i++) {
		st[i] = 0;
	}
	for (i = 0; i < W8 / 8; i++) {
		uint64_t x = 0;
		int u;

		for (u = 0; u < 8 && i * 8 + u < K; u++) {
			x |= (uint64_t)(uint8_t)arow[i * 8 + u] << (8 * u);
		}
		acc += mb_pext_dot8(pmmb_rows_b[i], (int64_t)x);
	}
	P = (uint64_t)(acc < 0 ? -acc : acc) * mt;
	G = (P >> 23) + 1;
	if (((P & mask) - half + G) <= 2 * G) {
		v = pmmb_exact(acc, total);
	} else {
		v = (int64_t)((P + half) >> sh);
		if (acc < 0) {
			v = -v;
		}
	}
	*o = (int8_t)mb_pext_clip8(v);
}

/* does row's aligned read window leave [blo, bhi)? */
static int pmmb_m1_oob(const int8_t *row, int K, const int8_t *blo, const int8_t *bhi)
{
	const unsigned p = (unsigned)((uintptr_t)row & 7u);
	const int8_t *w = (const int8_t *)((uintptr_t)row & ~(uintptr_t)7);

	return w < blo || w + (int)(((unsigned)K + p + 7u) >> 3) * 8 > bhi;
}

/*
 * THE PHASE PADS, BUILT ONCE AND SHIFTED -- B59's own defect, one level in.
 *
 * MEASURED on spike at the decoder's cross-PV shape, B62 (archive/runs/b62_pv_layout/
 * b62_decomp.c, riscv64-zephyr-elf -O2, the board's flags).  Fitting the tb = 1 path's
 * instruction count against N at K = 165 gives 12,919 instructions of FIXED cost per batch
 * plus 178 per output element:
 *
 *      N = 36  536.8 instr/element      N = 72  357.4      N = 288  222.9
 *      fixed 12,919/batch   marginal 178.0/element   (residual < 0.02 %)
 *
 * The fixed part is these pads: L = 8 / gcd(K, 8) of them, each `T*8` byte stores of zero
 * and `K` byte stores of A, at ~4.7 instructions a byte.  At QK^T's K = 36, N = 165 that
 * is 4.8 instructions per output element and invisible -- which is why B59 did not see it.
 * At PV's K = 165, N = 36 it is 359 of the path's 537, SIXTY-SEVEN PER CENT: L is at its
 * largest (K odd, so all eight phases occur) against the smallest N to amortise it over.
 *
 * Phase 0's pad is A gathered into 8-aligned words.  Phase p's pad is THE SAME BYTE STRING
 * MOVED UP p BYTES, and on a little-endian machine that is a 64-bit shift of phase 0's
 * words: byte j of pad_p is A[j - p], so word t is
 *
 *      (q0[t] << 8p) | (q0[t - 1] >> (64 - 8p))
 *
 * -- five instructions a word against K + T*8 byte stores.  BIT-IDENTICAL BY CONSTRUCTION,
 * the same bytes in the same places, and the gate compares all three builds byte for byte
 * over 5,334 shapes and 38,400 exhaustive small ones under ASan+UBSan.
 */
static void pmmb_m1_pad0(int64_t *q0, const int8_t *arow, int K, int T0)
{
	const int full = K >> 3;
	int t, u;

	/* the whole words, with the `t * 8 + u < K` test out of the way -- it was ten
	 * instructions a byte with it in (spike: 90 a word against 25) */
	for (t = 0; t < full; t++) {
		const int8_t *s = arow + (size_t)t * 8;
		uint64_t x;

		x  = (uint64_t)(uint8_t)s[0];
		x |= (uint64_t)(uint8_t)s[1] << 8;
		x |= (uint64_t)(uint8_t)s[2] << 16;
		x |= (uint64_t)(uint8_t)s[3] << 24;
		x |= (uint64_t)(uint8_t)s[4] << 32;
		x |= (uint64_t)(uint8_t)s[5] << 40;
		x |= (uint64_t)(uint8_t)s[6] << 48;
		x |= (uint64_t)(uint8_t)s[7] << 56;
		q0[t] = (int64_t)x;
	}
	for (t = full; t < T0; t++) {
		uint64_t x = 0;

		for (u = 0; u < 8 && t * 8 + u < K; u++) {
			x |= (uint64_t)(uint8_t)arow[t * 8 + u] << (8 * u);
		}
		q0[t] = (int64_t)x;
	}
	/* one zero word past the end, so the shifted phases read q0[T0] without a test */
	q0[T0] = 0;
}

static void pmmb_m1_padp(int64_t *qp, const int64_t *q0, int Tp, unsigned p)
{
	const unsigned s = 8u * p;                  /* p >= 1 here, so s is 8..56 */
	uint64_t prev = 0;
	int t;

	for (t = 0; t < Tp; t++) {
		const uint64_t cur = (uint64_t)q0[t];

		qp[t] = (int64_t)((cur << s) | (prev >> (64u - s)));
		prev = cur;
	}
}

#ifndef MBP_B84
#define MBP_B84 0
#endif
#ifndef MBP_B84_POISON
#define MBP_B84_POISON 0
#endif

#if MBP_B84
/*
 * B84 -- THE SEVEN SHIFTED PASSES, INTERCHANGED.  MATMUL_B_COST.md section 32.8 item 1
 * priced this and did not build it, because section 32.6 had just measured an
 * instruction-only lever on this op transferring at ZERO.  B82 measured that same lever
 * again on 0x5A5A002F and it transfers at 0.86-1.25, so the item is re-opened; see
 * B84_BAND.md.
 *
 * WHAT IT IS.  pmmb_m1_padp above is called once per phase, and each call walks q0 from
 * the top: `for p { for t }`.  Every pass reloads the same T words of q0 and pays its own
 * loop bookkeeping.  Interchanging the two loops -- `for t { for p }` with p fully
 * unrolled -- loads q0[t] ONCE and keeps q0[t-1] in a register for all seven destinations.
 * Section 32.8 costed a binary-doubling cascade (4 + 2 + 1 destinations per pass) at
 * 1,514 -> 1,017 instructions at T = 22; the interchange is cheaper than that cascade
 * because the cascade still reloads its own intermediate phases.  The number that decides
 * it is measured, not argued: see b84_icount.sh.
 *
 * BIT-IDENTICAL, AND NOT BY AN ASSOCIATIVITY ARGUMENT.  Destination p receives exactly
 * pmmb_m1_padp's expression, `(q0[t] << 8p) | (q0[t-1] >> (64 - 8p))`, with q0[-1] taken
 * as zero -- the same words, in the same places, from the same source.  Nothing is
 * reassociated and nothing is recomputed from a shifted copy.
 *
 * WIDTH.  Phase p is read only for t < Tp = (K + p + 7) >> 3, and Tp is monotone in p, so
 * every phase is written to T7 = (K + 14) >> 3 words and the wider ones are never read
 * past their own Tp.  q0 carries T0 + 1 valid words (pmmb_m1_pad0 writes the zero word at
 * q0[T0]) and T7 <= T0 + 1 for every K, so the source is in range.  The caller's own
 * precondition at the bottom of this file already requires 8 * qstride words of
 * pmmb_rows_a, and the highest index written here is 7 * qstride + T7 - 1 <= 8*qstride - 2.
 *
 * WHEN.  Only when all eight phases are wanted -- L == 8 and at least eight rows inside
 * the window.  Below that the lazy per-phase path builds fewer than seven and wins.
 */
static void pmmb_m1_padall8(int64_t *q, size_t qstride, int T7)
{
	int64_t *const q1 = q + qstride;
	int64_t *const q2 = q1 + qstride;
	int64_t *const q3 = q2 + qstride;
	int64_t *const q4 = q3 + qstride;
	int64_t *const q5 = q4 + qstride;
	int64_t *const q6 = q5 + qstride;
	int64_t *const q7 = q6 + qstride;
	uint64_t prev = 0;
	int t;

	for (t = 0; t < T7; t++) {
		const uint64_t cur = (uint64_t)q[t];

		q1[t] = (int64_t)((cur <<  8) | (prev >> 56));
		q2[t] = (int64_t)((cur << 16) | (prev >> 48));
		q3[t] = (int64_t)((cur << 24) | (prev >> 40));
		q4[t] = (int64_t)((cur << 32) | (prev >> 32));
		q5[t] = (int64_t)((cur << 40) | (prev >> 24));
		q6[t] = (int64_t)((cur << 48) | (prev >> 16));
#if MBP_B84_POISON == 1
		/* the last destination built from the WRONG source word: visible in the
		 * output of every dispatch whose phase-7 class is non-empty */
		q7[t] = (int64_t)((cur << 56) | (prev >> 16));
#elif MBP_B84_POISON == 2
		/* one byte short: phase 7 becomes phase 6 */
		q7[t] = (int64_t)((cur << 48) | (prev >> 16));
#else
		q7[t] = (int64_t)((cur << 56) | (prev >>  8));
#endif
		prev = cur;
	}
}
#endif /* MBP_B84 */

/*
 * PHASE STRATIFICATION, which is what makes the loop cheap rather than merely copy-free.
 * Written the obvious way -- compute p, T and the pad pointer from the row address each
 * time round -- the j-loop carries 24 instructions of bookkeeping per output element
 * (an `auipc`/`addi` pair rematerialising pmmb_rows_a, a `mul` by the pad stride, the
 * built-yet test and six for the bounds test), which is the same defect section 10 of
 * MATMUL_B_COST.md found in the old tail.  But the phase only takes 8 / gcd(K, 8) values
 * and they repeat: row j and row j + L share a phase, where L = 8 / gcd(K, 8), and
 * L * K is a multiple of 8 by construction.  So walk each phase CLASS -- j, j+L, j+2L --
 * with p, T, the pad pointer and the word count all loop-invariant and the row pointer
 * advancing by the constant L * K bytes.  Nothing per element but the DOT8s and the tail.
 */
#if defined(__GNUC__)
__attribute__((noinline))
#endif
static void pmmb_m1_rows(const int8_t *arow, const int8_t *brows, int8_t *ob,
			 int K, int N, const int8_t *blo, const int8_t *bhi,
			 uint64_t mt, uint64_t half, uint64_t mask, int sh,
			 fx32_t total)
{
	const size_t qstride = (size_t)((K + 14) / 8) + 1;
	const int T0 = (K + 7) >> 3;
	int g = K & -K, L, lo = 0, hi = N, r;
	unsigned built = 0;

	if (g > 8) {
		g = 8;
	}
	L = 8 / g;

	/*
	 * Windows are monotone in j at BOTH ends, so the rows that leave the tensor form a
	 * prefix and a suffix -- not just one row each, because at K < 8 several rows share
	 * one word.  Walk each end until it is inside; the interior then needs no bounds
	 * test at all.  At the decoder's K this stages nothing or one row per end.
	 */
	while (lo < hi && pmmb_m1_oob(brows + (size_t)lo * (size_t)K, K, blo, bhi)) {
		pmmb_m1_one(arow, brows + (size_t)lo * (size_t)K, ob + lo, K,
			    mt, half, mask, sh, total);
		lo++;
	}
	while (hi > lo && pmmb_m1_oob(brows + (size_t)(hi - 1) * (size_t)K, K, blo, bhi)) {
		hi--;
		pmmb_m1_one(arow, brows + (size_t)hi * (size_t)K, ob + hi, K,
			    mt, half, mask, sh, total);
	}

	for (r = 0; r < L; r++) {
		int j = lo + r;
		const int8_t *row;
		const int64_t *q, *wb;
		unsigned p;
		int T;

		if (j >= hi) {
			break;
		}
		row = brows + (size_t)j * (size_t)K;
		p = (unsigned)((uintptr_t)row & 7u);
		T = (int)(((unsigned)K + p + 7u) >> 3);
		q = pmmb_rows_a + (size_t)p * qstride;
		wb = (const int64_t *)((uintptr_t)row & ~(uintptr_t)7);
		if (!(built & (1u << p))) {
			if (!(built & 1u)) {
				pmmb_m1_pad0(pmmb_rows_a, arow, K, T0);
				built |= 1u;
			}
#if MBP_B84
			if (L == 8 && hi - lo >= 8) {
				pmmb_m1_padall8(pmmb_rows_a, qstride,
						(int)(((unsigned)K + 14u) >> 3));
				built = 0xffu;
			} else
#endif
			if (p != 0u) {
				pmmb_m1_padp(pmmb_rows_a + (size_t)p * qstride,
					     pmmb_rows_a, T, p);
			}
			built |= 1u << p;
		}
		for (; j < hi; j += L) {
			uint64_t P, G;
			int64_t acc = 0, v;

#ifndef MBP_MMB_M1_UNROLL8
			int t;

			for (t = 0; t < T; t++) {
				acc += mb_pext_dot8(wb[t], q[t]);
			}
#else
			/*
			 * THE DOT8 LOOP'S OWN BOOKKEEPING -- MEASURED, BANKED AS A FINDING,
			 * AND SHIPPED OFF.  Read the verdict before the mechanism.
			 *
			 * B68 (MATMUL_B_COST.md section 32) unrolled this loop and put it on the
			 * board as its own arm against a control differing in nothing else.
			 * It removed 4,681,354 cycles from matmul_b_s8 -- a real 10.9 % of the
			 * op -- and the decoder's steady_cycles moved by +43,729, which is
			 * +0.019 %.  NOTHING.  `linear_s8` took +4,605,541 in the same pair:
			 * 98.4 % of the saving went straight back to the engine, whose fill rate
			 * fell 0.8645 -> 0.8300 beats/cycle on IDENTICAL `fill_beats`.
			 *
			 * That is section 30.2's discriminator at its limit.  This change removes
			 * ONLY `addi` and `bne`: every load, every store and every byte is
			 * identical, so all it does is issue hart 0's loads more densely -- the
			 * B56 case, which transferred at 0.33, taken to the extreme where it
			 * transfers at ZERO.  On this decoder, on this bitstream, a hart-0 lever
			 * that moves no bytes is worth nothing end to end.
			 *
			 * SO IT IS OFF.  -DMBP_MMB_M1_UNROLL8=1 turns it on, and it is kept
			 * rather than deleted because the op-level win is real and would be
			 * collectable on a configuration that is not fill-bound.
			 *
			 * WHAT IT DOES, counted off objdump.  One word of the rolled loop above
			 * costs SEVEN instructions:
			 *
			 *   ld wb[t] / addi / ld q[t] / addi / DOT8 / add acc / bne
			 *
			 * and THREE of the seven are bookkeeping -- 43 % of this op's marginal
			 * cost.  One output element is 4 + 7*T + 23; at K = 165 the phases give
			 * T = 21.5, so 4 + 150.5 + 23 = 177.5 against the 178.0 that a least
			 * squares fit against N measures.  Walking pointers and unrolling by
			 * eight makes the body 16 ld + 8 DOT8 + 8 add + 2 addi + 1 bne = 35 for
			 * 8 words, 4.375 apiece, with no spills.
			 *
			 * The remainder is a 1/2/4 CASCADE and not a trailing rolled loop: a
			 * trailing loop costs TEN instructions a word because it re-derives both
			 * addresses from the index, and at QK^T's T = 5 that ate the whole gain
			 * (spike: plain unroll-by-4 plus a trailing loop is -2.3 % at K = 36
			 * against this form's -18.8 %).  T is loop-invariant inside a phase
			 * class, so the three cascade branches predict perfectly.
			 *
			 * BIT-IDENTICAL, and not by an associativity argument: the head takes
			 * words 0..r-1 and the unrolled loop r..T-1, so `acc` receives the same
			 * int64 addends in the same ORDER as the rolled loop.  Both gates compare
			 * the two builds byte for byte over 5,335 shapes and 38,400 exhaustive
			 * small ones under ASan+UBSan.
			 *
			 * Measured on spike at the board's own flags, instructions per element:
			 *
			 *   cross PV   K = 165 N = 36  tb = 1   256.87 -> 205.67   -19.9 %
			 *   cross QK^T K = 36  N = 165 tb = 1    66.29 ->  53.81   -18.8 %
			 *   self QK^T  K = 36  N = 24  tb = 1    88.90 ->  76.65   -13.8 %
			 *
			 * and on the board, cycles per element (B68 arms B -> C):
			 *
			 *   cross PV   391.10 -> 353.39   -9.6 %   CPI 1.520 -> 1.736
			 *   cross QK^T 100.83 ->  85.26  -15.4 %   CPI 1.498 -> 1.582
			 *
			 * -- the cycles fall by less than the instructions because what is left
			 * is loads, which is the same thing the engine saw.
			 */
			{
				const int64_t *pw = wb, *pq = q;
				int n = T;

				if (n & 1) {
					acc += mb_pext_dot8(pw[0], pq[0]);
					pw++; pq++;
				}
				if (n & 2) {
					acc += mb_pext_dot8(pw[0], pq[0]);
					acc += mb_pext_dot8(pw[1], pq[1]);
					pw += 2; pq += 2;
				}
				if (n & 4) {
					acc += mb_pext_dot8(pw[0], pq[0]);
					acc += mb_pext_dot8(pw[1], pq[1]);
					acc += mb_pext_dot8(pw[2], pq[2]);
					acc += mb_pext_dot8(pw[3], pq[3]);
					pw += 4; pq += 4;
				}
				for (n >>= 3; n > 0; n--) {
					acc += mb_pext_dot8(pw[0], pq[0]);
					acc += mb_pext_dot8(pw[1], pq[1]);
					acc += mb_pext_dot8(pw[2], pq[2]);
					acc += mb_pext_dot8(pw[3], pq[3]);
					acc += mb_pext_dot8(pw[4], pq[4]);
					acc += mb_pext_dot8(pw[5], pq[5]);
					acc += mb_pext_dot8(pw[6], pq[6]);
					acc += mb_pext_dot8(pw[7], pq[7]);
					pw += 8; pq += 8;
				}
			}
#endif
			P = (uint64_t)(acc < 0 ? -acc : acc) * mt;
			G = (P >> 23) + 1;
			if (((P & mask) - half + G) <= 2 * G) {
				v = pmmb_exact(acc, total);
			} else {
				v = (int64_t)((P + half) >> sh);
				if (acc < 0) {
					v = -v;
				}
			}
			ob[j] = (int8_t)mb_pext_clip8(v);
			wb = (const int64_t *)((const int8_t *)wb + (size_t)L * (size_t)K);
		}
	}
}

#if defined(__GNUC__)
__attribute__((noinline))
#endif
static void pmmb_m1_cols(const int64_t *wa, const int8_t *bb, int8_t *ob,
			 int K, int N,
			 uint64_t mt, uint64_t half, uint64_t mask, int sh,
			 fx32_t total)
{
	const size_t st = (size_t)N;
	int j;

	for (j = 0; j < N; j++) {
		const int8_t *p = bb + j;
		uint64_t P, G;
		int64_t acc = 0, v;
		int k = 0, w = 0;

		for (; k + 8 <= K; k += 8, w++) {
			uint64_t x;

			x  = (uint64_t)(uint8_t)p[0];
			x |= (uint64_t)(uint8_t)p[st] << 8;
			x |= (uint64_t)(uint8_t)p[st * 2] << 16;
			x |= (uint64_t)(uint8_t)p[st * 3] << 24;
			x |= (uint64_t)(uint8_t)p[st * 4] << 32;
			x |= (uint64_t)(uint8_t)p[st * 5] << 40;
			x |= (uint64_t)(uint8_t)p[st * 6] << 48;
			x |= (uint64_t)(uint8_t)p[st * 7] << 56;
			acc += mb_pext_dot8((int64_t)x, wa[w]);
			p += st * 8;
		}
		if (k < K) {
			uint64_t x = 0;
			int i;

			for (i = 0; k + i < K; i++) {
				x |= (uint64_t)(uint8_t)p[st * (size_t)i] << (8 * i);
			}
			acc += mb_pext_dot8((int64_t)x, wa[w]);
		}
		P = (uint64_t)(acc < 0 ? -acc : acc) * mt;
		G = (P >> 23) + 1;
		if (((P & mask) - half + G) <= 2 * G) {
			v = pmmb_exact(acc, total);
		} else {
			v = (int64_t)((P + half) >> sh);
			if (acc < 0) {
				v = -v;
			}
		}
		ob[j] = (int8_t)mb_pext_clip8(v);
	}
}
#endif  /* MBP_MMB_NO_M1 */

void kernel_matmul_b_s8(const int8_t *a, const int8_t *b, int8_t *output,
			int B, int M, int K, int N,
			float scale_a, float scale_b, float scale_out,
			int transpose_b, float scale_div,
			int activation_min, int activation_max)
{
	const fx32_t sa = fx32_dec(scale_a), sb = fx32_dec(scale_b);
	const fx32_t so = fx32_dec(scale_out), sd = fx32_dec(scale_div);
	const int W = (K + 7) / 8;
	const int use_dot8 = (size_t)M * (size_t)W <= MBP_MMB_SCRATCH_WORDS
			     && (size_t)N * (size_t)W <= MBP_MMB_SCRATCH_WORDS;
	const int clip8 = activation_min == -128 && activation_max == 127;
	fx32_t total;
	uint64_t mt = 0, half = 0, mask = 0;
	int sh = 0, fast = 0, bi, i, j, k;
#ifndef MBP_MMB_NO_M1
	int m1;
#endif

	if (fx32_scale_ok(sa) && fx32_scale_ok(sb) && fx32_scale_ok(so) && fx32_scale_ok(sd)) {
		total = fx32_div(fx32_mul(sa, sb), fx32_mul(so, sd));
		mt = total.m;
		sh = -total.e;
		/* K <= 1024 keeps |acc| <= K * 2^14 below 2^24, where (float)acc is exact and
		 * P = |acc| * mt (< 2^48) is the exact product the reference rounds. */
		fast = mt != 0 && sh >= 2 && sh <= 62 && K <= 1024;
		if (fast) {
			half = (uint64_t)1 << (sh - 1);
			mask = ((uint64_t)1 << sh) - 1;
		}
	} else {
		/* outside the exact helper's domain: nothing here to be exact against */
		total = fx32_div(fx32_mul(sa, sb), fx32_mul(so, sd));
	}
#ifndef MBP_MMB_NO_M1
	/* the decoder's shape, and the only one where the copy outweighs the arithmetic */
	m1 = M == 1 && use_dot8 && fast && clip8
	     && (size_t)8 * ((size_t)((K + 14) / 8) + 1) <= (size_t)MBP_MMB_SCRATCH_WORDS;
#endif
#ifdef FX_STATS
	pint_mmb_count += (unsigned long)B * (unsigned long)M * (unsigned long)N;
#endif

	for (bi = 0; bi < B; bi++) {
		const int8_t *ab = a + (size_t)bi * (size_t)M * (size_t)K;
		const int8_t *bb = b + (size_t)bi * (size_t)K * (size_t)N;
		int8_t *ob = output + (size_t)bi * (size_t)M * (size_t)N;

#ifndef MBP_MMB_NO_M1
		if (m1) {
			if (transpose_b) {
				/* B's rows are contiguous: read them in place, no copy at all */
				pmmb_m1_rows(ab, bb, ob, K, N,
					     b, b + (size_t)B * (size_t)K * (size_t)N,
					     mt, half, mask, sh, total);
			} else {
				/* B is read by column: pack the column into the register DOT8
				 * wants, and leave the scratch out of it.  A's one row still
				 * goes to 8-aligned scratch -- K bytes per batch, not N * K. */
				int8_t *ra = (int8_t *)pmmb_rows_a;

				memcpy(ra, ab, (size_t)K);
				memset(ra + K, 0, (size_t)W * 8 - (size_t)K);
				pmmb_m1_cols(pmmb_rows_a, bb, ob, K, N,
					     mt, half, mask, sh, total);
			}
			continue;
		}
#endif
		if (use_dot8) {
			int8_t *ra = (int8_t *)pmmb_rows_a;
			int8_t *rb = (int8_t *)pmmb_rows_b;
			const size_t K8 = (size_t)W * 8;

			for (i = 0; i < M; i++) {
				memcpy(ra + (size_t)i * K8, ab + (size_t)i * (size_t)K, (size_t)K);
				memset(ra + (size_t)i * K8 + (size_t)K, 0, K8 - (size_t)K);
			}
			for (j = 0; j < N; j++) {
				int8_t *row = rb + (size_t)j * K8;

				if (transpose_b) {
					memcpy(row, bb + (size_t)j * (size_t)K, (size_t)K);
				} else {
					for (k = 0; k < K; k++) {
						row[k] = bb[(size_t)k * (size_t)N + (size_t)j];
					}
				}
				memset(row + K, 0, K8 - (size_t)K);
			}
		}
#ifndef MBP_MMB_NO_SPECIALIZE
		if (use_dot8 && fast && clip8) {
			pmmb_nest_fast_clip8(pmmb_rows_a, pmmb_rows_b, ob, M, N, W,
					     mt, half, mask, sh, total);
			continue;
		}
#endif
		for (i = 0; i < M; i++) {
			const int64_t *wa = pmmb_rows_a + (size_t)i * (size_t)W;

			for (j = 0; j < N; j++) {
				int64_t acc = 0, v;

				if (use_dot8) {
					const int64_t *wb = pmmb_rows_b + (size_t)j * (size_t)W;
					int w;

					for (w = 0; w < W; w++) {
						acc += mb_pext_dot8(wa[w], wb[w]);
					}
				} else {
					for (k = 0; k < K; k++) {
						const int8_t av = ab[(size_t)i * (size_t)K + k];
						const int8_t bv = transpose_b ? bb[(size_t)j * (size_t)K + k]
									      : bb[(size_t)k * (size_t)N + j];
						acc += (int32_t)av * (int32_t)bv;
					}
				}
				if (fast) {
					const uint64_t P = (uint64_t)(acc < 0 ? -acc : acc) * mt;
					const uint64_t G = (P >> 23) + 1;

					if (((P & mask) - half + G) <= 2 * G) {
						v = pmmb_exact(acc, total);
					} else {
						v = (int64_t)((P + half) >> sh);
						if (acc < 0) {
							v = -v;
						}
					}
				} else {
					v = pmmb_exact(acc, total);
				}
				if (clip8) {
					ob[(size_t)i * (size_t)N + j] = (int8_t)mb_pext_clip8(v);
				} else {
					if (v < activation_min) v = activation_min;
					if (v > activation_max) v = activation_max;
					ob[(size_t)i * (size_t)N + j] = (int8_t)v;
				}
			}
		}
	}
}
