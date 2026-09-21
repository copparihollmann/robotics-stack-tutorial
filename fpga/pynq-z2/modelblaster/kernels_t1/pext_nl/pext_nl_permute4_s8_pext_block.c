/* SPDX-License-Identifier: Apache-2.0 */
/* source: curated */
/* algorithm: pext_block */
/* accuracy_class: bit_exact */
/* origin: reference_kernels.py PERMUTE4_S8 reference_impl, with its per-element multiply removed */
/*
 * permute4_s8, BIT-EXACT with the reference: the same elements in the same output order, and
 * for a requantising permute the reference's own float expression per element.
 *
 * Lab B26 measured the reference at 39.7 cycles/element on Moonshine's encoder: 47.2 M cycles,
 * 7 % of it.  WHERE THOSE CYCLES GO, counted on spike with the board's flags
 * (count_muldiv.py, one inference): 14.9 M instructions in the kernel and 28.5 M in __eqsf2.
 * The board has no FPU, so the reference's `pure = (scale_in == scale_out)` is a soft-float
 * libcall, and GCC evaluates it inside the element loop: 24 instructions of float compare per
 * element.  The index multiplies are NOT the cost -- GCC strength-reduces them (75 mulw in the
 * whole kernel); an earlier comment here said otherwise, before the count.
 *
 * Here `pure` is decided once, every index is a pointer advanced by a stride, and when the
 * innermost output axis is the input's innermost axis (os[3] == 1 -- every attention head
 * split and merge, (0, 2, 1, 3)) each output row is a contiguous run of the input, copied a
 * 64-bit word at a time.  Spike: 5.3 M instructions and no float compares per element.
 *
 * Kept in fpga/pynq-z2/modelblaster/kernels_t1, not in the default curated tree, so no existing
 * build changes its pick; scripts/50's *_perm variants add it (patches/0107).
 */
#include <stdint.h>
#include <stddef.h>

/*
 * B76 -- THE RUN COPY IS THREE MEMORY OPERATIONS PER BYTE, AND TWO OF THEM ARE THE
 * COMPILER'S, NOT THE ALGORITHM'S.  Counted off the shipping decoder image's own
 * disassembly (out/b73_dec_ship/dec_q16/dis.txt, <pblk_nest> 800012cc..80001330), the
 * `while (n >= 8)` body above is:
 *
 *     8 x lbu   from src          the memcpy, byte-wise
 *     8 x sb    to dst            the memcpy, byte-wise
 *     8 x sb    to 0(s0)          <- the uint64_t `w`, ALSO written, to a stack slot
 *     2 x addi, 1 x bne
 *
 * 27 instructions for 8 bytes.  TWO separate defects stack:
 *
 *   (1) -mtune=rocket (the default tune) declares unaligned access slow, so GCC will not
 *       emit `ld`/`sd` for a memcpy off an `int8_t *` whose alignment it cannot prove --
 *       correct, because Rocket traps them, and the trap handler is not cheap either.
 *   (2) `w` has its address taken by both memcpys, so GCC materialises it in memory and
 *       stores every byte TWICE.  The 64-bit temporary buys nothing and costs 8 stores.
 *
 * THE FIX IS TO PROVE THE ALIGNMENT ONCE PER CALL RATHER THAN NEVER.  Every pointer this
 * op sees is a ModelBlaster intermediate buffer (gen/buffers.c: `__attribute__((aligned(64)))`
 * on every one), and in RUNS mode the run base moves by os[0], os[1], os[2] and the run
 * length is od[3].  So the common alignment of every (src, dst) pair in the whole nest is
 * fixed by ONE or of the two bases, the three strides and the length -- computed once,
 * outside every loop, exactly as `pure` and `mode` already are.  The decoder's 288
 * dispatches are (0,2,1,3) on d3 = 36 with strides {288*d1, 36, 288, 1}: 4-byte aligned,
 * not 8, so they take the `lw`/`sw` nest at 9 words per 36-byte run.
 *
 * THE BYTE NEST IS KEPT AND IS THE DEFAULT for anything that does not prove out -- it is
 * the loop above with the dead temporary removed, which is already strictly better.
 *
 * Measured (test/b76_icount.sh, retired instructions on spike at the board's own flags):
 * see B76_BAND.md.  -DMBP_B76=1 selects it.
 */
#ifndef MBP_B76
#define MBP_B76 0
#endif
/* LIVE-PATH PROOF, not a feature.  Each value perturbs one of the new routes visibly in
 * the OUTPUT (a copy has no arithmetic to absorb a perturbation, so a flipped bit in the
 * byte written is the only poison that can work here):
 *   1  the 8-byte run copy
 *   2  the 4-byte run copy
 *   3  the byte run copy (the rewritten default) */
#ifndef MBP_B76_POISON
#define MBP_B76_POISON 0
#endif

#if MBP_B76
/* One `or` of everything that can move a run base or end it.  A stride is a size_t and a
 * length an int; both are non-negative here (the caller has already rejected od[k] <= 0). */
static inline int pblk_align(const int8_t *in, const int8_t *out,
			     const size_t os[4], const int od[4])
{
	uintptr_t u = (uintptr_t)in | (uintptr_t)out |
		      (uintptr_t)os[0] | (uintptr_t)os[1] | (uintptr_t)os[2] |
		      (uintptr_t)(unsigned)od[3];

	if ((u & 7u) == 0u) {
		return 8;
	}
	if ((u & 3u) == 0u) {
		return 4;
	}
	return 1;
}
#endif

static inline void pblk_copy(int8_t *dst, const int8_t *src, size_t n)
{
	while (n >= 8) {
		uint64_t w;
		__builtin_memcpy(&w, src, 8);
		__builtin_memcpy(dst, &w, 8);
		src += 8; dst += 8; n -= 8;
	}
	while (n--) *dst++ = *src++;
}

/* The three loop nests, each with its own innermost body, chosen ONCE per call.  A single nest
 * with `if (pure)` inside let GCC re-evaluate the soft-float compare per output row (spike:
 * 31,845 __eqsf2 calls per inference, 0.73 M instructions); a call per loop nest cannot be. */
typedef enum { PBLK_RUNS, PBLK_STRIDE, PBLK_REQUANT } pblk_mode;

#if MBP_B76
/* A load/store unit whose alignment the CALLER has proved, so GCC emits the access rather
 * than a byte expansion.  `may_alias` because an int8_t buffer is being read through it;
 * `aligned(1)` is NOT used -- the point is that these ARE aligned. */
typedef uint64_t pblk_u64 __attribute__((may_alias));
typedef uint32_t pblk_u32 __attribute__((may_alias));

/* The RUNS nest at one proved width.  `wid` is a constant at every call site, so each copy
 * of this body carries one loop and no width test -- the same reason pblk_nest takes `mode`
 * by value and is called once per mode rather than tested per row. */
static inline __attribute__((always_inline)) void
pblk_runs_w(const int8_t *input, int8_t *output, const int od[4], const size_t os[4], int wid)
{
	int8_t *w = output;
	const int8_t *b0 = input;
	const int nrun = od[3];
	int o0, o1, o2, i;

	for (o0 = 0; o0 < od[0]; o0++, b0 += os[0]) {
		const int8_t *b1 = b0;

		for (o1 = 0; o1 < od[1]; o1++, b1 += os[1]) {
			const int8_t *b2 = b1;

			for (o2 = 0; o2 < od[2]; o2++, b2 += os[2], w += nrun) {
				if (wid == 8) {
					pblk_u64 *d = (pblk_u64 *)w;
					const pblk_u64 *s = (const pblk_u64 *)b2;

					for (i = 0; i < nrun >> 3; i++)
						d[i] = s[i];
					for (i = (nrun >> 3) << 3; i < nrun; i++)
						w[i] = b2[i];
#if MBP_B76_POISON == 1
					w[0] ^= 1;
#endif
				} else if (wid == 4) {
					pblk_u32 *d = (pblk_u32 *)w;
					const pblk_u32 *s = (const pblk_u32 *)b2;

					for (i = 0; i < nrun >> 2; i++)
						d[i] = s[i];
					for (i = (nrun >> 2) << 2; i < nrun; i++)
						w[i] = b2[i];
#if MBP_B76_POISON == 2
					w[0] ^= 1;
#endif
				} else {
					for (i = 0; i < nrun; i++)
						w[i] = b2[i];
#if MBP_B76_POISON == 3
					w[0] ^= 1;
#endif
				}
			}
		}
	}
}

__attribute__((noinline))
static void pblk_runs(const int8_t *input, int8_t *output, const int od[4],
		      const size_t os[4], int wid)
{
	if (wid == 8) {
		pblk_runs_w(input, output, od, os, 8);
	} else if (wid == 4) {
		pblk_runs_w(input, output, od, os, 4);
	} else {
		pblk_runs_w(input, output, od, os, 1);
	}
}

/*
 * B76 -- THE STRIDE NEST IS NINE INSTRUCTIONS PER BYTE AND TWO OF THEM ARE RELOADS.
 * From the same image's disassembly (<pblk_nest> 800011a0..800011b6) the innermost body is
 *
 *     lb / addiw / addi / sb / ld 24(s9) / lw 12(s2) / add / blt
 *
 * -- `os[3]` and `od[3]` fetched from memory on EVERY element, because they arrive as
 * `const size_t *` / `const int *` and the store through `int8_t *w` may alias anything.
 * Copying them into locals is all it takes.
 *
 * AND THE ACCESS ORDER IS THE LARGER HALF.  The decoder's 6 real transposes are
 * od = (1, 8, 36, 165), os = (47520, 36, 1, 288): the innermost loop walks the SOURCE at
 * stride 288 for 165 iterations, so every load is a different cache line and the 47,520-byte
 * source is swept once per (o1, o2) pair -- 5,940 line-crossing loads per o1 out of a buffer
 * that is 3x the 16 KB L1D, with no reuse to be had because the o2 loop that would supply it
 * sits OUTSIDE the one that evicts.  These 6 dispatches are 27.6 % of decoder permute4_s8 at
 * 10.48 cycles/byte against the RUNS mode's 5.96.
 *
 * When os[2] == 1 -- the output's third axis IS the input's innermost axis, which is what a
 * (0, 2, 1, 3) transpose of a head-split tensor always gives -- the o2 and o3 loops can be
 * interchanged.  Then each (o1, o3) reads 36 CONTIGUOUS bytes (one line) and writes them at
 * stride od[3] into a od[2]*od[3] = 5,940-byte output block that fits L1.  Same bytes, same
 * output order, same result; 36x fewer line-crossing loads.  The interchange is a pure
 * reordering of independent writes to distinct addresses, so it is exact by construction.
 */
__attribute__((noinline))
static void pblk_tblock(const int8_t *input, int8_t *output, const int od[4],
			const size_t os[4])
{
	const int n0 = od[0], n1 = od[1], n2 = od[2], n3 = od[3];
	const size_t s0 = os[0], s1 = os[1], s3 = os[3];
	int8_t *w = output;
	const int8_t *b0 = input;
	int o0, o1, o2, o3;

	for (o0 = 0; o0 < n0; o0++, b0 += s0) {
		const int8_t *b1 = b0;

		for (o1 = 0; o1 < n1; o1++, b1 += s1) {
			for (o3 = 0; o3 < n3; o3++) {
				const int8_t *s = b1 + (size_t)o3 * s3;
				int8_t *ww = w + o3;

				for (o2 = 0; o2 < n2; o2++, ww += n3)
					*ww = s[o2];
			}
#if MBP_B76_POISON == 4
			w[0] ^= 1;
#endif
			w += (size_t)n2 * n3;
		}
	}
}

/* The general strided gather, with the two reloads hoisted and nothing else changed. */
__attribute__((noinline))
static void pblk_stride(const int8_t *input, int8_t *output, const int od[4],
			const size_t os[4])
{
	const int n0 = od[0], n1 = od[1], n2 = od[2], n3 = od[3];
	const size_t s0 = os[0], s1 = os[1], s2 = os[2], s3 = os[3];
	int8_t *w = output;
	const int8_t *b0 = input;
	int o0, o1, o2, o3;

	for (o0 = 0; o0 < n0; o0++, b0 += s0) {
		const int8_t *b1 = b0;

		for (o1 = 0; o1 < n1; o1++, b1 += s1) {
			const int8_t *b2 = b1;

			for (o2 = 0; o2 < n2; o2++, b2 += s2) {
				const int8_t *s = b2;

				for (o3 = 0; o3 < n3; o3++, s += s3)
					*w++ = *s;
#if MBP_B76_POISON == 5
				w[-1] ^= 1;
#endif
			}
		}
	}
}
#endif /* MBP_B76 */

__attribute__((noinline))
static void pblk_nest(const int8_t *input, int8_t *output, const int od[4], const size_t os[4],
		      pblk_mode mode, float ratio, int activation_min, int activation_max)
{
	int8_t *w = output;
	const int8_t *b0 = input;
	int o0, o1, o2, o3;

	for (o0 = 0; o0 < od[0]; o0++, b0 += os[0]) {
		const int8_t *b1 = b0;
		for (o1 = 0; o1 < od[1]; o1++, b1 += os[1]) {
			const int8_t *b2 = b1;
			for (o2 = 0; o2 < od[2]; o2++, b2 += os[2]) {
				const int8_t *s = b2;
				switch (mode) {
				case PBLK_RUNS:
					pblk_copy(w, b2, (size_t)od[3]);
					w += od[3];
					break;
				case PBLK_STRIDE:
					for (o3 = 0; o3 < od[3]; o3++, s += os[3]) *w++ = *s;
					break;
				default:
					for (o3 = 0; o3 < od[3]; o3++, s += os[3]) {
						int8_t v = *s;
						float f = (float)v * ratio;
						int32_t q = (int32_t)(f >= 0.0f ? f + 0.5f : f - 0.5f);
						if (q < activation_min) q = activation_min;
						if (q > activation_max) q = activation_max;
						*w++ = (int8_t)q;
					}
					break;
				}
			}
		}
	}
}

void kernel_permute4_s8(const int8_t *input, int8_t *output,
                        int d0, int d1, int d2, int d3,
                        int p0, int p1, int p2, int p3,
                        float scale_in, float scale_out,
                        int activation_min, int activation_max)
{
	const int din[4] = { d0, d1, d2, d3 };
	const size_t sin[4] = { (size_t)d1 * d2 * d3, (size_t)d2 * d3, (size_t)d3, 1 };
	const int perm[4] = { p0, p1, p2, p3 };
	int od[4];
	size_t os[4];
	int k;

	for (k = 0; k < 4; k++) { od[k] = din[perm[k]]; os[k] = sin[perm[k]]; }
	if (od[0] <= 0 || od[1] <= 0 || od[2] <= 0 || od[3] <= 0)
		return;
#if MBP_B76
	/* The RUNS arm splits off; the other two stay in pblk_nest exactly as they were. */
	if (scale_in == scale_out) {                         /* one soft-float compare per call */
		if (os[3] == 1)
			pblk_runs(input, output, od, os, pblk_align(input, output, os, od));
		else if (os[2] == 1)
			pblk_tblock(input, output, od, os);
		else
			pblk_stride(input, output, od, os);
	} else {
		pblk_nest(input, output, od, os, PBLK_REQUANT, scale_in / scale_out,
			  activation_min, activation_max);
	}
#else
	if (scale_in == scale_out)                           /* one soft-float compare per call */
		pblk_nest(input, output, od, os, os[3] == 1 ? PBLK_RUNS : PBLK_STRIDE, 1.0f,
			  activation_min, activation_max);
	else
		pblk_nest(input, output, od, os, PBLK_REQUANT, scale_in / scale_out,
			  activation_min, activation_max);
#endif
}
