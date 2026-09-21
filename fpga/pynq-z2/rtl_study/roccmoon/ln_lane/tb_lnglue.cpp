// SPDX-License-Identifier: Apache-2.0
//
// tb_lnglue -- the LN path of merge/mbxr_lanes.v, end to end: the engine's real scratchpad in,
// the streamer, mbxr_ln, the packer, and the drain words mbxr_st would swallow.
//
// This is the half no other suite reaches.  tb_ln.cpp drives mbxr_ln's own ports; tb_mbxr runs
// with the lanes idle; the attention track's mbxa_glue.v covers mbxa_core through the same
// mbxr_lanes but declined this half.  The ground truth here is the same q16 reference the lane
// itself is verified against, so the byte order is checked rather than assumed.
//
//   ./Vtb [--quick]

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cinttypes>
#include <vector>
#include <string>
#include "Vmbxr_ln_glue.h"
#include "verilated.h"

typedef __int128 i128;
typedef unsigned __int128 u128;

static u128 g_isqrt(u128 v) {
  u128 r = 0, bit = (u128)1 << 126;
  while (bit > v) bit >>= 2;
  while (bit) { if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; } else r >>= 1; bit >>= 2; }
  return r;
}

struct Cfg {
  int K = 288, HW = 1, M = 1, nc = 288;
  bool in16 = false, out16 = false, tp = false;
  int64_t eps = 1 << 20;
  std::vector<uint32_t> umul;
  std::vector<int64_t>  gmul, badd;
  std::string name;
};

// the q16 normalisation core, as ln_lane/tb_ln.cpp's oracle (itself checked against the
// verbatim reference kernels and against acts.npz on all 14 Moonshine dispatches)
static void ref_rows(const Cfg &c, const std::vector<int32_t> &x, std::vector<int32_t> &y) {
  y.resize((size_t)c.M * c.K);
  for (int m = 0; m < c.M; m++) {
    const int32_t *xp = &x[(size_t)m * c.K];
    int64_t S = 0; i128 Q = 0;
    for (int k = 0; k < c.K; k++) {
      int64_t u = (int64_t)xp[k] * (int64_t)c.umul[k / c.HW];
      S += u; Q += (i128)u * (i128)u;
    }
    i128 V = (i128)c.K * Q - (i128)S * (i128)S + (i128)c.eps;
    int64_t R = (int64_t)g_isqrt(((u128)1 << 120) / (u128)V);
    for (int k = 0; k < c.K; k++) {
      int cc = k / c.HW;
      int64_t u = (int64_t)xp[k] * (int64_t)c.umul[cc];
      i128 d = (i128)c.K * (i128)u - (i128)S;
      int64_t t = (int64_t)((d * (i128)R) >> 44);
      int64_t v = (t * c.gmul[cc] + c.badd[cc] * 65536 + ((int64_t)1 << 31)) >> 32;
      int64_t lo = c.out16 ? -32768 : -128, hi = c.out16 ? 32767 : 127;
      y[(size_t)m * c.K + k] = (int32_t)(v < lo ? lo : (v > hi ? hi : v));
    }
  }
}

struct Dut {
  Vmbxr_ln_glue *t; uint64_t cyc = 0;
  Dut() { t = new Vmbxr_ln_glue; t->clk = 0; t->rst = 1; t->cfg_we = 0; t->go_ln = 0;
          t->sp_we = 0; t->out_hold = 0; t->abuf = 0; reset(); }
  ~Dut() { delete t; }
  void tick() { t->eval(); t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++; }
  void reset() { t->rst = 1; for (int i = 0; i < 8; i++) tick(); t->rst = 0;
                 for (int i = 0; i < 4; i++) tick(); }
  void wr(uint32_t a, uint32_t d) { t->cfg_we = 1; t->cfg_addr = a; t->cfg_wdata = d; tick();
                                    t->cfg_we = 0; }
  void spw(uint32_t word, uint64_t data) { t->sp_we = 1; t->sp_word = word; t->sp_data = data;
                                           tick(); t->sp_we = 0; }
};

static int g_fail = 0;
static uint64_t g_disp = 0, g_rows = 0, g_elems = 0, g_differ = 0, g_bp = 0;

// lane 2 = mbxr_ln (13-bit local map), lane 3 = the streamer
static uint32_t L2(uint32_t local) { return (2u << 13) | (local & 0x1fff); }
static uint32_t L3(uint32_t local) { return (3u << 13) | (local & 0x1fff); }

// The activation buffer is 1,024 words: the streamer drives rd_addr[0] = {5'd0, abuf,
// r_word[9:0]} and mbxd_spad2 gives a buffer 2 banks x 512.  A range past that WRAPS, and
// unlike the engine's own mapper (which raises pa_bad) nothing checks it.  expect_wrap asserts
// that this is still true: if someone widens the address, this case fails and must be updated.
static bool g_expect_wrap = false;
static void run_case(Dut &d, Cfg &c, const std::vector<int32_t> &x, unsigned bpseed) {
  const int epw_in  = c.in16  ? 4 : 8;
  const int epw_out = c.out16 ? 4 : 8;
  const size_t nel  = (size_t)c.M * c.K;
  // The streamer reads a CONTIGUOUS word stream and cuts rows by K, so the input is packed
  // contiguously across the row boundary.  The OUTPUT is word-aligned per row, because the
  // packer flushes on in_last.  That asymmetry is the design's, and it is why this test
  // exists: nothing else in the suite could have found it.
  const int nwords = (int)((nel + epw_in - 1) / epw_in);

  d.reset();
  for (int w = 0; w < nwords; w++) {
    uint64_t word = 0;
    for (int e = 0; e < epw_in; e++) {
      size_t k = (size_t)w * epw_in + e;
      if (k >= nel) break;
      int32_t v = x[k];
      if (c.in16) word |= (uint64_t)(uint16_t)(int16_t)v << (16 * e);
      else        word |= (uint64_t)(uint8_t)(int8_t)v   << (8 * e);
    }
    d.spw((uint32_t)w, word);
  }
  // ---- lane 2: mbxr_ln's own map, unchanged by the merge -------------------------------
  for (int i = 0; i < c.nc; i++) {
    uint64_t ku = (uint64_t)c.K * (uint64_t)c.umul[i];
    d.wr(L2((uint32_t)(i << 3) | 0), c.umul[i] & 0x1ffffffu);
    d.wr(L2((uint32_t)(i << 3) | 1), (uint32_t)(ku & 0xffffffffull));
    d.wr(L2((uint32_t)(i << 3) | 2), (uint32_t)((ku >> 32) & 0xffull));
    d.wr(L2((uint32_t)(i << 3) | 3), (uint32_t)(uint64_t)c.gmul[i]);
    d.wr(L2((uint32_t)(i << 3) | 4), (uint32_t)(uint64_t)c.badd[i]);
  }
  d.wr(L2(0x1000), (uint32_t)c.K);
  d.wr(L2(0x1001), (uint32_t)c.HW);
  d.wr(L2(0x1002), (uint32_t)((uint64_t)c.eps & 0xffffffffull));
  d.wr(L2(0x1003), (uint32_t)(((uint64_t)c.eps) >> 32));
  d.wr(L2(0x1004), (uint32_t)((c.in16 ? 1 : 0) | (c.out16 ? 2 : 0) | (c.tp ? 4 : 0)));
  d.wr(L2(0x1005), 0);
  // ---- lane 3: the streamer ------------------------------------------------------------
  d.wr(L3(0), 0);                                   // first scratchpad word
  d.wr(L3(1), (uint32_t)nwords);                    // words to read
  d.wr(L3(2), (uint32_t)c.K);                       // K, for in_last
  d.wr(L3(3), (uint32_t)((c.in16 ? 1 : 0) | (c.out16 ? 2 : 0) | (c.tp ? 4 : 0)));

  // ---- go, and collect the drain ---------------------------------------------------------
  std::vector<uint64_t> words;
  const size_t want_words = (size_t)c.M * ((c.K + epw_out - 1) / epw_out);
  unsigned rng = bpseed;
  auto rnd = [&]() { rng = rng * 1664525u + 1013904223u; return (rng >> 16) & 0xffff; };
  d.t->go_ln = 1; d.t->eval();
  bool refused = d.t->go_bad;
  d.t->clk = 1; d.t->eval(); d.t->clk = 0; d.t->eval(); d.cyc++;
  d.t->go_ln = 0;
  if (g_expect_wrap) {
    // 0x5A5A002B onwards: a range past the buffer is REFUSED, as the engine's own mapper
    // refuses it (pa_bad).  Before that it wrapped silently and returned a wrong answer.
    for (int i = 0; i < 40; i++) d.tick();
    if (!refused) {
      fprintf(stderr, "LNG_FAIL %s: a %d-word range into a %d-word buffer was NOT refused\n",
              c.name.c_str(), nwords, 1 << 10); g_fail = 1;
    } else if (d.t->busy) {
      fprintf(stderr, "LNG_FAIL %s: refused but the unit went busy anyway\n", c.name.c_str());
      g_fail = 1;
    } else {
      printf("LNG_REFUSED %s: %d words into a 1,024-word buffer -> go_bad, unit idle, "
             "no dispatch (was a SILENT wrong answer before 0x5A5A002B)\n",
             c.name.c_str(), nwords);
    }
    g_disp++;
    return;
  }
  uint64_t guard = (uint64_t)nel * 40 + 400000;
  bool saw_busy = false;
  while (true) {
    if (guard-- == 0) {
      fprintf(stderr, "LNG_FAIL hang in %s: %zu/%zu words, busy %d status 0x%08x\n",
              c.name.c_str(), words.size(), want_words, (int)d.t->busy, (unsigned)d.t->status);
      g_fail = 1; return;
    }
    d.t->out_hold = (bpseed && (rnd() & 3) == 0) ? 1 : 0;
    d.t->eval();
    // mbxr_st's in_valid is unconditional: out_hold back-pressures the LANE, it does not
    // stall the packer's one-cycle pulse.  A testbench that gates on out_hold drops words.
    if (d.t->out_valid) words.push_back(d.t->out_data);
    if (d.t->busy) saw_busy = true;
    d.t->clk = 1; d.t->eval(); d.t->clk = 0; d.t->eval(); d.cyc++;
    if (words.size() >= want_words && !d.t->busy && saw_busy) break;
  }
  // ownership must come back: busy low, and the unit must not still own the scratchpad
  for (int i = 0; i < 40; i++) d.tick();
  if (d.t->busy || d.t->rd_own || d.t->out_own) {
    fprintf(stderr, "LNG_FAIL %s: ownership not returned (busy %d rd_own %d out_own %d)\n",
            c.name.c_str(), (int)d.t->busy, (int)d.t->rd_own, (int)d.t->out_own);
    g_fail = 1;
  }
  if (words.size() != want_words) {
    fprintf(stderr, "LNG_FAIL %s: %zu drain words, expected %zu\n",
            c.name.c_str(), words.size(), want_words);
    g_fail = 1; return;
  }
  // ---- unpack and compare ---------------------------------------------------------------
  std::vector<int32_t> ref; ref_rows(c, x, ref);
  const int owpr = (c.K + epw_out - 1) / epw_out;
  size_t bad = 0;
  for (int m = 0; m < c.M; m++)
    for (int k = 0; k < c.K; k++) {
      uint64_t w = words[(size_t)m * owpr + k / epw_out];
      int e = k % epw_out;
      int32_t got = c.out16 ? (int32_t)(int16_t)(w >> (16 * e))
                            : (int32_t)(int8_t)(w >> (8 * e));
      if (got != ref[(size_t)m * c.K + k]) {
        if (bad < 6) fprintf(stderr, "LNG_MISMATCH %s row %d k %d: rtl %d ref %d\n",
                             c.name.c_str(), m, k, got, ref[(size_t)m * c.K + k]);
        bad++;
      }
    }
  g_disp++; g_rows += c.M; g_elems += nel; g_differ += bad; if (bpseed) g_bp++;
}

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint64_t rnd64() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int64_t rr(int64_t lo, int64_t hi) { return lo + (int64_t)(rnd64() % (uint64_t)(hi - lo + 1)); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  bool quick = false;
  for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--quick")) quick = true;
  Dut d;

  // PRECONDITION, found by this testbench: the streamer's length is in WORDS, so M*K must be
  // a whole number of scratchpad words (a multiple of 8 for int8 input, 4 for int16).  If it
  // is not, the last word's padding elements are fed as the start of a row that never
  // completes and ownership is never returned.  Moonshine satisfies it: LayerNorm 165*288 =
  // 47,520 = 5,940 words, GroupNorm 287,712 = 71,928 words.  See LAYERNORM_LANE.md s17.
  struct Shape { int K, HW, M; bool in16, out16, tp; const char *nm; } S[] = {
    {288, 1, 3, false, false, false, "moonshine LN K=288 int8"},
    {288, 1, 2, true,  false, false, "layernorm_s16_s8 K=288"},
    {288, 1, 1, false, false, false, "one row"},
    {256, 1, 2, false, false, false, "K=256, word-aligned"},
    {250, 1, 4, false, false, false, "K=250, M*K a whole number of words"},
    {252, 4, 2, true,  true,  false, "int16 in/out, HW=4"},
    { 64, 8, 3, false, false, false, "HW=8, a partial affine group"},
    {  8, 1, 4, false, false, false, "K=8, one word per row"},
    {  5, 1, 4, true,  true,  false, "K=5, partial in and out"},
    // TWO-PASS: the GroupNorm shape.  Before 0x5A5A002A's streamer replay these were not
    // reachable through the merged unit at all (LAYERNORM_LANE.md s17, finding 3).  A
    // two-pass dispatch is ONE row, because the replay covers the whole range.
    {1024, 4, 1, true,  true,  true,  "GN-shaped two-pass K=1024 HW=4"},
    {2048, 8, 1, true,  true,  true,  "GN-shaped two-pass K=2048 HW=8"},
    { 288, 1, 1, false, false, true,  "two-pass on a LayerNorm row, int8"},
    {  64, 8, 1, true,  true,  true,  "two-pass, small"},
  };
  int nsets = quick ? 2 : 10;
  for (unsigned s = 0; s < sizeof S / sizeof S[0]; s++) {
    for (int set = 0; set < nsets; set++) {
      Cfg c; c.K = S[s].K; c.HW = S[s].HW; c.M = S[s].M;
      c.in16 = S[s].in16; c.out16 = S[s].out16; c.tp = S[s].tp;
      if (((size_t)c.M * c.K) % (c.in16 ? 4 : 8)) {
        fprintf(stderr, "LNG_FAIL %s violates the M*K word precondition\n", S[s].nm);
        g_fail = 1; continue;
      }
      c.nc = (c.K + c.HW - 1) / c.HW;
      c.eps = rr(1 << 19, (int64_t)1 << 46);
      c.umul.resize(c.nc); c.gmul.resize(c.nc); c.badd.resize(c.nc);
      bool pc = !c.in16 && (set & 1);
      for (int i = 0; i < c.nc; i++) {
        c.umul[i] = pc ? (uint32_t)rr(1, 1 << 24) : 1u;
        c.gmul[i] = rr(-(1 << 21), 1 << 21);
        c.badd[i] = (set & 2) ? rr(-500000, 500000) : 0;
      }
      std::vector<int32_t> x((size_t)c.M * c.K);
      int lim = c.in16 ? 32767 : 127;
      for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rr(-lim - 1, lim);
      char nm[96]; snprintf(nm, sizeof nm, "%s/set%d", S[s].nm, set); c.name = nm;
      run_case(d, c, x, (set & 1) ? (unsigned)(s * 1000 + set + 1) : 0);
    }
  }

  // ---- the documented limit, demonstrated ------------------------------------------------
  {
    g_expect_wrap = true;
    Cfg c; c.K = 8192; c.HW = 32; c.M = 1; c.nc = 256;
    c.in16 = true; c.out16 = true; c.tp = true; c.eps = 1 << 20;
    c.umul.assign(c.nc, 1u); c.gmul.assign(c.nc, 1 << 18); c.badd.assign(c.nc, 0);
    std::vector<int32_t> x((size_t)c.K);
    for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rr(-32768, 32767);
    c.name = "two-pass 2,048 words (buffer is 1,024)";
    run_case(d, c, x, 0);
    g_expect_wrap = false;
  }

  printf("%s %" PRIu64 " dispatches (%" PRIu64 " with back-pressure), %" PRIu64 " rows, "
         "%" PRIu64 " elements, %" PRIu64 " differ from the q16 reference\n",
         (g_differ == 0 && !g_fail) ? "LNG_TB_OK" : "LNG_TB_FAILED",
         g_disp, g_bp, g_rows, g_elems, g_differ);
  return (g_differ == 0 && !g_fail) ? 0 : 1;
}
