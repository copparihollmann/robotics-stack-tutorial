// SIMULATION ONLY.  PROBE-LEVEL, PRE-REV2B.  The generated private weight channel of
// PynqZ2RocketBigLittlePextTacitMicRgbBwWLaneProbeConfig (MEMORY_BANDWIDTH.md s9.9, design (ii')): a stand-in weight lane
// (BwBypass's mbxd_dma, one lane) in the wlane clock domain, its TLBuffer -> TLToAXI4 -> AXI4IdIndexer -> AXI4UserYanker,
// and the pbus-side MMIO crossing -- against a behavioural AXI4 memory standing in for S_AXI_HP2 (RVALID and its payload
// held while RREADY is low).  Two clocks: the lane on clk1 (FCLK1-like, 10 ns), the MMIO source on clk0 (FCLK0-like, 29 ns).
//
//   Vwlanetb_top [--lat L] [--blocks N] [--outs 1,2,4,8] [--p0 ps] [--p1 ps]
//                [--abort gate|reset] [--reset-cycles N] [--rdrop] [--hold-after N] [--abort-after GETS] [--stall-min CYCLES]  sweep | abort | oow
//
// Contract checked on EVERY AR/AW/W at the pins, in every test: ARLEN = 7 (8 beats), ARSIZE = 3, ARBURST = INCR, the
// burst inside the weight window [0x8000_0000, 0x9000_0000) and 64-byte aligned; AWVALID and WVALID never asserted.
//
// abort: the lane runs at 8 in flight; tb_dhold stalls the lane's D path until RREADY is low at the pins with RVALID
// high and Gets outstanding; then the abort is issued WHILE R is back-pressured:
//   gate   max_outstanding <- 0 over MMIO (issuing stops), then the stall is released (the abort discards);
//   reset  rst0 and rst1 asserted together for --reset-cycles lane cycles (a SoC reset; the PS is not reset).
// Drain oracle, at the pins, every lane cycle: AR = RLAST, nothing pending or mid-burst in the memory, RVALID not held
// against RREADY, within 30,000 lane cycles; and (gate) the lane's own in-flight counter must not reach 0 while the pins
// still have a burst outstanding.  Then a resume must deliver every word with the right checksum.
// Negative controls: --rdrop forces RREADY low at the pins from the abort on (a lane that drops RREADY during the drain);
// the skip_rlast build (MUTANT=skip_rlast ./build.sh) counts a Get complete on its first beat.
#include "Vwlanetb_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

static Vwlanetb_top *top;
static uint64_t H0 = 14500, H1 = 5000;   // half periods (ps): FCLK0 = 1000/29 MHz, FCLK1 = 100 MHz
static uint64_t next0, next1;
static bool c0 = false, c1 = false;
static uint64_t cyc0 = 0, cyc1 = 0;

static const uint64_t WIN_BASE = 0x80000000ULL, WIN_END = 0x90000000ULL;
static const uint64_t BASE = 0x100d0000ULL, BUF = 0x82000000ULL, BUF2 = 0x8a000000ULL;

static uint64_t word_at(uint64_t addr) {
  uint64_t x = addr * 0x9E3779B97F4A7C15ULL;
  x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ULL; x ^= x >> 32;
  return x;
}

// ---- the AXI4 memory (S_AXI_HP2 stand-in), clocked by clk1 -------------------------------------------------------
struct RB { uint8_t id; uint64_t addr; unsigned beats; uint64_t ready_at; };
struct Mem {
  unsigned lat = 20, cap = 8;
  std::deque<RB> pend; bool act = false; RB cur{}; unsigned beat = 0;
  uint64_t ar = 0, rlast = 0, rbeats = 0, aw_valid_cycles = 0, w_valid_cycles = 0, contract_bad = 0;
  uint64_t stall_run = 0, stall_max = 0, stall_cycles = 0;
  uint64_t arlen[256] = {0};
  unsigned out_r() const { return pend.size() + (act ? 1 : 0); }
};
static Mem mem;
static uint64_t protocol_errors = 0;
static void perr(const char *msg, uint64_t a = 0) {
  if (protocol_errors < 20) fprintf(stderr, "PROTOCOL: %s 0x%llx (cyc1=%llu)\n", msg, (unsigned long long)a, (unsigned long long)cyc1);
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
}

struct Hs { bool ar, r, rv, awv, wv; uint8_t arid; uint64_t araddr; unsigned arlen, arsize, arburst; };
static Hs mem_sample() {
  Hs h{};
  h.ar = top->axi_ar_valid && top->axi_ar_ready; h.arid = top->axi_ar_bits_id; h.araddr = top->axi_ar_bits_addr;
  h.arlen = top->axi_ar_bits_len; h.arsize = top->axi_ar_bits_size; h.arburst = top->axi_ar_bits_burst;
  h.rv = top->axi_r_valid; h.r = top->axi_r_valid && top->axi_r_ready;
  h.awv = top->axi_aw_valid; h.wv = top->axi_w_valid;
  return h;
}
static void mem_update(const Hs &h) {
  if (h.ar) {
    bool ok = h.arlen == 7 && h.arsize == 3 && h.arburst == 1 && (h.araddr & 63) == 0 &&
              h.araddr >= WIN_BASE && h.araddr + 64 <= WIN_END;
    if (!ok) { mem.contract_bad++; perr("AR outside the contract (len/size/burst/window/alignment), addr", h.araddr); }
    mem.pend.push_back(RB{h.arid, h.araddr, h.arlen + 1, cyc1 + mem.lat}); mem.ar++; mem.arlen[h.arlen & 255]++;
  }
  if (h.awv) { if (!mem.aw_valid_cycles) perr("AWVALID on a read-only channel"); mem.aw_valid_cycles++; }
  if (h.wv)  { if (!mem.w_valid_cycles) perr("WVALID on a read-only channel"); mem.w_valid_cycles++; }
  if (h.rv && !h.r) { mem.stall_run++; mem.stall_cycles++; mem.stall_max = std::max(mem.stall_max, mem.stall_run); } else mem.stall_run = 0;
  if (h.r) { mem.rbeats++; if (++mem.beat == mem.cur.beats) { mem.act = false; mem.rlast++; } }
}

// ---- time --------------------------------------------------------------------------------------------------------
static void (*clk1_hook)() = nullptr;
static void tick0() {
  for (;;) {
    uint64_t t = std::min(next0, next1);
    bool e0 = next0 == t, e1 = next1 == t;
    bool r0 = e0 && !c0, r1 = e1 && !c1;
    Hs h{};
    if (r1) { mem_drive(); top->eval(); h = mem_sample(); }
    if (e0) { c0 = !c0; top->clk0 = c0; next0 += H0; }
    if (e1) { c1 = !c1; top->clk1 = c1; next1 += H1; }
    top->eval();
    if (r1) { mem_update(h); cyc1++; mem_drive(); top->eval(); if (clk1_hook) clk1_hook(); }
    if (r0) { cyc0++; return; }
  }
}
static void run_lane_cycles(uint64_t n) { uint64_t e = cyc1 + n; while (cyc1 < e) tick0(); }

// ---- TL-UL register access through the generated crossing, clk0 domain --------------------------------------------
static uint64_t tl(bool put, uint64_t addr, uint64_t data) {
  top->mmio_a_valid = 1; top->mmio_a_bits_opcode = put ? 0 : 4; top->mmio_a_bits_param = 0; top->mmio_a_bits_size = 3;
  top->mmio_a_bits_source = 0; top->mmio_a_bits_address = addr; top->mmio_a_bits_mask = 0xff;
  top->mmio_a_bits_data = put ? data : 0; top->mmio_a_bits_corrupt = 0; top->mmio_d_ready = 1;
  for (int i = 0;; i++) {
    top->eval(); bool acc = top->mmio_a_ready; bool got = top->mmio_d_valid; uint64_t d = top->mmio_d_bits_data; tick0();
    if (acc && got) { top->mmio_a_valid = 0; return d; }
    if (acc) break;
    if (i > 200000) { fprintf(stderr, "mmio A never accepted\n"); exit(4); }
  }
  top->mmio_a_valid = 0;
  for (int i = 0;; i++) {
    top->eval(); bool got = top->mmio_d_valid; uint64_t d = top->mmio_d_bits_data; tick0();
    if (got) return d;
    if (i > 200000) { fprintf(stderr, "mmio D never came\n"); exit(4); }
  }
}
static void wr(uint64_t off, uint64_t v) { tl(true, BASE + off, v); }
static uint64_t rd(uint64_t off) { return tl(false, BASE + off, 0); }

static uint64_t setup(uint64_t buf, unsigned blocks) {
  wr(0x100, buf); wr(0x108, blocks); wr(0x110, 1); wr(0x118, 0);
  uint64_t sw = 0; for (uint64_t b = 0; b < blocks; b++) for (int w = 0; w < 8; w++) sw ^= word_at(buf + 64 * b + 8 * w);
  return sw;
}
static bool wait_idle(uint64_t max_lane_cycles) {
  uint64_t e = cyc1 + max_lane_cycles;
  while (rd(0x018) & 1) if (cyc1 > e) return false;
  return true;
}

// ---- sweep -------------------------------------------------------------------------------------------------------
static bool point(int out, unsigned blocks) {
  uint64_t sw = setup(BUF, blocks);
  wr(0x010, out); wr(0x008, 1);
  uint64_t ar0 = mem.ar, st0 = mem.stall_cycles; mem.stall_max = 0;
  wr(0x000, 1);
  bool idle = wait_idle(50ULL * blocks + 100000);
  uint64_t cyc = rd(0x020), beats = rd(0x028), reqs = rd(0x030), ck = rd(0x038), den = rd(0x040), peak = rd(0x048);
  double bpc = cyc ? 8.0 * beats / cyc : 0;
  bool ok = idle && beats == 8ULL * blocks && reqs == blocks && ck == sw && den == 0 && mem.ar - ar0 == blocks;
  printf("WLANETB sweep lat=%u out=%d cycles=%llu words=%llu reqs=%llu bpc=%.4f mbps_at_100=%.1f cyc_per_get=%.3f peak=%llu denied=%llu ar=%llu rstall_cyc=%llu rstall_max=%llu cksum=%s -> %s\n",
         mem.lat, out, (unsigned long long)cyc, (unsigned long long)beats, (unsigned long long)reqs, bpc, bpc * 100.0,
         reqs ? (double)cyc / reqs * out : 0.0, (unsigned long long)(peak & 0xff), (unsigned long long)den, (unsigned long long)(mem.ar - ar0),
         (unsigned long long)(mem.stall_cycles - st0), (unsigned long long)mem.stall_max, ck == sw ? "ok" : "MISMATCH", ok ? "PASS" : "FAIL");
  fflush(stdout);
  return ok;
}

// ---- abort-drain ---------------------------------------------------------------------------------------------------
static bool balanced() { return mem.ar == mem.rlast && mem.out_r() == 0; }
static struct {
  bool armed = false, check_claim = false, claimed = false, violation = false;
  uint64_t claim_cyc = 0, claim_out = 0, max_stall = 0;
} orc;
static void oracle_hook() {
  if (!orc.armed) return;
  orc.max_stall = std::max(orc.max_stall, mem.stall_run);
  if (orc.check_claim && !orc.claimed && top->tb_inflight == 0) {
    orc.claimed = true; orc.claim_cyc = cyc1; orc.claim_out = mem.out_r() + (mem.ar - mem.rlast > mem.out_r() ? 0 : 0);
    if (!balanced()) { orc.violation = true; orc.claim_out = mem.ar - mem.rlast; }
  }
}

static int abort_test(unsigned blocks, const std::string &mode, unsigned reset_cycles, bool rdrop, unsigned hold_after, unsigned abort_after, unsigned stall_min) {
  uint64_t sw = setup(BUF, blocks);
  wr(0x010, 8); wr(0x008, 1); wr(0x000, 1);
  // (a) mid-stream: abort_after Gets delivered, and running at 8 in flight
  uint64_t rl0 = mem.rlast;
  for (int i = 0; i < 400000 && (mem.rlast - rl0 < abort_after || mem.out_r() < 6); i++) tick0();
  uint64_t done_before = mem.rlast - rl0;
  // (b) back-pressure R: stall the lane's D path until RREADY is low with RVALID high at the pins
  top->tb_dhold = 1;
  bool pre = false;
  for (uint64_t e = cyc1 + 4000; cyc1 < e; ) { tick0(); if (mem.stall_run >= stall_min && mem.out_r() >= 4) { pre = true; break; } }
  unsigned pre_out = mem.out_r(); uint64_t pre_stall = mem.stall_run; unsigned pre_inflight = top->tb_inflight;
  if (!pre) {
    printf("WLANETB abort mode=%s PRECONDITION NOT MET: out=%u stall_run=%llu\n", mode.c_str(), pre_out, (unsigned long long)pre_stall);
    return 5;
  }
  // (c) the abort, issued while R is back-pressured
  uint64_t ar_at_abort, abort_cyc; unsigned at_out, at_beat = 0; bool at_stalled, at_act = false;
  if (mode == "gate") {
    wr(0x010, 0);                                   // tb_dhold still 1: the write lands while RREADY is low
    at_out = mem.out_r(); at_stalled = mem.stall_run > 0; at_act = mem.act; at_beat = mem.beat;
    ar_at_abort = mem.ar; abort_cyc = cyc1;
    if (hold_after) run_lane_cycles(hold_after);
    top->tb_dhold = 0; top->tb_rdrop = rdrop;
  } else {
    at_out = mem.out_r(); at_stalled = mem.stall_run > 0; at_act = mem.act; at_beat = mem.beat;
    top->rst0 = 1; top->rst1 = 1; top->tb_dhold = 0; top->tb_rdrop = rdrop;
    ar_at_abort = mem.ar; abort_cyc = cyc1;
  }
  orc = {}; orc.armed = true; orc.check_claim = mode == "gate"; clk1_hook = oracle_hook;
  uint64_t in_reset_stall = 0;
  if (mode == "reset") {
    uint64_t st0 = mem.stall_cycles;
    run_lane_cycles(reset_cycles);
    in_reset_stall = mem.stall_cycles - st0;
    top->rst0 = 0; top->rst1 = 0;
  }
  // (d) drain window
  uint64_t quiet_since = cyc1, last_act = mem.ar + mem.rbeats, deadline = cyc1 + 30000;
  while (cyc1 < deadline) {
    tick0();
    uint64_t act = mem.ar + mem.rbeats;
    if (act != last_act) { last_act = act; quiet_since = cyc1; }
    if (balanced() && cyc1 - quiet_since > 2000) break;
  }
  clk1_hook = nullptr; orc.armed = false;
  unsigned end_inflight = top->tb_inflight;
  bool drained = balanced() && mem.stall_run == 0 && !orc.violation && (mode != "gate" || end_inflight == 0);
  std::string why;
  if (!balanced()) why += " pins_outstanding";
  if (mem.stall_run) why += " rvalid_held_against_rready";
  if (orc.violation) why += " lane_claimed_drained_with_bursts_outstanding";
  if (mode == "gate" && end_inflight) why += " lane_inflight_nonzero";
  if (mode == "reset" && end_inflight) why += " (pins drained; lane in-flight counter corrupt after reset)";
  printf("WLANETB abort mode=%s%s lat=%u p1=%.3fns rdrop=%d hold_after=%u pre: gets_done=%llu/%u out=%u rstall_run=%llu inflight=%u | at_abort: out=%u r_backpressured=%d burst_beat=%s | "
         "end: ar=%llu rlast=%llu held=%u inflight=%u new_ar_after_abort=%llu max_rstall_after_abort=%llu%s claim=%s | %s%s\n",
         mode.c_str(), mode == "reset" ? (" reset_cycles=" + std::to_string(reset_cycles)).c_str() : "", mem.lat, 2.0 * H1 / 1000.0, (int)rdrop, hold_after,
         (unsigned long long)done_before, blocks, pre_out, (unsigned long long)pre_stall, pre_inflight, at_out, (int)at_stalled, at_act ? (std::to_string(at_beat) + "/8").c_str() : "none",
         (unsigned long long)mem.ar, (unsigned long long)mem.rlast, mem.out_r(), end_inflight, (unsigned long long)(mem.ar - ar_at_abort),
         (unsigned long long)orc.max_stall,
         mode == "reset" ? (" rready_low_cycles_in_reset=" + std::to_string(in_reset_stall)).c_str() : "",
         !orc.check_claim ? "n/a" : orc.violation ? ("VIOLATION(outstanding=" + std::to_string(orc.claim_out) + ")").c_str() : orc.claimed ? "ok" : "never",
         drained ? "DRAINED" : "NOT DRAINED:", why.c_str());
  fflush(stdout);
  (void)abort_cyc;
  // (e) resume
  top->tb_rdrop = 0;
  bool resumed;
  if (mode == "gate") {
    wr(0x010, 8);
    bool idle = wait_idle(50ULL * blocks + 100000);
    uint64_t beats = rd(0x028), ck = rd(0x038), reqs = rd(0x030);
    resumed = idle && beats == 8ULL * blocks && reqs == blocks && ck == sw;
    printf("WLANETB resume mode=gate words=%llu expected=%llu reqs=%llu idle=%d cksum=%s -> %s\n", (unsigned long long)beats,
           (unsigned long long)(8ULL * blocks), (unsigned long long)reqs, (int)idle, ck == sw ? "ok" : "MISMATCH", resumed ? "RESUME OK" : "RESUME FAILED");
  } else {
    for (int i = 0; i < 40; i++) tick0();
    uint64_t sw2 = setup(BUF2, blocks);
    wr(0x010, 8); wr(0x008, 1);
    uint64_t ar0 = mem.ar;
    wr(0x000, 1);
    bool idle = wait_idle(50ULL * blocks + 100000);
    uint64_t beats = rd(0x028), ck = rd(0x038), reqs = rd(0x030);
    resumed = idle && beats == 8ULL * blocks && reqs == blocks && ck == sw2 && mem.ar - ar0 == blocks && balanced();
    printf("WLANETB resume mode=reset fresh_descriptor words=%llu expected=%llu reqs=%llu ar=%llu idle=%d cksum=%s -> %s\n", (unsigned long long)beats,
           (unsigned long long)(8ULL * blocks), (unsigned long long)reqs, (unsigned long long)(mem.ar - ar0), (int)idle, ck == sw2 ? "ok" : "MISMATCH",
           resumed ? "RESUME OK" : "RESUME FAILED");
  }
  fflush(stdout);
  return drained && resumed ? 0 : 1;
}

// ---- out of window: does anything on the SoC side stop a Get outside the weight window? ---------------------------
static int oow_test() {
  setup(WIN_END, 4);
  wr(0x010, 8); wr(0x008, 1); wr(0x000, 1);
  bool idle = wait_idle(100000);
  printf("WLANETB oow src=0x%llx idle=%d ar=%llu contract_bad=%llu denied=%llu\n", (unsigned long long)WIN_END, (int)idle,
         (unsigned long long)mem.ar, (unsigned long long)mem.contract_bad, (unsigned long long)rd(0x040));
  return 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  unsigned lat = 20, blocks = 4096, reset_cycles = 64, hold_after = 0, abort_after = 1024, stall_min = 16; bool rdrop = false;
  std::string outs = "1,2,4,8", mode = "gate"; std::vector<std::string> tests;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--blocks") && i + 1 < argc) blocks = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--outs") && i + 1 < argc) outs = argv[++i];
    else if (!strcmp(argv[i], "--p0") && i + 1 < argc) H0 = atoll(argv[++i]) / 2;
    else if (!strcmp(argv[i], "--p1") && i + 1 < argc) H1 = atoll(argv[++i]) / 2;
    else if (!strcmp(argv[i], "--abort") && i + 1 < argc) mode = argv[++i];
    else if (!strcmp(argv[i], "--reset-cycles") && i + 1 < argc) reset_cycles = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--hold-after") && i + 1 < argc) hold_after = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--rdrop")) rdrop = true;
    else if (!strcmp(argv[i], "--abort-after") && i + 1 < argc) abort_after = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--stall-min") && i + 1 < argc) stall_min = atoi(argv[++i]);
    else if (argv[i][0] != '+') tests.push_back(argv[i]);
  }
  next0 = H0; next1 = H1;
  top = new Vwlanetb_top;
  mem.lat = lat;
  top->mmio_a_valid = 0; top->mmio_d_ready = 1; top->tb_dhold = 0; top->tb_rdrop = 0;
  top->rst0 = 1; top->rst1 = 1;
  for (int i = 0; i < 40; i++) tick0();
  top->rst0 = 0; top->rst1 = 0;
  for (int i = 0; i < 40; i++) tick0();
  uint64_t geo = rd(0x050);
  printf("WLANETB geometry=0x%llx lanes=%llu depth=%llu get=%llu FCLK0=%.4fMHz FCLK1=%.4fMHz lat=%u\n", (unsigned long long)geo,
         (unsigned long long)((geo >> 8) & 0xff), (unsigned long long)(geo & 0xff), (unsigned long long)((geo >> 16) & 0xffff),
         1e6 / (2.0 * H0), 1e6 / (2.0 * H1), lat);
  std::vector<int> ov; { std::string o = outs; for (char *t = strtok(&o[0], ","); t; t = strtok(nullptr, ",")) ov.push_back(atoi(t)); }
  int rc = 0;
  for (auto &t : tests) {
    if (t == "sweep") { for (int o : ov) if (!point(o, blocks)) rc = 1; }
    else if (t == "abort") { int r = abort_test(blocks, mode, reset_cycles, rdrop, hold_after, abort_after, stall_min); if (r) rc = r; }
    else if (t == "oow") oow_test();
    else { fprintf(stderr, "unknown test %s\n", t.c_str()); return 2; }
  }
  printf("WLANETB arlen");
  for (int l = 0; l < 256; l++) if (mem.arlen[l]) printf(" len%d(%d beats)=%llu", l, l + 1, (unsigned long long)mem.arlen[l]);
  printf("\nWLANETB end cyc0=%llu cyc1=%llu pins ar=%llu rlast=%llu contract_bad=%llu awvalid_cycles=%llu wvalid_cycles=%llu protocol_errors=%llu -> %s\n",
         (unsigned long long)cyc0, (unsigned long long)cyc1, (unsigned long long)mem.ar, (unsigned long long)mem.rlast,
         (unsigned long long)mem.contract_bad, (unsigned long long)mem.aw_valid_cycles, (unsigned long long)mem.w_valid_cycles,
         (unsigned long long)protocol_errors, rc == 0 && protocol_errors == 0 ? "PASS" : "FAIL");
  delete top;
  return protocol_errors ? (rc ? rc : 1) : rc;
}
