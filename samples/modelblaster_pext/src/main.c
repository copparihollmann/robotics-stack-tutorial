/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * The MBP-accelerated network on the hart that has MBP, and the proof that the other
 * hart does not.
 *
 * TWO HALVES, AND THE SECOND ONE IS THE POINT.  PEXT_SPEC.md section 7.6 asks for both,
 * for the reason it states: a build in which the custom-0 decode was accidentally mapped
 * over BOTH tiles -- the natural mistake, since WithTacitEncoder already maps over every
 * tile -- passes every positive test and silently destroys the heterogeneity the SoC
 * exists to demonstrate.  So:
 *
 *   1. POSITIVE.  A worker pinned to CPU 0 runs the ModelBlaster-generated network with
 *      the curated MBP kernels, times it with rdcycle, and compares the output against
 *      the baked int8 golden.  max_abs_err must be 0: a latency number from a run that
 *      computed the wrong answer would mean nothing.
 *
 *   2. NEGATIVE.  A worker pinned to CPU 1 executes ONE MBP.DOT8 and must take an
 *      illegal-instruction trap.  An application k_sys_fatal_error_handler catches it,
 *      records mcause and mtval, releases the semaphore main() is waiting on, and aborts
 *      the offending thread instead of halting the system -- which is what the __weak
 *      default would do.  If that instruction RETIRES on CPU 1, this reports FAIL.
 *
 * The negative test executes a single instruction rather than a whole kernel on purpose:
 * it makes the report unambiguous about what trapped.  mtval carries the faulting
 * instruction word on Rocket, so the console shows the actual encoding, which decodes
 * against the table in PEXT_SPEC.md section 3.0.
 *
 * WHAT MAKES THIS SAFE TO PIN AT ALL.  k_thread_cpu_pin() requires a thread that has not
 * begun running, so every worker is created K_FOREVER, pinned, and only then started --
 * the same sequence samples/smp_hart_proof uses, and it needs CONFIG_SCHED_CPU_MASK=y.
 *
 * NOT A CONCURRENT MEASUREMENT.  One worker at a time, the other hart in wfi, for the
 * same reason samples/modelblaster_hart_latency gives: the two harts share an inclusive
 * L2 and one AXI path to DDR.  This app does not modify that one; it is a separate
 * sample because it is a separate experiment and because its image is built with
 * CONFIG_MB_PEXT=y, which that one must never be.
 *
 * Everything printed is integer.  No float appears anywhere in this image (prj.conf).
 */

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/sys/printk.h>
#include <zephyr/fatal.h>
#include <zephyr/arch/riscv/csr.h>

#include "pext.h"
#if defined(MBXR_RT_LUT) && MBXR_RT_LUT
/* T4's LUT-lane counters live in the kernel that owns them (sw/roccmoon/mbxr_lut_map.h, pulled
 * in by the generated kernels.c); declared rather than included so this file does not depend on
 * which kernels a given image selected. */
#include <stdint.h>
extern struct {
	uint32_t calls, calls_lane, calls_fallback, tiles_lane, elems_lane, elems_scalar,
		 tiles_copied;
	int32_t  last_rc;
	uint32_t last_uerr;
} mbxr_lut_stats;
#endif
#include "model.h"
#include "test_io.h"

/* The decoupled RoCC engine's runtime counters (fpga/pynq-z2/sw/roccmoon/mbxr_rt.h), when
 * the image links the engine kernels (ModelBlaster backend roccmoon, patches/0102).  WEAK:
 * an image without the engine has no such symbol, the address is NULL, nothing is printed,
 * and the image is otherwise unchanged. */
#define MBXR_RT_TYPES_ONLY
#include "roccmoon/mbxr_rt.h"
#pragma weak mbxr_rt_stats

/* softmax_s8 pext_int_memo2's counters (kernels/pext_nl/pext_nl_softmax_s8_pext_int_memo2.c),
 * WEAK in the same way: the per-row zero-cutoff histogram measured on the board. */
typedef struct {
	uint64_t rows, elements, zero_by_cutoff, exact_evals;
	uint64_t d0_hist[257];
} mb_smx2_stats_t;
extern mb_smx2_stats_t mb_smx2_stats __attribute__((weak));

/* B100: the attention lane's per-dispatch tax, split where it actually lives
 * (kernels/roccmoon/roccmoon_attention_s8_roccmoon_lane.c, -DMBP_B100_TAX=1).  WEAK for the
 * same reason as the two above: an image built without the flag has no such symbol, the
 * address is NULL, nothing is printed, and the image is otherwise unchanged. */
typedef struct {
	uint64_t heads, dispatches;
	uint64_t t_table, t_stage, t_issue, t_round, t_lane, t_copy;
} mbxa_tax_t;
extern mbxa_tax_t mbxa_tax __attribute__((weak));

#ifndef MB_ITERS
#define MB_ITERS 11
#endif
/* MB_WARMUP=0 skips the untimed warm-up inference (warm= then reports 0).  For a model that
 * takes many minutes per inference (a speech encoder with float kernels) the warm-up doubles
 * the board time and warms nothing a single multi-minute run does not. */
#ifndef MB_WARMUP
#define MB_WARMUP 1
#endif

#define WORKER_STACK     8192
/* A whole speech encoder is minutes, not seconds: warm run + MB_ITERS of Moonshine's encoder
 * with float elementwise kernels is ~6 min on this core.  -DMB_JOIN_TIMEOUT_S overrides. */
#ifndef MB_JOIN_TIMEOUT_S
#define MB_JOIN_TIMEOUT_S 200
#endif
#define JOIN_TIMEOUT_S   MB_JOIN_TIMEOUT_S
#define BIG_CPU          0
#define LITTLE_CPU       1

#define CORE_HZ     ((uint64_t)CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * \
		     CONFIG_RTC_CLOCK_DIVIDER_VALUE)
#define CYC_PER_MS  ((uint32_t)(CORE_HZ / 1000U))

K_THREAD_STACK_DEFINE(big_stack, WORKER_STACK);
K_THREAD_STACK_DEFINE(neg_stack, WORKER_STACK);
static struct k_thread big_thread;
static struct k_thread neg_thread;
static struct k_sem done_sem;

static model_output_t model_output[MODEL_OUTPUT_SIZE];

/* ------------------------------------------------------------------ *
 * MB_DEC_AR: THE AUTOREGRESSIVE DECODER, ON THE BOARD.
 *
 * Everything below is compiled ONLY when -DMB_DEC_AR=1 is passed.  An image that does not
 * ask for it preprocesses to exactly what it was before this block existed -- the sample's
 * default behaviour (walk the whole baked dispatch table MB_ITERS times and diff the output
 * against model_test_golden) is untouched.
 *
 * WHY IT IS HERE AND NOT IN A SECOND SAMPLE.  out/decint8/gen_eng/dec_driver.c is the HOST
 * driver that closes Moonshine's decoder loop: argmax over the step's logits, EOS as the
 * bound on the dispatch table, and the embedding row of the chosen token quantised into the
 * next step's input slot.  It is 73 lines and it is the ONLY thing that has ever chosen a
 * token in this programme -- every transcript this repo has produced came from the host.
 * The graph is identical either way (`MODEL_<MID>_DISPATCH_FNS[]`, file-static buffers that
 * outlive a dispatch), so porting the driver is 60 lines here rather than a second copy of
 * a 500-line harness.
 *
 * WHAT THE BOARD DECIDES, AND WHAT IS STILL FED TO IT.  The board does the argmax, the EOS
 * test and the embedding lookup.  The FLOAT CROSS-ATTENTION PROLOGUE and the encoder run on
 * the host and arrive inside `mb_ar_in` -- named here because it is one of the standing
 * caveats and must not be folded into a total.
 *
 * EARLY EXIT IS A BREAK OUT OF THE UNROLLED DISPATCH SEQUENCE, not a loop over one step's
 * dispatches: the graph is unrolled to N_STEPS steps, each with its own growing K/V shapes,
 * and STEP_END[k] (driver_meta.h, emitted from the IR that was actually built) is the LAST
 * dispatch of step k.  `d` therefore never restarts.
 *
 * FLOAT ON A SOFT-FLOAT TARGET.  The SoC is WithoutFPU, so `row[j] / s` becomes a libgcc
 * __divsf3 call.  That is correct, not merely tolerable: libgcc's soft float is IEEE-754
 * round-to-nearest-even, which is what the host's SSE single-precision divide does, so the
 * quantised embedding row is bit-identical to dec_driver.c's.  It costs DHID divides per
 * step -- nothing against ~175 dispatches.
 * ------------------------------------------------------------------ */
#if defined(MB_DEC_AR) && MB_DEC_AR
#include <string.h>
#include "driver_meta.h"      /* N_STEPS, VOCAB, DHID, EOS_ID, STEP_END, H_OFF, H_SCALE */

#ifndef MB_AR_UTTS
#define MB_AR_UTTS 1
#endif
/* MB_AR_BATCH (B): how many INDEPENDENT utterances one pass of the graph decodes.
 *
 * The batch dimension lives in the IR (fpga/pynq-z2/modelblaster/ir_batch.py), not here:
 * that pass multiplies the graph's tensors, so MODEL_INPUT_SIZE and MODEL_OUTPUT_SIZE are
 * ALREADY B times what they were and the two static buffers below need no change at all.
 * This driver learns about B through exactly two index expressions -- step k's logits for
 * row b at (k*B + b)*VOCAB, and step k's input row b at H_OFF[k] + b*DHID -- plus a per-row
 * done mask.  At B = 1 every line below is byte-for-byte the code that shipped.
 *
 * WHY EACH ROW IS AN INDEPENDENT UTTERANCE AND NOT A BEAM.  No op in this graph reduces
 * across rows: layernorm and softmax reduce along K, the elementwise kernels are per byte,
 * permute4 keeps p0 = 0, and matmul_b strides its own leading axis.  Every quant scale is a
 * per-step constant already shared by all 765 utterances.  So a batched sequence decodes to
 * exactly the tokens it decodes alone -- which is the gate, checked per sequence. */
#ifndef MB_AR_BATCH
#define MB_AR_BATCH 1
#endif
/* Which utterance dumps per-dispatch rows (TODO item 22).  ONE of them, not all: the rows
 * are ~2,100 lines per utterance at ~12 steps and the console is 115200 baud, so all of
 * them would be ~40 minutes of UART for a measurement that is the same shape each time.
 * -1 disables the dump entirely. */
#ifndef MB_AR_ROWS_UTT
#define MB_AR_ROWS_UTT 0
#endif

/* MB_ENC_DISPATCHES (Lab B129): ONE ENCODER IN THE GRAPH, B UTTERANCES TO PUT THROUGH IT.
 *
 * `ir_regbatch.py --mode once` batches the DECODER region and leaves the encoder at one row,
 * because `roccmoon_conv2d_s8_roccmoon_engine.c:52` gates the accelerator on `N == 1` and a
 * batched conv would leave the engine entirely (B106 measured that failure mode: the pick
 * still reads `roccmoon_engine` while 0.00 % of dispatches reach it).  The pass therefore
 * widens the crossing tensor `enc` to [B, 165, 288] and emits a graph in which dispatches
 * [0, MB_ENC_DISPATCHES) are the encoder -- ONE encoder -- and everything after them expects
 * all B rows of `enc` to be filled.
 *
 * THE AR LOOP CANNOT DO THAT BY ITSELF.  It walks `for (; d <= STEP_END[k]; d++)` from d = 0
 * exactly once per group, and the encoder's dispatches sit inside STEP_END[0].  So this
 * driver runs them B times before the step loop, each pass reading its own window through
 * `st.input` and leaving its answer in `enc`'s slot 0, which is then copied to slot b.
 *
 * b DESCENDS so slot 0 is written LAST and in place: the encoder always writes slot 0, so
 * ascending b would overwrite slot 1 with slot 0's copy of itself.  At b = 0 the copy is
 * elided because source and destination are the same bytes.
 *
 * ZERO (the default) COMPILES THIS BLOCK OUT ENTIRELY, so an image that does not ask for it
 * preprocesses to exactly the driver that shipped -- there is no `if (B > 1)` at run time.
 *
 *   MB_ENC_DISPATCHES  how many leading dispatches are the encoder (ir_regbatch's
 *                      `encoder_dispatches`, 117 on this graph)
 *   MB_ENC_BUF         the codegen's buffer for the crossing tensor.  generate_skeleton
 *                      emits every buffer in buffers.c GLOBAL and non-static, so it can be
 *                      declared here; on this graph it is `buf_moonshine_e2e_enc`.
 *   MB_ENC_BYTES       the wire: 165 x 288 int8 = 47,520 B, ONE utterance's worth
 *   MB_ENC_IN_BYTES    the audio field's per-utterance stride, 64,000 B.  It is the FIRST
 *                      packed field, so window b starts at ar_input + b * this.
 */
#ifndef MB_ENC_DISPATCHES
#define MB_ENC_DISPATCHES 0
#endif
/* Defined unconditionally so the banner below can print them without an #ifdef; they mean
 * nothing when MB_ENC_DISPATCHES is 0 and the banner prints 0 for them in that case. */
#ifndef MB_ENC_BYTES
#define MB_ENC_BYTES 47520
#endif
#ifndef MB_ENC_IN_BYTES
#define MB_ENC_IN_BYTES 64000
#endif
#if MB_ENC_DISPATCHES > 0
#ifndef MB_ENC_BUF
#error "MB_ENC_DISPATCHES needs -DMB_ENC_BUF=<the crossing tensor's buffer symbol>"
#endif
/* buffers.c, generated: `int8_t buf_<mid>_enc[B * MB_ENC_BYTES] __attribute__((aligned(64)))`.
 * Declared without a bound so this file need not know B. */
extern int8_t MB_ENC_BUF[];
#endif

/* The baked inputs and the embedding table (samples/modelblaster_pext/ar_io.S, generated by
 * scripts/74).  `mb_ar_emb` is VOCAB x DHID float32 in target byte order; it is read through
 * a float pointer, so the .S aligns it to 16. */
extern const int8_t mb_ar_in[];
extern const unsigned char mb_ar_emb[];

/* The input is WRITTEN every step (the next token's embedding lands at H_OFF[k+1]), so it
 * cannot be the const .rodata copy.  One buffer, refilled per utterance. */
static model_input_t ar_input[MODEL_INPUT_SIZE];

static struct {
	int           n;                 /* tokens_emitted */
	int           steps;             /* steps_taken -- equal to n, kept separately so a
					  * future non-one-token-per-step driver cannot silently
					  * conflate them */
	int           hit_eos;           /* the loop ended on the board's own EOS test */
	int32_t       tok[N_STEPS];
	int32_t       val[N_STEPS];      /* the winning int8 logit code: the argmax's VALUE,
					  * which differs if the arithmetic diverged even when
					  * the chosen index does not */
	unsigned long step_cyc[N_STEPS];
	unsigned long cyc;
	unsigned long dispatches;
	unsigned long enc_passes;        /* MB_ENC_DISPATCHES > 0: how many times the group
					  * ran the encoder region.  0 when the encoder is in
					  * the dispatch walk (or absent), so a console can
					  * never be read as if it had batched an encoder it
					  * did not. */
} ar[MB_AR_UTTS];

/* How many of the baked utterances to actually decode.  Defaults to all of them; a smaller
 * number runs the same IMAGE -- same symbol addresses, same layout -- over fewer utterances,
 * which is what makes a memory self-test comparable with a decode run. */
#ifndef MB_AR_LIMIT
#define MB_AR_LIMIT MB_AR_UTTS
#endif

/* MB_AR_SELFTEST: WHAT THE GUEST ACTUALLY READS.
 *
 * Lab B57's 255-utterance image decodes wrong answers that its 8-utterance image gets right,
 * with the SAME inputs and a byte-identical embedding table in the file -- so the question is
 * whether the guest's view of its own .rodata matches the file the linker produced.  Nothing
 * else can distinguish "my driver is wrong" from "these bytes do not read back".  FNV-1a per
 * 16 MB block rather than one hash over the whole thing, so a mismatch LOCALISES to an address
 * range instead of only being detected. */
#ifndef MB_AR_SELFTEST
#define MB_AR_SELFTEST 0
#endif

/* Per-dispatch rows for MB_AR_ROWS_UTT, with the step index TODO item 22 asks for. */
#if MB_AR_ROWS_UTT >= 0
static int16_t ar_row_step[MODEL_OP_COUNT];
#endif
#endif  /* MB_DEC_AR */


static struct {
	bool          ran;
	uint32_t      cpu_id;
	uint32_t      hartid;
	unsigned long warm_cycles;
	unsigned long cyc[MB_ITERS];
	unsigned long median, min, max;
	unsigned long mtime_ticks;
	int           max_abs_err;
	mbxr_rt_stats_t eng_warm;      /* engine counters after the warm-up run */
	mbxr_rt_stats_t eng_total;     /* ... and after the MB_ITERS timed runs too */
	int8_t        out[MODEL_TEST_OUTPUT_LEN];
	int           n_ops;
	int           op_id[MODEL_OP_COUNT];
	const char   *op_name[MODEL_OP_COUNT];
	const char   *op_kind[MODEL_OP_COUNT];
	const char   *op_shape[MODEL_OP_COUNT];
	unsigned long op_cycles[MODEL_OP_COUNT];
} big;

/* Written by the fatal handler, read by main() after the negative worker is gone. */
static volatile struct {
	bool          trapped;     /* the handler ran */
	bool          retired;     /* the instruction did NOT trap -- the failure case */
	unsigned int  reason;      /* Zephyr's K_ERR_* */
	unsigned long cpu_id;
	unsigned long hartid;
	unsigned long mcause;
	unsigned long mtval;       /* the faulting instruction word, on Rocket */
	int64_t       result;      /* what DOT8 returned, if it returned */
} neg;

static inline unsigned long rdcycle(void)
{
	unsigned long c;

	__asm__ volatile("rdcycle %0" : "=r"(c));
	return c;
}

__attribute__((unused)) static void sort_ul(unsigned long *a, int n)
{
	for (int i = 1; i < n; i++) {
		unsigned long v = a[i];
		int j = i - 1;

		while (j >= 0 && a[j] > v) {
			a[j + 1] = a[j];
			j--;
		}
		a[j + 1] = v;
	}
}

/* ------------------------------------------------------------------ *
 * B123 E-SPLIT: A WORKING-SET SWEEP BETWEEN INFERENCES.
 *
 * WHY.  B117 measured the merged encoder+prologue+decoder image EXACT on its first
 * inference and WRONG on its second, at dispatch 17 (the first attention_s8); C1 then
 * measured the STANDALONE encoder bit-exact on both.  Two differences between those two
 * images survive: E1, what runs between the two executions of dispatch 17 (117
 * dispatches over 8.3 MB against 4,389 over a 33 MB engine arena), and E2, the address
 * map (__kernel_ram_end 0x8100_5798 against 0x82c8_4308).  THIS BLOCK VARIES E1 WITH E2
 * HELD FIXED: it touches N bytes of DRAM between two inferences of the SAME image, so
 * every generated buffer, every stack and __kernel_ram_end itself sit at exactly the
 * same address in every pass, and the only thing that differs between pass k and pass
 * k+1 is how much memory was touched in between.
 *
 * WHERE IT TOUCHES, AND WHERE IT MUST NOT.  Two FIXED physical windows, neither of them
 * guest RAM and neither of them the engine's weight-image arena:
 *
 *   FREE   0x8200_0000 .. 0x8800_0000   96 MB of DRAM above this image's own
 *                                       __kernel_ram_end and below MBXR_RT_IMG_BASE.
 *                                       Nothing in the system reads it.
 *   STAGE  0x8C00_0000 .. 0x8E00_0000   32 MB: the engine's MBXR_RT_IN_STAGE,
 *                                       _SCRATCH, _OUT_STAGE and _ROW_STAGE, every one
 *                                       of which is rewritten per dispatch (_ROW_STAGE
 *                                       only while a weight image is built, i.e. pass 0).
 *
 * 0x8800_0000 .. 0x8C00_0000 -- MBXR_RT_IMG_BASE..MBXR_RT_IMG_END, the weight image
 * built once in pass 0 and REUSED by every later pass -- is NEVER touched.  Scribbling
 * it would produce a divergence that says nothing about this defect.
 *
 * GAP 0 IS DELIBERATELY EMPTY, and that is not an oversight: it is the WITHIN-IMAGE NULL
 * CONTROL.  Pass 1 follows pass 0 with no sweep at all, so "this image reproduces C1's
 * bit-exact second pass" is MEASURED HERE rather than inherited from a build whose .bss
 * layout differs by the few hundred bytes this block itself adds.
 *
 * It runs OUTSIDE irq_lock and OUTSIDE the rdcycle bracket, so big.cyc[] is the same
 * quantity an uninstrumented arm reports; and it prints its own cycle count and a
 * read-back sum, so a sweep that was optimised away, or that faulted, or that never ran,
 * cannot be mistaken for a null result.
 *
 * Undefined -- which is every build that does not ask for it -- and this whole block is
 * a no-op and the image is byte for byte what it was.
 * ------------------------------------------------------------------ */
#ifndef MB_ESPLIT
#define MB_ESPLIT 0
#endif
#if MB_ESPLIT
#define MB_ESPLIT_FREE   0x82000000UL
#define MB_ESPLIT_STAGE  0x8C000000UL
#define MB_ESPLIT_MB(x)  ((unsigned long)(x) << 20)

struct mb_esplit_gap { unsigned long base, bytes; const char *what; };

static const struct mb_esplit_gap mb_esplit_gaps[] = {
#if MB_ESPLIT == 1        /* arm S -- B117's pre-registered design, plus the null control */
	{ 0,              0,                "none"    },
	{ MB_ESPLIT_FREE, MB_ESPLIT_MB(8),  "free8"   },
	{ MB_ESPLIT_FREE, MB_ESPLIT_MB(96), "free96"  },
#elif MB_ESPLIT == 2      /* arm T -- the engine's own staging windows (this lab's addition) */
	{ 0,               0,                "none"     },
	{ MB_ESPLIT_STAGE, MB_ESPLIT_MB(32), "stage32"  },
	{ MB_ESPLIT_STAGE, MB_ESPLIT_MB(32), "stage32b" },
#elif MB_ESPLIT == 3      /* arm M -- the MERGED image, whose guest reaches 0x82c8_4308 */
	/* THE FREE WINDOW MOVES UP, and it has to: the merged image's __kernel_ram_end is
	 * 0x82c8_4308, ABOVE arm S's 0x8200_0000 base, so arm S's window would scribble the
	 * model's own buffers.  0x8300_0000 .. 0x8800_0000 is 80 MB, still more than the whole
	 * 79.7 MB the merged image occupies (46.7 MB of guest + a 33.0 MB engine arena). */
	{ 0,               0,                "none"     },
	{ 0x83000000UL,    MB_ESPLIT_MB(8),  "free8"    },
	{ 0x83000000UL,    MB_ESPLIT_MB(80), "free80"   },
#else
#error "MB_ESPLIT must be 1 (free DRAM), 2 (the engine's staging windows) or 3 (merged)"
#endif
};

/* THE REFUSAL, not an assertion.  A sweep window that has slipped below the guest's own RAM
 * end does not produce a wrong answer to be puzzled over later: it silently overwrites the
 * model's buffers and every fold after it is garbage.  b123_esplit.sh gates this at BUILD
 * time off the ELF; this is the same check at run time, from the only side that can name
 * __kernel_ram_end without being told, and it prints and skips rather than corrupting. */
extern char __kernel_ram_end[];

static unsigned long mb_esplit_sweep(const struct mb_esplit_gap *g, unsigned long tag)
{
	volatile unsigned long *p = (volatile unsigned long *)g->base;
	unsigned long n = g->bytes / sizeof(unsigned long);
	unsigned long i, s = 0;

	/* One store per 64-byte line and then one load per line: the store ALLOCATES and
	 * DIRTIES the line, the load proves it landed.  A read-only sweep would evict but
	 * leave nothing dirty behind it, which is half the disturbance a real dispatch is. */
	for (i = 0; i < n; i += 8) {
		p[i] = tag + i;
	}
	for (i = 0; i < n; i += 8) {
		s += p[i];
	}
	return s;
}
#endif

/* B124 -- HOW MANY ENGINE DISPATCHES SIT BETWEEN TWO ATTENTION EXECUTIONS.
 *
 * The same shape as MB_ESPLIT above and for a question MB_ESPLIT cannot ask.  MB_ESPLIT moves
 * MEMORY between two inferences; every arm that did so came back null, and B123's mirror arm
 * showed why -- the merged image's wrong answer survives an 80 MB flush and repeats
 * bit-identically, so the state that carries it is not addressable from hart 0 at all.
 *
 * The ONE dimension left in which the merged image differs from the standalone is the work the
 * ACCELERATOR does between two executions of the encoder's first attention dispatch: 1,395
 * engine dispatches and no attention ones in the merged image, 39 in the standalone -- and the
 * engine and the attention lane are ONE RoCC unit.  So this gap issues N real engine
 * dispatches on the standalone image, which is proven bit-exact across two inferences, and
 * asks whether N is what breaks it.
 *
 * WHY THE GAP IS THE RIGHT PLACE TO PUT THEM.  A pass ends after its last attention dispatch
 * and the next pass runs sixteen-odd engine dispatches before its first one, so a burst here
 * lands with NO attention dispatch between it and the attention execution under test -- which
 * is exactly the merged image's condition, and exactly why B117's divergence resolves to the
 * FIRST attention dispatch of the pass rather than to any later one.
 */
#ifndef MB_B124
#define MB_B124 0
#endif
#if MB_B124
#if MB_ESPLIT
#error "MB_B124 and MB_ESPLIT both fill the between-pass gap: pick one"
#endif
/* Declared, not included: main.c builds with MBXR_RT_TYPES_ONLY and must not carry a second
 * copy of the runtime.  The definition lives in mbxr_rt.h under MBP_B124, which the KERNEL
 * cflags turn on -- so a harness asking for a burst that the kernels were not built to provide
 * fails at the link rather than silently doing nothing. */
void mbxr_rt_b124_burst(int n, unsigned long *o);

static const int mb_b124_burst[] = {
#if MB_B124 == 1          /* arm A -- the sweep: the null, the log-midpoint, the merged count */
	0, 256, 1395
#elif MB_B124 == 2        /* arm P -- the positive control: the merged image, no burst at all */
	0, 0, 0
#elif MB_B124 == 3        /* arm C -- DOES THE CORRUPTION PERSIST, and where is the threshold */
	/* Arm A put the big burst last, so it could not ask whether the damage survives a pass
	 * that does not carry one.  This puts it FIRST: gap 0 breaks pass 1, gap 1 adds nothing
	 * at all, and if pass 2 comes back exact then the machine repairs itself and a pass is
	 * wrong if and ONLY if a long run of engine dispatches immediately precedes its first
	 * attention dispatch -- which is a defect a dispatch-ordering change can work around.
	 * Gap 2's 640 is a threshold probe between arm A's exact 256 and its broken 1,395, and
	 * it is READABLE ONLY IF gap 1 came back exact. */
	1395, 0, 640
#elif MB_B124 == 4        /* B126 arm R -- the merged image's own run length in EVERY gap, so
			   * every pass but the first is put in the condition B124 measured
			   * wrong and the only thing that varies between them is which repair
			   * MB_B126 has switched on. */
	1395, 1395, 1395
#else
#error "MB_B124 must be 1 (the standalone sweep), 2 (the merged control), 3 (persistence) or 4 (B126)"
#endif
};
#endif

/* ---- B126: WHICH REPAIR, AND A CONTROL THAT PROVES THE INSTRUMENT SEES THE DEFECT ---------
 *
 * The runtime carries the repair (mbxr_rt.h, MBP_B126); this selects WHICH ONE IS ACTIVE, per
 * pass, so a control and two candidate repairs fit in ONE image and ONE board round.  The mode
 * is set BEFORE each pass and reported after it.
 *
 *   arm 1 (R)  THE STANDALONE TEST.  B117's C1 encoder, four passes, a 1,395-dispatch engine
 *              burst in every gap (MB_B124 arm 4).  Pass 0 is clean.  Pass 1 runs with the
 *              repair OFF -- ***THE POSITIVE CONTROL***, which must reproduce B124 arm C's own
 *              wrong fold 4c8e0c2b.  Pass 2 runs with MBXR_CAP re-asserted before every
 *              attention dispatch.  Pass 3 runs with the redo.
 *   arm 2 (M)  THE MERGED DELIVERABLE, redo.      arm 3: the merged image, CAP.
 *   arm 4      every pass with the repair OFF: the merged image as it is today.
 */
#ifndef MB_B126
#define MB_B126 0
#endif
#if MB_B126
/* Declared, not included, for MB_B124's reason: main.c builds with MBXR_RT_TYPES_ONLY and must
 * not carry a second copy of the runtime.  Both are defined in mbxr_rt.h under MBP_B126, which
 * the KERNEL cflags turn on -- so a harness asking for a mode the kernels were not built to
 * provide fails at the link rather than silently doing nothing. */
void mbxr_rt_b126_mode_set(int m);
void mbxr_rt_b126_report(unsigned long *o);

static const int mb_b126_mode[] = {
#if MB_B126 == 1          /* arm R: clean, THE CONTROL, CAP, redo */
	0, 0, 1, 2
#elif MB_B126 == 2        /* arm M: the redo, every pass */
	2, 2, 2, 2
#elif MB_B126 == 3        /* the CAP, every pass */
	1, 1, 1, 1
#elif MB_B126 == 4        /* the repair off, every pass: today's behaviour, stated explicitly */
	0, 0, 0, 0
#else
#error "MB_B126 must be 1 (the standalone test), 2 (redo), 3 (CAP) or 4 (off)"
#endif
};
#endif

/* ------------------------------------------------------------------ *
 * 1. The positive half: the network on the hart that has MBP.
 * ------------------------------------------------------------------ */
#if !(defined(MB_DEC_AR) && MB_DEC_AR)
static void big_worker(void *p1, void *p2, void *p3)
{
	unsigned long a, b;

	ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

	big.cpu_id = arch_curr_cpu()->id;
	big.hartid = csr_read(mhartid);
	big.ran = true;

	/* Belt and braces on top of the pin: names the cause if the scheduler ever
	 * put this thread somewhere else, instead of leaving an illegal-instruction
	 * halt with no context. */
	MB_PEXT_ASSERT_BIG_HART();

	if (MB_WARMUP) {
		unsigned int key = irq_lock();

		a = rdcycle();
		model_run_test(model_output, NULL);
		b = rdcycle();
		irq_unlock(key);
		big.warm_cycles = b - a;
		if (&mbxr_rt_stats != NULL) {
			big.eng_warm = mbxr_rt_stats;
		}
	}

	for (int i = 0; i < MB_ITERS; i++) {
#if MB_B126
		/* BEFORE the pass, outside the timed bracket: one store. */
		if (i < (int)(sizeof(mb_b126_mode) / sizeof(mb_b126_mode[0])))
			mbxr_rt_b126_mode_set(mb_b126_mode[i]);
#endif
		unsigned int key = irq_lock();

		a = rdcycle();
		model_run_test(model_output, NULL);
		b = rdcycle();
		irq_unlock(key);
		big.cyc[i] = b - a;
		big.mtime_ticks = model_wall_cycles();
#if MB_B126
		{
			unsigned long o[8];

			mbxr_rt_b126_report(o);
			printk("MB_B126 pass=%d mode=%lu fired=%lu maxrun=%lu run=%lu "
			       "attn=%lu caps=%lu n=%lu cap=%lu\n", i, o[0], o[1], o[2],
			       o[3], o[4], o[5], o[6], o[7]);
		}
#endif
#if MB_ESPLIT
		if (i + 1 < MB_ITERS &&
		    i < (int)(sizeof(mb_esplit_gaps) / sizeof(mb_esplit_gaps[0]))) {
			const struct mb_esplit_gap *g = &mb_esplit_gaps[i];
			unsigned long c0, c1, s;

			if (g->bytes && g->base < (unsigned long)(uintptr_t)__kernel_ram_end) {
				printk("MB_ESPLIT gap=%d REFUSED base=0x%lx is below "
				       "__kernel_ram_end=0x%lx\n", i, g->base,
				       (unsigned long)(uintptr_t)__kernel_ram_end);
				continue;
			}
			c0 = rdcycle();
			s = mb_esplit_sweep(g, 0x5A5A0000UL + (unsigned long)i);
			c1 = rdcycle();
			printk("MB_ESPLIT gap=%d what=%s base=0x%lx bytes=%lu cycles=%lu "
			       "sum=%lu\n", i, g->what, g->base, g->bytes, c1 - c0, s);
		}
#endif
#if MB_B124
		if (i + 1 < MB_ITERS &&
		    i < (int)(sizeof(mb_b124_burst) / sizeof(mb_b124_burst[0]))) {
			unsigned long o[12];
			unsigned int bkey = irq_lock();

			/* Under irq_lock, because that is how the model's own dispatches are
			 * issued and this burst is meant to be indistinguishable from them. */
			mbxr_rt_b124_burst(mb_b124_burst[i], o);
			irq_unlock(bkey);
			printk("MB_B124 gap=%d ask=%d done=%lu cycles=%lu calls_engine=%lu "
			       "image_bytes=%lu bytes_wgt=%lu pairs=%lu rc=%ld fold=%08lx "
			       "ncache=%lu kmax=%lu skip=%lu\n", i, mb_b124_burst[i], o[0],
			       o[1], o[2], o[3], o[4], o[10], (long)o[5], o[6], o[7], o[11],
			       o[9]);
		}
#endif
	}

	if (&mbxr_rt_stats != NULL) {
		big.eng_total = mbxr_rt_stats;
	}

	{
		int n = 0;
		const model_op_record_t *rec = model_profile_records(&n);

		if (n > MODEL_OP_COUNT) {
			n = MODEL_OP_COUNT;
		}
		big.n_ops = n;
		for (int i = 0; i < n; i++) {
			big.op_id[i]     = rec[i].dispatch_id;
			big.op_name[i]   = rec[i].name;
			big.op_kind[i]   = rec[i].op;
			big.op_shape[i]  = rec[i].shape;
			big.op_cycles[i] = rec[i].cycles;
		}
	}

	big.max_abs_err = 0;
	for (int i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
		int d = (int)model_output[i] - (int)model_test_golden[i];

		if (d < 0) {
			d = -d;
		}
		if (d > big.max_abs_err) {
			big.max_abs_err = d;
		}
		big.out[i] = (int8_t)model_output[i];
	}

	{
		unsigned long tmp[MB_ITERS];

		for (int i = 0; i < MB_ITERS; i++) {
			tmp[i] = big.cyc[i];
		}
		sort_ul(tmp, MB_ITERS);
		big.min = tmp[0];
		big.max = tmp[MB_ITERS - 1];
		big.median = tmp[MB_ITERS / 2];
	}

	k_sem_give(&done_sem);
}
#else   /* MB_DEC_AR: the autoregressive driver replaces the fixed-trajectory replay */

/* The board chooses its own tokens.  This is dec_driver.c's loop, unchanged in structure and
 * in arithmetic, running on hart 0 against the same generated graph. */
static void big_worker(void *p1, void *p2, void *p3)
{
	ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

	big.cpu_id = arch_curr_cpu()->id;
	big.hartid = csr_read(mhartid);
	big.ran = true;
	MB_PEXT_ASSERT_BIG_HART();

#if MB_AR_SELFTEST
	{
		static const struct {
			const char *name;
			const unsigned char *p;
			unsigned long n;
		} reg[2] = {
			/* MODEL_INPUT_SIZE is the GROUP size at B > 1, so the region is
			 * UTTS/B groups -- not UTTS of them, which would double-count. */
			{ "mb_ar_in",  (const unsigned char *)mb_ar_in,
			  (unsigned long)(MB_AR_UTTS / MB_AR_BATCH) * MODEL_INPUT_SIZE },
			{ "mb_ar_emb", mb_ar_emb, (unsigned long)VOCAB * DHID * 4u },
		};
		const unsigned long blk = 16uL << 20;

		for (int r = 0; r < 2; r++) {
			for (unsigned long off = 0; off < reg[r].n; off += blk) {
				unsigned long n = reg[r].n - off < blk ? reg[r].n - off : blk;
				unsigned long long h = 14695981039346656037ULL;
				const unsigned char *p = reg[r].p + off;

				for (unsigned long i = 0; i < n; i++) {
					h ^= (unsigned long long)p[i];
					h *= 1099511628211ULL;
				}
				printk("MB_AR_SUM region=%s off=%lu len=%lu fnv1a=%08x%08x\n",
				       reg[r].name, off, n,
				       (unsigned int)(h >> 32), (unsigned int)h);
			}
		}
	}
#endif

	BUILD_ASSERT(MB_AR_LIMIT % MB_AR_BATCH == 0,
		     "MB_AR_LIMIT must be a whole number of batches: a ragged last group would "
		     "decode rows that were never baked");
	for (int u = 0; u < MB_AR_LIMIT; u += MB_AR_BATCH) {
		unsigned int key = irq_lock();
		unsigned long u0, k0;
		int d = 0, k, b;
		int enc_passes = 0;
		int n[MB_AR_BATCH], done[MB_AR_BATCH];

		for (b = 0; b < MB_AR_BATCH; b++) {
			n[b] = 0;
			done[b] = 0;
		}
		/* ONE CONTIGUOUS COPY, because the baker writes the GROUPED layout: at B > 1
		 * each of the 36 packed fields holds the group's B sequences adjacent, so a
		 * group is one MODEL_INPUT_SIZE block and not B blocks to be interleaved here.
		 * Volume per utterance is unchanged -- 577,152 B, exactly as at B = 1. */
		memcpy(ar_input, mb_ar_in + (size_t)(u / MB_AR_BATCH) * MODEL_INPUT_SIZE,
		       MODEL_INPUT_SIZE);
		model_state_t st = { ar_input, model_output, NULL };

		model_reset_profile();
		u0 = rdcycle();
#if MB_ENC_DISPATCHES > 0
		/* THE B ENCODER PASSES.  `d` is left at MB_ENC_DISPATCHES, so the step loop
		 * below resumes at the first op that reads `enc` and the encoder is NOT run
		 * a (B+1)th time.  The wall clock started above, so every one of these passes
		 * is inside the group's measured cycles -- none of this is free and none of
		 * it is hidden.
		 *
		 * THE PROFILE IS RESET AGAIN BEFORE THE LAST PASS.  `records_` is exactly
		 * MODEL_OP_COUNT long and `n_` wraps modulo it; B passes of the encoder would
		 * overrun it by (B-1) * MB_ENC_DISPATCHES and overwrite the first rows with
		 * the last ones.  Resetting before b = 0 makes the dumped rows ONE encoder
		 * pass plus the batched decoder -- which is the per-group accounting unit --
		 * instead of a wrapped mixture that would look like data. */
		for (b = MB_AR_BATCH - 1; b >= 0; b--) {
			model_state_t es = { ar_input + (size_t)b * MB_ENC_IN_BYTES,
					     model_output, NULL };

			if (b == 0) {
				model_reset_profile();
			}
			for (d = 0; d < MB_ENC_DISPATCHES; d++) {
				model_dispatch_fns[d](&es);
			}
			if (b) {
				memcpy(MB_ENC_BUF + (size_t)b * MB_ENC_BYTES,
				       MB_ENC_BUF, MB_ENC_BYTES);
			}
		}
		enc_passes = MB_AR_BATCH;
#endif
		for (k = 0; k < N_STEPS; k++) {
			int alive = 0;

			k0 = rdcycle();
			/* EARLY EXIT IS THE LOOP BOUND: `d` is never reset, so the break
			 * below leaves the remaining steps' dispatches unexecuted.  At B > 1
			 * the walk is SHARED -- every row sits at the same step k, which is
			 * also why rope's position table is correct for all of them. */
			for (; d <= STEP_END[k]; d++) {
				model_dispatch_fns[d](&st);
			}
			for (b = 0; b < MB_AR_BATCH; b++) {
				const int8_t *lg;
				int best;
				int8_t bv;

				/* A ROW THAT HIT EOS IS NOT READ AGAIN.  Its slice of the
				 * output keeps being computed -- the group pays max(steps),
				 * which is the tax B99 step 2 measured -- but nothing it
				 * produces after EOS reaches a token. */
				if (done[b]) {
					continue;
				}
				/* argmax on the int8 codes: one output tensor, one scale, so
				 * the code order IS the value order.  Ties break to the lowest
				 * index, which is what dec_driver.c does. */
				lg = model_output +
				     ((size_t)k * MB_AR_BATCH + b) * VOCAB;
				best = 0;
				bv = lg[0];
				for (int i = 1; i < VOCAB; i++) {
					if (lg[i] > bv) {
						bv = lg[i];
						best = i;
					}
				}
				ar[u + b].tok[n[b]] = best;
				ar[u + b].val[n[b]] = bv;
				ar[u + b].step_cyc[n[b]] = rdcycle() - k0;
				n[b]++;
				if (best == EOS_ID) {
					ar[u + b].hit_eos = 1;
					done[b] = 1;
					continue;
				}
				alive++;
				if (k + 1 < N_STEPS) {
					const float s = H_SCALE[k + 1];
					int8_t *dst = ar_input + H_OFF[k + 1] +
						      (size_t)b * DHID;
					const float *row = (const float *)mb_ar_emb +
							   (size_t)best * DHID;

					for (int j = 0; j < DHID; j++) {
						float q = row[j] / s;
						int v = (int)(q < 0 ? q - 0.5f : q + 0.5f);

						dst[j] = (int8_t)(v > 127 ? 127 :
								  (v < -127 ? -127 : v));
					}
				}
			}
			if (alive == 0) {
				break;
			}
		}
		for (b = 0; b < MB_AR_BATCH; b++) {
			ar[u + b].cyc = rdcycle() - u0;
			ar[u + b].n = n[b];
			ar[u + b].steps = n[b];
			/* the dispatch walk is shared, so it is the GROUP's count.
			 * `d` counts ONE walk: the (B-1) extra encoder passes the
			 * once-mode driver ran are reported separately rather than
			 * folded in, so this stays the number a B = 1 image reports
			 * for the same trajectory and nothing is quietly inflated. */
			ar[u + b].dispatches = (unsigned long)d;
			ar[u + b].enc_passes = (unsigned long)enc_passes;
		}
		irq_unlock(key);

		/* THE ENGINE COUNTERS, WHICH THE FIRST RUN OF THIS IMAGE DID NOT CAPTURE.
		 * Without them `calls_fallback = 0` is 0 out of 0 counted, and a run that
		 * silently fell back to the reference kernels would report the same thing as
		 * one that did not -- the 438eb27 shape again, one field along.  In AR mode
		 * `warm` means AFTER THE FIRST UTTERANCE, which is the one that pays the
		 * one-time weight-image build, and `total` after all of them; the console
		 * labels are the replay path's and the run record says what they mean here. */
		if (&mbxr_rt_stats != NULL) {
			if (u == 0) {
				big.eng_warm = mbxr_rt_stats;
			}
			big.eng_total = mbxr_rt_stats;
		}

#if MB_AR_ROWS_UTT >= 0
		/* the rows belong to a GROUP now; dump the group that contains the asked-for
		 * utterance, which at B = 1 is `u == MB_AR_ROWS_UTT` exactly as before */
		if (u <= MB_AR_ROWS_UTT && MB_AR_ROWS_UTT < u + MB_AR_BATCH) {
			int nr = 0;
			const model_op_record_t *rec = model_profile_records(&nr);

			if (nr > MODEL_OP_COUNT) {
				nr = MODEL_OP_COUNT;
			}
			big.n_ops = nr;
			for (int i = 0, kk = 0; i < nr; i++) {
				big.op_id[i]     = rec[i].dispatch_id;
				big.op_name[i]   = rec[i].name;
				big.op_kind[i]   = rec[i].op;
				big.op_shape[i]  = rec[i].shape;
				big.op_cycles[i] = rec[i].cycles;
				/* the step this dispatch belongs to, from the same
				 * STEP_END the driver walked -- TODO item 22 */
				while (kk < N_STEPS - 1 &&
				       rec[i].dispatch_id > STEP_END[kk]) {
					kk++;
				}
				ar_row_step[i] = (int16_t)kk;
			}
		}
#endif
	}

	/* A replay image reports max_abs_err against a baked golden.  There is no such
	 * golden here -- the trajectory is data-dependent and is the RESULT -- so this
	 * image reports NOTHING of the kind rather than a 0 that compared nothing
	 * (438eb27).  Correctness is the token sequence, checked off-board against the
	 * host driver's, and the per-step argmax VALUE printed beside each token. */
	big.max_abs_err = -1;
	k_sem_give(&done_sem);
}
#endif  /* MB_DEC_AR */

/* ------------------------------------------------------------------ *
 * 2. The negative half: one MBP.DOT8 on the hart that must not have it.
 * ------------------------------------------------------------------ */
static void neg_worker(void *p1, void *p2, void *p3)
{
	/* volatile so the operands cannot be constant-folded and the instruction
	 * cannot be optimised away -- there is nothing to compute here, the point is
	 * that the encoding reaches the decoder. */
	static volatile int64_t lhs = 0x0102030405060708LL;
	static volatile int64_t rhs = 0x0101010101010101LL;
	int64_t r;

	ARG_UNUSED(p1); ARG_UNUSED(p2); ARG_UNUSED(p3);

	neg.cpu_id = arch_curr_cpu()->id;
	neg.hartid = csr_read(mhartid);

	r = mb_pext_dot8((int64_t)lhs, (int64_t)rhs);

	/* Reaching here means the instruction RETIRED on the LITTLE hart, i.e. the
	 * decode was mapped over both tiles.  That is the failure this test exists
	 * to catch, and it is silent everywhere else.
	 *
	 * THE ORDER OF THESE TWO STORES IS LOAD-BEARING, AND THE OBVIOUS ORDER IS
	 * WRONG.  pext.h emits the instruction with a plain (non-volatile, no memory
	 * clobber) `__asm__`, which is correct for a pure ALU op -- it is what lets
	 * GCC schedule, CSE and hoist MBP out of the curated kernels' loops, and the
	 * 14.89x in PEXT_KERNELS.md depends on it.  But a plain asm may also be moved
	 * ACROSS a volatile store, and `neg.retired = true` does not depend on `r`, so
	 * GCC was free to sink the `.insn` below it.  It did:
	 *
	 *     800002de:  sb   a2,1(a5)        <- neg.retired = true
	 *     800002e2:  .insn 0x00d7070b     <- MBP.DOT8, which traps here
	 *     800002e6:  sd   a4,40(a5)       <- neg.result = r, never reached
	 *
	 * so on a CORRECT SoC the trap fired, `neg.retired` was already 1, and this
	 * test reported "MBP.DOT8 RETIRED on hart 1" -- a false FAIL that accuses the
	 * hardware of exactly the defect it is there to detect.  Measured on the board;
	 * see PEXT_VALIDATION.md section 3.
	 *
	 * The fix is a data dependency, not a barrier: `neg.result = r` CANNOT be
	 * hoisted above the instruction that produces `r`, and a volatile store after
	 * another volatile store stays after it.  So `retired` is now written last and
	 * only by code the trap cannot skip.  The explicit barrier is belt and braces.
	 */
	__asm__ volatile("" ::: "memory");
	neg.result = r;
	neg.retired = true;
	k_sem_give(&done_sem);
}

/* The application override.  Without it, Zephyr's __weak k_sys_fatal_error_handler
 * calls k_fatal_halt() and the board stops with "Illegal instruction" and no further
 * output -- which is the correct production behaviour and useless as a test.  Here the
 * cause is recorded, main() is released, and only the offending thread dies. */
void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf)
{
	ARG_UNUSED(esf);

	neg.trapped = true;
	neg.reason  = reason;
	neg.mcause  = csr_read(mcause);
	neg.mtval   = csr_read(mtval);

	k_sem_give(&done_sem);
	k_thread_abort(k_current_get());
	CODE_UNREACHABLE;
}

__attribute__((unused)) static void print_ms(unsigned long c)
{
	printk("%lu.%03lu ms", c / CYC_PER_MS, (c % CYC_PER_MS) / (CYC_PER_MS / 1000U));
}

static int run_pinned(struct k_thread *th, k_thread_stack_t *stack,
		      k_thread_entry_t entry, int cpu, const char *what)
{
	k_tid_t tid = k_thread_create(th, stack, WORKER_STACK, entry,
				      NULL, NULL, NULL, 5, 0, K_FOREVER);
	int rc = k_thread_cpu_pin(tid, cpu);

	if (rc != 0) {
		printk("FAIL: k_thread_cpu_pin(%s -> CPU %d) = %d\n", what, cpu, rc);
		return rc;
	}
	k_thread_start(tid);
	/* NOT K_FOREVER: a worker pinned to a CPU that never came online would never
	 * run, and main() would stop with no explanation. */
	if (k_sem_take(&done_sem, K_SECONDS(JOIN_TIMEOUT_S)) != 0) {
		printk("FAIL: %s on CPU %d did not finish within %d s\n",
		       what, cpu, JOIN_TIMEOUT_S);
		return -EAGAIN;
	}
	return 0;
}

int main(void)
{
	bool ok = true;

	k_sem_init(&done_sem, 0, 2);

	printk("\nMB_PEXT_BUILD model=%s quant=%s ops=%d iters=%d hw=%d\n",
	       MODEL_NAME, MODEL_QUANT, MODEL_OP_COUNT, MB_ITERS, MB_PEXT_HW);
#if defined(MB_DEC_AR) && MB_DEC_AR
	printk("MB_DEC_BUILD autoregressive=1 utts=%d decoded=%d n_steps=%d vocab=%d dhid=%d "
	       "eos_id=%d rows_utt=%d selftest=%d\n",
	       MB_AR_UTTS, MB_AR_LIMIT, N_STEPS, VOCAB, DHID, EOS_ID, MB_AR_ROWS_UTT,
	       MB_AR_SELFTEST);
#endif
	printk("MB_PEXT_BUILD main_cpu=%u main_hartid=%lu cpus=%d\n",
	       arch_curr_cpu()->id, (unsigned long)csr_read(mhartid),
	       CONFIG_MP_MAX_NUM_CPUS);

	if (!MB_PEXT_HW) {
		printk("WARN: built with MB_PEXT_HW=0 -- this image runs pext.h's "
		       "software model, not the extension. CONFIG_MB_PEXT is off.\n");
	}

	/* --- 1. positive: the network on CPU 0 ---------------------------- */
	if (run_pinned(&big_thread, big_stack, big_worker, BIG_CPU, "model") != 0) {
		ok = false;
	}
	if (big.ran) {
		printk("MB_PEXT_RUN cpu=%u mhartid=%u median=%lu min=%lu max=%lu "
		       "warm=%lu mtime=%lu max_abs_err=%d\n",
		       big.cpu_id, big.hartid, big.median, big.min, big.max,
		       big.warm_cycles, big.mtime_ticks, big.max_abs_err);
		for (int i = 0; i < big.n_ops; i++) {
#if defined(MB_DEC_AR) && MB_DEC_AR && MB_AR_ROWS_UTT >= 0
			/* TODO item 22: a decoder row needs the STEP it belongs to, or the
			 * timeline folds into 24 uniform blocks and cannot show where early
			 * exit fired.  `phase` is added on the host, which has the IR. */
			printk("MB_PEXT_OP id=%d name=%s op=%s shape=%s cycles=%lu step=%d utt=%d\n",
			       big.op_id[i], big.op_name[i], big.op_kind[i],
			       big.op_shape[i], big.op_cycles[i],
			       (int)ar_row_step[i], MB_AR_ROWS_UTT);
#else
			printk("MB_PEXT_OP id=%d name=%s op=%s shape=%s cycles=%lu\n",
			       big.op_id[i], big.op_name[i], big.op_kind[i],
			       big.op_shape[i], big.op_cycles[i]);
#endif
		}
		if (&mbxr_rt_stats != NULL) {
			/* Cumulative counters: phase=warm is after the warm-up run, phase=total after
			 * the warm-up AND the MB_ITERS timed runs (timed = total - warm; one-time
			 * weight-image builds land in the warm-up). */
			for (int ph = 0; ph < 2; ph++) {
				const mbxr_rt_stats_t *e = ph ? &big.eng_total : &big.eng_warm;

				/* lp64: unsigned long is the counters' 64 bits; %lu, as the rest */
				printk("MB_ROCCMOON phase=%s calls_engine=%lu calls_fallback=%lu "
				       "cycles_h0=%lu cycles_h1=%lu cycles_stage=%lu cycles_stage_in=%lu image_cycles=%lu "
				       "image_bytes=%lu loads_act=%lu loads_wgt=%lu bytes_act=%lu "
				       "bytes_wgt=%lu pairs=%lu polls=%lu fill_beats=%lu cyc_fill=%lu "
				       "cyc_tseq=%lu cyc_busy=%lu steps=%lu "
				       "cyc_wait=%lu cyc_place=%lu placed_early=%lu cap_asked=%d "
				       "last_rc=%d attn_lane=%lu attn_fallback=%lu "
				       "attn_fence_polls=%lu attn_lane_polls=%lu attn_last_rc=%d "
				       "attn_aerr=%u attn_fence_cyc=%lu attn_wait_cyc=%lu"
#if defined(MBXR_RT_LUT) && MBXR_RT_LUT
/* T4's LUT LANE.  A fallback that produces correct results is indistinguishable from success by
 * any correctness check, because the fallback IS the specification -- so the only thing that can
 * tell them apart is a count of which path executed.  Guarded, so an image that does not ask for
 * the lane prints exactly the line it printed before. */
				       " lut_lane=%lu lut_fallback=%lu lut_tiles=%lu"
				       " lut_els_lane=%lu lut_els_scalar=%lu lut_copied=%lu"
				       " lut_last_rc=%d lut_last_uerr=%u"
#endif
/* THE SUB-BYTE WEIGHT GRID.  Guarded, so an int8 image prints EXACTLY the line it printed
 * before and the control arm's console stays byte-comparable with every earlier decoder run.
 * wpack_clipped is the field that keeps two different failures apart: non-zero says a six-bit
 * guest was built against an int8 IR, zero-with-wrong-bytes says the engine's unpacker. */
#if defined(MBXR_RT_WBITS) && MBXR_RT_WBITS != 8
				       " wbits=%d wpack_rows=%lu wpack_clipped=%lu"
#endif
				       "\n",
				       ph ? "total" : "warm",
				       (unsigned long)e->calls_engine, (unsigned long)e->calls_fallback,
				       (unsigned long)e->cycles_h0, (unsigned long)e->cycles_h1,
				       (unsigned long)e->cycles_stage, (unsigned long)e->cycles_stage_in,
				       (unsigned long)e->image_cycles,
				       (unsigned long)e->image_bytes, (unsigned long)e->loads_act,
				       (unsigned long)e->loads_wgt, (unsigned long)e->bytes_act,
				       (unsigned long)e->bytes_wgt, (unsigned long)e->pairs,
				       (unsigned long)e->polls, (unsigned long)e->fill_beats,
				       (unsigned long)e->cyc_fill,
				       (unsigned long)e->cyc_tseq, (unsigned long)e->cyc_busy,
				       (unsigned long)e->steps, (unsigned long)e->cyc_wait,
				       (unsigned long)e->cyc_place, (unsigned long)e->placed_early,
				       e->cap_asked, e->last_rc,
				       (unsigned long)e->attn_lane, (unsigned long)e->attn_fallback,
				       (unsigned long)e->attn_fence_polls,
				       (unsigned long)e->attn_lane_polls, e->attn_last_rc,
				       (unsigned)e->attn_aerr, (unsigned long)e->attn_fence_cyc,
				       (unsigned long)e->attn_wait_cyc
#if defined(MBXR_RT_LUT) && MBXR_RT_LUT
				       , (unsigned long)mbxr_lut_stats.calls_lane,
				       (unsigned long)mbxr_lut_stats.calls_fallback,
				       (unsigned long)mbxr_lut_stats.tiles_lane,
				       (unsigned long)mbxr_lut_stats.elems_lane,
				       (unsigned long)mbxr_lut_stats.elems_scalar,
				       (unsigned long)mbxr_lut_stats.tiles_copied,
				       mbxr_lut_stats.last_rc, (unsigned)mbxr_lut_stats.last_uerr
#endif
#if defined(MBXR_RT_WBITS) && MBXR_RT_WBITS != 8
				       , MBXR_RT_WBITS,
				       (unsigned long)e->wpack_rows,
				       (unsigned long)e->wpack_clipped
#endif
				       );
			}
		}
		if (&mb_smx2_stats != NULL) {
			const mb_smx2_stats_t *h = &mb_smx2_stats;

			printk("MB_SMX2 rows=%lu elements=%lu zero_by_cutoff=%lu exact_evals=%lu d0_hist=",
			       (unsigned long)h->rows, (unsigned long)h->elements,
			       (unsigned long)h->zero_by_cutoff, (unsigned long)h->exact_evals);
			for (int i = 0; i < 257; i++) {
				if (h->d0_hist[i]) {
					printk("%d:%lu,", i - 1, (unsigned long)h->d0_hist[i]);
				}
			}
			printk("\n");
		}
		if (&mbxa_tax != NULL) {
			const mbxa_tax_t *x = &mbxa_tax;

			/* t_round - t_lane is the CROSS-HART term and is reported lumped: hart 0
			 * and hart 1 keep independent rdcycle counters whose offset nothing here
			 * has calibrated, so wake and spin are not separable without a number
			 * this tree does not have.  Everything else is one hart's own delta. */
			printk("MB_B100TAX heads=%lu dispatches=%lu t_table=%lu t_stage=%lu "
			       "t_issue=%lu t_round=%lu t_lane=%lu t_copy=%lu\n",
			       (unsigned long)x->heads, (unsigned long)x->dispatches,
			       (unsigned long)x->t_table, (unsigned long)x->t_stage,
			       (unsigned long)x->t_issue, (unsigned long)x->t_round,
			       (unsigned long)x->t_lane, (unsigned long)x->t_copy);
		}
#if defined(MB_DEC_AR) && MB_DEC_AR
		/* THE RESULT.  One line per utterance and one per step, and the tokens are
		 * what this image exists to produce.  `val` is the winning int8 logit code:
		 * a divergence in the arithmetic moves it even when the argmax INDEX is
		 * unchanged, so the pair is a stronger check than the token alone. */
		/* WHAT THE GUEST ACTUALLY COMPILED WITH.  `-DMB_AR_BATCH=2` on a west build
		 * line is a CMAKE CACHE VARIABLE; if CMakeLists.txt does not forward it, the
		 * driver compiles at the #ifndef default of 1 and decodes a B = 2 GRAPH one row
		 * at a time -- it boots, runs, emits plausible tokens and is wrong.  B99 lost a
		 * board round to that, and the counters could not distinguish it from a bad
		 * graph: the only tell was that each utterance had its OWN dispatch count where
		 * a group's rows must share one.  So the guest now STATES its B, and the scorer
		 * can refuse a console whose B is not the one the image was built for. */
		printk("MB_DEC_CFG batch=%d utts=%d limit=%d input_size=%d output_size=%d "
		       "enc_dispatches=%d enc_bytes=%d enc_in_bytes=%d\n",
		       (int)MB_AR_BATCH, (int)MB_AR_UTTS, (int)MB_AR_LIMIT,
		       (int)MODEL_INPUT_SIZE, (int)MODEL_OUTPUT_SIZE,
		       (int)MB_ENC_DISPATCHES,
		       MB_ENC_DISPATCHES > 0 ? (int)MB_ENC_BYTES : 0,
		       MB_ENC_DISPATCHES > 0 ? (int)MB_ENC_IN_BYTES : 0);
		for (int u = 0; u < MB_AR_LIMIT; u++) {
			printk("MB_DEC_UTT u=%d tokens_emitted=%d steps_taken=%d eos=%d "
			       "dispatches=%lu cycles=%lu enc_passes=%lu\n",
			       u, ar[u].n, ar[u].steps, ar[u].hit_eos,
			       ar[u].dispatches, ar[u].cyc, ar[u].enc_passes);
			for (int i = 0; i < ar[u].n; i++) {
				printk("MB_DEC_STEP u=%d k=%d tok=%d val=%d cycles=%lu\n",
				       u, i, (int)ar[u].tok[i], (int)ar[u].val[i],
				       ar[u].step_cyc[i]);
			}
			printk("MB_DEC_TOKS u=%d n=%d ids=", u, ar[u].n);
			for (int i = 0; i < ar[u].n; i++) {
				printk("%s%d", i ? "," : "", (int)ar[u].tok[i]);
			}
			printk("\n");
		}
		printk("   hart %u (big): %d utterances decoded autoregressively; "
		       "there is no baked golden here and none is claimed\n",
		       big.hartid, MB_AR_LIMIT);
#else
		printk("MB_PEXT_OUT");
		for (int i = 0; i < MODEL_TEST_OUTPUT_LEN; i++) {
			printk(" %d", (int)big.out[i]);
		}
		printk("\n");
		printk("   hart %u (big): median ", big.hartid);
		print_ms(big.median);
		printk("   max_abs_err=%d\n", big.max_abs_err);
#endif

		if (big.hartid != MB_PEXT_BIG_HART) {
			printk("FAIL: the model ran on hart %u, not the big hart\n",
			       big.hartid);
			ok = false;
		}
#if !(defined(MB_DEC_AR) && MB_DEC_AR)
		if (big.max_abs_err != 0) {
			printk("FAIL: max_abs_err=%d against the baked int8 golden\n",
			       big.max_abs_err);
			ok = false;
		}
#else
		/* The AR image has no baked golden to be right or wrong against; a 0 here
		 * would be "max_abs_err=0 over 0 bytes compared".  The check that matters
		 * runs on the host, against dec_driver.c's token sequence. */
		for (int u = 0; u < MB_AR_LIMIT; u++) {
			if (ar[u].n <= 0) {
				printk("FAIL: utterance %d emitted no tokens\n", u);
				ok = false;
			}
		}
#endif
	} else {
		ok = false;
	}

	/* --- 2. negative: one MBP.DOT8 on CPU 1 --------------------------- */
	printk("MB_PEXT_NEG starting -- one MBP.DOT8 pinned to CPU %d; an "
	       "illegal-instruction trap here is the PASS\n", LITTLE_CPU);
	(void)run_pinned(&neg_thread, neg_stack, neg_worker, LITTLE_CPU, "negtest");

	if (neg.retired) {
		printk("MB_PEXT_NEG cpu=%lu mhartid=%lu trapped=0 result=%lld\n",
		       neg.cpu_id, neg.hartid, (long long)neg.result);
		printk("FAIL: MBP.DOT8 RETIRED on hart %lu. The decode is mapped over "
		       "both tiles, and the heterogeneity this SoC exists to "
		       "demonstrate is not there.\n", neg.hartid);
		ok = false;
	} else if (neg.trapped) {
		printk("MB_PEXT_NEG cpu=%lu mhartid=%lu trapped=1 reason=%u "
		       "mcause=%lu mtval=0x%08lx\n",
		       neg.cpu_id, neg.hartid, neg.reason, neg.mcause, neg.mtval);
		/* THE PASS CONDITION IS "it trapped instead of retiring", and the two
		 * CSRs below are corroboration rather than the test.  mcause 2 is
		 * Illegal Instruction and mtval carries the faulting instruction word
		 * on Rocket, but neither is architecturally guaranteed to still hold
		 * the original values by the time an application fatal handler runs --
		 * Zephyr's RISC-V esf does not carry mcause, so these are read from the
		 * CSRs directly and a second trap on the way here would overwrite them.
		 * Reporting them as unconfirmed is honest; failing the test on them
		 * would make a correct SoC look broken. */
		if (neg.mcause == 2 && (neg.mtval & 0x7fu) == MB_PEXT_OPCODE) {
			printk("   hart %lu refused 0x%08lx -- custom-0, funct3=%lu: "
			       "MBP is on hart %d only, as specified\n",
			       neg.hartid, neg.mtval, (neg.mtval >> 12) & 7u,
			       MB_PEXT_BIG_HART);
		} else {
			printk("   hart %lu trapped as required, but mcause=%lu / "
			       "mtval=0x%08lx do not confirm an illegal-instruction "
			       "exception on a custom-0 word (expected mcause=2, "
			       "opcode 0x%02x). The trap itself is the result; these "
			       "CSRs may have been overwritten before the handler ran.\n",
			       neg.hartid, neg.mcause, neg.mtval, MB_PEXT_OPCODE);
		}
	} else {
		printk("FAIL: the negative worker neither trapped nor retired -- it "
		       "never ran. CPU %d may not have come online.\n", LITTLE_CPU);
		ok = false;
	}

	printk("RESULT: %s -- the MBP kernels ran bit-exact on hart %d and the "
	       "same instruction is illegal on hart %d\n",
	       ok ? "PASS" : "FAIL", MB_PEXT_BIG_HART, LITTLE_CPU);
	return 0;
}
