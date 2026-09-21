/* THE PLANE COUNT IS A PARAMETER, NOT A FOUR.  The attention lane's weight image is planar
 * exactly as the engine's is (mbxr.c: n = (t*Q + q)*NCH + r), and it was written with the
 * literal 4 in three places -- here, the kernel's own builder, and tb_attn.cpp -- while
 * mbxr.c was parameterised at 23 of 23 sites.  At NCH = 8 the hardware reads NCH planes and
 * produces NCH finals a quad; an image laid out 4j+c across four planes then feeds it rows
 * that were never written, |acc| passes 2^24 and mbxa_unit raises err[2].  That is what
 * 0x5A5A0034 did on garden: attn_lane 0, attn_fallback 6, 111x slow, max_abs_err 0.
 * At MBXA_NCH = 4 every expression below folds to exactly what it folded to before. */
#ifndef MBXA_NCH
#define MBXA_NCH 4
#endif

static void mbxa_build_q(const int8_t *q, int T, int D, int gs, int8_t *img)
{
	int t, d, W = gs * 8;
	for (t = 0; t < T; t++) {
		const int8_t *src = q + (size_t)t * D;
		int8_t *dst = img + (size_t)t * W;
		for (d = 0; d < D; d++) dst[d] = src[d];
		for (d = D; d < W; d++) dst[d] = 0;
	}
}
static void mbxa_build_w(const int8_t *k, const int8_t *v, int N, int D,
			 int gs, int qs, int gp, int qp, int lgpw,
			 int kbase_w, int vtbase_w, int8_t *img)
{
	const size_t plane = (size_t)1 << lgpw;          /* words per plane */
	int c, j, w, b;

	for (c = 0; c < MBXA_NCH; c++) {
		int8_t *P = img + (size_t)c * plane * 8;
		/* k quads: row MBXA_NCH*j+c of k, gs words, behind a zero bias word */
		for (j = 0; j < qs; j++) {
			int8_t *quad = P + (size_t)(kbase_w + j * (gs + 1)) * 8;
			int row = MBXA_NCH * j + c;
			for (b = 0; b < 8; b++) quad[b] = 0;             /* the bias word */
			for (w = 0; w < gs * 8; w++)
				quad[8 + w] = (row < N && w < D) ? k[(size_t)row * D + w] : 0;
		}
		/* v^T quads: row MBXA_NCH*j+c of v^T, i.e. that COLUMN of v, gp words */
		for (j = 0; j < qp; j++) {
			int8_t *quad = P + (size_t)(vtbase_w + j * (gp + 1)) * 8;
			int col = MBXA_NCH * j + c;
			for (b = 0; b < 8; b++) quad[b] = 0;
			for (w = 0; w < gp * 8; w++)
				quad[8 + w] = (col < D && w < N) ? v[(size_t)w * D + col] : 0;
		}
	}
}
