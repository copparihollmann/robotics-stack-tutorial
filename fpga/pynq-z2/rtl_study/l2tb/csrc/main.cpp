// SIMULATION ONLY.  C++ driver for l2tb_top: the BwProbe MMIO sequence, a behavioural TL-UH
// memory model behind TLCacheCork, and per-cycle attribution counters.
//
// Usage:
//   Vl2tb_top [options] RUN [RUN ...]
//   options (apply to the runs that follow them, may be repeated between runs):
//     S=<n>            sbus delay slices each way (0..6), set at reset and before each run
//     mode=serial|parallel|fifo
//     L=<n>            memory latency: first D beat valid >= acc+1+L (0 = ideal, minLatency 1)
//                      SERIAL: >= max(acc+1, prev_last_beat+1+G) + L  (one request served at a time)
//                      PARALLEL: >= max(acc+1+L, prev_last_beat+1+G)  (independent, bursts contiguous)
//                      FIFO:     as PARALLEL but strictly in request order (no overtaking)
//     G=<n>            idle cycles forced between two D bursts
//     M=<n>            max requests outstanding at the memory (A ready drops at M)
//     blocks=<n>       DRAM blocks per timed run (default 16384)
//     warm=<n>         DRAM warm-up blocks (default 16384)
//     win=<a>,<b>      attribution window, in instrument requests issued (default 10%..90%)
//     trace=<n>        print a per-cycle timeline of n cycles starting at the window start
//   RUN:
//     hits:<o1>,<o2>,...   L2-resident 4 KiB, 64 blocks x 1025 reps, warm pass first
//     dram:<o1>,<o2>,...   fresh 64-byte linear stream, L2 pre-filled (every miss evicts)
//     ws:<o1>,...          working set of wsbytes (default 128 KiB) in a fresh region: 1 untimed pass, wsreps (33) timed
//     pw:<o1>,...          pre-dirty a 4 MiB region with 64-byte PutFulls (client), read it with the probe while a lag writer
//                          keeps victims dirty, then read it back again; both reads are checked against every write
//   phases=1           per-Get event timeline (use at 1 in flight)
//   env L2TB_VIOLATE_MINLAT=1 / L2TB_BAD_SOURCE=1   positive controls for the TL monitors (the run must abort)
//
// Output lines start with RESULT (one per run) and ATTR (attribution, per run).

#include "Vl2tb_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>
#include <map>
#include <algorithm>
#include <functional>

// bits [lsb, lsb+n) of a Verilator wide signal (n <= 32)
static inline uint32_t wbits(const WData *w, int lsb, int n) {
  uint64_t v = w[lsb / 32];
  if ((lsb % 32) + n > 32) v |= (uint64_t)w[lsb / 32 + 1] << 32;
  return (uint32_t)((v >> (lsb % 32)) & ((1ull << n) - 1));
}

static uint64_t mix64(uint64_t z) {
  z += 0x9E3779B97F4A7C15ull;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

// ------------------------------------------------------------------------------------
// memory model
// ------------------------------------------------------------------------------------
struct MemReq {
  int64_t acc;      // cycle the (last) A beat was accepted
  int lat;          // this request's latency (L, dithered when L is fractional)
  bool get;
  uint32_t addr;
  uint8_t src, size;
  int beats, sent;
  int wait = 0;     // cycles this response sat valid && !ready at the cork
};

struct WaitStat {
  uint64_t n = 0, waited = 0, sum = 0; int max = 0;
  void add(int w) { n++; sum += w; if (w) waited++; if (w > max) max = w; }
};

struct Mem {
  bool serial = true;
  bool fifo = false;   // strict request order, latency counted from accept (not serialised)
  int L = 0, G = 0, M = 8;
  double Lfrac = 0.0, Lacc = 0.0;   // fractional part of L, Bresenham-dithered per request
  int next_lat() {
    Lacc += Lfrac;
    if (Lacc >= 1.0 - 1e-9) { Lacc -= 1.0; return L + 1; }
    return L;
  }
  std::deque<MemReq> q;           // outstanding, in accept order
  int cur = -1;                   // index into q of the burst on D, -1 none
  int64_t last_end = -1000000;    // cycle of the last D beat of the previous burst
  // put in progress (ReleaseData -> PutFullData)
  bool put_in = false;
  MemReq put_req;
  int put_beats_seen = 0;
  std::unordered_map<uint32_t, uint64_t> overlay;
  uint64_t nget = 0, nput = 0;
  // what a correct system must hold: client writes over the original pattern
  std::unordered_map<uint32_t, uint64_t> truth;
  // every value ever written to an address: an eviction racing a newer client Put may carry an older value
  std::unordered_map<uint32_t, std::vector<uint64_t>> hist;
  bool legal_value(uint32_t a, uint64_t v) const {
    if (v == mix64(a ^ 0x5A5A0009ull)) return true;
    auto it = hist.find(a);
    if (it == hist.end()) return false;
    for (auto x : it->second) if (x == v) return true;
    return false;
  }
  uint64_t put_beats = 0, put_mismatch = 0;
  WaitStat wait_grant, wait_ack;
  uint64_t truth_word(uint32_t a) const {
    auto it = truth.find(a);
    return it == truth.end() ? mix64(a ^ 0x5A5A0009ull) : it->second;
  }

  uint64_t word(uint32_t a) const {
    auto it = overlay.find(a);
    return it == overlay.end() ? mix64(a ^ 0x5A5A0009ull) : it->second;
  }
  int bb = 8;                  // outer beat bytes (8 or 16), from obs_obytes
  int P = 1;                   // supply period: at most one outer D beat every P cycles
  int64_t next_beat_ok = 0;
  int outstanding() const { return (int)q.size() + (put_in ? 1 : 0); }
  bool a_ready() const { return put_in || outstanding() < M; }

  void on_a(int64_t now, uint8_t opc, uint8_t size, uint8_t src, uint32_t addr, const uint64_t *data) {
    int beats = (1 << size) >= bb ? (1 << size) / bb : 1;
    if (opc == 4) {  // Get
      q.push_back(MemReq{now, next_lat(), true, addr, src, size, beats, 0});
      nget++;
    } else if (opc == 0 || opc == 1) {  // Put
      if (!put_in) {
        put_in = true;
        put_req = MemReq{now, 0, false, addr, src, size, beats, 0};
        put_beats_seen = 0;
      }
      for (int k = 0; k < bb / 8; k++) {
        uint32_t wa = put_req.addr + bb * put_beats_seen + 8 * k;
        overlay[wa] = data[k];
        put_beats++;
        if (!legal_value(wa, data[k])) put_mismatch++;
      }
      put_beats_seen++;
      if (put_beats_seen == put_req.beats) {
        put_req.acc = now;
        put_req.lat = next_lat();
        put_req.beats = 1;  // AccessAck is one beat
        q.push_back(put_req);
        put_in = false;
        nput++;
      }
    } else {
      fprintf(stderr, "MEM: unexpected A opcode %d\n", opc);
      exit(2);
    }
  }
  bool eligible(size_t i, int64_t now) const {
    const MemReq &r = q[i];
    // L = 0 is the ideal memory the diplomatic parameters allow: minLatency = 1, so the first
    // D beat can be valid in the cycle after the A beat is accepted (TLMonitor_47 enforces it).
    static const int minlat = getenv("L2TB_VIOLATE_MINLAT") ? 0 : 1;   // positive control for TLMonitor_47
    if (fifo) {
      if (i != 0) return false;
      return now >= r.acc + minlat + r.lat && now >= last_end + 1 + G;
    } else if (serial) {
      if (i != 0) return false;
      int64_t svc = std::max<int64_t>(r.acc + minlat, last_end + 1 + G);
      return now >= svc + r.lat;
    } else {
      return now >= r.acc + minlat + r.lat && now >= last_end + 1 + G;
    }
  }
  // choose the D output for this cycle; returns true if valid
  bool choose(int64_t now) {
    if (cur >= 0) return true;
    for (size_t i = 0; i < q.size(); i++) {
      if (eligible(i, now)) { cur = (int)i; return true; }
      if (serial || fifo) break;
    }
    return false;
  }
  // earliest cycle an idle memory D could present something (for idle attribution)
  bool any_waiting_latency(int64_t now) const {
    for (size_t i = 0; i < q.size(); i++) {
      const MemReq &r = q[i];
      if (fifo) {
        if (now < r.acc + 1 + r.lat) return true;
        break;
      } else if (serial) {
        int64_t svc = std::max<int64_t>(r.acc + 1, last_end + 1 + G);
        if (now < svc + r.lat) return true;
        break;
      } else if (now < r.acc + 1 + r.lat) return true;
    }
    return false;
  }
  void on_d_fire(int64_t now) {
    MemReq &r = q[cur];
    r.sent++;
    if (r.sent == r.beats) {
      if (r.get) wait_grant.add(r.wait); else wait_ack.add(r.wait);
      q.erase(q.begin() + cur);
      cur = -1;
      last_end = now;
    }
  }
};

// ------------------------------------------------------------------------------------
// per-request latency statistics
struct LatStat {
  std::vector<uint32_t> v;
  void add(int64_t x) { v.push_back((uint32_t)x); }
  void print(const char *who) {
    if (v.empty()) { printf("LAT who=%s n=0\n", who); return; }
    std::vector<uint32_t> w = v;
    std::sort(w.begin(), w.end());
    double mean = 0; for (auto x : w) mean += x; mean /= w.size();
    uint32_t med = w[w.size() / 2];
    auto pct = [&](double p) { size_t i = (size_t)(p * (w.size() - 1)); return w[i]; };
    uint64_t over = 0; for (auto x : w) if (x > 2 * med) over++;
    printf("LAT who=%s n=%zu mean=%.3f median=%u p99=%u p99.9=%u max=%u over_2x_median=%llu (threshold %u)\n", who,
           w.size(), mean, med, pct(0.99), pct(0.999), w.back(), (unsigned long long)over, 2 * med);
  }
};

// A C++-driven TileLink client on the second port (non-caching source IDs).
struct ClReq { bool get; uint8_t size; uint32_t addr; uint64_t data[8]; int beats; };
struct ClFlight { bool busy = false; bool get = false; int64_t t = 0, t_l2 = -1; uint32_t addr = 0; int rx = 0; int nb = 0; uint64_t exp[8]; };
struct Client {
  std::deque<ClReq> getq, putq;
  std::vector<int> get_ids, put_ids;       // source IDs for Gets and for Puts
  int get_cap = 8, put_cap = 2;
  ClFlight fl[64];
  bool a_busy = false; ClReq cur; int cur_beat = 0, cur_src = -1;
  LatStat get_lat, put_lat, get_in, put_in;   // *_in: from acceptance at the L2 inner port
  uint64_t get_beats = 0, get_done = 0, put_done = 0, mismatch = 0, a_fires_get = 0;
  std::function<void(uint32_t)> on_get_done;
  int peak_get = 0;
  int inflight(bool get) const { int n = 0; for (int i = 0; i < 64; i++) if (fl[i].busy && fl[i].get == get) n++; return n; }
  bool idle() const { if (a_busy || !getq.empty() || !putq.empty()) return false; for (int i = 0; i < 64; i++) if (fl[i].busy) return false; return true; }
  int free_id(const std::vector<int> &ids) const { for (int id : ids) if (!fl[id].busy) return id; return -1; }
};

// ------------------------------------------------------------------------------------
// attribution counters
// Per-Get event timeline, meaningful at 1 in flight: offsets from the probe's A fire.
enum { EV_PROBE_A, EV_L2_INNER_A, EV_DIR_READ, EV_SCHED_CW, EV_OUTER_C, EV_SCHED_A, EV_OUTER_A, EV_MEM_A,
       EV_MEM_D_FIRST, EV_OUTER_D_FIRST_DATA, EV_SINKD_DEQ_FIRST_DATA, EV_SCHED_DE, EV_SRCD_BUSY, EV_INNER_D_FIRST,
       EV_MEM_D_LAST, EV_OUTER_D_RA, EV_SINKD_DEQ_RA, EV_INNER_D_LAST, EV_PROBE_D_FIRST, EV_PROBE_D_LAST,
       EV_SCHED_W, EV_NEXT_PROBE_A, NEV };
static const char *ev_name[NEV] = {
  "probe A fire (t0)", "L2 inner A accepted (SinkA)", "Directory read", "scheduled CW (Release+dir invalidate)",
  "outer C fire (Release -> cork)", "scheduled A (Acquire)", "outer A fire (Acquire -> cork)",
  "memory A accepted (Get)", "memory D first beat", "outer D first GrantData beat", "SinkD deq first GrantData beat",
  "scheduled DE (execute + GrantAck)", "SourceD busy", "inner D first AccessAckData beat",
  "memory D last beat", "outer D ReleaseAck", "SinkD deq ReleaseAck", "inner D last beat",
  "probe D first beat", "probe D last beat", "scheduled W (dir writeback, MSHR free)", "next probe A fire"};
struct PhaseAcc {
  int64_t t0 = -1;
  int64_t ev[NEV];
  int n_mem = 0, n_ld = 0, n_pd = 0;
  double sum[NEV] = {0};
  uint64_t cnt[NEV] = {0};
  uint64_t gets = 0;
  void reset(int64_t now) { t0 = now; for (int i = 0; i < NEV; i++) ev[i] = -1; ev[EV_PROBE_A] = 0; n_mem = n_ld = n_pd = 0; }
  void mark(int e, int64_t now) { if (t0 >= 0 && ev[e] < 0) ev[e] = now - t0; }
  void close(int64_t now) {
    if (t0 < 0) return;
    ev[EV_NEXT_PROBE_A] = now - t0;
    for (int i = 0; i < NEV; i++) if (ev[i] >= 0) { sum[i] += ev[i]; cnt[i]++; }
    gets++;
  }
};

// ------------------------------------------------------------------------------------
struct Attr {
  uint64_t cyc = 0, blocks = 0, probe_a = 0, inner_d = 0;
  int ibeats = 8;
  // memory side
  uint64_t mem_a = 0, mem_d_fire = 0, mem_d_stall = 0, mem_d_idle_empty = 0,
           mem_d_idle_latency = 0, mem_d_idle_gap = 0, mem_a_block = 0, mem_d_idle_supply = 0;
  // cork / L2 outer D
  uint64_t od_fire_grant = 0, od_fire_rack = 0, od_stall = 0, od_idle = 0;
  uint64_t rack_pending = 0, rack_pending_blocked_by_data = 0;
  uint64_t outa_fire = 0, outc_fire = 0, outc_block = 0, oute = 0;
  // SinkD internals
  uint64_t sd_deq_fire = 0, sd_deq_block_bank = 0, sd_deq_block_hazard = 0, sd_deq_block_hazard_rack = 0, sd_reserve_noop = 0;
  // SourceD
  uint64_t srcd_busy = 0, srcd_req_wait = 0, srcd_rd_blocked = 0, srcd_rd_blocked_by_sinkd = 0,
           inner_d_stall = 0, srcd_s1_idle_but_s3 = 0;
  // scheduler
  uint64_t sch_select = 0, sch_idle = 0, sch_lost_arb = 0, sch_resblock = 0;
  uint64_t rb_a = 0, rb_c = 0, rb_d = 0, rb_e = 0, rb_dir = 0, rb_stall = 0;
  std::map<std::string, uint64_t> sel_plan;
  // directory
  uint64_t dir_read = 0, dir_write_enq_block = 0, dir_write_q_defer = 0, dir_write_fire = 0;
  // sinkA
  uint64_t sinka_req_block = 0, sinka_req_fire = 0, inner_a_block = 0;
  // mshrs
  uint64_t mshr_hist[17] = {0};
  PhaseAcc ph;
  int nm = 7;
  uint64_t phase[10] = {0};
};

static const char *phase_name[10] = {
  "no_meta(dir lookup)", "release_unsched", "acquire_unsched", "await_first_grant",
  "exec/grantack_unsched", "grant_streaming", "await_releaseack", "writeback_unsched",
  "other", "hit_exec_unsched"};

// ------------------------------------------------------------------------------------
struct Sim {
  Vl2tb_top *t;
  VerilatedContext *ctx;
  Mem mem;
  int64_t now = 0;
  int S = 0;
  bool attr_on = false;
  Attr A;
  int64_t trace_left = 0;
  bool trace_compact = true;
  bool phases = false;
  // probe-side counts (for windows)
  uint64_t probe_a_fires = 0;
  // second client, probe latency, per-cycle hook
  Client cl;
  bool lat_on = false;
  LatStat probe_lat, probe_in;
  int64_t probe_t[8] = {0}, probe_tl2[8] = {0};
  int probe_rx[8] = {0};
  std::function<void()> hook;

  Sim(int argc, char **argv) {
    ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    if (getenv("L2TB_NOFATAL")) ctx->fatalOnError(false);   // control runs: report every monitor that fires
    t = new Vl2tb_top{ctx};
    t->clock = 0; t->reset = 1; t->mmio_a_valid = 0; t->cfg_s = 0;
    t->mem_a_ready = 0; t->mem_d_valid = 0;
  }

  static inline bool bit(uint64_t v, int b) { return (v >> b) & 1; }

  void observe(bool mafire, bool mdfire) {
    uint64_t o0 = t->obs0, o1 = t->obs1;
    const WData *wplan = t->obs_plan.data(), *wflag = t->obs_mshr.data();
    int nm = t->obs_nm;
    bool pa_v = bit(o0, 63), pa_r = bit(o0, 62);
    if (pa_v && pa_r) probe_a_fires++;
    {
      // acceptance at the L2's inner A port (first beat of a message)
      uint32_t m = t->obs_mux;
      if (((m >> 8) & 1) && ((m >> 7) & 1)) {
        int src = (m >> 1) & 0x3f;
        if ((src >> 3) == 4) probe_tl2[src & 7] = now;
        else if (cl.fl[src].busy && cl.fl[src].t_l2 < 0) cl.fl[src].t_l2 = now;
      }
    }
    if (lat_on) {
      int ps = (t->obs_probe >> 13) & 7, ds = (t->obs_probe >> 10) & 7, dop = (t->obs_probe >> 7) & 7;
      if (pa_v && pa_r) { probe_t[ps] = now; probe_rx[ps] = 0; }
      if (bit(o0, 61) && dop == 1 && ++probe_rx[ds] == (int)t->obs_ibeats) {
        probe_lat.add(now - probe_t[ds]); probe_in.add(now - probe_tl2[ds]); probe_rx[ds] = 0;
        if (slow_thr > 0 && now - probe_t[ds] > slow_thr)
          printf("SLOW probe_get src=%d issued=%lld done=%lld lat=%lld\n", ds, (long long)probe_t[ds], (long long)now, (long long)(now - probe_t[ds]));
      }
    }
    if (!attr_on) return;
    Attr &a = A;
    a.cyc++;
    a.ibeats = t->obs_ibeats;
    if (pa_v && pa_r) a.probe_a++;
    bool pd_v = bit(o0, 61);
    bool la_v = bit(o0, 55), la_r = bit(o0, 54), ld_v = bit(o0, 53), ld_r = bit(o0, 52);
    int ld_opc = (o0 >> 49) & 7;
    if (ld_v && ld_r && ld_opc == 1) a.inner_d++;
    if (ld_v && !ld_r) a.inner_d_stall++;
    if (la_v && !la_r) a.inner_a_block++;
    bool oa_v = bit(o0, 47), oa_r = bit(o0, 46), oc_v = bit(o0, 45), oc_r = bit(o0, 44);
    bool od_v = bit(o0, 40), od_r = bit(o0, 39);
    int od_opc = (o0 >> 36) & 7;
    bool oe_v = bit(o0, 35);
    if (oa_v && oa_r) a.outa_fire++;
    if (oc_v && oc_r) a.outc_fire++;
    if (oc_v && !oc_r) a.outc_block++;
    if (oe_v) a.oute++;
    if (od_v && od_r) { if (od_opc == 6) a.od_fire_rack++; else a.od_fire_grant++; }
    else if (od_v) a.od_stall++;
    else a.od_idle++;
    bool q_v = bit(o0, 31);
    bool idle1 = bit(o0, 29), st10 = bit(o0, 28);
    if (q_v) {
      a.rack_pending++;
      bool rack_goes = od_v && od_r && od_opc == 6;
      if (!rack_goes && (t->mem_d_valid || (!idle1 && st10))) a.rack_pending_blocked_by_data++;
    }
    int req = t->obs_req, sel = t->obs_sel;
    // memory
    if (mafire) a.mem_a++;
    if (t->mem_a_valid && !t->mem_a_ready) a.mem_a_block++;
    if (mdfire) a.mem_d_fire++;
    else if (t->mem_d_valid) a.mem_d_stall++;
    else if (mem.cur >= 0 && now < mem.next_beat_ok) a.mem_d_idle_supply++;
    else if (mem.q.empty()) a.mem_d_idle_empty++;
    else if (mem.any_waiting_latency(now)) a.mem_d_idle_latency++;
    else a.mem_d_idle_gap++;
    // SinkD
    bool sd_dv = bit(o1, 63), sd_dr = bit(o1, 62), sd_gs = bit(o1, 61), sd_bv = bit(o1, 60),
         sd_br = bit(o1, 59), sd_noop = bit(o1, 58);
    int sd_cnt = (o1 >> 52) & 7;
    int sd_beat = (o1 >> 55) & 7;
    if (sd_dv && sd_dr) a.sd_deq_fire++;
    int sd_opc = (o1 >> 49) & 7;
    if (sd_dv && !sd_dr) { if (!sd_br) a.sd_deq_block_bank++; else { a.sd_deq_block_hazard++; if (sd_opc == 6) a.sd_deq_block_hazard_rack++; } }
    if (sd_bv && sd_noop) a.sd_reserve_noop++;
    // SourceD
    bool s_reqv = bit(o1, 47), s_reqr = bit(o1, 46), s_busy = bit(o1, 45);
    bool s_rv = bit(o1, 43), s_rr = bit(o1, 42);
    int s_beat = (o1 >> 39) & 7;
    bool s2 = bit(o1, 38), s3 = bit(o1, 37), s4 = bit(o1, 36);
    if (s_busy || s2 || s3 || s4) a.srcd_busy++;
    if (s_reqv && !s_reqr) a.srcd_req_wait++;
    if (s_rv && !s_rr) {
      a.srcd_rd_blocked++;
      if (sd_bv && ((sd_beat & 3) == (s_beat & 3))) a.srcd_rd_blocked_by_sinkd++;
    }
    (void)sd_cnt;
    // resources
    bool srcA_r = bit(o1, 30), srcC_r = bit(o1, 28), srcD_r = s_reqr, srcE_r = bit(o1, 26);
    bool dir_wv = bit(o1, 25), dir_wr = bit(o1, 24), dir_rv = bit(o1, 23), dir_qv = bit(o1, 22);
    bool sinka_v = bit(o1, 21), sinka_r = bit(o1, 20);
    if (dir_rv) a.dir_read++;
    if (dir_wv && !dir_wr) a.dir_write_enq_block++;
    if (dir_wv && dir_wr) a.dir_write_fire++;
    if (dir_qv && dir_rv) a.dir_write_q_defer++;
    if (sinka_v && !sinka_r) a.sinka_req_block++;
    if (sinka_v && sinka_r) a.sinka_req_fire++;
    int schv = t->obs_schv, statv = t->obs_statv;
    // scheduler
    if (sel) a.sch_select++; else a.sch_idle++;
    a.nm = nm;
    for (int i = 0; i < nm; i++) {
      int p = wbits(wplan, 6 * i, 6);  // {x, dir, e, d, c, a}
      bool sv = (schv >> i) & 1, rq = (req >> i) & 1, sl = (sel >> i) & 1;
      if (sv && rq && !sl) a.sch_lost_arb++;
      if (sv && !rq) {
        a.sch_resblock++;
        bool any = false;
        if ((p & 1) && !srcA_r) { a.rb_a++; any = true; }
        if ((p & 2) && !srcC_r) { a.rb_c++; any = true; }
        if ((p & 4) && !srcD_r) { a.rb_d++; any = true; }
        if ((p & 8) && !srcE_r) { a.rb_e++; any = true; }
        if ((p & 16) && !dir_wr) { a.rb_dir++; any = true; }
        if (!any) a.rb_stall++;
      }
      if (sl) {
        std::string s;
        if (p & 2) s += "C";
        if (p & 1) s += "A";
        if (p & 4) s += "D";
        if (p & 8) s += "E";
        if (p & 16) s += "W";
        if (p & 32) s += "X";
        if (s.empty()) s = "-";
        a.sel_plan[s]++;
      }
    }
    // MSHRs
    int nvalid = __builtin_popcount(statv);
    a.mshr_hist[nvalid]++;
    for (int i = 0; i < nm; i++) {
      if (!((statv >> i) & 1)) continue;
      // flags: bit0 request_valid, 1 meta_hit, 2 s_writeback, 3 s_grantack, 4 s_execute, 5 w_grant,
      //        6 w_grantlast, 7 w_grantfirst, 8 s_acquire, 9 w_releaseack, 10 s_release, 11 meta_valid
      uint64_t f = wbits(wflag, 12 * i, 12);
      bool meta_valid = (f >> 11) & 1, s_release = (f >> 10) & 1, w_releaseack = (f >> 9) & 1,
           s_acquire = (f >> 8) & 1, w_grantfirst = (f >> 7) & 1, w_grantlast = (f >> 6) & 1,
           s_execute = (f >> 4) & 1, s_grantack = (f >> 3) & 1, s_writeback = (f >> 2) & 1,
           meta_hit = (f >> 1) & 1;
      int ph;
      if (!meta_valid) ph = 0;
      else if (!s_release) ph = 1;
      else if (!s_acquire) ph = 2;
      else if (!w_grantfirst) ph = 3;
      else if (!s_execute || !s_grantack) ph = (meta_hit && s_grantack) ? 9 : 4;
      else if (!w_grantlast) ph = 5;
      else if (!w_releaseack) ph = 6;
      else if (!s_writeback) ph = 7;
      else ph = 8;
      a.phase[ph]++;
    }
    if (phases) {
      PhaseAcc &P = a.ph;
      if (pa_v && pa_r) { P.close(now); P.reset(now); }
      if (la_v && la_r) P.mark(EV_L2_INNER_A, now);
      if (dir_rv) P.mark(EV_DIR_READ, now);
      for (int i = 0; i < nm; i++) if ((sel >> i) & 1) {
        int p = wbits(wplan, 6 * i, 6);
        if (p & 2) P.mark(EV_SCHED_CW, now);
        if (p & 1) P.mark(EV_SCHED_A, now);
        if (p & 4) P.mark(EV_SCHED_DE, now);
        if ((p & 16) && !(p & 2)) P.mark(EV_SCHED_W, now);
      }
      if (oc_v && oc_r) P.mark(EV_OUTER_C, now);
      if (oa_v && oa_r) P.mark(EV_OUTER_A, now);
      if (mafire) P.mark(EV_MEM_A, now);
      if (mdfire) { P.mark(EV_MEM_D_FIRST, now); if (++P.n_mem == 64 / (int)t->obs_obytes) P.mark(EV_MEM_D_LAST, now); }
      if (od_v && od_r && od_opc != 6) P.mark(EV_OUTER_D_FIRST_DATA, now);
      if (od_v && od_r && od_opc == 6) P.mark(EV_OUTER_D_RA, now);
      if (sd_dv && sd_dr) P.mark(sd_opc == 6 ? EV_SINKD_DEQ_RA : EV_SINKD_DEQ_FIRST_DATA, now);
      if (s_busy || s2 || s3 || s4) P.mark(EV_SRCD_BUSY, now);
      if (ld_v && ld_r && ld_opc == 1) { P.mark(EV_INNER_D_FIRST, now); if (++P.n_ld == (int)t->obs_ibeats) P.mark(EV_INNER_D_LAST, now); }
      if (pd_v) { P.mark(EV_PROBE_D_FIRST, now); if (++P.n_pd == (int)t->obs_ibeats) P.mark(EV_PROBE_D_LAST, now); }
    }
    if (trace_left > 0 && getenv("L2TB_SCHDBG")) {
      int dmask = 0, amask = 0, cmask = 0, wmask = 0;
      for (int i = 0; i < nm; i++) { int p = wbits(wplan, 6 * i, 6); if (p & 4) dmask |= 1 << i; if (p & 1) amask |= 1 << i; if (p & 2) cmask |= 1 << i; if ((p & 16) && !(p & 2)) wmask |= 1 << i; }
      printf("S %lld %d %d %d %x %x %x %x %x %x %x %x\n", (long long)now, (int)s_reqr, (int)dir_wr, (int)dir_rv,
             schv, req, sel, dmask, amask, cmask, wmask, statv);
    }
    if (trace_left > 0 && getenv("L2TB_MUXDBG")) {
      uint32_t m = t->obs_mux;
      printf("M %lld ca%d%d xa%d%d gcl%d lock%d last%d L2A%d%d src%02x | sinkA req%d%d dirR%d\n", (long long)now,
             (m>>15)&1, (m>>14)&1, (m>>13)&1, (m>>12)&1, (m>>11)&1, (m>>10)&1, (m>>9)&1, (m>>8)&1, (m>>7)&1, (m>>1)&0x3f,
             sinka_v, sinka_r, (int)bit(o0, 6));
    }
    if (trace_left > 0 && trace_compact) {
      trace_left--;
      std::string plan = "-";
      for (int i = 0; i < nm; i++) if ((sel >> i) & 1) {
        int p = wbits(wplan, 6 * i, 6); plan = "m" + std::to_string(i) + ":";
        if (p & 2) plan += "C"; if (p & 1) plan += "A"; if (p & 4) plan += "D"; if (p & 8) plan += "E"; if (p & 16) plan += "W";
      }
      const char *od = !od_v ? "  .  " : (od_r ? (od_opc == 6 ? " RACK" : " DATA") : " stal");
      printf("T %7lld probeA%s | L2inA%s | outA%s outC%s outD%s | cork_rack_q%d | mem_out%zu memD%s | SourceD%s | sched %-8s | MSHRs %d\n",
             (long long)now, pa_v ? (pa_r ? "F" : "w") : ".", la_v ? (la_r ? "F" : "w") : ".",
             oa_v ? (oa_r ? "F" : "w") : ".", oc_v ? (oc_r ? "F" : "w") : ".", od, q_v, mem.q.size(),
             t->mem_d_valid ? (mdfire ? "F" : "w") : ".", (s_busy || s2 || s3 || s4) ? "busy" : " -- ",
             plan.c_str(), __builtin_popcount(statv));
    } else if (trace_left > 0) {
      trace_left--;
      printf("T %7lld pa%d%d | inA%d%d inD%d%d | oA%d%d oC%d%d oD%d%d:%d oE%d | rack_q%d | mem q%zu dV%d%s | "
             "sdD%d%d gs%d bs%d%d n%d b%d | srcD req%d%d busy%d rd%d%d b%d s234=%d%d%d | sch req%03x sel%03x | "
             "dir r%d w%d%d q%d | st%03x\n",
             (long long)now, pa_v, pa_r, la_v, la_r, ld_v, ld_r, oa_v, oa_r, oc_v, oc_r, od_v, od_r,
             od_opc, oe_v, q_v, mem.q.size(), (int)t->mem_d_valid, mdfire ? "F" : " ",
             sd_dv, sd_dr, sd_gs, sd_bv, sd_br, sd_noop, sd_beat, s_reqv, s_reqr, s_busy, s_rv,
             s_rr, s_beat, s2, s3, s4, req, sel, dir_rv, dir_wv, dir_wr, dir_qv, statv);
    }
  }

  void cl_drive() {
    Client &c = cl;
    t->cl_d_ready = 1;
    t->cl_a_valid = 0;
    if (!c.a_busy) {
      // prefer a pending Put (writer) over a Get when both are ready to go
      ClReq *r = nullptr; int id = -1; bool fromput = false;
      if (!c.putq.empty() && c.inflight(false) < c.put_cap && (id = c.free_id(c.put_ids)) >= 0) { r = &c.putq.front(); fromput = true; }
      else if (!c.getq.empty() && c.inflight(true) < c.get_cap && (id = c.free_id(c.get_ids)) >= 0) {
        r = &c.getq.front();
        static bool bad_used = false;
        if (getenv("L2TB_BAD_SOURCE") && !bad_used) { id = 63; bad_used = true; }   // positive control for TLMonitor_45/46
      }
      if (r) { c.cur = *r; c.cur_beat = 0; c.cur_src = id; if (fromput) c.putq.pop_front(); else c.getq.pop_front(); c.a_busy = true; }
    }
    if (c.a_busy) {
      t->cl_a_valid = 1;
      t->cl_a_opcode = c.cur.get ? 4 : 0;
      t->cl_a_size = c.cur.size;
      t->cl_a_source = c.cur_src;
      t->cl_a_address = c.cur.addr;
      t->cl_a_mask = c.cur.size >= 3 ? 0xFF : ((1 << (1 << c.cur.size)) - 1);
      t->cl_a_data = c.cur.get ? 0 : c.cur.data[c.cur_beat];
    }
  }
  bool cl_debug = getenv("L2TB_CLDEBUG") != nullptr;
  int64_t slow_thr = getenv("L2TB_SLOW") ? atoll(getenv("L2TB_SLOW")) : 0;
  void cl_after_a() {
    Client &c = cl;
    if (cl_debug && t->cl_a_valid && (now % 1 == 0)) printf("CLA %lld v=%d r=%d src=%d op=%d addr=%08x beat=%d\n", (long long)now, (int)t->cl_a_valid, (int)t->cl_a_ready, (int)t->cl_a_source, (int)t->cl_a_opcode, (unsigned)t->cl_a_address, c.cur_beat);
    if (!(t->cl_a_valid && t->cl_a_ready)) return;
    if (c.cur_beat == 0) {
      ClFlight &f = c.fl[c.cur_src];
      f.busy = true; f.get = c.cur.get; f.t = now; f.t_l2 = -1; f.addr = c.cur.addr; f.rx = 0; f.nb = c.cur.get ? c.cur.beats : 1;
      if (c.cur.get) { c.a_fires_get++; for (int b = 0; b < f.nb; b++) f.exp[b] = mem.truth_word(f.addr + 8 * b);
                       int n = c.inflight(true); if (n > c.peak_get) c.peak_get = n; }
      else for (int b = 0; b < c.cur.beats; b++) { mem.truth[c.cur.addr + 8 * b] = c.cur.data[b]; mem.hist[c.cur.addr + 8 * b].push_back(c.cur.data[b]); }
    }
    if (++c.cur_beat == (c.cur.get ? 1 : c.cur.beats)) c.a_busy = false;
  }
  void cl_after_d() {
    Client &c = cl;
    if (!t->cl_d_valid) return;
    int src = t->cl_d_source;
    ClFlight &f = c.fl[src];
    if (cl_debug) printf("CLD %lld src=%d op=%d data=%016llx busy=%d\n", (long long)now, src, (int)t->cl_d_opcode, (unsigned long long)t->cl_d_data, (int)f.busy);
    if (!f.busy) { fprintf(stderr, "CLIENT: D for idle source %d\n", src); exit(5); }
    if (f.get) {
      if (t->cl_d_opcode != 1) { fprintf(stderr, "CLIENT: bad D opcode %d\n", (int)t->cl_d_opcode); exit(5); }
      if (t->cl_d_data != f.exp[f.rx]) c.mismatch++;
      c.get_beats++;
    }
    if (++f.rx == f.nb) {
      f.busy = false;
      if (f.get) { if (lat_on) { c.get_lat.add(now - f.t); c.get_in.add(now - f.t_l2); } c.get_done++; if (c.on_get_done) c.on_get_done(f.addr); }
      else { if (lat_on) { c.put_lat.add(now - f.t); c.put_in.add(now - f.t_l2); } c.put_done++;
             if (slow_thr > 0 && now - f.t > slow_thr) printf("SLOW client_put src=%d addr=%08x issued=%lld done=%lld lat=%lld\n", src, f.addr, (long long)f.t, (long long)now, (long long)(now - f.t)); }
    }
  }

  int64_t trace_at = getenv("L2TB_TRACE_AT") ? atoll(getenv("L2TB_TRACE_AT")) : -1;
  int64_t trace_n = getenv("L2TB_TRACE_N") ? atoll(getenv("L2TB_TRACE_N")) : 100;
  void step() {
    if (now == trace_at) { trace_left = trace_n; }
    if (trace_at >= 0 && now >= trace_at && now < trace_at + trace_n) attr_on = true;
    if (hook) hook();
    cl_drive();
    // (1) inputs that depend only on state
    t->mem_a_ready = mem.a_ready();
    t->mem_d_valid = 0;
    t->eval();
    cl_after_a();
    bool afire = t->mem_a_valid && t->mem_a_ready;
    if (afire) {
      uint64_t w[2] = { ((uint64_t)t->mem_a_data[1] << 32) | t->mem_a_data[0], ((uint64_t)t->mem_a_data[3] << 32) | t->mem_a_data[2] };
      mem.on_a(now, t->mem_a_opcode, t->mem_a_size, t->mem_a_source, t->mem_a_address, w);
    }
    // (2) D, possibly same cycle (L = 0); the memory supplies at most one beat every P cycles
    for (int k = 0; k < 4; k++) t->mem_d_data[k] = 0;
    if (mem.choose(now) && now >= mem.next_beat_ok) {
      MemReq &r = mem.q[mem.cur];
      t->mem_d_valid = 1;
      t->mem_d_opcode = r.get ? 1 : 0;
      t->mem_d_size = r.size;
      t->mem_d_source = r.src;
      if (r.get) for (int k = 0; k < mem.bb / 8; k++) {
        uint64_t v = mem.word(r.addr + mem.bb * r.sent + 8 * k);
        t->mem_d_data[2 * k] = (uint32_t)v; t->mem_d_data[2 * k + 1] = (uint32_t)(v >> 32);
      }
    }
    t->eval();
    bool dfire = t->mem_d_valid && t->mem_d_ready;
    if (t->mem_d_valid && !dfire) mem.q[mem.cur].wait++;
    cl_after_d();
    observe(afire, dfire);
    // (3) clock edge
    t->clock = 1;
    t->eval();
    t->clock = 0;
    ctx->timeInc(1);
    if (dfire) { mem.on_d_fire(now); mem.next_beat_ok = now + mem.P; }
    now++;
  }

  void mmio_write(uint32_t off, uint64_t v) {
    t->mmio_a_valid = 1; t->mmio_a_opcode = 0; t->mmio_a_address = 0x100A0000u + off; t->mmio_a_data = v;
    step();
    t->mmio_a_valid = 0;
  }
  uint64_t mmio_read(uint32_t off) {
    t->mmio_a_valid = 1; t->mmio_a_opcode = 4; t->mmio_a_address = 0x100A0000u + off; t->mmio_a_data = 0;
    t->eval();
    uint64_t v = t->mmio_d_data;
    t->mmio_a_valid = 0;
    t->eval();
    return v;
  }

  void do_reset() {
    t->reset = 1;
    t->cfg_s = S;
    for (int i = 0; i < 20; i++) step();
    t->reset = 0;
    // Directory wipe runs after reset; wait for it (obs0 bit 3 = directory io_ready)
    int guard = 0;
    while (!((t->obs0 >> 6) & 1)) { step(); if (++guard > 5000) { fprintf(stderr, "no wipeDone\n"); exit(3); } }
    for (int i = 0; i < 20; i++) step();
    mem.bb = t->obs_obytes;
    printf("INFO reset done at cycle %lld (directory wipe complete)\n", (long long)now);
  }
};

struct RunOut {
  uint64_t cycles, beats, reqs, cksum, peak, denied;
  bool ok;
};

static uint64_t region_xor(const Mem &m, uint64_t base, uint64_t row_blocks, uint64_t nrows, uint64_t stride) {
  uint64_t x = 0;
  for (uint64_t r = 0; r < nrows; r++) {
    uint64_t rb = base + r * stride;
    uint64_t rx = 0;
    for (uint64_t b = 0; b < row_blocks; b++)
      for (int w = 0; w < 8; w++) rx ^= mix64((uint32_t)(rb + b * 64 + w * 8) ^ 0x5A5A0009ull);
    x ^= rx;
  }
  return x;
}

static uint64_t region_xor_truth(const Mem &m, uint64_t base, uint64_t row_blocks, uint64_t nrows, uint64_t stride) {
  uint64_t x = 0;
  for (uint64_t r = 0; r < nrows; r++)
    for (uint64_t b = 0; b < row_blocks; b++)
      for (int w = 0; w < 8; w++) x ^= m.truth_word((uint32_t)(base + r * stride + b * 64 + w * 8));
  return x;
}

static RunOut probe_go(Sim &s, uint64_t base, uint64_t row_blocks, uint64_t nrows, uint64_t stride, int maxout,
                       bool attribute, double w0, double w1, int64_t trace, const uint64_t *expect_override = nullptr) {
  uint64_t total = row_blocks * nrows;
  s.mmio_write(0x00, base);
  s.mmio_write(0x08, row_blocks);
  s.mmio_write(0x10, nrows);
  s.mmio_write(0x18, stride);
  s.mmio_write(0x20, maxout);
  s.probe_a_fires = 0;
  s.A = Attr();
  s.mmio_write(0x28, 1);
  uint64_t lo = (uint64_t)(w0 * total), hi = (uint64_t)(w1 * total);
  int64_t guard = 0;
  bool traced = false;
  while (true) {
    if (attribute) {
      bool on = s.probe_a_fires >= lo && s.probe_a_fires < hi;
      if (on && !traced && trace > 0) { s.trace_left = trace; traced = true; }
      s.attr_on = on;
    }
    s.step();
    if ((++guard & 255) == 0 && !(s.mmio_read(0x30) & 1)) break;
    if (guard > 400000000) { fprintf(stderr, "run timeout\n"); exit(4); }
  }
  s.attr_on = false;
  for (int i = 0; i < 4; i++) s.step();
  RunOut r;
  r.cycles = s.mmio_read(0x38);
  r.beats = s.mmio_read(0x40);
  r.reqs = s.mmio_read(0x48);
  r.cksum = s.mmio_read(0x50);
  r.peak = (s.mmio_read(0x30) >> 9) & 0xff;
  r.denied = s.mmio_read(0x58);
  uint64_t expect = expect_override ? *expect_override : region_xor(s.mem, base, row_blocks, nrows, stride);
  r.ok = (r.cksum == expect) && (r.beats == 8 * total) && (r.reqs == total) && r.denied == 0;
  return r;
}

static void print_attr(const Attr &a, int maxout) {
  double blk = a.blocks ? (double)a.blocks : 1.0;
  double nb = a.inner_d / (double)a.ibeats;
  if (nb < 1) nb = 1;
  printf("ATTR out=%d window_cycles=%llu blocks_delivered=%.1f cycles_per_block=%.3f\n", maxout,
         (unsigned long long)a.cyc, nb, a.cyc / nb);
  auto pb = [&](const char *name, uint64_t v) { printf("ATTR   %-44s %10llu  %7.3f /block\n", name, (unsigned long long)v, v / nb); };
  printf("ATTR  [memory side, TLCacheCork auto_out]\n");
  pb("mem A accepted (Get/Put)", a.mem_a);
  pb("mem A valid && !ready (M cap)", a.mem_a_block);
  pb("mem D fire", a.mem_d_fire);
  pb("mem D valid && !ready (cork/L2 backpressure)", a.mem_d_stall);
  pb("mem D idle: nothing outstanding at memory", a.mem_d_idle_empty);
  pb("mem D idle: outstanding, inside latency L", a.mem_d_idle_latency);
  pb("mem D idle: outstanding, gap G", a.mem_d_idle_gap);
  pb("mem D idle: burst chosen, supply period P", a.mem_d_idle_supply);
  printf("ATTR  [L2 outer port]\n");
  pb("outer A fire (Acquire)", a.outa_fire);
  pb("outer C fire (Release)", a.outc_fire);
  pb("outer C valid && !ready (cork RA queue full)", a.outc_block);
  pb("outer E valid (GrantAck)", a.oute);
  pb("outer D fire GrantData beats", a.od_fire_grant);
  pb("outer D fire ReleaseAck", a.od_fire_rack);
  pb("outer D valid && !ready", a.od_stall);
  pb("outer D idle", a.od_idle);
  pb("cork ReleaseAck queued", a.rack_pending);
  pb("cork ReleaseAck queued, lost to data", a.rack_pending_blocked_by_data);
  printf("ATTR  [SinkD]\n");
  pb("SinkD deq fire", a.sd_deq_fire);
  pb("SinkD deq blocked: BankedStore (sinkC/sourceC)", a.sd_deq_block_bank);
  pb("SinkD deq blocked: grant hazard (SourceD)", a.sd_deq_block_hazard);
  pb("  ... of which the head is a ReleaseAck", a.sd_deq_block_hazard_rack);
  pb("SinkD bank reservation w/o data (noop)", a.sd_reserve_noop);
  printf("ATTR  [SourceD / inner D]\n");
  pb("inner D AccessAckData beats", a.inner_d);
  pb("inner D valid && !ready", a.inner_d_stall);
  pb("SourceD busy (any stage)", a.srcd_busy);
  pb("SourceD req valid && !ready (execute waits)", a.srcd_req_wait);
  pb("SourceD SRAM read blocked", a.srcd_rd_blocked);
  pb("  ... same bank as SinkD beat", a.srcd_rd_blocked_by_sinkd);
  printf("ATTR  [inner A / SinkA / Directory]\n");
  pb("inner A valid && !ready", a.inner_a_block);
  pb("SinkA req fire", a.sinka_req_fire);
  pb("SinkA req valid && !ready", a.sinka_req_block);
  pb("Directory read", a.dir_read);
  pb("Directory write fire (enq)", a.dir_write_fire);
  pb("Directory write enq blocked", a.dir_write_enq_block);
  pb("Directory write queued behind a read", a.dir_write_q_defer);
  printf("ATTR  [scheduler, one MSHR per cycle]\n");
  pb("cycles an MSHR was scheduled", a.sch_select);
  pb("cycles nothing scheduled", a.sch_idle);
  pb("MSHR-cycles ready but lost arbitration", a.sch_lost_arb);
  pb("MSHR-cycles plan blocked by a resource", a.sch_resblock);
  pb("  ... sourceA busy", a.rb_a);
  pb("  ... sourceC busy", a.rb_c);
  pb("  ... sourceD busy", a.rb_d);
  pb("  ... sourceE busy", a.rb_e);
  pb("  ... directory write not ready", a.rb_dir);
  pb("  ... set interlock (BC/C MSHR)", a.rb_stall);
  for (auto &kv : a.sel_plan) {
    std::string n = "scheduled plan " + kv.first;
    pb(n.c_str(), kv.second);
  }
  printf("ATTR  [MSHR occupancy, MSHR-cycles by phase]\n");
  for (int i = 0; i < 10; i++) if (a.phase[i]) pb(phase_name[i], a.phase[i]);
  printf("ATTR  MSHRs valid histogram (fraction of cycles):");
  double mean = 0;
  for (int i = 0; i <= a.nm; i++) { printf(" %d:%.3f", i, a.cyc ? (double)a.mshr_hist[i] / a.cyc : 0.0); mean += i * (double)a.mshr_hist[i]; }
  printf("  mean %.3f\n", a.cyc ? mean / a.cyc : 0.0);
  if (a.ph.gets) {
    printf("PHASE out=%d gets=%llu (mean cycle offset from the probe's A fire; first occurrence per Get)\n", maxout,
           (unsigned long long)a.ph.gets);
    for (int i = 0; i < NEV; i++)
      if (a.ph.cnt[i]) printf("PHASE   %-42s %8.3f   (seen in %llu Gets)\n", ev_name[i], a.ph.sum[i] / a.ph.cnt[i],
                              (unsigned long long)a.ph.cnt[i]);
  }
  (void)blk;
}

int main(int argc, char **argv) {
  Sim s(argc, argv);
  int S = 0;
  uint64_t blocks = 16384, warm = 16384;
  double w0 = 0.10, w1 = 0.90;
  int64_t trace = 0;
  bool reset_done = false;
  bool attr = true;
  uint64_t dram_region = 0, ws_region = 0, alt_next = 0, pw_region = 0;
  int wr_size = 3, wr_lag = 32, wr_every = 1, wr_cap = 2;
  uint64_t alt_pairs = 512; int alt_dirty = 0;
  uint64_t lcg = 0x243F6A8885A308D3ull;
  auto rnd = [&]() { lcg = lcg * 6364136223846793005ull + 1442695040888963407ull; return lcg ^ (lcg >> 29); };
  s.cl.put_ids = {0x30, 0x31};
  for (int i = 0; i < 8; i++) s.cl.get_ids.push_back(i);   // debug/serial_tl range 0x00-0x07, non-caching
  uint64_t wsbytes = 131072, wsreps = 33;
  bool dram_warmed = false;

  auto setS = [&](int v) { S = v; s.S = v; };

  for (int ai = 1; ai < argc; ai++) {
    std::string arg = argv[ai];
    auto eq = arg.find('=');
    auto col = arg.find(':');
    if (eq != std::string::npos && (col == std::string::npos || eq < col)) {
      std::string k = arg.substr(0, eq), v = arg.substr(eq + 1);
      if (k == "S") setS(atoi(v.c_str()));
      else if (k == "mode") { s.mem.serial = (v == "serial"); s.mem.fifo = (v == "fifo");
        if (v != "serial" && v != "parallel" && v != "fifo") { fprintf(stderr, "bad mode %s\n", v.c_str()); return 1; } }
      else if (k == "L") { double d = atof(v.c_str()); s.mem.L = (int)d; s.mem.Lfrac = d - (int)d; s.mem.Lacc = 0; }
      else if (k == "G") s.mem.G = atoi(v.c_str());
      else if (k == "M") s.mem.M = atoi(v.c_str());
      else if (k == "supply") s.mem.P = atoi(v.c_str());
      else if (k == "blocks") blocks = strtoull(v.c_str(), 0, 0);
      else if (k == "warm") warm = strtoull(v.c_str(), 0, 0);
      else if (k == "win") { sscanf(v.c_str(), "%lf,%lf", &w0, &w1); }
      else if (k == "trace") trace = atoll(v.c_str());
      else if (k == "tracefmt") s.trace_compact = (v != "raw");
      else if (k == "phases") s.phases = atoi(v.c_str()) != 0;
      else if (k == "wsbytes") wsbytes = strtoull(v.c_str(), 0, 0);
      else if (k == "wsreps") wsreps = strtoull(v.c_str(), 0, 0);
      else if (k == "attr") attr = atoi(v.c_str()) != 0;
      else if (k == "wr_size") wr_size = atoi(v.c_str());
      else if (k == "wr_lag") wr_lag = atoi(v.c_str());
      else if (k == "wr_every") wr_every = atoi(v.c_str());
      else if (k == "wr_cap") wr_cap = atoi(v.c_str());
      else if (k == "alt_pairs") alt_pairs = strtoull(v.c_str(), 0, 0);
      else if (k == "alt_dirty") alt_dirty = atoi(v.c_str());
      else { fprintf(stderr, "unknown option %s\n", k.c_str()); return 1; }
      continue;
    }
    if (col == std::string::npos) { fprintf(stderr, "bad arg %s\n", arg.c_str()); return 1; }
    std::string kind = arg.substr(0, col);
    std::vector<int> outs;
    {
      std::string l = arg.substr(col + 1);
      size_t p = 0;
      while (p < l.size()) {
        size_t c = l.find(',', p);
        outs.push_back(atoi(l.substr(p, c - p).c_str()));
        if (c == std::string::npos) break;
        p = c + 1;
      }
    }
    if (!reset_done || s.t->cfg_s != S) { s.do_reset(); reset_done = true; dram_warmed = false; }
    s.t->cfg_s = S;
    const char *mname = s.mem.fifo ? "fifo" : (s.mem.serial ? "serial" : "parallel");
    for (int o : outs) {
      uint64_t base, rb, nr, stride, total;
      if (kind == "hits") {
        base = 0x81000000ull; rb = 64; nr = 1025; stride = 0;
        probe_go(s, base, rb, nr, stride, o, false, 0, 0, 0);    // untimed warm pass, as the lab does
      } else if (kind == "alt") {
        // client-only: alternate a 64-block warm region W with fresh 64-block regions aligned to W's sets
        const uint32_t W = 0x8C000000u;
        auto enqget = [&](uint32_t a) { ClReq r; r.get = true; r.size = 6; r.addr = a; r.beats = 8; s.cl.getq.push_back(r); };
        s.cl.get_cap = o; s.cl.put_cap = wr_cap;
        s.cl.on_get_done = nullptr;
        for (int b = 0; b < 64; b++) enqget(W + 64 * b);           // untimed warm pass of W
        while (!s.cl.idle()) s.step();
        if (alt_dirty) s.cl.on_get_done = [&](uint32_t a) {
          if (a >= W && a < W + 4096) {
            ClReq r; r.get = false; r.size = 3; r.addr = a + 8 * (rnd() % 8); r.beats = 1; r.data[0] = rnd();
            s.cl.putq.push_back(r);
          }
        };
        for (uint64_t pr = 0; pr < alt_pairs; pr++) {
          for (int b = 0; b < 64; b++) enqget(W + 64 * b);
          uint32_t F = W + (uint32_t)(alt_next++ + 1) * 0x4000u;
          for (int b = 0; b < 64; b++) enqget(F + 64 * b);
        }
        uint64_t total_g = s.cl.getq.size();
        s.cl.get_lat = LatStat(); s.cl.put_lat = LatStat(); s.cl.get_in = LatStat(); s.cl.put_in = LatStat(); s.cl.get_beats = 0; s.cl.mismatch = 0; s.cl.peak_get = 0;
        s.cl.get_done = 0; s.cl.put_done = 0; s.cl.a_fires_get = 0;
        s.mem.wait_grant = WaitStat(); s.mem.wait_ack = WaitStat();
        uint64_t nget0 = s.mem.nget, nput0 = s.mem.nput, pm0 = s.mem.put_mismatch;
        s.A = Attr(); s.lat_on = true;
        int64_t c0 = s.now;
        while (!s.cl.idle()) {
          s.attr_on = attr && s.cl.a_fires_get >= total_g / 10 && s.cl.a_fires_get < total_g * 9 / 10;
          s.step();
        }
        s.attr_on = false; s.lat_on = false;
        uint64_t cyc = s.now - c0;
        uint64_t mm_run = s.cl.mismatch, gd_run = s.cl.get_done, gb_run = s.cl.get_beats, pd_run = s.cl.put_done;
        // untimed read-back of W after every write has been acknowledged: must equal the last value written
        s.cl.on_get_done = nullptr;
        for (int b = 0; b < 64; b++) enqget(W + 64 * b);
        while (!s.cl.idle()) s.step();
        bool readback_ok = (s.cl.mismatch == mm_run);
        printf("RESULT kind=alt%s S=%d mode=%s L=%g G=%d M=%d out=%d reqs=%llu beats=%llu cycles=%llu B/cycle=%.4f "
               "cycles/Get=%.3f peak=%d denied=0 cksum_ok=%d mem_gets=%llu mem_puts=%llu client_puts=%llu put_data_ok=%d readback_ok=%d\n",
               alt_dirty ? "_dirty" : "", S, mname, s.mem.L + s.mem.Lfrac, s.mem.G, s.mem.M, o,
               (unsigned long long)gd_run, (unsigned long long)gb_run, (unsigned long long)cyc,
               8.0 * gb_run / cyc, (double)cyc / gd_run, s.cl.peak_get, (int)(mm_run == 0),
               (unsigned long long)(s.mem.nget - nget0), (unsigned long long)(s.mem.nput - nput0),
               (unsigned long long)pd_run, (int)(s.mem.put_mismatch == pm0), (int)readback_ok);
        s.cl.get_lat.print("client_get");
        s.cl.get_in.print("client_get_from_L2_accept");
        if (alt_dirty) { s.cl.put_lat.print("client_put"); s.cl.put_in.print("client_put_from_L2_accept"); }
        printf("BURST grantdata n=%llu delayed=%llu mean_wait=%.4f max_wait=%d | accessack n=%llu delayed=%llu mean_wait=%.4f max_wait=%d\n",
               (unsigned long long)s.mem.wait_grant.n, (unsigned long long)s.mem.wait_grant.waited,
               s.mem.wait_grant.n ? (double)s.mem.wait_grant.sum / s.mem.wait_grant.n : 0.0, s.mem.wait_grant.max,
               (unsigned long long)s.mem.wait_ack.n, (unsigned long long)s.mem.wait_ack.waited,
               s.mem.wait_ack.n ? (double)s.mem.wait_ack.sum / s.mem.wait_ack.n : 0.0, s.mem.wait_ack.max);
        if (attr) print_attr(s.A, o);
        s.cl.on_get_done = nullptr;
        fflush(stdout);
        continue;
      } else if (kind == "dram" || kind == "dramw" || kind == "pw") {
        if (!dram_warmed) {
          // fill the L2 with a different region so every timed miss evicts a valid clean victim
          // row_blocks is 16 bits: split a long warm-up into rows of <= 32768 blocks
          uint64_t wrb = warm > 32768 ? 32768 : warm, wnr = (warm + wrb - 1) / wrb;
          RunOut w = probe_go(s, 0x82000000ull, wrb, wnr, wrb * 64, 8, false, 0, 0, 0);
          printf("INFO dram warm-up %llu blocks: cycles=%llu cksum_ok=%d\n", (unsigned long long)warm,
                 (unsigned long long)w.cycles, (int)w.ok);
          dram_warmed = true;
        }
        if (kind == "pw") base = 0x8E000000ull + (pw_region++) * 0x00400000ull;   // pre-dirtied 4 MiB slot
        else base = 0x84000000ull + (dram_region++) * 0x00800000ull;   // fresh 8 MiB slot per run
        if (blocks > 0xf000) { rb = blocks / 2; nr = 2; stride = rb * 64; }
        else { rb = blocks; nr = 1; stride = 0; }
      } else if (kind == "ws") {
        // working set: fresh region, one untimed warm pass, then wsreps timed passes (wsreps odd for the XOR)
        base = 0x8A000000ull + (ws_region++) * 0x00400000ull;
        rb = wsbytes / 64; nr = wsreps; stride = 0;
        probe_go(s, base, rb, 1, 0, o, false, 0, 0, 0);
      } else { fprintf(stderr, "unknown run kind %s\n", kind.c_str()); return 1; }
      total = rb * nr;
      uint64_t nget0 = s.mem.nget, nput0 = s.mem.nput, pm0 = s.mem.put_mismatch;
      s.probe_lat = LatStat(); s.probe_in = LatStat(); s.cl.put_lat = LatStat(); s.cl.put_in = LatStat(); s.cl.put_done = 0;
      s.mem.wait_grant = WaitStat(); s.mem.wait_ack = WaitStat();
      int64_t next_w = 0; uint64_t wr_skipped = 0;
      uint64_t pw_expect = 0, pw_cycles = 0, pw_puts = 0, pw_mem_puts = 0;
      if (kind == "pw") {
        // phase 1 (untimed): pre-dirty every block of the region with a 64-byte PutFull of random data
        s.cl.put_cap = wr_cap;
        int64_t c0 = s.now; uint64_t np0 = s.mem.nput, pd0 = s.cl.put_done;
        for (uint64_t i = 0; i < total; i++) {
          ClReq q; q.get = false; q.size = 6; q.beats = 8; q.addr = (uint32_t)(base + i * 64);
          for (int b = 0; b < 8; b++) q.data[b] = rnd();
          s.cl.putq.push_back(q);
        }
        while (!s.cl.idle()) s.step();
        pw_cycles = s.now - c0; pw_puts = s.cl.put_done - pd0; pw_mem_puts = s.mem.nput - np0;
        pw_expect = region_xor_truth(s.mem, base, rb, nr, stride);   // what phase 2 must read back
        nget0 = s.mem.nget; nput0 = s.mem.nput;
        s.cl.put_lat = LatStat(); s.cl.put_in = LatStat(); s.cl.put_done = 0;
        s.mem.wait_grant = WaitStat(); s.mem.wait_ack = WaitStat();
      }
      if (kind == "dramw" || kind == "pw") {
        s.cl.put_cap = wr_cap;
        s.probe_a_fires = 0;   // the previous run's count must not look like a stream head
        s.hook = [&, base]() {
          if (s.cl_debug && (s.now % 200 == 0)) printf("HOOK %lld fires=%llu next_w=%lld putq=%zu abusy=%d infl_put=%d cycle_busy=%d\n", (long long)s.now, (unsigned long long)s.probe_a_fires, (long long)next_w, s.cl.putq.size(), (int)s.cl.a_busy, s.cl.inflight(false), 0);
          while (next_w + wr_lag <= (int64_t)s.probe_a_fires && next_w < (int64_t)total) {
            if (s.cl.putq.size() >= 4) { next_w += wr_every; wr_skipped++; continue; }
            ClReq r; r.get = false; r.size = wr_size; r.beats = wr_size > 3 ? (1 << wr_size) / 8 : 1;
            uint32_t blk = (uint32_t)(base + next_w * 64);
            r.addr = wr_size >= 6 ? blk : blk + 8 * (uint32_t)(rnd() % 8);
            for (int b = 0; b < r.beats; b++) r.data[b] = rnd();
            s.cl.putq.push_back(r);
            next_w += wr_every;
          }
        };
      }
      s.lat_on = true;
      RunOut r = probe_go(s, base, rb, nr, stride, o, attr, w0, w1, trace, kind == "pw" ? &pw_expect : nullptr);
      s.lat_on = false;
      s.hook = nullptr;
      while (!s.cl.idle()) s.step();
      uint64_t mem_gets_run = s.mem.nget - nget0, mem_puts_run = s.mem.nput - nput0;
      Attr attr_run = s.A;
      WaitStat wg_run = s.mem.wait_grant, wa_run = s.mem.wait_ack;
      uint64_t pb_run = s.mem.put_beats, pm_run = s.mem.put_mismatch;
      int pw_readback_ok = -1;
      if (kind == "pw") {
        // phase 3 (untimed): read the region again; must equal every write, including phase 2's
        uint64_t exp3 = region_xor_truth(s.mem, base, rb, nr, stride);
        RunOut r3 = probe_go(s, base, rb, nr, stride, 8, false, 0, 0, 0, &exp3);
        pw_readback_ok = r3.ok;
        s.A = attr_run;
        // report phase 2 only (phase 3's put checks still count toward put_data_ok below)
        pm_run = s.mem.put_mismatch;
        s.mem.wait_grant = wg_run; s.mem.wait_ack = wa_run;
      }
      double bpc = 8.0 * r.beats / r.cycles;
      printf("RESULT kind=%s S=%d mode=%s L=%g G=%d M=%d %sout=%d reqs=%llu beats=%llu cycles=%llu B/cycle=%.4f "
             "cycles/Get=%.3f peak=%llu denied=%llu cksum_ok=%d mem_gets=%llu mem_puts=%llu\n",
             kind.c_str(), S, mname, s.mem.L + s.mem.Lfrac, s.mem.G, s.mem.M, s.mem.P == 1 ? "" : ("supply=" + std::to_string(s.mem.P) + " ").c_str(), o, (unsigned long long)r.reqs,
             (unsigned long long)r.beats, (unsigned long long)r.cycles, bpc, (double)r.cycles / total,
             (unsigned long long)r.peak, (unsigned long long)r.denied, (int)r.ok,
             (unsigned long long)mem_gets_run, (unsigned long long)mem_puts_run);
      if (kind == "pw")
        printf("PW prewrite_64B_puts=%llu prewrite_cycles=%llu prewrite_evictions_as_ReleaseData=%llu phase2_read_matches_prewritten=%d "
               "phase3_readback_matches_all_writes=%d phase2_ReleaseData_per_probe_Get=%.4f\n",
               (unsigned long long)pw_puts, (unsigned long long)pw_cycles, (unsigned long long)pw_mem_puts, (int)r.ok,
               pw_readback_ok, (double)mem_puts_run / r.reqs);
      if (kind == "dram" || kind == "dramw" || kind == "pw") {
        s.probe_lat.print("probe_get");
        s.probe_in.print("probe_get_from_L2_accept");
        if (kind == "dramw" || kind == "pw") {
          s.cl.put_lat.print("writer_put");
          s.cl.put_in.print("writer_put_from_L2_accept");
          printf("WRITER puts_done=%llu skipped=%llu wr_size=%d lag=%d cap=%d put_data_ok=%d mem_put_beats_checked=%llu\n",
                 (unsigned long long)s.cl.put_done, (unsigned long long)wr_skipped, wr_size, wr_lag, wr_cap,
                 (int)(pm_run == pm0), (unsigned long long)pb_run);
        }
        printf("BURST grantdata n=%llu delayed=%llu mean_wait=%.4f max_wait=%d | accessack n=%llu delayed=%llu mean_wait=%.4f max_wait=%d\n",
               (unsigned long long)s.mem.wait_grant.n, (unsigned long long)s.mem.wait_grant.waited,
               s.mem.wait_grant.n ? (double)s.mem.wait_grant.sum / s.mem.wait_grant.n : 0.0, s.mem.wait_grant.max,
               (unsigned long long)s.mem.wait_ack.n, (unsigned long long)s.mem.wait_ack.waited,
               s.mem.wait_ack.n ? (double)s.mem.wait_ack.sum / s.mem.wait_ack.n : 0.0, s.mem.wait_ack.max);
      }
      if (attr) print_attr(s.A, o);
      fflush(stdout);
    }
  }
  s.t->final();
  return 0;
}
