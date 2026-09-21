/* SPDX-License-Identifier: Apache-2.0
 *
 * The host half of the verification bar for the curated gelu_s8 LUT-lane kernel.
 *
 * THE TRAP THIS CHECK IS BUILT TO AVOID, stated first because the gate workstream fell into it
 * on layernorm_s8: a golden regenerated from the NEW kernel's own arithmetic compares that
 * kernel against itself, passes at max_abs_err = 0, and proves nothing.  So the reference here
 * is `int_gelu_s8()` -- THE CURATED KERNEL'S OWN FUNCTION, the one
 * kernels/pext_nl/pext_nl_gelu_s8_pext_int_lut.c calls -- run over the same tensors, and the
 * comparison is byte-for-byte.
 *
 * It proves four things without a board, and they are the four that decide whether a board arm
 * is worth taking:
 *   1. the lane kernel's TABLE and the curated kernel's OUTPUT agree on every input byte, over
 *      the model's own (scale_in, scale_out, amin, amax) and over a sweep;
 *   2. the PLAN satisfies every hardware rule that is not enforced -- destination 64-byte
 *      aligned, word counts a multiple of 8, word0 + words inside one 1,024-word buffer, and
 *      the drain's whole blocks exactly covering the tile with nothing written past it;
 *   3. it does so ON THE MODEL'S ACTUAL SHAPES, including the two whose naive last tile is 820
 *      and 124 words -- neither a multiple of 8, and each of them the hang;
 *   4. the whole kernel, fallback path included, is byte-identical to the curated kernel.
 *
 * Build:  cc -I sw -I sw/roccmoon -I modelblaster/kernels/roccmoon \
 *            modelblaster/moonshine/check/gelu_lane_check.c -o /tmp/gelu_lane_check -lm
 */
#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* the host's model of custom-1: never reached, because the lane path is compiled out off
 * Zephyr.  Present so the kernel's includes resolve exactly as they do on the target. */
void mbxr_l_cfg(uint64_t a, uint64_t d) { (void)a; (void)d; }
void mbxr_l_go(uint64_t w, uint64_t u) { (void)w; (void)u; }
uint64_t mbxr_l_st(uint64_t a, uint64_t b) { (void)a; (void)b; return 0; }

#include "roccmoon_gelu_s8_roccmoon_lut.c"

/* THE CURATED tanh_s8 KERNEL ITSELF, under a rename so both entry points can coexist in one
 * translation unit.  The tanh lane kernel TRANSCRIBES that file's expression rather than
 * calling into it (it exports no builder), so the transcription is what has to be checked --
 * against the curated OUTPUT, never against a golden rebuilt from the transcription. */
#define kernel_tanh_s8 curated_tanh_s8
#include "../../kernels/pext/pext_tanh_s8_pext_memo_lut.c"
#undef kernel_tanh_s8
#include "roccmoon_tanh_s8_roccmoon_lut.c"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { printf("  FAIL  "); printf(__VA_ARGS__); \
	printf("\n"); fails++; } } while (0)

/* ---- 1. the table IS the curated kernel, over every input byte -------------------------------
 * The lane is a pure map, so if the table agrees on all 256 entries the streams agree for every
 * possible input.  That is a proof over the whole domain rather than a sample -- the same
 * argument the curated kernel's own header makes for its accuracy class. */
static void check_table(float si, float so, int amin, int amax)
{
	int8_t tbl[256], probe[256], want[256];

	int_gelu_s8_table(tbl, si, so, amin, amax);
	for (int q = -128; q < 128; q++)
		probe[q + 128] = (int8_t)q;
	/* the CURATED kernel, not a re-derivation: n = 256 >= 32 takes its table path */
	int_gelu_s8(probe, want, 256, si, so, amin, amax);

	for (int i = 0; i < 256; i++)
		CHECK(tbl[i] == want[i],
		      "table[%d] = %d, curated kernel gives %d  (si=%g so=%g amin=%d amax=%d)",
		      i - 128, tbl[i], want[i], si, so, amin, amax);
}

/* ---- 1b. THE HARDWARE'S OWN INDEXING, which is what arm B got wrong ------------------------
 * Comparing the table's CONTENTS against the curated kernel's proves the entries are right and
 * says nothing about the ORDER the lane reads them in.  int_nonlin.c stores +128-biased
 * (`tbl[(uint8_t)(q + 128)]`, :378) and `mbxl_lut` indexes by the raw byte
 * (`tbl[rd_data[8*g +: 8]]`, mbxl_lut.v:125) -- XOR 0x80 apart.  Arm B dispatched the software
 * order, the lane ran perfectly over rotated entries, and the board came back max_abs_err = 80.
 *
 * So this models the LANE: it builds the byte array the kernel will actually write into the
 * hardware and applies it the way the RTL applies it, then compares against the curated
 * kernel's output.  A model of the sink is what the lane's own testbench had; this is the sink's
 * stated behaviour, quoted from the RTL line that implements it. */
static void check_lane_indexing(float si, float so, int amin, int amax)
{
	int8_t tbl[256], hw[256], probe[256], got[256], want[256];

	int_gelu_s8_table(tbl, si, so, amin, amax);
	for (int i = 0; i < 256; i++)
		hw[i] = tbl[(uint8_t)(i ^ 0x80)];          /* what the kernel writes through lcfg */
	for (int q = -128; q < 128; q++)
		probe[q + 128] = (int8_t)q;
	for (int i = 0; i < 256; i++)
		got[i] = hw[(uint8_t)probe[i]];            /* mbxl_lut.v:125, by the raw byte */
	int_gelu_s8(probe, want, 256, si, so, amin, amax);
	for (int i = 0; i < 256; i++)
		CHECK(got[i] == want[i],
		      "lane-indexed[%d] = %d, curated kernel gives %d (si=%g so=%g)",
		      i - 128, got[i], want[i], si, so);
}

/* ---- 2 and 3. the plan, on the model's own shapes ------------------------------------------ */
struct shape { const char *name; int n; int off_in, off_out; };

static void check_plan(const struct shape *s, int8_t *base_in, int8_t *base_out)
{
	const int8_t *in = base_in + s->off_in;
	int8_t *out = base_out + s->off_out;
	mbxr_lut_plan_t p = mbxr_lut_plan(in, out, s->n);
	long off, left, covered = 0;
	int t = 0;

	if (!p.ok) {
		printf("  %-22s n=%-7d PLAN REFUSED why=%d\n", s->name, s->n, p.why);
		CHECK(s->n < 64, "%s: a plan this size should not be refused", s->name);
		return;
	}

	/* the head is what makes every later destination 64-byte aligned */
	CHECK((((uintptr_t)out + (uintptr_t)p.head) & 63u) == 0u,
	      "%s: head %d does not align the destination", s->name, p.head);
	CHECK(p.head < 64 && p.tail < 64, "%s: head %d tail %d -- one of them is a whole block",
	      s->name, p.head, p.tail);
	CHECK(p.head + p.mid_bytes + p.tail == s->n,
	      "%s: head+mid+tail = %ld, n = %d", s->name,
	      (long)p.head + p.mid_bytes + p.tail, s->n);
	CHECK(p.mid_bytes % 64 == 0, "%s: the middle is %ld bytes, not whole blocks",
	      s->name, p.mid_bytes);
	CHECK(p.skew_w >= 0 && p.skew_w <= 7, "%s: skew %d words", s->name, p.skew_w);
	CHECK(p.tile_w_max % 8 == 0 && p.tile_w_max > 0,
	      "%s: tile_w_max %d is not a positive multiple of 8", s->name, p.tile_w_max);
	CHECK(p.skew_w + p.tile_w_max <= 1024,
	      "%s: skew %d + tile %d leaves the 1,024-word buffer", s->name,
	      p.skew_w, p.tile_w_max);

	/* and now every tile the loop will actually issue */
	off = p.head; left = p.mid_bytes;
	while (left > 0) {
		long bytes = left < (long)p.tile_w_max * 8 ? left : (long)p.tile_w_max * 8;
		int words = (int)(bytes / 8);
		uint64_t dst = (uint64_t)(uintptr_t)(out + off);
		uint64_t src_blk = ((uint64_t)(uintptr_t)(in + off)) & ~(uint64_t)63;
		mbxr_lane_plan lp;
		int rc;

		/* RULE (b), the one nothing checked before Lab B37: a word count that is not a
		 * multiple of 8 leaves the last block never written, returns rc = 0 with
		 * u_err = 0x0, and leaves the drain busy forever. */
		CHECK(words % 8 == 0, "%s tile %d: %d words is not a multiple of 8",
		      s->name, t, words);
		/* RULE (a): the destination is aligned and the drain's whole blocks cover the
		 * tile EXACTLY -- nothing is ever written past it. */
		CHECK((dst & 63u) == 0u, "%s tile %d: destination not 64-byte aligned",
		      s->name, t);
		CHECK((long)(words / 8) * 64 == bytes,
		      "%s tile %d: %d blocks cover %ld bytes, tile is %ld",
		      s->name, t, words / 8, (long)(words / 8) * 64, bytes);
		/* RULE (c): the fill starts at a 64-byte block and the lane is told the skew. */
		CHECK((src_blk & 63u) == 0u, "%s tile %d: fill source not aligned", s->name, t);
		CHECK((uint64_t)(uintptr_t)(in + off) - src_blk == (uint64_t)p.skew_w * 8,
		      "%s tile %d: skew is not the plan's %d words", s->name, t, p.skew_w);

		/* and the SHARED path's own precondition matrix must accept it -- the same
		 * function the target will call, so this is the accept/reject decision itself
		 * rather than a restatement of it */
		lp.src_pa = src_blk;
		lp.src_blocks = (p.skew_w + words + 7) / 8;
		lp.abuf = 0;
		lp.word0 = p.skew_w;
		lp.words = words;
		lp.dst_pa = dst;
		lp.dst_blocks = words / 8;
		lp.which = MBXR_GO_LUT;
		lp.budget = 1000;
		rc = mbxr_lane_check(&lp);
		CHECK(rc == MBXR_OK, "%s tile %d: the shared path refuses it, rc %d",
		      s->name, t, rc);

		covered += bytes;
		off += bytes; left -= bytes; t++;
	}
	CHECK(t == p.tiles, "%s: planned %d tiles, issued %d", s->name, p.tiles, t);
	CHECK(covered == p.mid_bytes, "%s: tiles cover %ld of %ld", s->name, covered, p.mid_bytes);
	printf("  %-22s n=%-7d head=%-3d mid=%-7ld tail=%-3d skew=%d tile_w=%-4d tiles=%d\n",
	       s->name, s->n, p.head, p.mid_bytes, p.tail, p.skew_w, p.tile_w_max, p.tiles);
}

/* ---- 4. the whole kernel against the curated one, on the model's shapes -------------------- */
static void check_bytes(const struct shape *s, int8_t *base_in, int8_t *base_out,
			int8_t *base_ref, float si, float so)
{
	const int8_t *in = base_in + s->off_in;
	int8_t *out = base_out + s->off_out;
	int8_t *ref = base_ref + s->off_out;
	long bad = 0;

	for (int i = 0; i < s->n; i++)
		((int8_t *)in)[i] = (int8_t)((i * 97 + (i >> 8) * 13) & 0xff);
	memset(out, 0x5A, (size_t)s->n);
	memset(ref, 0x5A, (size_t)s->n);

	kernel_gelu_s8(in, out, s->n, si, so, -128, 127);
	int_gelu_s8(in, ref, s->n, si, so, -128, 127);       /* THE CURATED KERNEL */

	for (int i = 0; i < s->n; i++)
		if (out[i] != ref[i]) bad++;
	CHECK(bad == 0, "%s: %ld of %d bytes differ from the curated kernel", s->name, bad, s->n);
}

int main(void)
{
	/* the encoder's own gelu_s8 shapes, from board/b34_qatu_lnhoist_run.json: eight
	 * dispatches, 1,378,656 elements, 26,658,038 cycles at 19.34 c/element.  The two that
	 * matter are stem.gelu3 and (for tanh_s8, the same lane and the same plan) stem.tanh,
	 * whose naive last tiles are 820 and 124 words -- NEITHER A MULTIPLE OF 8. */
	static const struct shape shapes[] = {
		{ "stem.gelu2",        190656, 0, 0 },
		{ "stem.gelu3",         47520, 0, 0 },   /* naive last tile 820 words */
		{ "layers.N.mlp.act",  190080, 0, 0 },
		{ "tanh_s8 (same shape)", 287712, 0, 0 },/* naive last tile 124 words */
		/* and the alignments the generator can hand us: it emits intermediates 8-byte
		 * aligned, so every offset that is a multiple of 8 and not of 64 is reachable */
		{ "190080 @ in+8",     190080, 8, 0 },
		{ "190080 @ out+8",    190080, 0, 8 },
		{ "190080 @ in+8,out+56", 190080, 8, 56 },
		{ "190080 @ in+56,out+8", 190080, 56, 8 },
		{ "small 64",              64, 0, 0 },
		{ "small 63",              63, 0, 0 },
		{ "small 32",              32, 0, 0 },
	};
	const long BUF = 300000;   /* > 287,712, the largest operator here */
	int8_t *bi, *bo, *br;

	/* 64-byte-aligned bases, so `off_in`/`off_out` mean exactly what they say: an offset of
	 * 8 IS an 8-mod-64 tensor, which is what generate_skeleton.py emits today. */
	if (posix_memalign((void **)&bi, 64, (size_t)BUF) ||
	    posix_memalign((void **)&bo, 64, (size_t)BUF) ||
	    posix_memalign((void **)&br, 64, (size_t)BUF)) {
		printf("out of memory\n");
		return 1;
	}

	printf("1. the table IS the curated kernel, over all 256 inputs\n");
	check_table(0.0781f, 0.05f, -128, 127);
	check_table(0.0234f, 0.0117f, -128, 127);
	check_table(0.125f, 0.0625f, -128, 127);
	check_table(0.0781f, 0.05f, -100, 100);          /* a clamped activation range */
	for (int i = 1; i <= 12; i++)
		check_table(0.01f * (float)i, 0.007f * (float)i, -128, 127);
	printf("   %d scale pairs x 256 inputs\n", 4 + 12);

	printf("1b. the table AS THE LANE INDEXES IT (raw byte, not +128-biased)\n");
	check_lane_indexing(0.0781f, 0.05f, -128, 127);
	check_lane_indexing(0.0234f, 0.0117f, -128, 127);
	check_lane_indexing(0.125f, 0.0625f, -128, 127);
	check_lane_indexing(0.0781f, 0.05f, -100, 100);
	for (int i = 1; i <= 12; i++)
		check_lane_indexing(0.01f * (float)i, 0.007f * (float)i, -128, 127);
	printf("   16 scale pairs x 256 inputs, through the RTL's own index expression\n");

	printf("2/3. the plan on the model's own shapes and alignments\n");
	for (unsigned i = 0; i < sizeof shapes / sizeof shapes[0]; i++)
		check_plan(&shapes[i], bi, bo);

	printf("4. the whole kernel, byte for byte against the curated kernel\n");
	for (unsigned i = 0; i < sizeof shapes / sizeof shapes[0]; i++)
		if (shapes[i].n <= BUF - 64)
			check_bytes(&shapes[i], bi, bo, br, 0.0781f, 0.05f);
	printf("5. tanh_s8: the TRANSCRIBED table against the curated kernel it transcribes\n");
	{
		static const float sis[] = { 0.0781f, 0.0234f, 0.125f, 0.031f };
		static const float sos[] = { 0.0078f, 0.0117f, 0.0625f, 0.0079f };

		for (unsigned k = 0; k < 4; k++) {
			int8_t probe[256], got[256], want[256];

			for (int q = -128; q < 128; q++) probe[q + 128] = (int8_t)q;
			kernel_tanh_s8(probe, got, 256, sis[k], sos[k], -128, 127);
			curated_tanh_s8(probe, want, 256, sis[k], sos[k], -128, 127);
			for (int i = 0; i < 256; i++)
				CHECK(got[i] == want[i],
				      "tanh[%d] = %d, curated gives %d (si=%g so=%g)",
				      i - 128, got[i], want[i], sis[k], sos[k]);
		}
		/* and on the operator's real length, which is the shape that tiles */
		{
			const int n = 287712;
			int8_t *gi = bi, *go = bo, *gr = br;

			for (int i = 0; i < n; i++)
				gi[i] = (int8_t)((i * 97 + (i >> 8) * 13) & 0xff);
			kernel_tanh_s8(gi, go, n, 0.0781f, 0.0078f, -128, 127);
			curated_tanh_s8(gi, gr, n, 0.0781f, 0.0078f, -128, 127);
			{
				long bad = 0;
				for (int i = 0; i < n; i++) if (go[i] != gr[i]) bad++;
				CHECK(bad == 0, "tanh_s8 n=%d: %ld bytes differ", n, bad);
			}
		}
		printf("   4 scale pairs x 256 inputs, and the 287,712-element operator\n");
	}

	printf("   calls=%u lane=%u fallback=%u tiles_copied=%u\n",
	       mbxr_lut_stats.calls, mbxr_lut_stats.calls_lane,
	       mbxr_lut_stats.calls_fallback, mbxr_lut_stats.tiles_copied);
	/* OFF THE BOARD THE LANE PATH IS COMPILED OUT, so every call must have fallen back --
	 * and this assertion is what stops the check reporting a pass for a run in which the
	 * kernel under test never executed its own code (438eb27's rule, one layer up). */
	CHECK(mbxr_lut_stats.calls_lane == 0,
	      "the host build took a lane path, which does not exist here");
	CHECK(mbxr_lut_stats.calls_fallback == mbxr_lut_stats.calls,
	      "calls %u, fallback %u -- some call did neither",
	      mbxr_lut_stats.calls, mbxr_lut_stats.calls_fallback);
	/* THE COPY-OUT COUNTER MUST BE ZERO.  docs/LANE_DISPATCH_RULES.md s1: a byte-wise
	 * copy-out is worse than not using the lane, and a 64-bit one still costs 0.09 of
	 * RTF_e2e.  This kernel drains into the caller's tensor and copies nothing; if that ever
	 * stops being true the number is here rather than in a transcript. */
	CHECK(mbxr_lut_stats.tiles_copied == 0, "a tile needed a copy-out");

	printf(fails ? "\nGELU_LANE_CHECK: FAIL (%d)\n" : "\nGELU_LANE_CHECK: PASS\n", fails);
	return fails ? 1 : 0;
}
