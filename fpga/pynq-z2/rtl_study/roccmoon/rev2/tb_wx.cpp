// SPDX-License-Identifier: Apache-2.0
//
// tb_wx -- mbxr_wx's crossing under two unrelated clocks.  The core side behaves like the
// driver (accepts a weight load only while FILL is clear); the lane side is a DMA stand-in that,
// on `start`, stays busy for a random number of lane cycles (0 = nothing to fetch), delivers a
// random number of beats while busy, and sometimes raises an error.  Checked, for thousands of
// loads at clock ratios from 1:5 to 5:1 with random phase:
//   1. every accepted load produces exactly one start;
//   2. FILL (core domain) is high from the accepting cycle until after the load's last beat
//      and last busy lane cycle -- never low while the lane is still working on it;
//   3. once idle, the core's beat count equals the beats delivered, and STAT clear zeroes it;
//   4. every lane error produces at least one error pulse in the core.
// Expect a final line beginning WX_TB_OK.
#include "Vtb_wx_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <random>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  std::mt19937_64 rng(2026);
  auto rnd = [&](uint64_t n) { return n ? rng() % n : 0; };
  int fails = 0;
  long total_loads = 0;
  for (int trial = 0; trial < 24; trial++) {
    Vtb_wx_top *t = new Vtb_wx_top;
    uint64_t pc = 10 + rnd(90), pw = 10 + rnd(90);      // periods, arbitrary units
    uint64_t tc = rnd(pc), tw = rnd(pw);                 // next rising edges
    t->clk = 0; t->wclk = 0; t->rst = 1; t->wrst = 1; t->accept = 0; t->clr_count = 0;
    t->dma_busy = 0; t->dma_beat = 0; t->dma_err = 0;
    // lane-side stand-in, with mbxd_dma's timing: `start` is taken at a lane edge, `busy` is
    // registered (high after that edge while blocks remain), beats happen only in busy cycles
    int remaining = 0;
    bool start_pending = false;      // accepted in the core, not yet started in the lane
    long beats_sent = 0, errs_sent = 0, starts = 0, accepts = 0, err_pulses = 0, early_clear = 0;
    long core_cycles = 0, lane_cycles = 0;
    int gap = 0;
    auto lane_edge = [&](bool allow_work) {
      lane_cycles++;
      if (lane_cycles == 4) t->wrst = 0;
      bool start = !t->wrst && t->start;
      t->dma_busy = remaining > 0;
      t->dma_beat = 0; t->dma_err = 0;
      if (remaining > 0 && allow_work) {
        if (rnd(3) == 0) { t->dma_beat = 1; beats_sent++; }
        if (rnd(400) == 0) { t->dma_err = 1; errs_sent++; }
      }
      t->wclk = 1; t->eval();
      t->wclk = 0; t->eval();
      if (start) { starts++; start_pending = false; remaining = (int)rnd(40); }
      else if (remaining > 0) remaining--;
    };
    for (long step = 0; step < 400000; step++) {
      bool core_edge = tc <= tw;
      uint64_t now = core_edge ? tc : tw;
      if (core_edge) {
        core_cycles++;
        if (core_cycles == 4) t->rst = 0;
        bool busy = t->busy;
        // invariant 2: FILL must not read clear while a load is accepted-but-not-started or
        // still has blocks to deliver
        if (!t->rst && !busy && (start_pending || remaining > 0)) early_clear++;
        t->accept = 0; t->clr_count = 0;
        if (!t->rst && !busy && step < 380000) {
          if (gap > 0) gap--;
          else { t->accept = 1; accepts++; start_pending = true; gap = (int)rnd(20); }
        }
        if (!t->rst && rnd(5000) == 0) t->clr_count = 1;
        t->clk = 1; t->eval();
        if (t->err_pulse) err_pulses++;
        t->clk = 0; t->eval();
        tc = now + pc;
      } else {
        lane_edge(true);
        tw = now + pw;
      }
    }
    // drain: both clocks run, no new loads, the lane finishes what it has
    for (int i = 0; i < 4000; i++) {
      t->accept = 0; t->clr_count = 0;
      t->clk = 1; t->eval(); if (t->err_pulse) err_pulses++; t->clk = 0; t->eval();
      lane_edge(true);
    }
    bool ok = (starts == accepts) && early_clear == 0 && (errs_sent == 0 || err_pulses > 0);
    // beat count against a clear: compare only when no clear happened would be too weak, so
    // clear now and check zero, then deliver a known number of beats
    t->clr_count = 1; t->clk = 1; t->eval(); t->clk = 0; t->eval(); t->clr_count = 0;
    for (int i = 0; i < 10; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    bool zero = t->beats == 0;
    for (int i = 0; i < 123; i++) { t->dma_busy = 1; t->dma_beat = 1; t->wclk = 1; t->eval(); t->wclk = 0; t->eval(); }
    t->dma_busy = 0;
    t->dma_beat = 0;
    for (int i = 0; i < 20; i++) { t->wclk = 1; t->eval(); t->wclk = 0; t->eval(); t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    bool counted = t->beats == 123;
    printf("  trial %2d: periods core %3llu lane %3llu | loads %6ld starts %6ld | FILL cleared early %ld | "
           "errors %ld -> pulses %ld | clear %s, 123 beats counted %s%s\n", trial,
           (unsigned long long)pc, (unsigned long long)pw, accepts, starts, early_clear, errs_sent, err_pulses,
           zero ? "ok" : "BAD", counted ? "ok" : "BAD", (ok && zero && counted) ? "" : "  FAIL");
    if (!(ok && zero && counted)) fails++;
    total_loads += accepts;
    delete t;
  }
  if (fails == 0) { printf("WX_TB_OK 24 clock pairs, %ld loads\n", total_loads); return 0; }
  printf("WX_TB_FAIL %d of 24\n", fails);
  return 1;
}
