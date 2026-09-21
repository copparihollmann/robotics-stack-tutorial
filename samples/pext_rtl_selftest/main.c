/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * pext_rtl_selftest -- the RTL acceptance test for MBP, the four-op packed-SIMD
 * extension built into Rocket's ALU on hart 0.
 *
 * WHAT THIS IS, AND WHAT IT IS NOT.  samples/pext_selftest is the differential test
 * against a patched Spike: same source, three builds, diff the logs.  THIS one is the
 * test that only real RTL can run.  It is bare metal on the Chipyard Verilator
 * TestHarness for PynqZ2RocketBigLittlePextTacitConfig, and it does two things that a
 * functional simulator cannot answer:
 *
 *   1. It executes the instructions on the SYNTHESISED ALU, in the EX stage, with the
 *      core's own bypass network feeding the operands -- so a lane swap, a sign
 *      extension off by one bit, or a result that is silently truncated at bit 31 by
 *      the DW_32 path shows up here and nowhere earlier.
 *   2. It runs the NEGATIVE test.  Hart 1 is a LITTLE Rocket with no PExtDecode table
 *      and no SIMD datapath, so the same four encodings MUST raise an
 *      illegal-instruction exception there.  That is the heterogeneity mechanism
 *      (PEXT_SPEC.md 7.6), not a degradation path, and it is only checkable on a
 *      two-hart machine that really lacks the unit on one of them.
 *
 * THE REFERENCE IS fpga/pynq-z2/sw/pext.h.  Every hardware result is compared against
 * mb_pext_*_sw() from that header, which is the specification; if the two disagree, the
 * RTL is wrong.  On top of that, the cases marked "golden" below carry an ABSOLUTE
 * expected value written out by hand, because comparing hardware against a reference
 * that is compiled from the same header into the same binary cannot catch an error that
 * is in the reference.  The goldens are the independent reading.
 *
 * WHAT THE CASES COVER, deliberately:
 *
 *   DOT8   the full +-131072 range (all eight lanes -128 x -128 = +131072, and
 *          -128 x +127 = -130048), one live lane in each of the eight positions -- which
 *          is what catches a lane index or a shift that is off by one -- mixed signs,
 *          and 256 pseudo-random pairs.
 *   MAX8   -128 against +127 in both operand orders, equal lanes (the tie must pick a
 *          value, and both are the same value), a patterned word that puts a different
 *          winner in every lane, 256 random pairs, and the ReLU form with rs2 = x0 --
 *          which is a DIFFERENT ENCODING from max8(x, 0) and so is exercised separately.
 *   QMUL   the rounding boundary.  p = +2^30 and p = -2^30 are exact half-LSB ties:
 *          round-half-up gives (+1, 0), round-half-away-from-zero gives (+1, -1),
 *          round-half-to-even gives (0, 0).  Only half-up produces the pair the
 *          reference produces, so those two cases ALONE separate the three rules -- and
 *          getting this wrong is 1 LSB on roughly half of all negative outputs.  Also
 *          both int32 extremes, where the product needs all 62 bits, and operands with
 *          garbage in bits 63:32, which the instruction must ignore.
 *   CLIP8  saturation at both ends: -129/-128/-127 and +126/+127/+128, plus the int64
 *          extremes, plus values that differ only above the byte.
 *   the composition QMUL -> scalar rounding shift -> CLIP8 against mb_pext_requant_sw,
 *          which is the shape a quantised kernel's output stage actually has.
 */

#include <stdint.h>
#include <stddef.h>

#include <pext.h>

#if !MB_PEXT_HW
#error "build this with -DMB_PEXT_HW=1: the point is to execute the instructions"
#endif

/* ------------------------------------------------------------------ *
 * HTIF console and exit.  fesvr finds `tohost`/`fromhost` by symbol; the
 * .htif section only exists to give them a page of their own.
 * ------------------------------------------------------------------ */
volatile uint64_t tohost   __attribute__((section(".htif"), aligned(64)));
volatile uint64_t fromhost __attribute__((section(".htif"), aligned(64)));

static volatile uint64_t magic_mem[8] __attribute__((aligned(64)));

#define SYS_write 64

static void htif_syscall(uint64_t n, uint64_t a0, uint64_t a1, uint64_t a2)
{
	magic_mem[0] = n;
	magic_mem[1] = a0;
	magic_mem[2] = a1;
	magic_mem[3] = a2;
	__asm__ volatile ("fence" ::: "memory");
	tohost = (uint64_t)(uintptr_t)magic_mem;
	while (fromhost == 0) {
	}
	fromhost = 0;
	__asm__ volatile ("fence" ::: "memory");
}

static void hputs(const char *s)
{
	size_t n = 0;

	while (s[n]) {
		n++;
	}
	if (n) {
		htif_syscall(SYS_write, 1, (uint64_t)(uintptr_t)s, n);
	}
}

static void put_hex64(uint64_t v)
{
	char b[19];
	int i;

	b[0] = '0';
	b[1] = 'x';
	for (i = 0; i < 16; i++) {
		unsigned int d = (unsigned int)((v >> (60 - 4 * i)) & 0xf);

		b[2 + i] = (char)(d < 10 ? ('0' + d) : ('a' + d - 10));
	}
	b[18] = 0;
	hputs(b);
}

static void put_i64(int64_t v)
{
	char b[24];
	int i = 23;
	uint64_t u;

	b[i--] = 0;
	u = (v < 0) ? ((uint64_t)(-(v + 1)) + 1u) : (uint64_t)v;
	if (u == 0) {
		b[i--] = '0';
	}
	while (u) {
		b[i--] = (char)('0' + (u % 10u));
		u /= 10u;
	}
	if (v < 0) {
		b[i--] = '-';
	}
	hputs(&b[i + 1]);
}

static void put_u(unsigned int v)
{
	put_i64((int64_t)v);
}

__attribute__((noreturn)) static void htif_exit(int code)
{
	__asm__ volatile ("fence" ::: "memory");
	tohost = ((uint64_t)(unsigned int)code << 1) | 1u;
	for (;;) {
	}
}

/* ------------------------------------------------------------------ *
 * Trap bookkeeping.  crt.S writes these; indexed by mhartid.
 * ------------------------------------------------------------------ */
#define NHARTS 2
volatile uint64_t mbp_trap_cause[NHARTS];
volatile uint64_t mbp_trap_epc[NHARTS];
volatile uint64_t mbp_trap_tval[NHARTS];
volatile uint64_t mbp_trap_count[NHARTS];

#define CAUSE_ILLEGAL_INSTRUCTION 2

/* Cross-hart handshake.  Plain volatile plus an explicit fence: the L2 is coherent, so
 * this is an ordering problem and not a visibility one. */
static volatile uint64_t go_hart1;
static volatile uint64_t hart1_done;
static volatile uint64_t hart1_probe_pc[4];
static volatile uint64_t hart1_probe_rd[4];
static volatile uint64_t hart1_trap_cause[4];
static volatile uint64_t hart1_trap_epc[4];
static volatile uint64_t hart1_trap_tval[4];

/* ------------------------------------------------------------------ *
 * Test bookkeeping
 * ------------------------------------------------------------------ */
static unsigned int checks;
static unsigned int fails;

static void fail2(const char *what, uint64_t a, uint64_t b, int64_t got, int64_t want)
{
	fails++;
	if (fails > 40) {
		return;                 /* do not drown the log; the count is still exact */
	}
	hputs("FAIL ");
	hputs(what);
	hputs(" rs1=");
	put_hex64(a);
	hputs(" rs2=");
	put_hex64(b);
	hputs(" got=");
	put_hex64((uint64_t)got);
	hputs(" (");
	put_i64(got);
	hputs(") want=");
	put_hex64((uint64_t)want);
	hputs(" (");
	put_i64(want);
	hputs(")\n");
}

static void check2(const char *what, uint64_t a, uint64_t b, int64_t got, int64_t want)
{
	checks++;
	if (got != want) {
		fail2(what, a, b, got, want);
	}
}

/* xorshift64*, so the random cases are the same on every run and on every host. */
static uint64_t rng_state = 0x139408dcbbf7a44ull;

static uint64_t rnd64(void)
{
	uint64_t x = rng_state;

	x ^= x >> 12;
	x ^= x << 25;
	x ^= x >> 27;
	rng_state = x;
	return x * 0x2545f4914f6cdd1dull;
}

#define NRANDOM 256

/* ------------------------------------------------------------------ *
 * MBP.DOT8
 * ------------------------------------------------------------------ */
struct dot8_golden {
	uint64_t a, b;
	int64_t want;
};

static const struct dot8_golden dot8_goldens[] = {
	{ 0x0000000000000000ull, 0x0000000000000000ull,      0 },
	{ 0x0101010101010101ull, 0x0101010101010101ull,      8 },
	/* every lane -128 x -128: the positive extreme of the whole instruction */
	{ 0x8080808080808080ull, 0x8080808080808080ull, 131072 },
	/* every lane -128 x +127: the negative extreme */
	{ 0x8080808080808080ull, 0x7f7f7f7f7f7f7f7full, -130048 },
	{ 0x7f7f7f7f7f7f7f7full, 0x7f7f7f7f7f7f7f7full, 129032 },
	{ 0xffffffffffffffffull, 0x7f7f7f7f7f7f7f7full,  -1016 },
	{ 0xffffffffffffffffull, 0xffffffffffffffffull,      8 },
	{ 0x0000000000000080ull, 0x0000000000000080ull,  16384 },  /* lane 0 only */
	{ 0x8000000000000000ull, 0x8000000000000000ull,  16384 },  /* lane 7 only */
	{ 0x0000000000000080ull, 0x000000000000007full, -16256 },
	{ 0x8000000000000000ull, 0x7f00000000000000ull, -16256 },
	{ 0x0102030405060708ull, 0x0102030405060708ull,    204 },
	/* rs2 = 0 : the whole product vanishes, no partial lane survives */
	{ 0x0102030405060708ull, 0x0000000000000000ull,      0 },
};

static void t_dot8(void)
{
	unsigned int i;

	for (i = 0; i < sizeof(dot8_goldens) / sizeof(dot8_goldens[0]); i++) {
		uint64_t a = dot8_goldens[i].a, b = dot8_goldens[i].b;
		int64_t hw = mb_pext_dot8((int64_t)a, (int64_t)b);
		int64_t sw = mb_pext_dot8_sw((int64_t)a, (int64_t)b);

		check2("dot8/golden", a, b, hw, dot8_goldens[i].want);
		check2("dot8/ref",    a, b, hw, sw);
	}

	/* one live lane in each of the eight positions, both signs -- this is the case
	 * that catches a lane index or a byte shift that is off by one. */
	for (i = 0; i < 8; i++) {
		uint64_t a = (uint64_t)0x80u << (8 * i);
		uint64_t b = (uint64_t)0x7fu << (8 * i);
		int64_t hw = mb_pext_dot8((int64_t)a, (int64_t)b);

		check2("dot8/lane", a, b, hw, mb_pext_dot8_sw((int64_t)a, (int64_t)b));
		check2("dot8/lane/golden", a, b, hw, -16256);

		a = (uint64_t)0x7fu << (8 * i);
		hw = mb_pext_dot8((int64_t)a, (int64_t)b);
		check2("dot8/lane+", a, b, hw, mb_pext_dot8_sw((int64_t)a, (int64_t)b));
		check2("dot8/lane+/golden", a, b, hw, 16129);
	}

	for (i = 0; i < NRANDOM; i++) {
		uint64_t a = rnd64(), b = rnd64();
		int64_t hw = mb_pext_dot8((int64_t)a, (int64_t)b);

		check2("dot8/rand", a, b, hw, mb_pext_dot8_sw((int64_t)a, (int64_t)b));
	}
}

/* ------------------------------------------------------------------ *
 * MBP.MAX8
 * ------------------------------------------------------------------ */
struct max8_golden {
	uint64_t a, b, want;
};

static const struct max8_golden max8_goldens[] = {
	{ 0x8080808080808080ull, 0x7f7f7f7f7f7f7f7full, 0x7f7f7f7f7f7f7f7full },
	{ 0x7f7f7f7f7f7f7f7full, 0x8080808080808080ull, 0x7f7f7f7f7f7f7f7full },
	{ 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull },
	{ 0xffffffffffffffffull, 0x0000000000000000ull, 0x0000000000000000ull },  /* -1 vs 0 */
	{ 0x0102030405060708ull, 0x0102030405060708ull, 0x0102030405060708ull },
	/* a different winner in every lane, alternating */
	{ 0x80ff7f01fe0200f0ull, 0x7f01800200ff01feull, 0x7f017f02000201feull },
	/* the unsigned reading would pick the other operand in every lane here */
	{ 0x8080808080808080ull, 0x0000000000000000ull, 0x0000000000000000ull },
};

static void t_max8(void)
{
	unsigned int i;

	for (i = 0; i < sizeof(max8_goldens) / sizeof(max8_goldens[0]); i++) {
		uint64_t a = max8_goldens[i].a, b = max8_goldens[i].b;
		int64_t hw = mb_pext_max8((int64_t)a, (int64_t)b);

		check2("max8/golden", a, b, hw, (int64_t)max8_goldens[i].want);
		check2("max8/ref",    a, b, hw, mb_pext_max8_sw((int64_t)a, (int64_t)b));
	}

	for (i = 0; i < NRANDOM; i++) {
		uint64_t a = rnd64(), b = rnd64();
		int64_t hw = mb_pext_max8((int64_t)a, (int64_t)b);

		check2("max8/rand", a, b, hw, mb_pext_max8_sw((int64_t)a, (int64_t)b));
	}

	/* The ReLU form.  rs2 = x0 is a DIFFERENT ENCODING from max8(x, 0) -- the
	 * assembler puts register 0 in the rs2 field rather than a register holding
	 * zero -- so it gets its own cases. */
	{
		static const uint64_t relu_in[] = {
			0x8080808080808080ull, 0x7f7f7f7f7f7f7f7full,
			0xffffffffffffffffull, 0x0000000000000000ull,
			0x80ff7f01fe0200f0ull, 0x0102030405060708ull,
		};
		static const uint64_t relu_want[] = {
			0x0000000000000000ull, 0x7f7f7f7f7f7f7f7full,
			0x0000000000000000ull, 0x0000000000000000ull,
			0x00007f0100020000ull, 0x0102030405060708ull,
		};

		for (i = 0; i < sizeof(relu_in) / sizeof(relu_in[0]); i++) {
			uint64_t a = relu_in[i];
			int64_t hw = mb_pext_relu8((int64_t)a);

			check2("relu8/golden", a, 0, hw, (int64_t)relu_want[i]);
			check2("relu8/ref",    a, 0, hw, mb_pext_max8_sw((int64_t)a, 0));
		}
		for (i = 0; i < NRANDOM; i++) {
			uint64_t a = rnd64();
			int64_t hw = mb_pext_relu8((int64_t)a);

			check2("relu8/rand", a, 0, hw, mb_pext_max8_sw((int64_t)a, 0));
		}
	}
}

/* ------------------------------------------------------------------ *
 * MBP.QMUL -- p = (sext32(rs1) * sext32(rs2) + 2^30) >> 31, ROUND-HALF-UP
 * ------------------------------------------------------------------ */
struct qmul_golden {
	int32_t a, m;
	int64_t want;
	const char *why;
};

static const struct qmul_golden qmul_goldens[] = {
	/* THE ROUNDING BOUNDARY.  p = +-2^30 are exact half-LSB ties.
	 *   half-up            -> (+1,  0)   <- the reference, and what this must be
	 *   half-away-from-0   -> (+1, -1)
	 *   half-to-even       -> ( 0,  0)
	 * These two rows alone separate all three rules. */
	{  2, 1 << 29,  1, "tie +2^30 -> +1 (half-up)" },
	{ -2, 1 << 29,  0, "tie -2^30 ->  0 (half-up, NOT -1)" },
	/* the next ties up and down */
	{  6, 1 << 29,  2, "tie +3*2^30 -> +2" },
	{ -6, 1 << 29, -1, "tie -3*2^30 -> -1" },
	/* just either side of a tie, so a fencepost error shows */
	{  2, (1 << 29) + 1,  1, "just above the +tie" },
	{  2, (1 << 29) - 1,  0, "just below the +tie" },
	{ -2, (1 << 29) + 1, -1, "just below the -tie" },
	{ -2, (1 << 29) - 1,  0, "just above the -tie" },
	/* the int32 extremes: the product needs all 62 bits */
	{ (int32_t)0x80000000, (int32_t)0x80000000,  2147483648LL, "INT32_MIN^2" },
	{ (int32_t)0x80000000, (int32_t)0x7fffffff, -2147483647LL, "INT32_MIN*INT32_MAX" },
	{ (int32_t)0x7fffffff, (int32_t)0x7fffffff,  2147483646LL, "INT32_MAX^2" },
	{ (int32_t)0x7fffffff, (int32_t)0x80000000, -2147483647LL, "INT32_MAX*INT32_MIN" },
	/* small values all round to zero, and -1 must NOT round to -1 */
	{  0, (int32_t)0x7fffffff, 0, "zero" },
	{  1, 1, 0, "1*1" },
	{ -1, 1, 0, "-1*1 -> 0, not -1" },
	{ -1, (int32_t)0x40000000, 0, "-0.5 in Q0.31 is the -tie -> 0, NOT -1" },
	{  1, (int32_t)0x40000000, 1, "+0.5 in Q0.31 is the +tie -> 1" },
	/* a Q0.31 multiplier of 0.5 against a real-sized accumulator */
	{  1000000, (int32_t)0x40000000,  500000, "0.5 * 1e6" },
	{ -1000000, (int32_t)0x40000000, -500000, "0.5 * -1e6" },
};

static void t_qmul(void)
{
	unsigned int i;

	for (i = 0; i < sizeof(qmul_goldens) / sizeof(qmul_goldens[0]); i++) {
		int64_t a = (int64_t)qmul_goldens[i].a;
		int64_t m = (int64_t)qmul_goldens[i].m;
		int64_t hw = mb_pext_qmul(a, m);

		check2("qmul/golden", (uint64_t)a, (uint64_t)m, hw, qmul_goldens[i].want);
		check2("qmul/ref",    (uint64_t)a, (uint64_t)m, hw, mb_pext_qmul_sw(a, m));

		/* Bits 63:32 of both operands MUST be ignored.  This is the case that
		 * catches an RTL that widened the multiply instead of truncating. */
		{
			uint64_t ag = ((uint64_t)a & 0xffffffffull) | 0xdeadbeef00000000ull;
			uint64_t mg = ((uint64_t)m & 0xffffffffull) | 0xcafef00d00000000ull;
			int64_t hwg = mb_pext_qmul((int64_t)ag, (int64_t)mg);

			check2("qmul/hi-garbage", ag, mg, hwg, qmul_goldens[i].want);
		}
	}

	for (i = 0; i < NRANDOM; i++) {
		uint64_t a = rnd64(), m = rnd64();
		int64_t hw = mb_pext_qmul((int64_t)a, (int64_t)m);

		check2("qmul/rand", a, m, hw, mb_pext_qmul_sw((int64_t)a, (int64_t)m));
	}

	/* Sweep the tie neighbourhood exhaustively in one dimension: for m = 2^29,
	 * p = a * 2^29, so a = 2k puts p exactly on the k-th tie. */
	for (i = 0; i < 64; i++) {
		int64_t a = (int64_t)i - 32;
		int64_t m = 1 << 29;
		int64_t hw = mb_pext_qmul(a, m);

		check2("qmul/tiesweep", (uint64_t)a, (uint64_t)m, hw, mb_pext_qmul_sw(a, m));
	}
}

/* ------------------------------------------------------------------ *
 * MBP.CLIP8 -- rd = sext64(clamp(rs1, -128, +127)), rs2 ignored
 * ------------------------------------------------------------------ */
struct clip8_golden {
	int64_t in, want;
};

static const struct clip8_golden clip8_goldens[] = {
	{        0,    0 },
	{      127,  127 },
	{      128,  127 },   /* saturates high by one */
	{      129,  127 },
	{     -128, -128 },
	{     -129, -128 },   /* saturates low by one */
	{     -130, -128 },
	{      126,  126 },
	{     -127, -127 },
	{      255,  127 },
	{     -256, -128 },
	{  0x7fffffffffffffffLL,  127 },   /* INT64_MAX */
	{ -0x7fffffffffffffffLL - 1, -128 },   /* INT64_MIN */
	{  0x0000000100000000LL,  127 },   /* only a high bit set */
	{ -0x0000000100000000LL, -128 },
	{  0x000000000000007fLL,  127 },
	{  0x0000000000000080LL,  127 },   /* +128, NOT -128: rs1 is a full int64 */
	{ (int64_t)0xffffffffffffff80ULL, -128 },   /* the bit pattern of -128 */
};

static void t_clip8(void)
{
	unsigned int i;

	for (i = 0; i < sizeof(clip8_goldens) / sizeof(clip8_goldens[0]); i++) {
		int64_t q = clip8_goldens[i].in;
		int64_t hw = mb_pext_clip8(q);

		check2("clip8/golden", (uint64_t)q, 0, hw, clip8_goldens[i].want);
		check2("clip8/ref",    (uint64_t)q, 0, hw, mb_pext_clip8_sw(q));
	}

	/* walk the whole in-range interval plus a margin at both ends */
	for (i = 0; i < 512; i++) {
		int64_t q = (int64_t)i - 256;
		int64_t hw = mb_pext_clip8(q);

		check2("clip8/walk", (uint64_t)q, 0, hw, mb_pext_clip8_sw(q));
	}

	for (i = 0; i < NRANDOM; i++) {
		uint64_t q = rnd64();
		int64_t hw = mb_pext_clip8((int64_t)q);

		check2("clip8/rand", q, 0, hw, mb_pext_clip8_sw((int64_t)q));
	}
}

/* ------------------------------------------------------------------ *
 * The composed output stage: QMUL, a scalar rounding shift, then CLIP8.
 * This is the shape a quantised kernel actually emits, and the thing the
 * fused MBP.RQS was split into.
 * ------------------------------------------------------------------ */
static void t_requant(void)
{
	static const int32_t mults[] = {
		(int32_t)0x40000000, (int32_t)0x7fffffff, (int32_t)0x60000000,
		(int32_t)0x4b1e2d3c, 1, (int32_t)0x80000000,
	};
	static const uint32_t shifts[] = { 0, 1, 2, 7, 8, 15, 31 };
	unsigned int i, j, k;

	for (i = 0; i < sizeof(mults) / sizeof(mults[0]); i++) {
		for (j = 0; j < sizeof(shifts) / sizeof(shifts[0]); j++) {
			for (k = 0; k < 24; k++) {
				int64_t acc = (int64_t)(int32_t)rnd64();
				uint32_t s = shifts[j];
				int64_t round = MB_PEXT_ROUND(s);
				int64_t p = mb_pext_qmul(acc, (int64_t)mults[i]);
				int64_t q = s ? ((p + round) >> s) : p;
				int64_t hw = mb_pext_clip8(q);
				int64_t sw = mb_pext_requant_sw(acc, mults[i], s);

				check2("requant/ref", (uint64_t)acc,
				       (uint64_t)mults[i], hw, sw);
			}
		}
	}
}

/* ------------------------------------------------------------------ *
 * The negative test: the same four encodings on hart 1 must trap.
 *
 * Written out with `.insn` rather than through pext.h's intrinsics on purpose --
 * this is the one place where the encoding itself is under test, and going
 * through the header would prove only that the header agrees with itself.
 * ------------------------------------------------------------------ */
static void hart1_probe(void)
{
	uint64_t a = 0x0102030405060708ull;
	uint64_t b = 0x1112131415161718ull;
	uint64_t rd;
	uint64_t pc;
	unsigned int i;

	for (i = 0; i < 4; i++) {
		rd = 0xa5a5a5a5a5a5a5a5ull;
		pc = 0;
		switch (i) {
		case 0:         /* MBP.DOT8  rd, rs1, rs2 */
			__asm__ volatile ("la %0, 1f\n1:\t.insn r 0x0b, 0, 0, %1, %2, %3"
					  : "=&r"(pc), "+r"(rd) : "r"(a), "r"(b));
			break;
		case 1:         /* MBP.MAX8  rd, rs1, rs2 */
			__asm__ volatile ("la %0, 1f\n1:\t.insn r 0x0b, 1, 0, %1, %2, %3"
					  : "=&r"(pc), "+r"(rd) : "r"(a), "r"(b));
			break;
		case 2:         /* MBP.QMUL  rd, rs1, rs2 */
			__asm__ volatile ("la %0, 1f\n1:\t.insn r 0x0b, 2, 0, %1, %2, %3"
					  : "=&r"(pc), "+r"(rd) : "r"(a), "r"(b));
			break;
		default:        /* MBP.CLIP8 rd, rs1, x0 */
			__asm__ volatile ("la %0, 1f\n1:\t.insn r 0x0b, 3, 0, %1, %2, x0"
					  : "=&r"(pc), "+r"(rd) : "r"(a));
			break;
		}
		hart1_probe_pc[i] = pc;
		hart1_probe_rd[i] = rd;
		hart1_trap_cause[i] = mbp_trap_cause[1];
		hart1_trap_epc[i] = mbp_trap_epc[1];
		hart1_trap_tval[i] = mbp_trap_tval[1];
	}
}

/* ------------------------------------------------------------------ */

static void report_hart1(void)
{
	unsigned int i;
	static const char * const names[4] = { "DOT8", "MAX8", "QMUL", "CLIP8" };

	if (mbp_trap_count[1] != 4) {
		fails++;
		hputs("FAIL hart1: expected 4 traps, saw ");
		put_i64((int64_t)mbp_trap_count[1]);
		hputs("\n");
	}
	checks++;

	for (i = 0; i < 4; i++) {
		checks += 3;
		if (hart1_trap_cause[i] != CAUSE_ILLEGAL_INSTRUCTION) {
			fails++;
			hputs("FAIL hart1 ");
			hputs(names[i]);
			hputs(": mcause=");
			put_hex64(hart1_trap_cause[i]);
			hputs(" expected 2 (illegal instruction)\n");
		}
		if (hart1_trap_epc[i] != hart1_probe_pc[i]) {
			fails++;
			hputs("FAIL hart1 ");
			hputs(names[i]);
			hputs(": mepc=");
			put_hex64(hart1_trap_epc[i]);
			hputs(" expected ");
			put_hex64(hart1_probe_pc[i]);
			hputs("\n");
		}
		if (hart1_probe_rd[i] != 0xa5a5a5a5a5a5a5a5ull) {
			fails++;
			hputs("FAIL hart1 ");
			hputs(names[i]);
			hputs(": rd was written (");
			put_hex64(hart1_probe_rd[i]);
			hputs(") -- a trapped instruction must not commit\n");
		}
		hputs("  hart1 ");
		hputs(names[i]);
		hputs(": mcause=");
		put_i64((int64_t)hart1_trap_cause[i]);
		hputs(" mepc=");
		put_hex64(hart1_trap_epc[i]);
		hputs(" mtval=");
		put_hex64(hart1_trap_tval[i]);
		hputs(" rd=");
		put_hex64(hart1_probe_rd[i]);
		hputs("\n");
	}
}

void hart_main(unsigned long hartid)
{
	if (hartid == 1) {
		while (go_hart1 == 0) {
		}
		__asm__ volatile ("fence" ::: "memory");
		hart1_probe();
		__asm__ volatile ("fence" ::: "memory");
		hart1_done = 1;
		for (;;) {
			__asm__ volatile ("wfi");
		}
	}

	if (hartid != 0) {
		for (;;) {
			__asm__ volatile ("wfi");
		}
	}

	hputs("\n=== MBP packed-SIMD RTL selftest ===\n");
	hputs("hart 0 (BIG): executing DOT8 / MAX8 / QMUL / CLIP8 on the ALU\n");

	t_dot8();
	t_max8();
	t_qmul();
	t_clip8();
	t_requant();

	checks++;
	if (mbp_trap_count[0] != 0) {
		fails++;
		hputs("FAIL hart0 took ");
		put_i64((int64_t)mbp_trap_count[0]);
		hputs(" trap(s); mcause=");
		put_hex64(mbp_trap_cause[0]);
		hputs(" mepc=");
		put_hex64(mbp_trap_epc[0]);
		hputs(" -- the instructions must be legal here\n");
	}

	hputs("hart 0: ");
	put_u(checks);
	hputs(" checks, ");
	put_u(fails);
	hputs(" failures\n");

	/* --- the negative test --- */
	hputs("hart 1 (LITTLE): the same four encodings must raise illegal-instruction\n");
	__asm__ volatile ("fence" ::: "memory");
	go_hart1 = 1;
	{
		uint64_t spins = 0;

		while (hart1_done == 0) {
			if (++spins > 200000000ull) {
				fails++;
				hputs("FAIL hart1 never reported -- did it start?\n");
				break;
			}
		}
	}
	__asm__ volatile ("fence" ::: "memory");
	if (hart1_done) {
		report_hart1();
	}

	hputs("TOTAL ");
	put_u(checks);
	hputs(" checks, ");
	put_u(fails);
	hputs(" failures\n");
	hputs(fails == 0 ? "PEXT_RTL_SELFTEST: PASS\n" : "PEXT_RTL_SELFTEST: FAIL\n");

	htif_exit(fails == 0 ? 0 : 1);
}
