// SPDX-License-Identifier: Apache-2.0
//
// tb_lut -- the LUT lane's testbench.
//
// WHAT IS WORTH CHECKING HERE, AND WHAT IS NOT.  The lane does not compute GELU; software
// builds the table.  So there is no arithmetic golden: correctness is entirely a property of
// the STREAM -- that every input byte reaches its own table entry, and every output byte its
// own position -- plus the protocol.  The suite is built around that.
//
//   1  exhaustive map          all 256 values in all 8 lane positions, twice, the second
//                              time with value decorrelated from position
//   2  random streams          random tables, random lengths, whole-stream comparison
//   3  backpressure            the same streams under 0/30/70/95 % hold; the 2-deep skid is
//                              the only real hazard in this lane and this is what finds it
//   4  the limit, AT the limit 1,024 words must run; 1,025 must REFUSE with err[2] and
//                              produce no output.  The LayerNorm lane's gate tested 512
//                              against a 1,024-word limit and passed a silent wrap; this
//                              case exists so that cannot happen here
//   5  refusals                words = 0, config written while busy
#include "Vmbxl_lut.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <random>

static Vmbxl_lut *top;
static uint64_t mem[1024];
static uint64_t pending;          // data for the NEXT cycle (1-cycle scratchpad latency)
static long g_fail = 0, g_checks = 0, g_words = 0, g_disp = 0;

static void tick(bool hold, std::vector<uint64_t> *out) {
  top->clk = 0;
  top->rd_data = pending;
  top->out_hold = hold ? 1 : 0;
  top->eval();
  uint32_t a = top->rd_word & 0x3ff;
  bool fire = top->out_valid && !hold;
  uint64_t d = top->out_data;
  pending = mem[a];
  top->clk = 1;
  top->eval();
  if (fire && out) out->push_back(d);
}

static void cfg(uint16_t addr, uint32_t data) {
  top->cfg_we = 1; top->cfg_addr = addr; top->cfg_wdata = data;
  tick(false, nullptr);
  top->cfg_we = 0; top->cfg_addr = 0; top->cfg_wdata = 0;
  tick(false, nullptr);
}

static void load_table(const uint8_t *t) {
  for (int i = 0; i < 256; i++) cfg((uint16_t)i, t[i]);
}

// run one dispatch; returns err.  `out` collects drained words.
static uint32_t dispatch(uint16_t word0, uint16_t words, std::vector<uint64_t> &out,
                         int hold_pct, std::mt19937 &rng, long max_cycles = 4000000) {
  cfg(0x100, word0);
  cfg(0x101, words);
  top->start = 1; tick(false, nullptr); top->start = 0;
  std::uniform_int_distribution<int> pc(0, 99);
  long c = 0;
  while (top->busy && c < max_cycles) { tick(hold_pct && pc(rng) < hold_pct, &out); c++; }
  for (int i = 0; i < 40; i++) tick(false, &out);       // let the tail drain
  if (c >= max_cycles) { printf("  TIMEOUT words=%u\n", words); g_fail++; }
  return top->err;
}

static void check_stream(const char *what, uint16_t word0, uint16_t words,
                         const uint8_t *t, const std::vector<uint64_t> &out) {
  g_disp++;
  if (out.size() != words) {
    printf("  FAIL %s: %zu words out, expected %u\n", what, out.size(), words);
    g_fail++; return;
  }
  for (uint32_t i = 0; i < words; i++) {
    uint64_t in = mem[(word0 + i) & 0x3ff];
    for (int b = 0; b < 8; b++) {
      uint8_t iv = (uint8_t)(in >> (8 * b));
      uint8_t ov = (uint8_t)(out[i] >> (8 * b));
      g_checks++;
      if (ov != t[iv]) {
        printf("  FAIL %s: word %u byte %d: in %02x -> %02x, table says %02x\n",
               what, i, b, iv, ov, t[iv]);
        g_fail++; if (g_fail > 20) exit(1); return;
      }
    }
    g_words++;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vmbxl_lut;
  top->clk = 0; top->rst = 1; top->cfg_we = 0; top->start = 0; top->out_hold = 0;
  top->cfg_addr = 0; top->cfg_wdata = 0; top->rd_data = 0;
  for (int i = 0; i < 8; i++) tick(false, nullptr);
  top->rst = 0;
  for (int i = 0; i < 4; i++) tick(false, nullptr);

  std::mt19937 rng(12345);
  uint8_t tbl[256];

  // ---- 1. exhaustive: every value, every position -----------------------------------------
  for (int i = 0; i < 256; i++) tbl[i] = (uint8_t)((i * 181 + 23) & 0xff);
  load_table(tbl);
  for (int i = 0; i < 256; i++) {           // pass A: all eight bytes the same value
    uint64_t w = 0;
    for (int b = 0; b < 8; b++) w |= (uint64_t)(uint8_t)i << (8 * b);
    mem[i] = w;
  }
  { std::vector<uint64_t> o; uint32_t e = dispatch(0, 256, o, 0, rng);
    if (e) { printf("  FAIL exhaustive A: err=%x\n", e); g_fail++; }
    check_stream("exhaustive-A", 0, 256, tbl, o); }
  for (int i = 0; i < 256; i++) {           // pass B: value decorrelated from position
    uint64_t w = 0;
    for (int b = 0; b < 8; b++) w |= (uint64_t)(uint8_t)((i + 37 * b) & 0xff) << (8 * b);
    mem[i] = w;
  }
  { std::vector<uint64_t> o; uint32_t e = dispatch(0, 256, o, 0, rng);
    if (e) { printf("  FAIL exhaustive B: err=%x\n", e); g_fail++; }
    check_stream("exhaustive-B", 0, 256, tbl, o); }
  printf("1. exhaustive map: 2 x 256 words, every value in every position\n");

  // ---- 2 & 3. random streams, with and without backpressure --------------------------------
  const int holds[4] = {0, 30, 70, 95};
  for (int trial = 0; trial < 48; trial++) {
    for (int i = 0; i < 256; i++) tbl[i] = (uint8_t)(rng() & 0xff);
    load_table(tbl);
    for (int i = 0; i < 1024; i++) mem[i] = ((uint64_t)rng() << 32) ^ rng();
    uint16_t words = (uint16_t)(1 + rng() % 300);
    uint16_t word0 = (uint16_t)(rng() % (1024 - words + 1));
    int hp = holds[trial & 3];
    std::vector<uint64_t> o;
    uint32_t e = dispatch(word0, words, o, hp, rng);
    if (e) { printf("  FAIL random: err=%x\n", e); g_fail++; }
    char nm[64]; snprintf(nm, sizeof nm, "random-%d-hold%d", trial, hp);
    check_stream(nm, word0, words, tbl, o);
  }
  printf("2/3. random streams under 0/30/70/95 %% backpressure: 48 dispatches\n");

  // ---- 4. THE LIMIT, TESTED AT THE LIMIT ---------------------------------------------------
  // 1,024 words is the whole buffer and must RUN.  1,025 must REFUSE.  This is the case the
  // LayerNorm lane's gate did not have: its largest was 512 against the same 1,024 limit.
  for (int i = 0; i < 256; i++) tbl[i] = (uint8_t)(255 - i);
  load_table(tbl);
  for (int i = 0; i < 1024; i++) mem[i] = ((uint64_t)rng() << 32) ^ rng();
  { std::vector<uint64_t> o; uint32_t e = dispatch(0, 1024, o, 0, rng);
    if (e) { printf("  FAIL limit-1024: err=%x (must run)\n", e); g_fail++; }
    check_stream("limit-1024", 0, 1024, tbl, o); }
  { std::vector<uint64_t> o; uint32_t e = dispatch(0, 1025, o, 0, rng);
    if (!(e & 0x4)) { printf("  FAIL limit-1025: err=%x, expected err[2]\n", e); g_fail++; }
    if (!o.empty()) { printf("  FAIL limit-1025: %zu words drained, expected 0\n", o.size()); g_fail++; }
    cfg(0x102, 1); }
  { std::vector<uint64_t> o; uint32_t e = dispatch(1023, 2, o, 0, rng);   // straddles the end
    if (!(e & 0x4)) { printf("  FAIL limit-straddle: err=%x, expected err[2]\n", e); g_fail++; }
    if (!o.empty()) { printf("  FAIL limit-straddle: %zu words drained\n", o.size()); g_fail++; }
    cfg(0x102, 1); }
  { std::vector<uint64_t> o; uint32_t e = dispatch(1023, 1, o, 0, rng);   // exactly the last
    if (e) { printf("  FAIL limit-last: err=%x (must run)\n", e); g_fail++; }
    check_stream("limit-last", 1023, 1, tbl, o); }
  printf("4. the limit at the limit: 1024 runs, 1025 and 1023+2 refuse with err[2], 1023+1 runs\n");

  // ---- 5. refusals --------------------------------------------------------------------------
  { std::vector<uint64_t> o; uint32_t e = dispatch(0, 0, o, 0, rng);
    if (!(e & 0x1)) { printf("  FAIL zero-length: err=%x, expected err[0]\n", e); g_fail++; }
    if (!o.empty()) { printf("  FAIL zero-length drained %zu\n", o.size()); g_fail++; }
    cfg(0x102, 1); }
  // a config write while busy must be refused and recorded, not silently latched
  { cfg(0x100, 0); cfg(0x101, 400);
    top->start = 1; tick(false, nullptr); top->start = 0;
    std::vector<uint64_t> o;
    for (int i = 0; i < 6; i++) tick(false, &o);
    top->cfg_we = 1; top->cfg_addr = 0x101; top->cfg_wdata = 12;
    tick(false, &o); top->cfg_we = 0;
    long c = 0; while (top->busy && c < 100000) { tick(false, &o); c++; }
    for (int i = 0; i < 40; i++) tick(false, &o);
    if (!(top->err & 0x2)) { printf("  FAIL cfg-while-busy: err=%x, expected err[1]\n", top->err); g_fail++; }
    if (o.size() != 400) { printf("  FAIL cfg-while-busy: %zu words, the write took effect\n", o.size()); g_fail++; }
    check_stream("cfg-while-busy", 0, 400, tbl, o);
    cfg(0x102, 1); }
  printf("5. refusals: zero length err[0]; a config write while busy is refused, err[1]\n");

  printf("\n%s: %ld dispatches, %ld words, %ld byte checks, %ld failures\n",
         g_fail ? "FAILED" : "PASS", g_disp, g_words, g_checks, g_fail);
  delete top;
  return g_fail ? 1 : 0;
}
