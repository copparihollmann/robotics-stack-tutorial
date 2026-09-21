/* SPDX-License-Identifier: Apache-2.0
 *
 * B87LN's pre-board gate: the shipped layernorm_s8 against the cached one, BYTE FOR BYTE,
 * at the decoder's own shape and over its own dispatch sequence.  Host only.
 *
 * A CACHE HAS A FAILURE MODE NO OTHER LEVER IN THIS CAMPAIGN HAS HAD: a FALSE HIT.  Every
 * other gate here asks "does the fast route compute the same thing?".  This one must also
 * ask "did the fast route answer a question it was not asked?" -- because the key is a
 * POINTER PAIR, and a pointer is a valid key only if it is unique over the domain it
 * joins.  That is the cardinality axis, added to this campaign's instrument list tonight
 * after a non-unique join key reported false disagreement on 1,840 ops; here the same
 * defect would report false AGREEMENT, which is the direction that flatters.
 *
 * So three of the cases below are about the KEY rather than the arithmetic:
 *   same pointers, different scale_out   -> must MISS (the table folds 1/scale_out)
 *   same pointers, mutated contents      -> must MISS (the content witnesses)
 *   distinct pointers, equal contents    -> may hit or miss, and must be RIGHT either way
 * and the sweep asserts the hit count, because a cache that never hits is byte-perfect
 * and worth nothing.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

void ln_ship(const int8_t *, const float *, const float *, int8_t *,
	     int, int, float, float, float, int, int);
void ln_cache(const int8_t *, const float *, const float *, int8_t *,
	      int, int, float, float, float, int, int);
extern unsigned long ln_cache_hits, ln_cache_misses;

#define K 288
#define SITES 12
#define STEPS 38
#define MMAX 4

static int8_t xin[K * MMAX], ya[K * MMAX], yb[K * MMAX];
static float sg[SITES][K], sb[SITES][K];
static float mg[K], mb[K];

static uint64_t rs_ = 0x2545F4914F6CDD1Dull;
static uint32_t rnd(void) { rs_ ^= rs_ << 13; rs_ ^= rs_ >> 7; rs_ ^= rs_ << 17; return (uint32_t)(rs_ >> 32); }

static long bytes_, bad_, cases_;

static void cmp(const char *what, int n)
{
	long bad = 0;
	int i;

	for (i = 0; i < n; i++) {
		if (ya[i] != yb[i]) {
			if (bad < 3) {
				printf("    %s: byte %d  ship %d  cache %d\n",
				       what, i, (int)ya[i], (int)yb[i]);
			}
			bad++;
		}
	}
	bytes_ += n; bad_ += bad; cases_++;
}

static void run(const char *tag, const float *g, const float *b, int M,
		float si, float so, float eps, int amin, int amax)
{
	int i;

	for (i = 0; i < M * K; i++) {
		xin[i] = (int8_t)(uint8_t)(rnd() >> 9);
	}
	memset(ya, 0x5A, sizeof ya);
	memset(yb, 0xA5, sizeof yb);
	ln_ship(xin, g, b, ya, M, K, si, so, eps, amin, amax);
	ln_cache(xin, g, b, yb, M, K, si, so, eps, amin, amax);
	cmp(tag, M * K);
}

int main(void)
{
	int i, k, t;
	unsigned long m0;

	for (i = 0; i < SITES; i++) {
		for (k = 0; k < K; k++) {
			sg[i][k] = 1.0f + (float)((int32_t)(rnd() % 2000) - 1000) / 4000.0f;
			sb[i][k] = (float)((int32_t)(rnd() % 2000) - 1000) / 8000.0f;
		}
	}

	printf("--- the decoder's own sequence: %d sites x %d steps, M=1 K=%d ---\n",
	       SITES, STEPS, K);
	ln_cache_hits = ln_cache_misses = 0;
	for (t = 0; t < STEPS; t++) {
		for (i = 0; i < SITES; i++) {
			run("seq", sg[i], sb[i], 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
		}
	}
	printf("    hits=%lu misses=%lu  (expect %d hits, %d misses)\n",
	       ln_cache_hits, ln_cache_misses, SITES * (STEPS - 1), SITES);
	if (ln_cache_hits != (unsigned long)(SITES * (STEPS - 1)) ||
	    ln_cache_misses != (unsigned long)SITES) {
		printf("    *** THE CACHE DID NOT BEHAVE AS A CACHE -- a byte-perfect route that "
		       "never hits is worth nothing\n");
		bad_++;
	}

	printf("--- the key: three cases that are about cardinality, not arithmetic ---\n");
	/* 1. same pointers, different scale_out: the table folds 1/scale_out, so it MUST miss */
	m0 = ln_cache_misses;
	run("key/scale_out", sg[0], sb[0], 1, 0.0116899032f, 0.031f, 1e-5f, -128, 127);
	printf("    different scale_out on a cached pointer pair: %s\n",
	       ln_cache_misses > m0 ? "MISSED (correct)" : "*** HIT -- FALSE HIT ***");
	if (ln_cache_misses == m0) { bad_++; }

	/* 2. same pointers, mutated contents: the witnesses MUST catch it */
	for (k = 0; k < K; k++) { mg[k] = sg[1][k]; mb[k] = sb[1][k]; }
	run("key/mutate-pre", mg, mb, 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	mg[0] = mg[0] * 1.5f;            /* a witness position */
	m0 = ln_cache_misses;
	run("key/mutate-w0", mg, mb, 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	printf("    gamma[0] mutated under a cached pointer: %s\n",
	       ln_cache_misses > m0 ? "MISSED (correct)" : "*** HIT -- FALSE HIT ***");
	if (ln_cache_misses == m0) { bad_++; }

	mb[K - 1] = mb[K - 1] - 0.25f;   /* the other end */
	m0 = ln_cache_misses;
	run("key/mutate-wK", mg, mb, 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	printf("    beta[K-1] mutated under a cached pointer: %s\n",
	       ln_cache_misses > m0 ? "MISSED (correct)" : "*** HIT -- FALSE HIT ***");
	if (ln_cache_misses == m0) { bad_++; }

	/* THE CASE THAT REJECTED THE FIRST DESIGN.  A four-witness key is blind to the
	 * interior; this mutation produced a FALSE HIT and a wrong output byte, and the
	 * first version of this gate recorded that as "a known limit" -- which is the wrong
	 * answer to a correctness hazard.  With a content hash it must MISS. */
	mg[K / 2] = mg[K / 2] * 2.0f;
	m0 = ln_cache_misses;
	run("key/mutate-interior", mg, mb, 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	printf("    gamma[K/2] mutated (INTERIOR): %s\n",
	       ln_cache_misses > m0 ? "MISSED (correct)" : "*** HIT -- FALSE HIT ***");
	if (ln_cache_misses == m0) { bad_++; }

	printf("--- arithmetic: shapes, clamps and scales the graph does and does not ship ---\n");
	run("M=1 model", sg[2], sb[2], 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	run("M=2", sg[3], sb[3], 2, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	run("M=4", sg[4], sb[4], 4, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	run("clamped", sg[5], sb[5], 1, 0.0116899032f, 0.024689531f, 1e-5f, -100, 90);
	run("tiny so", sg[6], sb[6], 1, 0.0116899032f, 1e-6f, 1e-5f, -128, 127);
	run("big so", sg[7], sb[7], 1, 0.0116899032f, 8.0f, 1e-5f, -128, 127);
	run("tiny si", sg[8], sb[8], 1, 1e-6f, 0.024689531f, 1e-9f, -128, 127);
	run("big eps", sg[9], sb[9], 1, 0.0116899032f, 0.024689531f, 1.0f, -128, 127);
	/* gamma with negatives and large magnitudes: gneg and the packed gs/b8 guards */
	for (k = 0; k < K; k++) {
		mg[k] = (float)((int32_t)(rnd() % 20000) - 10000) / 100.0f;
		mb[k] = (float)((int32_t)(rnd() % 20000) - 10000) / 100.0f;
	}
	run("wide gamma/beta", mg, mb, 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	for (k = 0; k < K; k++) { mg[k] = -mg[k]; }
	run("negated gamma", mg, mb, 1, 0.0116899032f, 0.024689531f, 1e-5f, -128, 127);
	/* magnitudes that should trip the packed-entry narrowing guard and fall back */
	for (k = 0; k < K; k++) { mg[k] = 3e30f; mb[k] = 3e30f; }
	run("overflowing beta", mg, mb, 1, 1e-30f, 1e-30f, 1e-5f, -128, 127);

	printf("MB_B87LN_GATE cases=%ld bytes=%ld mismatches=%ld %s\n",
	       cases_, bytes_, bad_, bad_ ? "FAIL" : "PASS");
	return bad_ ? 1 : 0;
}
