// SPDX-License-Identifier: Apache-2.0
//
// tb_mbxr -- the engine, driven by the board's own driver, against ModelBlaster's reference.
//
// WHAT IS UNDER TEST.  rtl_study/roccmoon/mbxr_engine.v (with rtl_study/rocc/mbxd_dma.v and
// mbxd_spad.v byte-identical to the measured files) AND sw/roccmoon/mbxr.c, the driver hart 1
// runs.  A "command" here drives the engine's RoCC fields for one cycle, which is what the
// Chisel shim does with a custom-1 instruction.
//
// THE REFERENCE IS NOT A MODEL OF THE ENGINE.  It is kernel_linear_s8 copied verbatim from
// ModelBlaster's pipeline/reference_kernels.py (reference_impl), the kernel every curated
// kernel in this repository is gated against.  A 1-D convolution over a contiguous window is
// checked by gathering the windows and calling the same function.
//
// THE MEMORY IS ADVERSARIAL.  Two TileLink slaves (client W and client A) over one byte array:
// random A-channel back-pressure, random per-source latency, at most one D beat per client
// per cycle chosen at random among the sources that are due -- so beats of one source arrive
// in order and beats of different sources interleave however TileLink allows.  It also
// CHECKS the protocol: a Get or Put on a source that is still in flight is an error, a Get
// that is not a 64-byte block-aligned request is an error, a Put burst that is not 8
// contiguous beats on one source and address is an error.
//
// INCREMENTAL PLACEMENT (dev.place_early) is checked the hard way: the scratch area is
// poisoned before every dispatch.  L2-LIKE PUTS (commit_at_ack): a Put's bytes reach memory only
// when its AccessAck is sent, and ack latency has a heavy tail (tail_permille of Puts wait
// log-uniformly up to tail_max cycles) -- the InclusiveCache completes a Put when a miss
// handler gets to it, and 001A measured 139-300 cycles worst-line with stalls modelled at
// ~6,640.  Acks of the two drain source IDs then return far out of order.  Otherwise, with
// put_commit_delay > 0 a Put's bytes reach memory
// that many cycles AFTER its last beat is accepted (in acceptance order, as a bus between the
// engine and the L2 would deliver them; the AccessAck waits for the commit).  A placement that
// read a block before its bytes landed would copy poison.
//
// Expect a final line beginning MBXR_TB_OK.

// MBXR_TB_2CLK: the revision-2b top (mbxr_engine_x, W_ASYNC = 1), with client W and the weight
// half on their own clock -- period tw_period against the engine's tc_period (default 10 : 29,
// the 100 MHz lane against 34.48 MHz), random phase.  Client W's latencies count lane cycles.
#ifdef MBXR_TB_2CLK
#include "Vmbxr_engine_x.h"
typedef Vmbxr_engine_x Vtop;
#else
#include "Vmbxr_engine.h"
typedef Vmbxr_engine Vtop;
#endif
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <string>
#include <vector>

extern "C" {
#include "mbxr.h"
}

// ---- reference: verbatim from ModelBlaster reference_kernels.py (kernel_linear_s8) -------
static void kernel_linear_s8(const int8_t *input, const int8_t *weight,
                      const int32_t *bias, int8_t *output,
                      int M, int K, int N,
                      int input_offset, int filter_offset, int output_offset,
                      int output_multiplier, int output_shift,
                      int activation_min, int activation_max) {
    for (int m = 0; m < M; m++) {
        for (int n = 0; n < N; n++) {
            int32_t acc = bias ? bias[n] : 0;
            for (int k = 0; k < K; k++) {
                int32_t in_v = (int32_t)input[m * K + k] + input_offset;
                int32_t w_v  = (int32_t)weight[n * K + k] + filter_offset;
                acc += in_v * w_v;
            }
            /* Q0.31 rounding multiply. */
            int64_t prod = (int64_t)acc * (int64_t)output_multiplier;
            prod = (prod + (1LL << 30)) >> 31;
            int32_t scaled = (int32_t)prod;
            if (output_shift > 0) {
                scaled = (int32_t)(((int64_t)scaled + ((int64_t)1 << (output_shift - 1))) >> output_shift);
            } else if (output_shift < 0) {
                scaled = scaled << (-output_shift);
            }
            scaled += output_offset;
            if (scaled < activation_min) scaled = activation_min;
            if (scaled > activation_max) scaled = activation_max;
            output[m * N + n] = (int8_t)scaled;
        }
    }
}

// ---- the simulated SoC ---------------------------------------------------------------------
static const uint64_t MEM_BASE = 0x80000000ULL;
static const uint64_t MEM_SIZE = 96ULL << 20;

struct Txn {
  bool live = false, put = false;
  uint64_t addr = 0;
  int beat = 0;
  uint64_t due = 0;
};

struct Slave {
  std::string name;
  std::vector<Txn> t;          // indexed by source
  int put_src = -1, put_beats = 0, put_size = 0;   // put_size: lg2(beats) of the burst
  uint64_t put_addr = 0;
  uint64_t *clk_ctr = nullptr;  // the cycle counter of this slave's clock
  explicit Slave(const char *n, int nsrc) : name(n), t(nsrc) {}
};

struct Sim {
  Vtop *top;
  std::vector<uint8_t> mem;
  std::mt19937_64 rng;
  uint64_t cyc = 0;
  int errors = 0;
  Slave W{"W", 16}, A{"A", 16};
  int lat_min = 1, lat_max = 30, ready_pct = 80;
  // MOST GETS EVER IN FLIGHT on each client, sampled every cycle.  The outstanding cap
  // (command 8) is the engine's only throttle on its fill, and it is what Lab B25's port
  // sweep varies; nothing tested that the RTL honours it until this counter existed.
  int max_live_w = 0, max_live_a = 0;
  uint64_t put_ack_extra = 0;     // make AccessAcks slow, so Puts overlap
  uint64_t put_commit_delay = 0;  // cycles from a Put beat's acceptance to its bytes in memory
  bool commit_at_ack = false;     // L2-like: bytes land with the AccessAck
  int tail_permille = 0;          // ... and this many Puts per 1000 wait up to tail_max cycles
  uint64_t tail_max = 0;
  std::multimap<uint64_t, std::pair<uint64_t, uint64_t>> pending;   // due -> (addr, data)
  uint64_t put_buf[16][8];
  uint64_t cmd_gap_max = 6;
  uint64_t gets = 0, puts = 0, early_bytes = 0, put_bytes = 0, put_beats_total = 0;

  uint64_t wcyc = 0, tc_period = 29, tw_period = 10, tc_next = 0, tw_next = 5;
  int alias_inject = 0, alias_injected = 0;  // stray W responses on ID + 4 while ID is busy
  bool force_not_quiet = false;              // a W port that never goes quiet
  uint64_t wrst_release_at = 0;              // release the lane's reset at this lane cycle
  Sim() : top(new Vtop), mem(MEM_SIZE, 0), rng(12345) { W.clk_ctr = &cyc; A.clk_ctr = &cyc; }

  uint64_t rnd(uint64_t n) { return n ? rng() % n : 0; }

  uint8_t *p(uint64_t pa) {
    if (pa < MEM_BASE || pa >= MEM_BASE + MEM_SIZE) { fprintf(stderr, "p2v out of range %llx\n", (unsigned long long)pa); abort(); }
    return &mem[pa - MEM_BASE];
  }
  uint64_t rd64(uint64_t pa) { uint64_t v = 0; for (int i = 0; i < 8; i++) v |= (uint64_t)*p(pa + i) << (8 * i); return v; }
  void wr64(uint64_t pa, uint64_t v) { for (int i = 0; i < 8; i++) *p(pa + i) = (uint8_t)(v >> (8 * i)); }

  void err(const char *msg) { if (errors < 20) fprintf(stderr, "[cyc %llu] PROTOCOL: %s\n", (unsigned long long)cyc, msg); errors++; }

  // drive D for one slave; returns true if a beat is presented
  void drive_d(Slave &s, bool is_w) {
    std::vector<int> due;
    for (size_t i = 0; i < s.t.size(); i++)
      if (s.t[i].live && s.t[i].due <= *s.clk_ctr) due.push_back((int)i);
    if (is_w) { top->wd_valid = 0; top->wd_error = 0; }
    else      { top->ad_valid = 0; top->ad_error = 0; }
    if (due.empty() || rnd(100) < 15) return;          // idle cycles on D, too
    int src = due[rnd(due.size())];
    Txn &x = s.t[src];
    if (is_w) {
      if (x.put) { err("Put on client W"); x.live = false; return; }
      top->wd_valid = 1; top->wd_source = src; top->wd_data = rd64(x.addr + 8ULL * x.beat);
      if (++x.beat == 8) x.live = false;
    } else {
      top->ad_valid = 1; top->ad_source = src;
      if (x.put) { top->ad_ack = 1; top->ad_data = 0; x.live = false; }
      else {
        top->ad_ack = 0; top->ad_data = rd64(x.addr + 8ULL * x.beat);
        if (++x.beat == 8) x.live = false;
      }
    }
  }

  // put_size: the engine's aa_size, 0..3 for 8/16/32/64-byte PutFullData.  A Get is always 64.
  void accept_a(Slave &s, bool fire, bool put, uint64_t addr, int src, uint64_t data, bool last,
                int size = 3) {
    if (!fire) return;
    if (!put) {
      gets++;
      if (addr < MEM_BASE || addr + 64 > MEM_BASE + MEM_SIZE) {    // outside the weight window
        err("Get outside the memory window");
        return;
      }
      if (s.put_src >= 0) err("Get interleaved into a Put burst");
      if (addr & 63) err("Get not block aligned");
      if (s.t[src].live) err("Get on a source already in flight");
      s.t[src] = Txn(); s.t[src].live = true; s.t[src].addr = addr;
      s.t[src].due = *s.clk_ctr + 1 + lat_min + rnd(lat_max - lat_min + 1);
      return;
    }
    if (s.put_src < 0) {
      if (s.t[src].live) err("Put on a source already in flight");
      if (size < 0 || size > 3) err("Put of an unsupported size");
      if (addr & ((8ULL << size) - 1)) err("Put not aligned to its own size");
      if (addr < MEM_BASE || addr + (8ULL << size) > MEM_BASE + MEM_SIZE)
        err("Put outside the memory window");
      s.put_src = src; s.put_addr = addr; s.put_beats = 0; s.put_size = size;
    } else if (s.put_src != src || s.put_addr != addr || s.put_size != size) {
      err("Put burst changed source, address or size mid-burst");
    }
    if (commit_at_ack) put_buf[src & 15][s.put_beats & 7] = data;
    else if (put_commit_delay) pending.insert({ cyc + put_commit_delay, { addr + 8ULL * s.put_beats, data } });
    else wr64(addr + 8ULL * s.put_beats, data);
    s.put_beats++;
    put_beats_total++;
    if (last) {
      if (s.put_beats != (1 << s.put_size)) err("Put burst is not its size in beats");
      puts++;
      put_bytes += 8ULL * s.put_beats;
      s.t[src] = Txn(); s.t[src].live = true; s.t[src].put = true; s.t[src].addr = addr;
      s.t[src].due = cyc + 1 + lat_min + rnd(lat_max - lat_min + 1) + put_ack_extra;
      if (s.t[src].due <= cyc + put_commit_delay) s.t[src].due = cyc + put_commit_delay + 1;
      if (tail_permille && (int)rnd(1000) < tail_permille)
        s.t[src].due += (uint64_t)std::exp(std::log((double)tail_max) * (double)rnd(1000001) / 1e6);
      if (commit_at_ack)             // the bytes land one cycle before the ack is presented
        for (int b = 0; b < (1 << s.put_size); b++)
          pending.insert({ s.t[src].due - 1, { addr + 8ULL * b, put_buf[src & 15][b] } });
      s.put_src = -1;
    } else if (s.put_beats >= (1 << s.put_size)) {
      err("Put burst longer than its size");
    }
  }

#ifdef MBXR_TB_2CLK
  void lane_edge() {
    if (wrst_release_at && wcyc >= wrst_release_at) { top->wrst = 0; wrst_release_at = 0; }
    drive_d(W, true);
    // A STRAY RESPONSE: an ID >= DEPTH (4) whose low bits name a busy source, carrying poison.
    if (alias_inject > 0 && !top->wd_valid && rnd(8) == 0) {
      for (int s = 0; s < 4; s++)
        if (W.t[s].live && !W.t[s].put) {
          top->wd_valid = 1; top->wd_source = s + 4; top->wd_data = 0xA5A5A5A5A5A5A5A5ULL; top->wd_error = 0;
          alias_inject--; alias_injected++;
          break;
        }
    }
    bool live = false;
    for (auto &x : W.t) live = live || x.live;
    top->w_quiet = !live && !force_not_quiet;   // the pins' AR/RLAST balance, as mbxr_wquiet computes it
    top->wa_ready = rnd(100) < (uint64_t)ready_pct;
    top->eval();
    bool wf = top->wa_valid && top->wa_ready;
    uint64_t wa_addr = top->wa_addr;
    int wa_src = top->wa_source;
    top->wclk = 1; top->eval();
    top->wclk = 0; top->eval();
    accept_a(W, wf, false, wa_addr, wa_src, 0, true);
    wcyc++;
  }
  void sample_live() {
    int w = 0, a = 0;
    for (auto &x : W.t) w += x.live && !x.put;
    for (auto &x : A.t) a += x.live && !x.put;
    if (w > max_live_w) max_live_w = w;
    if (a > max_live_a) max_live_a = a;
  }
  void tick() {
    while (tw_next < tc_next) { lane_edge(); tw_next += tw_period; }
    tc_next += tc_period;
    while (!pending.empty() && pending.begin()->first <= cyc) {
      wr64(pending.begin()->second.first, pending.begin()->second.second);
      pending.erase(pending.begin());
    }
    drive_d(A, false);
    top->aa_ready = rnd(100) < (uint64_t)ready_pct;
    top->eval();
    bool af = top->aa_valid && top->aa_ready;
    uint64_t aa_addr = top->aa_addr, aa_data = top->aa_data;
    int aa_src = top->aa_source;
    bool aa_put = top->aa_put, aa_last = top->aa_last;
#ifdef MBXR_TB_FLAT_ENGINE
    // compat/: the pre-0x5A5A002E engine has no aa_size port -- every Put is a 64-byte block.
    int aa_size = 3;
#else
    int aa_size = (int)top->aa_size;
#endif
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    top->cmd_valid = 0;
    accept_a(A, af, aa_put, aa_addr, aa_src, aa_data, aa_last, aa_size);
    sample_live();
    cyc++;
  }
#else
  void sample_live() {
    int w = 0, a = 0;
    for (auto &x : W.t) w += x.live && !x.put;
    for (auto &x : A.t) a += x.live && !x.put;
    if (w > max_live_w) max_live_w = w;
    if (a > max_live_a) max_live_a = a;
  }
  void tick() {
    while (!pending.empty() && pending.begin()->first <= cyc) {
      wr64(pending.begin()->second.first, pending.begin()->second.second);
      pending.erase(pending.begin());
    }
    drive_d(W, true);
    drive_d(A, false);
    top->wa_ready = rnd(100) < (uint64_t)ready_pct;
    top->aa_ready = rnd(100) < (uint64_t)ready_pct;
    top->eval();
    bool wf = top->wa_valid && top->wa_ready;
    bool af = top->aa_valid && top->aa_ready;
    uint64_t wa_addr = top->wa_addr, aa_addr = top->aa_addr, aa_data = top->aa_data;
    int wa_src = top->wa_source, aa_src = top->aa_source;
    bool aa_put = top->aa_put, aa_last = top->aa_last;
#ifdef MBXR_TB_FLAT_ENGINE
    // compat/: the pre-0x5A5A002E engine has no aa_size port -- every Put is a 64-byte block.
    int aa_size = 3;
#else
    int aa_size = (int)top->aa_size;
#endif
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    top->cmd_valid = 0;
    accept_a(W, wf, false, wa_addr, wa_src, 0, true);
    accept_a(A, af, aa_put, aa_addr, aa_src, aa_data, aa_last, aa_size);
    sample_live();
    cyc++;
  }
#endif

  uint64_t cmd(unsigned funct, uint64_t rs1, uint64_t rs2, int xd) {
    top->cmd_valid = 1; top->cmd_funct = funct; top->cmd_rs1 = rs1; top->cmd_rs2 = rs2;
    top->cmd_xd = xd;
    top->eval();
    uint64_t r = top->resp_data;
    if (xd && !top->resp_valid) err("xd command without resp_valid");
    tick();
    uint64_t gap = 1 + rnd(cmd_gap_max);
    for (uint64_t i = 0; i < gap; i++) tick();
    return r;
  }
};

// PROTOCOL-VIOLATION INJECTION (revision-2 engines, MBXR_TB_REV2): the driver's commands pass
// through, and at one chosen point the testbench issues a command a correct driver never
// would.  The engine must flag it (sticky error, so mbxr_run returns MBXR_E_HW) and refuse it.
//   1  a load whose mode does not match its client (weights on client A), after the drain starts
//   2  a weight load into the buffer the running tile reads, right after an mm
//   3  cfg + mm on the buffer a weight pre-load is still filling, right after that load starts
static int g_inject = 0, g_injected = 0;
static uint64_t g_cfg_rs2 = 0;

// ---- WAIT-SITE ATTRIBUTION (--waitsites) -----------------------------------------------------
// THE QUESTION IT ANSWERS: on the board, hart 1's `cyc_wait` rose 4.72x when the 2-D drain
// removed placement, and `mbxr.c` has four places that spin on the fence.  `mbxr_stats` sums
// them into one number, so nothing in a board run can say WHICH of them hart 1 sat in.
//
// This classifies every fence poll WITHOUT touching the driver, from the command stream the
// driver emits and the status word each poll read.  A run of consecutive FENCEs is closed by
// the next non-fence command, and that command names the site:
//   -> STAT : the mbxr_wait(BUSY) before a dispatch arms anything          (INIT)
//   -> SD   : a load's wait_place(FILL)                                    (FILL)
//   -> CFG  : the tile pair's wait_place(FILL|TSEQ)                        (TSEQ)
//   -> ST   : BOTH of the above back to back -- the pair's FILL|TSEQ wait and then the
//             strided arm's mbxr_wait(DRAIN|PIPE) before the descriptor is re-armed.  The two
//             merge into one run because no command separates them, so they are SPLIT at the
//             first poll whose status had FILL and TSEQ clear: that poll is the last of the
//             FILL|TSEQ wait, and everything after it is the drain flush.       (TSEQ + FLUSH)
//   closed by hand after mbxr_run_to returns: the final wait_place(BUSY)    (FINAL)
// Cycles are the cycles the simulated SoC advanced inside each fence command, which is what
// mbxr_wait's own now()-to-now() measures.
enum { WS_INIT = 0, WS_FILL, WS_TSEQ, WS_FLUSH, WS_FINAL, WS_N };
static const char *ws_name[WS_N] = { "init BUSY", "load FILL", "pair FILL|TSEQ",
                                     "re-arm DRAIN|PIPE", "final BUSY" };
static int g_ws_on = 0;
static uint64_t g_ws_polls[WS_N], g_ws_cyc[WS_N], g_ws_visits[WS_N];
static std::vector<std::pair<uint64_t, uint64_t> > g_ws_run;   // (status, cycles) of the open run
static void ws_reset(void) {
  for (int i = 0; i < WS_N; i++) { g_ws_polls[i] = g_ws_cyc[i] = g_ws_visits[i] = 0; }
  g_ws_run.clear();
}
static void ws_charge(int site, size_t lo, size_t hi) {   // [lo, hi) of the open run
  if (hi <= lo) return;
  g_ws_visits[site]++;
  for (size_t i = lo; i < hi; i++) { g_ws_polls[site]++; g_ws_cyc[site] += g_ws_run[i].second; }
}
static void ws_close(unsigned next_f) {                   // next_f = ~0u: end of dispatch
  if (g_ws_run.empty()) return;
  int site = WS_TSEQ;
  if (next_f == MBXR_STAT) site = WS_INIT;
  else if (next_f == MBXR_SD) site = WS_FILL;
  else if (next_f == (unsigned)~0u) site = WS_FINAL;
  if (next_f == MBXR_ST) {
    size_t j = 0;
    while (j < g_ws_run.size() && (g_ws_run[j].first & (MBXR_S_FILL | MBXR_S_TSEQ)) != 0) j++;
    // j is the first poll that saw FILL|TSEQ clear; it is the last poll of that wait.  If the
    // run never cleared them it is all one wait (the flat arm's single ST, before the loop).
    if (j < g_ws_run.size()) { ws_charge(WS_TSEQ, 0, j + 1); ws_charge(WS_FLUSH, j + 1, g_ws_run.size()); }
    else ws_charge(WS_TSEQ, 0, g_ws_run.size());
  } else {
    ws_charge(site, 0, g_ws_run.size());
  }
  g_ws_run.clear();
}

static uint64_t c_cmd(void *ctx, unsigned f, uint64_t a, uint64_t b, int xd) {
  Sim *S = (Sim *)ctx;
  uint64_t wc0 = S->cyc;
  uint64_t r = S->cmd(f, a, b, xd);
  if (g_ws_on) {
    if (f == MBXR_FENCE) g_ws_run.push_back(std::make_pair(r, S->cyc - wc0));
    else ws_close(f);
  }
  if (f == MBXR_CFG) g_cfg_rs2 = b;
  if (g_inject && !g_injected) {
    if (g_inject == 1 && f == MBXR_ST) {
      S->cmd(MBXR_LD, (1ULL << 18) | (1ULL << 17) | (10ULL << 8), 0, 0);
      g_injected = 1;
    } else if (g_inject == 2 && f == MBXR_MM) {
      uint64_t wbuf = (g_cfg_rs2 >> 41) & 1;
      S->cmd(MBXR_LD, (1ULL << 17) | (wbuf << 16) | (10ULL << 8), 0, 0);
      g_injected = 1;
    } else if (g_inject == 3 && f == MBXR_LD && ((a >> 17) & 1)) {
      uint64_t fbuf = (a >> 16) & 1;
      S->cmd(MBXR_CFG, (1ULL << 32) | (1ULL << 16) | 1ULL, (1ULL << 48) | (fbuf << 41), 0);
      S->cmd(MBXR_MM, 0, 0, 0);
      g_injected = 1;
    }
  }
  return r;
}
static void *c_p2v(void *ctx, uint64_t pa) { return ((Sim *)ctx)->p(pa); }
static uint64_t c_now(void *ctx) { return ((Sim *)ctx)->cyc; }

// THE BOARD'S BUILDER.  mbxr_rt.h builds every weight image with mbxr_wimage_build_fn (one
// pass, no staging buffer), so the bench builds them that way too -- otherwise the 80-case
// output check verifies a function the board no longer calls.  The callback hands back rows of
// the same flat [N, K] buffer the staged form took.
struct RowSrc { const int8_t *w; int K; };
static void tb_row_fn(void *ctx, int n, int8_t *dst) {
  const RowSrc *r = (const RowSrc *)ctx;
  for (int k = 0; k < r->K; k++) dst[k] = r->w[(size_t)n * r->K + k];
}

struct Case {
  std::string name;
  int npix, K, N, astride;      // astride in words; linear: astride = K/8
};

static int g_expect_rc = 0;       // a case that must END with this rc (not MBXR_OK): outputs are not compared
static int run_case(Sim &S, mbxr_dev &dev, const Case &c, uint64_t seed, bool verbose, uint64_t in_off) {
  std::mt19937_64 r(seed);
  const int K = c.K, N = c.N, npix = c.npix, as = c.astride;
  uint64_t in_bytes = (uint64_t)(npix - 1) * 8 * as + K;
  // input tensor at an 8-byte-aligned address that is deliberately NOT block aligned
  uint64_t in_pa = MEM_BASE + (16ULL << 20) + in_off;
  std::vector<int8_t> w((size_t)N * K);
  std::vector<int32_t> bias(N);
  for (auto &x : w) x = (int8_t)(r() & 0xff);
  // mostly full range, sometimes corners only
  bool corners = (r() % 4) == 0;
  static const int8_t cv[] = { -128, -1, 0, 1, 127 };
  for (uint64_t i = 0; i < in_bytes; i++) *S.p(in_pa + i) = corners ? (uint8_t)cv[r() % 5] : (uint8_t)(r() & 0xff);
  if (corners) for (auto &x : w) x = cv[r() % 5];
  for (auto &b : bias) {
    switch (r() % 4) {
      case 0: b = 0; break;
      case 1: b = (int32_t)(r() % 2001) - 1000; break;
      case 2: b = (int32_t)(r() % 200001) - 100000; break;
      default: b = (int32_t)(uint32_t)r(); break;          // int32 wrap territory
    }
  }
  mbxr_quant q;
  q.mult = (int32_t)((1u << 30) + (uint32_t)(r() % (1u << 30)));
  int sh = (int)(r() % 26) - 3;             // -3 .. 22
  q.shift = sh;
  q.amin = (r() % 3 == 0) ? 0 : ((r() % 3 == 0) ? -(int)(r() % 128) : -128);
  q.amax = (r() % 3 == 0) ? (int)(r() % 128) : 127;
  if (q.amin > q.amax) q.amin = q.amax;

  mbxr_wimage img;
  if (!mbxr_wimage_plan_ex(&img, N, K, dev.drain_strided)) { fprintf(stderr, "%s: plan refused\n", c.name.c_str()); return 1; }
  uint64_t img_pa = MEM_BASE + (32ULL << 20);
  { RowSrc rs = { w.data(), K }; mbxr_wimage_build_fn(&dev, &img, img_pa, tb_row_fn, &rs, bias.data()); }
  uint64_t scratch_pa = MEM_BASE + (64ULL << 20);
  std::vector<int8_t> gold((size_t)npix * N);
  // THE OUTPUT TENSOR LIVES IN THE SIMULATED MEMORY, with a guard band either side.  The
  // strided drain WRITES it -- "a drain may not over-write" is the one asymmetry against the
  // fill, and a guard band is how that claim is checked rather than argued.  The flat arm
  // places into the same buffer through the same pointer, so the bound holds for both.
  const uint64_t GUARD = 4096;
  uint64_t out_pa = MEM_BASE + (80ULL << 20);
  int8_t *outp = (int8_t *)S.p(out_pa);
  for (uint64_t i = 0; i < GUARD; i++) {
    *S.p(out_pa - GUARD + i) = (uint8_t)(0x3C ^ (i * 17));
    *S.p(out_pa + (uint64_t)npix * N + i) = (uint8_t)(0xC3 ^ (i * 17));
  }
  for (size_t i = 0; i < (size_t)npix * N; i++) outp[i] = 0x55;
  // poison the scratch area: a result placed before the drain wrote it is caught
  uint64_t sbytes = (uint64_t)npix * (uint64_t)((N + 3) / 4) * 4 + 64;
  for (uint64_t i = 0; i < sbytes; i++) *S.p(scratch_pa + i) = (uint8_t)(0xA5 ^ (i * 131));

  // golden: gather windows, call the reference
  std::vector<int8_t> win((size_t)npix * K);
  for (int pp = 0; pp < npix; pp++)
    for (int k = 0; k < K; k++) win[(size_t)pp * K + k] = (int8_t)*S.p(in_pa + (uint64_t)pp * 8 * as + k);
  kernel_linear_s8(win.data(), w.data(), bias.data(), gold.data(), npix, K, N, 0, 0, 0,
                   q.mult, q.shift, q.amin, q.amax);

  mbxr_stats st; memset(&st, 0, sizeof st);
  uint64_t c0 = S.cyc, dp0 = S.puts, db0 = S.put_beats_total;
  int rc = mbxr_run_to(&dev, &img, in_pa, npix, as, &q, scratch_pa, outp, out_pa, &st);
  uint64_t cycles = S.cyc - c0, dputs = S.puts - dp0, dbeats = S.put_beats_total - db0;
  uint64_t steps = S.cmd(MBXR_STAT, MBXR_C_STEPS, 0, 1);
  uint64_t fillb = S.cmd(MBXR_STAT, MBXR_C_FILL_BEATS, 0, 1);
  if (g_expect_rc) return rc == g_expect_rc ? 0 : 1;
  if (rc != MBXR_OK) { fprintf(stderr, "%s: mbxr_run rc=%d\n", c.name.c_str(), rc); return 1; }
  size_t bad = 0; int maxerr = 0;
  for (uint64_t i = 0; i < GUARD; i++) {
    if (*S.p(out_pa - GUARD + i) != (uint8_t)(0x3C ^ (i * 17)) ||
        *S.p(out_pa + (uint64_t)npix * N + i) != (uint8_t)(0xC3 ^ (i * 17))) {
      fprintf(stderr, "  %s: the drain wrote OUTSIDE out[%d][%d] at guard byte %llu\n",
              c.name.c_str(), npix, N, (unsigned long long)i);
      bad++;
      break;
    }
  }
  for (size_t i = 0; i < (size_t)npix * N; i++) {
    int e = abs((int)outp[i] - (int)gold[i]);
    if (e) { if (bad < 5) fprintf(stderr, "  %s: out[%zu] = %d, reference %d\n", c.name.c_str(), i, outp[i], gold[i]); bad++; }
    if (e > maxerr) maxerr = e;
  }
  if (verbose || bad)
    printf("  %-28s npix %4d K %5d N %5d astride %4d | tiles_w %3d Q %3d lgpw %2d | pairs %4llu "
           "loads a/w %llu/%llu fill %6llu KB | cycles %9llu steps %9llu fillbeats %8llu | "
           "shift %3d amin %4d amax %4d | strided %d drain %6llu Puts %8llu beats | early %d placed early %7llu of %7llu | max_abs_err %d%s\n",
           c.name.c_str(), npix, K, N, as, img.tiles, img.Q, img.lgpw,
           (unsigned long long)st.pairs, (unsigned long long)st.loads_act,
           (unsigned long long)st.loads_wgt, (unsigned long long)((st.bytes_act + st.bytes_wgt) >> 10),
           (unsigned long long)cycles, (unsigned long long)steps, (unsigned long long)fillb,
           q.shift, q.amin, q.amax, img.strided && dev.drain_strided,
           (unsigned long long)dputs, (unsigned long long)dbeats, dev.place_early,
           (unsigned long long)st.placed_early,
           (unsigned long long)((size_t)npix * N), maxerr, bad ? "  MISMATCH" : "");
  if (dev.place_early) S.early_bytes += st.placed_early;
  return bad ? 1 : 0;
}

// ---- a dispatch from a file: a real model's weights, requantisation, input and GOLDEN output
// (fpga/pynq-z2/modelblaster/moonshine/engine_cases.py).  The expected bytes are the integer
// golden's, not the reference kernel's run here.
// ---- THE IDENTITY DISPATCH, in the bench, emitting exactly what the board emits ---------------
// The two-halves configuration -- the MM reading the weight banks on one clock while the lane
// writes them on another, with the double-buffer switch underneath -- is the one thing no gate in
// this campaign has driven, and 0x5A5A0013's wrong arithmetic survives every one of them.  This
// runs the board's section 2b here: A = 2I and a unit requantiser, so the output IS the weight
// matrix and a wrong byte names a (plane, tile, quad, word, byte) instead of a count.
//
// TWO RULES IT KEEPS, both learned the hard way in this campaign:
//   * WHAT DECIDES THE VERDICT IS NOT THE MECHANISM UNDER TEST.  The answer comes from
//     kernel_linear_s8 -- ModelBlaster's own reference, no engine in it -- and from the weight
//     bytes themselves.  A bench whose plumbing shares the write-side fanout it is meant to
//     indict cannot tell a reproduction from a bug in itself.
//   * PROVE IT ON A KNOWN ANSWER FIRST.  RMB_ID_HARNESS must read ref_vs_weights_bad=0 or nothing
//     below it means anything; and the FIRST shape is G + 1 = 37, which the board gets exactly
//     right, so a bench that corrupts everything is caught before it can look like a reproduction.
// It prints the board's line format on purpose: moonshine/score_identity.py grades this bench and
// the two boards with one scorer, against bands that live in a file rather than in a judgement.
static int run_identity(Sim &S, mbxr_dev &dev, int K, int N)
{
  const int M = K;                       // A = 2I forces it
  std::vector<int8_t> w((size_t)N * K);
  for (int n = 0; n < N; n++)
    for (int k = 0; k < K; k++) w[(size_t)n * K + k] = (int8_t)((((n & 15) << 3) | (k & 7)) - 64);
  std::vector<int32_t> bias(N, 0);
  mbxr_quant q; q.mult = 1 << 30; q.shift = 0; q.amin = -128; q.amax = 127;

  mbxr_wimage img;
  if (!mbxr_wimage_plan(&img, N, K)) { printf("RMB_ID_SKIP K=%d N=%d\n", K, N); return 0; }
  uint64_t img_pa = MEM_BASE + (32ULL << 20);
  { RowSrc rs = { w.data(), K }; mbxr_wimage_build_fn(&dev, &img, img_pa, tb_row_fn, &rs, bias.data()); }

  uint64_t in_pa = MEM_BASE + (16ULL << 20);
  for (size_t i = 0; i < (size_t)M * K; i++) *S.p(in_pa + i) = 0;
  for (int m = 0; m < M; m++) *S.p(in_pa + (uint64_t)m * K + m) = 2;

  std::vector<int8_t> win((size_t)M * K), gold((size_t)M * N);
  for (int m = 0; m < M; m++)
    for (int k = 0; k < K; k++) win[(size_t)m * K + k] = (int8_t)*S.p(in_pa + (uint64_t)m * K + k);
  kernel_linear_s8(win.data(), w.data(), bias.data(), gold.data(), M, K, N, 0, 0, 0,
                   q.mult, q.shift, q.amin, q.amax);
  size_t refbad = 0;
  for (int m = 0; m < M; m++)
    for (int n = 0; n < N; n++) if (gold[(size_t)m * N + n] != w[(size_t)n * K + m]) refbad++;
  printf("RMB_ID_HARNESS K=%d N=%d G=%d Q=%d lgpw=%d tiles=%d ref_vs_weights_bad=%zu\n",
         K, N, img.G, img.Q, img.lgpw, img.tiles, refbad);
  if (refbad) return 1;                  // the harness is wrong; nothing below means anything

  uint64_t scratch_pa = MEM_BASE + (64ULL << 20);
  uint64_t sbytes = (uint64_t)M * (uint64_t)((N + 3) / 4) * 4 + 64;
  for (uint64_t i = 0; i < sbytes; i++) *S.p(scratch_pa + i) = (uint8_t)(0xA5 ^ (i * 131));
  std::vector<int8_t> out((size_t)M * N, 0x55);
  mbxr_stats st; memset(&st, 0, sizeof st);
  int rc = mbxr_run(&dev, &img, in_pa, M, K / 8, &q, scratch_pa, out.data(), &st);

  size_t bad = 0; int hp[4] = { 0 }, hb[8] = { 0 }, ht[8] = { 0 }, shown = 0;
  for (int m = 0; m < M && rc == MBXR_OK; m++) {
    for (int n = 0; n < N; n++) {
      int8_t got = out[(size_t)m * N + n], exp = w[(size_t)n * K + m];
      if (got == exp) continue;
      bad++;
      int r = n % 4, tq = n / 4, t = tq / img.Q, qd = tq % img.Q;
      int word = qd * (img.G + 1) + m / 8, byte = m % 8;
      hp[r]++; hb[byte]++; if (t < 8) ht[t]++;
      if (shown++ < 24)
        printf("RMB_ID_BAD K=%d m=%d n=%d exp=%d got=%d plane=%d tile=%d quad=%d word=%d bank=%d "
               "byte=%d from_n=%d from_k=%d\n", K, m, n, exp, got, r, t, qd, word, word >> 9, byte,
               ((got + 64) >> 3) & 15, (got + 64) & 7);
    }
  }
  printf("RMB_ID K=%d N=%d rc=%d bad=%zu of %zu  plane=%d,%d,%d,%d  byte=%d,%d,%d,%d,%d,%d,%d,%d  "
         "tile0_7=%d,%d,%d,%d,%d,%d,%d,%d\n", K, N, rc, bad, (size_t)M * N,
         hp[0], hp[1], hp[2], hp[3], hb[0], hb[1], hb[2], hb[3], hb[4], hb[5], hb[6], hb[7],
         ht[0], ht[1], ht[2], ht[3], ht[4], ht[5], ht[6], ht[7]);
  return (rc != MBXR_OK) ? 1 : 0;        // WRONG BYTES ARE THE POINT: they are not a tb failure
}

static int run_file_case(Sim &S, mbxr_dev &dev, const char *path, uint64_t *cyc_out) {
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
  std::vector<uint8_t> d;
  { uint8_t buf[65536]; size_t n; while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n); }
  fclose(f);
  if (d.size() < 52 || memcmp(d.data(), "MBXRCASE", 8)) { fprintf(stderr, "%s: not a case file\n", path); return 1; }
  size_t o = 8;
  auto u32 = [&](void) { uint32_t v; memcpy(&v, &d[o], 4); o += 4; return v; };
  uint32_t kind = u32(), npix = u32(), K = u32(), N = u32(), as = u32();
  int32_t mult = (int32_t)u32(), shift = (int32_t)u32(), amin = (int32_t)u32(), amax = (int32_t)u32();
  uint64_t inb; memcpy(&inb, &d[o], 8); o += 8;
  size_t need = o + inb + (size_t)N * K + 4 * (size_t)N + (size_t)npix * N;
  if (d.size() < need) { fprintf(stderr, "%s: short file\n", path); return 1; }
  std::string name(d.begin() + need, d.end());
  uint64_t in_pa = MEM_BASE + (16ULL << 20) + 16;
  memcpy(S.p(in_pa), &d[o], inb); o += inb;
  memset(S.p(in_pa + inb), 0, 64);
  std::vector<int8_t> w(&d[o], &d[o] + (size_t)N * K); o += (size_t)N * K;
  std::vector<int32_t> bias(N); memcpy(bias.data(), &d[o], 4 * (size_t)N); o += 4 * (size_t)N;
  std::vector<int8_t> gold(&d[o], &d[o] + (size_t)npix * N);
  mbxr_wimage img;
  if (!mbxr_wimage_plan(&img, (int)N, (int)K)) { fprintf(stderr, "%s: plan refused\n", name.c_str()); return 1; }
  uint64_t img_pa = MEM_BASE + (32ULL << 20);
  { RowSrc rs = { w.data(), K }; mbxr_wimage_build_fn(&dev, &img, img_pa, tb_row_fn, &rs, bias.data()); }
  uint64_t scratch_pa = MEM_BASE + (64ULL << 20);
  uint64_t sbytes = (uint64_t)npix * (uint64_t)((N + 3) / 4) * 4 + 64;
  for (uint64_t i = 0; i < sbytes; i++) *S.p(scratch_pa + i) = (uint8_t)(0xA5 ^ (i * 131));
  std::vector<int8_t> out((size_t)npix * N, 0x55);
  mbxr_quant q; q.mult = mult; q.shift = shift; q.amin = amin; q.amax = amax;
  mbxr_stats st; memset(&st, 0, sizeof st);
  uint64_t c0 = S.cyc;
  int rc = mbxr_run(&dev, &img, in_pa, (int)npix, (int)as, &q, scratch_pa, out.data(), &st);
  *cyc_out = S.cyc - c0;
  size_t bad = 0;
  if (rc == MBXR_OK)
    for (size_t i = 0; i < out.size(); i++) if (out[i] != gold[i]) { if (bad < 3) fprintf(stderr, "  %s: out[%zu] = %d, golden %d\n", name.c_str(), i, out[i], gold[i]); bad++; }
  printf("  %-44s %s npix %4u K %5u N %4u astride %4u shift %3d | pairs %4llu cycles %9llu | rc %d, %zu of %zu bytes differ%s\n",
         name.c_str(), kind ? "conv  " : "linear", npix, K, N, as, shift, (unsigned long long)st.pairs,
         (unsigned long long)*cyc_out, rc, bad, out.size(), (rc || bad) ? "  MISMATCH" : "");
  return (rc != MBXR_OK || bad) ? 1 : 0;
}


// ==========================================================================================
// LANE COVERAGE (--lanes).  The gap the registry names: "mbxr_lanes.v's LN streamer and its
// ownership arbitration have no testbench of their own and are not exercised by any gate."
//
// WHY IT EXISTS NOW.  Three board loads found three faults in the lane dispatch path, one per
// load, because there was nowhere else for them to show.  Every one of them would have appeared
// here in seconds.  The rule this follows -- build the guard while the trigger is still free to
// demonstrate -- means FAULT 4 IS A REPRODUCTION AND NOT A HYPOTHESIS: the first case below
// replays the board's own sequence and fails if ownership does not come back, before anything
// is fixed on the strength of a guess.
//
// WHAT MAKES THIS COVERAGE RATHER THAN A MODEL OF IT: the cases call the REAL DRIVER --
// sw/roccmoon/mbxr_lanes.h's mbxr_ln_dispatch(), the same header the board runs -- with the
// three custom-1 stubs bound to this testbench's command interface.  A bug in the driver is a
// bug here.  (Fault 1, the affine table written from hart 0, is the one thing this cannot see:
// there are no harts in Verilator.  It is listed in the summary as uncovered rather than
// silently absent.)
// ==========================================================================================
static Sim *g_lane_sim = nullptr;
extern "C" void mbxr_l_cfg(uint64_t a, uint64_t d) { g_lane_sim->cmd(9, a, d, 0); }
extern "C" void mbxr_l_go(uint64_t w, uint64_t u) { g_lane_sim->cmd(10, w, u, 0); }
extern "C" uint64_t mbxr_l_st(uint64_t a, uint64_t b) { return g_lane_sim->cmd(11, a, b, 1); }

#include "mbxr_lanes.h"

// the reference this op is DEFINED by (reference_kernels.py's _Q16_NORM_CORE), so a match is
// against the definition rather than against a second implementation
static unsigned __int128 ln_isqrt128(unsigned __int128 v) {
  unsigned __int128 r = 0, bit = (unsigned __int128)1 << 126;
  while (bit > v) bit >>= 2;
  while (bit) { if (v >= r + bit) { v -= r + bit; r = (r >> 1) + bit; } else r >>= 1; bit >>= 2; }
  return r;
}
static void ln_golden(const int8_t *x, const int32_t *umul, const int64_t *gmul,
                      const int64_t *badd, int8_t *y, int M, int K, int64_t eps) {
  for (int m = 0; m < M; m++) {
    const int8_t *xr = x + (size_t)m * K; int8_t *yr = y + (size_t)m * K;
    int64_t S = 0; __int128 Q = 0;
    for (int k = 0; k < K; k++) { int64_t u = (int64_t)xr[k] * umul[k]; S += u; Q += (__int128)u * u; }
    __int128 V = (__int128)K * Q - (__int128)S * S + (__int128)eps;
    int64_t R = (int64_t)ln_isqrt128(((unsigned __int128)1 << 120) / (unsigned __int128)V);
    for (int k = 0; k < K; k++) {
      int64_t u = (int64_t)xr[k] * umul[k];
      __int128 d = (__int128)K * u - (__int128)S;
      int64_t t = (int64_t)((d * (__int128)R) >> 44);
      int64_t v = (t * gmul[k] + badd[k] * 65536 + ((int64_t)1 << 31)) >> 32;
      yr[k] = (int8_t)(v < -128 ? -128 : v > 127 ? 127 : v);
    }
  }
}

// A lane that never returns ownership poisons every case after it, so each case starts from
// reset.  Without this the first stall makes the rest of the suite report -68 and the log says
// nothing about the cases that did not actually run -- which is how a suite reports six failures
// for one fault.
static void lane_reset(Sim &S) {
  S.top->rst = 1; S.top->cmd_valid = 0;
  for (int i = 0; i < 8; i++) S.tick();
  S.top->rst = 0;
  for (int i = 0; i < 8; i++) S.tick();
}

static const uint64_t LN_SRC = MEM_BASE + (8ULL << 20);
static const uint64_t LN_DST = MEM_BASE + (16ULL << 20);

// one dispatch through the real driver; returns the driver's rc and fills `bad`
// THE CYCLE BUDGET.  The suite checked what the lane computed and never how long it took, and the
// next fault landed on exactly that axis: a dispatch that was byte-exact and 748x its predicted
// cost reached a board load because nothing here had a clock.  The budget is derived rather than
// guessed -- Lab B33's SILICON numbers, 0.99826 cycles/element and a 196-cycle wrapper, plus the
// lane's own 550-cycle per-dispatch latency -- and the multiplier is stated:
//
//   ideal   = 196 + 550 + elements * 0.99826
//   traffic = the tile's bytes in and out; in this testbench the slave answers in 1-30 cycles
//   budget  = LN_BUDGET_X * (ideal + traffic)
//
// LN_BUDGET_X is deliberately loose.  It is not a performance target: it is a tripwire for the
// order-of-magnitude failures that a functional suite cannot see, and a tight budget here would
// fail on Verilator's memory model rather than on the design.
#ifndef LN_BUDGET_X
#define LN_BUDGET_X 6.0
#endif
static double ln_ideal(int rows, int K) {
  double els = (double)rows * K;
  return 196.0 + 550.0 + els * 0.99826 + 2.0 * els;   // + fill and drain, one cycle per byte
}

static int ln_case(Sim &S, int rows, int K, int HW, int64_t eps, size_t *bad, uint64_t *polls,
                   int drain_override = 0, double *ratio = nullptr) {
  lane_reset(S);
  uint64_t cyc0 = S.cyc;
  std::vector<int8_t> x((size_t)rows * K), gold((size_t)rows * K);
  std::vector<int32_t> umul(K);
  std::vector<int64_t> gmul(K), badd(K);
  for (int k = 0; k < K; k++) {
    umul[k] = 1 + (int32_t)S.rnd(1 << 20);
    gmul[k] = (int64_t)S.rnd(1 << 19) - (1 << 18);
    badd[k] = (int64_t)S.rnd(1 << 21) - (1 << 20);
  }
  for (size_t i = 0; i < x.size(); i++) x[i] = (int8_t)(S.rnd(256) - 128);
  ln_golden(x.data(), umul.data(), gmul.data(), badd.data(), gold.data(), rows, K, eps);
  long bytes = (long)rows * K, blocks = (bytes + 63) / 64;
  long drain_blocks = drain_override ? drain_override : blocks;
  for (long i = 0; i < blocks * 64; i++) *S.p(LN_SRC + i) = (i < bytes) ? (uint8_t)x[i] : 0;
  for (long i = 0; i < (blocks + 2) * 64; i++) *S.p(LN_DST + i) = 0xAA;  // poison: a short drain shows
  // the affine table, written the way the runtime writes it: on the hart that owns custom-1
  for (int k = 0; k < K; k++)
    mbxr_ln_table((unsigned)k, (uint32_t)umul[k], (uint64_t)((int64_t)K * umul[k]),
                  (uint32_t)gmul[k], (uint32_t)badd[k]);
  int rc = mbxr_ln_dispatch(c_cmd, &S, LN_SRC, (int)(bytes / 8), 0, LN_DST, (int)drain_blocks,
                            rows, K, HW, (uint64_t)eps, 0, 200000, polls);
  double took = (double)(S.cyc - cyc0);
  if (ratio) *ratio = took / ln_ideal(rows, K);
  *bad = 0;
  if (rc == MBXR_OK)
    for (long i = 0; i < bytes; i++)
      if ((int8_t)*S.p(LN_DST + i) != gold[i]) (*bad)++;
  return rc;
}

static int lanes_main(Sim &S) {
  g_lane_sim = &S;
  int fails = 0, n = 0;
  const int64_t EPS = 262145 * 7;
  printf("MBXR_LANES: the coverage the registry says does not exist\n");

  // ---- FAULT 4, REPRODUCED FIRST: the board's own sequence, before any fix is trusted -------
  // 13 dispatches of 165 x 288, six tiles each, back to back.  On the board this stalled the
  // hart-1 worker for 58 s with last_rc = -4 and no trap.  If ownership fails to return here,
  // the reproduction is in hand; if it does not, that is itself a finding about where it lives.
  {
    int stalled = 0; uint64_t worst_polls = 0;
    for (int d = 0; d < 13 && !stalled; d++) {
      for (int m0 = 0; m0 < 165; m0 += 28) {
        int rows = 165 - m0 > 28 ? 28 : 165 - m0;
        while ((rows * 288) % 64) rows++;        /* the kernel's own padding rule */
        size_t bad = 0; uint64_t polls = 0;
        int rc = ln_case(S, rows, 288, 1, EPS, &bad, &polls);
        if (polls > worst_polls) worst_polls = polls;
        n++;
        if (rc == MBXR_E_LANE_HANG) { stalled = 1; break; }
        if (rc != MBXR_OK || bad) {
          printf("  FAULT4-SEQ d=%d m0=%d rc=%d bad=%zu\n", d, m0, rc, bad);
          fails++; break;
        }
      }
    }
    printf("  fault 4 (58 s worker stall): %s after %d dispatches, worst poll count %llu\n",
           stalled ? "REPRODUCED -- ownership never returned" : "did NOT reproduce",
           n, (unsigned long long)worst_polls);
    if (stalled) fails++;

    // ---- THE SEAM THE LOOP ABOVE DOES NOT COVER, and the board found it -------------------
    // ln_case() calls lane_reset() and REWRITES THE WHOLE AFFINE TABLE for every tile, with a
    // fresh random table each time.  The kernel does neither: roccmoon_layernorm_pc_s8's
    // mbxr_rt_ln_tile(..., m0 == 0 ? K : 0) writes the table ONCE FOR SIX TILES, there is no
    // reset between them, and the six drains are copied into ONE 165-row output that is
    // checked as a whole.  So the loop above runs the board's SHAPES and not the board's
    // SEQUENCE, and "13 dispatches, 0 failing" was never evidence about the sequence.
    //
    // This is what Lab B39 is still seeing: with the stale-buffer cfg fixed, max_abs_err fell
    // 241 -> 96 but not to 0.  A residue that survives a correct buffer, with rc = 0 and no
    // error bit on any tile, is a plausible-wrong-answer defect, and the only state that
    // crosses a tile boundary here is the affine table and whatever mbxr_ln_config rewrites
    // per tile.  One table, six tiles, one assembled answer -- exactly the kernel.
    {
      const int M = 165, K = 288, RPT = 28;
      std::vector<int8_t> x((size_t)M * K), gold((size_t)M * K), got((size_t)M * K, 0);
      std::vector<int32_t> umul(K);
      std::vector<int64_t> gmul(K), badd(K);
      for (int k = 0; k < K; k++) {
        umul[k] = 1 + (int32_t)S.rnd(1 << 20);
        gmul[k] = (int64_t)S.rnd(1 << 19) - (1 << 18);
        badd[k] = (int64_t)S.rnd(1 << 21) - (1 << 20);
      }
      for (size_t i = 0; i < x.size(); i++) x[i] = (int8_t)(S.rnd(256) - 128);
      ln_golden(x.data(), umul.data(), gmul.data(), badd.data(), gold.data(), M, K, EPS);

      lane_reset(S);                      /* once, as the board resets once */
      for (int k = 0; k < K; k++)         /* THE TABLE: once, before tile 0, as the runtime */
        mbxr_ln_table((unsigned)k, (uint32_t)umul[k], (uint64_t)((int64_t)K * umul[k]),
                      (uint32_t)gmul[k], (uint32_t)badd[k]);

      int seq_rc = MBXR_OK, tiles = 0;
      size_t seq_bad = 0;
      for (int m0 = 0; m0 < M && seq_rc == MBXR_OK; m0 += RPT) {
        int rows = M - m0 > RPT ? RPT : M - m0;
        int pad_rows = rows;
        while (((long)pad_rows * K) % 64) pad_rows++;      /* the kernel's padding rule */
        long bytes = (long)rows * K, pad_bytes = (long)pad_rows * K;
        /* the kernel stages a padded tile zero-filled and feeds an unpadded one directly */
        for (long i = 0; i < pad_bytes; i++)
          *S.p(LN_SRC + i) = (i < bytes) ? (uint8_t)x[(size_t)m0 * K + i] : 0;
        for (long i = 0; i < (pad_bytes / 64 + 2) * 64; i++) *S.p(LN_DST + i) = 0xAA;
        uint64_t p = 0;
        seq_rc = mbxr_ln_dispatch(c_cmd, &S, LN_SRC, (int)(pad_bytes / 8), 0, LN_DST,
                                  (int)(pad_bytes / 64), pad_rows, K, 1, (uint64_t)EPS, 0,
                                  200000, &p);
        tiles++;
        if (seq_rc != MBXR_OK) break;
        for (long i = 0; i < bytes; i++)          /* the kernel's copy-out: REAL rows only */
          got[(size_t)m0 * K + i] = (int8_t)*S.p(LN_DST + i);
      }
      if (seq_rc == MBXR_OK)
        for (size_t i = 0; i < gold.size(); i++)
          if (got[i] != gold[i]) seq_bad++;
      int first_bad_row = -1, worst = 0;
      for (size_t i = 0; i < gold.size() && seq_rc == MBXR_OK; i++)
        if (got[i] != gold[i]) {
          int d = (int)got[i] - (int)gold[i]; if (d < 0) d = -d;
          if (d > worst) worst = d;
          if (first_bad_row < 0) first_bad_row = (int)(i / K);
        }
      n++;
      printf("  ONE TABLE, SIX TILES, one assembled 165x288 answer (the kernel's own sequence):\n"
             "    tiles=%d rc=%d bad=%zu of %zu  first bad row=%d  max_abs_err=%d\n",
             tiles, seq_rc, seq_bad, gold.size(), first_bad_row, worst);
      if (seq_rc != MBXR_OK || seq_bad) fails++;

      // ---- CAN THIS LANE SERVE A PER-TENSOR LAYERNORM?  The arithmetic worst case. --------
      // The shipping candidate QATU emits per-tensor layernorm_s8, and patches/0103's
      // layernorm() would lower it to layernorm_pc_s8 with umul = vec/max(vec) * 2^24 -- which
      // for a per-tensor input is the CONSTANT 2^24 on every channel.  Per-CHANNEL puts only
      // the largest channel at 2^24; per-TENSOR puts all K there at once, and Q accumulates K
      // terms of u^2.  So the per-tensor case is a strictly harsher load on the lane's Q
      // accumulator than anything candidate R has ever asked of it, and mbxr_ln_consts_fit's
      // bounds (umul < 2^25, K*umul < 2^40) do not by themselves say Q survives.
      // Run with QATU's OWN numbers: K = 288, eps_q from eps 1e-5 and scale_in 0.48719966.
      {
        const int M = 165, K = 288, RPT = 28;
        const int64_t EPS_PT = 983582551378402LL;     /* rint(eps*K^2*(2^24/scale_in)^2) */
        std::vector<int8_t> x((size_t)M * K), gold((size_t)M * K), got((size_t)M * K, 0);
        std::vector<int32_t> umul(K);
        std::vector<int64_t> gmul(K), badd(K);
        for (int k = 0; k < K; k++) {
          umul[k] = 1 << 24;                          /* THE PER-TENSOR TABLE: constant */
          gmul[k] = (int64_t)S.rnd(1 << 21) - (1 << 20);
          badd[k] = (int64_t)S.rnd(1 << 21) - (1 << 20);
        }
        for (size_t i = 0; i < x.size(); i++) x[i] = (int8_t)(S.rnd(256) - 128);
        ln_golden(x.data(), umul.data(), gmul.data(), badd.data(), gold.data(), M, K, EPS_PT);
        lane_reset(S);
        for (int k = 0; k < K; k++)
          mbxr_ln_table((unsigned)k, (uint32_t)umul[k], (uint64_t)((int64_t)K * umul[k]),
                        (uint32_t)gmul[k], (uint32_t)badd[k]);
        int rc = MBXR_OK; size_t bad = 0;
        for (int m0 = 0; m0 < M && rc == MBXR_OK; m0 += RPT) {
          int rows = M - m0 > RPT ? RPT : M - m0, pad_rows = rows;
          while (((long)pad_rows * K) % 64) pad_rows++;
          long bytes = (long)rows * K, pad_bytes = (long)pad_rows * K;
          for (long i = 0; i < pad_bytes; i++)
            *S.p(LN_SRC + i) = (i < bytes) ? (uint8_t)x[(size_t)m0 * K + i] : 0;
          uint64_t p = 0;
          rc = mbxr_ln_dispatch(c_cmd, &S, LN_SRC, (int)(pad_bytes / 8), 0, LN_DST,
                                (int)(pad_bytes / 64), pad_rows, K, 1, (uint64_t)EPS_PT, 0,
                                200000, &p);
          if (rc != MBXR_OK) break;
          for (long i = 0; i < bytes; i++)
            got[(size_t)m0 * K + i] = (int8_t)*S.p(LN_DST + i);
        }
        int worst = 0;
        if (rc == MBXR_OK)
          for (size_t i = 0; i < gold.size(); i++)
            if (got[i] != gold[i]) {
              bad++;
              int d = (int)got[i] - (int)gold[i]; if (d < 0) d = -d;
              if (d > worst) worst = d;
            }
        n++;
        printf("  PER-TENSOR table (umul = 2^24 on all %d channels, QATU's eps_q), 165x288:\n"
               "    rc=%d bad=%zu of %zu  max_abs_err=%d  -> the lane %s serve per-tensor\n",
               K, rc, bad, gold.size(), worst,
               (rc == MBXR_OK && !bad) ? "CAN" : "*** CANNOT ***");
        if (rc != MBXR_OK || bad) fails++;
      }

      // ---- AND THE PRECONDITION THIS FILE COULD NOT SEE ---------------------------------
      // LN_SRC and LN_DST are MEM_BASE + 8 MB and + 16 MB: 64-byte aligned BY CONSTRUCTION.
      // mbxd_dma.v:71 takes "the byte address of the first block, 64-BYTE ALIGNED" and :38
      // says there is no byte funnel, so every case above satisfied a precondition it never
      // tested -- while on the board five tiles in six fill from an address 8, 24, 40 or 56
      // bytes into a block, because generate_skeleton.py emits the intermediates 8-byte
      // aligned.  That is a plausible wrong answer with rc = 0 and no error bit.  It is now a
      // REFUSAL, and this is the case that holds it to that.
      for (int off = 8; off <= 56; off += 16) {
        uint64_t p = 0;
        int rc = mbxr_ln_dispatch(c_cmd, &S, LN_SRC + off, 28 * 288 / 8, 0, LN_DST,
                                  28 * 288 / 64, 28, 288, 1, (uint64_t)EPS, 0, 200000, &p);
        n++;
        printf("    unaligned fill src+%2d -> rc=%d %s\n", off, rc,
               rc == MBXR_E_ALIGN ? "MBXR_E_ALIGN (refused)" : "*** NOT REFUSED ***");
        if (rc != MBXR_E_ALIGN) fails++;
      }
      {
        uint64_t p = 0;
        int rc = mbxr_ln_dispatch(c_cmd, &S, LN_SRC, 28 * 288 / 8, 0, LN_DST + 8,
                                  28 * 288 / 64, 28, 288, 1, (uint64_t)EPS, 0, 200000, &p);
        n++;
        printf("    unaligned drain dst+8 -> rc=%d %s\n", rc,
               rc == MBXR_E_ALIGN ? "MBXR_E_ALIGN (refused)" : "*** NOT REFUSED ***");
        if (rc != MBXR_E_ALIGN) fails++;
      }
    }

    // WHICH tile, and why.  The sequence stalls on the LAST tile of 165 rows -- 25 rows, 7,200
    // bytes, 112.5 drain blocks -- so the suspect is the drain block count rather than the lane.
    // Sim is where that costs seconds: ask the same tile for ceil, floor and exact-plus-padding.
    printf("  fault 4, isolated on the short tile (25 rows = 7,200 B = 112.5 blocks):\n");
    struct { int drain; const char *what; } dv[] = {
      { 113, "ceil  -- what the kernel asks for today" },
      { 112, "floor -- the drain gets only whole blocks" },
      {   0, "same as ceil, for control" },
    };
    for (auto &d : dv) {
      size_t bad = 0; uint64_t polls = 0;
      int rc = ln_case(S, 25, 288, 1, EPS, &bad, &polls, d.drain);
      printf("    drain=%-4d %-44s rc=%-5d bad=%zu polls=%llu\n",
             d.drain ? d.drain : 113, d.what, rc, bad, (unsigned long long)polls);
    }
  }

  // ---- FAULT 2 as a regression: HW must be 1, and HW = K must be VISIBLY wrong --------------
  {
    size_t bad1 = 0, badK = 0; uint64_t p1 = 0, pK = 0;
    int rc1 = ln_case(S, 4, 288, 1, EPS, &bad1, &p1);
    int rcK = ln_case(S, 4, 288, 288, EPS, &badK, &pK);
    n += 2;
    printf("  fault 2 (affine index): HW=1 rc=%d bad=%zu ; HW=K rc=%d bad=%zu\n",
           rc1, bad1, rcK, badK);
    if (rc1 != MBXR_OK || bad1) { printf("  FAIL: HW=1 must be exact\n"); fails++; }
    if (rcK == MBXR_OK && badK == 0) { printf("  FAIL: HW=K must NOT be exact\n"); fails++; }
  }

  // ---- DOES THE COST SCALE WITH MEMORY LATENCY?  The board measured 740.671 c/el where this
  // suite measures 0.6-3.2x ideal, so the mechanism is something this testbench does not model.
  // The two candidates are the per-tile hart-0/hart-1 hand-off (absent here) and memory latency
  // (1-30 cycles here, DRAM on the board).  This isolates the second: hold the shape fixed and
  // raise the slave's latency.  A cost that rises with LATENCY rather than with BYTES means a
  // poll loop is waiting on something the dispatch does not own -- which is the fence hypothesis.
  // If it stays flat, the fence is exonerated and the hand-off is where to look next.
  {
    int save_lo = S.lat_min, save_hi = S.lat_max, save_rdy = S.ready_pct;
    printf("  latency sweep on a 28-row tile (ideal %.0f cycles):\n", ln_ideal(28, 288));
    struct { int lo, hi, rdy; const char *what; } lv[] = {
      {  1,  30, 80, "as the rest of this suite runs" },
      { 20,  60, 60, "slower" },
      { 80, 200, 40, "DRAM-ish" },
      { 200, 500, 25, "worse than the part" },
    };
    for (auto &l : lv) {
      S.lat_min = l.lo; S.lat_max = l.hi; S.ready_pct = l.rdy;
      size_t bad = 0; uint64_t polls = 0; double ratio = 0;
      int rc = ln_case(S, 28, 288, 1, EPS, &bad, &polls, 0, &ratio); n++;
      printf("    lat %3d-%-3d ready %2d%%  %-30s rc=%-4d bad=%zu  %6.1fx ideal  polls=%llu\n",
             l.lo, l.hi, l.rdy, l.what, rc, bad, ratio, (unsigned long long)polls);
      if (rc != MBXR_OK || bad) fails++;
    }
    S.lat_min = save_lo; S.lat_max = save_hi; S.ready_pct = save_rdy;

    // AND THE OTHER VARIABLE, which the first sweep missed.  The fence waits for the DRAIN to
    // retire, and a drain retires on Put ACKNOWLEDGEMENTS -- not on Get latency.  Sweeping Gets
    // exonerated the fence against the wrong knob.  put_ack_extra is the right one.
    uint64_t save_ack = S.put_ack_extra;
    printf("  Put-ack sweep on the same tile (the fence waits on the drain, not on the fill):\n");
    for (uint64_t extra : { (uint64_t)0, (uint64_t)8, (uint64_t)64, (uint64_t)512 }) {
      S.put_ack_extra = extra;
      size_t bad = 0; uint64_t polls = 0; double ratio = 0;
      int rc = ln_case(S, 28, 288, 1, EPS, &bad, &polls, 0, &ratio); n++;
      printf("    put_ack_extra %4llu  rc=%-4d bad=%zu  %6.1fx ideal  polls=%llu\n",
             (unsigned long long)extra, rc, bad, ratio, (unsigned long long)polls);
      if (rc != MBXR_OK || bad) fails++;
    }
    S.put_ack_extra = save_ack;
  }

  // ---- shapes: the reach bound, the staged short tile, and a single decoder row -------------
  {
    // The shapes the kernel actually issues after padding by rows: every one a whole number
    // of drain blocks.  The two that hang (25, 1) are kept above as the fault-4 isolation, so
    // this list is the POSITIVE half -- what the kernel does now, all of it expected exact.
    struct { int rows, K; const char *what; } sh[] = {
      { 28, 288, "a full tile, 1,008 of 1,024 words" },
      { 26, 288, "the last tile of 165 rows, padded 25 -> 26" },
      {  2, 288, "one decoder row, padded 1 -> 2" },
      {  4, 288, "a small even tile" },
      { 32, 256, "a different K, exact in blocks" },
    };
    for (auto &c : sh) {
      size_t bad = 0; uint64_t polls = 0; double ratio = 0;
      int rc = ln_case(S, c.rows, c.K, 1, EPS, &bad, &polls, 0, &ratio); n++;
      bool overbudget = ratio > LN_BUDGET_X;
      printf("  shape rows=%-3d %-40s rc=%-4d bad=%zu  %6.1fx ideal %s\n",
             c.rows, c.what, rc, bad, ratio,
             overbudget ? "OVER BUDGET" : "");
      if (rc != MBXR_OK || bad || overbudget) fails++;
    }
  }

  printf("%s %d lane cases, %d failing (fault 1, the hart mismatch, is NOT covered: no harts here)\n",
         fails ? "MBXR_LANES_FAIL" : "MBXR_LANES_OK", n, fails);
  return fails;
}

// ---- --waitsites: WHAT HART 1 IS WAITING ON, per site, on the encoder's own shapes -----------
// The board can only report one `cyc_wait`.  Here the same driver runs the same shapes against
// the same RTL and every poll is attributed.  Two knobs matter and both are set to the board:
//   * the fence poll COST.  On the board a custom-1 fence round trip is 52.5 cycles (B65:
//     cyc_wait/polls 53.7 flat, 52.5 strided).  In the bench a command costs 2 + (gap-1)/2
//     cycles, so cmd_gap_max = 101 is the board's hart 1 and the default 6 is a hart 1 that
//     reacts ~12x faster -- which BIASES AGAINST finding a flush cost, so both are run.
//   * L2-like Puts: bytes land with the AccessAck, acks far out of order, a 4 permille tail.
// dev.place_early = 1 on BOTH arms, because both board images are built -DMBXR_RT_PLACE_EARLY=1
// and the strided arm is where that flag becomes dead code.
// ---- THE 6-BIT WEIGHT GRID (B79) --------------------------------------------------------
//
// WHAT THIS CAN AND CANNOT PROVE, said plainly.  The int6 grid is fixed by the extractor
// (B77's --weight-bits 6) and lives one code per byte in [-31, 31].  A code in that range IS
// an ordinary int8 weight, so the reference here is kernel_linear_s8 over THE SAME CODES --
// a byte-identical reference, not one rebuilt from the changed path.  max_abs_err 0 is
// therefore a real check: it says the pack/unpack round trip and the engine's 4-beat/3-word
// schedule reproduce the arithmetic the host WER arm measured, byte for byte.  It says
// nothing about accuracy, which B75 and B77 measured and which this cannot see.
//
// EACH SHAPE RUNS TWICE, 8 bits and 6, and the pair is the measurement: bytes_wgt and
// fill_beats must MOVE (that is the whole lever) and cyc_tseq must NOT (the MAC does the
// same 36 beats either way).  A lever whose signature is the other way round is a different
// lever; B75 says so and four labs' worth of claw-back says so.
struct Int6Row { const int8_t *codes; int K, wbits; };
static void tb_row_fn_bits(void *ctx, int n, int8_t *dst) {
  const Int6Row *r = (const Int6Row *)ctx;
  const int8_t *src = r->codes + (size_t)n * r->K;
  if (r->wbits == 8) { for (int k = 0; k < r->K; k++) dst[k] = src[k]; return; }
  mbxr_pack6(src, r->K, (uint8_t *)dst);
}

struct Int6Res { uint64_t bytes_wgt, fill_beats, cyc_fill, cyc_tseq, steps, cycles; int maxerr; };

static int run_case_bits(Sim &S, mbxr_dev &dev, const Case &c, uint64_t seed, int wbits,
                         Int6Res *res) {
  std::mt19937_64 r(seed);
  const int K = c.K, N = c.N, npix = c.npix, as = c.astride;
  uint64_t in_bytes = (uint64_t)(npix - 1) * 8 * as + K;
  uint64_t in_pa = MEM_BASE + (16ULL << 20);
  // THE CODES ARE THE SAME AT BOTH GRIDS.  Both arms of a pair see the identical matrix, so a
  // difference between them is the mechanism and not the data.  [-31, 31] is what the
  // extractor's 6-bit grid emits; it is a legal int8 matrix as well.
  std::vector<int8_t> w((size_t)N * K);
  for (auto &x : w) x = (int8_t)((int)(r() % 63) - 31);
  std::vector<int32_t> bias(N);
  for (uint64_t i = 0; i < in_bytes; i++) *S.p(in_pa + i) = (uint8_t)(r() & 0xff);
  for (auto &b : bias) b = (int32_t)(r() % 200001) - 100000;

  mbxr_quant q;
  q.mult = (int32_t)((1u << 30) + (uint32_t)(r() % (1u << 30)));
  q.shift = (int)(r() % 20) + 2;
  q.amin = -128; q.amax = 127;

  // the bit order is a contract: check the round trip before trusting the image
  if (wbits == 6) {
    std::vector<uint8_t> packed((size_t)K * 6 / 8);
    std::vector<int8_t> back(K);
    for (int n = 0; n < N; n++) {
      mbxr_pack6(w.data() + (size_t)n * K, K, packed.data());
      mbxr_unpack6(packed.data(), K, back.data());
      for (int k = 0; k < K; k++)
        if (back[k] != w[(size_t)n * K + k]) {
          fprintf(stderr, "  %s: mbxr_pack6 round trip failed at row %d code %d\n",
                  c.name.c_str(), n, k);
          return 1;
        }
    }
  }

  mbxr_wimage img;
  if (!mbxr_wimage_plan_bits(&img, N, K, wbits, dev.drain_strided)) {
    fprintf(stderr, "%s: plan refused at %d bits\n", c.name.c_str(), wbits); return 1; }
  uint64_t img_pa = MEM_BASE + (32ULL << 20);
  { Int6Row rs = { w.data(), K, wbits };
    mbxr_wimage_build_fn(&dev, &img, img_pa, tb_row_fn_bits, &rs, bias.data()); }

  uint64_t scratch_pa = MEM_BASE + (64ULL << 20);
  const uint64_t GUARD = 4096;
  uint64_t out_pa = MEM_BASE + (80ULL << 20);
  int8_t *outp = (int8_t *)S.p(out_pa);
  for (uint64_t i = 0; i < GUARD; i++) {
    *S.p(out_pa - GUARD + i) = (uint8_t)(0x3C ^ (i * 17));
    *S.p(out_pa + (uint64_t)npix * N + i) = (uint8_t)(0xC3 ^ (i * 17));
  }
  for (size_t i = 0; i < (size_t)npix * N; i++) outp[i] = 0x55;
  uint64_t sbytes = (uint64_t)npix * (uint64_t)((N + 3) / 4) * 4 + 64;
  for (uint64_t i = 0; i < sbytes; i++) *S.p(scratch_pa + i) = (uint8_t)(0xA5 ^ (i * 131));

  std::vector<int8_t> gold((size_t)npix * N), win((size_t)npix * K);
  for (int pp = 0; pp < npix; pp++)
    for (int k = 0; k < K; k++) win[(size_t)pp * K + k] = (int8_t)*S.p(in_pa + (uint64_t)pp * 8 * as + k);
  kernel_linear_s8(win.data(), w.data(), bias.data(), gold.data(), npix, K, N, 0, 0, 0,
                   q.mult, q.shift, q.amin, q.amax);

  mbxr_stats st; memset(&st, 0, sizeof st);
  uint64_t c0 = S.cyc;
  int rc = mbxr_run_to(&dev, &img, in_pa, npix, as, &q, scratch_pa, outp, out_pa, &st);
  uint64_t cycles = S.cyc - c0;
  uint64_t steps = S.cmd(MBXR_STAT, MBXR_C_STEPS, 0, 1);
  uint64_t fillb = S.cmd(MBXR_STAT, MBXR_C_FILL_BEATS, 0, 1);
  uint64_t cfill = S.cmd(MBXR_STAT, MBXR_C_CYC_FILL, 0, 1);
  uint64_t ctseq = S.cmd(MBXR_STAT, MBXR_C_CYC_TSEQ, 0, 1);
  if (rc != MBXR_OK) { fprintf(stderr, "%s @%d bits: mbxr_run rc=%d\n", c.name.c_str(), wbits, rc); return 1; }

  size_t bad = 0; int maxerr = 0;
  for (uint64_t i = 0; i < GUARD; i++)
    if (*S.p(out_pa - GUARD + i) != (uint8_t)(0x3C ^ (i * 17)) ||
        *S.p(out_pa + (uint64_t)npix * N + i) != (uint8_t)(0xC3 ^ (i * 17))) {
      fprintf(stderr, "  %s @%d bits: the drain wrote OUTSIDE out[%d][%d]\n",
              c.name.c_str(), wbits, npix, N);
      bad++; break;
    }
  for (size_t i = 0; i < (size_t)npix * N; i++) {
    int e = abs((int)outp[i] - (int)gold[i]);
    if (e) { if (bad < 5) fprintf(stderr, "  %s @%d bits: out[%zu] = %d, reference %d\n",
                                  c.name.c_str(), wbits, i, outp[i], gold[i]); bad++; }
    if (e > maxerr) maxerr = e;
  }
  printf("  %-20s %d bits | K %5d Kw %5d G %4d Q %3d tiles %3d lgpw %2d | image %8llu B | "
         "bytes_wgt %9llu fill_beats %8llu cyc_fill %9llu cyc_tseq %9llu steps %8llu | "
         "cycles %9llu | max_abs_err %d%s\n",
         c.name.c_str(), wbits, img.K, img.Kw, img.G, img.Q, img.tiles, img.lgpw,
         (unsigned long long)img.bytes,
         (unsigned long long)st.bytes_wgt, (unsigned long long)fillb,
         (unsigned long long)cfill, (unsigned long long)ctseq, (unsigned long long)steps,
         (unsigned long long)cycles, maxerr, bad ? "  MISMATCH" : "");
  if (res) { res->bytes_wgt = st.bytes_wgt; res->fill_beats = fillb; res->cyc_fill = cfill;
             res->cyc_tseq = ctseq; res->steps = steps; res->cycles = cycles; res->maxerr = maxerr; }
  return bad ? 1 : 0;
}

static int int6_main(Sim &S) {
  mbxr_dev dev;
  dev.cmd = c_cmd; dev.p2v = c_p2v; dev.ctx = &S; dev.poll_limit = 50000000; dev.now = c_now;
  dev.place_chunk = 1; dev.place_early = 0; dev.drain_strided = 0; dev.lane_wait = 0;

  uint64_t id = S.cmd(MBXR_STAT, MBXR_C_ID, 0, 1);
  printf("MBXR engine id %016llx\n", (unsigned long long)id);

  // THE FOUR SHAPES ARE THE DECODER'S, plus one the packing has to get wrong if the bit order
  // is wrong.  K = 288 -> G 36/27, K = 1152 -> G 144/108: both exact at three words per four
  // beats, which is the arithmetic the engine assumes and refuses to check at run time.
  std::vector<Case> cs = {
    { "dec_288x288",    1, 288,  288, 36 },
    { "dec_288x1152",   1, 288, 1152, 36 },
    { "dec_1152x288",   1, 1152, 288, 144 },
    { "dec_lmhead",     1, 288,  512, 36 },
    { "dec_288x288_m8", 8, 288,  288, 36 },
    { "enc_windowed",   6, 288,  288, 40 },   // astride != G: a pixel stride the packing must not touch
  };
  int fails = 0, ncases = 0;
  bool tseq_moved = false, bytes_still = false;
  for (size_t i = 0; i < cs.size(); i++) {
    Int6Res r8, r6;
    fails += run_case_bits(S, dev, cs[i], 9000 + i, 8, &r8); ncases++;
    fails += run_case_bits(S, dev, cs[i], 9000 + i, 6, &r6); ncases++;
    // THE FALSIFIER, and it can fire.  This lever's signature is fill_beats MOVING; the
    // claw-back's is fill_beats unmoved.  If bytes_wgt does not move, the packing did not
    // reach the image; if cyc_tseq moves, the MAC is doing different work and the arithmetic
    // gate above is measuring something other than the same 36 beats.
    double bw = r8.bytes_wgt ? (double)r6.bytes_wgt / (double)r8.bytes_wgt : 1.0;
    double fb = r8.fill_beats ? (double)r6.fill_beats / (double)r8.fill_beats : 1.0;
    printf("    -> bytes_wgt x%.4f  fill_beats x%.4f  cyc_tseq %llu -> %llu  steps %llu -> %llu\n",
           bw, fb, (unsigned long long)r8.cyc_tseq, (unsigned long long)r6.cyc_tseq,
           (unsigned long long)r8.steps, (unsigned long long)r6.steps);
    if (r6.steps != r8.steps) { printf("       MAC STEP COUNT MOVED\n"); tseq_moved = true; }
    if (r6.bytes_wgt >= r8.bytes_wgt) { printf("       bytes_wgt DID NOT MOVE\n"); bytes_still = true; }
  }
  printf("TileLink: %llu Gets, %llu Puts, %d protocol errors, %llu cycles simulated\n",
         (unsigned long long)S.gets, (unsigned long long)S.puts, S.errors, (unsigned long long)S.cyc);
  if (fails == 0 && S.errors == 0 && !tseq_moved && !bytes_still) {
    printf("MBXR_INT6_OK %d arms, every output byte equal to kernel_linear_s8 over the same codes, "
           "bytes_wgt moved, the MAC step count did not\n", ncases);
    return 0;
  }
  printf("MBXR_INT6_FAIL %d of %d arms, %d protocol errors%s%s\n", fails, ncases, S.errors,
         tseq_moved ? ", MAC step count moved" : "", bytes_still ? ", bytes_wgt did not move" : "");
  return 1;
}

static int waitsites_main(Sim &S) {
  mbxr_dev dev;
  dev.cmd = c_cmd; dev.p2v = c_p2v; dev.ctx = &S; dev.poll_limit = 50000000; dev.now = c_now;
  dev.place_chunk = 1; dev.place_early = 1; dev.drain_strided = 0; dev.lane_wait = 0;
  std::vector<Case> cs = {
    { "enc q/k/v/o 165x288->288",  165,  288,  288,  36 },
    { "enc fc1     165x288->1152", 165,  288, 1152,  36 },
    { "enc fc2     165x1152->288", 165, 1152,  288, 144 },
    { "stem conv3  s2 IC576 KW3",  165, 1728,  288, 144 },
    { "stem conv1  s64 K127->128", 999,  128,  288,   8 },
  };
  static const uint64_t gaps[] = { 101, 6 };
  int fails = 0;
  for (int gi = 0; gi < 2; gi++) {
    S.cmd_gap_max = gaps[gi];
    printf("\n==== fence poll cost knob: cmd_gap_max %llu (board is 52.5 cyc/poll) ====\n",
           (unsigned long long)S.cmd_gap_max);
    for (int arm = 1; arm >= 0; arm--) {
      dev.drain_strided = arm;
      uint64_t tot_polls = 0, tot_cyc = 0, tot_steps = 0, tot_run = 0, tot_pairs = 0;
      uint64_t ap[WS_N], ac[WS_N], av[WS_N];
      for (int i = 0; i < WS_N; i++) { ap[i] = ac[i] = av[i] = 0; }
      printf("  -- %s drain --\n", arm ? "2-D (strided)" : "flat");
      for (size_t i = 0; i < cs.size(); i++) {
        S.commit_at_ack = true; S.tail_permille = 40; S.tail_max = 3000; S.put_ack_extra = 120;
        S.lat_max = 30; S.ready_pct = 80;
        ws_reset(); g_ws_on = 1;
        uint64_t c0 = S.cyc;
        int bad = run_case(S, dev, cs[i], 700 + i, false, 16);
        ws_close((unsigned)~0u);
        g_ws_on = 0;
        uint64_t run_cyc = S.cyc - c0;
        S.commit_at_ack = false; S.tail_permille = 0; S.tail_max = 0; S.put_ack_extra = 0;
        uint64_t steps = S.cmd(MBXR_STAT, MBXR_C_STEPS, 0, 1);
        uint64_t tsq = S.cmd(MBXR_STAT, MBXR_C_CYC_TSEQ, 0, 1);
        fails += bad;
        uint64_t ps = 0, cs_ = 0;
        for (int k = 0; k < WS_N; k++) { ps += g_ws_polls[k]; cs_ += g_ws_cyc[k];
                                         ap[k] += g_ws_polls[k]; ac[k] += g_ws_cyc[k]; av[k] += g_ws_visits[k]; }
        printf("    %-28s run %8llu cyc  tseq %8llu  steps %8llu | polls %7llu wait %8llu (%.1f cyc/poll) | max_abs_err %s\n",
               cs[i].name.c_str(), (unsigned long long)run_cyc, (unsigned long long)tsq,
               (unsigned long long)steps, (unsigned long long)ps, (unsigned long long)cs_,
               ps ? (double)cs_ / (double)ps : 0.0, bad ? "NONZERO" : "0");
        for (int k = 0; k < WS_N; k++)
          if (g_ws_polls[k])
            printf("        %-20s visits %6llu  polls %7llu  cycles %8llu  %5.1f%% of wait\n",
                   ws_name[k], (unsigned long long)g_ws_visits[k], (unsigned long long)g_ws_polls[k],
                   (unsigned long long)g_ws_cyc[k], cs_ ? 100.0 * (double)g_ws_cyc[k] / (double)cs_ : 0.0);
        tot_polls += ps; tot_cyc += cs_; tot_steps += steps; tot_run += run_cyc;
      }
      (void)tot_pairs;
      printf("    TOTAL %s: run %llu cyc, steps %llu, polls %llu, wait %llu\n",
             arm ? "strided" : "flat", (unsigned long long)tot_run, (unsigned long long)tot_steps,
             (unsigned long long)tot_polls, (unsigned long long)tot_cyc);
      for (int k = 0; k < WS_N; k++)
        if (ap[k])
          printf("      %-20s visits %7llu  polls %8llu  cycles %9llu  %5.1f%% of wait  %7.1f cyc/visit\n",
                 ws_name[k], (unsigned long long)av[k], (unsigned long long)ap[k],
                 (unsigned long long)ac[k], tot_cyc ? 100.0 * (double)ac[k] / (double)tot_cyc : 0.0,
                 av[k] ? (double)ac[k] / (double)av[k] : 0.0);
    }
  }
  S.cmd_gap_max = 6;
  printf("\nMBXR_WAITSITES_%s %d mismatched cases, %d protocol errors\n",
         (fails == 0 && S.errors == 0) ? "OK" : "FAIL", fails, S.errors);
  return (fails == 0 && S.errors == 0) ? 0 : 1;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Sim S;
  int random_cases = 60;
  bool big = true, lanes_only = false, waitsites_only = false, int6_only = false;
  const char *casedir = nullptr;
  int shard = 0, nshards = 1;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--quick")) { random_cases = 20; big = false; }
    if (!strncmp(argv[i], "--random=", 9)) random_cases = atoi(argv[i] + 9);
    if (!strncmp(argv[i], "--casedir=", 10)) casedir = argv[i] + 10;
    if (!strncmp(argv[i], "--shard=", 8)) sscanf(argv[i] + 8, "%d/%d", &shard, &nshards);
    if (!strcmp(argv[i], "--lanes")) lanes_only = true;
    if (!strcmp(argv[i], "--waitsites")) waitsites_only = true;
    if (!strcmp(argv[i], "--int6")) int6_only = true;
  }
  if (int6_only) {
    S.top->clk = 0; S.top->rst = 1; S.top->cmd_valid = 0;
    S.top->wd_valid = 0; S.top->ad_valid = 0; S.top->wa_ready = 0; S.top->aa_ready = 0;
    for (int i = 0; i < 8; i++) S.tick();
    S.top->rst = 0;
    for (int i = 0; i < 8; i++) S.tick();
    return int6_main(S);
  }
  if (lanes_only) {
    S.top->clk = 0; S.top->rst = 1; S.top->cmd_valid = 0;
    for (int i = 0; i < 8; i++) S.tick();
    S.top->rst = 0;
    for (int i = 0; i < 8; i++) S.tick();
    return lanes_main(S) ? 1 : 0;
  }
  if (waitsites_only) {
    S.top->clk = 0; S.top->rst = 1; S.top->cmd_valid = 0;
    for (int i = 0; i < 8; i++) S.tick();
    S.top->rst = 0;
    for (int i = 0; i < 8; i++) S.tick();
    return waitsites_main(S);
  }
#ifdef MBXR_TB_2CLK
  S.W.clk_ctr = &S.wcyc;
  for (int i = 1; i < argc; i++)
    if (!strncmp(argv[i], "--periods=", 10)) sscanf(argv[i] + 10, "%llu:%llu",
        (unsigned long long *)&S.tc_period, (unsigned long long *)&S.tw_period);
  S.tw_next = S.tw_period / 2 + 1;
  S.top->wclk = 0; S.top->wrst = 1; S.top->w_quiet = 1;
  printf("two clocks: engine period %llu, weight lane period %llu\n",
         (unsigned long long)S.tc_period, (unsigned long long)S.tw_period);
#endif
  S.top->clk = 0; S.top->rst = 1; S.top->cmd_valid = 0;
  S.top->wd_valid = 0; S.top->ad_valid = 0; S.top->wa_ready = 0; S.top->aa_ready = 0;
  for (int i = 0; i < 5; i++) S.tick();
  S.top->rst = 0;
#ifdef MBXR_TB_2CLK
  S.top->wrst = 0;
#endif
  for (int i = 0; i < 3; i++) S.tick();

  mbxr_dev dev;
  dev.cmd = c_cmd; dev.p2v = c_p2v; dev.ctx = &S; dev.poll_limit = 50000000; dev.now = c_now;
  dev.place_chunk = 0;
  dev.place_early = 0;
  dev.drain_strided = 0;
  dev.lane_wait = 0;

  if (casedir) {
    // file cases only: every *.bin in the directory, sorted, this shard's share
    std::vector<std::string> files;
    std::string cmdl = std::string("ls -1 ") + casedir + "/*.bin 2>/dev/null | sort";
    FILE *ls = popen(cmdl.c_str(), "r");
    char line[4096];
    while (ls && fgets(line, sizeof line, ls)) { line[strcspn(line, "\n")] = 0; files.push_back(line); }
    if (ls) pclose(ls);
    dev.place_chunk = 1;                  /* as mbxr_rt.h runs it */
    int fails = 0, n = 0;
    uint64_t cyc_total = 0;
    for (size_t i = 0; i < files.size(); i++) {
      if ((int)(i % nshards) != shard) continue;
      uint64_t c = 0;
      fails += run_file_case(S, dev, files[i].c_str(), &c);
      cyc_total += c; n++;
    }
    printf("TileLink: %llu Gets, %llu Puts, %d protocol errors, %llu cycles simulated\n",
           (unsigned long long)S.gets, (unsigned long long)S.puts, S.errors, (unsigned long long)S.cyc);
    if (fails == 0 && S.errors == 0 && n > 0) {
      printf("MBXR_CASES_OK %d cases (shard %d/%d), every output byte equal to the integer golden, %llu engine cycles\n",
             n, shard, nshards, (unsigned long long)cyc_total);
      return 0;
    }
    printf("MBXR_CASES_FAIL %d of %d cases, %d protocol errors\n", fails, n, S.errors);
    return 1;
  }

  uint64_t id = S.cmd(MBXR_STAT, MBXR_C_ID, 0, 1);
  printf("MBXR engine id %016llx (NCH %llu LDEPTH %llu SDEPTH %llu) drain %s\n", (unsigned long long)id,
         (unsigned long long)(id >> 32), (unsigned long long)((id >> 24) & 0xff),
         (unsigned long long)((id >> 16) & 0xff),
         MBXR_ID_SIG(id) == MBXR_ID_STRIDE ? "2-D (MS)" :
         (MBXR_ID_SIG(id) == MBXR_ID_FLAT ? "flat (MR)" : "UNKNOWN"));
#ifdef MBXR_TB_FLAT_ENGINE
  // compat/: this build is DELIBERATELY pointed at the pre-002E engine, which says 'MR'.
  if (MBXR_ID_SIG(id) != MBXR_ID_FLAT) { fprintf(stderr, "compat build: engine id is not 'MR'\n"); return 1; }
#else
  if (MBXR_ID_SIG(id) != MBXR_ID_STRIDE) { fprintf(stderr, "engine id is not 'MS'\n"); return 1; }
#endif
  // THE WIDTH CONTRACT, IN THE BENCH, BEFORE ANY DISPATCH.  mbxr.c lays out NCH weight planes
  // and sizes every drain row at qt*NCH bytes; the engine addresses MBXR_ID_NCH(id) planes.
  // Disagree and the store never reaches terminal -- MBXR_E_TIMEOUT with no error bit, which
  // is a 20-million-poll hang on a board and an unbounded simulation here.  0x5A5A0033 spent a
  // whole board session proving that (0 of 4,125 dispatches).  Fail in a second instead.
  if (MBXR_ID_NCH(id) != (uint32_t)MBXR_NCH) {
    fprintf(stderr, "MBXR_TB_WIDTH_MISMATCH: the engine says NCH = %u, this driver was built "
            "MBXR_NCH = %d.  The weight planes, the `sd` nrows and the drain's row_bytes are "
            "all laid out for %d; rebuild with -DMBXR_NCH=%u.\n",
            MBXR_ID_NCH(id), MBXR_NCH, MBXR_NCH, MBXR_ID_NCH(id));
    return 1;
  }

  int fails = 0, ncases = 0;

  // ---- the identity dispatch FIRST, so part 1 of the bar is checked before anything else ------
  // ROCC_DECOUPLED.md 8.15.9 sets the bar this bench has to clear; score it with
  // moonshine/score_identity.py, which grades this output and the two boards' with one scorer.
  {
    S.lat_max = 30; S.ready_pct = 80;
    dev.place_early = 0; dev.place_chunk = 1;
    for (auto kn : { std::pair<int,int>{ 288, 288 }, { 32, 288 }, { 8, 288 } })
      fails += run_identity(S, dev, kn.first, kn.second);
  }

  std::mt19937_64 r(7);
  // ---- random shapes: the corners of the tile planner ---------------------------------
  for (int i = 0; i < random_cases; i++) {
    Case c;
    int G = 1 + (int)(r() % 64);
    if (r() % 5 == 0) G = 1 + (int)(r() % 300);
    c.K = 8 * G;
    c.N = 1 + (int)(r() % 70);
    bool conv = (r() % 3) == 0;
    c.astride = conv ? 1 + (int)(r() % G) : G;
    c.npix = 1 + (int)(r() % (conv ? 90 : 60));
    c.name = std::string(conv ? "rand-conv-" : "rand-linear-") + std::to_string(i);
    S.lat_max = 1 + (int)(r() % 60);
    S.ready_pct = 40 + (int)(r() % 61);
    dev.place_chunk = i & 1;            /* both placement paths, alternately */
    fails += run_case(S, dev, c, 1000 + i, false, 8 * (r() % 8));
    ncases++;
  }
  printf("random: %d cases, %d failed\n", ncases, fails);

  // ---- Moonshine Tiny's encoder shapes, and a decode-step shape ------------------------
  S.lat_max = 30; S.ready_pct = 80;
  dev.place_chunk = 1;                  /* as mbxr_rt.h runs it */
  std::vector<Case> real = {
    { "enc q/k/v/o  165x288->288",  165,  288,  288,  36 },
    { "enc fc1      165x288->1152", 165,  288, 1152,  36 },
    { "enc fc2      165x1152->288", 165, 1152,  288, 144 },
    { "stem conv3   s2 IC576 KW3",  165, 1728,  288, 144 },
    { "stem conv1   s64 K127->128", 999,  128,  288,   8 },
    { "dec o_proj   1x288->288",      1,  288,  288,  36 },
    { "dec fc1      1x288->2304",     1,  288, 2304,  36 },
  };
  if (big) {
    real.push_back({ "stem conv2   s3 IC288 KW7", 331, 2016, 576, 108 });
    real.push_back({ "dec lm_head/8 1x288->4096",   1,  288, 4096,  36 });
  }
  for (size_t i = 0; i < real.size(); i++) {
    fails += run_case(S, dev, real[i], 500 + i, true, 16);
    ncases++;
  }
  // ---- the drain under pressure: short reductions produce bytes faster than slow acks
  // return, so both Put source IDs are in flight at once and the drain must stall at two.
  // Without this case no two Puts ever overlap (0.1 B/cycle of output at K = 288), and a
  // drain that reused one source ID passed every other test.
  S.put_ack_extra = 400;
  dev.place_chunk = 0;
  for (int i = 0; i < 3; i++) {
    Case c = { "drain-stress K8 N64 x" + std::to_string(i), 600, 8, 64, 1 };
    fails += run_case(S, dev, c, 900 + i, true, 0);
    ncases++;
  }
  S.put_ack_extra = 0;
  // ---- windows shorter than the stride: the geometry Lab B25 run 7 dispatched by accident
  // (stem_conv2 and stem_conv3 given stem_conv1's cached image, K = 128), which is a legal
  // dispatch in its own right -- the engine must finish it and match the reference.
  S.lat_max = 30; S.ready_pct = 80;
  dev.place_chunk = 1;
  {
    std::vector<Case> gap = {
      { "gap K128 N288 as108 x331", 331, 128, 288, 108 },
      { "gap K128 N288 as144 x165", 165, 128, 288, 144 },
    };
    for (size_t i = 0; i < gap.size(); i++) {
      fails += run_case(S, dev, gap[i], 950 + i, true, 16);
      ncases++;
    }
  }
  // ---- THE STRIDED DRAIN: the engine writes out[npix][N] itself ------------------------
  // What is being checked, and each of these is a way the change could be wrong:
  //   * every output byte still equals kernel_linear_s8's, with the SAME shapes the flat arm
  //     runs, so a Q rounded down to even has not changed the answer;
  //   * NOTHING outside out[npix][N] is written -- the guard band in run_case.  This is the
  //     asymmetry against the fill: mbxd_dma may over-FETCH the slop at the end of a row, a
  //     drain may not over-WRITE it;
  //   * THE UNALIGNED TAIL.  A row of qt*NCH bytes at column t*Q*NCH of an N-byte row starts
  //     and ends wherever it likes inside a 64-byte block, and its alignment CHANGES from row
  //     to row when N is not a multiple of 64 (N = 288 gives 0, 32, 0, 32, ...).  The shapes
  //     below are chosen so that every one of the four transaction sizes is issued and so that
  //     rows begin at every 8-byte offset of a block;
  //   * the flat arm is unchanged: it is the same descriptor with one block per row.
  {
    int sfails = 0, scases = 0;
    uint64_t p0 = S.puts, b0 = S.put_beats_total;
    S.lat_max = 30; S.ready_pct = 80;
    dev.place_early = 0; dev.place_chunk = 1;
#ifdef MBXR_TB_FLAT_ENGINE
    // THE POINT OF THIS BUILD is that the FLAT arm is unchanged on old silicon; the strided arm
    // has no engine to run on here, so it is skipped and the flat sweep is what is scored.
    dev.drain_strided = 0;
#else
    dev.drain_strided = 1;
#endif
    std::vector<Case> sc = {
      { "S enc q/k/v/o 165x288->288",  165,  288,  288,  36 },   // tiles_w 3, rows 104/104/80 B
      { "S enc fc1     165x288->1152", 165,  288, 1152,  36 },   // N a multiple of 64
      { "S enc fc2     165x1152->288", 165, 1152,  288, 144 },   // Q 7 -> 6, rows 24 B
      { "S stem conv1  s64 K127->128", 999,  128,  288,   8 },
      { "S stem conv3  s2 IC576 KW3",  165, 1728,  288, 144 },
      { "S dec o_proj  1x288->288",      1,  288,  288,  36 },   // one row per descriptor
      { "S dec fc1     1x288->2304",     1,  288, 2304,  36 },
      // the unaligned tail, deliberately: N mod 64 = 8, 16, 24, 40, 56 and one odd-ish quad count
      { "S tail N8     7x8->8",          7,    8,    8,   1 },
      { "S tail N24    5x16->24",        5,   16,   24,   2 },
      { "S tail N40    9x24->40",        9,   24,   40,   3 },
      { "S tail N56    33x8->56",       33,    8,   56,   1 },
      { "S tail N72    17x64->72",      17,   64,   72,   8 },
      { "S tail N1000  13x8->1000",     13,    8, 1000,   1 },
      { "S tail N136   64x8->136",      64,    8,  136,   1 },
      // a conv geometry, and a many-tile case where the last tile's quad count is the short one
      { "S conv N288   as108 x331",    331,  128,  288, 108 },
      { "S many-tile   3x2048->2048",    3, 2048, 2048, 256 },
    };
    uint64_t p0s = S.puts, b0s = S.put_beats_total;
    for (size_t i = 0; i < sc.size(); i++) {
      sfails += run_case(S, dev, sc[i], 700 + i, true, 16);
      scases++;
    }
    uint64_t p_same = S.puts, b_same = S.put_beats_total;
    // the drain under pressure, strided: short rows, slow acks, both source IDs busy
    S.put_ack_extra = 400;
    for (int i = 0; i < 3; i++) {
      Case c = { "S drain-stress K8 N64 x" + std::to_string(i), 600, 8, 64, 1 };
      sfails += run_case(S, dev, c, 800 + i, true, 0);
      scases++;
    }
    S.put_ack_extra = 0;
    // L2-like Puts: the bytes land with the AccessAck, acks far out of order, a heavy tail.
    S.commit_at_ack = true; S.tail_permille = 40; S.tail_max = 3000; S.put_ack_extra = 120;
    for (size_t i = 0; i < 4; i++) { sfails += run_case(S, dev, sc[i], 850 + i, true, 16); scases++; }
    S.commit_at_ack = false; S.tail_permille = 0; S.tail_max = 0; S.put_ack_extra = 0;
    // AND THE SAME SHAPES ON THE FLAT ARM, in the same process: the answers must agree byte for
    // byte with the reference on both, which is what makes this an A/B and not two experiments.
    dev.drain_strided = 0;
    uint64_t p1 = S.puts, b1 = S.put_beats_total;
    for (size_t i = 0; i < sc.size(); i++) { sfails += run_case(S, dev, sc[i], 700 + i, false, 16); scases++; }
    printf("strided drain: %d cases, %d failed | THE SAME %zu SHAPES, strided %llu Puts %llu beats "
           "vs flat %llu Puts %llu beats\n",
           scases, sfails, sc.size(), (unsigned long long)(p_same - p0s), (unsigned long long)(b_same - b0s),
           (unsigned long long)(S.puts - p1), (unsigned long long)(S.put_beats_total - b1));
    (void)p0; (void)b0;
    fails += sfails; ncases += scases;
    dev.place_chunk = 1;
  }

  // ---- incremental placement: the same kinds of dispatch with results placed while the
  // engine computes, both placement paths, Puts committed 0..3 blocks' worth of beats late,
  // and the drain under pressure.
  {
    int early_fails = 0, early_cases = 0;
    std::mt19937_64 re(99);
    std::vector<Case> ec = {
      { "early enc q/k/v/o 165x288->288",  165,  288,  288,  36 },
      { "early enc fc1   165x288->1152",   165,  288, 1152,  36 },
      { "early enc fc2   165x1152->288",   165, 1152,  288, 144 },
      { "early conv3     s2 IC576 KW3",    165, 1728,  288, 144 },
      { "early conv1     s64 K127->128",   999,  128,  288,   8 },
      { "early dec fc1   1x288->2304",       1,  288, 2304,  36 },
    };
    static const uint64_t delays[] = { 0, 1, 8, 16, 24 };
    for (size_t i = 0; i < ec.size(); i++) {
      dev.place_early = 1;
      dev.place_chunk = (int)(i & 1);
      S.put_commit_delay = delays[i % 5];
      S.lat_max = 1 + (int)(re() % 60); S.ready_pct = 40 + (int)(re() % 61);
      early_fails += run_case(S, dev, ec[i], 700 + i, true, 16);
      early_cases++;
    }
    for (int i = 0; i < random_cases; i++) {
      Case c;
      int G = 1 + (int)(re() % 64);
      if (re() % 5 == 0) G = 1 + (int)(re() % 300);
      c.K = 8 * G;
      c.N = 1 + (int)(re() % 70);
      bool conv = (re() % 3) == 0;
      c.astride = conv ? 1 + (int)(re() % G) : G;
      c.npix = 1 + (int)(re() % (conv ? 90 : 60));
      c.name = std::string(conv ? "early-rand-conv-" : "early-rand-linear-") + std::to_string(i);
      S.lat_max = 1 + (int)(re() % 60);
      S.ready_pct = 40 + (int)(re() % 61);
      S.put_commit_delay = delays[re() % 5];
      dev.place_early = 1;
      dev.place_chunk = i & 1;
      early_fails += run_case(S, dev, c, 3000 + i, false, 8 * (re() % 8));
      early_cases++;
    }
    S.put_ack_extra = 400;
    for (int i = 0; i < 2; i++) {
      Case c = { "early drain-stress K8 N64 x" + std::to_string(i), 600, 8, 64, 1 };
      S.put_commit_delay = delays[3 + i];
      dev.place_early = 1; dev.place_chunk = i;
      early_fails += run_case(S, dev, c, 980 + i, true, 0);
      early_cases++;
    }
    S.put_ack_extra = 0; S.put_commit_delay = 0;
    printf("incremental placement: %d cases, %d failed, %llu bytes placed while the engine ran\n",
           early_cases, early_fails, (unsigned long long)S.early_bytes);
    // ---- L2-like Put latency: bytes land with the ack, 3 % of acks wait up to 10,000 cycles.
    // Reported separately: a driver that gates placement on elapsed time must FAIL here.
    {
      int lf = 0, lc = 0;
      S.commit_at_ack = true; S.tail_permille = 30; S.tail_max = 10000;
      S.lat_max = 30; S.ready_pct = 80;
      std::vector<Case> lc_cases = {
        { "L2-tail enc q/k/v/o 165x288->288", 165,  288,  288,  36 },
        { "L2-tail enc fc1  165x288->1152",   165,  288, 1152,  36 },
        { "L2-tail enc fc2  165x1152->288",   165, 1152,  288, 144 },
        { "L2-tail conv1    s64 K127->128",   999,  128,  288,   8 },
        { "L2-tail K8 N64 x600",              600,    8,   64,   1 },
      };
      for (size_t i = 0; i < lc_cases.size(); i++) {
        for (int e = 0; e < 2; e++) {
          dev.place_early = e; dev.place_chunk = 1;
          Case c = lc_cases[i]; c.name += e ? " early" : " late";
          int f = run_case(S, dev, c, 1200 + i, true, 16);
          if (e) { lf += f; lc++; } else { fails += f; ncases++; }
        }
      }
      S.commit_at_ack = false; S.tail_permille = 0; S.tail_max = 0;
      printf("L2-like latency, incremental placement: %d cases, %d failed\n", lc, lf);
      early_fails += lf; early_cases += lc;
    }
    dev.place_early = 0;
    fails += early_fails;
    ncases += early_cases;
  }
#ifdef MBXR_TB_REV2
  // ---- revision 2: the engine refuses and flags protocol violations ----------------------
  {
    int pv_fails = 0;
    S.lat_max = 30; S.ready_pct = 80;
    dev.place_early = 0; dev.place_chunk = 1;
    const Case pc = { "violation enc q/k/v/o 165x288->288", 165, 288, 288, 36 };
    for (int m = 1; m <= 3; m++) {
      g_inject = m; g_injected = 0;
      mbxr_dev d2 = dev; d2.poll_limit = 2000000;
      int f = run_case(S, d2, pc, 4000 + m, false, 16);     // expected: rc != OK
      uint64_t s = S.cmd(MBXR_FENCE, 0, 0, 1);
      bool flagged = (f == 1) && g_injected && ((s >> 47) & 1);
      printf("  protocol violation %d: injected %d, run refused with the error bit %s (fence %016llx)\n",
             m, g_injected, flagged ? "SET" : "NOT SET", (unsigned long long)s);
      if (!flagged) pv_fails++;
      g_inject = 0;
      for (int k = 0; k < 200000 && (S.cmd(MBXR_FENCE, 0, 0, 1) & MBXR_S_BUSY); k++) {}
      int g = run_case(S, dev, pc, 4100 + m, false, 16);    // mbxr_run clears the sticky error
      printf("  protocol violation %d: the next dispatch %s\n", m, g ? "FAILED" : "is exact");
      pv_fails += g;
      ncases += 2;
    }
    printf("protocol violations: %d of 3 not flagged or not recovered\n", pv_fails);
    fails += pv_fails;
  }
#endif

  // ---- the outstanding cap (command 8) is honoured, and reaches what it asks for ------------
  // Lab B25's port sweep reads 6.300 B/cycle at cap 3 and 7.342 at cap 4 on 0x5A5A0028, and the
  // driver now asks for 4 (MBXR_RT_CAP).  Nothing checked that the RTL obeys the field, so a
  // revision that dropped it would look like a slow port and nothing else.  Here every cycle of a
  // real dispatch is sampled: the fill may never exceed the cap, and with a load this size it must
  // reach it.  cap 0 means 1 (mbxr_engine.v: `l_cap <= rs2 ? rs2 : 1`).
  {
    int cap_fails = 0;
    S.lat_max = 30; S.ready_pct = 80;
    dev.place_early = 0; dev.place_chunk = 1;
    const Case cc = { "cap enc fc1 165x288->1152", 165, 288, 1152, 36 };
    for (int k = 1; k <= 4; k++) {
      S.cmd(MBXR_CAP, 0, (uint64_t)k, 0);
      S.max_live_w = S.max_live_a = 0;
      int g = run_case(S, dev, cc, 6000 + k, false, 16);
      bool over = (S.max_live_w > k) || (S.max_live_a > k);
      bool reached = (S.max_live_w == k) && (S.max_live_a == k);
      printf("  cap %d: max in flight W %d, A %d -> %s%s%s\n", k, S.max_live_w, S.max_live_a,
             g ? "DISPATCH FAILED " : "exact", over ? ", OVER THE CAP" : "",
             reached ? "" : ", never reached the cap");
      cap_fails += g + (over ? 1 : 0) + (reached ? 0 : 1);
      ncases++;
    }
    S.cmd(MBXR_CAP, 0, 3, 0);                  // back to the reset default for what follows
    S.max_live_w = S.max_live_a = 0;
    printf("outstanding cap: %d failures over caps 1..4\n", cap_fails);
    fails += cap_fails;
  }
#if defined(MBXR_TB_REV2) && defined(MBXR_TB_2CLK)
  // ---- revision 2b: a short reset with weight Gets outstanding, and the weight window --------
  {
    int rb_fails = 0;
    S.lat_max = 60; S.ready_pct = 70;
    dev.place_early = 0; dev.place_chunk = 1;
    const Case pc = { "after-reset enc q/k/v/o 165x288->288", 165, 288, 288, 36 };
    std::mt19937_64 rr(77);
    // a weight image to load: N = K = 288
    std::vector<int8_t> w(288 * 288);
    std::vector<int32_t> bias(288, 0);
    for (auto &x : w) x = (int8_t)rr();
    mbxr_wimage img;
    mbxr_wimage_plan(&img, 288, 288);
    uint64_t img_pa = MEM_BASE + (32ULL << 20), plane = 8ULL << img.lgpw;
    { RowSrc rs = { w.data(), K }; mbxr_wimage_build_fn(&dev, &img, img_pa, tb_row_fn, &rs, bias.data()); }
    for (int trial = 0; trial < 8; trial++) {
      int errs0 = S.errors;
      S.cmd(MBXR_STAT, 0, 1, 1);
      S.cmd(MBXR_SD, img_pa, (plane << 32) | (4ULL << 16) | (plane / 64), 0);
      S.cmd(MBXR_LD, (1ULL << 17) | ((uint64_t)img.lgpw << 8), 0, 0);
      int outstanding = 0;
      for (int k = 0; k < 4000 && outstanding < 3; k++) {
        S.tick();
        outstanding = 0;
        for (auto &x : S.W.t) outstanding += x.live;
      }
      // reset for at most 56 lane cycles; the slave keeps answering (RREADY stays high)
      uint64_t lane_cycles = 1 + rr() % 56, w0 = S.wcyc;
      S.top->rst = 1; S.top->wrst = 1;
      while (S.wcyc - w0 < lane_cycles) S.tick();
      S.top->rst = 0; S.top->wrst = 0;
      int g = run_case(S, dev, pc, 5000 + trial, false, 16);
      bool ok = (g == 0) && (S.errors == errs0);
      printf("  short reset %d: %d Gets outstanding, reset %2llu lane cycles -> next dispatch %s, protocol errors %d\n",
             trial, outstanding, (unsigned long long)lane_cycles, g ? "FAILED" : "exact", S.errors - errs0);
      if (!ok) rb_fails++;
      ncases++;
    }
    // the weight window: a descriptor wholly outside, and one that runs off its end
    const struct { const char *name; uint64_t base; } oob[] = {
      { "wholly outside", MEM_BASE + MEM_SIZE },
      { "runs off the end", MEM_BASE + MEM_SIZE - 128 },
    };
    for (auto &o : oob) {
      int errs0 = S.errors;
      S.cmd(MBXR_STAT, 0, 1, 1);
      S.cmd(MBXR_SD, o.base, (plane << 32) | (4ULL << 16) | (plane / 64), 0);
      S.cmd(MBXR_LD, (1ULL << 17) | ((uint64_t)img.lgpw << 8), 0, 0);
      uint64_t s = 0;
      for (int k = 0; k < 200000; k++) { s = S.cmd(MBXR_FENCE, 0, 0, 1); if (!(s & MBXR_S_FILL)) break; }
      bool flagged = (s >> 47) & 1, no_fill = !(s & MBXR_S_FILL), clean = (S.errors == errs0);
      int g = run_case(S, dev, pc, 5100, false, 16);
      printf("  window, descriptor %s: error bit %s, fill %s, Gets outside the window %s -> next dispatch %s\n",
             o.name, flagged ? "SET" : "NOT SET", no_fill ? "finished" : "HUNG",
             clean ? "none" : "ISSUED", g ? "FAILED" : "exact");
      if (!(flagged && no_fill && clean && g == 0)) rb_fails++;
      ncases += 2;
    }
    // a stray response on an ID past DEPTH, aliasing a busy source: dropped, never written
    {
      int errs0 = S.errors;
      S.alias_inject = 64; S.alias_injected = 0;
      int g = run_case(S, dev, pc, 5200, false, 16);
      int injected = S.alias_injected;
      S.alias_inject = 0;
      printf("  stray W responses on ID + 4 while that ID is busy: %d injected -> dispatch %s, protocol errors %d\n",
             injected, g ? "FAILED" : "exact", S.errors - errs0);
      if (g || injected == 0 || S.errors != errs0) rb_fails++;
      ncases++;
    }
    // the W lane's ready bit: a lane held in reset past the SoC's, and a W port that never goes quiet
    {
      mbxr_dev dl = dev; dl.lane_wait = 100000;
      int errs0 = S.errors;
      // (a) held: SoC and lane reset together, the SoC released, the lane held 3,000 lane cycles more
      S.top->rst = 1; S.top->wrst = 1;
      for (int k = 0; k < 20; k++) S.tick();
      S.top->rst = 0;
      // the lane comes out of reset 3,000 lane cycles later, while the driver is already waiting
      S.wrst_release_at = S.wcyc + 3000;
      uint64_t fence_held = S.cmd(MBXR_FENCE, 0, 0, 1);
      int g1 = run_case(S, dl, pc, 5300, false, 16);
      printf("  lane held in reset 3,000 lane cycles past the SoC's: fence bit 41 while held %d -> dispatch after release %s\n",
             (int)((fence_held >> 41) & 1), g1 ? "FAILED" : "exact");
      if (g1 || ((fence_held >> 41) & 1)) rb_fails++;
      // (b) never quiet: the driver must give up with MBXR_E_LANE and leave the engine idle
      S.force_not_quiet = true;
      for (int k = 0; k < 50; k++) S.tick();
      mbxr_dev dn = dev; dn.lane_wait = 2000;
      g_expect_rc = MBXR_E_LANE;
      int g2 = run_case(S, dn, pc, 5301, false, 16);
      g_expect_rc = 0;
      uint64_t fence_after = S.cmd(MBXR_FENCE, 0, 0, 1);
      S.force_not_quiet = false;
      for (int k = 0; k < 50; k++) S.tick();
      int g3 = run_case(S, dl, pc, 5302, false, 16);
      printf("  W port never quiet: mbxr_run %s MBXR_E_LANE, engine %s -> next dispatch once quiet %s, protocol errors %d\n",
             g2 ? "did NOT return" : "returned", (fence_after & MBXR_S_BUSY) ? "BUSY" : "idle", g3 ? "FAILED" : "exact",
             S.errors - errs0);
      if (g2 || (fence_after & MBXR_S_BUSY) || g3 || S.errors != errs0) rb_fails++;
      ncases += 3;
    }
    printf("revision 2b reset and window cases: %d failed\n", rb_fails);
    fails += rb_fails;
  }
#endif
  printf("TileLink: %llu Gets, %llu Puts, %d protocol errors, %llu cycles simulated\n",
         (unsigned long long)S.gets, (unsigned long long)S.puts, S.errors, (unsigned long long)S.cyc);
  if (fails == 0 && S.errors == 0) {
    printf("MBXR_TB_OK %d cases, every output byte equal to kernel_linear_s8, 0 protocol errors\n", ncases);
    return 0;
  }
  printf("MBXR_TB_FAIL %d of %d cases, %d protocol errors\n", fails, ncases, S.errors);
  return 1;
}
