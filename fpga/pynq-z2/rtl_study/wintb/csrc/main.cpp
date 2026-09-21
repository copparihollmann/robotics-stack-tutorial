// SIMULATION ONLY.  The generated system bus and memory bus of PynqZ2RocketBigLittlePextTacitMicRgbBwWinConfig,
// on TWO clocks, against a behavioural AXI4 memory per channel.  MEMORY_BANDWIDTH.md section 9.
//
//   Vwintb_top [--lat L] [--cap C] [--rows N] [--p0 ps] [--p1 ps] <test> ...
//
// tests:  win     BwWindow's 128-bit core-clock lanes: sets L0 L2 L01 L012 L0123 SEQ x in-flight sweep
//         ap      BwProbe (64-bit, core clock) through the DMA aperture, in-flight sweep
//         tile    8-byte Gets and Puts on tile 0's master port through the aperture: round trip per request
//         drain   abort-drain: lanes at 8 in flight, issuing stopped mid-run, every AXI transaction must
//                 complete with nothing held; then resumed to completion with the checksum checked
//         lsweep  WIN_L0 at 1 in flight for several memory latencies (the latency law)
//
// The memory: AR/AW accepted while fewer than C transactions of that direction are outstanding on the
// channel; a read burst's first beat is eligible L memory-bus cycles after its AR handshake, a B is
// eligible L cycles after WLAST; bursts are returned one at a time in eligibility order, one beat per
// cycle, and HELD while RREADY is low (the AXI rule; the longest such hold is reported, because a
// core-clock lane consumes 16 B per FCLK0 cycle and a port supplies 8 B per FCLK1 cycle).  Unwritten
// data is a function of address; written data is remembered.  Protocol checks: AR/AW shape, RVALID and
// BVALID never withdrawn by the model, W only for an accepted AW, WLAST on the right beat.
#include "Vwintb_top.h"
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

static Vwintb_top *top;
static uint64_t t_ps = 0, H0 = 14500, H1 = 5000;   // half periods: FCLK0 = 1000/29 MHz, FCLK1 = 100 MHz
static uint64_t next0, next1;
static bool c0 = false, c1 = false;
static uint64_t cyc0 = 0, cyc1 = 0;

static uint64_t word_at(uint64_t addr) {
  uint64_t x = addr * 0x9E3779B97F4A7C15ULL;
  x ^= x >> 29; x *= 0xBF58476D1CE4E5B9ULL; x ^= x >> 32;
  return x;
}
static std::map<uint64_t, uint64_t> written;
static uint64_t mem_word(uint64_t a) { auto it = written.find(a); return it == written.end() ? word_at(a) : it->second; }

// ---- per-channel AXI4 memory, clocked by clk1 ------------------------------------------------------
struct RB { uint8_t id; uint64_t addr; unsigned beats; uint64_t ready_at; };
struct WB { uint8_t id; uint64_t addr; unsigned beats; unsigned got; bool done; uint64_t b_at; };
struct Mem {
  int ch; unsigned lat = 20, cap = 8;
  std::deque<RB> pend; bool act = false; RB cur{}; unsigned beat = 0;
  std::deque<WB> wq;        // accepted AWs in order
  uint64_t ar = 0, rlast = 0, aw = 0, bfire = 0, rbeats = 0, stall = 0, stall_max = 0, stall_cycles = 0;
  uint64_t arlen[16] = {0};   // AR bursts by ARLEN: the burst length the PS actually sees
  unsigned out_r() const { return pend.size() + (act ? 1 : 0); }
  unsigned out_w() const { return wq.size(); }
};
static Mem mems[4];
static uint64_t protocol_errors = 0;
static void perr(const char *msg, int ch) {
  if (protocol_errors < 20) fprintf(stderr, "PROTOCOL ch%d: %s (cyc1=%llu)\n", ch, msg, (unsigned long long)cyc1);
  protocol_errors++;
}

#define CH(c, f) ((c) == 0 ? top->axi0_##f : (c) == 1 ? top->axi1_##f : (c) == 2 ? top->axi2_##f : top->axi3_##f)
#define CHSET(c, f, v) do { switch (c) { case 0: top->axi0_##f = (v); break; case 1: top->axi1_##f = (v); break; \
                                          case 2: top->axi2_##f = (v); break; default: top->axi3_##f = (v); } } while (0)

static void mem_drive(Mem &m) {
  int c = m.ch;
  CHSET(c, ar_ready, m.out_r() < m.cap);
  CHSET(c, aw_ready, m.out_w() < m.cap);
  // W is accepted for the oldest AW whose data is not complete
  bool wopen = false; for (auto &w : m.wq) if (!w.done) { wopen = true; break; }
  CHSET(c, w_ready, wopen);
  if (!m.act) {
    for (size_t i = 0; i < m.pend.size(); i++)
      if (m.pend[i].ready_at <= cyc1) { m.cur = m.pend[i]; m.pend.erase(m.pend.begin() + i); m.act = true; m.beat = 0; break; }
  }
  if (m.act) {
    CHSET(c, r_valid, 1); CHSET(c, r_bits_id, m.cur.id);
    CHSET(c, r_bits_data, mem_word(m.cur.addr + 8ULL * m.beat));
    CHSET(c, r_bits_resp, 0); CHSET(c, r_bits_last, m.beat + 1 == m.cur.beats);
  } else { CHSET(c, r_valid, 0); CHSET(c, r_bits_last, 0); }
  bool bv = !m.wq.empty() && m.wq.front().done && m.wq.front().b_at <= cyc1;
  CHSET(c, b_valid, bv);
  if (bv) { CHSET(c, b_bits_id, m.wq.front().id); CHSET(c, b_bits_resp, 0); }
}

struct Hs { bool ar, r, aw, w, b, rv; uint8_t arid, awid; uint64_t araddr, awaddr, wdata; unsigned arlen, arsize, arburst, awlen, awsize, awburst, wstrb; bool wlast; };
static Hs mem_sample(Mem &m) {
  int c = m.ch; Hs h{};
  h.ar = CH(c, ar_valid) && CH(c, ar_ready); h.arid = CH(c, ar_bits_id); h.araddr = CH(c, ar_bits_addr);
  h.arlen = CH(c, ar_bits_len); h.arsize = CH(c, ar_bits_size); h.arburst = CH(c, ar_bits_burst);
  h.r = CH(c, r_valid) && CH(c, r_ready); h.rv = CH(c, r_valid);
  h.aw = CH(c, aw_valid) && CH(c, aw_ready); h.awid = CH(c, aw_bits_id); h.awaddr = CH(c, aw_bits_addr);
  h.awlen = CH(c, aw_bits_len); h.awsize = CH(c, aw_bits_size); h.awburst = CH(c, aw_bits_burst);
  h.w = CH(c, w_valid) && CH(c, w_ready); h.wdata = CH(c, w_bits_data); h.wstrb = CH(c, w_bits_strb); h.wlast = CH(c, w_bits_last);
  h.b = CH(c, b_valid) && CH(c, b_ready);
  return h;
}
static void mem_update(Mem &m, const Hs &h) {
  if (h.ar) {
    if (h.arsize != 3 || h.arburst != 1 || (h.arlen != 7 && h.arlen != 0)) perr("AR shape", m.ch);
    m.pend.push_back(RB{h.arid, h.araddr, h.arlen + 1, cyc1 + m.lat}); m.ar++; m.arlen[h.arlen & 15]++;
  }
  if (h.rv && !h.r) { m.stall++; m.stall_cycles++; m.stall_max = std::max(m.stall_max, m.stall); } else m.stall = 0;
  if (h.r) { m.rbeats++; if (++m.beat == m.cur.beats) { m.act = false; m.rlast++; } }
  if (h.aw) {
    if (h.awsize != 3 || h.awburst != 1 || h.awlen != 0) perr("AW shape", m.ch);
    m.wq.push_back(WB{h.awid, h.awaddr, h.awlen + 1, 0, false, 0}); m.aw++;
  }
  if (h.w) {
    WB *w = nullptr; for (auto &x : m.wq) if (!x.done) { w = &x; break; }
    if (!w) perr("W without AW", m.ch);
    else {
      if (h.wstrb != 0xff) perr("partial WSTRB", m.ch);
      written[w->addr + 8ULL * w->got] = h.wdata;
      w->got++;
      if (h.wlast != (w->got == w->beats)) perr("WLAST", m.ch);
      if (w->got == w->beats) { w->done = true; w->b_at = cyc1 + m.lat; }
    }
  }
  if (h.b) { m.wq.pop_front(); m.bfire++; }
}

// ---- time -------------------------------------------------------------------------------------------
// Advance to (and through) the next clk0 rising edge; every clk1 edge on the way is processed with the
// memory models.  The caller has set its clk0-domain inputs and sampled its handshakes beforehand.
static void tick0() {
  for (;;) {
    uint64_t t = std::min(next0, next1);
    bool e0 = next0 == t, e1 = next1 == t;
    bool r0 = e0 && !c0, r1 = e1 && !c1;
    Hs h[4];
    if (r1) { for (auto &m : mems) mem_drive(m); top->eval(); for (int c = 0; c < 4; c++) h[c] = mem_sample(mems[c]); }
    t_ps = t;
    if (e0) { c0 = !c0; top->clk0 = c0; next0 += H0; }
    if (e1) { c1 = !c1; top->clk1 = c1; next1 += H1; }
    top->eval();
    if (r1) { for (int c = 0; c < 4; c++) mem_update(mems[c], h[c]); cyc1++; for (auto &m : mems) mem_drive(m); top->eval(); }
    if (r0) { cyc0++; return; }
  }
}

// ---- TL-UL register access, clk0 domain -------------------------------------------------------------
enum Port { WIN, PRB };
static uint64_t tl(Port pt, bool put, uint64_t addr, uint64_t data) {
  #define PS(f, v) do { if (pt == WIN) top->win_##f = (v); else top->prb_##f = (v); } while (0)
  #define PG(f) (pt == WIN ? top->win_##f : top->prb_##f)
  PS(a_valid, 1); PS(a_bits_opcode, put ? 0 : 4); PS(a_bits_param, 0); PS(a_bits_size, 3); PS(a_bits_source, 0);
  PS(a_bits_address, addr); PS(a_bits_mask, 0xff); PS(a_bits_data, put ? data : 0); PS(a_bits_corrupt, 0); PS(d_ready, 1);
  // The register node can answer in the cycle it accepts (D valid with A fire), so D is sampled
  // alongside A: a response taken at the same edge must not be waited for again.
  for (int i = 0;; i++) {
    top->eval(); bool acc = PG(a_ready); bool got = PG(d_valid); uint64_t d = PG(d_bits_data); tick0();
    if (acc && got) { PS(a_valid, 0); return d; }
    if (acc) break;
    if (i > 100000) { fprintf(stderr, "mmio A never accepted\n"); exit(4); }
  }
  PS(a_valid, 0);
  for (int i = 0;; i++) {
    top->eval(); bool got = PG(d_valid); uint64_t d = PG(d_bits_data); bool den = false; tick0();
    if (got) { if (den) { fprintf(stderr, "mmio denied at 0x%llx\n", (unsigned long long)addr); exit(4); } return d; }
    if (i > 100000) { fprintf(stderr, "mmio D never came\n"); exit(4); }
  }
}
static const uint64_t WBASE = 0x100c0000ULL, PBASE = 0x100a0000ULL;
static void wwr(uint64_t off, uint64_t v) { tl(WIN, true, WBASE + off, v); }
static uint64_t wrd(uint64_t off) { return tl(WIN, false, WBASE + off, 0); }
static void pwr(uint64_t off, uint64_t v) { tl(PRB, true, PBASE + off, v); }
static uint64_t prd(uint64_t off) { return tl(PRB, false, PBASE + off, 0); }

static const uint64_t BUF = 0x82000000ULL, ALIAS = 0x42000000ULL;

static void quiet() { top->win_a_valid = 0; top->prb_a_valid = 0; top->t0_a_valid = 0; top->t0_c_valid = 0; top->t0_e_valid = 0;
                      top->win_d_ready = 1; top->prb_d_ready = 1; top->t0_b_ready = 1; top->t0_d_ready = 1; }

static void snap(uint64_t ar[4], uint64_t rl[4], uint64_t st[4]) {
  for (int c = 0; c < 4; c++) { ar[c] = mems[c].ar; rl[c] = mems[c].rlast; st[c] = mems[c].stall_cycles; mems[c].stall_max = 0; }
}

// ---- BwWindow points --------------------------------------------------------------------------------
struct Set { const char *name; unsigned mask; bool seq; };
static const Set WSETS[] = {{"L0", 1, false}, {"L2", 4, false}, {"L01", 3, false}, {"L012", 7, false},
                            {"L0123", 15, false}, {"SEQ", 1, true}};

static uint64_t win_setup(const Set &s, unsigned rows) {
  uint64_t sw = 0; const uint64_t stride = 256;
  for (unsigned l = 0; l < 4; l++) {
    uint64_t lb = 0x100 + l * 0x40;
    if (s.seq && l == 0) { wwr(lb + 0x00, BUF); wwr(lb + 0x08, rows); wwr(lb + 0x10, 1); wwr(lb + 0x18, 0); }
    else { wwr(lb + 0x00, BUF + l * 64); wwr(lb + 0x08, 1); wwr(lb + 0x10, rows); wwr(lb + 0x18, stride); }
    if (s.mask & (1u << l)) {
      if (s.seq && l == 0) { for (uint64_t b = 0; b < rows; b++) for (int w = 0; w < 8; w++) sw ^= mem_word(BUF + 64 * b + 8 * w); }
      else { for (uint64_t r = 0; r < rows; r++) for (int w = 0; w < 8; w++) sw ^= mem_word(BUF + l * 64 + stride * r + 8 * w); }
    }
  }
  return sw;
}

static void win_point(const Set &s, int out, unsigned rows, const char *tag) {
  uint64_t sw = win_setup(s, rows);
  wwr(0x010, out); wwr(0x008, s.mask);
  uint64_t ar0[4], rl0[4], st0[4]; snap(ar0, rl0, st0);
  uint64_t c1a = cyc1;
  wwr(0x000, 1);
  while (wrd(0x018) & 1) {}
  uint64_t c1b = cyc1;
  uint64_t cyc = wrd(0x020), beats = wrd(0x028), reqs = wrd(0x030), ck = wrd(0x038), den = wrd(0x040), peak = wrd(0x048), db = wrd(0x058);
  double bpc = 8.0 * beats / cyc;
  printf("WINTB %s lat=%u cap=%u set=WIN_%s out=%d cycles=%llu words=%llu dbeats=%llu reqs=%llu bpc=%.4f mbps=%.1f cyc_per_get=%.3f peak=%llu denied=%llu",
         tag, mems[0].lat, mems[0].cap, s.name, out, (unsigned long long)cyc, (unsigned long long)beats, (unsigned long long)db,
         (unsigned long long)reqs, bpc, bpc * 1e6 / (2.0 * H0), (double)cyc * __builtin_popcount(s.mask) / reqs,
         (unsigned long long)peak, (unsigned long long)den);
  for (unsigned l = 0; l < 4; l++) if (s.mask & (1u << l)) {
    uint64_t lb = 0x100 + l * 0x40;
    printf(" lane%u(c=%llu w=%llu r=%llu p=%llu)", l, (unsigned long long)wrd(lb + 0x20), (unsigned long long)wrd(lb + 0x28),
           (unsigned long long)wrd(lb + 0x30), (unsigned long long)(wrd(lb + 0x38) & 0xff));
  }
  printf(" ar=");  for (int c = 0; c < 4; c++) printf("%s%llu", c ? "/" : "", (unsigned long long)(mems[c].ar - ar0[c]));
  printf(" rlast="); for (int c = 0; c < 4; c++) printf("%s%llu", c ? "/" : "", (unsigned long long)(mems[c].rlast - rl0[c]));
  printf(" rstall_cyc1="); for (int c = 0; c < 4; c++) printf("%s%llu", c ? "/" : "", (unsigned long long)(mems[c].stall_cycles - st0[c]));
  printf(" rstall_max="); for (int c = 0; c < 4; c++) printf("%s%llu", c ? "/" : "", (unsigned long long)mems[c].stall_max);
  printf(" width=%s cksum=%s\n", (db * 16 == reqs * 64) ? "16B/beat" : "WRONG", ck == sw ? "ok" : "MISMATCH");
  (void)c1a; (void)c1b;
  fflush(stdout);
}

// ---- BwProbe through the aperture -------------------------------------------------------------------
static void ap_point(int out, unsigned blocks) {
  uint64_t sw = 0;
  for (uint64_t b = 0; b < blocks; b++) for (int w = 0; w < 8; w++) sw ^= mem_word(BUF + 64 * b + 8 * w);
  pwr(0x00, ALIAS); pwr(0x08, blocks); pwr(0x10, 1); pwr(0x18, 0); pwr(0x20, out);
  pwr(0x28, 1);
  while (prd(0x30) & 1) {}
  uint64_t cyc = prd(0x38), beats = prd(0x40), reqs = prd(0x48), ck = prd(0x50), den = prd(0x58), st = prd(0x30);
  double bpc = 8.0 * beats / cyc;
  printf("WINTB ap lat=%u set=AP_PROBE out=%d cycles=%llu words=%llu reqs=%llu bpc=%.4f mbps=%.1f cyc_per_get=%.3f peak=%llu denied=%llu cksum=%s\n",
         mems[0].lat, out, (unsigned long long)cyc, (unsigned long long)beats, (unsigned long long)reqs, bpc, bpc * 1e6 / (2.0 * H0),
         (double)cyc / reqs, (unsigned long long)((st >> 9) & 0xff), (unsigned long long)den, ck == sw ? "ok" : "MISMATCH");
  fflush(stdout);
}

// ---- tile 0 through the aperture: one 8-byte request at a time --------------------------------------
static void tile_test(unsigned n, unsigned src) {
  uint64_t sum_get = 0, sum_put = 0, max_get = 0, max_put = 0, bad = 0;
  for (int phase = 0; phase < 2; phase++) {       // 0: Puts, 1: Gets of what was put
    for (unsigned i = 0; i < n; i++) {
      bool put = phase == 0;
      uint64_t a = ALIAS + 0x100000 + 8ULL * i, pa = BUF + 0x100000 + 8ULL * i;
      uint64_t val = 0xA5A5000000000000ULL ^ (i * 0x1234567ULL);
      top->t0_a_valid = 1; top->t0_a_bits_opcode = put ? 0 : 4; top->t0_a_bits_param = 0; top->t0_a_bits_size = 3;
      top->t0_a_bits_source = src; top->t0_a_bits_address = a; top->t0_a_bits_mask = 0xff; top->t0_a_bits_data = put ? val : 0;
      top->t0_a_bits_corrupt = 0; top->t0_d_ready = 1;
      uint64_t start = cyc0;
      for (int k = 0;; k++) { top->eval(); bool acc = top->t0_a_ready; tick0(); if (acc) break; if (k > 100000) { fprintf(stderr, "tile A stuck\n"); exit(5); } }
      top->t0_a_valid = 0;
      for (int k = 0;; k++) {
        top->eval(); bool got = top->t0_d_valid; uint64_t d = top->t0_d_bits_data; unsigned op = top->t0_d_bits_opcode; bool den = top->t0_d_bits_denied; tick0();
        if (got) {
          uint64_t rt = cyc0 - start;   // A valid raised .. D taken, in FCLK0 cycles
          if (den) bad++;
          if (put) { sum_put += rt; max_put = std::max(max_put, rt); if (op != 0) bad++; if (mem_word(pa) != val) bad++; }
          else     { sum_get += rt; max_get = std::max(max_get, rt); if (op != 1 || d != val) bad++; }
          break;
        }
        if (k > 100000) { fprintf(stderr, "tile D never came\n"); exit(5); }
      }
    }
  }
  printf("WINTB tile lat=%u src=%u n=%u put_rt_avg=%.3f put_rt_max=%llu get_rt_avg=%.3f get_rt_max=%llu bad=%llu (FCLK0 cycles, A valid to D taken)\n",
         mems[0].lat, src, n, (double)sum_put / n, (unsigned long long)max_put, (double)sum_get / n, (unsigned long long)max_get, (unsigned long long)bad);
  fflush(stdout);
}

// ---- abort-drain -----------------------------------------------------------------------------------
static void drain_test(unsigned rows) {
  const Set s = {"L0123", 15, false};
  uint64_t sw = win_setup(s, rows);
  wwr(0x010, 8); wwr(0x008, 15);
  wwr(0x000, 1);
  for (int i = 0; i < 3000; i++) tick0();               // well into the run
  uint64_t ar_at_stop = 0; for (auto &m : mems) ar_at_stop += m.ar;
  wwr(0x010, 0);                                         // stop issuing: in-flight transactions must all finish
  uint64_t quiet_since = cyc1, last_act = 0;
  for (int i = 0; i < 20000; i++) {
    tick0();
    uint64_t act = 0; for (auto &m : mems) act += m.ar + m.rbeats;
    if (act != last_act) { last_act = act; quiet_since = cyc1; }
    if (cyc1 - quiet_since > 2000) break;
  }
  bool balanced = true; uint64_t held = 0, ar = 0, rl = 0;
  for (auto &m : mems) { if (m.ar != m.rlast || m.act || !m.pend.empty()) balanced = false; held += m.out_r(); ar += m.ar; rl += m.rlast; }
  printf("WINTB drain stopped_after_ar=%llu pins: ar=%llu rlast=%llu held_by_memory=%llu status_busy=%llu -> %s\n",
         (unsigned long long)ar_at_stop, (unsigned long long)ar, (unsigned long long)rl, (unsigned long long)held,
         (unsigned long long)(wrd(0x018) & 1), balanced ? "DRAINED" : "NOT DRAINED");
  wwr(0x010, 8);                                         // resume: the run must complete with the right bytes
  while (wrd(0x018) & 1) {}
  uint64_t ck = wrd(0x038), beats = wrd(0x028);
  printf("WINTB drain resumed words=%llu expected=%llu cksum=%s\n", (unsigned long long)beats, (unsigned long long)(rows * 4ULL * 8),
         ck == sw ? "ok" : "MISMATCH");
  fflush(stdout);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  unsigned lat = 20, cap = 8, rows = 1024, tsrc = 1;
  std::string outs = "1,2,3,4,5,6,8", sets = "L0,L2,L01,L012,L0123,SEQ", lats = "5,10,20,30,40";
  std::vector<std::string> tests;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--cap") && i + 1 < argc) cap = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--rows") && i + 1 < argc) rows = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--outs") && i + 1 < argc) outs = argv[++i];
    else if (!strcmp(argv[i], "--sets") && i + 1 < argc) sets = argv[++i];
    else if (!strcmp(argv[i], "--lats") && i + 1 < argc) lats = argv[++i];
    else if (!strcmp(argv[i], "--tsrc") && i + 1 < argc) tsrc = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--p0") && i + 1 < argc) H0 = atoll(argv[++i]) / 2;
    else if (!strcmp(argv[i], "--p1") && i + 1 < argc) H1 = atoll(argv[++i]) / 2;
    else if (argv[i][0] != '+') tests.push_back(argv[i]);
  }
  next0 = H0; next1 = H1;
  top = new Vwintb_top;
  for (int c = 0; c < 4; c++) { mems[c].ch = c; mems[c].lat = lat; mems[c].cap = cap; }
  quiet();
  top->rst0 = 1; top->rst1 = 1;
  for (int i = 0; i < 40; i++) tick0();
  top->rst0 = 0; top->rst1 = 0;
  for (int i = 0; i < 40; i++) tick0();
  uint64_t geo = wrd(0x050);
  printf("WINTB geometry=0x%llx laneBytes=%llu tag=0x%llx get=%llu lanes=%llu depth=%llu FCLK0=%.4fMHz FCLK1=%.4fMHz\n",
         (unsigned long long)geo, (unsigned long long)((geo >> 40) & 0xff), (unsigned long long)((geo >> 32) & 0xff),
         (unsigned long long)((geo >> 16) & 0xffff), (unsigned long long)((geo >> 8) & 0xff), (unsigned long long)(geo & 0xff),
         1e6 / (2.0 * H0), 1e6 / (2.0 * H1));
  std::vector<int> ov; { std::string o = outs; for (char *t = strtok(&o[0], ","); t; t = strtok(nullptr, ",")) ov.push_back(atoi(t)); }
  std::vector<std::string> sv; { std::string o = sets; for (char *t = strtok(&o[0], ","); t; t = strtok(nullptr, ",")) sv.push_back(t); }
  std::vector<int> lv; { std::string o = lats; for (char *t = strtok(&o[0], ","); t; t = strtok(nullptr, ",")) lv.push_back(atoi(t)); }
  for (auto &t : tests) {
    if (t == "win") { for (auto &sn : sv) for (auto &s : WSETS) if (sn == s.name) for (int o : ov) win_point(s, o, rows, "win"); }
    else if (t == "ap") { for (int o : ov) ap_point(o, rows * 4); }
    else if (t == "tile") { tile_test(256, tsrc); }
    else if (t == "drain") { drain_test(rows); }
    else if (t == "lsweep") {
      for (int L : lv) { for (auto &m : mems) m.lat = L; win_point(WSETS[0], 1, rows / 4 + 1, "lsweep"); win_point(WSETS[0], 8, rows, "lsweep"); }
      for (auto &m : mems) m.lat = lat;
    }
    else { fprintf(stderr, "unknown test %s\n", t.c_str()); return 2; }
  }
  uint64_t ar = 0, rl = 0, aw = 0, b = 0; for (auto &m : mems) { ar += m.ar; rl += m.rlast; aw += m.aw; b += m.bfire; }
  printf("WINTB arlen");
  for (int c = 0; c < 4; c++) for (int l = 0; l < 16; l++) if (mems[c].arlen[l]) printf(" ch%d:len%d(%d beats)=%llu", c, l, l + 1, (unsigned long long)mems[c].arlen[l]);
  printf("\n");
  printf("WINTB end cyc0=%llu cyc1=%llu pins ar=%llu rlast=%llu aw=%llu b=%llu protocol_errors=%llu\n",
         (unsigned long long)cyc0, (unsigned long long)cyc1, (unsigned long long)ar, (unsigned long long)rl,
         (unsigned long long)aw, (unsigned long long)b, (unsigned long long)protocol_errors);
  delete top;
  return protocol_errors ? 1 : 0;
}
