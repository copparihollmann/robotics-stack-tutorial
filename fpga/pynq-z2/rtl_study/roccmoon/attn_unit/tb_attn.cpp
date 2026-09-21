// SPDX-License-Identifier: Apache-2.0
//
// tb_attn -- the attention unit against the curated kernels it replaces, byte for byte.
//
// One dispatch is one head: q [T][D], k [N][D], v [N][D] -> out [T][D].  The golden is
// attn_golden_head(), which is kernel_matmul_b_s8 -> kernel_softmax_s8 ->
// kernel_matmul_b_s8 with the kernels included as source, so agreement here is agreement
// with what hart 0 computes today for one batch element of encoder dispatches 17, 18, 19.
//
// The scratchpad is modelled here rather than instantiated, because mbxd_spad2 belongs to
// the engine: a registered read, one word per port per cycle, exactly
//   rd_data(t+1) = mem[rd_addr(t)]
// which is what mbxd_spad2.v does and what mbxr_tseq.v item 4 depends on.
//
// Cases
//   moonshine  every head of every layer of the real encoder, from acts.npz: 48 dispatches
//              of T=165, D=36, N=165 with the model's own scales, checked BOTH against the
//              C golden and against the recorded output activations.
//   random     random shapes and scales, random int8 operands, random back-pressure.
//   corner     ties in the row maximum, saturating scores, a one-row dispatch, N and D not
//              multiples of 4 or 8, the smallest legal G.
//   refuse     configurations the block must refuse (err[0]) rather than compute wrongly.
//
//   tb_attn [--shard i --nshards n] [--quick] [--moonshine FILE]
//
// Expect a final line beginning ATTN_TB_OK.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <vector>
#include <string>
#include <verilated.h>
// The DUT is mbxa_unit by default and mbxa_glue (the MERGED mbxr_lanes) when the build
// overrides these, so one testbench covers the block and its integration.
#ifndef ATTN_DUT_HDR
#define ATTN_DUT_HDR "Vmbxa_unit.h"
#endif
#ifndef ATTN_DUT
#define ATTN_DUT Vmbxa_unit
#endif
#include ATTN_DUT_HDR

extern "C" {
void attn_golden_head(const int8_t *q, const int8_t *k, const int8_t *v, int8_t *out,
                      int T, int D, int N,
                      float qk_sa, float qk_sb, float qk_so, float qk_sd,
                      float sm_si, float sm_so,
                      float av_sa, float av_sb, float av_so,
                      int8_t *scores, int8_t *probs);
int  attn_rq_consts(float sa, float sb, float so, float sd, uint32_t *mt, int *sh);
void attn_smx_cfg(float scale_in, float scale_out, uint32_t ex[256], int32_t *om, int *s);
}

// ---------------------------------------------------------------------------------------
// the device and the scratchpad it reads
// ---------------------------------------------------------------------------------------
static ATTN_DUT *dut;
static uint64_t g_cyc;

#define SPW 1024
/* THE BENCH'S OWN PLANE COUNT.  It modelled FOUR weight planes and drove read ports 1..4, so it
 * could not have exercised NCH = 8 whatever the image layout said -- ports 5..8 read nothing and
 * the accumulator took garbage.  That is half of why 0x5A5A0034's attention lane raised err[2]
 * on the board and this bench did not see it.  kstage.inc defines the same name with the same
 * default; defined here first because it is used above that include. */
#ifndef MBXA_NCH
#define MBXA_NCH 4
#endif
/* TWO BUFFERS, because the board has two and the lane chooses between them with a wire this
 * testbench used to pin to 0.  mbxr_lanes.v:312 addresses the lane's reads as
 * {5'd0, abuf, word}, and `abuf` is the engine's t_abuf -- set by `cfg` (funct 2), which
 * mbxr_attn_dispatch never issues.  Modelling one buffer cannot see that. */
static uint64_t sp_act[2][SPW];
static uint64_t sp_w[2][MBXA_NCH][SPW];
static int g_fill_buf = 0;
static int g_stale = 0;                 /* the buffer the fill targets */

static inline uint32_t rd_addr_port(int p)
{
    const uint32_t *w = (const uint32_t *)&dut->rd_addr;
    return (w[p >> 1] >> ((p & 1) * 16)) & 0xffffu;
}
static inline void rd_data_port(int p, uint64_t v)
{
    uint32_t *w = (uint32_t *)&dut->rd_data;
    w[p * 2]     = (uint32_t)v;
    w[p * 2 + 1] = (uint32_t)(v >> 32);
}

struct Sample { bool out_valid; uint64_t out_data; bool idle; uint32_t err; };

static uint64_t g_rng = 0x123456789abcdefull;
static inline uint64_t nxt()
{
    g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17; return g_rng;
}

static int g_hold_pct = 0;

static Sample cyc()
{
    dut->out_hold = (g_hold_pct && (int)(nxt() % 100) < g_hold_pct) ? 1 : 0;
    dut->eval();
    Sample s;
    s.out_valid = dut->out_valid;
    s.out_data  = dut->out_data;
    s.idle      = dut->idle;
    s.err       = dut->err;
    uint32_t a0 = rd_addr_port(0), w0 = rd_addr_port(1);
    uint32_t a = a0 & (SPW - 1), w = w0 & (SPW - 1);
    int ab = (a0 >> 10) & 1, wb = (w0 >> 10) & 1;
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    g_cyc++;
    rd_data_port(0, sp_act[ab][a]);
    for (int p = 1; p < MBXA_NCH + 1; p++) rd_data_port(p, sp_w[wb][p - 1][w]);
    return s;
}

static void cfg_w(uint32_t addr, uint32_t data)
{
    dut->cfg_we = 1; dut->cfg_addr = addr; dut->cfg_wdata = data;
    cyc();
    dut->cfg_we = 0;
}

// ---------------------------------------------------------------------------------------
// staging: what software must write, and the only place the layouts are defined
// ---------------------------------------------------------------------------------------
static inline int ceil_div(int a, int b) { return (a + b - 1) / b; }

static void put_byte(uint64_t *mem, int word, int byte, int8_t v)
{
    mem[word] &= ~((uint64_t)0xff << (byte * 8));
    mem[word] |= ((uint64_t)(uint8_t)v) << (byte * 8);
}

struct Shape {
    int T, D, N;
    int gs, qs, gp, qp;
    int kbase, vtbase;
};

static Shape shape_of(int T, int D, int N)
{
    Shape s;
    s.T = T; s.D = D; s.N = N;
    s.gs = ceil_div(D, 8); s.qs = ceil_div(N, MBXA_NCH);
    s.gp = ceil_div(N, 8); s.qp = ceil_div(D, MBXA_NCH);
    s.kbase = 0;
    s.vtbase = s.qs * (s.gs + 1);
    return s;
}

// q [T][D] -> activation words, rows abutting, the tail past D zeroed
// ---------------------------------------------------------------------------------------
// ATTN_KSTAGE=1: stage through the CURATED KERNEL'S OWN IMAGE BUILDERS and a model of the
// weight DMA's plane mapper, instead of the testbench's direct writes.
//
// WHY THIS EXISTS.  The 210-dispatch verification wrote sp_act / sp_w[c] DIRECTLY, so it
// never exercised two things the board does: the kernel's mbxa_build_q / mbxa_build_w, and
// the linear-image -> plane mapping (mbxr_engine.v:478, `pr = word >> lgpw`).  The board
// raises err[2] on every dispatch, which the accumulator bound says is impossible with
// int8 x int8 over K terms (ATTENTION_UNIT.md s10.10).  This path is the differential.
// ---------------------------------------------------------------------------------------
#include "../../../modelblaster/kernels/roccmoon/kstage.inc"

static void stage_via_kernel(const int8_t *q, const int8_t *k, const int8_t *v, const Shape &s)
{
    static int8_t q_img[SPW * 8], w_img[MBXA_NCH * 512 * 8];
    const int lgpw = 9;

    memset(sp_act[g_fill_buf], 0, sizeof(sp_act[g_fill_buf]));
    memset(sp_w[g_fill_buf], 0, sizeof(sp_w[g_fill_buf]));
    memset(q_img, 0, sizeof(q_img));
    memset(w_img, 0, sizeof(w_img));

    mbxa_build_q(q, s.T, s.D, s.gs, q_img);
    mbxa_build_w(k, v, s.N, s.D, s.gs, s.qs, s.gp, s.qp, lgpw, s.kbase, s.vtbase, w_img);

    // the activation DMA is flat: word i of the image is word i of the buffer
    for (int w = 0; w < s.T * s.gs && w < SPW; w++)
        memcpy(&sp_act[g_fill_buf][w], q_img + (size_t)w * 8, 8);
    // the weight DMA splits the linear image into planes of 2^lgpw words: plane = word >> lgpw
    for (int w = 0; w < (MBXA_NCH << lgpw); w++) {
        int pr = w >> lgpw, poff = w & ((1 << lgpw) - 1);
        if (pr < MBXA_NCH && poff < SPW) memcpy(&sp_w[g_fill_buf][pr][poff], w_img + (size_t)w * 8, 8);
    }
}

static void stage_q(const int8_t *q, const Shape &s)
{
    memset(sp_act[g_fill_buf], 0, sizeof(sp_act[g_fill_buf]));
    for (int t = 0; t < s.T; t++)
        for (int d = 0; d < s.D; d++)
            put_byte(sp_act[g_fill_buf], t * s.gs + d / 8, d % 8, q[t * s.D + d]);
}

// k [N][D] and v [N][D] -> the four weight planes, each quad a zero bias word then G words
static void stage_kv(const int8_t *k, const int8_t *v, const Shape &s)
{
    memset(sp_w[g_fill_buf], 0, sizeof(sp_w[g_fill_buf]));
    for (int j = 0; j < s.qs; j++)
        for (int c = 0; c < MBXA_NCH; c++) {
            int n = MBXA_NCH * j + c;
            if (n >= s.N) continue;                       // padded rows stay zero
            for (int d = 0; d < s.D; d++)
                put_byte(sp_w[g_fill_buf][c], s.kbase + j * (s.gs + 1) + 1 + d / 8, d % 8,
                         k[n * s.D + d]);
        }
    for (int j = 0; j < s.qp; j++)
        for (int c = 0; c < MBXA_NCH; c++) {
            int d = MBXA_NCH * j + c;
            if (d >= s.D) continue;
            for (int n = 0; n < s.N; n++)                 // v^T row d
                put_byte(sp_w[g_fill_buf][c], s.vtbase + j * (s.gp + 1) + 1 + n / 8, n % 8,
                         v[n * s.D + d]);
        }
}

// ---------------------------------------------------------------------------------------
// one dispatch
// ---------------------------------------------------------------------------------------
struct Stats { uint64_t cycles; int err; };

static bool dispatch(const Shape &s,
                     uint32_t mt_s, int sh_s, uint32_t mt_p, int sh_p,
                     const uint32_t ex[256], int32_t om, int smx_s,
                     std::vector<uint8_t> &got, Stats *st)
{
    for (int i = 0; i < 256; i++) cfg_w(i, ex[i]);
    cfg_w(0x100, (uint32_t)om);
    cfg_w(0x101, (uint32_t)smx_s);
    cfg_w(0x102, (uint32_t)s.N);
    cfg_w(0x103, 0);
    cfg_w(0x200, 0);
    cfg_w(0x201, s.kbase);
    cfg_w(0x202, s.vtbase);
    cfg_w(0x203, s.gs);
    cfg_w(0x204, s.qs);
    cfg_w(0x205, s.gp);
    cfg_w(0x206, s.qp);
    cfg_w(0x207, s.T);
    cfg_w(0x208, s.N);
    cfg_w(0x209, s.D);
    cfg_w(0x20a, mt_s);
    cfg_w(0x20b, (uint32_t)sh_s | (0x80u << 8) | (0x7fu << 16));
    cfg_w(0x20c, mt_p);
    cfg_w(0x20d, (uint32_t)sh_p | (0x80u << 8) | (0x7fu << 16));
    cfg_w(0x20e, 0);

    size_t want_words = ((size_t)ceil_div(s.T * s.D, 8) + 7) / 8 * 8;
    // a generous bound on a correct run: (gs + 1) * qs + (gp + 1) * qp steps a row, plus
    // the pipeline, plus whatever back-pressure the caller injects
    uint64_t cap = 64ull * s.T * ((uint64_t)(s.gs + 1) * s.qs + (uint64_t)(s.gp + 1) * s.qp)
                   + 200000ull;
    got.clear();
    uint64_t t0 = g_cyc;
    dut->start = 1; cyc(); dut->start = 0;
    int err = 0;
    bool done = false;
    while (g_cyc - t0 < cap) {
        Sample sm = cyc();
        err |= sm.err;
        if (sm.out_valid) {
            for (int b = 0; b < 8; b++) got.push_back((uint8_t)(sm.out_data >> (b * 8)));
        }
        if (sm.idle && got.size() >= want_words * 8) { done = true; break; }
    }
    st->cycles = g_cyc - t0;
    st->err = err;
    if (!done)
        printf("ATTN_TB_FAIL: dispatch did not finish in %llu cycles (%zu of %zu bytes,"
               " idle=%d)\n", (unsigned long long)cap, got.size(), want_words * 8,
               (int)dut->idle);
    return done && got.size() == want_words * 8;
}

// ---------------------------------------------------------------------------------------
static uint64_t n_disp = 0, n_rows = 0, n_bytes = 0, n_bad = 0, n_bp = 0, n_vs_acts = 0;
// acts.npz holds the EXTRACTOR'S float reference chain, not the curated kernels': the
// softmax kernel's accuracy class is numeric_drift (<= 2 LSB), and that drift amplifies
// through the weighted sum.  Measured in pure software, with no RTL involved: scores 0 of
// 1,306,800 differ, probs 1,510 (0.1155 %), output 4,204 of 285,120 (1.4745 %), and the
// output is exact again when the recorded probs are fed in.  So the golden for the RTL is
// the kernels -- what the board runs -- and the acts comparison is a statistic whose only
// requirement is that the RTL drifts from acts in EXACTLY the places the software does.
static uint64_t n_acts_rtl = 0, n_acts_gold = 0;
static double perf_cyc_per_row = 0; static uint64_t perf_rows = 0;
static double perf_ms_cyc = 0; static uint64_t perf_ms_rows = 0;  // Moonshine's own shape, no back-pressure

static bool one_case(const char *name, int T, int D, int N,
                     const int8_t *q, const int8_t *k, const int8_t *v,
                     float qk_sa, float qk_sb, float qk_so, float qk_sd,
                     float sm_si, float sm_so, float av_sa, float av_sb, float av_so,
                     const int8_t *acts_out, int hold_pct)
{
    uint32_t mt_s, mt_p; int sh_s, sh_p;
    if (!attn_rq_consts(qk_sa, qk_sb, qk_so, qk_sd, &mt_s, &sh_s)) return false;
    if (!attn_rq_consts(av_sa, av_sb, av_so, 1.0f, &mt_p, &sh_p)) return false;
    uint32_t ex[256]; int32_t om; int ss;
    attn_smx_cfg(sm_si, sm_so, ex, &om, &ss);
    if (ss < 0) return false;

    Shape s = shape_of(T, D, N);
    // shapes the block refuses by design, and the scratchpad's own capacity
    if (s.gs < 2 || s.gp < 2 || s.gp > 32) return false;      // both reductions need K >= 9
    if (s.T * s.gs > SPW) return false;
    if (s.vtbase + s.qp * (s.gp + 1) > SPW) return false;

    std::vector<int8_t> want((size_t)T * D), scores((size_t)T * N), probs((size_t)T * N);
    attn_golden_head(q, k, v, want.data(), T, D, N, qk_sa, qk_sb, qk_so, qk_sd,
                     sm_si, sm_so, av_sa, av_sb, av_so, scores.data(), probs.data());

    if (getenv("ATTN_KSTAGE") && atoi(getenv("ATTN_KSTAGE"))) {
        // The kernel's `fits` guard, applied here too: at lgpw = 9 a plane is 512 words, and
        // the kernel REFUSES a shape needing more.  The testbench's own guard is SPW = 1024
        // -- it writes sp_w[c] directly and has no plane -- so without this the differential
        // reports the harness's mismatch as a builder defect.  It did, first run: 13,264
        // differing bytes on random shapes, 0 on Moonshine's.
        if (s.vtbase + s.qp * (s.gp + 1) > 512) return false;
        stage_via_kernel(q, k, v, s);
    }
    else {
        stage_q(q, s);
        stage_kv(k, v, s);
    }

    g_hold_pct = hold_pct;
    std::vector<uint8_t> got;
    Stats st;
    bool ok = dispatch(s, mt_s, sh_s, mt_p, sh_p, ex, om, ss, got, &st);
    g_hold_pct = 0;

    n_disp++; n_rows += T; n_bytes += (uint64_t)T * D;
    if (hold_pct) n_bp++;
    perf_cyc_per_row += (double)st.cycles; perf_rows += T;
    if (T == 165 && D == 36 && N == 165 && !hold_pct) {
        perf_ms_cyc += (double)st.cycles; perf_ms_rows += T;
    }

    if (!ok) {
        printf("ATTN_TB_FAIL %s: %zu output bytes, expected at least %d\n",
               name, got.size(), T * D);
        n_bad++;
        return true;
    }
    if (st.err) {
        printf("ATTN_TB_FAIL %s: err = 0x%x\n", name, st.err);
        n_bad++;
        return true;
    }
    uint64_t bad = 0;
    for (int i = 0; i < T * D; i++)
        if ((int8_t)got[i] != want[i]) {
            if (bad < 4)
                printf("ATTN_TB_MISMATCH %s: byte %d (t=%d d=%d) want %d got %d\n",
                       name, i, i / D, i % D, want[i], (int8_t)got[i]);
            bad++;
        }
    for (size_t i = (size_t)T * D; i < got.size(); i++)
        if (got[i] != 0) {
            if (bad < 4) printf("ATTN_TB_MISMATCH %s: pad byte %zu is %d\n", name, i, got[i]);
            bad++;
        }
    if (acts_out) {
        for (int i = 0; i < T * D; i++) {
            if ((int8_t)got[i] != acts_out[i]) n_acts_rtl++;
            if (want[i] != acts_out[i]) n_acts_gold++;
            // the only requirement: the RTL agrees with acts wherever the software does
            if (((int8_t)got[i] != acts_out[i]) != (want[i] != acts_out[i])) {
                if (bad < 4)
                    printf("ATTN_TB_MISMATCH %s: byte %d acts %d golden %d rtl %d\n",
                           name, i, acts_out[i], want[i], (int8_t)got[i]);
                bad++;
            }
        }
        n_vs_acts += (uint64_t)T * D;
    }
    n_bad += bad;
    return true;
}

// ---------------------------------------------------------------------------------------
static float rnd_scale(int lo, int hi)
{
    int e = lo + (int)(nxt() % (uint64_t)(hi - lo));
    float m = 1.0f + (float)(nxt() % 8388608) / 8388608.0f;
    return (float)ldexp(m, e);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    int shard = 0, nshards = 1, quick = 0;
    const char *mfile = nullptr;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--shard")) shard = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nshards")) nshards = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quick")) quick = 1;
        else if (!strcmp(argv[i], "--moonshine")) mfile = argv[++i];
    }
    g_rng ^= (uint64_t)(shard + 1) * 0x9e3779b97f4a7c15ull;

    dut = new ATTN_DUT;
    dut->clk = 0; dut->rst = 1; dut->cfg_we = 0; dut->start = 0;
    dut->out_hold = 0; dut->abuf = 0; dut->wbuf = 0;
#ifdef ATTN_HAS_BUF
    /* ATTN_STALEBUF: the `cfg`/t_abuf hypothesis (ATTENTION_UNIT.md s10.12).
     *   0  control -- the lane reads the buffer the fill targeted
     *   1  *** NOT A CLEAN CONTROL -- DO NOT DRAW THE INTENDED CONCLUSION FROM IT. ***
     *      It was meant to be a valid image with ZERO bias words, so that a difference from
     *      case 2 would separate "reads the wrong buffer" from "reads a non-zero bias word".
     *      It is a memset of the WHOLE buffer, so the word at each quad head -- the bias
     *      position -- is 0x05060708 = 84,281,096, FIVE TIMES the err[2] threshold.  Both
     *      cases therefore carry a non-zero bias and both raise err[2]; this pair shows
     *      "stale buffer -> err[2]" and CANNOT attribute it.  Making it a real control needs
     *      a legal quad layout (zero bias at stride gs+1 for k, gp+1 for v^T), which is
     *      per-shape work rather than one line -- and that asymmetry is the lesson: THE
     *      CHEAP WAY TO BUILD A CONTROL IS USUALLY THE WAY THAT MAKES IT INSENSITIVE TO THE
     *      THING IT IS CONTROLLING FOR.
     *   2  the other buffer holds a previous dispatch's leavings WITH A NON-ZERO BIAS WORD.
     *      If a non-zero bias is what fires err[2], only this case does.
     * The two together discriminate "reads the wrong buffer" from "reads a non-zero bias",
     * which matter differently: the first is a missing `cfg`, the second is a stale plane.
     * Modelling only case 2 would reproduce the symptom for a reason I had not established. */
    g_stale = getenv("ATTN_STALEBUF") ? atoi(getenv("ATTN_STALEBUF")) : 0;
    if (g_stale) {
        dut->abuf = 1; dut->wbuf = 1;          /* the lane reads buffer 1 ... */
        g_fill_buf = 0;                        /* ... while the fill targets buffer 0 */
        for (int b = 0; b < SPW; b++) {
            sp_act[1][b] = 0x0102030405060708ull;
            for (int c = 0; c < MBXA_NCH; c++)
                sp_w[1][c][b] = (g_stale == 2 && (b % 6) == 0)
                                ? 0x7fffffff7fffffffull   /* a NON-ZERO BIAS WORD */
                                : 0x0102030405060708ull;  /* plausible int8 payload */
        }
    }
#endif
    for (int i = 0; i < 8; i++) cyc();
    dut->rst = 0;
    cyc();

    // ---- moonshine: every head of every layer, real activations ------------------------
    uint64_t m_disp = 0, m_before = n_bad;
    if (mfile) {
        FILE *f = fopen(mfile, "rb");
        if (!f) { printf("ATTN_TB_FAIL: cannot open %s\n", mfile); return 1; }
        char magic[4]; uint32_t nl;
        if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "ATTN", 4) ||
            fread(&nl, 4, 1, f) != 1) { printf("ATTN_TB_FAIL: bad %s\n", mfile); return 1; }
        for (uint32_t L = 0; L < nl; L++) {
            float sc[9]; uint32_t sh4[4];
            if (fread(sc, 4, 9, f) != 9 || fread(sh4, 4, 4, f) != 4) break;
            int B = sh4[0], T = sh4[1], D = sh4[2], N = sh4[3];
            std::vector<int8_t> q((size_t)B * T * D), k((size_t)B * N * D),
                                v((size_t)B * N * D), o((size_t)B * T * D);
            if (fread(q.data(), 1, q.size(), f) != q.size()) break;
            if (fread(k.data(), 1, k.size(), f) != k.size()) break;
            if (fread(v.data(), 1, v.size(), f) != v.size()) break;
            if (fread(o.data(), 1, o.size(), f) != o.size()) break;
            for (int b = 0; b < B; b++) {
                if ((int)((L * B + b) % nshards) != shard) continue;
                if (quick && b > 0) continue;
                char nm[64]; snprintf(nm, sizeof(nm), "moonshine L%u h%d", L, b);
                int hold = ((L * B + b) % 3 == 0) ? 20 : 0;
                if (one_case(nm, T, D, N, q.data() + (size_t)b * T * D,
                             k.data() + (size_t)b * N * D, v.data() + (size_t)b * N * D,
                             sc[0], sc[1], sc[2], sc[3], sc[4], sc[5], sc[6], sc[7], sc[8],
                             o.data() + (size_t)b * T * D, hold))
                    m_disp++;
            }
        }
        fclose(f);
        printf("ATTN_TB_CASE moonshine: %llu head dispatches, %llu bytes, %llu differ\n",
               (unsigned long long)m_disp, (unsigned long long)n_vs_acts,
               (unsigned long long)(n_bad - m_before));
        printf("ATTN_TB_ACTS %llu bytes against acts.npz: RTL differs in %llu, the curated"
               " kernels differ in %llu (the softmax kernel's numeric_drift)\n",
               (unsigned long long)n_vs_acts, (unsigned long long)n_acts_rtl,
               (unsigned long long)n_acts_gold);
    }

    // ---- random shapes, scales and operands --------------------------------------------
    {
        uint64_t before = n_bad, d0 = n_disp;
        int ntr = quick ? 6 : 140;
        for (int t = 0; t < ntr; t++) {
            if ((t % nshards) != shard) continue;
            int T = 1 + (int)(nxt() % 24);
            int D = 9 + (int)(nxt() % 56);
            int N = 9 + (int)(nxt() % 248);
            if ((nxt() & 7) == 0) { T = 165; D = 36; N = 165; }
            std::vector<int8_t> q((size_t)T * D), k((size_t)N * D), v((size_t)N * D);
            for (auto &x : q) x = (int8_t)(nxt() & 0xff);
            for (auto &x : k) x = (int8_t)(nxt() & 0xff);
            for (auto &x : v) x = (int8_t)(nxt() & 0xff);
            float qk_so = rnd_scale(-4, 2), sm_so = rnd_scale(-9, -5);
            one_case("random", T, D, N, q.data(), k.data(), v.data(),
                     rnd_scale(-6, 0), rnd_scale(-6, 0), qk_so, (nxt() & 1) ? 6.0f : 1.0f,
                     qk_so, sm_so, sm_so, rnd_scale(-6, 0), rnd_scale(-6, 0),
                     nullptr, (int)(nxt() % 3) * 15);
        }
        printf("ATTN_TB_CASE random: %llu dispatches, %llu differ\n",
               (unsigned long long)(n_disp - d0), (unsigned long long)(n_bad - before));
    }

    // ---- corners ------------------------------------------------------------------------
    {
        uint64_t before = n_bad, d0 = n_disp;
        struct { int T, D, N; const char *why; } cs[] = {
            { 1, 36, 165, "a single query row" },
            { 3, 36, 165, "fewer rows than the lookahead" },
            { 4, 36, 167, "N not a multiple of 4: the surplus scores are dropped" },
            { 4, 33, 165, "D not a multiple of 4 or 8" },
            { 5, 16, 9,   "the smallest legal G on both phases" },
            { 2, 64, 256, "the widest p ring the four slots hold" },
            { 165, 36, 165, "Moonshine's own shape, synthetic operands" },
        };
        for (size_t c = 0; c < sizeof(cs) / sizeof(cs[0]); c++) {
            if ((int)(c % nshards) != shard) continue;
            int T = cs[c].T, D = cs[c].D, N = cs[c].N;
            for (int mode = 0; mode < 4; mode++) {
                std::vector<int8_t> q((size_t)T * D), k((size_t)N * D), v((size_t)N * D);
                switch (mode) {
                case 0:  // every score equal: the row maximum is a tie everywhere
                    for (auto &x : q) x = 1;
                    for (auto &x : k) x = 1;
                    for (auto &x : v) x = (int8_t)(nxt() & 0xff);
                    break;
                case 1:  // saturating scores at both ends
                    for (auto &x : q) x = (int8_t)((nxt() & 1) ? 127 : -128);
                    for (auto &x : k) x = (int8_t)((nxt() & 1) ? 127 : -128);
                    for (auto &x : v) x = (int8_t)((nxt() & 1) ? 127 : -128);
                    break;
                case 2:  // all zero: sum of exponentials is at its floor, p is uniform
                    break;
                default:
                    for (auto &x : q) x = (int8_t)(nxt() & 0xff);
                    for (auto &x : k) x = (int8_t)(nxt() & 0xff);
                    for (auto &x : v) x = (int8_t)(nxt() & 0xff);
                }
                char nm[96];
                snprintf(nm, sizeof(nm), "corner %s mode %d", cs[c].why, mode);
                one_case(nm, T, D, N, q.data(), k.data(), v.data(),
                         0.0756474892924151f, 0.09842554227573665f, 0.2807556926612239f,
                         6.0f, 0.2807556926612239f, 0.007874015748031496f,
                         0.007874015748031496f, 0.047303631549745095f,
                         0.028866251622598003f, nullptr, (mode == 3) ? 25 : 0);
            }
        }
        printf("ATTN_TB_CASE corner: %llu dispatches, %llu differ\n",
               (unsigned long long)(n_disp - d0), (unsigned long long)(n_bad - before));
    }

    // ---- configurations that must be refused --------------------------------------------
    if (shard == 0) {
        struct { uint32_t addr, val; const char *why; } bad[] = {
            { 0x203, 1,    "gs = 1: the serialiser needs three cycles between quads" },
            { 0x205, 1,    "gp = 1" },
            { 0x205, 64,   "gp too wide for four slots of the p ring" },
            { 0x207, 0,    "no rows" },
            { 0x208, 1000, "nsc beyond the quads the scores phase produces" },
            { 0x209, 1000, "nout beyond the quads the p.v phase produces" },
        };
        Shape s = shape_of(8, 36, 40);
        int refused = 0;
        for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
            cfg_w(0x201, s.kbase); cfg_w(0x202, s.vtbase);
            cfg_w(0x203, s.gs); cfg_w(0x204, s.qs); cfg_w(0x205, s.gp); cfg_w(0x206, s.qp);
            cfg_w(0x207, s.T); cfg_w(0x208, s.N); cfg_w(0x209, s.D);
            cfg_w(0x20a, 9491883); cfg_w(0x20b, 31 | (0x80u << 8) | (0x7fu << 16));
            cfg_w(0x20c, 13854799); cfg_w(0x20d, 30 | (0x80u << 8) | (0x7fu << 16));
            cfg_w(0x20e, 0);
            cfg_w(bad[i].addr, bad[i].val);
            Sample sm = cyc();
            if (!(sm.err & 1)) {
                printf("ATTN_TB_FAIL: %s was accepted (err = 0x%x)\n", bad[i].why, sm.err);
                n_bad++;
            } else {
                dut->start = 1; cyc(); dut->start = 0;
                for (int n = 0; n < 32; n++) sm = cyc();
                if (!sm.idle) {
                    printf("ATTN_TB_FAIL: %s started anyway\n", bad[i].why);
                    n_bad++;
                } else {
                    refused++;
                }
            }
        }
        printf("ATTN_TB_CASE refuse: %d of %zu unusable configurations refused\n",
               refused, sizeof(bad) / sizeof(bad[0]));
    }

    if (perf_rows)
        printf("ATTN_TB_PERF %.3f cycles per query row over %llu rows\n",
               perf_cyc_per_row / (double)perf_rows, (unsigned long long)perf_rows);
    if (perf_ms_rows)
        printf("ATTN_TB_PERFMS %.3f cycles per query row over %llu rows at T=165 D=36 N=165,"
               " no back-pressure\n", perf_ms_cyc / (double)perf_ms_rows,
               (unsigned long long)perf_ms_rows);
    printf("%s shard %d/%d: %llu dispatches (%llu with back-pressure), %llu rows, "
           "%llu output bytes, %llu differ from the curated kernels\n",
           n_bad ? "ATTN_TB_FAILED" : "ATTN_TB_OK", shard, nshards,
           (unsigned long long)n_disp, (unsigned long long)n_bp,
           (unsigned long long)n_rows, (unsigned long long)n_bytes,
           (unsigned long long)n_bad);
    delete dut;
    return n_bad != 0;
}
