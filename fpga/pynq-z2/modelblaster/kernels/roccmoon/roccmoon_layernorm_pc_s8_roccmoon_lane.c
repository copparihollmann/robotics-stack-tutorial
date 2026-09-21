/* accuracy_class: bit_exact
 *
 * layernorm_pc_s8 on the NORMALISATION LANE inside the decoupled RoCC engine
 * (ROCC_DECOUPLED.md section 8.15.21-24, LAYERNORM_LANE.md), hart 1.
 *
 * THE FIRST KERNEL THAT DISPATCHES TO A LANE.  Everything before this went to `mbxr_tseq`, the
 * engine's tile sequencer; this goes to `mbxr_ln` through custom-1 functs 9/10/11.  The protocol
 * is not folklore: Lab B33 issued the first lane dispatch on silicon and every precondition it
 * found is a return code in sw/roccmoon/mbxr_lanes.h, so this file asks rather than assumes.
 *
 * BIT-EXACT BY CONSTRUCTION.  The lane computes the reference expression, not an approximation
 * of it -- ModelBlaster's own semantics for this op are
 *     u_k = x_k * umul[k]                      (umul = s_k/s_ref in Q24)
 *     S = sum u,  Q = sum u^2,  V = K*Q - S^2 + eps_q,  R = isqrt(floor(2^120 / V))
 *     y_k = clamp8(floor((floor((K*u_k - S)*R / 2^44)*gmul[k] + badd[k]*2^16 + 2^31) / 2^32))
 * and LAYERNORM_LANE.md section 1 is that expression term for term.  The fallback below is the
 * reference itself, so "bit-exact" is checked against the thing it is defined by rather than
 * against a second implementation that could be wrong in the same way.
 *
 * WHAT GOES TO THE LANE AND WHAT DOES NOT.  The lane takes a dispatch only when every one of the
 * preconditions holds, and they are shape conditions rather than judgement:
 *   * K a whole number of scratchpad words in and out, and M*K likewise (else the streamer's
 *     element count and the lane's row length disagree and OWNERSHIP IS NEVER RETURNED);
 *   * a tile within one 1,024-word buffer (else the reader wraps SILENTLY -- no error bit, the
 *     hazard MAGIC_REGISTRY.md's 0x5A5A002A row demonstrates as LNG_WRAP_DEMO);
 *   * EVERY TILE A WHOLE NUMBER OF 64-BYTE DRAIN BLOCKS, reached by padding with ROWS.  This
 *     went round twice and the second answer is the measured one.  A partial final block HANGS:
 *     the lane produces rows*K bytes, the drain waits for the rest of the block, the packer
 *     backpressures, the streamer stops and ownership never returns -- reproduced in simulation
 *     at 25 rows and at 1 row, against bit-exact results at 28 and 2.  Lab B33's probe appeared
 *     to show a 4.5-block tile draining cleanly, and that was a different question: the smoke
 *     test never filled the scratchpad, so there was no fill to backpressure.  M = 165 is odd
 *     and 288 x odd is never a multiple of 64, so the last tile is padded UP to an even row
 *     count and the extra row is computed and discarded -- free, because each row is normalised
 *     independently and a zero row is well defined (V = eps_q > 0);
 *   * eps_q > 262144 and the per-channel constants inside the lane's field widths.
 * Anything else falls back.  That is not caution about the lane -- it is that a fallback costs a
 * dispatch and a wrong precondition costs a board.
 *
 * ONE DISPATCH PER TILE, NOT PER LAYER.  An earlier version of this programme required batching
 * to one dispatch per layer, from a wrapper cost of 4,924 cycles carried over from a GEMM
 * dispatch.  Lab B33 measured the lane wrapper at 196 cycles and that requirement was withdrawn
 * (ROCC_DECOUPLED.md 8.15.24): at 13 layernorms x 6 tiles the wrapper is ~0.17 % of the work.
 * The tiling here is set by the 1,024-word reach, which is a correctness bound, not by cost.
 */
#include <stddef.h>
#include <stdint.h>
#include "pext.h"
#include "roccmoon/mbxr_rt.h"
#include "roccmoon/mbxr_lanes.h"

/* THE PER-CHANNEL ENTRY.  Its table arrives already quantised, so there is nothing to derive:
 * everything below the entry point -- the q16 core, the reference fallback, the field checks,
 * the tiling and the staging -- is shared with the per-tensor kernel and lives in the include.
 * This file is the op's NAME and its argument order, which is all that distinguishes it. */
#include "roccmoon/mbxr_ln_driver.h"

void kernel_layernorm_pc_s8(const int8_t *input, const int32_t *umul, const int64_t *gmul,
			    const int64_t *badd, int8_t *output, int M, int K, int64_t eps_q)
{
	mbxr_ln_run(input, umul, gmul, badd, output, M, K, eps_q);
}
