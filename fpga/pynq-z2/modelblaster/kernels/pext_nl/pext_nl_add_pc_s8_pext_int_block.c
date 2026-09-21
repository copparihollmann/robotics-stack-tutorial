/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_int_block */
/* accuracy_class: bit_exact */
/* origin: patches/0103, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * add_pc_s8 -- the residual add into a per-channel int8 output (extract_q16).  The reference
 * finds each element's channel as i % C: one 64-bit divide per element on a core whose
 * divider is iterative.  Here the loop walks whole channel blocks (the channel axis is the
 * last, so element i of block b is channel i - b*C) and the per-channel multipliers are
 * read by the block index.  The arithmetic per element is the reference's, operand for
 * operand: (a*amul[c] + b*bmul[c] + 2^23) >> 24 in int64, clamped.
 */
#include <stdint.h>

static inline int8_t padd_clip8(int64_t v)
{
	return (int8_t)(v < -128 ? -128 : (v > 127 ? 127 : v));
}

void kernel_add_pc_s8(const int8_t *a, const int8_t *b, const int64_t *amul,
                      const int64_t *bmul, int8_t *output, int n, int C)
{
	const int64_t rnd = (int64_t)1 << 23;
	int i = 0;

	for (; i + C <= n; i += C) {
		const int8_t *pa = a + i, *pb = b + i;
		int8_t *po = output + i;

		for (int c = 0; c < C; c++)
			po[c] = padd_clip8(((int64_t)pa[c] * amul[c] + (int64_t)pb[c] * bmul[c] + rnd) >> 24);
	}
	for (int c = 0; i < n; i++, c++)
		output[i] = padd_clip8(((int64_t)a[i] * amul[c] + (int64_t)b[i] * bmul[c] + rnd) >> 24);
}
