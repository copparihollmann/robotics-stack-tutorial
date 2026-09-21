/* SPDX-License-Identifier: Apache-2.0
 *
 * B67 -- WHERE cat2_c1_s8's CYCLES ACTUALLY GO, and what the integer builder is worth,
 * both measured before any board time is taken.
 *
 * Lab B44 predicted 15,727,562 cycles for a LUT lane on this operator and measured
 * 647,557 -- a 24x miss -- because it priced a two-way split (build, gather) when the
 * split is three-way (build, MARKING, gather) and a lane removes only the gather.  This
 * program does not repeat that: it measures all three, on the model's own 552 sides,
 * before anything is proposed.
 *
 * WHAT IT COUNTS.  `minstret`, retired instructions, read by the guest on either side of
 * each call and corrected for the counter reads, on spike, with the board's own compiler
 * and flags (riscv64-zephyr-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64
 * -mcmodel=medany -O2).  Same method and harness as b66_icount_main.c and
 * fpga/pynq-z2/modelblaster/check/count_instructions.py.
 *
 * INSTRUCTIONS ARE NOT CYCLES -- B59 measured 1.377 cyc/instr on this hart, and B63c
 * measured a table BUILD running at 3.97x its instruction account under engine load,
 * because a cold-line store on this L1D costs far more than one cycle.  What survives the
 * conversion is the SHAPE: which term dominates, and where a guard crosses.  The board
 * arm settles the cycles.
 *
 * THE THREE-WAY SPLIT IS SOLVED, NOT ASSERTED.  The shipped kernel's instruction count is
 * affine in (cnt, D):
 *
 *     I(cnt, D) = S + (M + G) * cnt + B * D
 *
 * with M the marking pass per element, G the gather per element, B the float builder per
 * table entry and S the per-side fixed cost.  Holding cnt and sweeping D gives B; holding
 * D and sweeping cnt gives M + G; and M and G are separated by the one thing a sweep
 * cannot see, the DISASSEMBLY: the marking inner loop is six instructions per element
 * (lbu, addi, xori, add, sb, bne) and the gather inner loop is eight (lbu, addi, addi,
 * xori, add, lbu, sb, bne), read off the shipped zephyr.elf and checked again against
 * this harness's own objdump.  So the sweep measures their SUM and the disassembly
 * measures their RATIO, and neither is taken on trust from the other.
 *
 * THE FOURTH ARM IS THE ROUTE THAT ALREADY EXISTS.  add_s8, mul_s8, rope_s8 and
 * matmul_b_s8 all build their tables through fexact32.h's fx32_apply.  cat2 does not, and
 * the first question about any fix here is whether the fix is already written.  Arm
 * `fx32` builds cat2's table with fx32_ratio + fx32_apply, exactly as mul_s8 does, so the
 * answer is a measured number rather than an opinion.  It is priced as a BUILDER and is
 * not a candidate kernel: it carries no half-integer guard, so it is not bit-exact and
 * nothing here proposes shipping it.
 */

#include <stdint.h>
#include <stddef.h>
#include "b67_sides.h"

/* roundf.  The freestanding harness links no libm, and the SHIPPED arm calls roundf once
 * per table entry -- so a stand-in would put the arm under measurement on a different
 * builder from the board's.  This is the board image's own roundf, transcribed from the
 * disassembly of zephyr.elf (0x800ef57a, newlib's bit-twiddling round-half-away): same
 * branches, same __addsf3 call on the inf/NaN arm, same 36 instructions. */
float roundf(float x);
float roundf(float x)
{
	uint32_t w;
	int e;

	__builtin_memcpy(&w, &x, 4);
	e = (int)((w >> 23) & 0xffu) - 127;
	if (e < 23) {
		if (e < 0) {
			w &= 0x80000000u;
			if (e == -1)
				w |= 0x3f800000u;
		} else {
			uint32_t m = 0x007fffffu >> e;

			if ((w & m) == 0)
				return x;
			w += 0x00400000u >> e;
			w &= ~m;
		}
	} else {
		if (e == 128)
			return x + x;
		return x;
	}
	__builtin_memcpy(&x, &w, 4);
	return x;
}

void htif_puts(const char *s);
void htif_putu(uint64_t v);
void htif_exit(int code);

void cat2_ship(const int8_t *, int, float, const int8_t *, int, float,
	       int8_t *, int, int, int, float, int, int);
void cat2_new(const int8_t *, int, float, const int8_t *, int, float,
	      int8_t *, int, int, int, float, int, int);
void cat2_cov(const int8_t *, int, float, const int8_t *, int, float,
	      int8_t *, int, int, int, float, int, int);
void cat2_tbl(const int8_t *, int, float, const int8_t *, int, float,
	      int8_t *, int, int, int, float, int, int);

/* ---- arm fx32: cat2's table through the builder mul_s8 already uses ---------------- */
#include "fexact32.h"

static int32_t fx32_cat2_entry(int k, fx32_t si, fx32_t so)
{
	return fx32_roundf_i32(fx32_div(fx32_mul(fx32_int(k), si), so));
}

void cat2_fx32(const int8_t *in0, int c0, float scale0,
	       const int8_t *in1, int c1, float scale1,
	       int8_t *output, int N, int H, int W,
	       float scale_out, int amin, int amax);
void cat2_fx32(const int8_t *in0, int c0, float scale0,
	       const int8_t *in1, int c1, float scale1,
	       int8_t *output, int N, int H, int W,
	       float scale_out, int amin, int amax)
{
	const int stride = H * W;
	const int8_t *ins[2] = { in0, in1 };
	const int cs[2] = { c0, c1 };
	const float scales[2] = { scale0, scale1 };
	const fx32_t so = fx32_dec(scale_out);
	int8_t tbl[256];
	int n, i, v;
	long k;

	for (n = 0; n < N; n++) {
		int out_c = 0;

		for (i = 0; i < 2; i++) {
			const fx32_t si = fx32_dec(scales[i]);
			const fx32_k_t kk = fx32_ratio(si, so);
			const long cnt = (long)cs[i] * stride;
			const int8_t *src = ins[i] + (long)n * cs[i] * stride;
			int8_t *dst = output + ((long)n * (c0 + c1) + out_c) * stride;
			int F = 30, ok = 1;

			out_c += cs[i];
			if (cnt <= 0)
				continue;
			for (v = 0; v < 256; v++) {
				int kv = v - 128;
				uint64_t m = (uint64_t)(kv < 0 ? -kv : kv);
				int64_t t = fx32_apply(m, 0, kv < 0, kk, F, &ok);
				int32_t q;

				if (!ok) {
					q = fx32_cat2_entry(kv, si, so);
				} else {
					int64_t h = (int64_t)1 << (F - 1);

					q = (int32_t)((t < 0 ? t - h : t + h) >> F);
				}
				if (q < amin) q = amin;
				if (q > amax) q = amax;
				tbl[v] = (int8_t)q;
			}
			for (k = 0; k < cnt; k++)
				dst[k] = tbl[(unsigned char)((int)src[k] + 128)];
		}
	}
}

/* ---------------------------------------------------------------------------------- */

static inline uint64_t rd_minstret(void)
{
	uint64_t v;

	__asm__ volatile("csrr %0, minstret" : "=r"(v));
	return v;
}

static uint64_t probe_overhead(void)
{
	uint64_t best = (uint64_t)-1;
	int i;

	for (i = 0; i < 8; i++) {
		uint64_t a = rd_minstret();
		uint64_t b = rd_minstret();

		if (b - a < best)
			best = b - a;
	}
	return best;
}

static uint64_t ovh;

#define MAXN 8192
static int8_t src[MAXN];
static int8_t dst[2 * MAXN];

typedef void (*kfn)(const int8_t *, int, float, const int8_t *, int, float,
		    int8_t *, int, int, int, float, int, int);

/* Fill cnt bytes with exactly the d byte codes the real side contained. */
static int fill(const b67_side_t *s)
{
	int vals[256], nv = 0, i, j;
	long k;

	for (i = 0; i < 64; i++) {
		char c = s->bm[i];
		int nib = (c >= 'a') ? (c - 'a' + 10) : (c - '0');

		for (j = 0; j < 4; j++)
			if (nib >> j & 1)
				vals[nv++] = i * 4 + j;
	}
	for (k = 0; k < s->cnt; k++)
		src[k] = (int8_t)(vals[k % nv] - 128);
	return nv;
}

/* One side: c0 = 1, c1 = 0, H = cnt, W = 1 -- one contiguous run, the decoder's shape. */
static uint64_t run_side(kfn f, const b67_side_t *s)
{
	uint64_t a, b;

	a = rd_minstret();
	/* c1 = 0 with scale1 = scale_out: the second side is a zero-length identity copy in
	 * every arm, so the account is the first side's and nothing else. */
	f(src, 1, s->s_in, src, 0, s->s_out, dst, 1, s->cnt, 1, s->s_out, s->amin, s->amax);
	b = rd_minstret();
	return b - a - ovh;
}

static uint64_t model(kfn f, int skip_ident)
{
	uint64_t tot = 0;
	int i;

	for (i = 0; i < B67_NSIDES; i++) {
		const b67_side_t *s = &b67_sides[i];

		if (skip_ident && s->ident)
			continue;
		fill(s);
		tot += run_side(f, s);
	}
	return tot;
}

static void line(const char *tag, uint64_t v)
{
	htif_puts(tag);
	htif_putu(v);
	htif_puts("\n");
}

/* A synthetic side: cnt elements drawn from exactly d byte codes. */
static void synth(int cnt, int d)
{
	long k;

	for (k = 0; k < cnt; k++)
		src[k] = (int8_t)((int)(k % d) - 128);
}

static uint64_t one(kfn f, int cnt, int d, float si, float so)
{
	uint64_t a, b;

	synth(cnt, d);
	a = rd_minstret();
	f(src, 1, si, src, 0, so, dst, 1, cnt, 1, so, -128, 127);
	b = rd_minstret();
	return b - a - ovh;
}

int main(void)
{
	const float SI = 0x1.a85f3a0000000p-5f, SO = 0x1.a8fa160000000p-5f;
	uint64_t i1, i2, i3, i4;
	int n;

	ovh = probe_overhead();
	line("MB_B67 probe_overhead=", ovh);

	/* ---- 1. the model's own 552 sides, whole-kernel, per arm ---- */
	line("MB_B67 model_ship=", model(cat2_ship, 0));
	line("MB_B67 model_new=", model(cat2_new, 0));
	line("MB_B67 model_cov=", model(cat2_cov, 0));
	line("MB_B67 model_fx32=", model(cat2_fx32, 0));
	line("MB_B67 model_ship_noident=", model(cat2_ship, 1));
	line("MB_B67 model_new_noident=", model(cat2_new, 1));

	/* ---- 2. the affine solve for the SHIPPED kernel: I = S + (M+G)*cnt + B*D ---- */
	/* B: hold cnt, sweep D */
	i1 = one(cat2_ship, 4096, 16, SI, SO);
	i2 = one(cat2_ship, 4096, 240, SI, SO);
	line("MB_B67 ship_c4096_d16=", i1);
	line("MB_B67 ship_c4096_d240=", i2);
	line("MB_B67 ship_B_x224=", i2 - i1);          /* / 224 = instructions per entry */
	/* M+G: hold D, sweep cnt */
	i3 = one(cat2_ship, 1024, 16, SI, SO);
	i4 = one(cat2_ship, 5120, 16, SI, SO);
	line("MB_B67 ship_c1024_d16=", i3);
	line("MB_B67 ship_c5120_d16=", i4);
	line("MB_B67 ship_MG_x4096=", i4 - i3);        /* / 4096 = marking + gather per element */

	/* ---- 3. the same solve for the B67 kernel: I = S' + G*cnt (D does not enter) ---- */
	i1 = one(cat2_new, 4096, 16, SI, SO);
	i2 = one(cat2_new, 4096, 240, SI, SO);
	line("MB_B67 new_c4096_d16=", i1);
	line("MB_B67 new_c4096_d240=", i2);
	i3 = one(cat2_new, 1024, 16, SI, SO);
	i4 = one(cat2_new, 5120, 16, SI, SO);
	line("MB_B67 new_c1024_d16=", i3);
	line("MB_B67 new_c5120_d16=", i4);
	line("MB_B67 new_G_x4096=", i4 - i3);
	/* the B67 build alone: extrapolate the per-side cost back to cnt = 0 */
	line("MB_B67 new_build_256=", i3 - (i4 - i3) / 4);

	/* the fx32 route's build, the same way */
	i3 = one(cat2_fx32, 1024, 16, SI, SO);
	i4 = one(cat2_fx32, 5120, 16, SI, SO);
	line("MB_B67 fx32_c1024_d16=", i3);
	line("MB_B67 fx32_G_x4096=", i4 - i3);
	line("MB_B67 fx32_build_256=", i3 - (i4 - i3) / 4);

	/* ---- 4. MBP_CAT2_MINN's crossover: table (arm new, forced) vs per-element ---- */
	for (n = 128; n <= 512; n += 16) {
		uint64_t t = one(cat2_tbl, n, 200, SI, SO);   /* MINN = 0: always table */
		uint64_t e = one(cat2_cov, n, 200, SI, SO);   /* MINN = 1e9: always per-element */

		htif_puts("MB_B67 minn n=");
		htif_putu((uint64_t)n);
		htif_puts(" table=");
		htif_putu(t);
		htif_puts(" element=");
		htif_putu(e);
		htif_puts("\n");
	}
	htif_exit(0);
	return 0;
}
