/* accuracy_class: bit_exact
 *
 * tanh_s8 on T4's LUT LANE.  The same lane, the same plan and the same tile loop as
 * `roccmoon_gelu_s8_roccmoon_lut.c` -- everything except the table, which is the one thing
 * that cannot be shared.  QATU emits this once, 287,712 elements, 6,569,496 cycles at 22.83
 * cycles/element, 1.19 % of encoder steady.
 *
 * WHY IT IS A SECOND FILE AND NOT A SECOND ENTRY POINT IN THE FIRST.  ModelBlaster selects a
 * kernel per op and each entry point carries the op's name, so the file boundary is fixed by
 * the build.  What is genuinely different rather than merely separate is the ARITHMETIC:
 * `gelu_s8`'s curated kernel is `pext_int_lut`, integer throughout, with a public builder this
 * lane kernel can call (`int_gelu_s8_table`), while `tanh_s8`'s curated kernel is
 * `pext_memo_lut` and evaluates `tanhf` and `roundf` in float.  Each lane kernel must be
 * bit-exact against ITS OWN curated kernel, so the builders cannot be shared.  Everything else
 * is `roccmoon_lut_map.inc`.
 *
 * AND THIS ONE CARRIES A RISK THE GELU KERNEL DOES NOT, SO IT IS WRITTEN DOWN.  The curated
 * tanh kernel has no exported table builder, so the expression below is a TRANSCRIPTION of
 * kernels/pext/pext_tanh_s8_pext_memo_lut.c rather than a call into it.  A transcription can be
 * wrong in a way the gelu path structurally cannot be.  What catches it is
 * `moonshine/check/gelu_lane_check.c`, which compiles the curated file under a rename and
 * compares this kernel's output against it byte for byte over every input value and several
 * scale pairs -- the curated kernel's OUTPUT, never a golden rebuilt from this file, which
 * would compare it against itself and pass at zero while proving nothing.
 *
 * THE NON-DIFFERENCE, as for gelu: the curated kernel evaluates only the distinct input bytes
 * that occur and leaves the rest of its table undefined; this builds all 256, because the lane
 * reads the table by value and cannot know which bytes are present.  Entries for bytes that do
 * not occur are never read, so the outputs agree everywhere the outputs exist.
 */
#include <stddef.h>
#include <stdint.h>
#include <math.h>
#include "pext.h"

#include "roccmoon/mbxr_lut_map.h"

/* Transcribed from kernels/pext/pext_tanh_s8_pext_memo_lut.c, term for term, INCLUDING the
 * order of operations: `roundf(y / scale_out)` and not a multiply by a reciprocal, because in
 * float those are not the same number and this kernel is graded on being the same number. */
static void mbxr_tanh_s8_table(int8_t tbl[256], float scale_in, float scale_out,
			       int activation_min, int activation_max)
{
	for (int v = 0; v < 256; v++) {
		float f = (float)(v - 128) * scale_in;
		float y = tanhf(f);
		int32_t q = (int32_t)roundf(y / scale_out);

		if (q < activation_min) q = activation_min;
		if (q > activation_max) q = activation_max;
		tbl[v] = (int8_t)q;
	}
}

void kernel_tanh_s8(const int8_t *input, int8_t *output, int n,
		    float scale_in, float scale_out,
		    int activation_min, int activation_max)
{
	int8_t tbl[256];

	mbxr_lut_stats.calls++;
	mbxr_tanh_s8_table(tbl, scale_in, scale_out, activation_min, activation_max);

	/* Below the curated kernel's own crossover it evaluates per element rather than building
	 * a table, which is the SAME EXPRESSION and therefore the same bytes -- so the table path
	 * serves both and there is no second arm to get wrong. */
	if (n >= 32 && mbxr_lut_map_op(input, output, n, tbl)) {
		mbxr_lut_stats.calls_lane++;
		return;
	}

	mbxr_lut_scalar(input, output, n, tbl);
	mbxr_lut_stats.calls_fallback++;
}
