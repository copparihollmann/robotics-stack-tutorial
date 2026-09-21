/* accuracy_class: bit_exact
 *
 * gelu_s8 on T4's LUT LANE inside the decoupled RoCC engine (T4_LANES.md, `mbxl_lut`), hart 1.
 *
 * WHY THIS FILE EXISTS.  `0x5A5A002D` carries a lane that is 8 elements/cycle, measured on
 * silicon at 0.1253 cycles/element with 187,904 bytes byte-compared and 0 differing
 * (T4_LANES.md s12, EXPERIMENT_LOG L310) -- and `ls kernels/roccmoon` was five files over four
 * ops, none of them this one, so NO MODEL IMAGE COULD SELECT IT.  Lab B37's records are a
 * device bench; the -0.46 of RTF_e2e they price is entirely unrealised until a kernel exists.
 * QATU emits `gelu_s8` eight times (1,378,656 elements, 26,658,038 cycles, 4.83 % of encoder
 * steady).  This is that kernel.
 *
 * ============================================================================================
 * BIT-EXACT BY CONSTRUCTION, AND THE CONSTRUCTION IS THE POINT
 * ============================================================================================
 * The lane does not compute GELU.  It is a 256-entry int8 -> int8 map, so the arithmetic is
 * whatever software puts in the table -- and the table here is built by
 * `int_gelu_s8_table()`, WHICH IS THE CURATED KERNEL'S OWN BUILDER (sw/int_nonlin.c:369, the
 * same `nl_gelu_one` over the same `nl_f2ms`/`nl_f2ms_recip` decomposition that
 * `int_gelu_s8()` uses).  Identical table + identical map = identical bytes, for every input,
 * by construction rather than by sampling.
 *
 * The one difference from the curated kernel is a NON-difference: `int_gelu_s8` evaluates only
 * the distinct input bytes that actually occur (its `seen[]` pass) and leaves the other table
 * entries undefined; this builds all 256.  Entries for bytes that do not occur are never read,
 * so the outputs agree everywhere the outputs exist.
 *
 * WHAT THAT MEANS FOR THE CHECK.  The verification bar is byte-exactness against the CURATED
 * KERNEL'S OUTPUT on the model's own tensors -- not against a golden regenerated from this
 * file's arithmetic, which would compare this kernel against itself and pass at 0 while
 * proving nothing.  `moonshine/check/gelu_lane_check.c` is that check and it runs on the host.
 *
 * ============================================================================================
 * THE ONE DESIGN DECISION THAT DECIDES WHETHER THIS IS WORTH DOING, AND IT IS NOT THE LANE
 * ============================================================================================
 * docs/LANE_DISPATCH_RULES.md s1, measured: same model, same clock, varying only where the
 * drain writes --
 *
 *     drain into the caller's destination        RTF_e2e 5.072
 *     copy out 64 bits at a time  (7.36 c/B)             5.166
 *     copy out a byte at a time   (60.2 c/B)             5.836
 *     ... not using the lane at all                      5.533
 *
 * A byte-wise copy-out spends 101.9 M cycles to remove 33.2 M and is WORSE THAN NOT USING THE
 * LANE.  The LayerNorm lane's kernel independently paid 72.7 % of a dispatch to that shape.
 * So this kernel drains into the caller's tensor and copies NOTHING -- not one byte, not even
 * for the ragged ends.  How it gets away with that is the plan below.
 *
 * ============================================================================================
 * THE PLAN: A SCALAR HEAD, WHOLE-BLOCK TILES STRAIGHT INTO `output`, A SCALAR TAIL
 * ============================================================================================
 * Three hardware rules have to hold at once and none of them is enforced:
 *
 *   (a) the drain destination is 64-BYTE ALIGNED and the drain writes WHOLE 64-byte blocks,
 *       so a tile whose bytes are not a multiple of 64 writes past its own end;
 *   (b) the word count is a MULTIPLE OF 8 (`mbxr_st.v:79`, `have_block = used >= 8`) -- a
 *       28-word dispatch leaves 4 words NEVER WRITTEN, returns ownership cleanly with rc = 0
 *       and u_err = 0x0, and LEAVES THE DRAIN BUSY FOREVER;
 *   (c) the fill source is 64-byte aligned (`mbxd_dma.v:71`), and there is no byte funnel.
 *
 * (b) is not hypothetical on this model: at 8,192-byte tiles the last tile of `stem.gelu3`
 * (47,520 elements) is 820 words and the last tile of `stem.tanh` (287,712) is 124 -- neither
 * a multiple of 8.  Tiling naively and arming `ceil(bytes/64)` blocks is precisely the hang.
 *
 * The plan removes all three without staging a single byte:
 *
 *   head   = (-(uintptr_t)output) & 63, capped at n.  Fewer than 64 elements, done with the
 *            SAME TABLE on the core.  After it, every tile boundary is 64-byte aligned in the
 *            destination, which is (a).
 *   middle = the whole 64-byte blocks that remain.  Every tile is a multiple of 64 bytes, so
 *            its word count is a multiple of 8, which is (b); and `dst_blocks * 64` is exactly
 *            the tile's bytes, so nothing is ever written past it.
 *   tail   = fewer than 64 elements, same table, on the core.
 *
 * (c) costs nothing either, because the streamer has a `word0`: the fill starts at the
 * containing 64-byte block and the lane is told to begin `skew` words in.  `input` is 8-byte
 * aligned (checked), so `skew` is a whole number of words, 0..7, constant for every tile
 * because the tile stride is a multiple of 64.  The tile shrinks by at most 7 words.
 *
 * Head and tail together are under 126 elements per operator -- ~2,400 cycles against the
 * 26.7 M this op costs today -- which is the price of copying nothing.
 *
 * SO THIS KERNEL DOES NOT NEED THE GENERATOR TO ALIGN ANYTHING, and that is worth stating
 * because the alternative was being designed elsewhere.  `generate_skeleton.py` emits every
 * intermediate 8-byte aligned (8/24/40/56 mod 64) while `mbxd_dma.v:71` wants 64, which is why
 * the LayerNorm lane stages its fill and copies its result out, and why the attention unit
 * spent ten arms at 24 mod 64.  A `__attribute__((aligned(64)))` there removes it for everyone
 * and should land.  But the head/tail construction above reaches an aligned destination at ANY
 * 8-byte-aligned output and `word0` reaches any 8-byte-aligned input, so this kernel drains
 * into the caller's tensor TODAY, on today's images.  The generator fix makes `head` zero and
 * the ends smaller; it is not load-bearing here.
 *
 * ONE CONSEQUENCE OF `word0`, WRITTEN DOWN BECAUSE IT LOOKS ALARMING AND IS NOT: the fill's
 * source is the tile's CONTAINING 64-byte block, so it can begin up to 56 bytes BEFORE the
 * tensor.  Those bytes are Get traffic into the scratchpad that the lane never reads -- `word0`
 * starts it past them -- and a Get has no side effects.  What it must not do is leave the DRAM
 * window, and it cannot: the window starts at 0x80000000 and no model tensor lives in its
 * first 64 bytes.
 *
 * ============================================================================================
 * THE TABLE IS WRITTEN ONCE PER OPERATOR, NOT ONCE PER TILE
 * ============================================================================================
 * 256 `lcfg` writes at a measured 20-22 cycles each is ~5,400 cycles.  Per tile that would be
 * 1.9x the tile's own cost; per operator it is 0.02 % of what the operator costs today.  The
 * table depends only on (scale_in, scale_out, amin, amax), which are constant across an
 * operator's tiles, so it is written before the tile loop and not touched again.  A dispatch
 * cannot change it: `mbxl_lut` refuses a config write while busy (err[1]).
 *
 * ============================================================================================
 * AND EVERY DISPATCH GOES THROUGH THE SHARED PATH
 * ============================================================================================
 * `sw/roccmoon/mbxr_lane_dispatch.h`, this kernel being its first consumer.  Six hazards on
 * this interface have been paid for two or three times each because the first fix went into a
 * kernel rather than a shared path; a fourth copy of the protocol here would make it seven.
 * Everything this file knows about `ld`'s bit 17, about `cfg` naming a DIFFERENT register from
 * the one the fill writes, about arming the drain only once `lgo` cannot be refused, and about
 * reading the engine's sticky refusal bit after each stage, it knows by calling that header.
 */
#include <stddef.h>
#include <stdint.h>
#include "pext.h"

/* the curated kernel's own arithmetic, and its table builder.  Pulled in exactly as
 * kernels/pext_nl/pext_nl_gelu_s8_pext_int_lut.c pulls it in, so there is one copy. */
#ifndef MBP_INT_NONLIN_INCLUDED
#define MBP_INT_NONLIN_INCLUDED
#include "int_nonlin.c"
#endif

#include "roccmoon/mbxr_lut_map.h"

void kernel_gelu_s8(const int8_t *input, int8_t *output, int n,
		    float scale_in, float scale_out,
		    int activation_min, int activation_max)
{
	int8_t tbl[256];

	mbxr_lut_stats.calls++;

	/* Below the curated kernel's own crossover a table costs more than it saves, and the
	 * lane cannot help with 31 elements either.  One path, and it is the curated one. */
	if (n < 32) {
		int_gelu_s8(input, output, n, scale_in, scale_out,
			    activation_min, activation_max);
		mbxr_lut_stats.calls_fallback++;
		return;
	}

	/* THE CURATED KERNEL'S OWN BUILDER (sw/int_nonlin.c:369).  Every entry, not only the ones
	 * that occur -- the lane reads the table by value and cannot know which bytes are
	 * present.  This is what makes bit-exactness a construction rather than a hope. */
	int_gelu_s8_table(tbl, scale_in, scale_out, activation_min, activation_max);

	if (mbxr_lut_map_op(input, output, n, tbl)) {
		mbxr_lut_stats.calls_lane++;
		return;
	}

	/* THE FALLBACK IS THE CURATED KERNEL, which is what this file must be bit-exact against.
	 * Not a re-derivation: the same function the `pext_int_lut` kernel calls. */
	int_gelu_s8(input, output, n, scale_in, scale_out, activation_min, activation_max);
	mbxr_lut_stats.calls_fallback++;
}
