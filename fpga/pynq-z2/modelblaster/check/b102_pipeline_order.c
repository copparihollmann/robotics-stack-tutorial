/* SPDX-License-Identifier: Apache-2.0
 *
 * Lab B102.  THE GATE NEITHER EXISTING BENCH CAN PROVIDE.
 *
 * run_compat_tb.sh runs the real mbxr.c against the compat engine and compares EXACT Gets,
 * Puts and cycles -- so it catches any change to mbxr_run_to's traffic, and B102 changes none.
 * tb_mbxr drives the driver from ONE thread.  Neither can see a CROSS-HART HANDSHAKE, which is
 * why B86d gated its issue/wait split with on-board poison arms instead (out/b86d_pois1
 * max_abs_err 142, out/b86d_pois2 102, both FAIL as designed).
 *
 * This runs the handshake itself, on the host, with two real threads: hart 0 staging and
 * transposing, hart 1 consuming in mbxr_run_to's real weight-outer tile order through the real
 * hook functions in sw/roccmoon/mbxr_b102.h.  It gates the ORDERING, not the arithmetic.
 *
 * WHY THE SENTINELS ARE NOT A RIGGED TEST.  On the board, a fill that runs ahead of hart 0
 * reads whatever the previous dispatch left in MBXR_RT_IN_STAGE -- a definite wrong value, but
 * one whose identity depends on history.  Here both arenas are pre-filled with a sentinel, so
 * "read before written" has a deterministic identity instead of a historical one.  The
 * sentinel makes the hazard OBSERVABLE; it does not make it occur.  What makes it occur is the
 * off-by-one, and with the off-by-one removed the same sentinels are never read.
 *
 * WHY AN "OK" HERE IS NOT VACUOUS.  B66 found a guard that passed 6,462 byte-for-byte
 * comparisons while testing the wrong branch.  So main() refuses to exit 0 unless the gate was
 * actually EXERCISED: hart 1 must have been made to wait at the fill gate (ld_spins > 0) and
 * the drain watermark must have been published (st_published > 0), on every shape.  An ON arm
 * that merely never raced is a FAIL here, not a pass.
 *
 *   cc -O2 -std=gnu11 -pthread -DMBP_B102=1 [-DMBP_B102_POISON=1|2] \
 *      -I fpga/pynq-z2/sw fpga/pynq-z2/modelblaster/check/b102_pipeline_order.c
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#ifndef MBP_B102
#error "build this check with -DMBP_B102=1; =0 compiles the mechanism out of the TU"
#endif

#ifndef MBXR_RT_STAGE_BLOCK
#error "build this check with -DMBXR_RT_STAGE_BLOCK=1: the pipeline stages through mbxr_stage_tr_j"
#endif
/* THE SHIPPING FILES, NOT COPIES OF THEM.  mbxr_stage.inc carries both the blocked transpose
 * and mbxr_b102_stage_chunk -- the chunk arithmetic where both of this gate's first-run bugs
 * lived -- and it pulls in mbxr_b102.h itself. */
#include "../modelblaster/kernels/roccmoon/mbxr_stage.inc"

#define NCH       8          /* the banked engine, 0x5A5A0035 */
#define BUF_WORDS 1024
/* THE SENTINEL IS A PARITY, so "read before written" is decidable byte by byte with no shadow
 * high-water mark and therefore no ordering race between the measure and the watermark it is
 * measuring.  Every source byte is forced ODD below; the arena is pre-filled with an EVEN
 * sentinel and the kernel's zero-fill past the plane is even too. */
#define SENT_IN   ((int8_t)0x5A)     /* staging arena: "hart 0 has not written this yet" */
#define SENT_OUT  ((int8_t)0x3C)     /* output stage:  "the drain has not written this yet" */

typedef struct {
	const char *name;
	int IC, IW, OC, KW, SW;
	/* THE MEASURED PASS-0 PRODUCER/CONSUMER RATIO, hart 0's gather against the engine, per
	 * activation tile, from out/b101_lgpw8_0035_f40c (ATTNFUSE, 0x5A5A0035, 40 MHz, NCH = 8).
	 * The host's own ratio is a property of gcc and this machine, not of the board, so it is
	 * declared here rather than inherited by accident.  > 1 means hart 0 is the slow side and
	 * the fill is the thing that waits -- the regime in which an off-by-one on the gather
	 * watermark can bite at all. */
	double board_ratio;
	/* derived, exactly as mbxr.c and mbxr.c's planner derive them */
	int K, npix, astride, P, tiles_a, quads, Q, tiles_w;
} shape_t;

static int lg2c(uint64_t x) { int l = 0; while ((1ULL << l) < x) l++; return l; }

static void derive(shape_t *s)
{
	int G;
	s->K = ((s->IC * s->KW) + 7) & ~7;
	s->npix = (s->IW - s->KW) / s->SW + 1;
	s->astride = s->SW * s->IC / 8;
	G = s->K / 8;
	s->quads = (s->OC + NCH - 1) / NCH;
	s->Q = BUF_WORDS / (G + 1);
	if (s->Q > s->quads) s->Q = s->quads;
	if ((s->OC % 8) == 0 && s->Q >= 2) s->Q &= ~1;
	s->tiles_w = (s->quads + s->Q - 1) / s->Q;
	s->P = (BUF_WORDS - 7 - G) / s->astride + 1;
	if (s->P > s->npix) s->P = s->npix;
	s->tiles_a = (s->npix + s->P - 1) / s->P;
}

/* ---- shared state -------------------------------------------------------------------- */
static shape_t     SH;
static mbxr_b102_t WM;
static int8_t     *g_src;        /* the model's NCHW input, [IC][IW]          */
static int8_t     *g_stage;      /* the staging arena,       [IW][IC]         */
static int8_t     *g_ostage;     /* the engine's output,     [npix][OC]       */
static int8_t     *g_out;        /* the model's NCHW output, [OC][npix]       */
static uint64_t    g_arena;      /* the largest extent the FILL ever asks for */
static uint64_t    g_readahead;  /* fills that read past hart 0's true high-water mark */
static uint64_t    g_staged;     /* hart 0's contiguous high-water mark, in bytes */
static uint64_t    g_earlyxpose; /* transposes of a weight tile hart 1 had not finished */
static uint32_t    g_written;    /* weight tiles hart 1 has actually finished writing */
static uint64_t    g_now;        /* a coarse "cycle" clock, for the spin bound */
static long        g_pace_ns;    /* hart 0's per-chunk hold-back, from SH.board_ratio */
static uint64_t    now_fn(void) { return __atomic_add_fetch(&g_now, 1, __ATOMIC_RELAXED); }

/* one pixel's window, as act_extent computes it */
static void act_extent(int a, uint64_t *src, uint64_t *blocks)
{
	uint64_t first = (uint64_t)a * SH.P * 8ULL * SH.astride;
	uint64_t last  = first + (uint64_t)(SH.P - 1) * 8ULL * SH.astride + (uint64_t)SH.K;
	*src = first & ~63ULL;
	*blocks = (last - *src + 63) / 64;
}

/* THE ACTIVATION IS READ ONCE PER TILE, NOT ONCE PER CHANNEL.  The engine loads a tile into
 * the scratchpad and the MAC array fans it across the weight planes; a model that re-reads the
 * window for every output channel is O(P*Q*NCH*K) and makes hart 1 the slow side, which is the
 * reverse of the board (stem.conv2 pass 0: gather 61,572 cycles a tile against 8,803 of
 * engine).  The digest still touches every staged byte, so a byte read before hart 0 wrote it
 * still changes the result -- which is the property this gate needs. */
static int32_t pix_digest(const int8_t *tile, int p_in_tile)
{
	const int8_t *w = tile + (size_t)p_in_tile * 8 * SH.astride;
	int32_t acc = 1;
	for (int k = 0; k < SH.K; k++) acc += (int32_t)w[k] * (int32_t)((k & 7) + 1);
	return acc;
}
static int8_t fan(int32_t dig, int n) { int32_t a = dig + n * 7; return (int8_t)(a ^ (a >> 11)); }

/* ---- hart 1: the engine, in mbxr_run_to's real weight-outer order ---------------------- */
static int g_h1_rc;
static void *hart1(void *unused)
{
	int8_t *buf = malloc((size_t)BUF_WORDS * 8 + 64);
	(void)unused;
	g_h1_rc = 1;
	for (int o = 0; o < SH.tiles_w; o++) {
		/* mbxr_run_to arms one `st` per WEIGHT tile when the weights are outer, after
		 * waiting out the previous tile's drain.  That wait is what the watermark
		 * republishes, so it is modelled by arming here, before the inner loop. */
		/* mbxr_run_to's weight-outer descriptor covers every pixel: nrows = npix */
		mbxr_b102_on_st(&WM, (uint64_t)(uint16_t)SH.npix);
		for (int i = 0; i < SH.tiles_a; i++) {
			uint64_t src, blocks;
			int pa = SH.npix - i * SH.P; if (pa > SH.P) pa = SH.P;
			int qt = SH.quads - o * SH.Q;  if (qt > SH.Q)  qt = SH.Q;
			act_extent(i, &src, &blocks);
			mbxr_b102_on_sd(&WM, WM.in_lo + src, blocks);
			if (!mbxr_b102_ld_wait(&WM, now_fn)) { g_h1_rc = 0; free(buf); return NULL; }
			/* the fill: whatever is in the arena AT THIS MOMENT is what the engine gets */
			memcpy(buf, g_stage + src, (size_t)blocks * 64);
			/* DID THE POISON HAVE AN OPPORTUNITY?  Measured from the BYTES, in the window
			 * the tile sequencer actually consumes (pa pixels, K bytes each) -- not from a
			 * shadow copy of hart 0's progress, which would race the watermark it exists to
			 * judge.  An even byte there is a byte hart 0 had not written. */
			{
				int hit = 0, p, k;
				for (p = 0; p < pa && !hit; p++) {
					const int8_t *w = buf + (src & 63) + (size_t)p * 8 * SH.astride;
					for (k = 0; k < SH.K; k++)
						if (((int)w[k] & 1) == 0) { hit = 1; break; }
				}
				if (hit) __atomic_add_fetch(&g_readahead, 1, __ATOMIC_RELAXED);
			}
			for (int p = 0; p < pa; p++) {
				int32_t dig = pix_digest(buf + (src & 63), p);
				for (int q = 0; q < qt; q++)
					for (int r = 0; r < NCH; r++) {
						int n = (o * SH.Q + q) * NCH + r;
						if (n >= SH.OC) continue;
						g_ostage[(size_t)(i * SH.P + p) * SH.OC + n] = fan(dig, n);
					}
			}
		}
		/* weight tile o's drain lands at the end of its pass; the NEXT on_st publishes it */
		__atomic_store_n(&g_written, (uint32_t)(o + 1), __ATOMIC_RELEASE);
	}
	free(buf);
	return NULL;
}

/* ---- hart 0: stage everything, then transpose what has drained ------------------------- */
static int g_wlo;
static void hart0_stage_chunk(int a)
{
	g_wlo = mbxr_b102_stage_chunk(&WM, g_stage, g_src, SH.IC, SH.IW, a, SH.P, SH.npix,
				      SH.astride, SH.K, g_arena, g_wlo);
	g_staged = (g_wlo >= SH.IW) ? g_arena : (uint64_t)g_wlo * SH.IC;
	/* hold hart 0 back to the board's measured ratio: on the board the fill is the thing that
	 * waits, and on the host it is not.  The hold is OUTSIDE the shipping function. */
	if (g_pace_ns > 0) { struct timespec ts = { 0, g_pace_ns }; nanosleep(&ts, NULL); }
}
static void hart0_transpose(int t)
{
	int n0 = t * SH.Q * NCH, n1 = n0 + SH.Q * NCH; if (n1 > SH.OC) n1 = SH.OC;
	/* DID POISON 2 HAVE AN OPPORTUNITY?  Measured against what hart 1 has actually finished
	 * writing, not against the watermark it published -- the watermark is the thing under
	 * test and cannot be its own witness. */
	{
		uint32_t w;
		__atomic_load(&g_written, &w, __ATOMIC_ACQUIRE);
		if ((uint32_t)t >= w) __atomic_add_fetch(&g_earlyxpose, 1, __ATOMIC_RELAXED);
	}
	for (int n = n0; n < n1; n++)
		for (int p = 0; p < SH.npix; p++)
			g_out[(size_t)n * SH.npix + p] = g_ostage[(size_t)p * SH.OC + n];
}

/* ---- one run: pipelined (threads) or serial (the reference) ---------------------------- */
static void run_pipelined(void)
{
	pthread_t th;
	uint32_t done = 0;
	g_readahead = 0; g_earlyxpose = 0; g_written = 0;
	g_pace_ns = (SH.board_ratio > 1.5) ? (long)(20000.0 * SH.board_ratio) : 0;
	memset(g_stage,  SENT_IN,  (size_t)SH.IW * SH.IC + 4096);
	memset(g_ostage, SENT_OUT, (size_t)SH.npix * SH.OC);
	memset(g_out,    0,        (size_t)SH.OC * SH.npix);
	mbxr_b102_arm(&WM, 0, g_arena, (uint32_t)SH.tiles_w,
		      (uint32_t)((uint64_t)SH.P * 8ULL * SH.astride), (uint32_t)SH.npix);
	/* stage tile 0 before the issue, exactly as the kernel would */
	g_staged = 0; g_wlo = 0;
	hart0_stage_chunk(0);
	pthread_create(&th, NULL, hart1, NULL);
	/* PHASE 1: finish the gather.
	 * Hart 0 never blocks on hart 1 here -- that ordering is what makes the handshake
	 * deadlock-free, and it is the shipped kernel's order (mbxr_b102.h).  Hart 0 is the slow
	 * side by the shapes' own arithmetic, exactly as it is on the board, so the fill is the
	 * thing that waits and the gate is under real pressure. */
	for (int a = 1; a < SH.tiles_a; a++) hart0_stage_chunk(a);
	/* PHASE 2: transpose weight tiles as their drains land */
	while (done < (uint32_t)SH.tiles_w) {
		uint32_t d = mbxr_b102_tiles_done(&WM);
		if (d > (uint32_t)SH.tiles_w) d = (uint32_t)SH.tiles_w;
		while (done < d) hart0_transpose((int)done++);
		if (done < (uint32_t)SH.tiles_w) {
			int alive;
			__atomic_load(&g_h1_rc, &alive, __ATOMIC_ACQUIRE);
			if (!alive) break;
			if (pthread_tryjoin_np(th, NULL) == 0) {       /* hart 1 finished */
				mbxr_b102_finish(&WM);
				while (done < (uint32_t)SH.tiles_w) hart0_transpose((int)done++);
				return;
			}
		}
	}
	pthread_join(th, NULL);
	mbxr_b102_finish(&WM);
}
static void run_serial(void)
{
	memset(g_stage,  SENT_IN,  (size_t)SH.IW * SH.IC + 4096);
	memset(g_ostage, SENT_OUT, (size_t)SH.npix * SH.OC);
	memset(g_out,    0,        (size_t)SH.OC * SH.npix);
	mbxr_b102_arm(&WM, 0, 0, 0, 0, 0);                 /* pipeline OFF: nothing is gated */
	g_staged = 0; g_wlo = 0; g_pace_ns = 0; g_written = 0;
	for (int a = 0; a < SH.tiles_a; a++) hart0_stage_chunk(a);
	hart1(NULL);
	for (int t = 0; t < SH.tiles_w; t++) hart0_transpose(t);
}

int main(void)
{
	shape_t shapes[] = {
		/*                IC    IW   OC   KW  SW   board pass-0 gather : engine, per tile */
		{ "stem.conv1", 1,   64000, 288, 127, 64, 72006.0 / 81325.0 },   /* 0.89: hart 1 slower */
		{ "stem.conv2", 288, 999,   576, 7,   3,  61572.0 /  8803.0 },   /* 7.00: hart 0 slower */
		{ "stem.conv3", 576, 331,   288, 3,   2,  61203.0 /  5757.0 },   /* 10.6: hart 0 slower */
	};
	int fails = 0, skips = 0, nshape = (int)(sizeof shapes / sizeof shapes[0]);
	printf("B102 pipeline ordering gate -- MBP_B102=%d MBP_B102_POISON=%d\n",
	       MBP_B102, MBP_B102_POISON);
	for (int s = 0; s < nshape; s++) {
		int8_t *ref;
		size_t obytes;
		SH = shapes[s]; derive(&SH);
		obytes = (size_t)SH.OC * SH.npix;
		{   /* THE FILL READS PAST THE PLANE.  act_extent() spans a FULL P-pixel window even
		     * on a short last tile, so stem.conv1's last SD asks for 576 bytes beyond
		     * [IW][IC] while the kernel writes only a 64-byte zero tail.  Harmless today --
		     * those pixels are past npix and their outputs are discarded -- but a watermark
		     * that stops at the plane makes hart 1 wait for bytes that are never published.
		     * Found by this gate on its first run. */
			uint64_t src, blocks;
			act_extent(SH.tiles_a - 1, &src, &blocks);
			g_arena = src + blocks * 64ULL;
		}
		g_src    = malloc((size_t)SH.IC * SH.IW);
		g_stage  = malloc((size_t)SH.IW * SH.IC + 4096);
		g_ostage = malloc((size_t)SH.npix * SH.OC);
		g_out    = malloc(obytes);
		ref      = malloc(obytes);
		for (size_t i = 0; i < (size_t)SH.IC * SH.IW; i++)
			g_src[i] = (int8_t)(((i * 1103515245u + 12345u) >> 17) | 1u);   /* odd */
		run_serial();   memcpy(ref, g_out, obytes);
		g_now = 0;
		run_pipelined();
		int diff = memcmp(ref, g_out, obytes) != 0;
		int exercised = (WM.ld_gated > 0) && (WM.st_published > 0);
		printf("  %-11s P=%-4d %2d act x %3d wgt   ld_gated %6llu  ld_spins %8llu  "
		       "st_pub %3llu  stall %llu  readahead %llu  earlyxpose %llu\n",
		       SH.name, SH.P, SH.tiles_a, SH.tiles_w,
		       (unsigned long long)WM.ld_gated, (unsigned long long)WM.ld_spins,
		       (unsigned long long)WM.st_published,
		       (unsigned long long)WM.stalled, (unsigned long long)g_readahead,
		       (unsigned long long)g_earlyxpose);
#if MBP_B102_POISON
		/* A POISON ARM THAT DIFFERS BECAUSE THE HANDSHAKE STALLED HAS PROVED NOTHING.
		 * The first run of this gate reported poison 2 "ok" on all three shapes when in fact
		 * every difference came from hart 1 spinning out the budget on a watermark bug of
		 * mine.  That is a passing state reachable without the thing under test being true,
		 * in the gate built to catch exactly that.  So the poison must bite with the
		 * handshake LIVE: no stall, and the gate actually exercised. */
		if (WM.stalled) { printf("     FAIL: the handshake STALLED (%llu) -- any difference "
					 "is the stall, not poison %d\n",
					 (unsigned long long)WM.stalled, MBP_B102_POISON); fails++; }
		else if (!(MBP_B102_POISON == 1 ? g_readahead : g_earlyxpose)) {
			printf("     SKIP: poison %d had no opportunity on this shape (%s = 0)\n",
			       MBP_B102_POISON,
			       MBP_B102_POISON == 1 ? "readahead" : "earlyxpose"); skips++; }
		else if (!diff) { printf("     FAIL: the poison had %llu opportunities and the result "
				    "is STILL identical -- it is not in this build\n",
				    (unsigned long long)(MBP_B102_POISON == 1 ? g_readahead
									      : g_earlyxpose)); fails++; }
		else if (!exercised) { printf("     FAIL: result differs but the gate was never "
					      "exercised -- the difference is not the poison\n"); fails++; }
		else        printf("     ok: poison %d changed the result with the handshake live\n",
				   MBP_B102_POISON);
#else
		if (WM.stalled) { printf("     FAIL: the handshake STALLED (%llu): hart 1 waited for "
					 "bytes hart 0 never published\n",
					 (unsigned long long)WM.stalled); fails++; }
		else if (g_readahead || g_earlyxpose) {
			printf("     FAIL: with the watermarks ON the fill read ahead %llu times and "
			       "hart 0 transposed early %llu times -- the gate does not hold\n",
			       (unsigned long long)g_readahead,
			       (unsigned long long)g_earlyxpose); fails++; }
		else if (diff)  { printf("     FAIL: pipelined result differs from the serial reference\n"); fails++; }
		else if (!exercised)
			   { printf("     FAIL: result matched but the gate was never exercised "
				    "(ld_spins %llu, st_published %llu) -- a dead path passes any "
				    "byte-for-byte gate\n",
				    (unsigned long long)WM.ld_spins,
				    (unsigned long long)WM.st_published); fails++; }
		else        printf("     ok: byte-identical AND the gate was exercised\n");
#endif
		free(g_src); free(g_stage); free(g_ostage); free(g_out); free(ref);
	}
	if (fails) { printf("B102_ORDER_FAIL %d of %d\n", fails, nshape); return 1; }
#if MBP_B102_POISON
	if (skips == nshape) { printf("B102_ORDER_FAIL: the poison bit on NO shape -- a gate that "
				      "cannot fail is not a gate\n"); return 1; }
	printf("B102_ORDER_OK poison %d bit on %d of %d shapes (%d skipped, no opportunity)\n",
	       MBP_B102_POISON, nshape - skips, nshape, skips);
#else
	printf("B102_ORDER_OK %d shapes\n", nshape);
#endif
	return 0;
}
