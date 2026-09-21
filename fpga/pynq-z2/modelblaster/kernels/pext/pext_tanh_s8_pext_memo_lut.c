/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_memo_lut */
/* accuracy_class: bit_exact */
/* origin: patches/0100, fpga/pynq-z2/modelblaster/moonshine/ */
/*
 * tanh_s8 -- Moonshine's stem nonlinearity, 287,712 elements per 4 s of audio -- as the
 * memoised 256-entry table pext/pext_gelu_s8_pext_memo_lut.c already is for GELU.
 *
 * With per-tensor symmetric quantisation this op is a map from 256 input bytes to 256
 * output bytes, so tanhf never needs evaluating once per ELEMENT.  One marking pass finds
 * the byte values that occur; the reference expression -- the same float32 casts, the same
 * tanhf, the same roundf and clamp -- fills those entries; a byte gather writes the output.
 *
 * BIT-EXACT BY CONSTRUCTION: every table entry is the reference's own expression on the
 * same int8 value, and there is no arithmetic anywhere else.  It is NOT float-free: at most
 * 256 tanhf calls per dispatch remain, and that is the point of the kernel (the same trade
 * the GELU memo table makes; ROCC_DECOUPLED.md 1.1).  Below the small-n guard the
 * reference runs per element.
 */
#include <math.h>
#include <stdint.h>

void kernel_tanh_s8(const int8_t *input, int8_t *output, int n,
		    float scale_in, float scale_out,
		    int activation_min, int activation_max)
{
	int8_t tbl[256];
	unsigned char seen[256];
	int i, v;

	if (n < 32) {
		for (i = 0; i < n; i++) {
			float f = (float)input[i] * scale_in;
			float y = tanhf(f);
			int32_t q = (int32_t)roundf(y / scale_out);

			if (q < activation_min) q = activation_min;
			if (q > activation_max) q = activation_max;
			output[i] = (int8_t)q;
		}
		return;
	}
	for (i = 0; i < 256; i++) seen[i] = 0;
	for (i = 0; i < n; i++) seen[(unsigned char)((int)input[i] + 128)] = 1;
	for (v = 0; v < 256; v++) {
		if (!seen[v]) continue;
		{
			float f = (float)(v - 128) * scale_in;
			float y = tanhf(f);
			int32_t q = (int32_t)roundf(y / scale_out);

			if (q < activation_min) q = activation_min;
			if (q > activation_max) q = activation_max;
			tbl[v] = (int8_t)q;
		}
	}
	for (i = 0; i < n; i++) output[i] = tbl[(unsigned char)((int)input[i] + 128)];
}
