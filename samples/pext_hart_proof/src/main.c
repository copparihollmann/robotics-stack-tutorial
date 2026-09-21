/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * pext_hart_proof -- the MBP acceptance test, on real silicon.
 *
 * samples/pext_rtl_selftest is the same test on the Verilator model of this SoC. This one
 * runs it on the PYNQ-Z1, under Zephyr SMP, on the routed bitstream, and it exists because
 * three things are only answerable there:
 *
 *   1. The four MBP ops compute what fpga/pynq-z2/sw/pext.h says they compute, on the
 *      PLACED AND ROUTED ALU at 34.4828 MHz. Simulation proves the logic; only hardware
 *      proves the logic closed timing. A path that is 0.1 ns short does not produce a
 *      neat failure -- it produces one wrong lane, sometimes.
 *
 *   2. THE NEGATIVE TEST. Hart 1 is a LITTLE Rocket built without the MBP decode table
 *      and without the datapath, so the same four encodings MUST raise an
 *      illegal-instruction exception there. This is the whole heterogeneity claim. Without
 *      it, an accidental WithPExtOnTiles() covering both tiles -- which elaborates, builds,
 *      routes and boots -- would pass every other check in this file.
 *
 *   3. Both harts still report the same riscv,isa, from the hardware's own misa CSR.
 *      MBP lives in the custom-0 opcode space, which has no extension letter, so misa is
 *      IDENTICAL on the two harts even though one of them has the unit. That is not a
 *      wrinkle, it is the reason 2 has to execute an instruction rather than read a
 *      register.
 *
 * THE REFERENCE IS fpga/pynq-z2/sw/pext.h, and it is frozen. Every hardware result is
 * compared against mb_pext_*_sw() from that header; if the two disagree, the HARDWARE is
 * wrong. On top of that, the cases marked "golden" carry an absolute expected value
 * written out by hand, because comparing hardware against a reference compiled from the
 * same header into the same binary cannot catch an error that is in the reference.
 *
 * The golden tables and the case selection below are deliberately the same ones
 * samples/pext_rtl_selftest uses, so a divergence between simulation and silicon is a
 * difference in the hardware and not a difference in the test.
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/printk.h>
#include <zephyr/arch/riscv/csr.h>

#include <pext.h>

#if !MB_PEXT_HW
#error "build this with MB_PEXT_HW=1: the point is to execute the instructions"
#endif

#define STACK_SIZE       4096
#define JOIN_TIMEOUT_S   60
#define CAUSE_ILLEGAL_INSTRUCTION 2
#define CLOCK_PROBE_MS   3000

/* misa bits 18 (S) and 20 (U) are PRIVILEGE MODES, not instruction-set extensions, and on
 * this SoC they are exactly what differs between the two harts: WithNSmallCores sets
 * useVM = false, so the LITTLE core has no supervisor mode and no user mode. That is the
 * documented big.LITTLE asymmetry (DUAL_CORE.md section 7), it is unrelated to MBP, and
 * it is why "both harts report the same riscv,isa" is a statement about the ISA LETTERS
 * and not about the raw misa word. MEASURED on the board:
 *   hart 0  misa = 0x8000000000941105  -> rv64 a c i m s u x
 *   hart 1  misa = 0x8000000000801105  -> rv64 a c i m     x
 * Mask S and U off and the two are identical, which is what the generated DTS's
 * riscv,isa = "rv64imaczicsr_zifencei_zihpm_xrocket" says for BOTH harts. */
#define MISA_S   (1ull << 18)
#define MISA_U   (1ull << 20)
#define MISA_PRIV_MASK  (MISA_S | MISA_U)
#define MISA_ISA(m)     ((m) & ~MISA_PRIV_MASK)

K_THREAD_STACK_DEFINE(big_stack, STACK_SIZE);
K_THREAD_STACK_DEFINE(little_stack, STACK_SIZE);
static struct k_thread big_thread, little_thread;
static struct k_sem done_sem;

/* ------------------------------------------------------------------ *
 * Test bookkeeping. One counter pair for the whole run; the workers do not
 * run at the same time (main() joins the first before starting the second),
 * so no atomics are needed and the counts stay exactly comparable with the
 * Verilator run's.
 * ------------------------------------------------------------------ */
static unsigned int checks;
static unsigned int fails;
static unsigned int printed;

static void fail2(const char *what, uint64_t a, uint64_t b, int64_t got, int64_t want)
{
	fails++;
	if (++printed > 40) {
		return;         /* do not drown the console; the count stays exact */
	}
	printk("FAIL %s rs1=0x%016llx rs2=0x%016llx got=0x%016llx (%lld) "
	       "want=0x%016llx (%lld)\n", what,
	       (unsigned long long)a, (unsigned long long)b,
	       (unsigned long long)got, (long long)got,
	       (unsigned long long)want, (long long)want);
}

static void check2(const char *what, uint64_t a, uint64_t b, int64_t got, int64_t want)
{
	checks++;
	if (got != want) {
		fail2(what, a, b, got, want);
	}
}

/* xorshift64*, so the random cases are identical on every run, on the board and on the
 * Verilator model. The seed is the same one samples/pext_rtl_selftest uses. */
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
	{ 0x0102030405060708ull, 0x0000000000000000ull,      0 },
};

static void t_dot8(void)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(dot8_goldens); i++) {
		uint64_t a = dot8_goldens[i].a, b = dot8_goldens[i].b;
		int64_t hw = mb_pext_dot8((int64_t)a, (int64_t)b);

		check2("dot8/golden", a, b, hw, dot8_goldens[i].want);
		check2("dot8/ref",    a, b, hw, mb_pext_dot8_sw((int64_t)a, (int64_t)b));
	}

	/* one live lane in each of the eight positions, both signs -- the case that
	 * catches a lane index or a byte shift that is off by one. */
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

	for (i = 0; i < ARRAY_SIZE(max8_goldens); i++) {
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

	/* The ReLU form. rs2 = x0 is a DIFFERENT ENCODING from max8(x, 0) -- the
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

		for (i = 0; i < ARRAY_SIZE(relu_in); i++) {
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
};

static const struct qmul_golden qmul_goldens[] = {
	/* THE ROUNDING BOUNDARY. p = +-2^30 are exact half-LSB ties.
	 *   half-up          -> (+1,  0)   <- the reference, and what this must be
	 *   half-away-from-0 -> (+1, -1)
	 *   half-to-even     -> ( 0,  0)
	 * These two rows alone separate all three rules, and getting it wrong is 1 LSB on
	 * roughly half of all negative outputs. */
	{  2, 1 << 29,  1 },
	{ -2, 1 << 29,  0 },
	{  6, 1 << 29,  2 },
	{ -6, 1 << 29, -1 },
	/* just either side of a tie, so a fencepost error shows */
	{  2, (1 << 29) + 1,  1 },
	{  2, (1 << 29) - 1,  0 },
	{ -2, (1 << 29) + 1, -1 },
	{ -2, (1 << 29) - 1,  0 },
	/* the int32 extremes: the product needs all 62 bits */
	{ (int32_t)0x80000000, (int32_t)0x80000000,  2147483648LL },
	{ (int32_t)0x80000000, (int32_t)0x7fffffff, -2147483647LL },
	{ (int32_t)0x7fffffff, (int32_t)0x7fffffff,  2147483646LL },
	{ (int32_t)0x7fffffff, (int32_t)0x80000000, -2147483647LL },
	{  0, (int32_t)0x7fffffff, 0 },
	{  1, 1, 0 },
	{ -1, 1, 0 },
	{ -1, (int32_t)0x40000000, 0 },
	{  1, (int32_t)0x40000000, 1 },
	{  1000000, (int32_t)0x40000000,  500000 },
	{ -1000000, (int32_t)0x40000000, -500000 },
};

static void t_qmul(void)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(qmul_goldens); i++) {
		int64_t a = (int64_t)qmul_goldens[i].a;
		int64_t m = (int64_t)qmul_goldens[i].m;
		int64_t hw = mb_pext_qmul(a, m);

		check2("qmul/golden", (uint64_t)a, (uint64_t)m, hw, qmul_goldens[i].want);
		check2("qmul/ref",    (uint64_t)a, (uint64_t)m, hw, mb_pext_qmul_sw(a, m));

		/* Bits 63:32 of both operands MUST be ignored. This is the case that
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
	{      128,  127 },                       /* saturates high by one */
	{      129,  127 },
	{     -128, -128 },
	{     -129, -128 },                       /* saturates low by one */
	{     -130, -128 },
	{      126,  126 },
	{     -127, -127 },
	{      255,  127 },
	{     -256, -128 },
	{  0x7fffffffffffffffLL,  127 },          /* INT64_MAX */
	{ -0x7fffffffffffffffLL - 1, -128 },      /* INT64_MIN */
	{  0x0000000100000000LL,  127 },          /* only a high bit set */
	{ -0x0000000100000000LL, -128 },
	{  0x000000000000007fLL,  127 },
	{  0x0000000000000080LL,  127 },          /* +128, NOT -128: rs1 is a full int64 */
	{ (int64_t)0xffffffffffffff80ULL, -128 }, /* the bit pattern of -128 */
};

static void t_clip8(void)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(clip8_goldens); i++) {
		int64_t q = clip8_goldens[i].in;
		int64_t hw = mb_pext_clip8(q);

		check2("clip8/golden", (uint64_t)q, 0, hw, clip8_goldens[i].want);
		check2("clip8/ref",    (uint64_t)q, 0, hw, mb_pext_clip8_sw(q));
	}

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
 * The composed output stage: QMUL, a scalar rounding shift, then CLIP8 --
 * the shape a quantised kernel actually emits, and what the fused MBP.RQS
 * was split into.
 * ------------------------------------------------------------------ */
static void t_requant(void)
{
	static const int32_t mults[] = {
		(int32_t)0x40000000, (int32_t)0x7fffffff, (int32_t)0x60000000,
		(int32_t)0x4b1e2d3c, 1, (int32_t)0x80000000,
	};
	static const uint32_t shifts[] = { 0, 1, 2, 7, 8, 15, 31 };
	unsigned int i, j, k;

	for (i = 0; i < ARRAY_SIZE(mults); i++) {
		for (j = 0; j < ARRAY_SIZE(shifts); j++) {
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
 * The trap probe. Runs on BOTH harts, with opposite expectations.
 *
 * Written out with `.insn` rather than through pext.h's intrinsics on purpose: this is
 * the one place where the ENCODING itself is under test, and going through the header
 * would prove only that the header agrees with itself.
 * ------------------------------------------------------------------ */
struct mbp_trap_rec {         /* offsets are hard-coded in trap.S */
	uint64_t scratch;     /*  0 */
	uint64_t mcause;      /*  8 */
	uint64_t mepc;        /* 16 */
	uint64_t mtval;       /* 24 */
	uint64_t count;       /* 32 */
};

extern void mbp_probe_trap_entry(void);

#define NPROBE 4
static const char * const probe_names[NPROBE] = { "DOT8", "MAX8", "QMUL", "CLIP8" };

struct probe_out {
	uint64_t pc[NPROBE];
	uint64_t rd[NPROBE];
	uint64_t cause[NPROBE];
	uint64_t epc[NPROBE];
	uint64_t tval[NPROBE];
	uint64_t traps[NPROBE];   /* cumulative trap count after each probe */
	uint64_t misa;
	uint32_t hartid;
	uint32_t cpu_id;
	bool     ran;
};

/* The operands are the ones whose CORRECT results are known, so the hart that does
 * implement MBP can be checked for a value and not merely for "no trap". */
#define PROBE_A 0x0102030405060708ull
#define PROBE_B 0x1112131415161718ull

static void run_probe(struct probe_out *out)
{
	static struct mbp_trap_rec rec;   /* one at a time: the two probes never overlap */
	unsigned int key;
	uintptr_t old_mtvec, old_mscratch;
	uint64_t a = PROBE_A, b = PROBE_B;
	unsigned int i;

	rec.count = 0;
	rec.mcause = 0;
	rec.mepc = 0;
	rec.mtval = 0;

	out->hartid = (uint32_t)mb_pext_mhartid();
	out->cpu_id = (uint32_t)arch_curr_cpu()->id;
	out->misa = csr_read(misa);

	/* Nothing may trap in this window except the instruction under test, and nothing
	 * may observe the displaced mtvec. See trap.S. */
	key = irq_lock();
	old_mtvec = csr_read(mtvec);
	old_mscratch = csr_read(mscratch);
	csr_write(mscratch, (uintptr_t)&rec);
	csr_write(mtvec, (uintptr_t)&mbp_probe_trap_entry);   /* bits [1:0] = 0: direct */

	for (i = 0; i < NPROBE; i++) {
		uint64_t rd = 0xa5a5a5a5a5a5a5a5ull;
		uint64_t pc = 0;

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
		out->pc[i] = pc;
		out->rd[i] = rd;
		out->cause[i] = rec.mcause;
		out->epc[i] = rec.mepc;
		out->tval[i] = rec.mtval;
		out->traps[i] = rec.count;
	}

	csr_write(mtvec, old_mtvec);
	csr_write(mscratch, old_mscratch);
	irq_unlock(key);

	out->ran = true;
}

/* ------------------------------------------------------------------ *
 * Reporting
 * ------------------------------------------------------------------ */
static void decode_misa(uint64_t misa, char *buf, size_t n)
{
	static const char letters[] = "abcdefghijklmnopqrstuvwxyz";
	size_t k = 0;
	unsigned int mxl = (unsigned int)(misa >> 62) & 3u;
	unsigned int i;

	if (k + 5 < n) {
		buf[k++] = 'r';
		buf[k++] = 'v';
		buf[k++] = (mxl == 1) ? '3' : (mxl == 2) ? '6' : '?';
		buf[k++] = (mxl == 1) ? '2' : (mxl == 2) ? '4' : '?';
	}
	for (i = 0; i < 26; i++) {
		if ((misa & (1ull << i)) && k + 1 < n) {
			buf[k++] = letters[i];
		}
	}
	buf[k < n ? k : n - 1] = '\0';
}

static void report_probe(const struct probe_out *o, bool expect_trap)
{
	unsigned int i;
	char isa[40];
	int64_t want[NPROBE];

	want[0] = mb_pext_dot8_sw((int64_t)PROBE_A, (int64_t)PROBE_B);
	want[1] = mb_pext_max8_sw((int64_t)PROBE_A, (int64_t)PROBE_B);
	want[2] = mb_pext_qmul_sw((int64_t)PROBE_A, (int64_t)PROBE_B);
	want[3] = mb_pext_clip8_sw((int64_t)PROBE_A);

	decode_misa(o->misa, isa, sizeof(isa));
	printk("   cpu %u / mhartid %u : misa = 0x%016llx -> \"%s\"\n",
	       o->cpu_id, o->hartid, (unsigned long long)o->misa, isa);

	checks++;
	if (o->hartid != (expect_trap ? 1u : 0u)) {
		fails++;
		printk("FAIL probe ran on mhartid %u, expected %u -- k_thread_cpu_pin "
		       "did not take, so this proves nothing\n",
		       o->hartid, expect_trap ? 1u : 0u);
	}

	checks++;
	if (o->traps[NPROBE - 1] != (expect_trap ? NPROBE : 0u)) {
		fails++;
		printk("FAIL hart %u took %llu trap(s), expected %d\n", o->hartid,
		       (unsigned long long)o->traps[NPROBE - 1], expect_trap ? NPROBE : 0);
	}

	for (i = 0; i < NPROBE; i++) {
		uint64_t traps_here = o->traps[i] - (i ? o->traps[i - 1] : 0u);

		if (expect_trap) {
			checks += 4;
			if (traps_here != 1u) {
				fails++;
				printk("FAIL hart1 %s: %llu traps, expected exactly 1 -- "
				       "the instruction did NOT raise an exception, so "
				       "the extension is present on the LITTLE hart\n",
				       probe_names[i], (unsigned long long)traps_here);
			}
			if (o->cause[i] != CAUSE_ILLEGAL_INSTRUCTION) {
				fails++;
				printk("FAIL hart1 %s: mcause=%llu expected 2 "
				       "(illegal instruction)\n", probe_names[i],
				       (unsigned long long)o->cause[i]);
			}
			if (o->epc[i] != o->pc[i]) {
				fails++;
				printk("FAIL hart1 %s: mepc=0x%016llx expected 0x%016llx\n",
				       probe_names[i], (unsigned long long)o->epc[i],
				       (unsigned long long)o->pc[i]);
			}
			if (o->rd[i] != 0xa5a5a5a5a5a5a5a5ull) {
				fails++;
				printk("FAIL hart1 %s: rd was written (0x%016llx) -- a "
				       "trapped instruction must not commit\n",
				       probe_names[i], (unsigned long long)o->rd[i]);
			}
			printk("   hart1 %-5s trapped: mcause=%llu mepc=0x%016llx "
			       "mtval=0x%08llx rd=0x%016llx (unwritten)\n",
			       probe_names[i], (unsigned long long)o->cause[i],
			       (unsigned long long)o->epc[i],
			       (unsigned long long)o->tval[i],
			       (unsigned long long)o->rd[i]);
		} else {
			checks += 2;
			if (traps_here != 0u) {
				fails++;
				printk("FAIL hart0 %s: took a trap (mcause=%llu) -- these "
				       "instructions must be LEGAL here\n", probe_names[i],
				       (unsigned long long)o->cause[i]);
			}
			if ((int64_t)o->rd[i] != want[i]) {
				fails++;
				printk("FAIL hart0 %s: rd=0x%016llx expected 0x%016llx\n",
				       probe_names[i], (unsigned long long)o->rd[i],
				       (unsigned long long)want[i]);
			}
			printk("   hart0 %-5s executed: rd=0x%016llx (%lld), no trap\n",
			       probe_names[i], (unsigned long long)o->rd[i],
			       (long long)(int64_t)o->rd[i]);
		}
	}
}

/* ------------------------------------------------------------------ *
 * Workers
 * ------------------------------------------------------------------ */
static struct probe_out big_probe, little_probe;
static uint32_t big_checks, big_fails;
static uint64_t clk_mcycles, clk_mticks;

static uint64_t rdcycle(void)
{
	return (uint64_t)csr_read(mcycle);
}

static void big_worker(void *a, void *b, void *c)
{
	uint32_t t0, t1;
	uint64_t c0, c1;

	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

	printk("\n-- 1. MBP on hart 0 (BIG): the four ops against sw/pext.h\n");
	t_dot8();
	t_max8();
	t_qmul();
	t_clip8();
	t_requant();
	big_checks = checks;
	big_fails = fails;
	printk("   %u checks, %u failures\n", big_checks, big_fails);

	printk("\n-- 2. the same four ENCODINGS on hart 0, under a private trap handler\n");
	run_probe(&big_probe);
	report_probe(&big_probe, false);

	/* The core clock, measured against mtime. mtime is the CLINT's counter, driven by
	 * the same PL clock divided by CONFIG_RTC_CLOCK_DIVIDER_VALUE (1000) in hardware.
	 * mcycle is the core's own cycle counter and, thanks to patches/0004, it does NOT
	 * stop in wfi -- but this loop never sleeps anyway. The ratio is the hardware
	 * divider and is a pure integer; the derived MHz depends on
	 * CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC being right, which is the point. */
	printk("\nCLOCK_PROBE_START %u ms by the guest's own reckoning\n", CLOCK_PROBE_MS);
	t0 = k_cycle_get_32();
	c0 = rdcycle();
	k_busy_wait(CLOCK_PROBE_MS * 1000U);
	c1 = rdcycle();
	t1 = k_cycle_get_32();
	clk_mcycles = c1 - c0;
	clk_mticks = (uint32_t)(t1 - t0);
	/* The host times the gap between these two lines against its own clock. That is the
	 * only measurement here that does NOT assume CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC is
	 * right -- everything derived from mtime alone is circular, because k_busy_wait
	 * counts the same ticks the constant defines. If the real PL clock were still
	 * 40 MHz, this "3000 ms" would take 2586 ms of wall time. */
	printk("CLOCK_PROBE_END\n");

	k_sem_give(&done_sem);
}

static void little_worker(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

	run_probe(&little_probe);
	k_sem_give(&done_sem);
}

/* ------------------------------------------------------------------ */

int main(void)
{
	k_tid_t tid;
	int rc;
	unsigned int n = (unsigned int)arch_num_cpus();
	uint64_t derived_hz;

	k_sem_init(&done_sem, 0, 1);

	printk("\n=== pext_hart_proof on %s ===\n", CONFIG_BOARD_TARGET);
	printk("arch_num_cpus        = %u\n", n);
	printk("main() cpu id        = %u   mhartid = %lu\n",
	       (unsigned int)arch_curr_cpu()->id, mb_pext_mhartid());
	printk("sys_clock_hw_cycles  = %d Hz (mtime)\n",
	       CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC);
	printk("MB_PEXT_HW           = %d\n", MB_PEXT_HW);

	if (n < 2) {
		printk("FAIL arch_num_cpus = %u -- the negative test needs hart 1\n", n);
		fails++;
	}

	/* Create suspended, pin, then start: k_thread_cpu_pin() needs a thread that has
	 * not begun running. Run the two probes ONE AT A TIME, so `rec` and the check
	 * counters need no locking and the console stays ordered. */
	tid = k_thread_create(&big_thread, big_stack, STACK_SIZE, big_worker,
			      NULL, NULL, NULL, K_PRIO_COOP(5), 0, K_FOREVER);
	rc = k_thread_cpu_pin(tid, 0);
	if (rc != 0) {
		printk("FAIL k_thread_cpu_pin(big -> CPU 0) = %d\n", rc);
		fails++;
	}
	k_thread_start(tid);
	if (k_sem_take(&done_sem, K_SECONDS(JOIN_TIMEOUT_S)) != 0) {
		printk("FAIL the hart-0 worker never finished\n");
		fails++;
	}

	printk("\n-- 3. THE NEGATIVE TEST: the same four encodings on hart 1 (LITTLE)\n");
	printk("      hart 1 has no MBP decode table and no datapath, so each must raise\n"
	       "      an illegal-instruction exception and must not write rd.\n");
	if (n >= 2) {
		tid = k_thread_create(&little_thread, little_stack, STACK_SIZE,
				      little_worker, NULL, NULL, NULL,
				      K_PRIO_COOP(5), 0, K_FOREVER);
		rc = k_thread_cpu_pin(tid, 1);
		if (rc != 0) {
			printk("FAIL k_thread_cpu_pin(little -> CPU 1) = %d\n", rc);
			fails++;
		}
		k_thread_start(tid);
		if (k_sem_take(&done_sem, K_SECONDS(JOIN_TIMEOUT_S)) != 0) {
			printk("FAIL the hart-1 worker never finished -- is hart 1 online?\n");
			fails++;
		}
	}
	if (little_probe.ran) {
		report_probe(&little_probe, true);
	}

	printk("\n-- 4. both harts report their ISA, from the misa CSR\n");
	{
		char isa0[40], isa1[40];

		decode_misa(big_probe.misa, isa0, sizeof(isa0));
		decode_misa(little_probe.misa, isa1, sizeof(isa1));
		printk("   hart 0 (BIG)    misa = 0x%016llx  \"%s\"\n",
		       (unsigned long long)big_probe.misa, isa0);
		printk("   hart 1 (LITTLE) misa = 0x%016llx  \"%s\"\n",
		       (unsigned long long)little_probe.misa, isa1);

		/* The ISA letters must match: one image, one ABI, one compiler target
		 * covers both harts. That is the whole reason this SoC is Rocket+Rocket
		 * and not Rocket + a different core family. */
		checks++;
		if (MISA_ISA(big_probe.misa) != MISA_ISA(little_probe.misa)) {
			fails++;
			printk("FAIL the two harts implement different INSTRUCTION SETS "
			       "(0x%016llx vs 0x%016llx with S/U masked off) -- one Zephyr "
			       "image cannot cover both\n",
			       (unsigned long long)MISA_ISA(big_probe.misa),
			       (unsigned long long)MISA_ISA(little_probe.misa));
		} else {
			printk("   ISA letters identical (0x%016llx with the S and U "
			       "privilege bits masked off).\n",
			       (unsigned long long)MISA_ISA(big_probe.misa));
		}
		printk("   MBP has no misa bit -- it is in the custom-0 opcode space, "
		       "which has no extension letter.\n"
		       "   THAT is why section 3 has to EXECUTE an instruction instead of "
		       "reading a register.\n");

		/* The privilege modes must NOT match, and that is a second, independent
		 * demonstration that the two workers really landed on different cores:
		 * WithNSmallCores sets useVM = false, so hart 1 has neither S nor U. If
		 * the pinning had silently put both probes on hart 0, these would agree. */
		checks++;
		if ((big_probe.misa & MISA_PRIV_MASK) == MISA_PRIV_MASK &&
		    (little_probe.misa & MISA_PRIV_MASK) == 0u) {
			printk("   privilege modes DIFFER, as big.LITTLE requires: hart 0 "
			       "has S and U, hart 1 has neither\n"
			       "   (WithNSmallCores sets useVM = false). Two different "
			       "cores answered, which is itself evidence the pinning "
			       "took.\n");
		} else {
			fails++;
			printk("FAIL expected hart 0 to have misa.S|misa.U and hart 1 to "
			       "have neither; got 0x%llx and 0x%llx\n",
			       (unsigned long long)(big_probe.misa & MISA_PRIV_MASK),
			       (unsigned long long)(little_probe.misa & MISA_PRIV_MASK));
		}
	}

	printk("\n-- 5. the core clock, measured\n");
	derived_hz = clk_mticks ? (clk_mcycles * (uint64_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC)
				  / clk_mticks : 0;
	{
		/* Three decimals by integer arithmetic. Printed as a bare quotient this
		 * reads "999" for a ratio of 999.9998, which looks like a hardware
		 * divider of 999 and is not one -- the shortfall is the handful of
		 * cycles between reading mtime and reading mcycle. */
		uint64_t milli = clk_mticks ? (clk_mcycles * 1000ull) / clk_mticks : 0;

		printk("   %llu mcycles in %llu mtime ticks -> %llu.%03llu cycles/tick "
		       "(hardware divider, expect 1000)\n",
		       (unsigned long long)clk_mcycles, (unsigned long long)clk_mticks,
		       (unsigned long long)(milli / 1000u),
		       (unsigned long long)(milli % 1000u));
	}
	printk("   core clock = %llu Hz = %llu.%03llu MHz\n",
	       (unsigned long long)derived_hz,
	       (unsigned long long)(derived_hz / 1000000u),
	       (unsigned long long)((derived_hz / 1000u) % 1000u));
	printk("   CLOCK_MCYCLES=%llu CLOCK_MTICKS=%llu\n",
	       (unsigned long long)clk_mcycles, (unsigned long long)clk_mticks);

	printk("\nCHECKS pext_ops=%d hart0_legal=%d hart1_traps=%d isa_match=%d "
	       "priv_split=%d\n",
	       big_fails == 0 ? 1 : 0,
	       (big_probe.ran && big_probe.traps[NPROBE - 1] == 0) ? 1 : 0,
	       (little_probe.ran && little_probe.traps[NPROBE - 1] == NPROBE) ? 1 : 0,
	       (big_probe.ran && little_probe.ran &&
		MISA_ISA(big_probe.misa) == MISA_ISA(little_probe.misa)) ? 1 : 0,
	       (big_probe.ran && little_probe.ran &&
		(big_probe.misa & MISA_PRIV_MASK) == MISA_PRIV_MASK &&
		(little_probe.misa & MISA_PRIV_MASK) == 0u) ? 1 : 0);
	printk("TOTAL %u checks, %u failures\n", checks, fails);
	printk(fails == 0 ? "PEXT_HART_PROOF: PASS\n" : "PEXT_HART_PROOF: FAIL\n");
	return 0;
}
