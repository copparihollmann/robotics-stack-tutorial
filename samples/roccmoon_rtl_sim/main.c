/* SPDX-License-Identifier: Apache-2.0
 *
 * The decoupled RoCC engine in the SoC's own RTL, in Verilator, before the board.
 *
 * tb_mbxr.cpp checks the engine alone against behavioural TileLink slaves.  This checks the
 * INTEGRATION the bitstream is built from -- RoccMoonShim in hart 1's tile, the BundleBridge
 * across the tile boundary, the engine's two clients on the real system bus, through the
 * real 64 KB InclusiveCache to DRAMSim -- with the board's driver (sw/roccmoon/mbxr.c):
 *
 *   hart 1: custom-1 answers with the engine's identity; one linear dispatch through the
 *           engine; MBP.DOT8 (custom-0) must still TRAP (patches/0101)
 *   hart 0: custom-1 must TRAP (no RoCC on tile 0); the reference kernel on the same data;
 *           compare every byte.
 *
 * A SECOND DISPATCH (golden2.h, from gen_golden2.c on the host): 40 x 288 -> 288, 6 tile pairs,
 * 180 result blocks, with INCREMENTAL PLACEMENT on.  Before it runs, hart 0 fills the scratch
 * area with poison through its own L1, so those blocks are dirty in hart 0's L1 when the engine
 * Puts its results: the real InclusiveCache must revoke them, and hart 1 must read each block
 * only below the drain's acknowledged watermark.  Every output byte is compared with the host
 * golden.  On a revision-1 engine the watermark reads 0 and nothing is placed early.
 *
 * Expect ROCCMOON_RTL_SIM: PASS.
 */
#include <stdint.h>
#include <stddef.h>
#include "mbxr.h"

void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }

volatile uint64_t tohost   __attribute__((section(".htif"), aligned(64)));
volatile uint64_t fromhost __attribute__((section(".htif"), aligned(64)));
static volatile uint64_t magic_mem[8] __attribute__((aligned(64)));

static void htif_syscall(uint64_t n, uint64_t a0, uint64_t a1, uint64_t a2)
{
	magic_mem[0] = n; magic_mem[1] = a0; magic_mem[2] = a1; magic_mem[3] = a2;
	__asm__ volatile ("fence" ::: "memory");
	tohost = (uint64_t)(uintptr_t)magic_mem;
	while (fromhost == 0) {
	}
	fromhost = 0;
	__asm__ volatile ("fence" ::: "memory");
}
static void hputs(const char *s) { size_t n = 0; while (s[n]) n++; if (n) htif_syscall(64, 1, (uint64_t)(uintptr_t)s, n); }
static void put_hex64(uint64_t v)
{
	char b[19]; b[0] = '0'; b[1] = 'x';
	for (int i = 0; i < 16; i++) { unsigned d = (unsigned)((v >> (60 - 4 * i)) & 0xf); b[2 + i] = (char)(d < 10 ? '0' + d : 'a' + d - 10); }
	b[18] = 0; hputs(b);
}
static void put_i64(int64_t v)
{
	char b[24]; int i = 23; uint64_t u; b[i--] = 0;
	u = (v < 0) ? ((uint64_t)(-(v + 1)) + 1u) : (uint64_t)v;
	if (!u) b[i--] = '0';
	while (u) { b[i--] = (char)('0' + u % 10); u /= 10; }
	if (v < 0) b[i--] = '-';
	hputs(&b[i + 1]);
}
__attribute__((noreturn)) static void htif_exit(int code)
{
	__asm__ volatile ("fence" ::: "memory");
	tohost = ((uint64_t)(unsigned)code << 1) | 1u;
	for (;;) {
	}
}

/* crt.S's trap bookkeeping, per hart; the handler skips the faulting 4-byte instruction */
volatile uint64_t mbp_trap_cause[2], mbp_trap_epc[2], mbp_trap_tval[2], mbp_trap_count[2];

/* custom-1 stubs, as the board image has them */
__asm__(".pushsection .text.rocc, \"ax\", @progbits\n.balign 4\n"
	"rc0: .insn r 0x2B, 3, 0, x0, a0, a1\n ret\n"
	"rc1: .insn r 0x2B, 3, 1, x0, a0, a1\n ret\n"
	"rc2: .insn r 0x2B, 3, 2, x0, a0, a1\n ret\n"
	"rc3: .insn r 0x2B, 3, 3, x0, a0, a1\n ret\n"
	"rc4: .insn r 0x2B, 3, 4, x0, a0, a1\n ret\n"
	"rc5: .insn r 0x2B, 3, 5, x0, a0, a1\n ret\n"
	"rc6: .insn r 0x2B, 7, 6, a0, a0, a1\n ret\n"
	"rc7: .insn r 0x2B, 7, 7, a0, a0, a1\n ret\n"
	"rc8: .insn r 0x2B, 3, 8, x0, a0, a1\n ret\n"
	"dot8: .insn r 0x0B, 0, 0, a0, a0, a1\n ret\n"
	".popsection\n");
extern uint64_t rc0(uint64_t, uint64_t) __asm__("rc0");
extern uint64_t rc1(uint64_t, uint64_t) __asm__("rc1");
extern uint64_t rc2(uint64_t, uint64_t) __asm__("rc2");
extern uint64_t rc3(uint64_t, uint64_t) __asm__("rc3");
extern uint64_t rc4(uint64_t, uint64_t) __asm__("rc4");
extern uint64_t rc5(uint64_t, uint64_t) __asm__("rc5");
extern uint64_t rc6(uint64_t, uint64_t) __asm__("rc6");
extern uint64_t rc7(uint64_t, uint64_t) __asm__("rc7");
extern uint64_t rc8(uint64_t, uint64_t) __asm__("rc8");
extern uint64_t dot8(uint64_t, uint64_t) __asm__("dot8");

static uint64_t cmd(void *ctx, unsigned f, uint64_t a, uint64_t b, int xd)
{
	(void)ctx; (void)xd;
	switch (f) { case 0: return rc0(a, b); case 1: return rc1(a, b); case 2: return rc2(a, b);
	case 3: return rc3(a, b); case 4: return rc4(a, b); case 5: return rc5(a, b);
	case 6: return rc6(a, b); case 7: return rc7(a, b); case 8: return rc8(a, b); }
	return ~0ULL;
}
static void *p2v(void *ctx, uint64_t pa) { (void)ctx; return (void *)(uintptr_t)pa; }

#define W_PA   0x81000000UL
#define IN_PA  0x81100008UL          /* 8 mod 64: the activation tile has a leading offset */
#define IMG_PA 0x81200000UL
#define SCR_PA 0x81300000UL
#define OUT_PA 0x81400000UL
#define REF_PA 0x81500000UL
#define B_PA   0x81600000UL
#define M 6
#define K 64
#define N 13

#include "golden2.h"
#define IN2_PA  0x81800008UL
#define IMG2_PA 0x81900000UL
#define SCR2_PA 0x81A00000UL
#define OUT2_PA 0x81B00000UL
static const mbxr_quant Q2 = { .mult = MULT2, .shift = SHIFT2, .amin = AMIN2, .amax = AMAX2 };
static volatile uint64_t h1_rc2, h1_early2, h1_polls2, h1_status2;

static volatile uint64_t go_hart1, hart1_done, h1_id, h1_rc, h1_polls, h1_status, h1_dot8_traps;

static void ref_linear(const int8_t *in, const int8_t *w, const int32_t *b, int8_t *out,
		       int32_t mult, int shift, int amin, int amax)
{
	for (int m = 0; m < M; m++)
		for (int n = 0; n < N; n++) {
			int32_t acc = b[n];
			for (int k = 0; k < K; k++) acc += (int32_t)in[m * K + k] * (int32_t)w[n * K + k];
			int64_t prod = ((int64_t)acc * mult + (1LL << 30)) >> 31;
			int32_t s = (int32_t)prod;
			if (shift > 0) s = (int32_t)(((int64_t)s + ((int64_t)1 << (shift - 1))) >> shift);
			else if (shift < 0) s = s << -shift;
			if (s < amin) s = amin;
			if (s > amax) s = amax;
			out[m * N + n] = (int8_t)s;
		}
}

static const mbxr_quant Q = { .mult = 1518500250, .shift = 5, .amin = -128, .amax = 127 };

void hart_main(unsigned long hartid)
{
	if (hartid == 1) {
		while (go_hart1 == 0) {
		}
		__asm__ volatile ("fence" ::: "memory");
		h1_id = rc7(MBXR_C_ID, 0);
		mbxr_dev dev = { cmd, p2v, 0, 200000 };
		mbxr_wimage img;
		mbxr_wimage_plan(&img, N, K);
		img.pa = IMG_PA;
		mbxr_stats st;
		memset(&st, 0, sizeof st);
		h1_rc = (uint64_t)(int64_t)mbxr_run(&dev, &img, IN_PA, M, K / 8, &Q, SCR_PA, (int8_t *)OUT_PA, &st);
		h1_polls = st.polls;
		h1_status = st.last_status;
		{
			mbxr_dev dev2 = { cmd, p2v, 0, 20000000, 0, 1, 1 };   /* 64-byte runs, placed early */
			mbxr_wimage img2;
			mbxr_wimage_plan(&img2, N2, K2);
			img2.pa = IMG2_PA;
			mbxr_stats st2;
			memset(&st2, 0, sizeof st2);
			h1_rc2 = (uint64_t)(int64_t)mbxr_run(&dev2, &img2, IN2_PA, M2, K2 / 8, &Q2, SCR2_PA,
							     (int8_t *)OUT2_PA, &st2);
			h1_early2 = st2.placed_early;
			h1_polls2 = st2.polls;
			h1_status2 = st2.last_status;
		}
		uint64_t before = mbp_trap_count[1];
		(void)dot8(0x0102030405060708ULL, 0x0101010101010101ULL);
		h1_dot8_traps = mbp_trap_count[1] - before;
		__asm__ volatile ("fence" ::: "memory");
		hart1_done = 1;
		for (;;) __asm__ volatile ("wfi");
	}
	if (hartid != 0) for (;;) __asm__ volatile ("wfi");

	int fails = 0;
	hputs("\n=== roccmoon RTL integration (Verilator, the SoC's own RTL) ===\n");
	/* hart 0 has no RoCC: custom-1 must trap */
	uint64_t t0 = mbp_trap_count[0];
	(void)rc7(MBXR_C_ID, 0);
	if (mbp_trap_count[0] - t0 != 1 || mbp_trap_cause[0] != 2) { hputs("FAIL custom-1 did not trap on hart 0\n"); fails++; }
	else hputs("hart 0: custom-1 traps (mcause 2), as it must\n");

	uint64_t x = 0x9E3779B97F4A7C15ULL;
	int8_t *w = (int8_t *)W_PA, *in = (int8_t *)IN_PA;
	int32_t *b = (int32_t *)B_PA;
	for (int i = 0; i < N * K; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; w[i] = (int8_t)x; }
	for (int i = 0; i < M * K; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; in[i] = (int8_t)x; }
	for (int i = 0; i < N; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; b[i] = (int32_t)(x % 20001) - 10000; }
	mbxr_dev dev0 = { cmd, p2v, 0, 0 };
	mbxr_wimage img;
	mbxr_wimage_plan(&img, N, K);
	mbxr_wimage_build(&dev0, &img, IMG_PA, w, b);
	for (int i = 0; i < M * N; i++) ((int8_t *)OUT_PA)[i] = 0x55;
	ref_linear(in, w, b, (int8_t *)REF_PA, Q.mult, Q.shift, Q.amin, Q.amax);
	{
		mbxr_wimage img2;
		mbxr_wimage_plan(&img2, N2, K2);
		memcpy((void *)IN2_PA, in2, sizeof in2);
		memset((void *)(IN2_PA + sizeof in2), 0, 64);
		mbxr_wimage_build(&dev0, &img2, IMG2_PA, w2, b2);
		unsigned char *scr = (unsigned char *)SCR2_PA;
		for (unsigned i = 0; i < (unsigned)(M2 * ((N2 + 3) / 4) * 4 + 64); i++) scr[i] = (unsigned char)(0xA5 ^ (i * 131));
		memset((void *)OUT2_PA, 0x55, M2 * N2);
	}
	__asm__ volatile ("fence" ::: "memory");

	go_hart1 = 1;
	while (hart1_done == 0) {
	}
	__asm__ volatile ("fence" ::: "memory");
	hputs("hart 1: engine id "); put_hex64(h1_id); hputs("  mbxr_run rc "); put_i64((int64_t)h1_rc);
	hputs("  polls "); put_i64((int64_t)h1_polls); hputs("  last fence "); put_hex64(h1_status); hputs("\n");
	if ((h1_id & 0xffff) != 0x4d52) { hputs("FAIL engine identity\n"); fails++; }
	if (h1_dot8_traps != 1) { hputs("FAIL MBP.DOT8 did not trap on hart 1 (patches/0101)\n"); fails++; }
	else hputs("hart 1: MBP.DOT8 traps (custom-0 not claimed by RoCCDecode)\n");
	if ((int64_t)h1_rc != 0) { hputs("FAIL engine dispatch\n"); fails++; }
	int bad = 0, maxe = 0;
	for (int i = 0; i < M * N; i++) {
		int e = ((int8_t *)OUT_PA)[i] - ((int8_t *)REF_PA)[i];
		if (e < 0) e = -e;
		if (e) bad++;
		if (e > maxe) maxe = e;
	}
	hputs("engine vs reference: "); put_i64(bad); hputs(" of "); put_i64(M * N);
	hputs(" bytes differ, max_abs_err "); put_i64(maxe); hputs("\n");
	if (bad) fails++;
	{
		int bad2 = 0;
		for (int i = 0; i < M2 * N2; i++) if (((int8_t *)OUT2_PA)[i] != gold2[i]) bad2++;
		hputs("dispatch 2 (40x288->288, placed early): mbxr_run rc "); put_i64((int64_t)h1_rc2);
		hputs("  polls "); put_i64((int64_t)h1_polls2); hputs("  placed early "); put_i64((int64_t)h1_early2);
		hputs(" of "); put_i64(M2 * N2); hputs(" bytes  last fence "); put_hex64(h1_status2);
		hputs("\nengine vs host golden: "); put_i64(bad2); hputs(" of "); put_i64(M2 * N2); hputs(" bytes differ\n");
		if ((int64_t)h1_rc2 != 0 || bad2) fails++;
	}
	hputs(fails ? "ROCCMOON_RTL_SIM: FAIL\n" : "ROCCMOON_RTL_SIM: PASS\n");
	htif_exit(fails ? 1 : 0);
}
