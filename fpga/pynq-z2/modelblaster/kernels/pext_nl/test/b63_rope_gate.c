/* SPDX-License-Identifier: Apache-2.0 */
/*
 * B63's pre-board gate for pext_nl_rope_s8_pext_int_rot.c -- host only, no board.
 *
 * The change is a PURE RESTRUCTURING: the three per-i stack arrays and the per-i `slow`
 * flag become one array of 32-byte entries carrying the tie test's two constants already
 * folded, `slow[i]` is expressed as g = half (which makes the tie test true for every x,
 * so the element takes the same exact path it took before), `fast` is hoisted out of the
 * i loop, and the full [-128, 127] clamp uses CLIP8.  Not one output byte may move.
 *
 * Compared: a = B63 default, b = -DMBP_ROPE_NO_FAST=1 (the shipping kernel).
 *
 * Coverage.  The arms can only differ through (i) the tie decision, (ii) the slow-entry
 * decision, (iii) the clamp, (iv) loop bounds.  So: ALL 65,536 (a0, a1) pairs at EVERY
 * one of the R2 table positions, at the encoder's and decoder's own scale pairs; rotary
 * tables that are the model's own shape plus adversarial rows chosen to drive entries
 * into `slow` (|c| or |s| large enough to overflow fx32_apply, and G >= half/2); every
 * (T, H, D, R) the graph dispatches plus a sweep of odd ones; and narrowed clamps.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

void rope_a(const int8_t *, const float *, const float *, int8_t *,
	    int, int, int, int, float, float, int, int);
void rope_b(const int8_t *, const float *, const float *, int8_t *,
	    int, int, int, int, float, float, int, int);

#define TMAX 8
#define HMAX 256
#define DMAX 64
#define R2MAX 32
#define NEL (TMAX * HMAX * DMAX)

static int8_t in[NEL], oa[NEL], ob[NEL];
static float ct[TMAX * R2MAX], st[TMAX * R2MAX];

static long fails, cases;
static uint64_t rs = 0xDEADBEEF12345678ull;
static uint64_t rnd(void)
{
	rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
	return rs;
}

static int cmp(const char *what, int T, int H, int D, int R, float si, float so,
	       int lo, int hi)
{
	const long n = (long)T * H * D;
	long i;

	memset(oa, 0x5a, sizeof(oa));
	memset(ob, 0xa5, sizeof(ob));
	rope_a(in, ct, st, oa, T, H, D, R, si, so, lo, hi);
	rope_b(in, ct, st, ob, T, H, D, R, si, so, lo, hi);
	cases++;
	for (i = 0; i < n; i++) {
		if (oa[i] != ob[i]) {
			if (fails < 10) {
				printf("MISMATCH %s at %ld  new=%d ship=%d  "
				       "T=%d H=%d D=%d R=%d si=%.9g so=%.9g clamp=[%d,%d]\n",
				       what, i, oa[i], ob[i], T, H, D, R,
				       (double)si, (double)so, lo, hi);
			}
			fails++;
			return 1;
		}
	}
	return 0;
}

/* Moonshine's own rotary shape: theta = t / 10000^(2i/R). */
static void tables_model(int T, int R2, int R)
{
	int t, i;

	for (t = 0; t < T; t++) {
		for (i = 0; i < R2; i++) {
			double f = (double)t / pow(10000.0, (2.0 * i) / (double)R);

			ct[t * R2 + i] = (float)cos(f);
			st[t * R2 + i] = (float)sin(f);
		}
	}
}

/* Rows that force entries into the slow class: fx32_apply overflow, and G >= half/2. */
static void tables_adversarial(int T, int R2)
{
	int t, i;

	for (t = 0; t < T; t++) {
		for (i = 0; i < R2; i++) {
			switch ((t * R2 + i) % 8) {
			case 0: ct[t * R2 + i] = 0.0f;      st[t * R2 + i] = 1.0f;      break;
			case 1: ct[t * R2 + i] = 1.0f;      st[t * R2 + i] = 0.0f;      break;
			case 2: ct[t * R2 + i] = -1.0f;     st[t * R2 + i] = -1.0f;     break;
			case 3: ct[t * R2 + i] = 3e38f;     st[t * R2 + i] = 1.0f;      break;
			case 4: ct[t * R2 + i] = 1.0f;      st[t * R2 + i] = 3e38f;     break;
			case 5: ct[t * R2 + i] = 1e-30f;    st[t * R2 + i] = 1e-30f;    break;
			case 6: ct[t * R2 + i] = 0.5f;      st[t * R2 + i] = 0.8660254f;break;
			default:
				ct[t * R2 + i] = (float)((double)(int64_t)rnd() / 9.3e18);
				st[t * R2 + i] = (float)((double)(int64_t)rnd() / 9.3e18);
			}
		}
	}
}

/* Every (a0, a1) pair at every table position i: a0 fixed across the run, a1 sweeping
 * over h.  H = 256 makes one run cover 256 pairs at each (t, i); 256 runs cover all. */
static void sweep_pairs(int T, int H, int D, int R, float si, float so, const char *what)
{
	int a0, t, h, d;

	for (a0 = 0; a0 < 256; a0++) {
		for (t = 0; t < T; t++) {
			for (h = 0; h < H; h++) {
				for (d = 0; d < D; d++) {
					long ix = ((long)t * H + h) * D + d;

					if (d < R) {
						in[ix] = (d & 1) ? (int8_t)(uint8_t)h
								 : (int8_t)(uint8_t)a0;
					} else {
						in[ix] = (int8_t)(uint8_t)(h + d);
					}
				}
			}
		}
		if (cmp(what, T, H, D, R, si, so, -128, 127)) {
			return;
		}
	}
}

int main(void)
{
	/* the encoder's 12 and a spread of the decoder's 288 scale pairs */
	static const float sc[][2] = {
		{ 0.0563248396f, 0.0632022619f }, { 0.0890492871f, 0.0915410593f },
		{ 0.0451285653f, 0.0445857197f }, { 0.0596134737f, 0.0589658991f },
		{ 0.0380824581f, 0.0369582586f }, { 0.0763365701f, 0.0759598762f },
		{ 0.0204842519f, 0.0204842519f }, { 0.0229028817f, 0.0229028817f },
		{ 0.0244491715f, 0.0244491715f }, { 0.0258020982f, 0.0258020982f },
		{ 0.02616488f, 0.02616488f },     { 0.0915410593f, 0.0890492871f },
	};
	const int nsc = (int)(sizeof(sc) / sizeof(sc[0]));
	int c, i;

	setvbuf(stdout, NULL, _IONBF, 0);

	/* 1. all 65,536 (a0, a1) pairs at every i, model tables, both halves' scales. */
	tables_model(2, 16, 32);
	for (c = 0; c < nsc; c++) {
		sweep_pairs(2, 256, 36, 32, sc[c][0], sc[c][1], "pairs/model");
	}
	printf("1. all (a0,a1) x 16 positions x %d scale pairs, model tables: "
	       "%ld cases, %ld fail\n", nsc, cases, fails);

	/* 2. the same, on tables built to put entries in the slow class. */
	tables_adversarial(2, 16);
	for (c = 0; c < nsc; c++) {
		sweep_pairs(2, 256, 36, 32, sc[c][0], sc[c][1], "pairs/adversarial");
	}
	printf("2. the same over adversarial tables (slow entries, overflow, ties): "
	       "cumulative %ld cases, %ld fail\n", cases, fails);

	/* 3. shape sweep: R2 from 1 to 32, D from R to 64, T and H small. */
	for (i = 0; i < NEL; i++) {
		in[i] = (int8_t)(uint8_t)rnd();
	}
	for (c = 2; c <= 64; c += 2) {
		int R = c, D = c;

		tables_model(4, R / 2, R);
		cmp("shape", 4, 7, D, R, 0.0563248396f, 0.0632022619f, -128, 127);
		if (D + 4 <= DMAX) {
			cmp("shape", 4, 7, D + 4, R, 0.0563248396f, 0.0632022619f, -128, 127);
		}
		tables_adversarial(4, R / 2);
		cmp("shape-adv", 4, 7, D, R, 0.0890492871f, 0.0915410593f, -128, 127);
	}
	/* R2 above MBP_ROPE_R2MAX: both arms must fall to the whole-dispatch slow path. */
	tables_model(2, 32, 64);
	cmp("R2-overflow", 2, 3, 64, 64, 0.0563248396f, 0.0632022619f, -128, 127);
	printf("3. shape sweep incl. R2 at and over MBP_ROPE_R2MAX: "
	       "cumulative %ld cases, %ld fail\n", cases, fails);

	/* 4. random and out-of-domain scale pairs, and narrowed clamps. */
	tables_model(4, 16, 32);
	for (c = 0; c < 3000; c++) {
		union { uint32_t u; float f; } p, q;
		int e1 = -40 + (int)(rnd() % 49), e2 = -40 + (int)(rnd() % 49);

		p.u = ((uint32_t)(e1 + 127) << 23) | (uint32_t)(rnd() & 0x7fffffu);
		q.u = ((uint32_t)(e2 + 127) << 23) | (uint32_t)(rnd() & 0x7fffffu);
		cmp("random-scale", 4, 7, 36, 32, p.f, q.f, -128, 127);
	}
	{
		const float bad[] = { -1.0f, 1e30f, 1e-30f, 3e38f, 1e-44f };
		unsigned x, y;

		for (x = 0; x < 5; x++) {
			for (y = 0; y < 5; y++) {
				cmp("out-of-domain", 4, 7, 36, 32, bad[x], bad[y], -128, 127);
			}
		}
	}
	for (c = 0; c < nsc; c++) {
		cmp("clamp", 4, 7, 36, 32, sc[c][0], sc[c][1], 0, 127);
		cmp("clamp", 4, 7, 36, 32, sc[c][0], sc[c][1], -128, 0);
		cmp("clamp", 4, 7, 36, 32, sc[c][0], sc[c][1], -13, 29);
	}
	printf("4. random / out-of-domain scales and narrowed clamps: "
	       "cumulative %ld cases, %ld fail\n", cases, fails);

	printf("\n%s: %ld dispatches byte-for-byte, %ld mismatches\n",
	       fails ? "GATE FAILED" : "GATE PASSED", cases, fails);
	return fails ? 1 : 0;
}
