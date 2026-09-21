/* SPDX-License-Identifier: Apache-2.0
 *
 * The decoupled RoCC engine on the silicon: placement, bit-exactness, timing, and its port.
 *
 * FOUR HALVES, IN THE ORDER A SKEPTIC WOULD ASK FOR THEM.
 *
 *  1. PLACEMENT.  The engine is a RoCC in hart 1's tile, custom-1.  So: a custom-1 command on
 *     hart 1 returns the engine's identity word; the same instruction on hart 0 must TRAP
 *     (hart 0 has no RoCC); and MBP.DOT8 (custom-0) on hart 1 must still TRAP -- which is
 *     what patches/0101 exists for, because without it RoCCDecode claims custom-0 on hart 1
 *     and the instruction hangs the hart instead.
 *
 *  2. BIT-EXACTNESS ON THE BOARD.  Random shapes and quantisation parameters.  Every output
 *     of the engine is compared with ModelBlaster's kernel_linear_s8 reference AND with the
 *     curated MBP kernel hart 0 runs, element by element.  The gate is max_abs_err = 0.
 *
 *  3. MOONSHINE TINY'S LINEAR SHAPES, both ways.  The core: the curated MBP kernel on hart 0,
 *     weights in DRAM exactly where a model's weights would be.  The engine: the driver on
 *     hart 1.  Cycles on hart 1 around the driver call AND on hart 0 around the whole
 *     hand-off, because a dispatch pays both.
 *
 *  4. THE ENGINE'S OWN PORT.  The decode projection -- 9.4 MB of weights at AI ~ 1, the
 *     workload that is memory-bound -- at an outstanding cap of 1..8, with the fill beats and
 *     fill-busy cycles the engine counts itself.  That is the measured port INSIDE the
 *     accelerator, to set beside MEMORY_BANDWIDTH.md's instrument.
 *
 * Every result is one line beginning RMB_ for scripts/51_rocket_roccmoon.sh to parse.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>
#include <string.h>

#include "pext.h"
#include "mbxr.h"

void ref_kernel_linear_s8(const int8_t *input, const int8_t *weight, const int32_t *bias,
			  int8_t *output, int M, int K, int N, int input_offset,
			  int filter_offset, int output_offset, int output_multiplier,
			  int output_shift, int activation_min, int activation_max);
void pext_kernel_linear_s8(const int8_t *input, const int8_t *weight, const int32_t *bias,
			   int8_t *output, int M, int K, int N, int input_offset,
			   int filter_offset, int output_offset, int output_multiplier,
			   int output_shift, int activation_min, int activation_max);
void pext_kernel_matmul_b_s8(const int8_t *a, const int8_t *b, int8_t *output,
			     int B, int M, int K, int N,
			     float scale_a, float scale_b, float scale_out,
			     int transpose_b, float scale_div,
			     int activation_min, int activation_max);
/* the same file with -DMBP_MMB_NO_SPECIALIZE: the general nest, for the A/B and the identity gate */
void pext_ref_matmul_b_s8(const int8_t *a, const int8_t *b, int8_t *output,
			  int B, int M, int K, int N,
			  float scale_a, float scale_b, float scale_out,
			  int transpose_b, float scale_div,
			  int activation_min, int activation_max);

/* ---- section 5: the curated kernel files, renamed exactly as ModelBlaster renames them ---- */
#define MBXR_RT_TYPES_ONLY
#include "roccmoon/mbxr_rt.h"
void rm_kernel_linear_s8(const int8_t *input, const int8_t *weight, const int32_t *bias,
			 int8_t *output, int M, int K, int N, int input_offset, int filter_offset,
			 int output_offset, int output_multiplier, int output_shift,
			 int activation_min, int activation_max);
void rm_kernel_conv2d_s8(const int8_t *input, const int8_t *weight, const int32_t *bias,
			 int8_t *output, int N, int IC, int IH, int IW, int OC, int KH, int KW,
			 int SH, int SW, int PH, int PW, int input_offset, int filter_offset,
			 int output_offset, int output_multiplier, int output_shift,
			 int activation_min, int activation_max);
void kernel_conv2d_s8(const int8_t *input, const int8_t *weight, const int32_t *bias,
		      int8_t *output, int N, int IC, int IH, int IW, int OC, int KH, int KW,
		      int SH, int SW, int PH, int PW, int input_offset, int filter_offset,
		      int output_offset, int output_multiplier, int output_shift,
		      int activation_min, int activation_max);

/* ---- RoCC stubs (rocc.S) --------------------------------------------------------------- */
#define DECL(f)  uint64_t mbxr_rocc_##f(uint64_t, uint64_t);
#define DECLX(f) uint64_t mbxr_roccx_##f(uint64_t, uint64_t);
DECL(0) DECL(1) DECL(2) DECL(3) DECL(4) DECL(5) DECLX(6) DECLX(7) DECL(8)

static uint64_t rocc_cmd(void *ctx, unsigned f, uint64_t a, uint64_t b, int xd)
{
	ARG_UNUSED(ctx); ARG_UNUSED(xd);
	switch (f) {
	case 0: return mbxr_rocc_0(a, b);
	case 1: return mbxr_rocc_1(a, b);
	case 2: return mbxr_rocc_2(a, b);
	case 3: return mbxr_rocc_3(a, b);
	case 4: return mbxr_rocc_4(a, b);
	case 5: return mbxr_rocc_5(a, b);
	case 6: return mbxr_roccx_6(a, b);
	case 7: return mbxr_roccx_7(a, b);
	case 8: return mbxr_rocc_8(a, b);
	}
	return ~0ULL;
}
static void *p2v(void *ctx, uint64_t pa) { ARG_UNUSED(ctx); return (void *)(uintptr_t)pa; }

/* A poll limit, so a fill or a drain that never completes returns MBXR_E_TIMEOUT with the
 * last fence word instead of hanging the bench. */
static uint64_t now_h(void *ctx)
{
	ARG_UNUSED(ctx);
	return csr_read(mcycle);     /* the same clock as cyc() below */
}
/* THE W LANE'S READY WAIT (revision 2b, 0x5A5A0013).  mbxr.c polls fence bit 41 (MBXR_S_WREADY)
 * for this many iterations before a dispatch arms anything, and returns MBXR_E_LANE if the lane
 * never reports ready; mbxr_rt.h has carried the same knob as MBXR_RT_LANE_WAIT since the driver
 * gained it.  THIS SAMPLE HAD NO SUCH WAIT AT ALL: the positional initialisers below stopped at
 * place_chunk, so lane_wait was 0 and a 2b bitstream ran its dispatches without ever asking whether
 * the lane was out of reset and quiet.
 *
 * It stays 0 by default ON PURPOSE.  Revisions 1 and 2a have no lane and read 0 in bit 41 for ever,
 * so a non-zero wait on those builds would turn every dispatch into MBXR_E_LANE.  A 2b build must
 * ask for it: west build ... -DRMB_LANE_WAIT=2000000 (mbxr_rt.h uses 2,000,000 fence polls, which is
 * several hundred million cycles -- a lane that is not ready by then is dead, not slow). */
#ifndef RMB_LANE_WAIT
#define RMB_LANE_WAIT 0
#endif
/* THE OUTSTANDING-GET CAP THIS BENCH RUNS AT, outside the sweep in section 4 (which varies it
 * on purpose and restores this value afterwards).  3 is the engine's reset default and what
 * every measurement before 2026-09-17 used, so unset changes nothing.  Set it to pin the cap
 * for a bisect -- west build ... -DRMB_CAP=1 -- without editing this file. */
#ifndef RMB_CAP
#define RMB_CAP 3
#endif
/* Section 2b, the identity dispatch that shows the SHAPE of a corruption (see there).  On
 * a healthy build it is one more exact dispatch and costs a few ms; it is on by default
 * because a bench that only counts wrong bytes cannot say where they are. */
#ifndef RMB_IDENTITY
#define RMB_IDENTITY 1
#endif
#ifndef RMB_IDENTITY_K
#define RMB_IDENTITY_K 288   /* M = K for A = I; 288 is dec_qkvo's */
#endif
#ifndef RMB_IDENTITY_N
#define RMB_IDENTITY_N 288
#endif
/* RMB_DRAIN_STRIDED=1: THE 2-D DRAIN (rtl_study/roccmoon/STRIDED_DRAIN.md).  The engine Puts
 * each weight tile's results straight into out[M][N] and hart 1 places NOTHING, so `cyc_place`
 * goes to zero.  Needs an engine whose id word reads 'MS'; on an 'MR' engine mbxr_run_to takes
 * the flat drain and places, which is what every measurement before this flag existed did.
 * One define is the whole A/B:  west build ... -DRMB_DRAIN_STRIDED=1 */
#ifndef RMB_DRAIN_STRIDED
#define RMB_DRAIN_STRIDED 0
#endif
MBXR_ABI_STAMP(rmb_abi_stamp, RMB_DRAIN_STRIDED);

static const mbxr_dev dev = { rocc_cmd, p2v, NULL, 5000000, now_h, 0, 0, RMB_LANE_WAIT,
			      RMB_DRAIN_STRIDED };
/* the same, placing results 64 bytes at a time (what mbxr_rt.h runs): section 3 times both */
static const mbxr_dev dev_chunk = { rocc_cmd, p2v, NULL, 5000000, now_h, 1, 0, RMB_LANE_WAIT,
				    RMB_DRAIN_STRIDED };

/* ---- fixed physical windows, far above the image --------------------------------------- */
#define W_BASE    0x82000000UL     /* [N,K] weights, as a model holds them        */
#define IN_BASE   0x83000000UL     /* the input tensor                             */
#define IMG_BASE  0x84000000UL     /* the engine's planar image                    */
#define SCR_BASE  0x85000000UL     /* the drain's scratch                          */
#define OUT_ENG   0x85800000UL
#define OUT_CORE  0x86000000UL
#define OUT_REF   0x86800000UL
#define BIAS_BASE 0x87000000UL
/* section 5 (the curated kernel files): mbxr_rt.h owns 0x8800_0000 .. 0x8DFF_FFFF */
#define CV_W      0x87100000UL
#define CV_IN     0x87400000UL
#define CV_OUT_E  0x87800000UL
#define CV_OUT_C  0x87C00000UL

/* ---- RMB_ lines also go to DRAM, so the result does not depend on the UART -------------------
 * A header at Rocket 0x87F0_0000 (PS physical 0x17F0_0000): magic "RMBLOG01", byte length,
 * done flag, then the text.  scripts/51_rocket_roccmoon.sh zeroes the header from the PS
 * before the program starts and reads the text back over /dev/mem, so a console that returns
 * nothing (as the bench console did for every lab from about 22:20 on 16 Sep) still yields a
 * result, and a stale log from an earlier run cannot be mistaken for this one. */
#define RMB_LOG_BASE 0x87F00000UL
#define RMB_LOG_CAP  (1UL << 20)
struct rmb_log_hdr { uint64_t magic, len, done, pad; };
static void rmb_log_init(void)
{
	struct rmb_log_hdr *h = (struct rmb_log_hdr *)RMB_LOG_BASE;
	h->len = 0; h->done = 0; h->pad = 0;
	memcpy(&h->magic, "RMBLOG01", 8);
}
static void rmb_log_put(const char *buf, size_t n)
{
	struct rmb_log_hdr *h = (struct rmb_log_hdr *)RMB_LOG_BASE;
	if (h->len + n > RMB_LOG_CAP - sizeof *h) return;
	memcpy((char *)(RMB_LOG_BASE + sizeof *h + h->len), buf, n);
	h->len += n;
}
#define rmb_printk(...) do { char _b[768]; int _n = snprintk(_b, sizeof _b, __VA_ARGS__); \
	if (_n > 0) rmb_log_put(_b, (size_t)(_n < (int)sizeof _b ? _n : (int)sizeof _b - 1)); \
	printk("%s", _b); } while (0)

static uint64_t rng = 0x9E3779B97F4A7C15ULL;
static uint64_t xr(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static inline uint64_t cyc(void) { return csr_read(mcycle); }

/* ---- hart 1 worker ----------------------------------------------------------------------- */
#define STK 8192
K_THREAD_STACK_DEFINE(h1_stack, STK);
static struct k_thread h1_thread;
static struct k_sem h1_go;
static atomic_t h1_done;

static struct {
	int op;                 /* 0 = linear dispatch, 1 = id, 2 = set outstanding cap */
	const mbxr_dev *dev;    /* op 0: NULL = dev */
	int cap;
	const mbxr_wimage *img;
	uint64_t in_pa;
	int npix, astride;
	mbxr_quant q;
	int8_t *out;
	mbxr_stats st;
	int rc;
	uint64_t cycles;        /* measured on hart 1 around mbxr_run */
	uint64_t hartid;
	uint64_t fill_beats, cyc_fill, steps, cyc_busy;
} job;

static void h1_entry(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	for (;;) {
		k_sem_take(&h1_go, K_FOREVER);
		job.hartid = csr_read(mhartid);
		if (job.op == 1) {
			job.cycles = rocc_cmd(NULL, MBXR_STAT, MBXR_C_ID, 0, 1);
		} else if (job.op == 2) {
			rocc_cmd(NULL, MBXR_CAP, 0, (uint64_t)job.cap, 0);
		} else {
			memset(&job.st, 0, sizeof job.st);
			uint64_t c0 = cyc();
			/* out's virtual address IS its physical one here (M-mode, no MMU), which is
			 * the identity p2v relies on; the strided drain needs it because the ENGINE
			 * writes the tensor. */
			job.rc = mbxr_run_to(job.dev ? job.dev : &dev, job.img, job.in_pa, job.npix,
					     job.astride, &job.q, SCR_BASE, job.out,
					     (uint64_t)(uintptr_t)job.out, &job.st);
			job.cycles = cyc() - c0;
			job.fill_beats = rocc_cmd(NULL, MBXR_STAT, MBXR_C_FILL_BEATS, 0, 1);
			job.cyc_fill   = rocc_cmd(NULL, MBXR_STAT, MBXR_C_CYC_FILL, 0, 1);
			job.steps      = rocc_cmd(NULL, MBXR_STAT, MBXR_C_STEPS, 0, 1);
			job.cyc_busy   = rocc_cmd(NULL, MBXR_STAT, MBXR_C_CYC_BUSY, 0, 1);
		}
		atomic_set(&h1_done, 1);
	}
}

/* Hand a job to hart 1 and spin until it is done.  Returns hart-0 wall cycles. */
static uint64_t on_hart1(void)
{
	atomic_set(&h1_done, 0);
	job.hartid = ~0UL;
	uint64_t c0 = cyc();
	k_sem_give(&h1_go);
	while (!atomic_get(&h1_done)) {
		if (cyc() - c0 > 1400000000ULL) {       /* ~40 s */
			rmb_printk("RMB_HANG op=%d worker_started=%d polls=%llu last_status=0x%016llx rc=%d\n",
			       job.op, job.hartid != ~0UL, (unsigned long long)job.st.polls,
			       (unsigned long long)job.st.last_status, job.rc);
			return ~0ULL;
		}
	}
	return cyc() - c0;
}

/* ---- negative tests: each on its own thread, because a trap kills the thread ---------------- */
static struct k_sem neg_sem;
static volatile int neg_id;
static struct { bool retired, trapped; unsigned long mcause, mtval, hart; uint64_t val; } neg[3];

void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf)
{
	ARG_UNUSED(reason); ARG_UNUSED(esf);
	neg[neg_id].trapped = true;
	neg[neg_id].mcause = csr_read(mcause);
	neg[neg_id].mtval = csr_read(mtval);
	k_sem_give(&neg_sem);
	k_thread_abort(k_current_get());
	CODE_UNREACHABLE;
}

static void neg_custom1(void *a, void *b, void *c)    /* custom-1 must reach the engine or trap */
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	neg[neg_id].hart = csr_read(mhartid);
	uint64_t v = mbxr_roccx_7(MBXR_C_ID, 0);
	__asm__ volatile("" ::: "memory");
	neg[neg_id].val = v;
	neg[neg_id].retired = true;
	k_sem_give(&neg_sem);
}

static void neg_mbp(void *a, void *b, void *c)        /* MBP.DOT8 must trap on hart 1 */
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	static volatile int64_t l = 0x0102030405060708LL, r = 0x0101010101010101LL;
	neg[neg_id].hart = csr_read(mhartid);
	int64_t v = mb_pext_dot8((int64_t)l, (int64_t)r);
	__asm__ volatile("" ::: "memory");
	neg[neg_id].val = (uint64_t)v;
	neg[neg_id].retired = true;
	k_sem_give(&neg_sem);
}

K_THREAD_STACK_DEFINE(neg_stack, STK);
static struct k_thread neg_thread;

static void run_neg(int id, k_thread_entry_t fn, int cpu, const char *what)
{
	neg_id = id;
	memset(&neg[id], 0, sizeof neg[id]);
	k_tid_t t = k_thread_create(&neg_thread, neg_stack, STK, fn, NULL, NULL, NULL, 4, 0, K_FOREVER);
	k_thread_cpu_pin(t, cpu);
	k_thread_start(t);
	if (k_sem_take(&neg_sem, K_SECONDS(5)) != 0) {
		rmb_printk("RMB_PLACE test=%s cpu=%d outcome=hang\n", what, cpu);
		return;
	}
	k_thread_join(t, K_SECONDS(1));
	rmb_printk("RMB_PLACE test=%s cpu=%d hart=%lu outcome=%s value=0x%016llx mcause=%lu mtval=0x%08lx\n",
	       what, cpu, neg[id].hart, neg[id].trapped ? "trap" : (neg[id].retired ? "retired" : "none"),
	       (unsigned long long)neg[id].val, neg[id].mcause, neg[id].mtval);
}

/* ---- data --------------------------------------------------------------------------------- */
static void fill_random(uint64_t pa, size_t n)
{
	uint8_t *p = (uint8_t *)pa;
	for (size_t i = 0; i < n; i++) p[i] = (uint8_t)xr();
}

static int check(const int8_t *a, const int8_t *b, size_t n, size_t *bad)
{
	int m = 0; *bad = 0;
	for (size_t i = 0; i < n; i++) {
		int e = a[i] - b[i]; if (e < 0) e = -e;
		if (e) (*bad)++;
		if (e > m) m = e;
	}
	return m;
}

static void rand_quant(mbxr_quant *q)
{
	q->mult = (int32_t)((1u << 30) + (uint32_t)(xr() % (1u << 30)));
	q->shift = (int)(xr() % 22) - 1;
	q->amin = (xr() % 3 == 0) ? 0 : -128;
	q->amax = 127;
}

static int engine_linear(mbxr_wimage *img, int M, int K, int N, const mbxr_quant *q,
			 uint64_t *h0_cycles)
{
	job.op = 0; job.img = img; job.in_pa = IN_BASE; job.npix = M; job.astride = K / 8;
	job.q = *q; job.out = (int8_t *)OUT_ENG;
	*h0_cycles = on_hart1();
	return job.rc;
}

int main(void)
{
	bool ok = true;
	k_sem_init(&h1_go, 0, 1);
	k_sem_init(&neg_sem, 0, 1);
	rmb_log_init();
	rmb_printk("RMB_START roccmoon_bench\n");

	/* ---- 1. placement --------------------------------------------------------------- */
	run_neg(0, neg_custom1, 1, "custom1_on_hart1");
	run_neg(1, neg_custom1, 0, "custom1_on_hart0");
	/* the MBP trap on hart 1 is taken LAST, after every engine run: a thread aborted from a
	 * fault on hart 1 must not be the reason the engine's worker never runs there */
	unsigned eng_sig = (unsigned)(neg[0].val & 0xffff);
	bool place_ok = neg[0].retired && (eng_sig == 0x4d52 || eng_sig == 0x4d53) && neg[1].trapped;
	rmb_printk("RMB_ENGINE_SIG sig=%04x drain=%s asked=%d\n", eng_sig,
		   eng_sig == 0x4d53 ? "2d" : (eng_sig == 0x4d52 ? "flat" : "unknown"),
		   RMB_DRAIN_STRIDED);
	if (!neg[0].retired) {
		rmb_printk("RMB_DONE ok=0 reason=no-engine-on-hart1\n");
		((struct rmb_log_hdr *)RMB_LOG_BASE)->done = 1;
		return 0;
	}

	k_tid_t h1 = k_thread_create(&h1_thread, h1_stack, STK, h1_entry, NULL, NULL, NULL, 5, 0, K_FOREVER);
	k_thread_cpu_pin(h1, 1);
	k_thread_start(h1);
	/* custom-1 exists only on hart 1: every engine command, the cap included, goes there */
	rmb_printk("RMB_STAGE worker\n");
	job.op = 1;
	if (on_hart1() == ~0ULL) {
		rmb_printk("RMB_DONE ok=0 reason=worker\n");
		((struct rmb_log_hdr *)RMB_LOG_BASE)->done = 1;
		return 0;
	}
	rmb_printk("RMB_WORKER hart=%lu id=0x%016llx\n", (unsigned long)job.hartid, (unsigned long long)job.cycles);
	job.op = 2; job.cap = RMB_CAP; on_hart1();
	rmb_printk("RMB_STAGE exactness\n");

	/* ---- 2. bit-exactness on the silicon ---------------------------------------------- */
	int cases = 0, worst = 0;
	for (int i = 0; i < 40; i++) {
		int G = 1 + (int)(xr() % 48), K = 8 * G;
		int N = 1 + (int)(xr() % 70), M = 1 + (int)(xr() % 40);
		mbxr_quant q; rand_quant(&q);
		fill_random(W_BASE, (size_t)N * K);
		fill_random(IN_BASE, (size_t)M * K);
		fill_random(BIAS_BASE, (size_t)N * 4);
		for (int n = 0; n < N; n++) ((int32_t *)BIAS_BASE)[n] %= 200000;
		mbxr_wimage img;
		if (!mbxr_wimage_plan_ex(&img, N, K, RMB_DRAIN_STRIDED)) continue;
		mbxr_wimage_build(&dev, &img, IMG_BASE, (int8_t *)W_BASE, (int32_t *)BIAS_BASE);
		ref_kernel_linear_s8((int8_t *)IN_BASE, (int8_t *)W_BASE, (int32_t *)BIAS_BASE,
				     (int8_t *)OUT_REF, M, K, N, 0, 0, 0, q.mult, q.shift, q.amin, q.amax);
		pext_kernel_linear_s8((int8_t *)IN_BASE, (int8_t *)W_BASE, (int32_t *)BIAS_BASE,
				      (int8_t *)OUT_CORE, M, K, N, 0, 0, 0, q.mult, q.shift, q.amin, q.amax);
		uint64_t h0;
		rmb_printk("RMB_CASE i=%d M=%d K=%d N=%d\n", i, M, K, N);
		int rc = engine_linear(&img, M, K, N, &q, &h0);
		if (rc != MBXR_OK) {
			rmb_printk("RMB_RUN_FAIL i=%d rc=%d polls=%llu last_status=0x%016llx loads_a=%llu loads_w=%llu pairs=%llu\n",
			       i, rc, (unsigned long long)job.st.polls, (unsigned long long)job.st.last_status,
			       (unsigned long long)job.st.loads_act, (unsigned long long)job.st.loads_wgt,
			       (unsigned long long)job.st.pairs);
			break;
		}
		size_t bad_e, bad_c;
		int me = check((int8_t *)OUT_ENG, (int8_t *)OUT_REF, (size_t)M * N, &bad_e);
		int mc = check((int8_t *)OUT_CORE, (int8_t *)OUT_REF, (size_t)M * N, &bad_c);
		if (rc != MBXR_OK || me || mc) {
			rmb_printk("RMB_EXACT_FAIL i=%d M=%d K=%d N=%d shift=%d amin=%d rc=%d eng_err=%d (%u) core_err=%d (%u)\n",
			       i, M, K, N, q.shift, q.amin, rc, me, (unsigned)bad_e, mc, (unsigned)bad_c);
			ok = false;
		}
		if (me > worst) worst = me;
		cases++;
	}
	rmb_printk("RMB_EXACT cases=%d engine_vs_reference_max_abs_err=%d\n", cases, worst);

	/* ---- 2b. THE SHAPE OF A WRONG BYTE: identity activations -------------------------
	 * Every run so far has reported the MAGNITUDE of the corruption on 0x5A5A0013 and never its
	 * SHAPE.  With A = I (M = K, one 1 per row) and a unit requantiser the engine's output IS the
	 * weight matrix, so a wrong output byte names a weight element, and the image layout turns
	 * that into (plane, tile, quad, word, byte) -- a bank and an offset rather than a count.
	 * The weights name themselves too: w = ((n & 15) << 3 | (k & 7)) - 64, so a byte that lands
	 * in the wrong place still says where it came from.
	 *
	 * PROVE THE HARNESS ON A KNOWN ANSWER FIRST: the software reference must reproduce the
	 * weight matrix exactly, or the identity setup is wrong and nothing below means anything.
	 * Needs no bitstream and no reconfiguration; it is one dispatch. */
#if RMB_IDENTITY
	static const struct { int K, N; } idshapes[] = {
		{ 288, 288 },   /* dec_qkvo's K and N, but M = K = 288: the regime enc_qkvo is EXACT in */
		{  32, 288 },   /* the same weights, a short dispatch: the regime the random cases fail in */
		{   8, 288 },   /* shorter still, one tile, G = 1 */
	};
	for (size_t idi = 0; idi < ARRAY_SIZE(idshapes); idi++) {
		const int K = idshapes[idi].K, M = idshapes[idi].K, N = idshapes[idi].N;
		/* A = 2I with (mult = 2^30, shift = 0) is the unit requantiser, EXACTLY: the reference
		 * rounds in Q0.31 BEFORE the shift, so acc = w with (2^30, -1) loses the low bit on odd
		 * values -- half the bytes -- and acc = 2w with (2^30, 0) gives floor(w + 1/2) = w for
		 * both signs.  Checked on the host against ref_linear.c before any board time: 0 of
		 * 82,944 bytes differ.  That check is the reason this section can be believed. */
		mbxr_quant q = { .mult = 1 << 30, .shift = 0, .amin = -128, .amax = 127 };
		int8_t *w = (int8_t *)W_BASE, *in = (int8_t *)IN_BASE;
		for (int n = 0; n < N; n++)
			for (int k = 0; k < K; k++) w[(size_t)n * K + k] = (int8_t)((((n & 15) << 3) | (k & 7)) - 64);
		for (size_t i = 0; i < (size_t)M * K; i++) in[i] = 0;
		for (int m = 0; m < M; m++) in[(size_t)m * K + m] = 2;   /* 2, not 1: see the quant above */
		for (int n = 0; n < N; n++) ((int32_t *)BIAS_BASE)[n] = 0;
		mbxr_wimage img;
		if (!mbxr_wimage_plan_ex(&img, N, K, RMB_DRAIN_STRIDED)) {
			rmb_printk("RMB_ID_SKIP K=%d N=%d\n", K, N);
		} else {
			mbxr_wimage_build(&dev, &img, IMG_BASE, w, (int32_t *)BIAS_BASE);
			ref_kernel_linear_s8(in, w, (int32_t *)BIAS_BASE, (int8_t *)OUT_REF,
					     M, K, N, 0, 0, 0, q.mult, q.shift, q.amin, q.amax);
			/* the known answer: ref[m][n] must be w[n][m] */
			size_t ref_bad = 0;
			for (int m = 0; m < M; m++)
				for (int n = 0; n < N; n++)
					if (((int8_t *)OUT_REF)[(size_t)m * N + n] != w[(size_t)n * K + m]) ref_bad++;
			rmb_printk("RMB_ID_HARNESS K=%d N=%d G=%d Q=%d lgpw=%d tiles=%d ref_vs_weights_bad=%u\n",
				   K, N, img.G, img.Q, img.lgpw, img.tiles, (unsigned)ref_bad);
			if (ref_bad) {
				ok = false;
			} else {
				uint64_t h0;
				int rc = engine_linear(&img, M, K, N, &q, &h0);
				size_t bad = 0;
				int hist_plane[MBXR_NCH] = { 0 }, hist_byte[8] = { 0 }, hist_tile[8] = { 0 };
				int shown = 0;
				for (int m = 0; m < M && rc == MBXR_OK; m++) {
					for (int n = 0; n < N; n++) {
						int8_t got = ((int8_t *)OUT_ENG)[(size_t)m * N + n];
						int8_t exp = w[(size_t)n * K + m];
						if (got == exp) continue;
						bad++;
						int r = n % MBXR_NCH, tq = n / MBXR_NCH;
						int t = tq / img.Q, qd = tq % img.Q;
						int word = qd * (img.G + 1) + m / 8, byte = m % 8;
						hist_plane[r]++; hist_byte[byte]++;
						if (t < 8) hist_tile[t]++;
						if (shown++ < 24)
							rmb_printk("RMB_ID_BAD K=%d m=%d n=%d exp=%d got=%d plane=%d tile=%d quad=%d word=%d bank=%d byte=%d from_n=%d from_k=%d\n",
								   K, m, n, exp, got, r, t, qd, word, word >> 9, byte,
								   ((got + 64) >> 3) & 15, (got + 64) & 7);
					}
				}
				rmb_printk("RMB_ID K=%d N=%d rc=%d bad=%u of %u  plane=%d,%d,%d,%d  byte=%d,%d,%d,%d,%d,%d,%d,%d  tile0_7=%d,%d,%d,%d,%d,%d,%d,%d\n",
					   K, N, rc, (unsigned)bad, (unsigned)((size_t)M * N),
					   hist_plane[0], hist_plane[1], hist_plane[2], hist_plane[3],
					   hist_byte[0], hist_byte[1], hist_byte[2], hist_byte[3],
					   hist_byte[4], hist_byte[5], hist_byte[6], hist_byte[7],
					   hist_tile[0], hist_tile[1], hist_tile[2], hist_tile[3],
					   hist_tile[4], hist_tile[5], hist_tile[6], hist_tile[7]);
				if (rc != MBXR_OK || bad) ok = false;
			}
		}
	}
#endif

	/* ---- 3. Moonshine Tiny's linear shapes ------------------------------------------- */
	static const struct { const char *name; int M, K, N; } shp[] = {
		{ "enc_qkvo",  165,  288,   288 },
		{ "enc_fc1",   165,  288,  1152 },
		{ "enc_fc2",   165, 1152,   288 },
		{ "dec_qkvo",    1,  288,   288 },
		{ "dec_fc1",     1,  288,  2304 },
		{ "dec_fc2",     1, 1152,   288 },
		{ "dec_lmhead",  1,  288, 32768 },
	};
	for (size_t s = 0; s < ARRAY_SIZE(shp); s++) {
		int M = shp[s].M, K = shp[s].K, N = shp[s].N;
		mbxr_quant q = { .mult = 1518500250, .shift = 9, .amin = -128, .amax = 127 };
		fill_random(W_BASE, (size_t)N * K);
		fill_random(IN_BASE, (size_t)M * K);
		memset((void *)BIAS_BASE, 0, (size_t)N * 4);
		for (int n = 0; n < N; n++) ((int32_t *)BIAS_BASE)[n] = (int32_t)(xr() % 4001) - 2000;
		mbxr_wimage img;
		mbxr_wimage_plan_ex(&img, N, K, RMB_DRAIN_STRIDED);
		uint64_t b0 = cyc();
		mbxr_wimage_build(&dev, &img, IMG_BASE, (int8_t *)W_BASE, (int32_t *)BIAS_BASE);
		uint64_t build = cyc() - b0;

		uint64_t core_best = ~0ULL, eng_best = ~0ULL, eng_h0_best = ~0ULL;
		for (int r = 0; r < 3; r++) {
			unsigned int key = irq_lock();
			uint64_t c0 = cyc();
			pext_kernel_linear_s8((int8_t *)IN_BASE, (int8_t *)W_BASE, (int32_t *)BIAS_BASE,
					      (int8_t *)OUT_CORE, M, K, N, 0, 0, 0, q.mult, q.shift, q.amin, q.amax);
			uint64_t c = cyc() - c0;
			irq_unlock(key);
			if (c < core_best) core_best = c;
		}
		mbxr_stats best_st = { 0 };
		uint64_t fb = 0, cf = 0, steps = 0, cb = 0;
		int rc = 0;
		for (int r = 0; r < 3; r++) {
			uint64_t h0;
			rc = engine_linear(&img, M, K, N, &q, &h0);
			if (job.cycles < eng_best) {
				eng_best = job.cycles; eng_h0_best = h0; best_st = job.st;
				fb = job.fill_beats; cf = job.cyc_fill; steps = job.steps; cb = job.cyc_busy;
			}
		}
		size_t bad;
		int me = check((int8_t *)OUT_ENG, (int8_t *)OUT_CORE, (size_t)M * N, &bad);
		if (rc != MBXR_OK || me) ok = false;
		rmb_printk("RMB_OP name=%s M=%d K=%d N=%d macs=%llu wbytes=%llu core_cycles=%llu "
		       "eng_cycles=%llu eng_h0_cycles=%llu img_build_cycles=%llu img_bytes=%llu "
		       "tiles_w=%d Q=%d pairs=%llu loads_a=%llu loads_w=%llu bytes_a=%llu bytes_w=%llu "
		       "polls=%llu fill_beats=%llu cyc_fill=%llu steps=%llu cyc_busy=%llu "
		       "cyc_wait=%llu cyc_place=%llu out_bytes=%llu rc=%d max_abs_err=%d\n",
		       shp[s].name, M, K, N, (unsigned long long)M * K * N,
		       (unsigned long long)N * K, (unsigned long long)core_best,
		       (unsigned long long)eng_best, (unsigned long long)eng_h0_best,
		       (unsigned long long)build, (unsigned long long)img.bytes, img.tiles, img.Q,
		       (unsigned long long)best_st.pairs, (unsigned long long)best_st.loads_act,
		       (unsigned long long)best_st.loads_wgt, (unsigned long long)best_st.bytes_act,
		       (unsigned long long)best_st.bytes_wgt, (unsigned long long)best_st.polls,
		       (unsigned long long)fb, (unsigned long long)cf, (unsigned long long)steps,
		       (unsigned long long)cb, (unsigned long long)best_st.cyc_wait,
		       (unsigned long long)best_st.cyc_place, (unsigned long long)best_st.out_bytes, rc, me);

		/* the same dispatch with results placed 64 bytes at a time (dev_chunk), same session,
		 * same image, same input: the A/B for the LITTLE hart's L1D aliasing */
		{
			uint64_t e_best = ~0ULL, h0_best = ~0ULL;
			mbxr_stats cst = { 0 };
			uint64_t ccb = 0;
			int crc = 0;
			memset((void *)OUT_ENG, 0x55, (size_t)M * N);
			job.dev = &dev_chunk;
			for (int r = 0; r < 3; r++) {
				uint64_t h0;
				crc = engine_linear(&img, M, K, N, &q, &h0);
				if (job.cycles < e_best) {
					e_best = job.cycles; h0_best = h0; cst = job.st; ccb = job.cyc_busy;
				}
			}
			job.dev = NULL;
			size_t cbad;
			int cme = check((int8_t *)OUT_ENG, (int8_t *)OUT_CORE, (size_t)M * N, &cbad);
			if (crc != MBXR_OK || cme) ok = false;
			rmb_printk("RMB_OPC name=%s eng_cycles=%llu eng_h0_cycles=%llu cyc_busy=%llu "
				   "cyc_wait=%llu cyc_place=%llu polls=%llu rc=%d max_abs_err=%d\n",
				   shp[s].name, (unsigned long long)e_best, (unsigned long long)h0_best,
				   (unsigned long long)ccb, (unsigned long long)cst.cyc_wait,
				   (unsigned long long)cst.cyc_place, (unsigned long long)cst.polls, crc, cme);
		}
	}

	/* ---- 4. the engine's fill port, on the decode projection ----------------------- */
	{
		int M = 1, K = 288, N = 32768;
		mbxr_quant q = { .mult = 1518500250, .shift = 9, .amin = -128, .amax = 127 };
		mbxr_wimage img;
		mbxr_wimage_plan_ex(&img, N, K, RMB_DRAIN_STRIDED);
		/* the image from section 3's last shape is still in place */
		static const int caps[] = { 1, 2, 3, 4, 6, 8 };
		for (size_t i = 0; i < ARRAY_SIZE(caps); i++) {
			img.pa = IMG_BASE;
			job.op = 2; job.cap = caps[i]; on_hart1();
			uint64_t h0;
			int rc = engine_linear(&img, M, K, N, &q, &h0);
			rmb_printk("RMB_PORT cap=%d rc=%d eng_cycles=%llu fill_beats=%llu cyc_fill=%llu "
			       "bytes_w=%llu loads_w=%llu\n", caps[i], rc,
			       (unsigned long long)job.cycles, (unsigned long long)job.fill_beats,
			       (unsigned long long)job.cyc_fill, (unsigned long long)job.st.bytes_wgt,
			       (unsigned long long)job.st.loads_wgt);
		}
		job.op = 2; job.cap = RMB_CAP; on_hart1();
	}


	/* ---- 5. the curated kernel files a ModelBlaster model links ------------------------ */
	{
		static const struct { const char *name; int IC, IW, OC, KW, SW; } cv[] = {
			{ "stem_conv1",   1, 64000, 288, 127, 64 },
			{ "stem_conv2", 288,   999, 576,   7,  3 },
			{ "stem_conv3", 576,   331, 288,   3,  2 },
		};
		for (size_t i = 0; i < ARRAY_SIZE(cv); i++) {
			int IC = cv[i].IC, IW = cv[i].IW, OC = cv[i].OC, KW = cv[i].KW, SW = cv[i].SW;
			int OW = (IW - KW) / SW + 1;
			mbxr_quant q = { .mult = 1518500250, .shift = 10, .amin = -128, .amax = 127 };
			rmb_printk("RMB_KOP_BEGIN name=%s\n", cv[i].name);
			mbxr_rt_forget();      /* the same weight buffer, rewritten: not the cached image */
			fill_random(CV_W, (size_t)OC * IC * KW);
			fill_random(CV_IN, (size_t)IC * IW);
			for (int n = 0; n < OC; n++) ((int32_t *)BIAS_BASE)[n] = (int32_t)(xr() % 4001) - 2000;
			uint64_t best_c = ~0ULL, best_e = ~0ULL;
			for (int r = 0; r < 2; r++) {
				unsigned int key = irq_lock();
				uint64_t c0 = cyc();
				kernel_conv2d_s8((int8_t *)CV_IN, (int8_t *)CV_W, (int32_t *)BIAS_BASE,
						 (int8_t *)CV_OUT_C, 1, IC, 1, IW, OC, 1, KW, 1, SW, 0, 0,
						 0, 0, 0, q.mult, q.shift, q.amin, q.amax);
				uint64_t c = cyc() - c0;
				irq_unlock(key);
				if (c < best_c) best_c = c;
			}
			rmb_printk("RMB_KOP_CORE name=%s core_cycles=%llu\n", cv[i].name,
				   (unsigned long long)best_c);
			mbxr_rt_stats_t before = mbxr_rt_stats;
			uint64_t stage0 = 0;
			for (int r = 0; r < 3; r++) {        /* the first call builds the image */
				stage0 = mbxr_rt_stats.cycles_stage;
				unsigned int key = irq_lock();
				uint64_t c0 = cyc();
				rm_kernel_conv2d_s8((int8_t *)CV_IN, (int8_t *)CV_W, (int32_t *)BIAS_BASE,
						    (int8_t *)CV_OUT_E, 1, IC, 1, IW, OC, 1, KW, 1, SW, 0, 0,
						    0, 0, 0, q.mult, q.shift, q.amin, q.amax);
				uint64_t c = cyc() - c0;
				irq_unlock(key);
				if (r > 0 && c < best_e) best_e = c;
			}
			size_t bad;
			int me = check((int8_t *)CV_OUT_E, (int8_t *)CV_OUT_C, (size_t)OC * OW, &bad);
			if (me) ok = false;
			rmb_printk("RMB_KOP name=%s kind=conv IC=%d IW=%d OC=%d KW=%d SW=%d OW=%d macs=%llu "
			       "core_cycles=%llu kernel_cycles=%llu engine_calls=%llu fallback_calls=%llu "
			       "stage_cycles_last=%llu image_cycles=%llu kicks=%llu giveups=%llu last_rc=%d "
			       "last_status=0x%016llx max_abs_err=%d\n",
			       cv[i].name, IC, IW, OC, KW, SW, OW, (unsigned long long)OW * IC * KW * OC,
			       (unsigned long long)best_c, (unsigned long long)best_e,
			       (unsigned long long)(mbxr_rt_stats.calls_engine - before.calls_engine),
			       (unsigned long long)(mbxr_rt_stats.calls_fallback - before.calls_fallback),
			       (unsigned long long)(mbxr_rt_stats.cycles_stage - stage0),
			       (unsigned long long)(mbxr_rt_stats.image_cycles - before.image_cycles),
			       (unsigned long long)(mbxr_rt_stats.kicks - before.kicks),
			       (unsigned long long)(mbxr_rt_stats.giveups - before.giveups),
			       mbxr_rt_stats.last_rc, (unsigned long long)mbxr_rt_stats.last_status, me);
		}
		/* and one linear dispatch through the kernel file, K not a multiple of 8, misaligned input */
		{
			int M = 37, K = 203, N = 150;
			mbxr_quant q = { .mult = 1518500250, .shift = 7, .amin = 0, .amax = 127 };
			rmb_printk("RMB_KOP_BEGIN name=lin_K203_misaligned\n");
			mbxr_rt_forget();
			fill_random(W_BASE, (size_t)N * K);
			fill_random(IN_BASE + 3, (size_t)M * K);
			for (int n = 0; n < N; n++) ((int32_t *)BIAS_BASE)[n] = (int32_t)(xr() % 4001) - 2000;
			pext_kernel_linear_s8((int8_t *)(IN_BASE + 3), (int8_t *)W_BASE, (int32_t *)BIAS_BASE,
					      (int8_t *)OUT_CORE, M, K, N, 0, 0, 0, q.mult, q.shift, q.amin, q.amax);
			mbxr_rt_stats_t before = mbxr_rt_stats;
			rm_kernel_linear_s8((int8_t *)(IN_BASE + 3), (int8_t *)W_BASE, (int32_t *)BIAS_BASE,
					    (int8_t *)OUT_ENG, M, K, N, 0, 0, 0, q.mult, q.shift, q.amin, q.amax);
			size_t bad;
			int me = check((int8_t *)OUT_ENG, (int8_t *)OUT_CORE, (size_t)M * N, &bad);
			if (me) ok = false;
			rmb_printk("RMB_KOP name=lin_K203_misaligned kind=linear M=%d K=%d N=%d engine_calls=%llu "
			       "fallback_calls=%llu max_abs_err=%d\n", M, K, N,
			       (unsigned long long)(mbxr_rt_stats.calls_engine - before.calls_engine),
			       (unsigned long long)(mbxr_rt_stats.calls_fallback - before.calls_fallback), me);
		}
	}


	/* ---- 6. matmul_b_s8: the encoder's per-element tail, separated ---------------------- */
	/*
	 * MATMUL_B_COST.md sections 6-8.  The encoder runs exactly TWO matmul_b_s8 shapes, so the
	 * model `cycles = d + a*el + b*el*ceil(K/8) + c*scratch` is SOLVED there with zero degrees
	 * of freedom, never fitted, and nothing in the records can decompose `a` further.  Two
	 * sweeps at the encoder's own M, with its own scales, give the missing freedom:
	 *
	 *   A.  N swept at M=165, K=36.  The intercept is what does not depend on N -- the dispatch
	 *       plus A's scratch copy, B*M*K bytes; the slope is everything proportional to a row
	 *       of B.  This is the sweep that prices the copy against the arithmetic.
	 *   B.  K swept at M=N=165.  `el` is CONSTANT at 217,800, so ceil(K/8) and the scratch move
	 *       and the per-element tail does not.  The intercept extrapolated to K=0 IS the tail.
	 *       The K set sits three points inside the W=5 step (33,36,40), three inside W=6
	 *       (41,44,48) and straddles the boundary once, which separates the per-DOT8 cost from
	 *       the per-scratch-byte cost exactly as the decoder's K=1..24 series does -- the one
	 *       place in the records where that separation is measured rather than assumed.
	 *
	 * Committed prediction (L325, MATMUL_B_COST.md section 8): the tail is 6-10 cyc/element.
	 * Falsifier: above 20 and the header's "one multiply, one shift, one compare and a CLIP8"
	 * is stale and the tail is the lever; below 10 and the encoder's cost is operand traffic,
	 * which tiling can address and the requantise description cannot.
	 *
	 * B, transpose_b, the scales and the activation range are encoder dispatch 17's verbatim
	 * (out/rocket_moonshine_enc/enc_ew/gen/model.c:603), so `fast` and the CLIP8 path taken
	 * here are the ones the encoder takes.  A at CV_W, B at CV_IN, the result at CV_OUT_C.
	 */
	{
		static const struct { const char *sweep; int M, K, N, tb; } mmb[] = {
			{ "N", 165,  36,  33, 1 }, { "N", 165,  36,  66, 1 }, { "N", 165,  36,  99, 1 },
			{ "N", 165,  36, 132, 1 }, { "N", 165,  36, 165, 1 },
			{ "K", 165,   8, 165, 1 }, { "K", 165,  16, 165, 1 }, { "K", 165,  24, 165, 1 },
			{ "K", 165,  32, 165, 1 }, { "K", 165,  33, 165, 1 }, { "K", 165,  36, 165, 1 },
			{ "K", 165,  40, 165, 1 }, { "K", 165,  41, 165, 1 }, { "K", 165,  44, 165, 1 },
			{ "K", 165,  48, 165, 1 },
			/*
			 * THE ENCODER'S OTHER SHAPE.  Dispatch 19 (scaled_dot_product_attention.av) is
			 * B=8 M=165 K=165 N=36 transpose_b=0 -- and transpose_b=0 reads B by COLUMN, a
			 * different copy path entirely.  The specialised nest is shared, so the tail
			 * saving should be the SAME ~19.3 cyc/element; PV's per-element cost is 2.8x
			 * larger, so it is a much smaller SHARE.  B52 estimated -7.27 % from that
			 * reasoning and banked 7.07 % of the encoder half on it.  These three rows turn
			 * the estimate into a measurement: PV's own shape, one at smaller K to check the
			 * saving really is K-independent under the column gather, and one at larger N.
			 */
			{ "PV", 165, 165,  36, 0 }, { "PV", 165,  36,  36, 0 },
			{ "PV", 165, 165,  72, 0 },
		};
		const int BN = 8;
		for (size_t i = 0; i < ARRAY_SIZE(mmb); i++) {
			int M = mmb[i].M, K = mmb[i].K, N = mmb[i].N, tb = mmb[i].tb;
			int W = (K + 7) / 8;
			/* dispatch 17's scales for the QK^T shapes, dispatch 19's for the PV shapes */
			float sa = tb ? 0.0756474882f : 0.00787401572f;
			float sb = tb ? 0.0984255448f : 0.0473036319f;
			float so = tb ? 0.280755699f  : 0.0288662519f;
			float sd = tb ? 6.0f          : 1.0f;
			unsigned long long el = (unsigned long long)BN * M * N;
			uint64_t best = ~0ULL;

			uint64_t bestref = ~0ULL;

			fill_random(CV_W, (size_t)BN * M * K);
			fill_random(CV_IN, (size_t)BN * K * N);
			for (int r = 0; r < 2; r++) {
				unsigned int key = irq_lock();
				uint64_t c0 = cyc();
				pext_kernel_matmul_b_s8((int8_t *)CV_W, (int8_t *)CV_IN,
							(int8_t *)CV_OUT_C, BN, M, K, N,
							sa, sb, so, tb, sd, -128, 127);
				uint64_t c = cyc() - c0;
				irq_unlock(key);
				if (c < best) best = c;
			}
			/* the same file with the hoisted nest compiled out: the A/B and the gate */
			for (int r = 0; r < 2; r++) {
				unsigned int key = irq_lock();
				uint64_t c0 = cyc();
				pext_ref_matmul_b_s8((int8_t *)CV_W, (int8_t *)CV_IN,
						     (int8_t *)CV_OUT_E, BN, M, K, N,
						     sa, sb, so, tb, sd, -128, 127);
				uint64_t c = cyc() - c0;
				irq_unlock(key);
				if (c < bestref) bestref = c;
			}
			size_t firstbad = 0;
			unsigned nbad = 0;
			for (size_t q = 0; q < (size_t)el; q++) {
				if (((int8_t *)CV_OUT_C)[q] != ((int8_t *)CV_OUT_E)[q]) {
					if (!nbad) firstbad = q;
					nbad++;
				}
			}
			if (nbad) ok = false;
			rmb_printk("RMB_MMB sweep=%s B=%d M=%d K=%d N=%d tb=%d W=%d el=%llu dot8=%llu "
				   "scratch=%llu core_cycles=%llu ref_cycles=%llu bytes_differing=%u "
				   "first_differing=%llu\n",
				   mmb[i].sweep, BN, M, K, N, tb, W, el, el * (unsigned)W,
				   (unsigned long long)BN * (M + N) * K,
				   (unsigned long long)best, (unsigned long long)bestref,
				   nbad, (unsigned long long)firstbad);
		}
	}

	run_neg(2, neg_mbp, 1, "mbp_dot8_on_hart1");
	place_ok = place_ok && neg[2].trapped;
	rmb_printk("RMB_PLACE_RESULT ok=%d\n", place_ok);
	ok = ok && place_ok;
	rmb_printk("RMB_DONE ok=%d\n", ok);
	((struct rmb_log_hdr *)RMB_LOG_BASE)->done = 1;
	return 0;
}
