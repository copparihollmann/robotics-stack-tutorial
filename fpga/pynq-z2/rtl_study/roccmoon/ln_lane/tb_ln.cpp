// SPDX-License-Identifier: Apache-2.0
//
// tb_ln -- mbxr_ln against the q16 normalisation reference, element for element.
//
// Three independent sources of truth are used, and where two apply they are required to agree:
//   1. the verbatim reference kernels (ln_golden.c, generated from reference_kernels.py):
//      kernel_layernorm_pc_s8, kernel_layernorm_s16_s8, kernel_groupnorm_s16;
//   2. the curated board kernel kernel_groupnorm_s16_memo (pext_int_memo), for GroupNorm;
//   3. a generic __int128 oracle here, which is the only one that covers configurations no
//      kernel has (arbitrary HW with per-channel umul, int16 in with int8 out and HW > 1, ...);
//   and 4. for the Moonshine cases, the activations the q16 lowering itself produced.
// R is additionally checked by the predicate R^2*V <= 2^120 < (R+1)^2*V, which does not go
// through any of the C.
//
//   ./Vtb [--quick] [--shard i --nshards n] [--moonshine FILE] [--perf]

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cinttypes>
#include <vector>
#include <string>
#include <map>
#include "Vmbxr_ln.h"
#include "verilated.h"

extern "C" {
void kernel_layernorm_pc_s8(const int8_t *input, const int32_t *umul, const int64_t *gmul,
                            const int64_t *badd, int8_t *output, int M, int K, int64_t eps_q);
void kernel_layernorm_s16_s8(const int16_t *input, const int64_t *gmul, const int64_t *badd,
                             int8_t *output, int M, int K, int64_t eps_q);
void kernel_groupnorm_s16(const int16_t *input, const int64_t *gmul, const int64_t *badd,
                          int16_t *output, int N, int C, int HW, int64_t eps_q);
void kernel_groupnorm_s16_memo(const int16_t *input, const int64_t *gmul, const int64_t *badd,
                               int16_t *output, int N, int C, int HW, int64_t eps_q);
}

typedef __int128 i128;
typedef unsigned __int128 u128;

// ------------------------------------------------------------------ the generic oracle
static u128 g_isqrt(u128 v) {
  u128 r = 0, bit = (u128)1 << 126;
  while (bit > v) bit >>= 2;
  while (bit) { if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; } else r >>= 1; bit >>= 2; }
  return r;
}

struct Cfg {
  int K = 0, HW = 1, M = 1, nc = 0;
  bool in16 = false, out16 = false, two_pass = false;
  int64_t eps = 1 << 19;
  std::vector<uint32_t> umul;     // per c, <= 2^24
  std::vector<int64_t>  kumul;    // per c, = K*umul
  std::vector<int64_t>  gmul, badd;
  std::string name;
};

struct RowInfo { i128 V; int64_t R, S; };

// the reference arithmetic, transcribed here so that configurations without a kernel are
// still checked; every case that also has a kernel is checked against the kernel as well.
static void ref_generic(const Cfg &c, const std::vector<int32_t> &x, std::vector<int32_t> &y,
                        std::vector<RowInfo> *rows) {
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
    if (rows) rows->push_back({V, R, S});
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

// ------------------------------------------------------------------ the DUT harness
struct Dut {
  Vmbxr_ln *t;
  uint64_t cyc = 0;
  Dut() { t = new Vmbxr_ln; t->clk = 0; t->rst = 1; t->cfg_we = 0; t->in_valid = 0;
          t->out_ready = 0; for (int i = 0; i < 8; i++) tick(); t->rst = 0; for (int i=0;i<4;i++) tick(); }
  ~Dut() { delete t; }
  void reset() { t->cfg_we = 0; t->in_valid = 0; t->out_ready = 0; t->rst = 1;
                 for (int i = 0; i < 8; i++) tick(); t->rst = 0; for (int i = 0; i < 4; i++) tick(); }
  void tick() { t->eval(); t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++; }
  void wr(uint32_t a, uint32_t d) { t->cfg_we = 1; t->cfg_addr = a; t->cfg_wdata = d; tick();
                                    t->cfg_we = 0; }
  void config(const Cfg &c) {
    for (int i = 0; i < c.nc; i++) {
      wr((uint32_t)(i << 3) | 0, c.umul[i] & 0x1ffffffu);
      wr((uint32_t)(i << 3) | 1, (uint32_t)((uint64_t)c.kumul[i] & 0xffffffffull));
      wr((uint32_t)(i << 3) | 2, (uint32_t)(((uint64_t)c.kumul[i] >> 32) & 0xffull));
      wr((uint32_t)(i << 3) | 3, (uint32_t)((uint64_t)c.gmul[i] & 0xffffffffull));
      wr((uint32_t)(i << 3) | 4, (uint32_t)((uint64_t)c.badd[i] & 0xffffffffull));
    }
    wr(0x1000, (uint32_t)c.K);
    wr(0x1001, (uint32_t)c.HW);
    wr(0x1002, (uint32_t)((uint64_t)c.eps & 0xffffffffull));
    wr(0x1003, (uint32_t)(((uint64_t)c.eps) >> 32));
    wr(0x1004, (uint32_t)((c.in16 ? 1 : 0) | (c.out16 ? 2 : 0) | (c.two_pass ? 4 : 0)));
    wr(0x1005, 0);
  }
};

struct Stats { uint64_t dispatches = 0, bp = 0, rows = 0, elems = 0, differ = 0,
                        unclamped = 0, boundary = 0; };

// stream one dispatch; returns cycles from the first input handshake to the last output
static uint64_t run_dispatch(Dut &d, const Cfg &c, const std::vector<int32_t> &x,
                             std::vector<int32_t> &y, unsigned bpseed, uint32_t *err_out) {
  d.config(c);
  const size_t nin = (size_t)c.M * c.K * (c.two_pass ? 2 : 1);
  const size_t nout = (size_t)c.M * c.K;
  y.clear(); y.reserve(nout);
  size_t si = 0;
  unsigned rng = bpseed ? bpseed : 0;
  uint64_t t0 = 0, t1 = 0;
  // mode 0 per-cycle random; 1 bursts on out_ready; 2 bursts on in_valid; 3 a stall long
  // enough to fill the output FIFO's 16 credits AND the 2-deep R->A queue, so that on release
  // three rows are applied back to back -- the only way the apply stage's two descriptor banks
  // can collide, and the only thing that exercises the guard on the early descriptor take
  const int mode = bpseed ? (int)(bpseed % 4) : -1;
  uint64_t phase = 0;
  auto rnd = [&]() { rng = rng * 1664525u + 1013904223u; return (rng >> 16) & 0xffff; };
  // the burst modes deliberately idle the lane for thousands of cycles at a time, so the
  // liveness guard has to allow for their duty cycle rather than for the lane's own rate
  uint64_t guard = (uint64_t)(nin + nout) * 4 + (uint64_t)c.M * 4000 + 400000;
  if (mode >= 1) guard *= 24;
  while (y.size() < nout) {
    if (guard-- == 0) {
      fprintf(stderr, "LN_TB_FAIL hang in %s: sent %zu/%zu got %zu/%zu in_ready %d out_valid %d "
              "idle %d err 0x%02x\n", c.name.c_str(), si, nin, y.size(), nout,
              (int)d.t->in_ready, (int)d.t->out_valid, (int)d.t->idle, (unsigned)d.t->err);
      exit(1);
    }
    // one element index inside a (row, pass)
    size_t row = 0, pos = 0; bool pass1 = false;
    if (si < nin) {
      size_t per = c.two_pass ? (size_t)c.K * 2 : (size_t)c.K;
      row = si / per; size_t r = si % per;
      pass1 = c.two_pass && r >= (size_t)c.K;
      pos = pass1 ? r - c.K : r;
    }
    bool want = (si < nin);
    bool offer = want;
    if (mode == 0) offer = want && ((rnd() & 3) != 0);
    else if (mode == 2) offer = want && ((phase % 460) < 40);
    else if (mode == 3) offer = want;
    int32_t xv = 0;
    if (want) xv = x[row * c.K + pos];
    d.t->in_valid = offer ? 1 : 0;
    d.t->in_data = (uint16_t)(c.in16 ? (uint16_t)(int16_t)xv : (uint8_t)(int8_t)xv);
    d.t->in_last = (want && pos == (size_t)c.K - 1) ? 1 : 0;
    d.t->out_ready = 1;
    if (mode == 0) d.t->out_ready = ((rnd() & 3) != 0) ? 1 : 0;
    else if (mode == 1) d.t->out_ready = ((phase % 800) < 60) ? 1 : 0;
    else if (mode == 3) d.t->out_ready = ((phase % 3400) >= 3000) ? 1 : 0;
    phase++;
    (void)pass1;
    d.t->eval();
    bool ifire = offer && d.t->in_ready;
    bool ofire = d.t->out_ready && d.t->out_valid;
    if (ofire) {
      int32_t v = c.out16 ? (int32_t)(int16_t)d.t->out_data : (int32_t)(int8_t)(d.t->out_data & 0xff);
      bool lst = d.t->out_last != 0;
      bool want_last = ((y.size() + 1) % (size_t)c.K) == 0;
      if (lst != want_last) { fprintf(stderr, "LN_TB_FAIL out_last at %zu in %s\n", y.size(), c.name.c_str()); exit(1); }
      y.push_back(v);
      t1 = d.cyc;
    }
    if (ifire) { if (si == 0) t0 = d.cyc; si++; }
    d.t->clk = 1; d.t->eval(); d.t->clk = 0; d.t->eval(); d.cyc++;
  }
  d.t->in_valid = 0; d.t->out_ready = 0;
  for (int i = 0; i < 8; i++) d.tick();
  *err_out = d.t->err;
  return t1 - t0 + 1;
}

// ------------------------------------------------------------------ checking one case
static int g_fail = 0;
static uint64_t g_last_cycles = 0;

static void check(Dut &d, Cfg &c, const std::vector<int32_t> &x, Stats &st, unsigned bpseed,
                  bool expect_err = false) {
  c.kumul.resize(c.nc);
  for (int i = 0; i < c.nc; i++) c.kumul[i] = (int64_t)c.K * (int64_t)c.umul[i];
  std::vector<int32_t> ref, got;
  std::vector<RowInfo> rows;
  ref_generic(c, x, ref, &rows);
  // the R predicate, independent of every C path
  for (size_t i = 0; i < rows.size(); i++) {
    u128 R = (u128)rows[i].R, V = (u128)rows[i].V;
    if (!(R * R * V <= ((u128)1 << 120) && ((R + 1) * (R + 1) * V > ((u128)1 << 120)))) {
      fprintf(stderr, "LN_TB_FAIL R predicate, case %s row %zu\n", c.name.c_str(), i); exit(1);
    }
  }
  // the verbatim kernels, wherever one covers this configuration
  if (c.HW == 1 && !c.in16 && !c.out16) {
    std::vector<int8_t> xi((size_t)c.M * c.K), yo((size_t)c.M * c.K);
    std::vector<int32_t> um(c.nc);
    for (size_t i = 0; i < xi.size(); i++) xi[i] = (int8_t)x[i];
    for (int i = 0; i < c.nc; i++) um[i] = (int32_t)c.umul[i];
    kernel_layernorm_pc_s8(xi.data(), um.data(), c.gmul.data(), c.badd.data(), yo.data(),
                           c.M, c.K, c.eps);
    for (size_t i = 0; i < yo.size(); i++)
      if ((int32_t)yo[i] != ref[i]) { fprintf(stderr, "LN_TB_FAIL oracle vs layernorm_pc_s8 %s\n", c.name.c_str()); exit(1); }
  }
  if (c.HW == 1 && c.in16 && !c.out16) {
    bool unit = true; for (int i = 0; i < c.nc; i++) unit &= (c.umul[i] == 1);
    if (unit) {
      std::vector<int16_t> xi((size_t)c.M * c.K); std::vector<int8_t> yo((size_t)c.M * c.K);
      for (size_t i = 0; i < xi.size(); i++) xi[i] = (int16_t)x[i];
      kernel_layernorm_s16_s8(xi.data(), c.gmul.data(), c.badd.data(), yo.data(), c.M, c.K, c.eps);
      for (size_t i = 0; i < yo.size(); i++)
        if ((int32_t)yo[i] != ref[i]) { fprintf(stderr, "LN_TB_FAIL oracle vs layernorm_s16_s8 %s\n", c.name.c_str()); exit(1); }
    }
  }
  if (c.in16 && c.out16) {
    bool unit = true; for (int i = 0; i < c.nc; i++) unit &= (c.umul[i] == 1);
    if (unit && c.M >= 1 && (c.K % c.HW) == 0) {
      std::vector<int16_t> xi((size_t)c.M * c.K), yo((size_t)c.M * c.K), yo2((size_t)c.M * c.K);
      for (size_t i = 0; i < xi.size(); i++) xi[i] = (int16_t)x[i];
      kernel_groupnorm_s16(xi.data(), c.gmul.data(), c.badd.data(), yo.data(),
                           c.M, c.K / c.HW, c.HW, c.eps);
      kernel_groupnorm_s16_memo(xi.data(), c.gmul.data(), c.badd.data(), yo2.data(),
                                c.M, c.K / c.HW, c.HW, c.eps);
      for (size_t i = 0; i < yo.size(); i++) {
        if ((int32_t)yo[i] != ref[i]) { fprintf(stderr, "LN_TB_FAIL oracle vs groupnorm_s16 %s\n", c.name.c_str()); exit(1); }
        if (yo2[i] != yo[i]) { fprintf(stderr, "LN_TB_FAIL curated vs reference groupnorm %s\n", c.name.c_str()); exit(1); }
      }
    }
  }
  { int64_t lo = c.out16 ? -32768 : -128, hi = c.out16 ? 32767 : 127;
    for (size_t i = 0; i < ref.size(); i++) if (ref[i] > lo && ref[i] < hi) st.unclamped++; }
  uint32_t e = 0;
  g_last_cycles = run_dispatch(d, c, x, got, bpseed, &e);
  st.dispatches++; st.rows += c.M; st.elems += (uint64_t)c.M * c.K;
  if (bpseed) st.bp++;
  if (!expect_err && (e & 0x3e)) {
    fprintf(stderr, "LN_TB_FAIL err=0x%02x in %s\n", e, c.name.c_str()); g_fail = 1;
  }
  for (size_t i = 0; i < got.size(); i++) if (got[i] != ref[i]) {
    if (st.differ < 8)
      fprintf(stderr, "LN_TB_MISMATCH %s elem %zu: rtl %d ref %d\n", c.name.c_str(), i, got[i], ref[i]);
    st.differ++;
  }
}

// ------------------------------------------------------------------ parameter helpers
static uint64_t rs = 0x243F6A8885A308D3ull;
static uint64_t rnd64() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int64_t rnd_range(int64_t lo, int64_t hi) { return lo + (int64_t)(rnd64() % (uint64_t)(hi - lo + 1)); }

static void fill_params(Cfg &c, bool pc, int64_t gmax, int64_t bmax) {
  c.umul.resize(c.nc); c.gmul.resize(c.nc); c.badd.resize(c.nc);
  for (int i = 0; i < c.nc; i++) {
    c.umul[i] = pc ? (uint32_t)rnd_range(1, 1 << 24) : 1u;
    c.gmul[i] = rnd_range(-gmax, gmax);
    c.badd[i] = bmax ? rnd_range(-bmax, bmax) : 0;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  bool quick = false, perf = false;
  int shard = 0, nsh = 1;
  const char *moon = nullptr;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--quick")) quick = true;
    else if (!strcmp(argv[i], "--perf")) perf = true;
    else if (!strcmp(argv[i], "--shard")) shard = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--nshards")) nsh = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--moonshine")) moon = argv[++i];
  }
  rs ^= (uint64_t)(shard + 1) * 0x9E3779B97F4A7C15ull;
  Dut d;
  std::map<std::string, Stats> S;

  // ---------------- case moonshine: the 14 real norm dispatches -----------------------
  if (moon) {
    FILE *f = fopen(moon, "rb");
    if (f) {
      char mg[4]; uint32_t n = 0;
      if (fread(mg, 1, 4, f) != 4 || memcmp(mg, "LNM1", 4) || fread(&n, 4, 1, f) != 1) n = 0;
      for (uint32_t di = 0; di < n; di++) {
        int32_t hdr[6]; int64_t eps;
        if (fread(hdr, 4, 6, f) != 6) break;
        if (fread(&eps, 8, 1, f) != 1) break;
        Cfg c; c.M = hdr[0]; c.K = hdr[1]; c.HW = hdr[2]; c.nc = hdr[3];
        c.in16 = hdr[4] & 1; c.out16 = hdr[4] & 2; c.two_pass = hdr[5] != 0; c.eps = eps;
        c.umul.resize(c.nc); c.gmul.resize(c.nc); c.badd.resize(c.nc);
        std::vector<int32_t> um(c.nc);
        if (fread(um.data(), 4, c.nc, f) != (size_t)c.nc) break;
        for (int i = 0; i < c.nc; i++) c.umul[i] = (uint32_t)um[i];
        if (fread(c.gmul.data(), 8, c.nc, f) != (size_t)c.nc) break;
        if (fread(c.badd.data(), 8, c.nc, f) != (size_t)c.nc) break;
        size_t ne = (size_t)c.M * c.K;
        std::vector<int16_t> xr(ne), yr(ne);
        if (fread(xr.data(), 2, ne, f) != ne) break;
        if (fread(yr.data(), 2, ne, f) != ne) break;
        if ((int)(di % nsh) != shard) continue;
        std::vector<int32_t> x(ne);
        for (size_t i = 0; i < ne; i++) x[i] = xr[i];
        char nm[64]; snprintf(nm, sizeof nm, "moonshine%u", di); c.name = nm;
        // fourth source: the activations the q16 lowering itself produced
        std::vector<int32_t> ref; ref_generic(c, x, ref, nullptr);
        for (size_t i = 0; i < ne; i++) if (ref[i] != (int32_t)yr[i]) {
          fprintf(stderr, "LN_TB_FAIL oracle vs recorded activations, %s elem %zu\n", nm, i);
          exit(1);
        }
        check(d, c, x, S["moonshine"], 0);
        if (quick) break;
        for (int sd = 0; sd < 5; sd++) check(d, c, x, S["moonshine"], 0x1234 + di * 17 + sd);
      }
      fclose(f);
    } else fprintf(stderr, "LN_TB_NOTE %s not found\n", moon);
  }

  // ---------------- case exh2: every int8 pair at K = 2 -------------------------------
  {
    int nsets = quick ? 1 : 6;
    for (int set = 0; set < nsets; set++) {
      Cfg c; c.K = 2; c.HW = 1; c.nc = 2; c.M = quick ? 64 : 512;
      static const int64_t ES[6] = {262145, 987654321, 398648, 888769851575925LL,
                                    351091841614LL, 13036413477666LL};
      static const uint32_t US[6][2] = {{16777216u, 244700u}, {3011u, 16777216u},
                                        {1u, 1u}, {16777216u, 16777216u},
                                        {244700u, 1u}, {1u, 16777216u}};
      static const int64_t GS[6][2] = {{1224754, -250595132}, {-88365, 421},
                                       {1179098, 221548}, {250595132, -1},
                                       {1, 2147483647LL}, {-2147483648LL, 1000000}};
      static const int64_t BS[6][2] = {{0, 0}, {517251, -695660}, {0, 0},
                                       {-695660, 517251}, {2147483647LL, -2147483648LL},
                                       {0, 42}};
      c.eps = ES[set];
      c.umul = {US[set][0], US[set][1]};
      c.gmul = {GS[set][0], GS[set][1]};
      c.badd = {BS[set][0], BS[set][1]};
      std::vector<int32_t> x((size_t)c.M * 2);
      int total = 65536, per = c.M * 1;
      for (int base = 0; base < total; base += per) {
        if (((base / per) % nsh) != shard) continue;
        for (int m = 0; m < c.M; m++) {
          int v = base + m; if (v >= total) v = total - 1;
          x[(size_t)m * 2 + 0] = (v & 0xff) - 128;
          x[(size_t)m * 2 + 1] = ((v >> 8) & 0xff) - 128;
        }
        char nm[48]; snprintf(nm, sizeof nm, "exh2_s%d_%d", set, base); c.name = nm;
        unsigned bps = 0;
        if ((base & 0x300) == 0x100) bps = (unsigned)(base * 4 + 1);   // out_ready bursts
        else if ((base & 0x300) == 0x200) bps = (unsigned)(base * 4);  // per-cycle random
        else if ((base & 0x300) == 0x300) bps = (unsigned)(base * 4 + 2);
        check(d, c, x, S["exh2"], bps);
        if (quick && base >= per * 4) break;
      }
    }
  }

  // ---------------- case all256: a K = 256 row holding every int8 code ----------------
  {
    int ngrid = quick ? 2 : 24;
    for (int gi = 0; gi < ngrid; gi++) {
      if ((gi % nsh) != shard) continue;
      Cfg c; c.K = 256; c.HW = 1; c.nc = 256; c.M = 4;
      c.eps = (gi & 1) ? 262145 : (int64_t)1 << (20 + (gi % 40));
      fill_params(c, (gi & 2) != 0, 1 << (10 + (gi % 20)), (gi & 4) ? 700000 : 0);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (int m = 0; m < c.M; m++)
        for (int k = 0; k < 256; k++)
          x[(size_t)m * 256 + k] = ((k + m * 37) & 0xff) - 128;
      char nm[48]; snprintf(nm, sizeof nm, "all256_%d", gi); c.name = nm;
      check(d, c, x, S["all256"], gi & 1 ? (unsigned)(gi * 31 + 5) : 0);
    }
  }

  // ---------------- case rand: the supported configuration space ----------------------
  {
    int nc_ = quick ? 6 : 220;
    static const int Ks[] = {1, 2, 3, 7, 17, 64, 128, 249, 250, 288, 511, 512};
    for (int i = 0; i < nc_; i++) {
      if ((i % nsh) != shard) continue;
      Cfg c;
      c.K = Ks[rnd64() % (sizeof Ks / sizeof Ks[0])];
      c.in16 = (rnd64() & 1) != 0; c.out16 = (rnd64() & 1) != 0;
      // HW divides K so the affine index never runs past the table
      int hw = 1; { int cand[] = {1, 1, 1, 2, 4, 8}; int h = cand[rnd64() % 6];
                    hw = (c.K % h == 0) ? h : 1; }
      c.HW = hw; c.nc = c.K / hw;
      c.M = 1 + (int)(rnd64() % 24);
      c.eps = (int64_t)rnd_range(262145, (int64_t)1 << 50);
      bool pc = !c.in16 && (rnd64() & 1);
      fill_params(c, pc, (int64_t)1 << (10 + rnd64() % 20), (rnd64() & 1) ? 700000 : 0);
      std::vector<int32_t> x((size_t)c.M * c.K);
      int lim = c.in16 ? 32767 : 127;
      for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-lim - 1, lim);
      char nm[48]; snprintf(nm, sizeof nm, "rand%d", i); c.name = nm;
      check(d, c, x, S["rand"], (i & 1) ? (unsigned)(i * 7919 + 3) : 0);
    }
  }

  // ---------------- case bulk: Moonshine's own LayerNorm shape, random parameters -------
  {
    int nb = quick ? 1 : 3000;
    for (int i = 0; i < nb; i++) {
      if ((i % nsh) != shard) continue;
      Cfg c; c.K = 288; c.HW = 1; c.nc = 288; c.M = 165;
      c.in16 = (i % 13) == 0; c.out16 = false;
      c.eps = (int64_t)rnd_range(262145, (int64_t)1 << 50);
      fill_params(c, !c.in16 && (i & 1), (int64_t)1 << (12 + rnd64() % 18),
                  (i & 2) ? 700000 : 0);
      std::vector<int32_t> x((size_t)c.M * c.K);
      int lim = c.in16 ? 32767 : 127;
      for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-lim - 1, lim);
      char nm[48]; snprintf(nm, sizeof nm, "bulk%d", i); c.name = nm;
      check(d, c, x, S["bulk"], (i & 3) == 0 ? (unsigned)(i * 5701 + 11) : 0);
    }
  }

  // ---------------- case corner --------------------------------------------------------
  {
    int ci = 0;
    auto one = [&](Cfg &c, std::vector<int32_t> &x, const char *nm) {
      if ((ci++ % nsh) != shard) return;
      c.name = nm; check(d, c, x, S["corner"], 0);
      c.name = std::string(nm) + "_bp"; check(d, c, x, S["corner"], (unsigned)(ci * 101 + 1));
    };
    { // a constant row: K*Q - S^2 == 0 exactly, so V == eps_q
      Cfg c; c.K = 288; c.HW = 1; c.nc = 288; c.M = 3; c.eps = 262145;
      fill_params(c, false, 1 << 20, 0);
      std::vector<int32_t> x((size_t)c.M * c.K, 77);
      one(c, x, "constant_eps_min");
    }
    { // the same at the model's own smallest eps_q
      Cfg c; c.K = 288; c.HW = 1; c.nc = 288; c.M = 3; c.eps = 398648; c.in16 = true;
      fill_params(c, false, 1 << 20, 0);
      std::vector<int32_t> x((size_t)c.M * c.K, -30000);
      one(c, x, "constant_eps_moonshine");
    }
    { // alternating extremes, int16 in and out
      Cfg c; c.K = 512; c.HW = 8; c.nc = 64; c.M = 2; c.eps = 888769851575925LL;
      c.in16 = true; c.out16 = true;
      fill_params(c, false, 250595132LL, 700000);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = (j & 1) ? 32767 : -32768;
      one(c, x, "alternating_s16");
    }
    { // saturation at both clamps: a huge gmul
      Cfg c; c.K = 64; c.HW = 1; c.nc = 64; c.M = 4; c.eps = 262145;
      // gmul and badd ride in the table as int32, which is the lane's supported range
      c.umul.assign(64, 1u); c.gmul.assign(64, 2147483647LL); c.badd.assign(64, 2147483647LL);
      for (int i = 0; i < 64; i += 2) { c.gmul[i] = -2147483648LL; c.badd[i] = -2147483648LL; }
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-128, 127);
      one(c, x, "saturate_both");
    }
    { // K = 1: d is identically zero
      Cfg c; c.K = 1; c.HW = 1; c.nc = 1; c.M = 8; c.eps = 262145;
      c.umul = {16777216u}; c.gmul = {123456}; c.badd = {-4242};
      std::vector<int32_t> x(8); for (int i = 0; i < 8; i++) x[i] = i * 17 - 60;
      one(c, x, "k1");
    }
    { // umul at both ends of Q24 with int8 input: |u| at its 2^31 bound
      Cfg c; c.K = 288; c.HW = 1; c.nc = 288; c.M = 2; c.eps = 262145;
      c.umul.assign(288, 16777216u); c.gmul.assign(288, 1224754); c.badd.assign(288, 0);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = (j & 1) ? 127 : -128;
      one(c, x, "umul_max");
    }
    { // |S| near its reachable maximum (2^40): int16 input with a large per-position scale,
      // almost all of one sign, so S is huge AND the variance is non-zero (a constant row
      // would hide any S^2 error, because d == 0 makes every t zero)
      Cfg c; c.K = 256; c.HW = 1; c.nc = 256; c.M = 3; c.eps = 262145; c.in16 = true;
      c.umul.assign(256, 131071u); c.gmul.assign(256, 1 << 20); c.badd.assign(256, 0);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = ((j % 37) == 0) ? 32767 : -32768;
      one(c, x, "s_max_signed");
    }
    { // the same with int8 input and umul at 2^24
      Cfg c; c.K = 512; c.HW = 1; c.nc = 512; c.M = 2; c.eps = 262145;
      c.umul.assign(512, 16777216u); c.gmul.assign(512, 1 << 20); c.badd.assign(512, 0);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = ((j % 64) == 0) ? 127 : -128;
      one(c, x, "s_max_int8");
    }
    { // three rows applied back to back: a short row and a stall that fills both the output
      // credits and the R->A queue, so the apply stage takes two descriptors early in a row
      for (int kk = 1; kk <= 4; kk++) {
        if ((ci++ % nsh) != shard) continue;
        Cfg c; c.K = kk; c.HW = 1; c.nc = kk; c.M = 14; c.eps = 262145;
        c.umul.assign(kk, 16777216u); c.gmul.assign(kk, 1 << 19); c.badd.assign(kk, 0);
        for (int j = 0; j < kk; j++) c.gmul[j] = (int64_t)(1 << 19) + j * 7919;
        std::vector<int32_t> x((size_t)c.M * c.K);
        for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-128, 127);
        char nm[32]; snprintf(nm, sizeof nm, "b2b_k%d", kk); c.name = nm;
        check(d, c, x, S["corner"], 3);          // mode 3
      }
    }
    { // the two-pass path on a small GroupNorm shape
      Cfg c; c.K = 20; c.HW = 5; c.nc = 4; c.M = 3; c.eps = 262145;
      c.in16 = true; c.out16 = true; c.two_pass = true;
      fill_params(c, false, 1 << 22, 500000);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-32768, 32767);
      one(c, x, "tp_small");
    }
    { // the same shape one-pass, to show the two paths agree
      Cfg c; c.K = 20; c.HW = 5; c.nc = 4; c.M = 3; c.eps = 262145;
      c.in16 = true; c.out16 = true; c.two_pass = false;
      fill_params(c, false, 1 << 22, 500000);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-32768, 32767);
      one(c, x, "op_small");
    }
  }

  // ---------------- case roundband: outputs placed EXACTLY on the +2^31 round boundary ---
  // A saturated output is insensitive to any rounding, and a random output lands on the
  // boundary with probability 2^-32.  Here badd[k] is solved for so that
  //   t[k]*gmul[k] + badd[k]*2^16 + 2^31  ==  out_target * 2^32  exactly,
  // with out_target inside the clamp, so the rounding constant is the only thing separating
  // out_target from out_target - 1.  (The attention track found two rounding mutants surviving
  // an exhaustive sweep for want of exactly this.)
  {
    int nrb = quick ? 2 : 240;
    for (int i = 0; i < nrb; i++) {
      if ((i % nsh) != shard) continue;
      Cfg c; c.K = 288; c.HW = 1; c.nc = 288; c.M = 1;
      c.in16 = (i & 4) != 0; c.out16 = false;
      c.eps = (int64_t)rnd_range(262145, (int64_t)1 << 48);
      c.umul.resize(288); c.gmul.resize(288); c.badd.assign(288, 0);
      std::vector<int64_t> gp(288);
      for (int k = 0; k < 288; k++) {
        c.umul[k] = (!c.in16 && (i & 1)) ? (uint32_t)rnd_range(1, 1 << 24) : 1u;
        gp[k] = rnd_range(1, 64);                       // gmul = gp * 2^16
        c.gmul[k] = gp[k] * 65536;
      }
      std::vector<int32_t> x(288);
      int lim = c.in16 ? 32767 : 127;
      for (int k = 0; k < 288; k++) x[k] = (int32_t)rnd_range(-lim - 1, lim);
      std::vector<int32_t> y0; std::vector<RowInfo> rows;
      c.kumul.assign(288, 0);
      for (int k = 0; k < 288; k++) c.kumul[k] = (int64_t)c.K * (int64_t)c.umul[k];
      ref_generic(c, x, y0, &rows);
      const int64_t Sr = rows[0].S, Rr = rows[0].R;
      int nb = 0;
      for (int k = 0; k < 288; k++) {
        int64_t u = (int64_t)x[k] * (int64_t)c.umul[k];
        i128 dd = (i128)c.K * (i128)u - (i128)Sr;
        int64_t t = (int64_t)((dd * (i128)Rr) >> 44);
        int64_t tgt = (int64_t)((k % 201) - 100);
        int64_t bb = tgt * 65536 - t * gp[k] - 32768;   // exact boundary
        if (i & 2) bb += (k & 1) ? 1 : -1;              // and one step either side of it
        if (bb < -2147483648LL || bb > 2147483647LL) { c.badd[k] = 0; continue; }
        c.badd[k] = bb;
        if (!(i & 2)) nb++;
      }
      char nm[48]; snprintf(nm, sizeof nm, "roundband%d", i); c.name = nm;
      check(d, c, x, S["roundband"], (i % 5) ? 0 : (unsigned)(i * 13 + 1));
      S["roundband"].boundary += nb;
    }
  }

  // ---------------- case bigk: K past 2^19, so the top bit of K reaches the K*Q loop -------
  if (shard == 0) {
    static const struct { int K, HW; } BK[] = {{600000, 1250}, {524800, 1312}, {786432, 2048}};
    for (unsigned i = 0; i < (quick ? 1u : sizeof BK / sizeof BK[0]); i++) {
      Cfg c; c.K = BK[i].K; c.HW = BK[i].HW; c.nc = BK[i].K / BK[i].HW; c.M = 1;
      c.in16 = true; c.out16 = true; c.two_pass = true;
      c.eps = 888769851575925LL;
      fill_params(c, false, 1 << 22, 500000);
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-32768, 32767);
      char nm[48]; snprintf(nm, sizeof nm, "bigk%u", i); c.name = nm;
      check(d, c, x, S["bigk"], 0);
    }
  }

  // ---------------- case errs: every err bit, deliberately raised -----------------------
  if (shard == 0) {
    Stats &st = S["errs"];
    struct EC { const char *nm; uint32_t want; } ecs[] = {
      {"eps_too_small", 0x01}, {"K_zero", 0x01}, {"K_over_ring", 0x01},
      {"c_over_table", 0x08}, {"u_overflow", 0x08}, {"last_mismatch", 0x20},
      {"cfg_while_busy", 0x02},
    };
    for (unsigned i = 0; i < sizeof ecs / sizeof ecs[0]; i++) {
      Cfg c; c.K = 32; c.HW = 1; c.nc = 32; c.M = 2; c.eps = 1 << 20;
      c.umul.assign(32, 1u); c.gmul.assign(32, 100000); c.badd.assign(32, 0);
      c.kumul.resize(32);
      std::string nm = ecs[i].want == 0x01 ? "cfgerr" : "runerr";
      if (!strcmp(ecs[i].nm, "eps_too_small")) c.eps = 262144;
      if (!strcmp(ecs[i].nm, "K_zero")) c.K = 0;
      if (!strcmp(ecs[i].nm, "K_over_ring")) c.K = 1024;
      if (!strcmp(ecs[i].nm, "c_over_table")) {   // 1024 affine indices, a 512-entry table
        c.K = 1024; c.nc = 1024; c.M = 1; c.two_pass = true;
        c.umul.assign(1024, 1u); c.gmul.assign(1024, 100000); c.badd.assign(1024, 0);
      }
      if (!strcmp(ecs[i].nm, "u_overflow")) { c.in16 = true; c.umul.assign(32, 1u << 24); }
      c.kumul.assign(c.nc, 0);
      for (int j = 0; j < c.nc; j++) c.kumul[j] = (int64_t)c.K * (int64_t)c.umul[j];
      d.config(c);
      // the configuration errors show up immediately, with in_ready held low
      if (ecs[i].want == 0x01) {
        d.t->in_valid = 1; d.t->in_data = 0; d.t->in_last = 0; d.t->out_ready = 1;
        d.t->eval();
        if (d.t->in_ready || !(d.t->err & 1)) {
          fprintf(stderr, "LN_TB_FAIL %s: err 0x%02x in_ready %d\n", ecs[i].nm,
                  (unsigned)d.t->err, (int)d.t->in_ready);
          g_fail = 1;
        }
        d.t->in_valid = 0; d.reset();
        st.dispatches++;
        continue;
      }
      // c_over_table needs a table larger than 2**TL2; it is driven by K alone here
      std::vector<int32_t> x((size_t)c.M * c.K);
      for (size_t j = 0; j < x.size(); j++)
        x[j] = c.in16 ? (int32_t)(30000 - (int)(j % 7)) : (int32_t)((j % 251) - 125);
      std::vector<int32_t> got; uint32_t e = 0;
      if (!strcmp(ecs[i].nm, "last_mismatch")) {
        // drive K+1 elements with in_last one early
        d.config(c);
        d.t->out_ready = 1;
        for (int j = 0; j < c.K; j++) {
          d.t->in_valid = 1; d.t->in_data = (uint8_t)(int8_t)x[j];
          d.t->in_last = (j == c.K - 2) ? 1 : 0;
          d.t->eval();
          bool f = d.t->in_ready;
          d.t->clk = 1; d.t->eval(); d.t->clk = 0; d.t->eval(); d.cyc++;
          if (!f) j--;
        }
        d.t->in_valid = 0;
        for (int j = 0; j < 400; j++) d.tick();
        e = d.t->err;
      } else if (!strcmp(ecs[i].nm, "cfg_while_busy")) {
        d.config(c);
        d.t->out_ready = 0;
        for (int j = 0; j < 4; j++) {
          d.t->in_valid = 1; d.t->in_data = 1; d.t->in_last = 0; d.t->eval();
          d.t->clk = 1; d.t->eval(); d.t->clk = 0; d.t->eval(); d.cyc++;
        }
        d.t->in_valid = 0;
        d.wr(0x1000, (uint32_t)c.K);
        e = d.t->err;
        for (int j = 0; j < 400; j++) d.tick();
      } else {
        e = 0; run_dispatch(d, c, x, got, 0, &e);
      }
      if (!(e & ecs[i].want)) {
        fprintf(stderr, "LN_TB_FAIL %s: err 0x%02x, wanted bit 0x%02x\n", ecs[i].nm,
                (unsigned)e, ecs[i].want);
        g_fail = 1;
      }
      d.reset();
      st.dispatches++;
    }
  }

  // ---------------- perf: cycles per row and per element -------------------------------
  if (perf && shard == 0) {
    struct { int K, HW, M; bool tp, in16, out16; const char *nm; } P[] = {
      {288, 1, 165, false, false, false, "LN  K=288  one-pass int8"},
      {288, 1, 165, false, true,  false, "LN  K=288  one-pass int16 in"},
      {512, 1,  32, false, false, false, "LN  K=512  one-pass int8"},
      {249, 1,  32, false, false, false, "LN  K=249  one-pass int8"},
      {248, 1,  32, false, false, false, "LN  K=248  one-pass int8"},
      {128, 1,  32, false, false, false, "LN  K=128  one-pass int8"},
      { 16, 1,  32, false, false, false, "LN  K=16   one-pass int8"},
      {  1, 1,  32, false, false, false, "LN  K=1    one-pass int8"},
      {288, 1,  32, true,  false, false, "LN  K=288  two-pass int8"},
      {1024, 4, 16, true,  true,  true,  "GN  K=1024 HW=4 two-pass int16"},
      {1000, 500, 8, true, true,  true,  "GN  K=1000 HW=500 two-pass int16"},
    };
    for (unsigned i = 0; i < sizeof P / sizeof P[0]; i++) {
      uint64_t cy[2]; int Ms[2] = {P[i].M, P[i].M * 3};
      for (int q = 0; q < 2; q++) {
        Cfg c; c.K = P[i].K; c.HW = P[i].HW; c.nc = (P[i].K + P[i].HW - 1) / P[i].HW;
        c.M = Ms[q]; c.two_pass = P[i].tp; c.in16 = P[i].in16; c.out16 = P[i].out16;
        c.eps = 262145;
        fill_params(c, false, 1 << 20, 0);
        std::vector<int32_t> x((size_t)c.M * c.K);
        int lim = c.in16 ? 32767 : 127;
        for (size_t j = 0; j < x.size(); j++) x[j] = (int32_t)rnd_range(-lim - 1, lim);
        c.name = P[i].nm;
        Stats tmp; check(d, c, x, tmp, 0);
        cy[q] = g_last_cycles;
      }
      double r = (double)(cy[1] - cy[0]) / (double)(Ms[1] - Ms[0]);   // steady rate per row
      double lat = (double)cy[0] - r * Ms[0];
      printf("LN_TB_PERF %-32s steady %8.2f cycles/row  %7.4f cycles/element"
             "  first-in-to-last-out %.0f + %.2f*M\n", P[i].nm, r, r / P[i].K, lat, r);
    }
  }

  uint64_t td = 0, tb = 0, tr = 0, te = 0, tf = 0;
  for (std::map<std::string, Stats>::iterator it = S.begin(); it != S.end(); ++it) {
    printf("LN_TB_CASE %-12s %8" PRIu64 " dispatches (%7" PRIu64 " with back-pressure) "
           "%9" PRIu64 " rows, %11" PRIu64 " elements, %" PRIu64 " differ, "
           "%" PRIu64 " unclamped, %" PRIu64 " on the round boundary\n",
           it->first.c_str(), it->second.dispatches, it->second.bp, it->second.rows,
           it->second.elems, it->second.differ, it->second.unclamped, it->second.boundary);
    td += it->second.dispatches; tb += it->second.bp; tr += it->second.rows;
    te += it->second.elems; tf += it->second.differ;
  }
  printf("%s shard %d: %" PRIu64 " dispatches (%" PRIu64 " with back-pressure), %" PRIu64
         " rows, %" PRIu64 " elements, %" PRIu64 " differ from the q16 reference\n",
         (tf == 0 && !g_fail) ? "LN_TB_OK" : "LN_TB_FAILED", shard, td, tb, tr, te, tf);
  return (tf == 0 && !g_fail) ? 0 : 1;
}
