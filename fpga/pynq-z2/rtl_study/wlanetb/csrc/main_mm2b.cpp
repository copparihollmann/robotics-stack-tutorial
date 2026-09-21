// SIMULATION ONLY.  THE TWO-CLOCK MM BENCH (MEMORY_BANDWIDTH.md s9.14): the configuration nothing in this campaign
// had ever driven -- an MM reading the weight banks on the ENGINE clock while the W lane writes them on the LANE
// clock, with the double buffer switching underneath, on the GENERATED design (RoccMoonEngine2b +
// wlaneClockSinkDomain: RoccMoonWHalf -> TLBuffer -> TLToAXI4 -> AXI4IdIndexer -> AXI4UserYanker), against an AXI4
// memory standing in for S_AXI_HP2 and a TileLink responder standing in for the L2 on client A.
//
// WHY IT EXISTS.  0x5A5A0013 computes wrong answers for short weight loads on silicon, non-deterministically, and
// nine mechanisms are ruled out (s9.14).  Every bench before this one drove weight loads with client A idle and no
// MM: the interaction between the engine's two halves across two clocks was never simulated at all.
//
// WHAT DRIVES IT.  The REAL DRIVER, sw/roccmoon/mbxr.c, compiled in unchanged and pointed at this DUT -- so the
// command sequence, the tiling, the double buffering and the placement are the board's, not a bench's imitation.
// The reference is kernel_linear_s8 (ModelBlaster's reference_kernels.py, verbatim), not a model of the engine.
//
// CAVEAT, CARRIED FORWARD FROM s9.14.2: Verilator has no delays.  Every FCLK0 -> FCLK1 signal here changes on one
// edge with all its bits together and zero route delay.  If this bench reproduces the fault, the mechanism is found;
// if it does not, that is NOT an acquittal.
//
//   Vmm2b [--lat L] [--alat L] [--p0 ps] [--p1 ps] [--cases N] [--seed S] [--jitter N] [--verbose]
#include "Vwlanetb2b_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <random>
#include <string>
#include <vector>

extern "C" {
#include "mbxr.h"
#include "mbxr.c"
}

// ---- reference: verbatim from ModelBlaster reference_kernels.py (kernel_linear_s8) ---------------------------------
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

// ---- the simulated SoC's memory -----------------------------------------------------------------------------------
static const uint64_t WIN_BASE = 0x80000000ULL;
static const uint64_t WIN_SIZE = 64ULL << 20;
static std::vector<uint8_t> MEM;
static inline bool in_win(uint64_t pa, uint64_t bytes) { return pa >= WIN_BASE && pa + bytes <= WIN_BASE + WIN_SIZE; }
static inline uint8_t *host(uint64_t pa) { return MEM.data() + (pa - WIN_BASE); }
static uint64_t rd64(uint64_t pa) { uint64_t v; memcpy(&v, host(pa), 8); return v; }
static void     wr64(uint64_t pa, uint64_t v) { memcpy(host(pa), &v, 8); }

static Vwlanetb2b_top *top;
static uint64_t H0 = 14500, H1 = 5000;    // half periods (ps): engine 1000/29 MHz, lane 100 MHz
static uint64_t next0, next1;
static bool c0 = false, c1 = false;
static uint64_t cyc0 = 0, cyc1 = 0;
static uint64_t protocol_errors = 0;
static void perr(const char *msg, uint64_t a = 0) {
  if (protocol_errors < 12) fprintf(stderr, "PROTOCOL: %s 0x%llx (cyc0=%llu cyc1=%llu)\n", msg,
                                    (unsigned long long)a, (unsigned long long)cyc0, (unsigned long long)cyc1);
  protocol_errors++;
}

// ---- the AXI4 memory on the LANE clock (S_AXI_HP2's stand-in) ------------------------------------------------------
struct RB { uint8_t id; uint64_t addr; unsigned beats; uint64_t ready_at; };
struct Mem {
  unsigned lat = 20, cap = 8, jitter = 0;
  std::deque<RB> pend; bool act = false; RB cur{}; unsigned beat = 0;
  uint64_t ar = 0, rlast = 0, rbeats = 0, contract_bad = 0;
  unsigned out_r() const { return pend.size() + (act ? 1 : 0); }
};
static Mem mem;
static bool g_debug = false;
static uint64_t ww_writes = 0, ww_nonzero = 0;   // the weight half's bank writes, counted on the LANE clock
static uint64_t g_jit = 0x243F6A8885A308D3ULL;

static void mem_drive() {
  top->axi_ar_ready = mem.out_r() < mem.cap;
  top->axi_aw_ready = 1; top->axi_w_ready = 1; top->axi_b_valid = 0; top->axi_b_bits_id = 0; top->axi_b_bits_resp = 0;
  if (!mem.act) {
    for (size_t i = 0; i < mem.pend.size(); i++)
      if (mem.pend[i].ready_at <= cyc1) { mem.cur = mem.pend[i]; mem.pend.erase(mem.pend.begin() + i); mem.act = true; mem.beat = 0; break; }
  }
  if (mem.act) {
    top->axi_r_valid = 1; top->axi_r_bits_id = mem.cur.id;
    top->axi_r_bits_data = rd64(mem.cur.addr + 8ULL * mem.beat);
    top->axi_r_bits_resp = 0; top->axi_r_bits_last = mem.beat + 1 == mem.cur.beats;
  } else { top->axi_r_valid = 0; top->axi_r_bits_last = 0; top->axi_r_bits_data = 0; }
}
static void mem_sample_lane() {           // on a rising LANE edge, after eval
  if (top->axi_ar_valid && top->axi_ar_ready) {
    uint64_t a = top->axi_ar_bits_addr;
    bool ok = top->axi_ar_bits_len == 7 && top->axi_ar_bits_size == 3 && top->axi_ar_bits_burst == 1
              && (a & 63) == 0 && in_win(a, 64);
    if (!ok) { mem.contract_bad++; perr("lane AR outside the contract, addr", a); }
    uint64_t extra = 0;
    if (mem.jitter) { g_jit = g_jit * 6364136223846793005ULL + 1442695040888963407ULL; extra = (g_jit >> 33) % (mem.jitter + 1); }
    mem.pend.push_back(RB{(uint8_t)top->axi_ar_bits_id, a, (unsigned)top->axi_ar_bits_len + 1, cyc1 + mem.lat + extra});
    mem.ar++;
  }
  if (top->axi_aw_valid) perr("AWVALID on the read-only lane");
  if (top->axi_w_valid)  perr("WVALID on the read-only lane");
  if (top->tb_ww_en) { ww_writes++; if (top->tb_ww_data) ww_nonzero++;
    if (g_debug && ww_writes <= 4) fprintf(stderr, "DBG ww word=0x%04x data=0x%016llx\n", (unsigned)top->tb_ww_word,
                                           (unsigned long long)top->tb_ww_data); }
  if (top->axi_r_valid && top->axi_r_ready) {
    mem.rbeats++;
    if (++mem.beat == mem.cur.beats) { mem.act = false; mem.rlast++; }
  }
}

// ---- the TileLink responder on client A (engine clock): the L2's stand-in ------------------------------------------
// 64-byte Gets: one A beat in, eight AccessAckData beats out, never interleaved with another message.
// 64-byte Puts: eight A beats in, one AccessAck out.  There is no d_ready on this interface -- the engine takes a
// beat every cycle D is valid -- so the responder presents at most one beat per engine cycle.
struct AJob { bool put; uint8_t source; uint64_t addr; unsigned beat; uint64_t ready_at; };
static unsigned A_LAT = 20;
static std::deque<AJob> a_reads, a_acks;
static AJob a_active{}; static bool a_act = false;
static uint64_t a_gets = 0, a_puts = 0, a_put_beats = 0, a_bad = 0;
static unsigned a_put_beat[8] = {0};       // beats seen so far, per source
static uint64_t a_put_addr[8] = {0};

static void a_drive() {
  top->a_a_ready = 1;
  if (!a_act) {
    if (!a_reads.empty() && a_reads.front().ready_at <= cyc0) { a_active = a_reads.front(); a_reads.pop_front(); a_act = true; }
    else if (!a_acks.empty() && a_acks.front().ready_at <= cyc0) { a_active = a_acks.front(); a_acks.pop_front(); a_act = true; }
  }
  if (a_act) {
    top->a_d_valid = 1;
    top->a_d_bits_source = a_active.source;
    top->a_d_bits_denied = 0; top->a_d_bits_corrupt = 0;
    if (a_active.put) { top->a_d_bits_opcode = 0; top->a_d_bits_data = 0; }
    else              { top->a_d_bits_opcode = 1; top->a_d_bits_data = rd64(a_active.addr + 8ULL * a_active.beat); }
  } else {
    top->a_d_valid = 0; top->a_d_bits_opcode = 0; top->a_d_bits_data = 0; top->a_d_bits_source = 0;
    top->a_d_bits_denied = 0; top->a_d_bits_corrupt = 0;
  }
}
static void a_sample() {                   // on a rising ENGINE edge, after eval
  if (top->a_a_valid && top->a_a_ready) {
    unsigned op = top->a_a_bits_opcode, src = top->a_a_bits_source & 7;
    uint64_t addr = top->a_a_bits_address;
    if (op == 4) {                                            // Get, 64 bytes
      if (!in_win(addr, 64) || (addr & 63)) { a_bad++; perr("client A Get outside the window or unaligned", addr); }
      a_reads.push_back(AJob{false, (uint8_t)src, addr, 0, cyc0 + A_LAT});
      a_gets++;
      if (g_debug && a_gets <= 4) fprintf(stderr, "DBG A Get src=%u addr=0x%llx first=0x%016llx\n", src,
                                          (unsigned long long)addr, (unsigned long long)rd64(addr));
    } else if (op == 0) {                                     // PutFullData, 8 beats of 8 bytes
      // TileLink holds `address` CONSTANT across the beats of a multibeat message (rocket-chip's
      // TLMonitor.legalizeMultibeatA checks exactly that), so the beat's offset comes from the beat
      // COUNT, not from the address field.  Writing every beat at the address field -- which this
      // bench did in its first hour -- keeps only the last beat of each 64-byte block.
      if (a_put_beat[src] == 0) a_put_addr[src] = addr;
      uint64_t dst = a_put_addr[src] + 8ULL * a_put_beat[src];
      if (!in_win(dst, 8)) { a_bad++; perr("client A Put outside the window", dst); }
      else wr64(dst, top->a_a_bits_data);
      a_put_beats++;
      if (++a_put_beat[src] == 8) {
        a_put_beat[src] = 0;
        a_acks.push_back(AJob{true, (uint8_t)src, a_put_addr[src], 0, cyc0 + A_LAT});
        a_puts++;
      }
    } else { a_bad++; perr("client A opcode neither Get nor PutFullData", op); }
  }
  if (a_act) {                                                // the beat we presented was taken
    if (a_active.put) a_act = false;
    else if (++a_active.beat == 8) a_act = false;
  }
}

// ---- time ----------------------------------------------------------------------------------------------------------
static void tick0() {
  for (;;) {
    uint64_t t = std::min(next0, next1);
    bool e0 = next0 == t, e1 = next1 == t;
    bool r0 = e0 && !c0, r1 = e1 && !c1;
    if (r1) { mem_drive(); }
    if (r0) { a_drive(); }
    top->eval();
    if (e0) { c0 = !c0; top->clk0 = c0; next0 += H0; }
    if (e1) { c1 = !c1; top->clk1 = c1; next1 += H1; }
    top->eval();
    if (r1) { mem_sample_lane(); cyc1++; mem_drive(); top->eval(); }
    if (r0) { a_sample(); cyc0++; a_drive(); top->eval(); return; }
  }
}
static void run0(uint64_t n) { for (uint64_t i = 0; i < n; i++) tick0(); }

// ---- the engine's RoCC command interface, as RoccMoonShim drives it for hart 1 --------------------------------------
static uint64_t rocc_cmd_sim(void *ctx, unsigned funct, uint64_t rs1, uint64_t rs2, int xd) {
  (void)ctx;
  top->cmd_valid = 1; top->cmd_funct = funct; top->cmd_rs1 = rs1; top->cmd_rs2 = rs2; top->cmd_xd = xd ? 1 : 0;
  top->eval();
  uint64_t r = top->rsp_respData;
  tick0();
  top->cmd_valid = 0; top->cmd_xd = 0; top->eval();
  return r;
}
static void *p2v_sim(void *ctx, uint64_t pa) { (void)ctx; return in_win(pa, 1) ? (void *)host(pa) : nullptr; }
static uint64_t now_sim(void *ctx) { (void)ctx; return cyc0; }

static void reset_both(unsigned lane_cycles) {
  top->rst0 = 1; top->rst1 = 1;
  top->cmd_valid = 0; top->cmd_xd = 0; top->tb_dhold = 0; top->tb_rdrop = 0;
  top->tb_mut_rfirst = 0; top->tb_mut_noquiet = 0; top->tb_mut_noresethold = 0;
  for (unsigned i = 0; i < lane_cycles; i++) tick0();
  top->rst0 = 0; top->rst1 = 0;
  run0(20);
}

// ---- one dispatch, driven by the real driver ------------------------------------------------------------------------
struct Case { int M, K, N; };
static int run_case(const mbxr_dev &dev, const Case &c, uint64_t seed, bool verbose) {
  std::mt19937_64 rng(seed);
  auto r8 = [&]() { return (int8_t)(int)((rng() % 255) - 127); };

  std::vector<int8_t> w((size_t)c.N * c.K), in((size_t)c.M * c.K), gold((size_t)c.M * c.N), out((size_t)c.M * c.N, 0);
  std::vector<int32_t> bias(c.N);
  for (auto &x : w) x = r8();
  for (auto &x : in) x = r8();
  for (auto &b : bias) b = (int32_t)(rng() % 2001) - 1000;

  mbxr_wimage img;
  if (!mbxr_wimage_plan(&img, c.N, c.K)) { fprintf(stderr, "plan refused for N=%d K=%d\n", c.N, c.K); return 2; }
  const uint64_t img_pa = WIN_BASE + 0x00100000ULL;
  const uint64_t in_pa  = WIN_BASE + 0x01000000ULL;
  const uint64_t scr_pa = WIN_BASE + 0x02000000ULL;
  if (mbxr_wimage_build(&dev, &img, img_pa, w.data(), bias.data()) != MBXR_OK) { fprintf(stderr, "image build failed\n"); return 2; }

  // the activation window: pixel p starts at in_pa + p*8*astride and is K bytes long
  const int astride = (c.K + 7) / 8;
  memset(host(in_pa), 0, (size_t)c.M * 8 * astride + 64);
  for (int p = 0; p < c.M; p++) memcpy(host(in_pa + (uint64_t)p * 8 * astride), &in[(size_t)p * c.K], c.K);

  mbxr_quant q; q.mult = 1 << 30; q.shift = 6; q.amin = -128; q.amax = 127;
  kernel_linear_s8(in.data(), w.data(), bias.data(), gold.data(), c.M, c.K, c.N, 0, 0, 0, q.mult, q.shift, q.amin, q.amax);

  mbxr_stats st; memset(&st, 0, sizeof st);
  uint64_t t0 = cyc0, l0 = cyc1, ar0 = mem.ar;
  int rc = mbxr_run(&dev, &img, in_pa, c.M, astride, &q, scr_pa, out.data(), &st);
  uint64_t cyc = cyc0 - t0;

  int bad = 0, maxerr = 0;
  for (size_t i = 0; i < gold.size(); i++) {
    int d = std::abs((int)out[i] - (int)gold[i]);
    if (d) { bad++; maxerr = std::max(maxerr, d); }
  }
  printf("MM2B case M=%-3d K=%-4d N=%-3d rc=%d cycles=%llu lane_cycles=%llu wgt_ar=%llu a_gets=%llu a_puts=%llu "
         "wrong=%d max_abs_err=%d -> %s\n",
         c.M, c.K, c.N, rc, (unsigned long long)cyc, (unsigned long long)(cyc1 - l0),
         (unsigned long long)(mem.ar - ar0), (unsigned long long)a_gets, (unsigned long long)a_puts,
         bad, maxerr, (rc == MBXR_OK && !bad) ? "PASS" : "FAIL");
  if (verbose && bad) {
    for (size_t i = 0, shown = 0; i < gold.size() && shown < 8; i++)
      if (out[i] != gold[i]) { printf("    [%zu] got %d want %d\n", i, (int)out[i], (int)gold[i]); shown++; }
  }
  fflush(stdout);
  return (rc == MBXR_OK && !bad) ? 0 : 1;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  unsigned lat = 20, alat = 20, jitter = 0, ncases = 8;
  uint64_t seed = 1;
  bool verbose = false;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--lat") && i + 1 < argc) lat = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--alat") && i + 1 < argc) alat = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--jitter") && i + 1 < argc) jitter = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--cases") && i + 1 < argc) ncases = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoull(argv[++i], nullptr, 0);
    else if (!strcmp(argv[i], "--p0") && i + 1 < argc) H0 = atoll(argv[++i]) / 2;
    else if (!strcmp(argv[i], "--p1") && i + 1 < argc) H1 = atoll(argv[++i]) / 2;
    else if (!strcmp(argv[i], "--verbose")) verbose = true;
    else if (!strcmp(argv[i], "--debug")) { g_debug = true; verbose = true; }
  }
  MEM.assign(WIN_SIZE, 0);
  mem.lat = lat; mem.jitter = jitter; A_LAT = alat;
  next0 = H0; next1 = H1;
  top = new Vwlanetb2b_top;
  reset_both(40);

  mbxr_dev dev;
  memset(&dev, 0, sizeof dev);
  dev.cmd = rocc_cmd_sim; dev.p2v = p2v_sim; dev.ctx = nullptr;
  dev.poll_limit = 20000000; dev.now = now_sim; dev.place_chunk = 1; dev.place_early = 0;
  dev.lane_wait = 2000000;

  uint64_t id = rocc_cmd_sim(nullptr, 7, 7, 0, 1);
  printf("MM2B engine id=0x%012llx (NCH=%llu LDEPTH=%llu SDEPTH=%llu) engine=%.4fMHz lane=%.4fMHz lat=%u alat=%u jitter=%u\n",
         (unsigned long long)id, (unsigned long long)((id >> 32) & 0xffff), (unsigned long long)((id >> 24) & 0xff),
         (unsigned long long)((id >> 16) & 0xff), 1e6 / (2.0 * H0), 1e6 / (2.0 * H1), lat, alat, jitter);

  // Shapes chosen the way the board's failures fall: the small ones first, since the fault tracks how often a
  // weight load starts and stops rather than how much it fetches (MEMORY_BANDWIDTH.md 9.14).
  const Case fixed[] = { {1, 64, 8}, {2, 128, 16}, {4, 256, 32}, {8, 64, 64}, {16, 512, 48}, {31, 368, 5} };
  int rc = 0;
  std::mt19937_64 rng(seed);
  for (unsigned i = 0; i < ncases; i++) {
    Case c;
    if (i < sizeof(fixed) / sizeof(fixed[0])) c = fixed[i];
    else { c.M = 1 + (int)(rng() % 40); c.K = 8 * (1 + (int)(rng() % 48)); c.N = 1 + (int)(rng() % 68); }
    if (run_case(dev, c, seed + 1000 * i, verbose)) rc = 1;
  }
  printf("MM2B ww_writes=%llu ww_nonzero=%llu\n", (unsigned long long)ww_writes, (unsigned long long)ww_nonzero);
  printf("MM2B end cyc0=%llu cyc1=%llu lane_ar=%llu rlast=%llu contract_bad=%llu a_gets=%llu a_puts=%llu a_bad=%llu "
         "protocol_errors=%llu -> %s\n",
         (unsigned long long)cyc0, (unsigned long long)cyc1, (unsigned long long)mem.ar, (unsigned long long)mem.rlast,
         (unsigned long long)mem.contract_bad, (unsigned long long)a_gets, (unsigned long long)a_puts,
         (unsigned long long)a_bad, (unsigned long long)protocol_errors,
         (rc == 0 && protocol_errors == 0 && mem.contract_bad == 0 && a_bad == 0) ? "PASS" : "FAIL");
  delete top;
  return rc ? rc : ((protocol_errors || mem.contract_bad || a_bad) ? 1 : 0);
}
