// SPDX-License-Identifier: Apache-2.0
//
// tb_rq -- mbxa_rq against kernel_matmul_b_s8's own requantise tail, EXHAUSTIVELY.
//
// The kernel's tail has two paths (a fixed-point fast path and, for near-ties, fexact32's
// pmmb_exact); mbxa_rq has one.  The claim that they agree everywhere is checked here over
// EVERY accumulator either Moonshine matmul can produce -- q.kT's |acc| <= 36*127*128 and
// p.v's |acc| <= 165*127*128, both signs, 6,534,914 values -- and then over random (mt, sh)
// against random accumulators, including the 2^24 domain edge.
//
//   tb_rq [--shard i --nshards n] [--quick]
//
// Expect a final line beginning RQ_TB_OK.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <cmath>
#include <verilated.h>
#include "Vmbxa_rq.h"

extern "C" {
int attn_rq_consts(float sa, float sb, float so, float sd, uint32_t *mt, int *sh);
int attn_rq_ref(int64_t acc, uint32_t mt, int sh, int amin, int amax, int *took_slow);
}

static Vmbxa_rq *dut;
static uint64_t g_cyc = 0;

static void tick()
{
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    g_cyc++;
}

// The block is a five-stage pipeline with one value per cycle.  Feed a batch, collect in
// order, compare.  Nothing here ever back-pressures: mbxa_rq has no ready.
struct Item { int32_t acc; int want; };

static uint64_t n_checked = 0, n_bad = 0, n_slow = 0, n_ovf = 0;
static int g_quiet = 0;   // the out-of-domain block expects disagreement

static void run_batch(const std::vector<Item> &v, uint32_t mt, int sh, int amin, int amax)
{
    size_t i = 0, o = 0;
    dut->mt = mt; dut->sh = sh; dut->amin = (uint8_t)amin; dut->amax = (uint8_t)amax;
    dut->in_tag = 0;
    while (o < v.size()) {
        dut->in_valid = (i < v.size());
        dut->acc = (i < v.size()) ? (uint32_t)v[i].acc : 0;
        tick();
        if (i < v.size()) i++;
        if (dut->out_valid) {
            int got = (int8_t)dut->y;
            if (dut->ovf) n_ovf++;
            if (got != v[o].want) {
                if (n_bad < 8 && !g_quiet)
                    printf("RQ_TB_MISMATCH mt=%u sh=%d acc=%d want=%d got=%d\n",
                           mt, sh, v[o].acc, v[o].want, got);
                n_bad++;
            }
            n_checked++;
            o++;
        }
    }
    dut->in_valid = 0;
}

struct Case { const char *name; float sa, sb, so, sd; long lim; };

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    int shard = 0, nshards = 1, quick = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--shard")) shard = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nshards")) nshards = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quick")) quick = 1;
    }
    dut = new Vmbxa_rq;
    dut->clk = 0; dut->rst = 1; dut->in_valid = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;

    // ---- 1. exhaustive at Moonshine's own two constant sets ----------------------------
    Case cases[2] = {
        { "qk", 0.0756474892924151f, 0.09842554227573665f, 0.2807556926612239f, 6.0f,
          36L * 127 * 128 },
        { "av", 0.007874015748031496f, 0.047303631549745095f, 0.028866251622598003f, 1.0f,
          165L * 127 * 128 },
    };
    for (int c = 0; c < 2; c++) {
        uint32_t mt; int sh;
        if (!attn_rq_consts(cases[c].sa, cases[c].sb, cases[c].so, cases[c].sd, &mt, &sh)) {
            printf("RQ_TB_FAIL: %s constants out of domain\n", cases[c].name);
            return 1;
        }
        long lim = quick ? 20000 : cases[c].lim;
        long lo = -lim + (long)((2 * lim + 1) * (long long)shard / nshards);
        long hi = -lim + (long)((2 * lim + 1) * (long long)(shard + 1) / nshards);
        uint64_t before = n_checked, slow_before = n_slow;
        std::vector<Item> batch;
        batch.reserve(4096);
        for (long a = lo; a < hi; a++) {
            int slow = 0;
            int want = attn_rq_ref(a, mt, sh, -128, 127, &slow);
            n_slow += slow;
            batch.push_back({ (int32_t)a, want });
            if (batch.size() == 4096) { run_batch(batch, mt, sh, -128, 127); batch.clear(); }
        }
        if (!batch.empty()) run_batch(batch, mt, sh, -128, 127);
        printf("RQ_TB_CASE %s: mt=%u sh=%d, %llu accumulators, %llu on the kernel's slow path\n",
               cases[c].name, mt, sh,
               (unsigned long long)(n_checked - before),
               (unsigned long long)(n_slow - slow_before));
    }

    // ---- 2. random scales, random accumulators, and the 2^24 domain edge ---------------
    uint64_t rng = 0x9e3779b97f4a7c15ull ^ (uint64_t)(shard + 1) * 0x243f6a8885a308d3ull;
    auto nxt = [&]() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; };
    auto rndf = [&]() {
        // a positive binary32 in roughly [2^-20, 2^4], the calibrated-scale range
        int e = (int)(nxt() % 25) - 20;
        float m = 1.0f + (float)(nxt() % 8388608) / 8388608.0f;
        return (float)ldexp(m, e);
    };
    long ntr = quick ? 200 : 4000;
    uint64_t before = n_checked, slow_before = n_slow;
    long used = 0;
    for (long t = 0; t < ntr; t++) {
        uint32_t mt; int sh;
        float sa = rndf(), sb = rndf(), so = rndf(), sd = (nxt() & 1) ? 1.0f : 6.0f;
        if (!attn_rq_consts(sa, sb, so, sd, &mt, &sh)) continue;
        int amin = (nxt() & 7) ? -128 : -(int)(nxt() % 128);
        int amax = (nxt() & 7) ?  127 :  (int)(nxt() % 128);
        if (amin > amax) amin = amax;
        std::vector<Item> batch;
        for (int i = 0; i < 512; i++) {
            int64_t a;
            switch (i % 4) {
            case 0: a = (int64_t)(nxt() % (1u << 24)); break;              // full domain
            case 1: a = (int64_t)(nxt() % 4096); break;                    // small
            case 2: a = (int64_t)((1u << 24) - 1 - (nxt() % 8)); break;    // the edge
            default: a = (int64_t)(nxt() % 1024) * 16384; break;           // MAC-like
            }
            if (nxt() & 1) a = -a;
            int slow = 0;
            int want = attn_rq_ref(a, mt, sh, amin, amax, &slow);
            n_slow += slow;
            batch.push_back({ (int32_t)a, want });
        }
        run_batch(batch, mt, sh, amin, amax);
        used++;
    }
    printf("RQ_TB_CASE random: %ld scale sets, %llu accumulators, %llu on the kernel's slow path\n",
           used, (unsigned long long)(n_checked - before),
           (unsigned long long)(n_slow - slow_before));

    // ---- 3. the UNCLAMPED band, contiguously -------------------------------------------
    // The exhaustive sweep above is mostly saturated: at Moonshine's constants only about
    // 20,000 of the 6.5 M accumulators produce a number rather than a clamp, and the
    // float32 multiply's inner rounding can only change a number.  So it is blind to the
    // one thing mbxa_rq does that a cheaper requantiser would not -- rounding the product
    // to 24 significant bits half-to-even.  (Three mutants of exactly that survived the
    // sweep; see ATTENTION_UNIT.md 3.4.)  This case sweeps CONTIGUOUS windows inside the
    // band |acc| * mt < 129 * 2^sh, where the output is unclamped and consecutive
    // accumulators walk across the rounding boundaries one ulp at a time.
    {
        uint64_t before = n_checked, slow_before = n_slow;
        long nset = quick ? 12 : 900;
        long used = 0;
        for (long t = 0; t < nset; t++) {
            uint32_t mt; int sh;
            float sa, sb, so, sd;
            if (t < 2) {   // Moonshine's own two, first
                sa = cases[t].sa; sb = cases[t].sb; so = cases[t].so; sd = cases[t].sd;
            } else {
                sa = rndf(); sb = rndf(); so = rndf(); sd = (nxt() & 1) ? 1.0f : 6.0f;
            }
            if (!attn_rq_consts(sa, sb, so, sd, &mt, &sh)) continue;
            if ((used % nshards) != shard) { used++; continue; }
            used++;
            // the largest |acc| whose output is not saturated, and a window inside it
            uint64_t amax = ((uint64_t)129 << sh) / mt;
            if (amax > 0xffffffull) amax = 0xffffffull;
            long win = quick ? 4000 : 40000;
            if ((long)amax < win) win = (long)amax + 1;
            long a0 = (amax > (uint64_t)win) ? (long)(nxt() % (amax - win + 1)) : 0;
            std::vector<Item> batch;
            batch.reserve(win);
            for (long i = 0; i < win; i++) {
                int64_t a = a0 + i;
                if (i & 1) a = -a;
                int slow = 0;
                int want = attn_rq_ref(a, mt, sh, -128, 127, &slow);
                n_slow += slow;
                batch.push_back({ (int32_t)a, want });
                if (batch.size() == 8192) { run_batch(batch, mt, sh, -128, 127); batch.clear(); }
            }
            if (!batch.empty()) run_batch(batch, mt, sh, -128, 127);
        }
        printf("RQ_TB_CASE unclamped: %ld scale sets, %llu accumulators inside the "
               "unclamped band, %llu on the kernel's slow path\n", used,
               (unsigned long long)(n_checked - before),
               (unsigned long long)(n_slow - slow_before));
    }

    // ---- 3. the domain guard: |acc| >= 2^24 must raise ovf -----------------------------
    {
        uint32_t mt; int sh;
        attn_rq_consts(cases[0].sa, cases[0].sb, cases[0].so, cases[0].sd, &mt, &sh);
        uint64_t ov_before = n_ovf;
        std::vector<Item> batch;
        for (int i = 0; i < 64; i++) {
            int32_t a = (int32_t)((1u << 24) + (uint32_t)i * 7919u);
            int slow = 0;
            batch.push_back({ a, attn_rq_ref(a, mt, sh, -128, 127, &slow) });
        }
        // the answers are not required to match out there; only the flag is
        uint64_t before_bad = n_bad;
        g_quiet = 1;
        run_batch(batch, mt, sh, -128, 127);
        g_quiet = 0;
        n_bad = before_bad;
        if (n_ovf - ov_before != 64) {
            printf("RQ_TB_FAIL: ovf raised %llu times for 64 out-of-domain accumulators\n",
                   (unsigned long long)(n_ovf - ov_before));
            n_bad++;
        } else {
            printf("RQ_TB_CASE domain: 64 accumulators at or above 2^24, all flagged\n");
        }
    }

    printf("%s shard %d/%d: %llu requantises, %llu on the kernel's slow path, %llu differ\n",
           n_bad ? "RQ_TB_FAILED" : "RQ_TB_OK", shard, nshards,
           (unsigned long long)n_checked, (unsigned long long)n_slow,
           (unsigned long long)n_bad);
    delete dut;
    return n_bad != 0;
}
