// SIMULATION ONLY.  One DRAM Put and one Get through 0x5A5A0018's memory port as built after
// f7f01e0 -- the generated TLWidthWidget16_3 (128 -> 64) + TLToAXI4 + AXI4IdIndexer +
// AXI4UserYanker, then src/axi4_to_axi3.v and the top level's address fold -- with every data
// word checked at ChipTop's AXI4 port and in the S_AXI_HP0 memory, then saturating Get and Put
// streams to measure what the 64-bit leg can carry per memory-bus cycle.
//
//   ./obj/Vwidthtb_top [--blocks N] [--rlat C] [--stall]
//
// Clock: one cycle here is one memory-bus cycle (FCLK1 in 0x5A5A0018/0019).  The AXI3 slave
// is an ideal S_AXI_HP0: AW/AR always ready, first R beat --rlat cycles after AR (default 1),
// then one beat per cycle, and W always ready once its AW is in.  --stall makes HP0's R/W and
// the TileLink D ready toggle pseudo-randomly, for data integrity under back-pressure.
#include "Vwidthtb_top.h"
#include "verilated.h"
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <vector>

static Vwidthtb_top *top;
static uint64_t cyc = 0;
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { if (fails < 20) { printf("FAIL cyc=%" PRIu64 ": ", cyc); printf(__VA_ARGS__); printf("\n"); } fails++; } } while (0)

static uint64_t pattern(uint64_t ddr_addr) { return ddr_addr * 0x9E3779B97F4A7C15ULL ^ 0x5A5A00185A5A0018ULL; }

// ---- S_AXI_HP0 ----------------------------------------------------------------------------
struct Burst { uint32_t id; uint64_t addr; unsigned len, k; uint64_t ready_at; };
static std::map<uint64_t, uint64_t> mem;
static std::deque<Burst> awq, arq;
static std::deque<uint32_t> bq;
static unsigned rlat = 1;
static bool stall = false;
static uint64_t lcg = 12345;
static bool coin() { lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL; return (lcg >> 33) & 1; }
static uint64_t memrd(uint64_t a) { auto it = mem.find(a); return it == mem.end() ? pattern(a) : it->second; }

// ---- TileLink master ------------------------------------------------------------------------
struct ABeat { unsigned opcode, size, source; uint32_t address; uint16_t mask; uint64_t lo, hi; };
static std::deque<ABeat> aq;
struct Pending { unsigned opcode; uint32_t address; unsigned beats_seen; uint64_t t_a; };
static std::map<unsigned, Pending> inflight;   // by source
static uint64_t d_data_beats = 0, d_bytes = 0, done_ops = 0, lat_max = 0, lat_sum = 0;
static uint64_t t_first_a = 0, t_last_d = 0;

// ---- AXI4-side observation (ChipTop.axi4_mem_0) -------------------------------------------
static std::vector<uint64_t> x_wwords;
static unsigned x_ar_bad = 0, x_aw_bad = 0, x_w_bad = 0, x_ar_n = 0, x_aw_n = 0;

static uint32_t tl_to_ddr(uint32_t a) { return 0x10000000u | (a & 0x0FFFFFFFu); }

static void set128(VlWide<4> &w, uint64_t lo, uint64_t hi) {
  w[0] = (uint32_t)lo; w[1] = (uint32_t)(lo >> 32); w[2] = (uint32_t)hi; w[3] = (uint32_t)(hi >> 32);
}
static void get128(const VlWide<4> &w, uint64_t &lo, uint64_t &hi) {
  lo = (uint64_t)w[0] | ((uint64_t)w[1] << 32); hi = (uint64_t)w[2] | ((uint64_t)w[3] << 32);
}

static void cycle(bool d_ready_forced = true) {
  // 1. drive
  if (!aq.empty()) {
    const ABeat &b = aq.front();
    top->a_valid = 1; top->a_opcode = b.opcode; top->a_size = b.size; top->a_source = b.source;
    top->a_address = b.address; top->a_mask = b.mask; set128(top->a_data, b.lo, b.hi);
  } else {
    top->a_valid = 0;
  }
  top->d_ready = stall ? coin() : d_ready_forced;
  top->h_awready = 1;
  top->h_arready = 1;
  top->h_wready = !awq.empty() && (!stall || coin());
  top->h_bvalid = !bq.empty();
  top->h_bid = bq.empty() ? 0 : bq.front();
  top->h_bresp = 0;
  bool rv = !arq.empty() && cyc >= arq.front().ready_at && (!stall || coin());
  top->h_rvalid = rv;
  if (!arq.empty()) {
    Burst &r = arq.front();
    top->h_rid = r.id; top->h_rdata = memrd(r.addr + 8ULL * r.k); top->h_rlast = (r.k + 1 == r.len);
  } else {
    top->h_rid = 0; top->h_rdata = 0; top->h_rlast = 0;
  }
  top->h_rresp = 0;
  top->clock = 0; top->eval();

  // 2. sample fires (before the edge)
  bool a_fire = top->a_valid && top->a_ready;
  bool d_fire = top->d_valid && top->d_ready;
  bool haw = top->h_awvalid && top->h_awready, hw = top->h_wvalid && top->h_wready;
  bool hb = top->h_bvalid && top->h_bready, har = top->h_arvalid && top->h_arready;
  bool hr = top->h_rvalid && top->h_rready;
  bool xar = top->x_arvalid && top->x_arready, xaw = top->x_awvalid && top->x_awready;
  bool xw = top->x_wvalid && top->x_wready, xr = top->x_rvalid && top->x_rready;
  uint32_t awid = top->h_awid, awaddr = top->h_awaddr, arid = top->h_arid, araddr = top->h_araddr;
  unsigned awlen = top->h_awlen, arlen = top->h_arlen, wid = top->h_wid;
  uint64_t wdata = top->h_wdata; unsigned wstrb = top->h_wstrb; bool wlast = top->h_wlast;
  unsigned d_op = top->d_opcode, d_src = top->d_source, d_den = top->d_denied;
  uint64_t dlo, dhi; get128(top->d_data, dlo, dhi);

  if (xar) { x_ar_n++; if (top->x_arsize != 3 || top->x_arlen != 7 || top->x_arburst != 1) { x_ar_bad++;
      CHECK(0, "AXI4 AR size=%u len=%u burst=%u (want 3, 7, INCR)", top->x_arsize, top->x_arlen, top->x_arburst); } }
  if (xaw) { x_aw_n++; if (top->x_awsize != 3 || top->x_awlen != 7 || top->x_awburst != 1) { x_aw_bad++;
      CHECK(0, "AXI4 AW size=%u len=%u burst=%u (want 3, 7, INCR)", top->x_awsize, top->x_awlen, top->x_awburst); } }
  if (xw) { x_wwords.push_back(top->x_wdata); if (top->x_wstrb != 0xFF) { x_w_bad++; CHECK(0, "AXI4 WSTRB=%02x", top->x_wstrb); } }
  if (xr) CHECK(top->x_rdata == top->h_rdata, "AXI4 RDATA differs from HP0 RDATA");
  CHECK(!top->err_burst_too_long, "shim: burst too long for AXI3");

  // 3. edge
  top->clock = 1; top->eval();
  cyc++;

  // 4. models
  if (a_fire) {
    ABeat b = aq.front(); aq.pop_front();
    if (!t_first_a) t_first_a = cyc;
    if (!inflight.count(b.source)) inflight[b.source] = Pending{b.opcode, b.address, 0, cyc};
  }
  if (haw) { awq.push_back(Burst{awid, awaddr, awlen + 1, 0, 0}); }
  if (hw) {
    Burst &w = awq.front();
    CHECK(wid == w.id, "HP0 WID %u != AWID %u", wid, w.id);
    uint64_t a = w.addr + 8ULL * w.k, old = memrd(a), v = 0;
    for (int i = 0; i < 8; i++) v |= (((wstrb >> i) & 1) ? wdata : old) & (0xFFULL << (8 * i));
    mem[a] = v;
    w.k++;
    CHECK(wlast == (w.k == w.len), "HP0 WLAST at beat %u of %u", w.k, w.len);
    if (w.k == w.len) { bq.push_back(w.id); awq.pop_front(); }
  }
  if (hb) bq.pop_front();
  if (har) arq.push_back(Burst{arid, araddr, arlen + 1, 0, cyc + (rlat ? rlat - 1 : 0)});
  if (hr) { Burst &r = arq.front(); r.k++; if (r.k == r.len) arq.pop_front(); }
  if (d_fire) {
    auto it = inflight.find(d_src);
    CHECK(it != inflight.end(), "D for source %u with nothing in flight", d_src);
    CHECK(!d_den, "D denied");
    if (it != inflight.end()) {
      Pending &p = it->second;
      if (p.opcode == 4) {            // Get -> AccessAckData, 4 beats of 16 bytes
        CHECK(d_op == 1, "Get answered with opcode %u", d_op);
        uint64_t a = tl_to_ddr(p.address) + 16ULL * p.beats_seen;
        CHECK(dlo == memrd(a) && dhi == memrd(a + 8),
              "Get src %u beat %u: D %016" PRIx64 "_%016" PRIx64 " want %016" PRIx64 "_%016" PRIx64,
              d_src, p.beats_seen, dhi, dlo, memrd(a + 8), memrd(a));
        p.beats_seen++; d_data_beats++; d_bytes += 16;
        if (p.beats_seen == 4) {
          uint64_t l = cyc - p.t_a; lat_sum += l; if (l > lat_max) lat_max = l;
          inflight.erase(it); done_ops++; t_last_d = cyc;
        }
      } else {                         // PutFullData -> AccessAck
        CHECK(d_op == 0, "Put answered with opcode %u", d_op);
        uint64_t l = cyc - p.t_a; lat_sum += l; if (l > lat_max) lat_max = l;
        inflight.erase(it); done_ops++; t_last_d = cyc;
      }
    }
  }
}

static void put64(unsigned src, uint32_t addr, const uint64_t w[8]) {
  for (int i = 0; i < 4; i++) aq.push_back(ABeat{0, 6, src, addr, 0xFFFF, w[2 * i], w[2 * i + 1]});
}
static void get64(unsigned src, uint32_t addr) { aq.push_back(ABeat{4, 6, src, addr, 0xFFFF, 0, 0}); }
static bool run_until_idle(uint64_t limit) {
  for (uint64_t i = 0; i < limit; i++) {
    cycle();
    if (aq.empty() && inflight.empty() && awq.empty() && arq.empty() && bq.empty()) return true;
  }
  return false;
}
static void reset_stats() { d_data_beats = d_bytes = done_ops = lat_max = lat_sum = 0; t_first_a = t_last_d = 0; }

// A saturating stream: `blocks` 64-byte operations, `par` in flight (distinct sources).
// Sources spread over every source the L2's outer edge may use (SRC_N, read by build.sh from the
// widget's TLMonitor: 10 at 7 MSHRs, 20 at 12).  At 12 MSHRs some are >= 16 and reach
// AXI4IdIndexer's extra echo bit, which 4-bit AXI IDs cannot carry.
static unsigned src_of(unsigned s) { return s * SRC_N / 8; }
static void stream(bool puts, unsigned blocks, unsigned par, uint32_t base) {
  reset_stats();
  unsigned next = 0;
  uint64_t guard = 0;
  while ((next < blocks || !inflight.empty() || !aq.empty()) && guard++ < 50ULL * blocks + 10000) {
    // top up: one new operation per free source, when the A queue is empty
    if (aq.empty() && next < blocks && inflight.size() < par) {
      for (unsigned s = 0; s < par; s++) {
        if (!inflight.count(src_of(s))) {
          uint32_t a = base + 64u * next;
          if (puts) { uint64_t w[8]; for (int k = 0; k < 8; k++) w[k] = ~pattern(tl_to_ddr(a) + 8 * k) + next; put64(src_of(s), a, w); }
          else get64(src_of(s), a);
          next++;
          break;
        }
      }
    }
    cycle();
  }
  run_until_idle(10000);
  if (puts) {
    unsigned bad = 0;
    for (unsigned i = 0; i < blocks; i++) {
      uint32_t a = base + 64u * i;
      for (int k = 0; k < 8; k++)
        if (memrd(tl_to_ddr(a) + 8 * k) != ~pattern(tl_to_ddr(a) + 8 * k) + i) bad++;
    }
    CHECK(bad == 0, "put stream: %u words in HP0 memory differ from what was written", bad);
  }
  double span = (double)(t_last_d - t_first_a + 1);
  printf("WIDTHTB stream=%s par=%u blocks=%u rlat=%u stall=%d cycles=%.0f done=%" PRIu64
         " B_per_mbus_cycle=%.3f lat_mean=%.2f lat_max=%" PRIu64 "\n",
         puts ? "put" : "get", par, blocks, rlat, stall ? 1 : 0, span, done_ops,
         64.0 * done_ops / span, done_ops ? (double)lat_sum / done_ops : 0.0, lat_max);
  CHECK(done_ops == blocks, "stream finished %" PRIu64 " of %u", done_ops, blocks);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  unsigned blocks = 4096;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--blocks") && i + 1 < argc) blocks = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--rlat") && i + 1 < argc) rlat = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--stall")) stall = true;
  }
  top = new Vwidthtb_top;
  top->reset = 1;
  for (int i = 0; i < 10; i++) cycle();
  top->reset = 0;
  for (int i = 0; i < 5; i++) cycle();

  // ---- 1. one Put, every word checked at the AXI4 port and in the HP0 memory ----
  const uint32_t A = 0x80000100u;
  uint64_t w[8];
  for (int k = 0; k < 8; k++) w[k] = 0x0123456789ABCDEFULL * (k + 1) ^ (0xF0ULL << (4 * k));
  x_wwords.clear(); x_aw_n = 0;
  put64(SRC_N - 1, A, w);
  bool ok1 = run_until_idle(2000);
  CHECK(ok1, "Put did not complete");
  CHECK(x_aw_n == 1, "Put issued %u AXI4 AW bursts (want 1)", x_aw_n);
  CHECK(x_wwords.size() == 8, "Put issued %zu AXI4 W beats (want 8)", x_wwords.size());
  for (size_t k = 0; k < x_wwords.size() && k < 8; k++)
    CHECK(x_wwords[k] == w[k], "AXI4 W beat %zu = %016" PRIx64 " want %016" PRIx64, k, x_wwords[k], w[k]);
  for (int k = 0; k < 8; k++)
    CHECK(memrd(tl_to_ddr(A) + 8 * k) == w[k], "HP0 memory word %d at %08x = %016" PRIx64 " want %016" PRIx64,
          k, tl_to_ddr(A) + 8 * k, memrd(tl_to_ddr(A) + 8 * k), w[k]);
  printf("WIDTHTB put: 1 TL PutFullData (4 x 128-bit beats) -> AXI4 AW size 3 len 7, W %zu beats, strb ff; "
         "HP0 memory at %08x matches: %s\n", x_wwords.size(), tl_to_ddr(A), fails ? "NO" : "yes");

  // ---- 2. one Get of the same block; D data checked against what the Put wrote ----
  int f0 = fails; x_ar_n = 0;
  get64(SRC_N - 2, A);
  bool ok2 = run_until_idle(2000);
  CHECK(ok2, "Get did not complete");
  CHECK(x_ar_n == 1, "Get issued %u AXI4 AR bursts (want 1)", x_ar_n);
  printf("WIDTHTB get: 1 TL Get (size 6) -> AXI4 AR size 3 len 7 -> 4 x 128-bit AccessAckData beats equal to the Put: %s\n",
         fails == f0 ? "yes" : "NO");

  // ---- 3. saturating streams ----
  const unsigned pars[] = {1, 2, 4, 8};
  for (unsigned p : pars) stream(false, blocks, p, 0x80400000u + 0x100000u * p);
  for (unsigned p : pars) stream(true, blocks / 4, p, 0x80800000u + 0x100000u * p);
  // read back what the put streams wrote
  for (unsigned p : pars) stream(false, blocks / 4, p, 0x80800000u + 0x100000u * p);

  printf("WIDTHTB_RESULT src_w=%d src_n=%d pass=%d fails=%d x_ar_bad=%u x_aw_bad=%u x_w_bad=%u cycles=%" PRIu64 "\n",
         SRC_W, SRC_N, fails == 0, fails, x_ar_bad, x_aw_bad, x_w_bad, cyc);
  delete top;
  return fails ? 1 : 0;
}
