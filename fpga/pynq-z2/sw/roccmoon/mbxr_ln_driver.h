/* SPDX-License-Identifier: Apache-2.0 */
/*
 * THE SHARED LayerNorm LANE DRIVER: tiling, padding, staging, the fill/drain plan and the
 * copy-out for ONE LayerNorm, over however many lane dispatches the 1,024-word activation
 * buffer forces.  Included by BOTH `layernorm_pc_s8` and `layernorm_s8`, which differ only in
 * where their affine table comes from, so there is ONE copy of this and not two.
 *
 * SEPARATE FROM roccmoon_ln_derive.inc ON PURPOSE.  That file is pure arithmetic and depends on
 * nothing, which is what lets moonshine/ln_pt_check.py compile it against the tree's own
 * pext_int_rsqrt kernel in one harness and diff the two cores at every site of a real graph.
 * This file needs the runtime.  A derivation that can only be tested inside a kernel is a
 * derivation nobody tests.
 *
 * The lane PROTOCOL -- SD/LD/fence/cfg/ST/arm/go/wait -- is NOT here either: it is
 * mbxr_ln_dispatch's, in sw/roccmoon/, where the attention and LUT lanes reach it too.
 */
#ifndef MBXR_LN_DRIVER_H
#define MBXR_LN_DRIVER_H

#include "roccmoon/mbxr_ln_derive.h"

/* ===== the shared driver, factored out of roccmoon_layernorm_pc_s8_roccmoon_lane.c ===== */

/* The fallback IS the reference: no curated kernel exists for this op (Lab B30 runs it as
 * "reference C"), so there is nothing else to fall back to and nothing else to be exact against. */
#ifndef MB_Q16_NORM_CORE
#define MB_Q16_NORM_CORE
/* floor(sqrt(v)), bit by bit */
static inline unsigned __int128 mb_q16_isqrt128(unsigned __int128 v) {
    unsigned __int128 r = 0, bit = (unsigned __int128)1 << 126;
    while (bit > v) bit >>= 2;
    while (bit) {
        if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; }
        else r >>= 1;
        bit >>= 2;
    }
    return r;
}
/* R = isqrt(floor(2^120 / V)), V = K*Q - S^2 + eps_q > 0 */
static inline int64_t mb_q16_norm_r(int64_t K, int64_t S, __int128 Q, int64_t eps_q) {
    __int128 V = (__int128)K * Q - (__int128)S * (__int128)S + (__int128)eps_q;
    return (int64_t)mb_q16_isqrt128(((unsigned __int128)1 << 120) / (unsigned __int128)V);
}
/* t = floor((K*u - S) * R / 2^44), then out = floor((t*g + b*2^16 + 2^31) / 2^32) */
static inline int64_t mb_q16_norm_out(int64_t K, int64_t u, int64_t S, int64_t R,
                                      int64_t g, int64_t b) {
    __int128 d = (__int128)K * (__int128)u - (__int128)S;
    int64_t t = (int64_t)((d * (__int128)R) >> 44);
    return (t * g + b * 65536 + ((int64_t)1 << 31)) >> 32;
}
#endif

static void mbxr_ln_reference(const int8_t *input, const int32_t *umul, const int64_t *gmul,
			      const int64_t *badd, int8_t *output, int M, int K, int64_t eps_q)
{
	for (int m = 0; m < M; m++) {
		const int8_t *x = input + (size_t)m * (size_t)K;
		int8_t *y = output + (size_t)m * (size_t)K;
		int64_t S = 0;
		__int128 Q = 0;
		for (int k = 0; k < K; k++) {
			const int64_t u = (int64_t)x[k] * (int64_t)umul[k];
			S += u;
			Q += (__int128)u * (__int128)u;
		}
		const int64_t R = mb_q16_norm_r(K, S, Q, eps_q);
		for (int k = 0; k < K; k++) {
			int64_t v = mb_q16_norm_out(K, (int64_t)x[k] * (int64_t)umul[k], S, R,
						    gmul[k], badd[k]);
			if (v < -128) v = -128;
			if (v > 127) v = 127;
			y[k] = (int8_t)v;
		}
	}
}

/* Defined on the host too, deliberately: it is one of the three things the host check can prove
 * without a board, and a predicate that is only compiled for the target is a predicate nobody
 * tests.  The per-channel constants must fit the lane's table fields, and a model whose constants do not
 * is a fallback rather than a wrong answer.  umul is 25 bits, K*umul 40, gmul and badd 32 --
 * mbxr_ln.v's map.  Moonshine's worst is well inside (LAYERNORM_LANE.md section 2's bit-lengths),
 * but checking costs K comparisons once per dispatch and a silent overflow costs a transcript. */
static int mbxr_ln_consts_fit(const int32_t *umul, const int64_t *gmul, const int64_t *badd,
			      int K)
{
	for (int k = 0; k < K; k++) {
		int64_t ku = (int64_t)K * (int64_t)umul[k];
		if (umul[k] < 0 || umul[k] >= (1 << 25))
			return 0;
		if (ku < 0 || ku >= ((int64_t)1 << 40))
			return 0;
		if (gmul[k] < -(int64_t)0x80000000 || gmul[k] > (int64_t)0x7fffffff)
			return 0;
		if (badd[k] < -(int64_t)0x80000000 || badd[k] > (int64_t)0x7fffffff)
			return 0;
	}
	return 1;
}

/* Rows per tile after both bounds: the 1,024-word reach and the whole-drain-block rule.  Exposed
 * so the host check can test the kernel's ACTUAL accept/reject decision rather than the reach
 * predicate alone -- they differ, and the difference is the limitation above. */
static int mbxr_ln_tile_rows(int M, int K)
{
	int rows = 0, tiles = 0;

	if (mbxr_ln_plan(M, K, 0, 0, &rows, &tiles) != MBXR_OK)
		return 0;
	return rows;
}

/* THE COPY THAT IS LEFT, 8 BYTES AT A TIME.  Lab B38 measured the byte-at-a-time version at
 * 7.43 cycles per byte over 55,008 bytes per dispatch -- 408,513 of 562,062 cycles, 72.7 % of
 * the whole operator, against 24.2 % for the lane itself.  On an in-order LITTLE core reading a
 * DMA destination in DRAM the cost is per ACCESS, so the fix is to make eight times fewer of
 * them; it is not a memcpy because nothing here should depend on what the libc lowering does.
 * Both ends are 8-byte aligned in practice -- MBXR_RT_SCRATCH is 64-byte aligned by
 * construction and a tile offset m0*K is a multiple of 8,064 -- but the alignment is TESTED
 * rather than assumed, because the buffers come from a generator this kernel does not control
 * and an unaligned 64-bit store on this core is a trap, not a slow path. */
__attribute__((unused)) static void mbxr_ln_copy(int8_t *d, const int8_t *s, long n)
{
	long i = 0;

	if (((((uintptr_t)d) | ((uintptr_t)s)) & 7u) == 0u) {
		uint64_t *d8 = (uint64_t *)(void *)d;
		const uint64_t *s8 = (const uint64_t *)(const void *)s;
		long n8 = n >> 3;

		for (i = 0; i < n8; i++)
			d8[i] = s8[i];
		i = n8 << 3;
	}
	for (; i < n; i++)
		d[i] = s[i];
}

/* THE A/B SWITCH.  -DMBXR_LN_LANE=0 forces the fallback, so the two arms of the board comparison
 * differ in exactly one define and in nothing else -- same image, same graph, same everything
 * around it.  The lane-off arm is also the KNOWN-ANSWER CONTROL: it runs the reference, which is
 * what Lab B30 measured for this op, so it must reproduce that rate.  Two arms wrong in the same
 * way is the failure a control exists to catch, and an A/B without one cannot see it. */
#ifndef MBXR_LN_LANE
#define MBXR_LN_LANE 1
#endif

/* HW IS 1, NOT K.  The lane's affine index is `c = floor(pos / HW)` and this op's index is `k`
 * (LAYERNORM_LANE.md s1's table: layernorm_pc_s8 -> c = k; s5's parameter table gives HW = 1 for
 * LayerNorm and 999 for GroupNorm).  Passing HW = K sends every element to affine index 0, which
 * is a plausible-looking wrong answer rather than an error: the first board run produced 159
 * dispatches, the right number of bytes, and max_abs_err = 52.  It is written as a named constant
 * because "1" at a call site looks like a placeholder. */
#define MBXR_LN_HW_PC 1

/* THE SHARED PER-OP DRIVER.  Tiling, padding, staging, the fill/drain plan and the copy-out
 * for ONE LayerNorm, over however many lane dispatches the 1,024-word buffer forces.  It is
 * static and lives here so that BOTH kernels -- per-channel `layernorm_pc_s8` and per-tensor
 * `layernorm_s8`, which differ only in where their table comes from -- drive the lane through
 * ONE copy.  The lane PROTOCOL below it (SD/LD/fence/cfg/ST/arm/go/wait) is mbxr_ln_dispatch's
 * and is not copied here either.  Trying the obvious alternative is how this shape was found:
 * a kernel that calls the other kernel does not link when a graph selects only one of them,
 * and #including it duplicates the entry point when a graph selects both. */
static void mbxr_ln_run(const int8_t *input, const int32_t *umul, const int64_t *gmul,
			const int64_t *badd, int8_t *output, int M, int K, int64_t eps_q)
{
#if defined(__ZEPHYR__) && MBXR_LN_LANE
	int rows_per_tile = 0, tiles = 0;

	rows_per_tile = mbxr_ln_tile_rows(M, K);
	(void)tiles;
	if (mbxr_rt_available() &&
	    mbxr_ln_cfg_ok(K, MBXR_LN_HW_PC, (uint64_t)eps_q, 0) == MBXR_OK &&
	    mbxr_ln_consts_fit(umul, gmul, badd, K)) {
		if (rows_per_tile > 0) {
			int ok = 1;

			/* THE AFFINE TABLE IS WRITTEN BY THE WORKER, NOT HERE.  `lcfg` is custom-1
			 * and custom-1 is in hart 1's tile: an earlier version of this loop ran on
			 * hart 0 and trapped with mcause 2 at mtval 0x12b5302b, which is lcfg's own
			 * instruction word.  It is passed with the first tile and written once per
			 * dispatch -- 5K writes, ~33 % of a 165-row dispatch at K = 288, and
			 * unavoidable because each of the 13 layernorms has its own constants. */
			for (int m0 = 0; m0 < M && ok; m0 += rows_per_tile) {
				int rows = M - m0;
				if (rows > rows_per_tile) rows = rows_per_tile;
				/* PAD THE TILE TO A WHOLE NUMBER OF DRAIN BLOCKS BY ADDING ROWS.
				 * A tile whose byte count is not a multiple of 64 HANGS: the lane
				 * produces rows*K bytes, the drain waits for the rest of the last
				 * block, the packer backpressures, the streamer stops, and ownership
				 * never returns.  Reproduced in simulation at 25 rows and at 1 row;
				 * whole-block tiles (28, 2) are bit-exact.
				 * Padding with ROWS rather than bytes is what makes this free: each
				 * row is normalised independently, so an extra zero row cannot affect
				 * any real row's output -- it is computed and discarded.  A zero row
				 * is well defined, since V = eps_q > 0. */
				int pad_rows = rows;
				while (((long)pad_rows * K) % 64)
					pad_rows++;
				long bytes = (long)rows * K;
				long pad_bytes = (long)pad_rows * K;
				long blocks = pad_bytes / 64;
				uint64_t src = (uint64_t)(uintptr_t)(input + (size_t)m0 * K);

				/* THE FILL does not tolerate one: MBXR_SD moves whole 64-byte
				 * blocks, so a tile that is not a whole number of them would be
				 * under-filled by up to 56 bytes.  Stage it zero-padded, exactly
				 * as the linear kernel stages unaligned input.  M = 165 at K = 288
				 * makes this the COMMON case, not the corner: 165 is odd and
				 * 288 x odd is never a multiple of 64, so the last tile of every
				 * encoder layernorm lands here.  Requiring whole blocks instead
				 * would have made the whole dispatch fall back, silently. */
				/* STAGE WHEN THE TILE IS PADDED **OR** WHEN THE SOURCE IS NOT
				 * 64-BYTE ALIGNED.  mbxd_dma.v:71 takes "the byte address of the
				 * first block, 64-byte aligned" and :38 says there is no byte
				 * funnel, so a misaligned source is read as whatever the enclosing
				 * block holds -- a plausible wrong answer, not an error.  Only the
				 * padded tile used to be staged, so on this model FIVE TILES IN SIX
				 * filled from an address 8, 24, 40 or 56 bytes into a block
				 * (generate_skeleton.py emits the intermediates 8-byte aligned).
				 * mbxr_ln_dispatch now REFUSES an unaligned fill, so getting this
				 * predicate wrong is a fallback rather than a transcript. */
				if (pad_rows != rows || (((uintptr_t)src) & 63u)) {
					int8_t *stg = (int8_t *)MBXR_RT_IN_STAGE;
					const int8_t *isrc = input + (size_t)m0 * K;
					if (pad_bytes + 64 > (8L << 20)) { ok = 0; break; }
					mbxr_ln_copy(stg, isrc, bytes);
					for (long i = bytes; i < pad_bytes; i++) stg[i] = 0;
					src = MBXR_RT_IN_STAGE;
				}
				/* every count is now the PADDED one and they agree: pad_rows rows of
				 * K elements, pad_bytes/8 words, pad_bytes/64 whole blocks.  Only the
				 * copy-out below takes the real row count. */
				/* WHERE THE DRAIN LANDS, which Lab B38 measured as 72.7 % of the dispatch.
				 * The lane's output is ALREADY in row order -- unlike the engine's, which is
				 * tile-ordered and must be permuted -- so the scratch buffer buys nothing but
				 * a copy.  Point the drain at the caller's own rows when it legally can:
				 *   * the tile must not be padded, or the drain's whole 64-byte blocks would
				 *     write up to 56 bytes PAST this tile's rows (and past the tensor, on the
				 *     last tile of all); and
				 *   * the destination must be 64-byte aligned, which mbxr.c:245 enforces for
				 *     the engine's own drain (MBXR_E_ALIGN) and the lane inherits.
				 * MEASURED, NOT ASSUMED: generate_skeleton.py emits the intermediate buffers
				 * as plain arrays and this model's land 8-byte aligned (mod 64 = 8, 24, 40,
				 * 56 for the four checked), so on THIS build the direct path never fires and
				 * the copy below is what runs.  It is kept because it costs one test, it is
				 * the whole fix the day those buffers gain an alignment attribute, and a fast
				 * path nobody can see taken is a fast path nobody can trust -- so the two
				 * paths differ only in the destination and both are exercised by the shapes
				 * this kernel already dispatches. */
				int8_t *d = output + (size_t)m0 * K;
				int direct = (pad_rows == rows) && ((((uintptr_t)d) & 63u) == 0u);
				uint64_t dst = direct ? (uint64_t)(uintptr_t)d
						      : (uint64_t)MBXR_RT_SCRATCH;
				int rc = mbxr_rt_ln_tile(src, (int)(pad_bytes / 8), 0, dst,
							 (int)blocks, pad_rows, K, MBXR_LN_HW_PC,
							 (uint64_t)eps_q, 0,
							 umul, gmul, badd, m0 == 0 ? K : 0);
				if (rc != MBXR_OK) { ok = 0; break; }
				if (!direct)
					mbxr_ln_copy(d, (const int8_t *)MBXR_RT_SCRATCH, bytes);
			}
			if (ok)
				return;
		}
	}
	mbxr_rt_stats.calls_fallback++;
#endif
	mbxr_ln_reference(input, umul, gmul, badd, output, M, K, eps_q);
}

#endif /* MBXR_LN_DRIVER_H */
