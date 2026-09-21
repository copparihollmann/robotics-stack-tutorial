// SPDX-License-Identifier: Apache-2.0
//
// tb_smx -- the softmax lane (mbxr_smx.v) against kernel_softmax_s8, byte for byte.
//
// THE GOLDEN IS THE KERNEL, NOT A MODEL OF THE LANE.  smx_golden.c is compiled as C with the
// host checks' flags and links kernel_softmax_s8 of pext_nl_softmax_s8_pext_int_memo2.c
// unchanged.  The lane's configuration (table, om, s) comes from smx_lane_cfg, a copy of the
// kernel's own set-up lines: if that copy were wrong, every dispatch would mismatch.
//
// CASES
//   table      softmax_memo_exact.c part (1)'s 20,000 scale_in draws (its generator, same seed,
//              same order), one dispatch each: K in [256, 1024], 2 rows, every row holding all
//              256 int8 values, so every d in [0, 255] is computed at every scale, at a spread of
//              scale_out (s from 0 to 45, 62..127 included) and row sums.
//   rows       softmax_memo_exact.c part (2), verbatim: 400,000 dispatches of random and corner
//              rows (all-equal, one-hot with max +127, max at -128, max near -127, max +127
//              near-equal), K in {1,2,3,7,36,165,512}, M in 1..8.  The generator continues from
//              part (1) exactly as in the C check, so these are its vectors.
//   grid       softmax_memo2_monotone.c's scale grid: 2,000 scale_in x 20 scale_out, one dispatch
//              per point, K = 1024, 4 rows each holding all 256 values plus 768 extras (j copies
//              of the max and 768 - j of the min, j in {0, 16, 128, 768}): every d at 4 row sums
//              per grid point (160,000 (scale_in, scale_out, sum) points x 256 d).
//   moonshine  the six encoder softmaxes of Moonshine (acts.npz: M = 1320, K = 165, their
//              scales from graph.json), twice (no back-pressure, then random back-pressure).
//              For information only, the kernel's output is also compared with the dump's
//              output tensor, which is ModelBlaster's float reference (numeric_drift class).
//   mshlike    synthetic Moonshine-shaped dispatches, K = 165, M = 1320.
//   synth      injected tables: arbitrary uint32 entries (ex[0] >= 2^31), om in [0, 2^31),
//              s in [0, 127], K in 1..1024.  Golden: the kernel's row code with the table
//              injected (memo2's smx2_out, cross-checked against pext_int_memo's nl_scale form).
//   stress     K = 1..8 (and 165, 1024) and long output stalls: fills the rings, the row queues, the divider's
//              holding register and the output FIFO.
//   perf       K = 165 (and 1024, 36): cycles per row and per element with the input always
//              valid and the output always ready; then scores arriving at one row per 186 cycles
//              (the MAC array's row time) -- does the lane ever push back?
//   errs       s < 0, K = 0, K = 1025, a configuration written while busy, a wrong in_last,
//              a row whose sum is below 2^31 (all-zero table: outputs 0, err[2]).
// BACK-PRESSURE: a fraction of the dispatches in every case (and all of `stress`) run with a
// random AXI-style source (valid held until taken) and a random sink, with bursts of stalls.
//
// Expect a final line beginning SMX_TB_OK.

#include "Vmbxr_smx.h"
#include "verilated.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
void smx_golden_kernel(const int8_t *in, int8_t *out, int M, int K, float scale_in,
                       float scale_out);
void smx_lane_cfg(float scale_in, float scale_out, uint32_t ex[256], int32_t *om, int *s);
long smx_golden_table(const int8_t *in, int8_t *out, int M, int K, const uint32_t ex[256],
                      int32_t om, int s);
}

// ---- softmax_memo_exact.c's generator, verbatim --------------------------------------------
static uint64_t rs = 88172645463325252ull;
static uint64_t xr(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static float rfloat(double lo, double hi) { double u = (xr() >> 11) * (1.0 / 9007199254740992.0); return (float)exp(log(lo) + u * (log(hi) - log(lo))); }

// ---- the testbench's own randomness (never touches rs) -------------------------------------
// tr: vector content, one fixed sequence whatever the sharding.  br: back-pressure and the perf
// rows, seeded per shard.
static uint64_t ts = 0x9E3779B97F4A7C15ull, bs = 0x2545F4914F6CDD1Dull;
static uint64_t tr(void) { ts ^= ts << 13; ts ^= ts >> 7; ts ^= ts << 17; return ts; }
static double tu(void) { return (tr() >> 11) * (1.0 / 9007199254740992.0); }
static float tfloat(double lo, double hi) { return (float)exp(log(lo) + tu() * (log(hi) - log(lo))); }
static uint64_t br(void) { bs ^= bs << 13; bs ^= bs >> 7; bs ^= bs << 17; return bs; }
static double bu(void) { return (br() >> 11) * (1.0 / 9007199254740992.0); }

struct BP {
  double p_in = 1.0, p_out = 1.0;      // per-cycle probability of offering / accepting
  double burst = 0.0;                   // per-cycle probability of starting a stall burst
  int burst_max = 0;                    // longest burst
  const char *name = "none";
};

static BP random_bp(void) {
  BP b;
  switch (br() % 7) {
  case 0: b.p_in = 0.5; b.p_out = 1.0; b.name = "in50"; break;
  case 1: b.p_in = 1.0; b.p_out = 0.5; b.name = "out50"; break;
  case 2: b.p_in = 0.7; b.p_out = 0.3; b.name = "in70out30"; break;
  case 3: b.p_in = 0.2; b.p_out = 0.9; b.name = "in20out90"; break;
  case 4: b.p_in = 0.9; b.p_out = 0.9; b.burst = 0.002; b.burst_max = 3000; b.name = "burst3000"; break;
  case 5: b.p_in = 1.0; b.p_out = 0.05; b.name = "out5"; break;
  default: b.p_in = 0.6; b.p_out = 0.6; b.burst = 0.02; b.burst_max = 40; b.name = "burst40"; break;
  }
  return b;
}

struct Totals {
  long dispatches = 0, rows = 0, bytes = 0, bad_bytes = 0, bad_dispatches = 0, bp_dispatches = 0;
};

// bytes checked by the lane's shift regime: s = 0, 1..16, 17 (Moonshine), 18..33, 34..61 (fast
// path, all 0), 62..127 (nl_scale branch, all 0)
static long s_bytes[6];
static void count_s(int s, long n) {
  int b = s == 0 ? 0 : s <= 16 ? 1 : s == 17 ? 2 : s <= 33 ? 3 : s <= 61 ? 4 : 5;
  s_bytes[b] += n;
}

static Vmbxr_smx *dut;
static uint64_t cyc = 0;
static int nfail_print = 0;

static void tick(void) {
  dut->clk = 1; dut->eval();
  dut->clk = 0; dut->eval();
  cyc++;
}

static void reset(void) {
  dut->rst = 1; dut->cfg_we = 0; dut->in_valid = 0; dut->out_ready = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst = 0; tick();
}

static void cfg_write(unsigned addr, uint32_t data) {
  dut->cfg_we = 1; dut->cfg_addr = addr; dut->cfg_wdata = data;
  tick();
  dut->cfg_we = 0;
}

static void configure(const uint32_t ex[256], int32_t om, int s, int K) {
  for (int d = 0; d < 256; d++) cfg_write((unsigned)d, ex[d]);
  cfg_write(0x100, (uint32_t)om);
  cfg_write(0x101, (uint32_t)s);
  cfg_write(0x102, (uint32_t)K);
}

// Per-row timing, recorded when asked (perf).
struct RowTimes { std::vector<uint64_t> first_in, last_in, last_out; long pushback = 0; };

// Stream M*K scores through the lane and check every output byte against exp.
// `gap_pattern` > 0: offer the scores of each row spread over gap_pattern cycles (MAC-array rate).
static bool stream(const std::vector<int8_t> &in, const std::vector<int8_t> &exp, int M, int K,
                   const BP &bp, const char *tag, Totals &t, RowTimes *rt = nullptr,
                   int row_cycles = 0) {
  const size_t N = (size_t)M * K;
  size_t ip = 0, op = 0;
  long bad = 0;
  int in_hold = 0, out_hold = 0;       // burst counters
  bool offered = false;
  uint64_t start = cyc;
  double per_byte = 20.0 / (bp.p_in * bp.p_out) * (1.0 + bp.burst * bp.burst_max) + 20.0;
  uint64_t idle_limit = 200000 + (uint64_t)((double)N * per_byte);
  long bucket = 0;                     // row_cycles > 0: the producer makes K scores per row_cycles

  while (op < N) {
    if (cyc - start > idle_limit) {
      printf("SMX_TB_FAIL %s: timeout at in %zu / out %zu of %zu (cycle %llu)\n", tag, ip, op, N,
             (unsigned long long)cyc);
      return false;
    }
    // sample the lane's registered outputs
    bool in_ready = dut->in_ready, out_valid = dut->out_valid;
    uint8_t out_data = dut->out_data;
    bool out_last = dut->out_last;
    // source: AXI-style, valid held until taken
    if (!offered && ip < N) {
      bool go;
      if (row_cycles > 0) {
        // a producer that finishes a score every row_cycles/K cycles and stalls (does not bank
        // time) while its score waits
        bucket += K;
        go = bucket >= row_cycles;
        if (go) bucket -= row_cycles;
      } else {
        if (in_hold > 0) { in_hold--; go = false; }
        else {
          if (bp.burst > 0 && bu() < bp.burst) in_hold = 1 + (int)(br() % (uint64_t)bp.burst_max);
          go = bu() < bp.p_in;
        }
      }
      offered = go;
    }
    bool ready;
    if (out_hold > 0) { out_hold--; ready = false; }
    else {
      if (bp.burst > 0 && bu() < bp.burst) out_hold = 1 + (int)(br() % (uint64_t)bp.burst_max);
      ready = bu() < bp.p_out;
    }
    dut->in_valid = offered;
    dut->in_data = offered ? (uint8_t)in[ip] : 0;
    dut->in_last = offered ? ((ip % (size_t)K) == (size_t)K - 1) : 0;
    dut->out_ready = ready;
    if (offered && !in_ready && rt) rt->pushback++;
    if (offered && in_ready) {
      if (rt) {
        if (ip % (size_t)K == 0) rt->first_in.push_back(cyc);
        if (ip % (size_t)K == (size_t)K - 1) rt->last_in.push_back(cyc);
      }
      ip++;
      offered = false;
    }
    if (out_valid && ready) {
      bool want_last = (op % (size_t)K) == (size_t)K - 1;
      if ((int8_t)out_data != exp[op] || out_last != want_last) {
        if (nfail_print < 20) {
          printf("SMX_TB_MISMATCH %s: byte %zu (row %zu col %zu) lane %d last %d, kernel %d last %d\n",
                 tag, op, op / (size_t)K, op % (size_t)K, (int)(int8_t)out_data, (int)out_last,
                 (int)exp[op], (int)want_last);
          nfail_print++;
        }
        bad++;
      }
      if (rt && want_last) rt->last_out.push_back(cyc);
      op++;
    }
    tick();
  }
  dut->in_valid = 0; dut->out_ready = 0;
  // the lane must be idle once the last byte is out (allow the state to settle a cycle or two)
  for (int i = 0; i < 4 && !dut->idle; i++) tick();
  if (!dut->idle) {
    printf("SMX_TB_FAIL %s: not idle after the last output\n", tag);
    return false;
  }
  t.dispatches++; t.rows += M; t.bytes += (long)N; t.bad_bytes += bad;
  if (bp.p_in < 1.0 || bp.p_out < 1.0 || bp.burst > 0) t.bp_dispatches++;
  if (bad) t.bad_dispatches++;
  return bad == 0;
}

static bool err_clear(void) {
  cfg_write(0x103, 0);
  return true;
}

static bool check_err(const char *tag, unsigned want) {
  unsigned e = dut->err;
  if (e != want) {
    printf("SMX_TB_FAIL %s: err = 0x%x, want 0x%x\n", tag, e, want);
    return false;
  }
  return true;
}

// one kernel dispatch: configure from the scales, stream, compare with kernel_softmax_s8
static bool kernel_dispatch(const std::vector<int8_t> &in, int M, int K, float sin_, float sout,
                            const BP &bp, const char *tag, Totals &t, std::vector<int8_t> *gold_out = nullptr) {
  uint32_t ex[256];
  int32_t om;
  int s;
  std::vector<int8_t> gold((size_t)M * K);
  smx_golden_kernel(in.data(), gold.data(), M, K, sin_, sout);
  if (gold_out) *gold_out = gold;
  smx_lane_cfg(sin_, sout, ex, &om, &s);
  if (s < 0) {             // ruled out (see mbxr_smx.v): the lane refuses such a configuration
    printf("SMX_TB_NOTE %s: s = %d < 0 skipped (scale_out %g)\n", tag, s, (double)sout);
    return true;
  }
  configure(ex, om, s, K);
  if (!check_err(tag, 0)) return false;
  count_s(s, (long)M * K);
  bool ok = stream(in, gold, M, K, bp, tag, t);
  if (!check_err(tag, 0)) return false;
  return ok;
}

// ---- cases ---------------------------------------------------------------------------------
struct Opts {
  long table = 20000, rows = 400000, synth = 40000, mshlike = 120, stress = 3000;
  int grid_a = 2000;
  double bp_frac = 0.25;
  const char *moonshine = nullptr;
  int shard = 0, nshards = 1;
  bool perf = true, errs = true;
};

static bool mine(const Opts &o, long idx) { return (idx % o.nshards) == o.shard; }

static float pick_sout(void) {
  // spread of s = floor(log2 scale_out) + 24: the Moonshine value, the check's range, and the
  // boundaries of the lane's s handling (0, 33, 34, 61, 62, 127)
  switch (tr() % 8) {
  case 0: case 1: return (float)(1.0 / 127.0);
  case 2: return tfloat(1e-3, 2.0);
  case 3: return tfloat(ldexp(1.0, -24), ldexp(1.0, 22));             // s in [0, 45]
  case 4: { int e = (int)(tr() % 12) - 24; return (float)ldexp(1.0 + tu(), e); }    // s in [0, 11]
  case 5: { static const int es[] = { 9, 10, 37, 38, 103 }; return (float)ldexp(1.0 + tu() * 0.99, es[tr() % 5]); }
  case 6: return tfloat(ldexp(1.0, 38), ldexp(1.0, 100));            // s in [62, 124]
  default: return tfloat(1e-4, 1.0);
  }
}

static bool case_table(const Opts &o, Totals &t) {
  std::vector<int8_t> in;
  bool ok = true;
  for (long n = 0; n < o.table; n++) {
    float sin_ = rfloat(1e-5, 30.0);         // softmax_memo_exact.c part (1)'s draw
    float sout = pick_sout();
    int K = 256 + (int)(tr() % 769), M = 2;
    in.assign((size_t)M * K, 0);
    for (int m = 0; m < M; m++) {
      int8_t *x = &in[(size_t)m * K];
      // all 256 values once, then K - 256 extras: random (row 0) or mostly copies of the max,
      // which raise the sum (row 1)
      for (int k = 0; k < K; k++)
        x[k] = (k < 256) ? (int8_t)(k - 128) : (m == 1 && (tr() % 4)) ? (int8_t)127 : (int8_t)(tr() & 0xff);
      for (int k = K - 1; k > 0; k--) { int j = (int)(tr() % (uint64_t)(k + 1)); std::swap(x[k], x[j]); }
    }
    if (!mine(o, n)) continue;
    BP bp = (bu() < o.bp_frac) ? random_bp() : BP();
    char tag[64]; snprintf(tag, sizeof tag, "table[%ld]", n);
    ok &= kernel_dispatch(in, M, K, sin_, sout, bp, tag, t);
    if (!ok) return false;
  }
  return ok;
}

static bool case_grid(const Opts &o, Totals &t) {
  static const int js[4] = { 0, 16, 128, 768 };
  const int K = 1024, M = 4;
  std::vector<int8_t> in((size_t)M * K);
  bool ok = true;
  long n = 0;
  for (int a = 0; a < o.grid_a; a++) {
    float sin_ = (float)exp(log(1e-4) + (log(40.0) - log(1e-4)) * a / 1999.0);
    for (int c = 0; c < 20; c++, n++) {
      float sout = c == 0 ? (float)(1.0 / 127.0) : (float)exp(log(1e-3) + (log(2.0) - log(1e-3)) * c / 19.0);
      if (!mine(o, n)) continue;
      for (int m = 0; m < M; m++) {
        int8_t *x = &in[(size_t)m * K];
        for (int k = 0; k < K; k++) x[k] = (k < 256) ? (int8_t)(k - 128) : (k < 256 + js[m]) ? (int8_t)127 : (int8_t)-128;
        for (int k = K - 1; k > 0; k--) { int j = (int)(br() % (uint64_t)(k + 1)); std::swap(x[k], x[j]); }
      }
      BP bp = (bu() < o.bp_frac) ? random_bp() : BP();
      char tag[64]; snprintf(tag, sizeof tag, "grid[%d,%d]", a, c);
      ok &= kernel_dispatch(in, M, K, sin_, sout, bp, tag, t);
      if (!ok) return false;
    }
  }
  return ok;
}

static bool case_rows(const Opts &o, Totals &t) {
  static const int Ks[] = { 1, 2, 3, 7, 36, 165, 512 };
  std::vector<int8_t> in(512 * 8);
  bool ok = true;
  for (long n = 0; n < o.rows; n++) {
    int K = Ks[xr() % 7], M = 1 + (int)(xr() % 8);
    float sin_ = rfloat(1e-4, 20.0), sout = (xr() % 3 == 0) ? rfloat(1e-3, 1.0) : (float)(1.0 / 127.0);
    int kind = (int)(xr() % 8);
    for (int i = 0; i < M * K; i++) {
      switch (kind) {
      case 0: in[i] = 5; break;
      case 1: in[i] = (i % K == (int)(n % K)) ? 127 : -128; break;
      case 2: in[i] = -128; break;
      case 3: in[i] = (int8_t)(-128 + (int)(xr() % 3)); break;
      case 4: in[i] = (int8_t)(127 - (int)(xr() % 2)); break;
      default: in[i] = (int8_t)(xr() & 0xff); break;
      }
    }
    if (!mine(o, n)) continue;
    BP bp = (bu() < o.bp_frac) ? random_bp() : BP();
    std::vector<int8_t> x(in.begin(), in.begin() + M * K);
    char tag[64]; snprintf(tag, sizeof tag, "rows[%ld]", n);
    ok &= kernel_dispatch(x, M, K, sin_, sout, bp, tag, t);
    if (!ok) return false;
  }
  return ok;
}

static bool case_moonshine(const Opts &o, Totals &t, Totals &t_bp, long &acts_mism) {
  FILE *f = fopen(o.moonshine, "rb");
  if (!f) { printf("SMX_TB_FAIL moonshine: cannot open %s\n", o.moonshine); return false; }
  char magic[4]; uint32_t nd;
  if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "SMXM", 4) || fread(&nd, 4, 1, f) != 1) {
    printf("SMX_TB_FAIL moonshine: bad file\n"); fclose(f); return false;
  }
  bool ok = true;
  for (uint32_t d = 0; d < nd; d++) {
    float sin_, sout; int32_t M, K;
    if (fread(&sin_, 4, 1, f) != 1 || fread(&sout, 4, 1, f) != 1 || fread(&M, 4, 1, f) != 1 ||
        fread(&K, 4, 1, f) != 1) { ok = false; break; }
    std::vector<int8_t> in((size_t)M * K), acts((size_t)M * K), gold;
    if (fread(in.data(), 1, in.size(), f) != in.size() ||
        fread(acts.data(), 1, acts.size(), f) != acts.size()) { ok = false; break; }
    uint32_t ex[256]; int32_t om; int s;
    smx_lane_cfg(sin_, sout, ex, &om, &s);
    char tag[64]; snprintf(tag, sizeof tag, "moonshine[%u]", d);
    ok &= kernel_dispatch(in, M, K, sin_, sout, BP(), tag, t, &gold);
    long am = 0;
    int amax = 0;
    for (size_t i = 0; i < gold.size(); i++) {
      int e = abs((int)gold[i] - (int)acts[i]);
      am += e != 0;
      if (e > amax) amax = e;
    }
    acts_mism += am;
    int zeros = 0;
    for (auto v : gold) zeros += v == 0;
    printf("SMX_TB_CASE %s: M %d K %d scale_in %.6f scale_out %.6f s %d om %d: %zu bytes, kernel vs "
           "float reference %ld differ, %.1f %% zero\n", tag, M, K, (double)sin_, (double)sout, s, om,
           gold.size(), am, 100.0 * zeros / (double)gold.size());
    printf("SMX_TB_NOTE %s: kernel vs float reference max_abs_err %d\n", tag, amax);
    snprintf(tag, sizeof tag, "moonshine_bp[%u]", d);
    BP bp; bp.p_in = 0.7; bp.p_out = 0.6; bp.burst = 0.001; bp.burst_max = 2000; bp.name = "mixed";
    ok &= kernel_dispatch(in, M, K, sin_, sout, bp, tag, t_bp);
    if (!ok) break;
  }
  fclose(f);
  return ok;
}

static bool case_mshlike(const Opts &o, Totals &t) {
  bool ok = true;
  for (long n = 0; n < o.mshlike; n++) {
    int M = 1320, K = 165;
    float sin_ = tfloat(0.15, 0.32), sout = (float)(1.0 / 127.0);
    std::vector<int8_t> in((size_t)M * K);
    for (int m = 0; m < M; m++) {
      // a few attended positions over a Gaussian-ish background
      double mu = -20.0 + 40.0 * tu(), sd = 8.0 + 30.0 * tu();
      for (int k = 0; k < K; k++) {
        double g = (tu() + tu() + tu() + tu() - 2.0) * 1.73 * sd + mu;
        if (tu() < 0.03) g += 40.0 + 60.0 * tu();
        int v = (int)lround(g);
        in[(size_t)m * K + k] = (int8_t)(v > 127 ? 127 : (v < -128 ? -128 : v));
      }
    }
    if (!mine(o, n)) continue;
    BP bp = (n % 2) ? random_bp() : BP();
    char tag[64]; snprintf(tag, sizeof tag, "mshlike[%ld]", n);
    ok &= kernel_dispatch(in, M, K, sin_, sout, bp, tag, t);
    if (!ok) break;
  }
  return ok;
}

static bool case_synth(const Opts &o, Totals &t, long &disagree) {
  bool ok = true;
  for (long n = 0; n < o.synth; n++) {
    uint32_t ex[256];
    int kind = (int)(tr() % 6);
    for (int d = 0; d < 256; d++) {
      uint32_t r = (uint32_t)tr();
      switch (kind) {
      case 0: ex[d] = r; break;                                   // anything
      case 1: ex[d] = r >> (tr() % 32); break;                    // spread of magnitudes
      case 2: ex[d] = 0xffffffffu; break;                         // the widest sum
      case 3: ex[d] = (d & 1) ? 0 : r; break;                     // non-monotone, zeros
      case 4: ex[d] = (uint32_t)(0x80000000u >> (d % 32)); break; // powers of two
      default: ex[d] = (tr() % 4) ? 0 : 0x80000000u; break;
      }
    }
    ex[0] |= 0x80000000u;                                         // the lane's precondition
    int32_t om;
    switch (tr() % 4) {
    case 0: om = (int32_t)(0x40000000u + (uint32_t)(tr() % 0x40000000u)); break;
    case 1: om = 0x7fffffff; break;
    case 2: om = (int32_t)(tr() % 0x80000000u); break;
    default: om = (int32_t)(tr() % 4096); break;
    }
    int s = (tr() % 4) ? (int)(tr() % 41) : (int)(tr() % 128);
    int K = (tr() % 3) ? 1 + (int)(tr() % 1024) : 1 + (int)(tr() % 8);
    int M = 1 + (int)(tr() % 4);
    std::vector<int8_t> in((size_t)M * K);
    int rk = (int)(tr() % 3);
    for (auto &v : in) v = (int8_t)(rk == 0 ? (tr() & 0xff) : rk == 1 ? (127 - (int)(tr() % 4)) : (-128 + (int)(tr() % 300 == 0)));
    std::vector<int8_t> gold((size_t)M * K);
    long dis = smx_golden_table(in.data(), gold.data(), M, K, ex, om, s);
    disagree += dis;
    if (!mine(o, n)) continue;
    BP bp = (bu() < o.bp_frac) ? random_bp() : BP();
    configure(ex, om, s, K);
    count_s(s, (long)M * K);
    char tag[64]; snprintf(tag, sizeof tag, "synth[%ld]", n);
    if (!check_err(tag, 0)) return false;
    ok &= stream(in, gold, M, K, bp, tag, t);
    if (!check_err(tag, 0)) return false;
    if (!ok) break;
  }
  return ok;
}

static bool case_stress(const Opts &o, Totals &t) {
  bool ok = true;
  for (long n = 0; n < o.stress; n++) {
    static const int Ks[] = { 1, 2, 3, 4, 5, 8, 165, 1024 };
    int K = Ks[tr() % 8];
    int M = (K >= 165) ? 2 + (int)(tr() % 6) : 50 + (int)(tr() % 400);
    float sin_ = tfloat(1e-3, 10.0), sout = pick_sout();
    std::vector<int8_t> in((size_t)M * K);
    for (auto &v : in) v = (int8_t)(tr() & 0xff);
    if (!mine(o, n)) continue;
    BP bp;
    switch (n % 3) {
    case 0: bp.p_in = 1.0; bp.p_out = 0.02; bp.burst = 0.001; bp.burst_max = 5000; bp.name = "sink-starved"; break;
    case 1: bp.p_in = 1.0; bp.p_out = 1.0; bp.burst = 0.01; bp.burst_max = 3000; bp.name = "long-stalls"; break;
    default: bp = random_bp(); break;
    }
    char tag[64]; snprintf(tag, sizeof tag, "stress[%ld] K%d", n, K);
    ok &= kernel_dispatch(in, M, K, sin_, sout, bp, tag, t);
    if (!ok) break;
  }
  return ok;
}

struct PerfResult { int K; int M; double period, lat_first, lat_steady, proc; long pushback; };

static bool perf_run(int K, int M, int row_cycles, Totals &t, PerfResult &r) {
  float sin_ = 0.2807556926612239f, sout = (float)(1.0 / 127.0);
  std::vector<int8_t> in((size_t)M * K), gold((size_t)M * K);
  for (auto &v : in) v = (int8_t)(br() & 0xff);
  smx_golden_kernel(in.data(), gold.data(), M, K, sin_, sout);
  uint32_t ex[256]; int32_t om; int s;
  smx_lane_cfg(sin_, sout, ex, &om, &s);
  configure(ex, om, s, K);
  RowTimes rt;
  char tag[64]; snprintf(tag, sizeof tag, "perf K%d rc%d", K, row_cycles);
  bool ok = stream(in, gold, M, K, BP(), tag, t, &rt, row_cycles);
  if (!ok || (int)rt.last_out.size() != M || (int)rt.first_in.size() != M) return false;
  int a = M / 2, b = M - 1;
  r.K = K; r.M = M;
  r.period = (double)(rt.last_out[b] - rt.last_out[a]) / (double)(b - a);
  r.lat_first = (double)(rt.last_out[0] - rt.first_in[0] + 1);
  r.lat_steady = (double)(rt.last_out[b] - rt.first_in[b] + 1);
  r.proc = (double)(rt.last_out[b] - rt.last_in[b]);
  r.pushback = rt.pushback;
  printf("SMX_TB_PERF K %d rows %d offered %s: steady %.2f cycles/row = %.3f cycles/element; "
         "first score in to last output out: row 0 %.0f, row %d %.0f cycles; last score in to "
         "last output out %.0f; cycles the source was held off %ld\n",
         K, M, row_cycles ? (std::to_string(row_cycles) + " cycles/row").c_str() : "always",
         r.period, r.period / K, r.lat_first, b, r.lat_steady, r.proc, r.pushback);
  return true;
}

static bool case_errs(Totals &t) {
  bool ok = true;
  uint32_t ex[256]; int32_t om; int s;
  smx_lane_cfg(0.25f, (float)(1.0 / 127.0), ex, &om, &s);
  // s < 0: refused
  configure(ex, om, -1, 165);
  ok &= check_err("errs s<0", 0x1);
  tick();
  if (dut->in_ready) { printf("SMX_TB_FAIL errs: in_ready with s < 0\n"); ok = false; }
  // K = 0 and K = 1025: refused; K = 1024 accepted
  configure(ex, om, s, 0);    ok &= check_err("errs K=0", 0x1);
  configure(ex, om, s, 1025); ok &= check_err("errs K=1025", 0x1);
  configure(ex, om, s, 1024); ok &= check_err("errs K=1024", 0x0);
  // a configuration write while a row is in flight
  configure(ex, om, s, 4);
  dut->in_valid = 1; dut->in_data = 3; dut->in_last = 0; tick(); dut->in_valid = 0;
  cfg_write(0x100, (uint32_t)om);
  ok &= check_err("errs busy", 0x2);
  // finish the row and drain it, then clear
  {
    std::vector<int8_t> rest = { 3, 1, -7, 3 }, gold(4);
    smx_golden_kernel(rest.data(), gold.data(), 1, 4, 0.25f, (float)(1.0 / 127.0));
    std::vector<int8_t> tail(rest.begin() + 1, rest.end());
    // the first byte is already in; stream the other three, expect the whole row
    size_t ip = 0, op = 0;
    for (int c = 0; c < 2000 && op < 4; c++) {
      bool rdy = dut->in_ready, ov = dut->out_valid; int8_t od = (int8_t)dut->out_data;
      dut->in_valid = ip < 3; dut->in_data = ip < 3 ? (uint8_t)tail[ip] : 0; dut->in_last = ip == 2;
      dut->out_ready = 1;
      if (ip < 3 && rdy) ip++;
      if (ov) { if (od != gold[op]) { printf("SMX_TB_FAIL errs: busy row byte %zu\n", op); ok = false; } op++; }
      tick();
    }
    dut->in_valid = 0; dut->out_ready = 0;
    for (int c = 0; c < 4; c++) tick();
    if (op != 4 || !dut->idle) { printf("SMX_TB_FAIL errs: busy row did not drain\n"); ok = false; }
  }
  err_clear();
  ok &= check_err("errs clear", 0x0);
  // wrong in_last
  configure(ex, om, s, 3);
  {
    std::vector<int8_t> row = { 1, 2, 3 }, gold(3);
    smx_golden_kernel(row.data(), gold.data(), 1, 3, 0.25f, (float)(1.0 / 127.0));
    size_t ip = 0, op = 0;
    for (int c = 0; c < 2000 && op < 3; c++) {
      bool rdy = dut->in_ready, ov = dut->out_valid; int8_t od = (int8_t)dut->out_data;
      dut->in_valid = ip < 3; dut->in_data = ip < 3 ? (uint8_t)row[ip] : 0; dut->in_last = (ip == 1);
      dut->out_ready = 1;
      if (ip < 3 && rdy) ip++;
      if (ov) { if (od != gold[op]) ok = false; op++; }
      tick();
    }
    dut->in_valid = 0; dut->out_ready = 0;
    for (int c = 0; c < 4; c++) tick();
  }
  ok &= check_err("errs in_last", 0x8);
  err_clear();
  // a row whose sum is below 2^31: an all-zero table gives sum == 0 -> every output 0, err[2]
  {
    uint32_t z[256] = { 0 };
    std::vector<int8_t> row = { 5, -3, 100, 7, 7 }, gold(5);
    long dis = smx_golden_table(row.data(), gold.data(), 1, 5, z, om, s);
    configure(z, om, s, 5);
    bool sok = stream(row, gold, 1, 5, BP(), "errs sum==0", t) && dis == 0;
    for (auto v : gold) sok &= v == 0;
    ok &= sok;
    ok &= check_err("errs sum<2^31", 0x4);
    err_clear();
    ok &= check_err("errs clear2", 0x0);
  }
  printf("SMX_TB_CASE errs: s<0, K=0, K=1025, K=1024, busy write, wrong in_last, sum==0: %s\n",
         ok ? "as specified" : "FAILED");
  return ok;
}

static void report(const char *name, const Totals &t) {
  printf("SMX_TB_CASE %s: %ld dispatches (%ld with back-pressure), %ld rows, %ld bytes, %ld bytes "
         "differ\n", name, t.dispatches, t.bp_dispatches, t.rows, t.bytes, t.bad_bytes);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Opts o;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto nxt = [&](void) { return (i + 1 < argc) ? argv[++i] : (char *)"0"; };
    if (a == "--table") o.table = atol(nxt());
    else if (a == "--rows") o.rows = atol(nxt());
    else if (a == "--grid") o.grid_a = atoi(nxt());
    else if (a == "--synth") o.synth = atol(nxt());
    else if (a == "--mshlike") o.mshlike = atol(nxt());
    else if (a == "--stress") o.stress = atol(nxt());
    else if (a == "--bp-frac") o.bp_frac = atof(nxt());
    else if (a == "--moonshine") o.moonshine = nxt();
    else if (a == "--shard") o.shard = atoi(nxt());
    else if (a == "--nshards") o.nshards = atoi(nxt());
    else if (a == "--no-perf") o.perf = false;
    else if (a == "--no-errs") o.errs = false;
    else if (a == "--quick") { o.table = 400; o.rows = 4000; o.synth = 200; o.mshlike = 2; o.stress = 30; o.grid_a = 20; }
  }
  // per-shard back-pressure, so shards do not repeat each other's
  bs ^= 0xD1B54A32D192ED03ull * (uint64_t)(o.shard + 1);
  for (int i = 0; i < 16; i++) br();

  dut = new Vmbxr_smx;
  dut->clk = 0;
  reset();
  bool ok = true;
  Totals t_table, t_grid, t_rows, t_msh, t_msh_bp, t_mshl, t_synth, t_stress, t_perf, t_errs;
  long acts_mism = 0, synth_dis = 0;
  bool first_shard = o.shard == 0;

  if (ok && o.perf && first_shard) {
    PerfResult r;
    ok &= perf_run(165, 64, 0, t_perf, r);
    ok &= perf_run(165, 64, 186, t_perf, r);
    ok &= perf_run(165, 64, 165, t_perf, r);
    ok &= perf_run(36, 64, 0, t_perf, r);
    ok &= perf_run(1024, 12, 0, t_perf, r);
    ok &= perf_run(1, 400, 0, t_perf, r);
    report("perf", t_perf);
  }
  if (ok && o.errs && first_shard) ok &= case_errs(t_errs);
  if (ok) { ok &= case_table(o, t_table); report("table", t_table); }
  if (ok) { ok &= case_rows(o, t_rows); report("rows", t_rows); }
  if (ok) { ok &= case_grid(o, t_grid); report("grid", t_grid); }
  if (ok && o.moonshine && first_shard) {
    ok &= case_moonshine(o, t_msh, t_msh_bp, acts_mism);
    report("moonshine", t_msh); report("moonshine_bp", t_msh_bp);
    printf("SMX_TB_NOTE moonshine: kernel_softmax_s8 vs acts.npz (float reference, informational): "
           "%ld of %ld bytes differ\n", acts_mism, t_msh.bytes);
  }
  if (ok) { ok &= case_mshlike(o, t_mshl); report("mshlike", t_mshl); }
  if (ok) {
    ok &= case_synth(o, t_synth, synth_dis); report("synth", t_synth);
    printf("SMX_TB_CASE synth: memo2 smx2_out vs pext_int_memo nl_scale form on the injected tables: "
           "%ld bytes differ\n", synth_dis);
    ok &= synth_dis == 0;
  }
  if (ok) { ok &= case_stress(o, t_stress); report("stress", t_stress); }

  Totals all;
  for (const Totals *x : { &t_table, &t_grid, &t_rows, &t_msh, &t_msh_bp, &t_mshl, &t_synth, &t_stress, &t_perf, &t_errs }) {
    all.dispatches += x->dispatches; all.rows += x->rows; all.bytes += x->bytes;
    all.bad_bytes += x->bad_bytes; all.bp_dispatches += x->bp_dispatches;
  }
  ok &= all.bad_bytes == 0;
  printf("SMX_TB_SHIFT bytes by s: s=0 %ld, 1..16 %ld, 17 %ld, 18..33 %ld, 34..61 %ld, 62..127 %ld\n",
         s_bytes[0], s_bytes[1], s_bytes[2], s_bytes[3], s_bytes[4], s_bytes[5]);
  printf("%s shard %d/%d: %ld dispatches (%ld with back-pressure), %ld rows, %ld output bytes, "
         "%ld differ from kernel_softmax_s8; %llu cycles\n",
         ok ? "SMX_TB_OK" : "SMX_TB_FAILED", o.shard, o.nshards, all.dispatches, all.bp_dispatches,
         all.rows, all.bytes, all.bad_bytes, (unsigned long long)cyc);
  delete dut;
  return ok ? 0 : 1;
}
