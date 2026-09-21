/* SPDX-License-Identifier: Apache-2.0
 *
 * permute4_s8 pext_block against ModelBlaster's reference implementation (extracted verbatim
 * from pipeline/reference_kernels.py into permute_ref.c by the build line below): all 24
 * permutations, random extents 1..40 per axis, Moonshine's three shapes, pure and requantising
 * (scale_in != scale_out, random clip ranges).  Exit 0 only if every output byte matches.
 *
 *   python3 -c "import re;s=open('<MB>/pipeline/reference_kernels.py').read();\
 *     print(re.search(r'op=\"permute4_s8\".*?reference_impl=\"\"\"\\\\\n(.*?)\"\"\",',s,re.S).group(1))" > permute_ref.c
 *   cc -O2 -std=gnu11 -ffp-contract=off -I. check/permute_block_exact.c -o permute_block_exact
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define kernel_permute4_s8 kernel_permute4_s8_ref
#include "permute_ref.c"
#undef kernel_permute4_s8
#define kernel_permute4_s8 kernel_permute4_s8_block
#include "kernels_t1/pext_nl/pext_nl_permute4_s8_pext_block.c"
#undef kernel_permute4_s8

static uint64_t rs = 0x243F6A8885A308D3ull;
static uint64_t xr(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }

static int run(int d[4], int p[4], float si, float so, int amin, int amax, long *bytes)
{
	size_t n = (size_t)d[0] * d[1] * d[2] * d[3];
	int8_t *in = malloc(n + 1), *a = malloc(n + 1), *b = malloc(n + 1);
	for (size_t i = 0; i < n; i++) in[i] = (int8_t)xr();
	memset(a, 0x11, n); memset(b, 0x22, n);
	kernel_permute4_s8_ref(in, a, d[0], d[1], d[2], d[3], p[0], p[1], p[2], p[3], si, so, amin, amax);
	kernel_permute4_s8_block(in, b, d[0], d[1], d[2], d[3], p[0], p[1], p[2], p[3], si, so, amin, amax);
	int bad = memcmp(a, b, n) != 0;
	*bytes += (long)n;
	free(in); free(a); free(b);
	return bad;
}

int main(void)
{
	int perms[24][4], np = 0;
	for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) for (int k = 0; k < 4; k++) for (int l = 0; l < 4; l++)
		if (i != j && i != k && i != l && j != k && j != l && k != l) { perms[np][0] = i; perms[np][1] = j; perms[np][2] = k; perms[np][3] = l; np++; }
	long cases = 0, bad = 0, bytes = 0;
	int moon[3][8] = { { 1, 165, 8, 36, 0, 2, 1, 3 }, { 1, 8, 165, 36, 0, 2, 1, 3 }, { 1, 288, 1, 165, 0, 2, 3, 1 } };
	for (int m = 0; m < 3; m++) {
		int d[4] = { moon[m][0], moon[m][1], moon[m][2], moon[m][3] }, p[4] = { moon[m][4], moon[m][5], moon[m][6], moon[m][7] };
		bad += run(d, p, 0.28592024f, 0.28592024f, -128, 127, &bytes); cases++;
		bad += run(d, p, 0.28592024f, 0.1f, -100, 90, &bytes); cases++;
	}
	for (int t = 0; t < 20000; t++) {
		int d[4], *p = perms[xr() % 24];
		for (int k = 0; k < 4; k++) d[k] = 1 + (int)(xr() % ((xr() & 3) ? 12 : 40));
		float si = (float)(1 + xr() % 1000) / 997.0f, so = (xr() & 1) ? si : (float)(1 + xr() % 1000) / 991.0f;
		int amin = -128, amax = 127;
		if (xr() % 3 == 0) { amin = -(int)(xr() % 129); amax = (int)(xr() % 128); }
		bad += run(d, p, si, so, amin, amax, &bytes); cases++;
	}
	printf("permute_block_exact: %ld cases, %ld output bytes, %ld mismatching cases: %s\n", cases, bytes, bad, bad ? "FAIL" : "OK");
	return bad ? 1 : 0;
}
