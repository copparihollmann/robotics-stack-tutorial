/* SPDX-License-Identifier: Apache-2.0
 *
 * mbxr -- driver for the decoupled RoCC engine.  See mbxr.h.
 *
 * THE TILE PLAN.  A dispatch is (activation tiles) x (weight tiles).  Whichever operand
 * is cheaper to re-fetch goes on the inner loop: re-reading the activations once per
 * weight tile costs tiles_w * act_bytes, re-reading the weights once per activation tile
 * costs tiles_a * wgt_bytes, and the plan takes the smaller -- the same arithmetic
 * ROCC_DECOUPLED.md 7.5's traffic column is.
 *
 * DOUBLE BUFFERING.  Each operand has two buffers.  A tile computes from one pair; the next
 * tile's changed operand is loaded into the other buffer while it computes.  The fill
 * engine and the sequencer share nothing but the scratchpad, and they never touch the same
 * banks, so the overlap is free.
 *
 * ONE DRAIN PER DISPATCH.  The quantised bytes of every tile stream into one `st` of
 * ceil(total/64) blocks; a final padding tile makes the total a whole number of blocks.
 * The bytes land in tile order in `scratch` and are placed into the [npix, N] output here.
 *
 * INCREMENTAL PLACEMENT (dev->place_early).  Placement walks the same tile order with a
 * cursor, so it can run while hart 1 would otherwise only poll: between tiles and during the
 * last one.  Each wait places at most MBXR_PLACE_SLICE bytes between polls, so the next
 * command is late by one slice at most.  It reads ONLY blocks below the drain's acknowledged
 * watermark (fence bits 63:48, a revision-2 engine): a block is complete when its AccessAck
 * says so, not after some number of cycles -- the L2 has been measured taking 139-300 cycles
 * to complete a Put under a miss stream, and modelled stalling for thousands.  A revision-1
 * engine reports 0 there, so nothing is placed early.  The bytes placed and their order are
 * exactly those of the late path; tb_mbxr checks both, under L2-like ack latency.
 */
#include "mbxr.h"

#define W64(p, v)  do { uint64_t _v = (uint64_t)(v); uint8_t *_p = (uint8_t *)(p); \
                        for (int _i = 0; _i < 8; _i++) _p[_i] = (uint8_t)(_v >> (8 * _i)); } while (0)

static int lg2ceil(uint64_t x)
{
  int l = 0;
  while ((1ULL << l) < x) l++;
  return l;
}

/* ---- the sub-byte weight grid ------------------------------------------------------------
 * ONE definition of the bit order, used by the builder here and by anything that checks it.
 * Code k at bits [6k, 6k+6) of the row, LSB first, two's complement.  Four codes fill three
 * bytes exactly, and a little-endian 64-bit word therefore yields ascending k with no byte
 * swap -- which is what lets the engine's read-port unpacker be a 48-bit select and a phase
 * counter instead of a shifter. */
void mbxr_pack6(const int8_t *codes, int K, uint8_t *dst)
{
  for (int i = 0; i < K; i += 4) {
    unsigned c0 = (unsigned)(codes[i]     & 0x3f);
    unsigned c1 = (unsigned)(codes[i + 1] & 0x3f);
    unsigned c2 = (unsigned)(codes[i + 2] & 0x3f);
    unsigned c3 = (unsigned)(codes[i + 3] & 0x3f);
    uint8_t *d = dst + (i >> 2) * 3;
    d[0] = (uint8_t)(c0 | (c1 << 6));
    d[1] = (uint8_t)((c1 >> 2) | (c2 << 4));
    d[2] = (uint8_t)((c2 >> 4) | (c3 << 2));
  }
}

void mbxr_unpack6(const uint8_t *src, int K, int8_t *codes)
{
  for (int i = 0; i < K; i += 4) {
    const uint8_t *d = src + (i >> 2) * 3;
    unsigned v = (unsigned)d[0] | ((unsigned)d[1] << 8) | ((unsigned)d[2] << 16);
    for (int j = 0; j < 4; j++) {
      unsigned c = (v >> (6 * j)) & 0x3f;
      codes[i + j] = (int8_t)(c & 0x20 ? (int)c - 64 : (int)c);   /* sign-extend 6 -> 8 */
    }
  }
}

/* One pass, no staging buffer: pack `Kp` codes where the first `n` come from `codes` and the
 * rest are the row's zero padding, clamping anything outside [-31, 31] and returning how many
 * were clamped.  A builder that has to clamp is building a six-bit image out of an EIGHT-bit
 * grid, which is a different defect from a broken unpacker and has to stay distinguishable
 * from it -- hence a count rather than silence, and a count rather than a refusal, because the
 * caller is inside a row callback with nowhere to return to. */
uint64_t mbxr_pack6_rowz(const int8_t *codes, int n, int Kp, uint8_t *dst)
{
  uint64_t clipped = 0;
  for (int i = 0; i < Kp; i += 4) {
    unsigned q = 0;
    for (int j = 0; j < 4; j++) {
      int c = 0;
      if (i + j < n) {
        c = codes[i + j];
        if (c > 31) { c = 31; clipped++; }
        else if (c < -31) { c = -31; clipped++; }
      }
      q |= ((unsigned)(c & 0x3f)) << (6 * j);
    }
    uint8_t *d = dst + (i >> 2) * 3;
    d[0] = (uint8_t)q; d[1] = (uint8_t)(q >> 8); d[2] = (uint8_t)(q >> 16);
  }
  return clipped;
}

size_t mbxr_wimage_plan_bits(mbxr_wimage *img, int N, int K, int wbits, int for_strided_drain)
{
  if (N <= 0 || K <= 0 || (K % 8) != 0) return 0;
  if (wbits != 8 && wbits != 6) return 0;
  /* A packed row has to be a whole number of 64-bit words: the scratchpad has no sub-word
   * addressing and the plane mapper moves words, not bits. */
  if (((long)K * wbits % 64) != 0) return 0;
  int Kw = (int)((long)K * wbits / 8);
  int G = Kw / 8;
  if (G + 1 > MBXR_BUF_WORDS) return 0;
  /* The ACTIVATION row still has to fit a buffer with room for a pixel: that bound is on K,
   * not on Kw, and this is the check the one-K planner could not make. */
  if (K / 8 + 1 > MBXR_BUF_WORDS) return 0;
  int quads = (N + MBXR_NCH - 1) / MBXR_NCH;
  int Q = MBXR_BUF_WORDS / (G + 1);
  if (Q > quads) Q = quads;
  /* THE ONE PLANNER CONSTRAINT THE 2-D DRAIN NEEDS.  A drained row is qt*NCH bytes; with
   * NCH = 4 that is a whole number of 64-bit words exactly when qt is EVEN, and then the
   * engine never has to split a packed word across two rows of out[npix][N].  Q even and
   * quads even (which N % 8 == 0 gives) make every tile's qt even, the last one included. */
  int strided = for_strided_drain && (N % 8) == 0 && Q >= 2;
  if (strided) Q &= ~1;
  int lgpw = lg2ceil((uint64_t)Q * (uint64_t)(G + 1));
  if (lgpw < 3) lgpw = 3;
  img->N = N; img->K = K; img->Kw = Kw; img->wbits = wbits;
  img->G = G; img->Q = Q; img->lgpw = lgpw;
  img->strided = strided;
  img->tiles = (quads + Q - 1) / Q;
  img->bytes = (size_t)img->tiles * MBXR_NCH * ((size_t)8 << lgpw);
  return img->bytes;
}

size_t mbxr_wimage_plan_ex(mbxr_wimage *img, int N, int K, int for_strided_drain)
{
  return mbxr_wimage_plan_bits(img, N, K, 8, for_strided_drain);
}

size_t mbxr_wimage_plan(mbxr_wimage *img, int N, int K)
{
  return mbxr_wimage_plan_ex(img, N, K, 0);
}

int mbxr_wimage_build(const mbxr_dev *dev, mbxr_wimage *img, uint64_t pa,
                      const int8_t *rows, const int32_t *bias)
{
  if ((pa & 63) != 0 || img->bytes == 0) return MBXR_E_ALIGN;
  img->pa = pa;
  uint8_t *base = (uint8_t *)dev->p2v(dev->ctx, pa);
  size_t plane_bytes = (size_t)8 << img->lgpw;
  const int G = img->G, K = img->K, N = img->N;
  for (int t = 0; t < img->tiles; t++) {
    for (int r = 0; r < MBXR_NCH; r++) {
      uint8_t *pl = base + ((size_t)t * MBXR_NCH + r) * plane_bytes;
      for (size_t i = 0; i < plane_bytes; i++) pl[i] = 0;
      for (int q = 0; q < img->Q; q++) {
        int n = (t * img->Q + q) * MBXR_NCH + r;
        uint8_t *row = pl + (size_t)q * 8 * (G + 1);
        if (n >= N) continue;                          /* padding lane: stays zero */
        int64_t b = bias ? bias[n] : 0;
        W64(row, (uint64_t)b);
        if (img->wbits == 8)
          for (int k = 0; k < K; k++) row[8 + k] = (uint8_t)rows[(size_t)n * K + k];
        else
          mbxr_pack6(rows + (size_t)n * K, K, row + 8);
      }
    }
  }
  return MBXR_OK;
}

int mbxr_wimage_build_fn(const mbxr_dev *dev, mbxr_wimage *img, uint64_t pa,
                         void (*row_fn)(void *ctx, int n, int8_t *dst), void *ctx,
                         const int32_t *bias)
{
  if ((pa & 63) != 0 || img->bytes == 0) return MBXR_E_ALIGN;
  img->pa = pa;
  uint8_t *base = (uint8_t *)dev->p2v(dev->ctx, pa);
  size_t plane_bytes = (size_t)8 << img->lgpw;
  const int G = img->G, N = img->N, Q = img->Q;
  const size_t rowb = (size_t)8 * (G + 1);
  /* Clear ONLY what no n maps to: a plane's padding lanes, and its tail past Q rows.  The
   * bytes every n DOES map to are written below, bias word included, so zeroing them first
   * would be the second pass this exists to remove. */
  for (int t = 0; t < img->tiles; t++)
    for (int r = 0; r < MBXR_NCH; r++) {
      uint8_t *pl = base + ((size_t)t * MBXR_NCH + r) * plane_bytes;
      for (int q = 0; q < Q; q++) {
        int n = (t * Q + q) * MBXR_NCH + r;
        if (n >= N) { uint8_t *row = pl + (size_t)q * rowb;
                      for (size_t i = 0; i < rowb; i++) row[i] = 0; }
      }
      for (size_t i = (size_t)Q * rowb; i < plane_bytes; i++) pl[i] = 0;
    }
  for (int n = 0; n < N; n++) {
    int r = n % MBXR_NCH, u = n / MBXR_NCH, q = u % Q, t = u / Q;
    uint8_t *row = base + ((size_t)t * MBXR_NCH + r) * plane_bytes + (size_t)q * rowb;
    W64(row, bias ? (uint64_t)(int64_t)bias[n] : 0ULL);
    /* writes exactly Kw = 8G IMAGE bytes -- the packed row at wbits = 6, not the K codes */
    row_fn(ctx, n, (int8_t *)row + 8);
  }
  return MBXR_OK;
}

uint64_t mbxr_wait(const mbxr_dev *dev, uint64_t mask, mbxr_stats *st)
{
  uint64_t n = 0;
  uint64_t c0 = (st && dev->now) ? dev->now(dev->ctx) : 0;
  for (;;) {
    uint64_t s = dev->cmd(dev->ctx, MBXR_FENCE, 0, 0, 1);
    if (st) { st->polls++; st->last_status = s; }
    if ((s & mask) == 0 || (dev->poll_limit && ++n >= dev->poll_limit)) {
      if (st && dev->now) st->cyc_wait += dev->now(dev->ctx) - c0;
      return (s & mask) == 0 ? s : ~0ULL;
    }
  }
}

typedef struct {
  const mbxr_dev *dev;
  mbxr_stats     *st;
  const mbxr_wimage *img;
  uint64_t in_pa;
  int  astride, npix, P;        /* P = pixels per activation tile */
  int  a_in[2], w_in[2];        /* tile held by each buffer, -1 = none */
  /* the placement cursor: pixel row `pp` of tile pair (po, pi) in loop order, `pk` of its
   * bytes placed, `pidx` the scratch index of the next byte */
  const int8_t *sb;
  int8_t *out;
  int  w_outer, outer_n, inner_n, quads;
  int  po, pi, pp, pk;
  uint64_t pidx, nblocks;
  int  early;                   /* place while waiting: the drain has been started */
} plan_t;

/* Place the tile-ordered bytes [pidx, limit) into out[npix, N].  Byte for byte what the late
 * path writes: lanes past N are padding and skipped, and the chunked path moves up to 64 bytes
 * at a time through a local buffer. */
static void place_upto(plan_t *pl, uint64_t limit)
{
  const mbxr_wimage *img = pl->img;
  const int N = img->N;
  while (pl->po < pl->outer_n) {
    int a = pl->w_outer ? pl->pi : pl->po;
    int t = pl->w_outer ? pl->po : pl->pi;
    int pa_ = pl->npix - a * pl->P; if (pa_ > pl->P) pa_ = pl->P;
    if (pl->pp >= pa_) {
      pl->pp = 0;
      if (++pl->pi == pl->inner_n) { pl->pi = 0; pl->po++; }
      continue;
    }
    int qt = pl->quads - t * img->Q; if (qt > img->Q) qt = img->Q;
    int len = qt * MBXR_NCH;
    int n0 = t * img->Q * MBXR_NCH;
    int keep = N - n0 < len ? N - n0 : len;
    uint64_t row0 = pl->pidx - (uint64_t)pl->pk;
    uint64_t end = row0 + (uint64_t)len;
    if (end > limit) end = limit;
    if (end <= pl->pidx) return;                 /* nothing more is available yet */
    int k1 = (int)(end - row0);
    int8_t *row = pl->out + (size_t)(a * pl->P + pl->pp) * N;
    int kk = k1 < keep ? k1 : keep;
    if (pl->dev->place_chunk) {
      int8_t buf[64];
      for (int k = pl->pk; k < kk; ) {
        int c = kk - k < 64 ? kk - k : 64;
        for (int j = 0; j < c; j++) buf[j] = pl->sb[row0 + k + j];
        for (int j = 0; j < c; j++) row[n0 + k + j] = buf[j];
        k += c;
      }
    } else {
      for (int k = pl->pk; k < kk; k++) row[n0 + k] = pl->sb[row0 + k];
    }
    pl->pidx = end;
    if (k1 == len) { pl->pp++; pl->pk = 0; } else { pl->pk = k1; return; }
  }
}

/* mbxr_wait, placing drained bytes between polls once the drain is running */
static uint64_t wait_place(plan_t *pl, uint64_t mask)
{
  const mbxr_dev *dev = pl->dev;
  mbxr_stats *st = pl->st;
  if (!pl->early) return mbxr_wait(dev, mask, st);
  uint64_t n = 0, cpl = 0;
  uint64_t c0 = dev->now ? dev->now(dev->ctx) : 0;
  for (;;) {
    uint64_t s = dev->cmd(dev->ctx, MBXR_FENCE, 0, 0, 1);
    st->polls++; st->last_status = s;
    if ((s & mask) == 0 || (dev->poll_limit && ++n >= dev->poll_limit)) {
      if (dev->now) st->cyc_wait += dev->now(dev->ctx) - c0 - cpl;
      return (s & mask) == 0 ? s : ~0ULL;
    }
#ifdef MBXR_PLACE_TEST_MARGIN
    uint64_t left = MBXR_S_LEFT(s);
    uint64_t issued = pl->nblocks > left ? pl->nblocks - left : 0;
    if (issued <= MBXR_PLACE_TEST_MARGIN) continue;
    uint64_t lim = (issued - MBXR_PLACE_TEST_MARGIN) * 64;
#else
    uint64_t acked = MBXR_S_ACKED(s);
    if (acked > pl->nblocks) acked = pl->nblocks;
    uint64_t lim = acked * 64;
#endif
    if (lim <= pl->pidx) continue;
    if (lim > pl->pidx + MBXR_PLACE_SLICE) lim = pl->pidx + MBXR_PLACE_SLICE;
    uint64_t p0 = dev->now ? dev->now(dev->ctx) : 0;
    uint64_t before = pl->pidx;
    place_upto(pl, lim);
    st->placed_early += pl->pidx - before;
    if (dev->now) { uint64_t d = dev->now(dev->ctx) - p0; cpl += d; st->cyc_place += d; }
  }
}

/* activation tile a: pixels [a*P, a*P + P); returns the scratchpad word of pixel 0 */
static void act_extent(const plan_t *pl, int a, uint64_t *src, uint64_t *blocks, int *aoff)
{
  const mbxr_wimage *img = pl->img;
  uint64_t first = pl->in_pa + (uint64_t)a * pl->P * 8ULL * pl->astride;
  uint64_t last = first + (uint64_t)(pl->P - 1) * 8ULL * pl->astride + (uint64_t)img->K;
  *src = first & ~63ULL;
  *aoff = (int)((first - *src) / 8);
  *blocks = (last - *src + 63) / 64;
}

static int load_act(plan_t *pl, int a, int buf)
{
  uint64_t src, blocks;
  int aoff;
  if (wait_place(pl, MBXR_S_FILL) == ~0ULL) return MBXR_E_TIMEOUT;
  act_extent(pl, a, &src, &blocks, &aoff);
  pl->dev->cmd(pl->dev->ctx, MBXR_SD, src, (blocks & 0xffff) | (1ULL << 16), 0);
  pl->dev->cmd(pl->dev->ctx, MBXR_LD, (1ULL << 18) | ((uint64_t)buf << 16) | (10ULL << 8), 0, 0);
  pl->a_in[buf] = a;
  pl->st->loads_act++;
  pl->st->bytes_act += blocks * 64;
  return MBXR_OK;
}

static int load_wgt(plan_t *pl, int t, int buf)
{
  const mbxr_wimage *img = pl->img;
  uint64_t plane_bytes = 8ULL << img->lgpw;
  uint64_t src = img->pa + (uint64_t)t * MBXR_NCH * plane_bytes;
  if (wait_place(pl, MBXR_S_FILL) == ~0ULL) return MBXR_E_TIMEOUT;
  pl->dev->cmd(pl->dev->ctx, MBXR_SD, src,
               (plane_bytes << 32) | ((uint64_t)MBXR_NCH << 16) | (plane_bytes / 64), 0);
  pl->dev->cmd(pl->dev->ctx, MBXR_LD, (1ULL << 17) | ((uint64_t)buf << 16) |
               ((uint64_t)img->lgpw << 8), 0, 0);
  pl->w_in[buf] = t;
  pl->st->loads_wgt++;
  pl->st->bytes_wgt += MBXR_NCH * plane_bytes;
  return MBXR_OK;
}

static int find(const int *in, int tile) { return in[0] == tile ? 0 : (in[1] == tile ? 1 : -1); }

int mbxr_run(const mbxr_dev *dev, const mbxr_wimage *img,
             uint64_t in_pa, int npix, int astride,
             const mbxr_quant *q, uint64_t scratch_pa, int8_t *out, mbxr_stats *stp)
{
  return mbxr_run_to(dev, img, in_pa, npix, astride, q, scratch_pa, out, 0, stp);
}

int mbxr_run_to(const mbxr_dev *dev, const mbxr_wimage *img,
                uint64_t in_pa, int npix, int astride,
                const mbxr_quant *q, uint64_t scratch_pa, int8_t *out, uint64_t out_pa,
                mbxr_stats *stp)
{
  mbxr_stats dummy;
  mbxr_stats *st = stp ? stp : &dummy;
  if (!stp) { for (size_t i = 0; i < sizeof dummy; i++) ((uint8_t *)&dummy)[i] = 0; }
  const int N = img->N;
  /* THE TWO GROUP COUNTS.  `G` is the weight words in a plane row; `Ga` is the ACTIVATION
   * words a pixel's row spans, and it is the one the tile sequencer steps.  They are equal at
   * wbits = 8 and they are 27 against 36 at wbits = 6, where the sequencer runs 36 MAC beats
   * over 27 weight words.  Everything below that sizes an ACTIVATION -- how many pixels fit a
   * buffer, and the group count in the cfg command -- takes Ga.  The engine derives the weight
   * schedule from the pack bit and needs no second count. */
  const int Ga = img->K / 8;
  const uint64_t cfg_pack = (img->wbits == 6) ? (1ULL << 48) : 0ULL;
  if (npix <= 0 || astride <= 0 || img->bytes == 0) return MBXR_E_SHAPE;
  if ((in_pa & 7) != 0) return MBXR_E_ALIGN;
  if ((scratch_pa & 63) != 0) return MBXR_E_ALIGN;
  if (q->shift < -31 || q->shift > 31 || q->amin < -128 || q->amax > 127 || q->amin > q->amax)
    return MBXR_E_SHAPE;

  plan_t pl = { dev, st, img, in_pa, astride, npix, 0, { -1, -1 }, { -1, -1 },
                NULL, out, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
  /* pixels per activation tile: worst-case leading offset of 7 words */
  if (MBXR_BUF_WORDS - 7 - Ga < 0) return MBXR_E_SHAPE;
  int P = (MBXR_BUF_WORDS - 7 - Ga) / astride + 1;
  if (P < 1) return MBXR_E_SHAPE;
  if (P > npix) P = npix;
  pl.P = P;
  int tiles_a = (npix + P - 1) / P;
  int tiles_w = img->tiles;
  int quads = (N + MBXR_NCH - 1) / MBXR_NCH;

  uint64_t act_bytes = (uint64_t)(npix - 1) * 8ULL * astride + (uint64_t)img->K;
  uint64_t wgt_bytes = img->bytes;
  int w_outer = ((uint64_t)tiles_w * act_bytes + wgt_bytes) <= ((uint64_t)tiles_a * wgt_bytes + act_bytes);

  /* total output bytes, in tile order, padded to a whole block */
  uint64_t total = 0;
  for (int t = 0; t < tiles_w; t++) {
    int qt = quads - t * img->Q; if (qt > img->Q) qt = img->Q;
    for (int a = 0; a < tiles_a; a++) {
      int pa_ = npix - a * P; if (pa_ > P) pa_ = P;
      total += (uint64_t)pa_ * qt * MBXR_NCH;
    }
  }
  uint64_t pad = (64 - total % 64) % 64;
  uint64_t blocks = (total + pad) / 64;

  /* THE STRIDED DRAIN.  The engine's `st` descriptor is (base, row_bytes, nrows, row_stride),
   * so a weight tile's results go straight into their rows of out[npix][N] and the CPU copy
   * disappears.  Three things have to hold and each is checked, not assumed:
   *   - the image was planned for it (mbxr_wimage_plan_ex), so every row is whole 64-bit words;
   *   - the caller gave out's physical address, 8-byte aligned;
   *   - the caller asked (dev->drain_strided), so an A/B is one flag.
   * Otherwise this is exactly the engine and the driver that were measured. */
  int strided = dev->drain_strided && img->strided && out_pa != 0 && (out_pa & 7) == 0 &&
                npix <= 0xffff && (N % 8) == 0;
  if (!strided && blocks > 0xffff) return MBXR_E_SHAPE;

  uint64_t s0 = mbxr_wait(dev, MBXR_S_BUSY, st);
  if (s0 == ~0ULL) return MBXR_E_TIMEOUT;
  if (dev->lane_wait) {
    /* revision 2b: the weight half is held in reset until its W port is quiet.  Check before the
     * drain is armed, so a lane that never comes back leaves the engine idle. */
    uint64_t n = 0, s = s0;
    while (!(s & MBXR_S_WREADY)) {
      if (++n >= dev->lane_wait) { st->last_status = s; return MBXR_E_LANE; }
      s = dev->cmd(dev->ctx, MBXR_FENCE, 0, 0, 1);
      st->polls++;
    }
  }
  dev->cmd(dev->ctx, MBXR_STAT, 0, 1, 1);                 /* clear counters + sticky error */
  dev->cmd(dev->ctx, MBXR_SQ, 0,
           ((uint64_t)(uint8_t)q->amax << 48) | ((uint64_t)(uint8_t)q->amin << 40) |
           ((uint64_t)(q->shift & 0x3f) << 32) | (uint32_t)q->mult, 0);
  /* THE FLAT DRAIN IS THE ONE-BLOCK-PER-ROW CASE of the same descriptor: `blocks` rows of 64
   * bytes, 64 bytes apart.  The size select in mbxr_st then picks 64 bytes every time, so the
   * A channel is beat for beat what revision 2a emitted.  (row_bytes is 16 bits, which is why
   * the block count goes in nrows and not in row_bytes.) */
  if (!strided)
    dev->cmd(dev->ctx, MBXR_ST, scratch_pa, MBXR_ST_FLAT(blocks), 0);

  int outer_n = w_outer ? tiles_w : tiles_a;
  int inner_n = w_outer ? tiles_a : tiles_w;
  pl.sb = (const int8_t *)dev->p2v(dev->ctx, scratch_pa);
  pl.w_outer = w_outer; pl.outer_n = outer_n; pl.inner_n = inner_n; pl.quads = quads;
  pl.nblocks = blocks;
  pl.early = !strided && dev->place_early != 0;   /* the drain is started: its left count is ours */
  int cur_ab = -1, cur_wb = -1;       /* buffers the in-flight tile computes from */
  int rc;
  for (int o = 0; o < outer_n; o++) {
    for (int i = 0; i < inner_n; i++) {
      int a = w_outer ? i : o;
      int t = w_outer ? o : i;
      int ab = find(pl.a_in, a), wb = find(pl.w_in, t);
      /* a buffer the in-flight tile reads must not be overwritten: wait it out if the only
       * candidate for a load is that one */
      if (ab < 0) {
        int b = (cur_ab == 0) ? 1 : 0;
        if ((rc = load_act(&pl, a, b)) != MBXR_OK) return rc;
        ab = b;
      }
      if (wb < 0) {
        int b = (cur_wb == 0) ? 1 : 0;
        if ((rc = load_wgt(&pl, t, b)) != MBXR_OK) return rc;
        wb = b;
      }
      if (wait_place(&pl, MBXR_S_FILL | MBXR_S_TSEQ) == ~0ULL) return MBXR_E_TIMEOUT;
      int pa_ = npix - a * P; if (pa_ > P) pa_ = P;
      int qt = quads - t * img->Q; if (qt > img->Q) qt = img->Q;
      if (strided && (i == 0 || !w_outer)) {
        /* ONE DESCRIPTOR PER WEIGHT TILE when the weights are the outer loop: the inner loop
         * then walks pixels 0..npix-1 in order at a fixed column offset, which is one 2-D
         * descriptor.  With the activations outer it is one per tile pair.  Either way the
         * drain must have finished the previous one and the packer must be empty before the
         * next is armed -- tiles_w flushes per dispatch, not one per byte. */
        if (mbxr_wait(dev, MBXR_S_DRAIN | MBXR_S_PIPE, st) == ~0ULL) return MBXR_E_TIMEOUT;
        int n0 = t * img->Q * MBXR_NCH;
        int r0 = w_outer ? 0 : a * P;
        int nr = w_outer ? npix : pa_;
        dev->cmd(dev->ctx, MBXR_ST,
                 out_pa + (uint64_t)r0 * (uint64_t)N + (uint64_t)n0,
                 MBXR_ST_RS2(qt * MBXR_NCH, nr, N), 0);
      }
      uint64_t src, nb; int aoff;
      act_extent(&pl, a, &src, &nb, &aoff);
      dev->cmd(dev->ctx, MBXR_CFG,
               cfg_pack | ((uint64_t)pa_ << 32) | ((uint64_t)qt << 16) | (uint64_t)Ga,
               ((uint64_t)astride << 48) | ((uint64_t)wb << 41) | ((uint64_t)ab << 40) |
               (uint64_t)aoff, 0);
      dev->cmd(dev->ctx, MBXR_MM, 0, 0, 0);
      st->pairs++;
      cur_ab = ab; cur_wb = wb;
      /* pre-load the next tile's changed operand into the buffer this one is not using */
      int ni = i + 1, no = o;
      if (ni == inner_n) { ni = 0; no = o + 1; }
      if (no < outer_n) {
        int na = w_outer ? ni : no, nt = w_outer ? no : ni;
        if (find(pl.a_in, na) < 0) { if ((rc = load_act(&pl, na, cur_ab ? 0 : 1)) != MBXR_OK) return rc; }
        else if (find(pl.w_in, nt) < 0) { if ((rc = load_wgt(&pl, nt, cur_wb ? 0 : 1)) != MBXR_OK) return rc; }
      }
    }
  }
  if (pad && !strided) {
    /* The flat drain rounds the dispatch up to a whole 64-byte block with a padding tile.  The
     * strided one has no such rounding to do: every row is a whole number of words by
     * construction, so the packer is empty at every tile boundary. */
    if (wait_place(&pl, MBXR_S_TSEQ) == ~0ULL) return MBXR_E_TIMEOUT;
    dev->cmd(dev->ctx, MBXR_CFG,
             cfg_pack | ((pad / MBXR_NCH) << 32) | (1ULL << 16) | (uint64_t)Ga,
             ((uint64_t)astride << 48) | ((uint64_t)(cur_wb < 0 ? 0 : cur_wb) << 41) |
             ((uint64_t)(cur_ab < 0 ? 0 : cur_ab) << 40), 0);
    dev->cmd(dev->ctx, MBXR_MM, 0, 0, 0);
    st->pairs++;
  }
  uint64_t s = wait_place(&pl, MBXR_S_BUSY);
  if (s == ~0ULL) return MBXR_E_TIMEOUT;
  if (s & (MBXR_S_ERR | MBXR_S_OVF)) return MBXR_E_HW;
  st->out_bytes += total + (strided ? 0 : pad);
  if (strided) return MBXR_OK;            /* the engine wrote out[npix][N]; there is no copy */
  if (pl.early) {
    uint64_t cp0 = dev->now ? dev->now(dev->ctx) : 0;
    place_upto(&pl, total);
    if (dev->now) st->cyc_place += dev->now(dev->ctx) - cp0;
    return MBXR_OK;
  }

  /* place the tile-ordered bytes into [npix, N] */
  uint64_t cp0 = dev->now ? dev->now(dev->ctx) : 0;
  const int8_t *sb = (const int8_t *)dev->p2v(dev->ctx, scratch_pa);
  uint64_t idx = 0;
  for (int o = 0; o < outer_n; o++) {
    for (int i = 0; i < inner_n; i++) {
      int a = w_outer ? i : o;
      int t = w_outer ? o : i;
      int pa_ = npix - a * P; if (pa_ > P) pa_ = P;
      int qt = quads - t * img->Q; if (qt > img->Q) qt = img->Q;
      for (int p = 0; p < pa_; p++) {
        int8_t *row = out + (size_t)(a * P + p) * N;
        int n = t * img->Q * MBXR_NCH;
        if (dev->place_chunk) {
          /* the lanes past N are padding: skip them, and move the rest 64 bytes at a time */
          int len = qt * MBXR_NCH, keep = N - n < len ? N - n : len;
          int8_t buf[64];
          for (int k = 0; k < keep; ) {
            int c = keep - k < 64 ? keep - k : 64;
            for (int j = 0; j < c; j++) buf[j] = sb[idx + k + j];
            for (int j = 0; j < c; j++) row[n + k + j] = buf[j];
            k += c;
          }
          idx += len;
          continue;
        }
        for (int k = 0; k < qt * MBXR_NCH; k++, n++, idx++)
          if (n < N) row[n] = sb[idx];
      }
    }
  }
  if (dev->now) st->cyc_place += dev->now(dev->ctx) - cp0;
  return MBXR_OK;
}
