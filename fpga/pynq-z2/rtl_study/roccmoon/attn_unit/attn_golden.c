/* SPDX-License-Identifier: Apache-2.0
 *
 * The C side of the attention unit's testbench, compiled as C with the host checks' flags
 * (run from fpga/pynq-z2/modelblaster):
 *
 *   cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw -c attn_golden.c
 *
 * THE GOLDEN IS THE CURATED KERNELS THEMSELVES, unchanged and included as source:
 *   pext_nl_matmul_b_s8_pext_dot8_exact.c   (.qk and .av, accuracy class bit_exact)
 *   pext_nl_softmax_s8_pext_int_memo2.c     (.softmax, bit-exact with memo and row)
 * so one head through attn_golden_head() is exactly what hart 0 computes today for one
 * batch element of dispatches 17, 18 and 19 of the encoder IR.
 *
 *   attn_golden_head   q.k^T -> softmax -> p.v for one head, through those kernels.
 *   attn_rq_consts     (mt, sh) for the RTL's requantiser: the reference's own `total`,
 *                      computed in exact binary32 by fexact32.h exactly as the kernel
 *                      computes it.
 *   attn_smx_cfg       the softmax lane's table and two scalars, line for line as
 *                      kernel_softmax_s8 computes them (smx_lane/smx_golden.c's own).
 *   attn_rq_ref        one requantise through the kernel's OWN two paths (fast path plus
 *                      the guard into pmmb_exact), for the exhaustive requantiser check.
 */
#include <stdint.h>
#include <stddef.h>
#include "pext_nl_matmul_b_s8_pext_dot8_exact.c"
#include "pext_nl_softmax_s8_pext_int_memo2.c"

/* one head: q [T][D], k [N][D], v [N][D] -> out [T][D], with scores and probs exposed */
void attn_golden_head(const int8_t *q, const int8_t *k, const int8_t *v, int8_t *out,
                      int T, int D, int N,
                      float qk_sa, float qk_sb, float qk_so, float qk_sd,
                      float sm_si, float sm_so,
                      float av_sa, float av_sb, float av_so,
                      int8_t *scores, int8_t *probs)
{
	/* .qk: transpose_b = 1 -- key row j is contiguous along d, so no gather */
	kernel_matmul_b_s8(q, k, scores, 1, T, D, N,
			   qk_sa, qk_sb, qk_so, 1, qk_sd, -128, 127);
	kernel_softmax_s8(scores, probs, T, N, sm_si, sm_so);
	/* .av: transpose_b = 0 -- v is read by COLUMN; the kernel gathers it into scratch */
	kernel_matmul_b_s8(probs, v, out, 1, T, N, D,
			   av_sa, av_sb, av_so, 0, 1.0f, -128, 127);
}

/* the reference's `total` = (sa*sb)/(so*sd) in exact binary32, as (mt, sh) */
int attn_rq_consts(float sa, float sb, float so, float sd, uint32_t *mt, int *sh)
{
	fx32_t fa = fx32_dec(sa), fb = fx32_dec(sb), fo = fx32_dec(so), fd = fx32_dec(sd);
	fx32_t total;

	if (!fx32_scale_ok(fa) || !fx32_scale_ok(fb) || !fx32_scale_ok(fo) ||
	    !fx32_scale_ok(fd)) {
		return 0;
	}
	total = fx32_div(fx32_mul(fa, fb), fx32_mul(fo, fd));
	*mt = (uint32_t)total.m;
	*sh = -total.e;
	return total.m != 0 && *sh >= 2 && *sh <= 62;
}

/* the kernel's own requantise tail for one accumulator: fast path, guard, pmmb_exact */
int attn_rq_ref(int64_t acc, uint32_t mt, int sh, int amin, int amax, int *took_slow)
{
	fx32_t total;
	uint64_t P, G, half, mask;
	int64_t v;

	total.m = mt;
	total.e = -sh;
	total.neg = 0;
	half = (uint64_t)1 << (sh - 1);
	mask = ((uint64_t)1 << sh) - 1;
	P = (uint64_t)(acc < 0 ? -acc : acc) * mt;
	G = (P >> 23) + 1;
	if (((P & mask) - half + G) <= 2 * G) {
		v = pmmb_exact(acc, total);
		*took_slow = 1;
	} else {
		v = (int64_t)((P + half) >> sh);
		if (acc < 0) {
			v = -v;
		}
		*took_slow = 0;
	}
	if (v < amin) v = amin;
	if (v > amax) v = amax;
	return (int)v;
}

/* the softmax lane's software half: ex[256], om and s, exactly as the kernel builds them */
void attn_smx_cfg(float scale_in, float scale_out, uint32_t ex[256], int32_t *om_out,
		  int *s_out)
{
	int32_t im, om;
	int is, os, k;

	nl_f2ms(scale_in, &im, &is);
	nl_f2ms_recip(scale_out, &om, &os);
	{
		uint64_t p = ((uint64_t)(uint32_t)im * 3098164010ull) >> 31;   /* log2e Q31 */
		while (p >= 0x80000000ull) { p >>= 1; is -= 1; }
		im = (int32_t)p;
	}
	for (k = 0; k < 256; k++) {
		ex[k] = int_exp2_q31((int32_t)nl_scale((int64_t)(-k) << 16, im, is));
	}
	*om_out = om;
	*s_out = os + 32 - 8;
}
