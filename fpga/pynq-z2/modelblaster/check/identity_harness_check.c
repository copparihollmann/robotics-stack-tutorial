/* SPDX-License-Identifier: Apache-2.0
 *
 * Prove the identity harness on a known answer, on the host, before any board time.
 *
 * samples/roccmoon_bench section 2b runs one dispatch with A = 2I and a unit requantiser so that
 * the engine's output IS the weight matrix, which turns a wrong byte into a (plane, tile, quad,
 * word, byte) rather than a count -- the shape of the 0x5A5A0013 corruption, which nothing has
 * ever seen.  That only means anything if the identity setup itself is exact, so this checks it
 * against the same reference kernel the bench links:
 *
 *     cc -O2 -o idchk identity_harness_check.c ../../../samples/roccmoon_bench/src/ref_linear.c
 *
 * It found the first choice wrong.  (mult = 2^30, shift = -1) looks like x1 and is not: the
 * reference rounds in Q0.31 BEFORE applying the shift, so an odd accumulator comes out one too
 * high -- 41,472 of 82,944 bytes, exactly half.  A = 2I with (2^30, 0) gives floor(w + 1/2) = w
 * for both signs: 0 of 82,944.  Had the bench gone to the board with the first one, half the
 * output would have been 'wrong' on a healthy engine. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
void ref_kernel_linear_s8(const int8_t *in, const int8_t *w, const int32_t *bias, int8_t *out,
                          int M, int K, int N, int a, int b, int c,
                          int32_t mult, int shift, int amin, int amax);
int main(void) {
  const int K = 288, M = 288, N = 288;
  int8_t *w = malloc((size_t)N*K), *in = calloc((size_t)M*K, 1), *out = malloc((size_t)M*N);
  int32_t *bias = calloc(N, 4);
  for (int n = 0; n < N; n++) for (int k = 0; k < K; k++) w[(size_t)n*K+k] = (int8_t)((((n & 15) << 3) | (k & 7)) - 64);
  for (int m = 0; m < M; m++) in[(size_t)m*K+m] = 2;
  ref_kernel_linear_s8(in, w, bias, out, M, K, N, 0, 0, 0, 1 << 30, 0, -128, 127);
  size_t bad = 0;
  for (int m = 0; m < M; m++) for (int n = 0; n < N; n++) if (out[(size_t)m*N+n] != w[(size_t)n*K+m]) bad++;
  printf("identity harness: %zu of %d output bytes differ from the weights\n", bad, M*N);
  return bad != 0;
}
