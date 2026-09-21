// SIMULATION ONLY.  THE FINAL W-LANE GATE (MEMORY_BANDWIDTH.md s9.9): the GENERATED revision-2b design of
// PynqZ2RocketBigLittlePextTacitMicRgbRoccMoon2bCheckConfig -- RoccMoonEngine2b (mbxr_engine_core) on the engine clock,
// wlaneClockSinkDomain (RoccMoonWHalf -> TLBuffer -> TLToAXI4 -> AXI4IdIndexer -> AXI4UserYanker) on the lane clock,
// mbxr_wquiet on the lane's AXI4 pins -- with the rev2 Verilog from 433898d, against an AXI4 memory standing in for
// S_AXI_HP2 (RVALID held while RREADY is low).
//
// THE WEIGHT HALF GETS REAL DESCRIPTORS: the bench drives mbxr_engine_core's RoCC command ports one cycle per
// instruction, as RoccMoonShim does for hart 1 -- cap, sd, ld (weights, client W), fence, stat -- and reads FILL (bit 0)
// and the sticky error (bit 47) from the fence.  Every weight word the weight half writes is checked at the weight
// banks' write port (ww_en/ww_word/ww_data, the BundleBridge into the core) against the memory's word for that flat
// index and plane: every expected word exactly once, the right data, nothing else.
//
// Checked every lane cycle in every test: every AR is ARLEN 7 / ARSIZE 3 / INCR, 64-byte aligned, inside
// [0x8000_0000, 0x9000_0000); AWVALID and WVALID never assert; client A never issues (weight loads only); and
// mbxr_wquiet's quiet equals the pins' balance (ARs == RLASTs) -- the drain claim is exact.
//
//   Vtop [--lat L] [--p0 ps] [--p1 ps] [--blocks N] [--caps 1,2,3,4] [--reset-cycles N] [--abort-after GETS]
//        [--rdrop] [--rfirst] [--noquiet] [--noresethold] [--nohold] [--stuck-watchdog N] [--ready-bit]
//        sweep | abort | window | stuck
#include "Vwlanetb2b_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>

static Vwlanetb2b_top *top;
static uint64_t H0 = 14500, H1 = 5000;   // half periods (ps): engine 1000/29 MHz, lane 100 MHz
static uint64_t next0, next1;
static bool c0 = false, c1 = false;
static uint64_t cyc0 = 0, cyc1 = 0;
static const uint64_t WIN_BASE = 0x80000000ULL, WIN_END = 0x90000000ULL;
static const int NCH = 4;

static uint64_t word_at(uint64_t addr) {
  uint64_t x = addr * 0x9E3779B97F4A7C15ULL;
  x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ULL; x ^= x >> 32;
  return x;
}

// ---- the AXI4 memory (S_AXI_HP2 stand-in), lane clock ------------------------------------------------------------
struct RB { uint8_t id; uint64_t addr; unsigned beats; uint64_t ready_at; };
struct Mem {
  unsigned lat = 20, cap = 8, jitter = 0;
  std::deque<RB> pend; bool act = false; RB cur{}; unsigned beat = 0;
  uint64_t ar = 0, rlast = 0, rbeats = 0, aw_valid_cycles = 0, w_valid_cycles = 0, contract_bad = 0;
  uint64_t stall_run = 0, stall_max = 0, stall_cycles = 0;
  uint64_t arlen[256] = {0};
  unsigned out_r() const { return pend.size() + (act ? 1 : 0); }
};
static Mem mem;
// --jitter: per-burst extra latency, so bursts with different IDs can complete OUT OF ORDER,
// which a real HP port may do and this bench did not until 2026-09-17 (MEMORY_BANDWIDTH.md 9.14).
static uint64_t g_jit_state = 0x243F6A8885A308D3ULL;
static uint64_t protocol_errors = 0, quiet_violations = 0, a_valid_cycles = 0, lane_rst_violations = 0;
static bool prev_lane_rst = true;
static void perr(const char *msg, uint64_t a = 0) {
  if (protocol_errors < 12) fprintf(stderr, "PROTOCOL: %s 0x%llx (cyc1=%llu)\n", msg, (unsigned long long)a, (unsigned long long)cyc1);
  protocol_errors++;
}
static void mem_drive() {
  top->axi_ar_ready = mem.out_r() < mem.cap;
  top->axi_aw_ready = 1; top->axi_w_ready = 1; top->axi_b_valid = 0; top->axi_b_bits_id = 0; top->axi_b_bits_resp = 0;
  if (!mem.act) {
    for (size_t i = 0; i < mem.pend.size(); i++)
      if (mem.pend[i].ready_at <= cyc1) { mem.cur = mem.pend[i]; mem.pend.erase(mem.pend.begin() + i); mem.act = true; mem.beat = 0; break; }
  }
  if (mem.act) {
    top->axi_r_valid = 1; top->axi_r_bits_id = mem.cur.id;
    top->axi_r_bits_data = word_at(mem.cur.addr + 8ULL * mem.beat);
    top->axi_r_bits_resp = 0; top->axi_r_bits_last = mem.beat + 1 == mem.cur.beats;
  } else { top->axi_r_valid = 0; top->axi_r_bits_last = 0; top->axi_r_bits_data = 0; }
  top->a_a_ready = 1; top->a_d_valid = 0;
}
struct Hs { bool ar, r, rv, awv, wv, av, we; uint8_t arid; uint64_t araddr; unsigned arlen, arsize, arburst; uint16_t wword; uint64_t wdata; };
static Hs sample() {
  Hs h{};
  h.ar = top->axi_ar_valid && top->axi_ar_ready; h.arid = top->axi_ar_bits_id; h.araddr = top->axi_ar_bits_addr;
  h.arlen = top->axi_ar_bits_len; h.arsize = top->axi_ar_bits_size; h.arburst = top->axi_ar_bits_burst;
  h.rv = top->axi_r_valid; h.r = top->axi_r_valid && top->axi_r_ready;
  h.awv = top->axi_aw_valid; h.wv = top->axi_w_valid; h.av = top->a_a_valid;
  h.we = top->tb_ww_en; h.wword = top->tb_ww_word; h.wdata = top->tb_ww_data;
  return h;
}

// ---- the weight-bank write checker -------------------------------------------------------------------------------
struct Expect { uint64_t data; unsigned seen; };
static std::map<uint16_t, Expect> expect_map;
static bool expecting = false;
static uint64_t w_writes = 0, w_bad_data = 0, w_dup = 0, w_unexpected = 0;
static uint64_t load_base = 0; static unsigned load_lgpw = 10, load_fbuf = 0, load_words = 0;
// The REAL descriptor the driver issues is multi-row: mbxr.c's load_wgt sends
//   sd  src, {stride[63:32] = plane_bytes, nrows[31:16] = MBXR_NCH, row_blocks[15:0] = plane_bytes/64}
// so every weight load on silicon walks NCH rows of row_blocks blocks, each row `stride` bytes on from
// the last, into contiguous destination words.  The single-row form below (nrows 1, stride 0) is what
// this bench drove until 2026-09-17, which is why the row loop and the strided address were never
// exercised here (MEMORY_BANDWIDTH.md 9.14).
static void expect_reset() { expect_map.clear(); w_writes = w_bad_data = w_dup = w_unexpected = 0; expecting = true; }
// add_only: keep what is already expected, so two loads into DIFFERENT buffers are checked as one union and a
// write that lands in the wrong buffer shows up as wrong data rather than being silently accepted.
static void expect_load_rows(uint64_t base, unsigned nrows, unsigned blocks, uint64_t stride,
                             unsigned lgpw, unsigned fbuf, bool add_only = false) {
  if (!add_only) { expect_map.clear(); w_writes = w_bad_data = w_dup = w_unexpected = 0; }
  load_base = base; load_lgpw = lgpw; load_fbuf = fbuf;
  unsigned per_row = 8 * blocks;
  load_words = nrows * per_row;
  for (unsigned w = 0; w < load_words; w++) {
    unsigned pr = w >> lgpw; if (pr >= (unsigned)NCH) { fprintf(stderr, "descriptor past NCH planes\n"); exit(2); }
    uint16_t key = (uint16_t)(((pr + 1) << 11) | (fbuf << 10) | (w & ((1u << lgpw) - 1)));
    expect_map[key] = Expect{word_at(base + (uint64_t)(w / per_row) * stride + 8ULL * (w % per_row)), 0};
  }
  expecting = true;
}
static void expect_load(uint64_t base, unsigned blocks, unsigned lgpw, unsigned fbuf, unsigned first_blocks_only = ~0u) {
  expect_map.clear(); w_writes = w_bad_data = w_dup = w_unexpected = 0;
  load_base = base; load_lgpw = lgpw; load_fbuf = fbuf;
  unsigned nb = std::min(blocks, first_blocks_only); load_words = 8 * nb;
  for (unsigned w = 0; w < 8 * nb; w++) {
    unsigned pr = w >> lgpw; if (pr >= (unsigned)NCH) { fprintf(stderr, "descriptor past NCH planes\n"); exit(2); }
    uint16_t key = (uint16_t)(((pr + 1) << 11) | (fbuf << 10) | (w & ((1u << lgpw) - 1)));
    expect_map[key] = Expect{word_at(base + 8ULL * w), 0};
  }
  expecting = true;
}
static void check_write(uint16_t word, uint64_t data) {
  w_writes++;
  auto it = expect_map.find(word);
  if (!expecting || it == expect_map.end()) { if (w_unexpected++ < 4) fprintf(stderr, "WRITE unexpected word=0x%04x (cyc1=%llu)\n", word, (unsigned long long)cyc1); return; }
  if (it->second.seen++) { if (w_dup++ < 4) fprintf(stderr, "WRITE duplicate word=0x%04x\n", word); }
  if (data != it->second.data) { if (w_bad_data++ < 4) fprintf(stderr, "WRITE wrong data word=0x%04x got=%016llx want=%016llx (cyc1=%llu)\n", word, (unsigned long long)data, (unsigned long long)it->second.data, (unsigned long long)cyc1); }
}
static bool load_exact(std::string &why) {
  uint64_t missing = 0; for (auto &kv : expect_map) if (!kv.second.seen) missing++;
  why.clear();
  if (missing) why += " missing=" + std::to_string(missing);
  if (w_dup) why += " duplicate=" + std::to_string(w_dup);
  if (w_bad_data) why += " wrong_data=" + std::to_string(w_bad_data);
  if (w_unexpected) why += " unexpected=" + std::to_string(w_unexpected);
  return why.empty();
}

static void mem_update(const Hs &h) {
  if (h.ar) {
    bool ok = h.arlen == 7 && h.arsize == 3 && h.arburst == 1 && (h.araddr & 63) == 0 && h.araddr >= WIN_BASE && h.araddr + 64 <= WIN_END;
    if (!ok) { mem.contract_bad++; perr("AR outside the contract (len/size/burst/window/alignment), addr", h.araddr); }
    uint64_t extra = 0;
    if (mem.jitter) { g_jit_state = g_jit_state * 6364136223846793005ULL + 1442695040888963407ULL;
                      extra = (g_jit_state >> 33) % (mem.jitter + 1); }
    mem.pend.push_back(RB{h.arid, h.araddr, h.arlen + 1, cyc1 + mem.lat + extra}); mem.ar++; mem.arlen[h.arlen & 255]++;
  }
  if (h.awv) { if (!mem.aw_valid_cycles) perr("AWVALID on a read-only channel"); mem.aw_valid_cycles++; }
  if (h.wv)  { if (!mem.w_valid_cycles) perr("WVALID on a read-only channel"); mem.w_valid_cycles++; }
  if (h.av)  { if (!a_valid_cycles) perr("client A issued during a weight-only test"); a_valid_cycles++; }
  if (h.rv && !h.r) { mem.stall_run++; mem.stall_cycles++; mem.stall_max = std::max(mem.stall_max, mem.stall_run); } else mem.stall_run = 0;
  if (h.r) { mem.rbeats++; if (++mem.beat == mem.cur.beats) { mem.act = false; mem.rlast++; } }
  if (h.we) check_write(h.wword, h.wdata);
}
static bool balanced() { return mem.ar == mem.rlast && mem.out_r() == 0; }

// ---- time --------------------------------------------------------------------------------------------------------
static uint64_t first_quiet_violation = 0;
// release watch: after a reset is released, when do the pins first balance, and when does the first new AR appear
static struct { bool armed = false; uint64_t at = 0, ar0 = 0, quiet_at = 0, first_ar = 0; } rw;
static void tick0() {
  for (;;) {
    uint64_t t = std::min(next0, next1);
    bool e0 = next0 == t, e1 = next1 == t;
    bool r0 = e0 && !c0, r1 = e1 && !c1;
    Hs h{};
    if (r1) { mem_drive(); top->eval(); h = sample(); }
    if (e0) { c0 = !c0; top->clk0 = c0; next0 += H0; }
    if (e1) { c1 = !c1; top->clk1 = c1; next1 += H1; }
    top->eval();
    if (r1) {
      mem_update(h); cyc1++; mem_drive(); top->eval();
      // the lane reset may only EXTEND a SoC reset: it must never rise while the SoC reset (rst1, as the lane sees it) is low
      bool lr = top->tb_lane_rst;
      if (lr && !prev_lane_rst && !top->rst1) { if (!lane_rst_violations++) fprintf(stderr, "LANE RESET ROSE OUTSIDE A SOC RESET (cyc1=%llu)\n", (unsigned long long)cyc1); }
      prev_lane_rst = lr;
      bool q = top->tb_quiet, b = (mem.ar == mem.rlast);
      if (q != b) { if (!quiet_violations++) { first_quiet_violation = cyc1; fprintf(stderr, "QUIET CLAIM quiet=%d but ar=%llu rlast=%llu (cyc1=%llu)\n", q, (unsigned long long)mem.ar, (unsigned long long)mem.rlast, (unsigned long long)cyc1); } }
      if (rw.armed) {
        if (!rw.quiet_at && b && mem.out_r() == 0) rw.quiet_at = cyc1;
        if (!rw.first_ar && mem.ar > rw.ar0) rw.first_ar = cyc1;
      }
    }
    if (r0) { cyc0++; return; }
  }
}
static void run_lane(uint64_t n) { uint64_t e = cyc1 + n; while (cyc1 < e) tick0(); }

// ---- the engine's RoCC command interface (engine clock), as RoccMoonShim drives it --------------------------------
static uint64_t cmd(unsigned funct, uint64_t rs1, uint64_t rs2, bool xd) {
  top->cmd_valid = 1; top->cmd_funct = funct; top->cmd_rs1 = rs1; top->cmd_rs2 = rs2; top->cmd_xd = xd;
  top->eval(); uint64_t r = top->rsp_respData;
  tick0();
  top->cmd_valid = 0; top->cmd_xd = 0; top->cmd_funct = 0; top->cmd_rs1 = 0; top->cmd_rs2 = 0;
  tick0();
  return r;
}
static uint64_t fence() { return cmd(6, 0, 0, true); }
static bool FILL(uint64_t s) { return s & 1; }
static bool ERR(uint64_t s) { return (s >> 47) & 1; }
static int READY(uint64_t s) { return (int)((s >> 41) & 1); }   // fence bit 41, "W lane ready"
// --ready-bit: drive the engine the way mbxr_dev.lane_wait does -- fence bit 41 before every weight load, MBXR_E_LANE
// if it never comes -- so a load is never issued while the lane is held in reset.
static bool g_ready_bit = false;
static uint64_t lane_wait_budget = 400000, lane_wait_max = 0, lane_wait_timeouts = 0;
static uint64_t stat_fill_beats() { return cmd(7, 0, 0, true) & ((1ULL << 48) - 1); }
static void stat_clear() { cmd(7, 0, 1, true); }
static bool lane_wait(uint64_t budget) {       // mbxr_dev.lane_wait: poll fence bit 41 before touching the lane
  uint64_t t0 = cyc1, e = cyc1 + budget;
  for (;;) {
    uint64_t s = fence();
    if (READY(s)) { lane_wait_max = std::max(lane_wait_max, cyc1 - t0); return true; }
    if (cyc1 > e) { lane_wait_timeouts++; fprintf(stderr, "MBXR_E_LANE: fence bit 41 never came in %llu lane cycles (cyc1=%llu)\n", (unsigned long long)budget, (unsigned long long)cyc1); return false; }
    run_lane(64);
  }
}
static void load(uint64_t base, unsigned blocks, unsigned lgpw, unsigned fbuf, unsigned cap, bool wait = true) {
  if (g_ready_bit && wait) lane_wait(lane_wait_budget);
  cmd(8, 0, cap, false);
  cmd(0, base, (1ULL << 16) | blocks, false);                     // sd: nrows 1, row_blocks = blocks, stride 0
  cmd(1, (1ULL << 17) | ((uint64_t)fbuf << 16) | ((uint64_t)lgpw << 8), 0, false);   // ld: weights, client W
}
static void load_rows(uint64_t base, unsigned nrows, unsigned blocks, uint64_t stride,
                      unsigned lgpw, unsigned fbuf, unsigned cap, bool wait = true) {
  if (g_ready_bit && wait) lane_wait(lane_wait_budget);
  cmd(8, 0, cap, false);
  cmd(0, base, ((stride & 0xffffffffULL) << 32) | ((uint64_t)nrows << 16) | blocks, false);
  cmd(1, (1ULL << 17) | ((uint64_t)fbuf << 16) | ((uint64_t)lgpw << 8), 0, false);
}
static bool wait_fill_clear(uint64_t max_lane, uint64_t &status) {
  uint64_t e = cyc1 + max_lane;
  for (;;) { status = fence(); if (!FILL(status)) return true; if (cyc1 > e) return false; run_lane(20); }
}
static void reset_both(unsigned lane_cycles) {
  top->rst0 = 1; top->rst1 = 1;
  uint64_t e = cyc1 + lane_cycles; while (cyc1 < e) tick0();
  top->rst0 = 0; top->rst1 = 0;
}

// ---- tests -------------------------------------------------------------------------------------------------------
static int sweep(const std::vector<int> &caps, unsigned blocks) {
  int rc = 0;
  for (int c : caps) {
    stat_clear();
    uint64_t base = 0x82000000ULL + (uint64_t)c * 0x100000ULL;
    expect_load(base, blocks, 10, c & 1);
    uint64_t ar0 = mem.ar, c1s = cyc1, st0 = mem.stall_cycles;
    load(base, blocks, 10, c & 1, c);
    uint64_t s; bool done = wait_fill_clear(60ULL * blocks + 200000, s);
    uint64_t lane = cyc1 - c1s, beats = stat_fill_beats();
    std::string why; bool exact = load_exact(why);
    bool ok = done && exact && !ERR(s) && beats == 8ULL * blocks && mem.ar - ar0 == blocks && (!g_ready_bit || READY(s));
    printf("WLANETB2B sweep lat=%u cap=%d blocks=%u lane_cycles=%llu B_per_lane_cycle=%.3f ar=%llu fill_beats=%llu err=%d ready_bit=%d rstall_cyc=%llu exact=%s%s -> %s\n",
           mem.lat, c, blocks, (unsigned long long)lane, 64.0 * blocks / lane, (unsigned long long)(mem.ar - ar0), (unsigned long long)beats,
           (int)ERR(s), READY(s), (unsigned long long)(mem.stall_cycles - st0), exact ? "yes" : "NO:", why.c_str(), ok ? "PASS" : "FAIL");
    fflush(stdout);
    if (!ok) rc = 1;
  }
  return rc;
}

// THE SHAPE SILICON ACTUALLY LOADS.  Lab B25 on 0x5A5A0013 found the engine returning wrong bytes for small
// shapes while big ones were exact (MEMORY_BANDWIDTH.md 9.14), and the driver's descriptor is multi-row with a
// stride -- a path this bench had never driven.  Each case here is (nrows, row_blocks, lgpw), with the stride
// the driver would use (plane_bytes = 8 << lgpw) and a base that is 64-byte aligned but not plane aligned in
// the last case, because mbxr.c computes src = img->pa + t * NCH * plane_bytes and nothing aligns img->pa
// beyond 64.
static int rows_test(const std::vector<int> &caps) {
  struct Case { unsigned nrows, blocks, lgpw; uint64_t base_off; const char *name; };
  const Case cases[] = {
    { 4, 128, 10, 0x00000000ULL, "real_lgpw10" },   // the exact descriptor load_wgt issues for a 1024-word plane
    { 4,  16,  7, 0x00010000ULL, "small_lgpw7"  },  // a small plane: 128 words, 16 blocks a row
    { 4,   1,  3, 0x00020000ULL, "tiny_lgpw3"   },  // one block a row, the smallest the driver can ask for
    { 2,  64,  9, 0x00030040ULL, "two_rows_off" },  // two rows from a base that is 64-byte but not plane aligned
  };
  int rc = 0;
  for (const Case &c : cases) {
    for (int cap : caps) {
      stat_clear();
      uint64_t plane_bytes = 8ULL << c.lgpw;
      uint64_t base = 0x82000000ULL + c.base_off;
      expect_load_rows(base, c.nrows, c.blocks, plane_bytes, c.lgpw, 0);
      uint64_t ar0 = mem.ar, c1s = cyc1;
      load_rows(base, c.nrows, c.blocks, plane_bytes, c.lgpw, 0, cap);
      uint64_t s; bool done = wait_fill_clear(60ULL * c.nrows * c.blocks + 200000, s);
      uint64_t lane = cyc1 - c1s, beats = stat_fill_beats();
      std::string why; bool exact = load_exact(why);
      uint64_t want_ar = (uint64_t)c.nrows * c.blocks;
      bool ok = done && exact && !ERR(s) && beats == 8 * want_ar && mem.ar - ar0 == want_ar;
      printf("WLANETB2B rows %s cap=%d nrows=%u blocks=%u lgpw=%u stride=%llu lane_cycles=%llu ar=%llu (want %llu) "
             "fill_beats=%llu (want %llu) err=%d exact=%s%s -> %s\n",
             c.name, cap, c.nrows, c.blocks, c.lgpw, (unsigned long long)plane_bytes, (unsigned long long)lane,
             (unsigned long long)(mem.ar - ar0), (unsigned long long)want_ar,
             (unsigned long long)beats, (unsigned long long)(8 * want_ar), (int)ERR(s),
             exact ? "yes" : "NO:", why.c_str(), ok ? "PASS" : "FAIL");
      fflush(stdout);
      if (!ok) rc = 1;
    }
  }
  return rc;
}

// BACK-TO-BACK LOADS THAT SWITCH BUFFERS THE INSTANT FILL CLEARS -- the driver's own pattern, and the sharpest
// test of the property the CDC-13 waiver rests on (MEMORY_BANDWIDTH.md 9.14.1).  mbxr.c's load_wgt waits for FILL to
// clear and then immediately sends sd + ld, which rewrites lw_fbuf and lw_lgpw.  Those two FCLK0 registers feed the
// weight banks' write-enable and write-address pins combinationally, so if FILL clears before the previous load's
// last writes have landed, the tail of load N is written at load N+1's address, in load N+1's buffer.  Both loads'
// words are expected as one union here, so a mis-destined write is caught as wrong data or as a duplicate.
static int btb_test(const std::vector<int> &caps) {
  int rc = 0;
  for (int cap : caps) {
    for (unsigned blocks : {1u, 4u, 16u}) {
      for (unsigned lgpw : {7u, 10u}) {
        unsigned nrows = 2;
        if (nrows * blocks * 8 > (1u << lgpw) * (unsigned)NCH) continue;
        uint64_t stride = 8ULL << lgpw;
        uint64_t b0 = 0x82000000ULL, b1 = 0x83000000ULL;
        stat_clear();
        expect_reset();
        expect_load_rows(b0, nrows, blocks, stride, lgpw, 0, true);
        expect_load_rows(b1, nrows, blocks, stride, lgpw, 1, true);
        uint64_t ar0 = mem.ar, c1s = cyc1;
        load_rows(b0, nrows, blocks, stride, lgpw, 0, cap);
        uint64_t s; bool d0 = wait_fill_clear(60ULL * nrows * blocks + 200000, s);
        load_rows(b1, nrows, blocks, stride, lgpw, 1, cap);        // issued the cycle FILL says it may be
        bool d1 = wait_fill_clear(60ULL * nrows * blocks + 200000, s);
        std::string why; bool exact = load_exact(why);
        uint64_t want_ar = 2ULL * nrows * blocks;
        bool ok = d0 && d1 && exact && !ERR(s) && mem.ar - ar0 == want_ar;
        printf("WLANETB2B btb cap=%d nrows=%u blocks=%u lgpw=%u lane_cycles=%llu ar=%llu (want %llu) err=%d "
               "exact=%s%s -> %s\n", cap, nrows, blocks, lgpw, (unsigned long long)(cyc1 - c1s),
               (unsigned long long)(mem.ar - ar0), (unsigned long long)want_ar, (int)ERR(s),
               exact ? "yes" : "NO:", why.c_str(), ok ? "PASS" : "FAIL");
        fflush(stdout);
        if (!ok) rc = 1;
      }
    }
  }
  return rc;
}

// abort = SoC reset (rev2b has no software abort); R back-pressured and Gets outstanding at the reset; then the next
// load on a fresh buffer must be exact.  reset_cycles <= 56 is finding (a).
static bool nohold = false;   // --nohold: reset as soon as 3+ Gets are outstanding, R NOT back-pressured (fresh ARs, PS latency still running)
static int abort_test(unsigned blocks, unsigned reset_cycles, unsigned abort_after, bool rdrop) {
  stat_clear();
  const uint64_t B1 = 0x82000000ULL, B2 = 0x8A000000ULL;
  expect_load(B1, blocks, 10, 0);
  uint64_t rl0 = mem.rlast;
  load(B1, blocks, 10, 0, 4);
  for (int i = 0; i < 400000 && (mem.rlast - rl0 < abort_after || mem.out_r() < 3); i++) tick0();
  uint64_t done_before = mem.rlast - rl0;
  std::string why1; load_exact(why1);
  bool load1_clean = w_bad_data == 0 && w_dup == 0 && w_unexpected == 0;
  bool pre = false;
  if (nohold) {
    uint64_t ar_seen = mem.ar;
    for (uint64_t e = cyc1 + 4000; cyc1 < e; ) { tick0(); if (mem.ar != ar_seen && mem.out_r() >= 3) { pre = true; break; } }
  } else {
    top->tb_dhold = 1;
    for (uint64_t e = cyc1 + 4000; cyc1 < e; ) { tick0(); if (mem.stall_run >= 16 && mem.out_r() >= 3) { pre = true; break; } }
  }
  unsigned at_out = mem.out_r(); uint64_t at_stall = mem.stall_run; unsigned at_beat = mem.act ? mem.beat : 99;
  if (!pre) { printf("WLANETB2B abort PRECONDITION NOT MET out=%u stall_run=%llu\n", at_out, (unsigned long long)at_stall); return 5; }
  // the abort: a SoC reset, issued while RREADY is low with bursts outstanding
  uint64_t st_before = mem.stall_cycles;
  top->rst0 = 1; top->rst1 = 1; top->tb_dhold = 0; top->tb_rdrop = rdrop;
  unsigned settle = std::min(2u, reset_cycles);   // a lane cycle in reset: the weight half writes nothing after it
  run_lane(settle);
  expect_load(B2, blocks, 10, 0);                 // from here on only the NEXT load's words may be written
  uint64_t e = cyc1 + (reset_cycles - settle); while (cyc1 < e) tick0();
  uint64_t rready_low_in_reset = mem.stall_cycles - st_before;
  unsigned out_at_release = mem.out_r() + (unsigned)((mem.ar - mem.rlast) > mem.out_r() ? 0 : 0);
  uint64_t outstanding_at_release = mem.ar - mem.rlast;
  top->rst0 = 0; top->rst1 = 0;
  // the next load, issued at once.  Every AR after the release belongs to it: all earlier ARs were issued before the reset.
  uint64_t ar_before2 = mem.ar, c_release = cyc1;
  rw = {}; rw.armed = true; rw.at = cyc1; rw.ar0 = mem.ar;
  if (balanced()) rw.quiet_at = cyc1;
  load(B2, blocks, 10, 0, 4);
  bool done = false; uint64_t s = 0;
  uint64_t deadline = cyc1 + 60ULL * blocks + 200000;
  while (cyc1 < deadline) {
    tick0();
    if ((cyc1 & 63) == 0) { s = fence(); if (!FILL(s) && cyc1 - c_release > 64) { done = true; break; } }
  }
  rw.armed = false;
  uint64_t quiet_at = rw.quiet_at, first_ar2 = rw.first_ar;
  bool hold_seen = outstanding_at_release > 0;          // was there anything to hold for?
  bool hold_ok = !first_ar2 || !quiet_at || first_ar2 > quiet_at || (first_ar2 == quiet_at && outstanding_at_release == 0);
  run_lane(3000);
  std::string why; bool exact = load_exact(why);
  bool drained = balanced() && mem.stall_run == 0;
  uint64_t beats = stat_fill_beats();
  bool ok = done && exact && drained && !ERR(s) && beats == 8ULL * blocks && mem.ar - ar_before2 == blocks && load1_clean;
  printf("WLANETB2B abort reset_cycles=%u lat=%u p1=%.3fns r_backpressured_at_reset=%d rdrop=%d noquiet=%d rfirst=%d noresethold=%d | pre: gets_done=%llu/%u load1_writes_clean=%d | at_reset: out=%u rstall_run=%llu burst_beat=%s | "
         "in_reset: rready_low_cycles=%llu | at_release: outstanding=%llu | next load: pins_quiet_at=+%lld first_AR=+%lld quiet_hold=%s ar=%llu fill_beats=%llu err=%d done=%d exact=%s%s | "
         "pins: ar=%llu rlast=%llu held=%u -> %s\n",
         reset_cycles, mem.lat, 2.0 * H1 / 1000.0, (int)!nohold, (int)rdrop, (int)top->tb_mut_noquiet, (int)top->tb_mut_rfirst, (int)top->tb_mut_noresethold,
         (unsigned long long)done_before, blocks, (int)load1_clean, at_out, (unsigned long long)at_stall,
         at_beat == 99 ? "none" : (std::to_string(at_beat) + "/8").c_str(), (unsigned long long)rready_low_in_reset,
         (unsigned long long)outstanding_at_release, quiet_at ? (long long)(quiet_at - c_release) : -1LL,
         first_ar2 ? (long long)(first_ar2 - c_release) : -1LL, !hold_seen ? "n/a(nothing_outstanding)" : hold_ok ? "held_until_quiet" : "AR_BEFORE_QUIET",
         (unsigned long long)(mem.ar - ar_before2), (unsigned long long)beats,
         (int)ERR(s), (int)done, exact ? "yes" : "NO:", why.c_str(),
         (unsigned long long)mem.ar, (unsigned long long)mem.rlast, mem.out_r(),
         ok ? "DRAINED, NEXT LOAD EXACT" : (std::string("FAIL:") + (done ? "" : " next_load_stalled") + (exact ? "" : " next_load_not_exact") +
                                            (drained ? "" : " pins_not_drained") + (ERR(s) ? " sticky_error" : "") +
                                            (beats == 8ULL * blocks ? "" : " fill_beats") + (load1_clean ? "" : " load1_writes")).c_str());
  (void)out_at_release;
  fflush(stdout);
  top->tb_rdrop = 0;
  return ok ? 0 : 1;
}

// finding (b): descriptors outside the window issue no AR, raise the sticky error and finish; then a clean load.
static int window_test() {
  struct Case { const char *name; uint64_t base; unsigned blocks; unsigned inside; };
  Case cases[] = { {"above", 0x90000000ULL, 16, 0}, {"below", 0x7FFFF000ULL, 16, 0}, {"runs_off_end", 0x8FFFFF00ULL, 16, 4},
                   {"last_block_inside", 0x8FFFFFC0ULL, 1, 1} };
  int rc = 0;
  for (auto &c : cases) {
    stat_clear();
    uint64_t s0 = fence();
    expect_load(c.base, c.blocks, 10, 0, c.inside);
    uint64_t ar0 = mem.ar, bad0 = mem.contract_bad;
    load(c.base, c.blocks, 10, 0, 4);
    uint64_t s; bool done = wait_fill_clear(200000, s);
    run_lane(500); s = fence();
    std::string why; bool exact = load_exact(why);
    bool want_err = c.inside < c.blocks;
    bool ok = done && exact && mem.ar - ar0 == c.inside && mem.contract_bad == bad0 && ERR(s) == want_err && !ERR(s0);
    printf("WLANETB2B window %s base=0x%llx blocks=%u ar=%llu (inside=%u) ars_outside_window=%llu err=%d (want %d) done=%d exact=%s%s -> %s\n",
           c.name, (unsigned long long)c.base, c.blocks, (unsigned long long)(mem.ar - ar0), c.inside, (unsigned long long)(mem.contract_bad - bad0),
           (int)ERR(s), (int)want_err, (int)done, exact ? "yes" : "NO:", why.c_str(), ok ? "PASS" : "FAIL");
    fflush(stdout);
    if (!ok) rc = 1;
  }
  // the error is sticky until STAT clear, and a normal load then runs clean
  stat_clear();
  expect_load(0x84000000ULL, 64, 10, 1);
  uint64_t ar0 = mem.ar;
  load(0x84000000ULL, 64, 10, 1, 4);
  uint64_t s; bool done = wait_fill_clear(200000, s);
  std::string why; bool exact = load_exact(why);
  bool ok = done && exact && !ERR(s) && mem.ar - ar0 == 64;
  printf("WLANETB2B window after_clear base=0x84000000 blocks=64 ar=%llu err=%d done=%d exact=%s%s -> %s\n", (unsigned long long)(mem.ar - ar0),
         (int)ERR(s), (int)done, exact ? "yes" : "NO:", why.c_str(), ok ? "PASS" : "FAIL");
  if (!ok) rc = 1;
  return rc;
}

// LIVENESS: an RLAST that never arrives.  A burst outstanding at a short reset is frozen in the memory (the PS never
// delivers it), so mbxr_wquiet never reports quiet and the lane stays in reset.  The engine must keep answering; the
// driver must see the lane not ready and time out.  Two drivers are modelled:
//   bit-41 driver (the Moonshine driver's protocol): before a weight LD, poll fence bit 41 ("W lane ready") with a budget;
//   plain driver: issue LD, then a no-progress watchdog on FILL and STAT fill beats.
// Then the PS delivers after all: the lane must leave reset by itself and the queued load must complete exactly.
static int stuck_test(unsigned blocks, unsigned reset_cycles, unsigned abort_after, uint64_t watchdog, bool ready_bit) {
  stat_clear();
  const uint64_t B1 = 0x82000000ULL, B2 = 0x8A000000ULL;
  expect_load(B1, blocks, 10, 0);
  uint64_t rl0 = mem.rlast;
  load(B1, blocks, 10, 0, 4);
  for (int i = 0; i < 400000 && (mem.rlast - rl0 < abort_after || mem.pend.empty() || mem.out_r() < 3); i++) tick0();
  if (mem.pend.empty()) { printf("WLANETB2B stuck PRECONDITION NOT MET: nothing pending\n"); return 5; }
  RB frozen = mem.pend.back(); mem.pend.back().ready_at = UINT64_MAX;       // the PS never delivers this burst
  unsigned out_at_reset = mem.out_r();
  top->rst0 = 1; top->rst1 = 1;
  unsigned settle = std::min(2u, reset_cycles);   // a lane cycle in reset: the weight half writes nothing after it
  run_lane(settle);
  expect_load(B2, blocks, 10, 0);
  { uint64_t e = cyc1 + (reset_cycles - settle); while (cyc1 < e) tick0(); }
  top->rst0 = 0; top->rst1 = 0;
  uint64_t c_release = cyc1, ar_release = mem.ar;
  // ---- the bit-41 driver: wait for "W lane ready" with a budget -------------------------------------------------------
  int ready_max = 0; uint64_t polls = 0; bool lane_rst_all = true;
  for (uint64_t e = cyc1 + watchdog; cyc1 < e; ) {
    uint64_t s = fence(); polls++; ready_max = std::max(ready_max, READY(s));
    if (!top->tb_lane_rst) lane_rst_all = false;
    run_lane(64);
  }
  bool ready_timeout = ready_max == 0;
  // ---- the plain driver: LD anyway (no lane_wait), then a no-progress watchdog -------------------------------------------
  load(B2, blocks, 10, 0, 4, false);
  uint64_t beats0 = stat_fill_beats(), s = 0; bool fill_all = true, progress = false; int inflight_max = 0;
  for (uint64_t e = cyc1 + watchdog; cyc1 < e; ) {
    s = fence(); polls++;
    if (!FILL(s)) fill_all = false;
    inflight_max = std::max(inflight_max, (int)((s >> 16) & 0xff));
    if (stat_fill_beats() != beats0) progress = true;
    if (!top->tb_lane_rst) lane_rst_all = false;
    run_lane(64);
  }
  bool watchdog_fired = fill_all && !progress;
  uint64_t ar_during_hold = mem.ar - ar_release;
  bool rvalid_held = mem.stall_run > 0;
  printf("WLANETB2B stuck reset_cycles=%u lat=%u p1=%.3fns | at_reset: out=%u, one burst frozen (id=%u addr=0x%llx) | "
         "held %llu lane cycles: lane_reset_asserted_throughout=%d ARs=%llu engine_answered=%llu_polls ready_bit_max=%d (%s) | "
         "plain driver: FILL_set_throughout=%d fill_beats_progress=%d inflight_max=%d err=%d -> watchdog %s\n",
         reset_cycles, mem.lat, 2.0 * H1 / 1000.0, out_at_reset, frozen.id, (unsigned long long)frozen.addr,
         (unsigned long long)(cyc1 - c_release), (int)lane_rst_all, (unsigned long long)ar_during_hold, (unsigned long long)polls, ready_max,
         ready_bit ? (ready_timeout ? "bit-41 driver: LANE NOT READY" : "bit-41 driver: READY SEEN") : "not enforced: the RTL may not carry bit 41",
         (int)fill_all, (int)progress, inflight_max, (int)ERR(s), watchdog_fired ? "LANE NOT READY" : "did not fire");
  fflush(stdout);
  // ---- the PS delivers after all ---------------------------------------------------------------------------------------
  for (auto &rb : mem.pend) if (rb.ready_at == UINT64_MAX) rb.ready_at = cyc1;
  uint64_t c_unfreeze = cyc1; bool done = false; int ready_after = 0;
  uint64_t deadline = cyc1 + 60ULL * blocks + 200000;
  while (cyc1 < deadline) { run_lane(64); s = fence(); ready_after = std::max(ready_after, READY(s)); if (!FILL(s) && !top->tb_lane_rst) { done = true; break; } }
  run_lane(3000);
  std::string why; bool exact = load_exact(why);
  bool drained = balanced() && mem.stall_run == 0;
  bool ok = lane_rst_all && ar_during_hold == 0 && watchdog_fired && !rvalid_held && done && exact && drained && !ERR(s)
            && (!ready_bit || (ready_timeout && ready_after == 1));
  printf("WLANETB2B stuck recovery: lane_left_reset_and_load_done=%d after %lld lane cycles, exact=%s%s, ready_bit_after=%d, pins ar=%llu rlast=%llu held=%u -> %s\n",
         (int)done, (long long)(cyc1 - c_unfreeze), exact ? "yes" : "NO:", why.c_str(), ready_after,
         (unsigned long long)mem.ar, (unsigned long long)mem.rlast, mem.out_r(), ok ? "PASS" : "FAIL");
  fflush(stdout);
  return ok ? 0 : 1;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  unsigned lat = 20, blocks = 512, reset_cycles = 256, abort_after = 100;
  bool rdrop = false, rfirst = false, noquiet = false, noresethold = false, ready_bit = false;
  uint64_t stuck_watchdog = 20000;
  std::string caps = "1,2,3,4"; std::vector<std::string> tests; int jitter = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--jitter") && i + 1 < argc) jitter = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) blocks = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--caps") && i + 1 < argc) caps = argv[++i];
    else if (!strcmp(argv[i], "--p0") && i + 1 < argc) H0 = atoll(argv[++i]) / 2;
    else if (!strcmp(argv[i], "--p1") && i + 1 < argc) H1 = atoll(argv[++i]) / 2;
    else if (!strcmp(argv[i], "--reset-cycles") && i + 1 < argc) reset_cycles = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--abort-after") && i + 1 < argc) abort_after = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--rdrop")) rdrop = true;
    else if (!strcmp(argv[i], "--rfirst")) rfirst = true;
    else if (!strcmp(argv[i], "--noquiet")) noquiet = true;
    else if (!strcmp(argv[i], "--noresethold")) noresethold = true;
    else if (!strcmp(argv[i], "--ready-bit")) { ready_bit = true; g_ready_bit = true; }
    else if (!strcmp(argv[i], "--stuck-watchdog") && i + 1 < argc) stuck_watchdog = atoll(argv[++i]);
    else if (!strcmp(argv[i], "--nohold")) nohold = true;
    else if (argv[i][0] != '+') tests.push_back(argv[i]);
  }
  if (blocks * 8 > (unsigned)NCH * 1024) { fprintf(stderr, "blocks too large for 4 planes of 1024 words\n"); return 2; }
  next0 = H0; next1 = H1;
  top = new Vwlanetb2b_top;
  mem.lat = lat; mem.jitter = jitter;
  top->cmd_valid = 0; top->tb_dhold = 0; top->tb_rdrop = 0; top->tb_mut_rfirst = rfirst; top->tb_mut_noquiet = noquiet; top->tb_mut_noresethold = noresethold;
  reset_both(40);
  run_lane(40);
  uint64_t id = cmd(7, 7, 0, true);
  printf("WLANETB2B engine id=0x%012llx (NCH=%llu LDEPTH=%llu SDEPTH=%llu) engine=%.4fMHz lane=%.4fMHz lat=%u jitter=%u rfirst=%d noquiet=%d\n",
         (unsigned long long)id, (unsigned long long)((id >> 32) & 0xffff), (unsigned long long)((id >> 24) & 0xff), (unsigned long long)((id >> 16) & 0xff),
         1e6 / (2.0 * H0), 1e6 / (2.0 * H1), lat, mem.jitter, (int)rfirst, (int)noquiet);
  std::vector<int> cv; { std::string o = caps; for (char *t = strtok(&o[0], ","); t; t = strtok(nullptr, ",")) cv.push_back(atoi(t)); }
  int rc = 0;
  for (auto &t : tests) {
    int r = 0;
    if (t == "sweep") r = sweep(cv, blocks);
    else if (t == "abort") r = abort_test(blocks, reset_cycles, abort_after, rdrop);
    else if (t == "rows") r = rows_test(cv);
    else if (t == "btb") r = btb_test(cv);
    else if (t == "window") r = window_test();
    else if (t == "stuck") r = stuck_test(blocks, reset_cycles, abort_after, stuck_watchdog, ready_bit);
    else { fprintf(stderr, "unknown test %s\n", t.c_str()); return 2; }
    if (r) rc = r;
  }
  printf("WLANETB2B arlen");
  for (int l = 0; l < 256; l++) if (mem.arlen[l]) printf(" len%d(%d beats)=%llu", l, l + 1, (unsigned long long)mem.arlen[l]);
  bool clean = protocol_errors == 0 && quiet_violations == 0 && lane_rst_violations == 0 && lane_wait_timeouts == 0;
  printf("\nWLANETB2B end cyc0=%llu cyc1=%llu pins ar=%llu rlast=%llu contract_bad=%llu awvalid_cycles=%llu wvalid_cycles=%llu a_valid_cycles=%llu quiet_claim_violations=%llu lane_reset_outside_soc_reset=%llu lane_wait_max=%llu lane_wait_timeouts=%llu protocol_errors=%llu -> %s\n",
         (unsigned long long)cyc0, (unsigned long long)cyc1, (unsigned long long)mem.ar, (unsigned long long)mem.rlast,
         (unsigned long long)mem.contract_bad, (unsigned long long)mem.aw_valid_cycles, (unsigned long long)mem.w_valid_cycles,
         (unsigned long long)a_valid_cycles, (unsigned long long)quiet_violations, (unsigned long long)lane_rst_violations, (unsigned long long)lane_wait_max, (unsigned long long)lane_wait_timeouts, (unsigned long long)protocol_errors,
         rc == 0 && clean ? "PASS" : "FAIL");
  delete top;
  return rc ? rc : (clean ? 0 : 1);
}
