#!/usr/bin/env bash
# Lab B57 -- THE BOARD CHOOSES ITS OWN TOKENS.  The first on-board transcription.
#
#   ./scripts/74_rocket_moonshine_tokens_board.sh --gen                       # 1. codegen, no board
#   ./scripts/74_rocket_moonshine_tokens_board.sh --hostref --n 8             # 2. host reference
#   ./scripts/74_rocket_moonshine_tokens_board.sh --image                     # 3. the AR image
#   PYNQ_HOST=... scripts/with_board_illixr.sh ./scripts/74_... --board-only  # 4. the board
#   ./scripts/74_rocket_moonshine_tokens_board.sh --report-only               # 5. score it again
#
# Stages are separate flags rather than one pipeline because three of the five take tens of
# minutes and only ONE of them holds the board lock: a failure in the parser must not cost a
# second board session, and the board step must not wait on a codegen.  With no stage flag
# every stage runs, in order.
#
# WHY THIS LAB EXISTS.  Every transcript this repository has produced came from the host.
# `samples/modelblaster_pext`'s image walks a baked dispatch table MB_ITERS times and diffs the
# result against a baked golden: there is no argmax in it, no EOS test, no embedding lookup and
# no feedback.  It replays a fixed 24-step trajectory that the HOST chose.  The thing that
# chooses is `out/decint8/gen_eng/dec_driver.c`, 73 lines, and its own header says where the
# line is: *"Everything data-dependent lives HERE, not in the graph."*  So `RTF_e2e` is composed
# today from two halves that each match a transcribing program rather than measured from one
# that transcribed, and the standing goal says *"for a model that transcribes"*.
#
# WHAT THE BOARD DECIDES HERE, STATED SO IT CANNOT BE FOLDED INTO A TOTAL:
#   ON BOARD    the 24-step unrolled int8 decoder graph; the argmax over each step's 32,768
#               logits; the EOS test; the embedding-row lookup and its requantisation into the
#               next step's input; and the early exit, which is a BREAK OUT OF THE UNROLLED
#               DISPATCH SEQUENCE and therefore the loop bound.
#   ON HOST     the encoder (HF float by default, `--enc` for ModelBlaster's int8 one) and the
#               FLOAT CROSS-ATTENTION PROLOGUE, whose kx/vx are packed into the board's input.
#               That prologue is one of the four standing caveats on every `RTF_e2e` quoted in
#               this tree and it is named in the run record, not absorbed.
#               Detokenising ids to text is also host-side: the board's job is the tokens.
#
# THE CHECK.  The board's token sequence must be IDENTICAL to `dec_driver.c`'s on the same
# input.  Not close -- identical.  The graph is bit-exact against the host's generated C on this
# bitstream (every decoder arm in Labs B49..B56 reports `max_abs_err = 0`), and the one new
# numeric is the embedding requantisation, which is IEEE-754 single precision on both sides
# (libgcc soft float on the board, SSE on the host).  So the per-step argmax VALUE is compared
# as well as its index: a divergence in the arithmetic moves `val` even where the token is
# unchanged, and a run that matched tokens by luck would not match values.
#
# WHAT IT REFUSES TO DO.  It reports no `max_abs_err`, because there is no baked golden for a
# data-dependent trajectory and "max_abs_err = 0 over 0 bytes compared" is the 438eb27 lie.  It
# does not substitute the board's own `mean_steps` into any composition -- it prints it beside
# `decoder_tokens_dev.json`'s 11.976 and says what the difference is.
#
# Produces out/<name>/{run.json,report.txt,verdict.txt,prediction.json,hostref/,ar/}.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="b57_dec_tokens"
IR_SRC=""
N_UTT=8
ROWS_UTT=0
# 0x5A5A002D roccmoonlut2: the build that carries the attention, LayerNorm and LUT lanes and
# that every decoder arm since B49 has measured on.  The lanes are not SELECTED by this image's
# picks (see the curated tree below) -- what matters is that the engine is the one the decoder
# has been validated against, and the cap-4 L2.
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonlut2_z1/pynqz1_rocket_micrgb_roccmoonlut2.bit"
WANT_MAGIC="0x5A5A002D"
RUNNER="run_rocket_roccmoonlut2.py"
BOARD="chipyard_pynqz1_micrgb"
LAB_REQUIRES="${LAB_REQUIRES:-rocc_engine pext}"
# --fclk <MHz>: THE PL CLOCK THIS RUN IS LOADED AT, TIMED AT AND DIVIDED BY -- one flag, so the
# four places that have to agree cannot drift apart.  It sets (1) the FCLK0 the runner programs
# on the load path, (2) the FCLK0 fclk.py reads back out of the SLCR and refuses, (3) the
# CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC this run's guest must have been built with, and (4) the Hz
# this run's cycles are divided by to make an RTF.  Pair it with the matching --board: on this
# port the clock reaches software through that Kconfig symbol alone, and that symbol also sets
# the SiFive UART's baud divisor, so a guest built for the wrong clock GARBLES THE CONSOLE and
# runs mtime fast -- it does not fail.  Default 34.4828 (1000/29), which is every build before
# 0x5A5A0030.
FCLK_CORE=34.4828
WINDOW_S_OPT=4.0
MAXREAD=5400
ENC_GEN=""
DO_GEN=0; DO_HOSTREF=0; DO_IMAGE=0; DO_BOARD=0; DO_REPORT=0; ANY_STAGE=0
KCF_ALL="-falign-loops=4 -DMBP_MMB_M1_UNROLL8=1 -DMBP_B76=1"
# MBP_MMB_M1_UNROLL8: in the bank's cflags since before this script existed, ABSENT from this
# script's, and visible in the cflag string the whole time without ever being compared.  It is
# worth 1.180x -> 1.003x of the bank on cross-attention `qk` (B99/B101, measured both ways on
# this lab's own arms) and nothing at all on `av`, whose tb=0 layout the DOT8 path cannot take
# -- that one needs ir_vperm.py.  Free, so it is not optional.
#
# MBP_B76 is read by mul_s8, layernorm_s8 and permute4_s8 (B101's op-by-op join: those are the
# only three rows it moves, and they are exactly the three that were off parity once silu and
# the matmuls were accounted for).  Also in the bank's cflags and absent from this script's.
PLACE_EARLY_CFLAG="-DMBXR_RT_PLACE_EARLY=1"
DO_CSE=1
# --lmsplit: shard a linear_s8 too wide to image in one piece, IN THE GRAPH (B99).
# Off by default: it is a graph change, and every arm before B99 measured without it.
DO_LMSPLIT=0
# --no-vperm turns off the hoisted V-permute flip (ir_vperm.py).  ON by default: it is
# bit-exact (verified by computing both outputs) and worth ~6.8 % of a decoder step.
DO_VPERM=1
# --batch-decode B: decode B independent utterances per pass of the graph (B99).
BATCH_DECODE=1
# --regbatch <mode>: LAB B129.  WHICH PASS GIVES THE GRAPH ITS BATCH DIMENSION.
#
# Empty (the default) is `ir_batch.py`, which is what every arm before B129 ran and which
# REFUSES the merged encoder+decoder graph -- six op kinds in the `e.` region have no rule
# (B127 measured all 33 sites there).  `ir_regbatch.py` batches ONE REGION and leaves the
# encoder at N = 1, which is what keeps conv2d_s8 on the engine
# (roccmoon_conv2d_s8_roccmoon_engine.c:52 gates on `N == 1 && IH == 1 && KH == 1 && PH == 0`).
#
#   replicate   B copies of the `e.` region in the graph, joined into `enc` [B,165,288].
#               A PURE IR PASS -- no driver change.  Capped at B = 2 by the 0x88000000
#               arena base (B127: B = 4 overshoots by 4,305,416 B).
#   once        ONE encoder, `enc` widened to [B,165,288].  NEEDS THE DRIVER: main.c must
#               walk dispatches [0, encoder_dispatches) B times.  That is what
#               MB_ENC_DISPATCHES / MB_ENC_BUF are for, and this script passes neither by
#               itself -- the caller sets them through MB_HCF_EXTRA, so an image cannot get
#               a `once` graph and a driver that does not know about it by forgetting a flag
#               here.  The gate for that is in the caller (b129_once.sh), not in a default.
REGBATCH=""
# SILU_INT: silu_s8's INTEGER table builder (pext_int_lut) instead of the bit_exact
# pext_memo_lut.  DEFAULT 1, FOLLOWING scripts/58, WHICH IS THIS SCRIPT'S STATED AUTHORITY
# FOR THE CURATED TREE ("chosen exactly the way scripts/58 chooses it", below).
#
# scripts/58 flipped its own default to 1 on 2026-09-18 on L316, which measured the integer
# builder at 7.82x on silicon -- 369.27 -> 47.20 cycles/element -- and banked it.  THIS SCRIPT
# DID NOT FOLLOW, so every scripts/74 arm since has silently carried the slow kernel and has
# not been comparable with any scripts/58 record.  Lab B99 lost a cross-configuration
# attribution to it: 366.5 against 47.07 cycles/element read as a DATA effect when it was a
# different kernel.  That is the fourth lab to walk into the trap scripts/58:560 documents.
SILU_INT="${SILU_INT:-1}"
# BATCHING, for Tier 2.  One image cannot carry the whole 765-utterance dev set: each
# utterance is 577,152 B of packed cross-attention K/V and hidden state, so 765 of them is
# 441 MB against ram0's 256.  --batch I --batch-size S carries utterances [I*S, (I+1)*S) and
# the report merges every batch's console, so the WER is over the whole set even though no
# single image held it.  Unset = one image, the whole of --n.
BATCH=""
BATCH_SIZE=""
PRISTINE="always"
DO_WER=0                           # --wer: score the BOARD's tokens (Tier 2)
# --replay: THE OTHER HALF OF THE BAR, and it is a DIFFERENT CLAIM.
#
# This lab's AR image reports no `max_abs_err` and says so loudly: the trajectory is
# data-dependent, there is no baked golden, and "max_abs_err = 0 over 0 bytes compared" is
# 438eb27's lie.  But `max_abs_err = 0` on a baked trajectory and "the board chose the same
# tokens" are two claims and NEITHER IMPLIES THE OTHER -- the int6 result turned on exactly
# that distinction, arithmetic that was bit-exact against its own golden and still moved the
# tokens.  So a configuration that has never decoded anything needs both, and until now this
# harness could only state one of them, which is how a config gets called "checked".
#
# --replay builds the SAME generated model from the SAME gen directory WITHOUT -DMB_DEC_AR,
# so samples/modelblaster_pext runs its fixed 24-step baked trajectory and diffs against
# MODEL_TEST_OUTPUT.  Same bitstream, same clock, same board, same session, same curated
# kernels -- the only difference is which of the two claims the image can make.
REPLAY=0
# --iters/--warmup: WHICH RUN THE PER-DISPATCH ROWS COME FROM, and it is not cosmetic.
# model.c writes `records_[slot].cycles = _e - _s` -- it OVERWRITES, it does not accumulate --
# so the rows a replay arm prints are the LAST call of model_run_test().  At the shipping
# MB_ITERS=1 MB_WARMUP=0 that last call is the only call, and it is COLD: it carries the
# one-time engine weight-image build, which is 130,416,004 of b103's 209,628,939 encoder
# cycles.  A row read off that run is not a steady cost and cannot be composed into an RTF.
# --warmup 1 makes the timed call the second one, so the rows are steady and the one-time
# build is isolated in `warm_cycles` and in the MB_ROCCMOON phase=warm counters.
# Defaults are the shipping ones, so every arm before Lab B112 gates exactly as it did.
REPLAY_ITERS=1
REPLAY_WARMUP=0
# --pro-int8: the IR computes the cross-attention prologue itself, so the HOST packs the
# encoder's one hidden state instead of twelve float kx/vx tensors (model_dec_run.py checks
# the flag against the IR both ways -- the two packings are the same buffer at different
# offsets and a mismatch is a transcript, not an error).
PRO_INT8=0
# --e2e <encoder run dir>: LAB B114.  THE ENCODER, THE PROLOGUE AND THE DECODER IN ONE IMAGE.
#
# `ir_concat.py` prepends the encoder's graph to the prologue-lowered decoder's, wiring the
# encoder's output tensor into the decoder's `enc` packed field -- so `enc` stops being a packed
# input and becomes an intermediate, exactly as B112 did to kx/vx.  The packed input is then the
# 4.0 s window of int8 AUDIO (64,000 B) plus the 24 `h` slots.
#
# ONE GRAPH, NOT TWO MODELS SHARING AN IMAGE, and the reason is not the packing.  Every curated
# engine kernel #includes fpga/pynq-z2/sw/roccmoon/mbxr_rt.h, which DEFINES the engine runtime's
# file-scope singletons -- mbxr_rt_stats, mbxr_rt_job, mbxr_rt_go and the hart-1 worker.  Two
# generated models means two kernels.c, which is a second worker and a second job structure for
# one RoCC: not a duplicate symbol, a second driver.  (samples/modelblaster_pext takes one
# MODEL_DIR, which is B112's stated reason, and it is the weaker of the two.)
#
# ONE IMAGE HAS ONE PICK PER OP KIND AND ONE SET OF KERNEL CFLAGS.  The two banked arms disagree
# on exactly one pick -- layernorm_s8 is roccmoon_lane in the encoder bank and pext_int_rsqrt in
# the decoder bank -- and those two cores are NOT bit-identical (ln_pt_check.json: one code apart
# on ~0.2 % of elements at these shapes).  This flag takes the DECODER bank's pick, so the 4,272
# decoder dispatches keep their kernel and the encoder's 13 layernorms change theirs; the
# encoder region is then gated against a control gen built the same way rather than against
# b103's lane golden.  gelu_s8/tanh_s8 go the other way -- the encoder needs the LUT lane and
# the decoder has neither op -- so the pext fallbacks are removed from the curated tree and
# -DMBXR_LUT_LANE=0 is NOT passed.
E2E_ENC=""
# --ln-lane: LAB B115.  TAKE THE **ENCODER** BANK'S layernorm_s8 PICK INSTEAD OF THE DECODER'S.
#
# B114 measured the price of the other direction: one image has one pick per op kind, it took
# `pext_int_rsqrt` (the decoder bank's), and the encoder's thirteen 165x288 LayerNorms cost
# +35,906,338 cycles -- +0.2244 of RTF_e2e, twelve times the whole prologue.  The REVERSE
# direction has never been run: keep `roccmoon_lane` (the encoder bank's) and move the
# decoder's 456 one-row LayerNorms onto the lane.
#
# IT IS A CURATED-TREE CHANGE AND NOTHING ELSE.  The probe walks spec.algorithms in order and
# `roccmoon_lane` is LAST in LAYERNORM_S8's list with target_affinity=("roccmoon",), so the
# lane wins on a roccmoon run whose tree carries the file: the only thing this flag does is
# NOT delete it.  The assertion below is flipped with it so the pick is checked BOTH WAYS --
# an arm that quietly took the other kernel would otherwise produce a clean number for a
# machine nobody configured (scripts/58:560).
#
# WHAT IT COSTS THE DECODER, STATED BEFORE IT RUNS.  M = 1, K = 288 plans to ONE tile
# (mbxr_ln_plan: 8,192/288 = 28 rows, capped at M), padded to two rows because 288 is not a
# multiple of 64 -- so every decoder LayerNorm stages through MBXR_RT_IN_STAGE, writes the
# WHOLE K = 288 affine table (`m0 == 0 ? K : 0`, five lane cfgs per entry) and drains through
# MBXR_RT_SCRATCH.  The encoder amortises that table over six tiles of 28 rows; the decoder
# cannot amortise it at all.  That is the arm.
LN_LANE=0
# --ln-split <prefix>: LAB B116.  TWO OP KINDS, SO THE TWO HALVES CAN PICK TWO KERNELS.
#
# B114 priced taking the decoder's LayerNorm pick (+35,906,338 cycles on the encoder) and B115
# priced taking the encoder's (+105,187,369 on the decoder).  Both directions lose because one
# image has ONE pick per OP KIND -- so this flag stops making them share a kind.
#
# `ir_lnsplit.py` rewrites the layernorm_s8 ops whose NAME starts with <prefix> into
# `layernorm_pc_s8`, which is not a new kind: it is a sibling that already has a KernelSpec, a
# curated lane kernel, a generate_skeleton emitter and an entry in feature_gate.py's
# (op, algorithm) table.  NOTHING IN THE CODEGEN CHANGES.  The pass bakes the affine table that
# `kernel_layernorm_s8` would otherwise derive at runtime, and the two kernels are the same
# driver under two names (`mbxr_ln_run`, one copy, in sw/roccmoon/mbxr_ln_driver.h) -- so the
# lane is handed the same bytes and answers the same bytes.  `--verify-c` compiles
# sw/roccmoon/mbxr_ln_derive.h and diffs the C's own derivation against the pass's, per element,
# per site, and is passed here rather than trusted.
#
# It runs LAST, after ir_cse/ir_lmsplit/ir_vperm, so those three see exactly the graph B114's
# arm gave them and every dispatch_id -- and therefore driver_meta.h -- is unchanged by it.
LN_SPLIT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --ir) IR_SRC="${2:?}"; shift 2 ;;
    --n) N_UTT="${2:?}"; shift 2 ;;
    --rows-utt) ROWS_UTT="${2:?}"; shift 2 ;;
    --batch) BATCH="${2:?}"; shift 2 ;;
    --batch-size) BATCH_SIZE="${2:?}"; shift 2 ;;
    --no-pristine) PRISTINE="auto"; shift ;;
    --wer) DO_WER=1; shift ;;
    --replay) REPLAY=1; shift ;;
    --iters) REPLAY_ITERS="${2:?}"; shift 2 ;;
    --warmup) REPLAY_WARMUP="${2:?}"; shift 2 ;;
    --pro-int8) PRO_INT8=1; shift ;;
    --e2e) E2E_ENC="${2:?}"; shift 2 ;;
    --ln-lane) LN_LANE=1; shift ;;
    --ln-split) LN_SPLIT="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --enc) ENC_GEN="${2:?}"; shift 2 ;;
    --no-cse) DO_CSE=0; shift ;;
    --lmsplit) DO_LMSPLIT=1; shift ;;
    --vperm) DO_VPERM=1; shift ;;
    --no-vperm) DO_VPERM=0; shift ;;
    --batch-decode) BATCH_DECODE="${2:?}"; shift 2 ;;
    --regbatch) REGBATCH="${2:?}"; shift 2 ;;
    --silu-int) SILU_INT=1; shift ;;
    --no-silu-int) SILU_INT=0; shift ;;
    --maxread) MAXREAD="${2:?}"; shift 2 ;;
    --gen)         DO_GEN=1; ANY_STAGE=1; shift ;;
    --hostref)     DO_HOSTREF=1; ANY_STAGE=1; shift ;;
    --image)       DO_IMAGE=1; ANY_STAGE=1; shift ;;
    --board-only)  DO_BOARD=1; DO_REPORT=1; ANY_STAGE=1; shift ;;
    --report-only) DO_REPORT=1; ANY_STAGE=1; shift ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ "$ANY_STAGE" -eq 1 ] || { DO_GEN=1; DO_HOSTREF=1; DO_IMAGE=1; DO_BOARD=1; DO_REPORT=1; }

MB="$ZCS/modelblaster"
MOON="$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
KERNELS_T1="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels_t1"
[ -n "$IR_SRC" ] || IR_SRC="$IISWC_OUT/decint8/ir"
RUN="$IISWC_OUT/$NAME"
GEN="$RUN/gen"
HREF="$RUN/hostref"
AR="$RUN/ar"
CUR="$RUN/kernels_board"
mkdir -p "$RUN" "$HREF" "$AR"
# FCLK0 = 1000 MHz / N for an integer N on this PS7 (the IO PLL is 50 x 20), so derive the Hz
# from N and not from the rounded MHz: that reproduces the repo's 34482759 = round(1e9/29) to the
# Hz and is exact at 1000/25 = 40 MHz.  GUEST_KHZ is CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC, which
# sets mtime AND the UART baud divisor -- wrong, it garbles the console rather than failing.
read -r CLK_HZ GUEST_KHZ <<EOF_CLK
$(python3 -c "
import sys
f = float(sys.argv[1])
n = round(1000.0 / f)
if n < 1 or abs(1000.0 / n - f) > 0.02 * f:
    sys.exit('the PS7 cannot deliver %g MHz: nearest is %g' % (f, 1000.0 / max(1, n)))
print('%d %d' % (round(1e9 / n), round(1e6 / n)))
" "$FCLK_CORE")
EOF_CLK
[ -n "${CLK_HZ:-}" ] || die "could not derive the core clock in Hz from --fclk $FCLK_CORE"
printf '%s\n' "$CLK_HZ" > "$RUN/clock_hz.txt"
info "clock: FCLK0 $FCLK_CORE MHz = $CLK_HZ Hz; guest CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ"
case "$WANT_MAGIC" in
  # B96: 0x5A5A0031 and 0x5A5A0032 WERE MISSING FROM THIS LIST.  scripts/57 (L198) and
  # scripts/58 (L292) both carry them; this file stopped at 0x5A5A0030 and nobody noticed,
  # because 74's default WANT_MAGIC is 0x5A5A002D and it has only ever been run on that.
  # The wildcard default below is CAP=3, so running the SHIPPING build through this harness
  # silently gave the engine a DIFFERENT OUTSTANDING CAP than 57 and 58 give it -- a second
  # lever wearing one name, which is the exact failure MAGIC_REGISTRY.md:97 records.
  0x5A5A0028|0x5A5A0013|0x5A5A0029|0x5A5A002A|0x5A5A002B|0x5A5A002C|0x5A5A002D|0x5A5A002E|0x5A5A002F|0x5A5A0030|0x5A5A0031|0x5A5A0032|0x5A5A0033|0x5A5A0034|0x5A5A0035) CAP_CFLAG="-DMBXR_RT_CAP=4" ;;
  *)                     CAP_CFLAG="-DMBXR_RT_CAP=3" ;;
esac
# THE ARRAY WIDTH THE GUEST PACKS FOR, KEYED BY MAGIC FOR CAP_CFLAG'S REASON.  MBXR_NCH lays out
# every weight plane (mbxr.h) and the silicon addresses a fixed number of them; disagree and the
# drain descriptor is the wrong size for what the packer emits and every dispatch times out.
# 0x5A5A0033 is REFUSED and absent here deliberately: its plane 7 is discarded by the hardware,
# so there is no guest that makes it correct.  mbxr_rt.h re-checks this against the engine's own
# id word at init and refuses with MBXR_E_WIDTH = -6, so a stale list is caught on the board
# rather than measured -- but it is a list, and B96 is what a stale one costs.
case "$WANT_MAGIC" in
  0x5A5A0034|0x5A5A0035) NCH_CFLAG="-DMBXR_NCH=8" ;;
  *)                     NCH_CFLAG="" ;;
esac
NCH_CFLAG_SP="${NCH_CFLAG:+ $NCH_CFLAG}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_ROOT MOONSHINE_WINDOW_S="$WINDOW_S_OPT"
export MOONSHINE_DIR="${MOONSHINE_DIR:-$IISWC_OUT/moonshine}"
PY="$ZCS/tools/miniforge3/envs/zephyr/bin/python"; [ -x "$PY" ] || PY=python
NM=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-nm' 2>/dev/null | head -1)

SNAP_DONE=0
snapshot_once () {
  [ "$SNAP_DONE" -eq 0 ] || return 0
  [ -d "$RUN" ] || return 0
  SNAP_DONE=1
  printf '\n    [archive] snapshotting %s before anything else\n' "$NAME"
  "$IISWC_ROOT/archive/tools/archive_run.py" "$NAME" 2>&1 | sed 's/^/    /' || \
    printf '    [archive] WARNING: archive_run.py failed; out/%s is still on disk\n' "$NAME"
}
trap snapshot_once EXIT

# ============================================================================================
# 1  CODEGEN -- the same generated model scripts/58 builds, plus driver_meta.h beside it
# ============================================================================================
if [ "$DO_GEN" -eq 1 ]; then
step "1/5  codegen (backend roccmoon) from $IR_SRC"
need_file "$IR_SRC/graph.json"; need_file "$IR_SRC/weights.npz"; need_file "$IR_SRC/io.npz"
MB_STACK="0100-modelblaster-moonshine-ops 0102-modelblaster-roccmoon-backend 0103-modelblaster-q16-lowering 0104-modelblaster-softmax-memo 0105-modelblaster-moonshine-stem-nhwc 0106-modelblaster-softmax-memo2 0107-modelblaster-permute-block"
MB_TOP="$IISWC_ROOT/patches/${MB_STACK##* }.patch"
git -C "$MB" apply --reverse --check "$MB_TOP" >/dev/null 2>&1 \
  || die "the ModelBlaster patch stack is not applied -- run scripts/58 --build-only once first"
info "patch stack through ${MB_STACK##* } is applied"

# ---- B114: THE CONCATENATION, BEFORE ANY PASS RUNS OVER IT -------------------------------
# ir_concat refuses unless the encoder's output tensor and the decoder's `enc` field agree on
# dtype, shape AND quant scale to the bit, so the handoff is the identity by construction and
# there is no requantisation between the two models at all.  b114_e2e_io.py then builds the
# merged io.npz, with the golden COMPOSED through the two banked gens' own generated C rather
# than through this graph -- a reference this graph can fail against.
if [ -n "$E2E_ENC" ]; then
  need_file "$E2E_ENC/ir/graph.json" "--e2e wants an encoder RUN dir holding ir/ and gen/"
  need_file "$E2E_ENC/gen/test_golden.bin" "--e2e needs the encoder gen's host-C golden"
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_concat.py" --selftest
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_concat.py" \
      --a "$E2E_ENC/ir" --b "$IR_SRC" --wire enc --a-prefix e --name moonshine_e2e \
      --out "$RUN/ir_cat" --report "$RUN/ir_concat_report.json"
  # The composed golden needs the DECODER RUN dir (the one holding gen/), which is not the
  # dir holding the lowered IR -- b112 lowers into out/b112_pro/ir and generates into
  # out/b112_pro_dec/gen.  Named, not derived: a wrong guess here is a golden for another
  # graph, which is the class of error this whole file is written against.
  if [ ! -f "$RUN/ir_cat/io.npz" ]; then
    [ -n "${E2E_B_RUN:-}" ] || die "set E2E_B_RUN to the decoder run dir holding gen/ (the one
       whose generated C composes the golden), or build \$RUN/ir_cat/io.npz first with
       fpga/pynq-z2/modelblaster/moonshine/b114_e2e_io.py"
    ( cd "$MOON" && "$PY" "$MOON/b114_e2e_io.py" --a "$E2E_ENC" \
        --b "$E2E_B_RUN" --merged "$RUN/ir_cat" \
        --work "$RUN/io" ) || die "the composed golden could not be built"
  fi
  need_file "$RUN/ir_cat/io.npz"
  echo "$E2E_ENC" > "$RUN/e2e_encoder.txt"
  IR_SRC="$RUN/ir_cat"
  info "e2e: merged graph at $IR_SRC"
fi

# The curated tree a board would run, chosen exactly the way scripts/58 chooses it: the probe
# walks spec.algorithms in order, so REMOVING the earlier file is how a later one wins.  Both
# directions, because registering a candidate offers it to every run (Lab B42).
rm -rf "$CUR"; cp -r "$KERNELS" "$CUR"
if [ "$LN_LANE" -eq 0 ]; then
  rm -f "$CUR/roccmoon/roccmoon_layernorm_s8_roccmoon_lane.c"
else
  # B115: the lane STAYS, and the pext candidate goes, so neither the probe's ordering nor its
  # affinity rule is what decides -- exactly ONE layernorm_s8 kernel is in the tree.
  need_file "$CUR/roccmoon/roccmoon_layernorm_s8_roccmoon_lane.c" "--ln-lane wants the lane kernel"
  rm -f "$CUR/pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c"
fi
if [ "$SILU_INT" -eq 1 ]; then
  rm -f "$CUR/pext_nl/pext_nl_silu_s8_pext_memo_lut.c"
  need_file "$CUR/pext_nl/pext_nl_silu_s8_pext_int_lut.c" "no pext_int_lut silu kernel"
else
  rm -f "$CUR/pext_nl/pext_nl_silu_s8_pext_int_lut.c"
  need_file "$CUR/pext_nl/pext_nl_silu_s8_pext_memo_lut.c" "no pext_memo_lut silu kernel"
fi
rm -f "$CUR/roccmoon/roccmoon_cat2_c1_s8_roccmoon_lut.c"
rm -f "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_row.c" "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_memo.c"
need_file "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_memo2.c"
[ "$LN_LANE" -eq 1 ] || need_file "$CUR/pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c"
need_file "$CUR/pext_nl/pext_nl_cat2_c1_s8_pext_memo_lut.c"
cp "$KERNELS_T1/pext_nl/pext_nl_permute4_s8_pext_block.c" "$CUR/pext_nl/"
# B114: gelu_s8 and tanh_s8 exist only in the ENCODER half and the LUT lane is what b103
# measured them on (19.34 cycles/element on the fallback against 1.45 measured here), so the
# pext candidates come out exactly the way scripts/57 --lut-lane takes them out.  layernorm_s8
# is NOT touched: the decoder bank's pext_int_rsqrt stays, and the encoder's 13 sites move.
if [ -n "$E2E_ENC" ]; then
  rm -f "$CUR/pext/pext_gelu_s8_pext_memo_lut.c" "$CUR/pext/pext_tanh_s8_pext_memo_lut.c" \
        "$CUR/pext_nl/pext_nl_gelu_s8_pext_int_lut.c"
  need_file "$CUR/roccmoon/roccmoon_gelu_s8_roccmoon_lut.c"
  need_file "$CUR/roccmoon/roccmoon_tanh_s8_roccmoon_lut.c"
  need_file "$CUR/roccmoon/roccmoon_conv2d_s8_roccmoon_engine.c"
  need_file "$CUR/roccmoon/roccmoon_attention_s8_roccmoon_lane.c"
fi
info "curated tree: softmax -> pext_int_memo2, permute4_s8 -> pext_block, silu_s8 -> $([ "$SILU_INT" -eq 1 ] && echo pext_int_lut || echo pext_memo_lut), no lanes selected"

IR="$IR_SRC"
if [ "$DO_CSE" -eq 1 ]; then
  CSE_IR="$RUN/ir_cse"; rm -rf "$CSE_IR"; mkdir -p "$CSE_IR"
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_cse.py" --selftest
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_cse.py" \
      --ir "$IR/graph.json" --out "$CSE_IR/graph.json" --report "$RUN/ir_cse_report.json"
  for f in weights.npz io.npz; do ln -sfn "$IR/$f" "$CSE_IR/$f"; done
  IR="$CSE_IR"
fi
# THE lm_head SHARD, AFTER THE CSE AND BEFORE driver_meta.  `kernels.c` shards a wide linear by
# N only at M == 1 (it has no output stride), so at M > 1 lm_head asks for one image, the 8 MiB
# staging guard refuses it and the largest layer in the decoder runs on the CPU -- reported only
# as calls_fallback.  Sharding in the GRAPH gives each shard its own output tensor, so Nc == N
# and that gate is never reached.  The shards are the images the kernel builds for itself today,
# so image_bytes, bytes_wgt and calls_engine do not move; proven bit-exact on the host (B99e).
if [ "$DO_LMSPLIT" -eq 1 ]; then
  LS_IR="$RUN/ir_lmsplit"; rm -rf "$LS_IR"; mkdir -p "$LS_IR"
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_lmsplit.py" --selftest
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_lmsplit.py" \
      --ir "$IR/graph.json" --weights "$IR/weights.npz" \
      --out "$LS_IR/graph.json" --out-weights "$LS_IR/weights.npz" \
      --report "$RUN/ir_lmsplit_report.json"
  # weights.npz is WRITTEN, not linked: the shards are new tensors and the parent is dropped.
  ln -sfn "$IR/io.npz" "$LS_IR/io.npz"
  IR="$LS_IR"
fi
# THE BATCH DIMENSION, LAST, because it multiplies shapes the two passes above reason about.
# It changes no weights, so weights.npz is LINKED, not rewritten.
# THE HOISTED V-PERMUTE, before the batch pass because that one multiplies leading dims.
# (0,2,1,3)+transpose_b=0 leaves K strided at 36 and pext_dot8_exact falls to scalar;
# (0,2,3,1)+transpose_b=1 makes K contiguous and the 8-wide DOT8 applies.  Bit-exact.
if [ "$DO_VPERM" -eq 1 ]; then
  VP_IR="$RUN/ir_vperm"; rm -rf "$VP_IR"; mkdir -p "$VP_IR"
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_vperm.py" --selftest
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_vperm.py" \
      --ir "$IR/graph.json" --out "$VP_IR/graph.json" --report "$RUN/ir_vperm_report.json"
  for f in weights.npz io.npz; do ln -sfn "$IR/$f" "$VP_IR/$f"; done
  IR="$VP_IR"
fi
# B116: THE OP-KIND SPLIT, LAST OF THE GRAPH PASSES.  It renames only; no dispatch is added,
# removed or reordered, so STEP_END and every H_OFF are untouched and driver_meta.h must come
# out byte-identical to the un-split arm's.  --strict: a selected site the lane cannot express
# is an ERROR here rather than a silent `layernorm_s8` that would then take the OTHER pick.
if [ -n "$LN_SPLIT" ]; then
  LN_IR="$RUN/ir_lnsplit"; rm -rf "$LN_IR"; mkdir -p "$LN_IR"
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_lnsplit.py" --selftest \
      --verify-c "$RUN/ir_lnsplit.cverify"
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_lnsplit.py" \
      --ir "$IR/graph.json" --weights "$IR/weights.npz" \
      --out "$LN_IR/graph.json" --out-weights "$LN_IR/weights.npz" \
      --prefix "$LN_SPLIT" --strict --verify-c "$RUN/ir_lnsplit.cverify" \
      --report "$RUN/ir_lnsplit_report.json"
  # weights.npz is WRITTEN, not linked: three integer tables per rewritten site are new and the
  # float gamma/beta they replace are dropped.
  ln -sfn "$IR/io.npz" "$LN_IR/io.npz"
  IR="$LN_IR"
fi
IR_UNBATCHED="$IR"
if [ "$BATCH_DECODE" -gt 1 ]; then
  B_IR="$RUN/ir_b$BATCH_DECODE"; rm -rf "$B_IR"; mkdir -p "$B_IR"
  if [ -n "$REGBATCH" ]; then
    # B129.  THE REGION-SCOPED PASS.  Its selftest is run here, unconditionally and before
    # the graph, for the reason B127 wrote it down: the check that says "no encoder op's
    # shape moved" was validated by injecting exactly that defect, and a selftest nobody
    # runs is a comment.
    run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_regbatch.py" --selftest
    run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_regbatch.py" \
        --ir "$IR/graph.json" --out "$B_IR/graph.json" -B "$BATCH_DECODE" \
        --mode "$REGBATCH" --report "$RUN/ir_regbatch_report.json"
  else
    run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_batch.py" --selftest
    run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/ir_batch.py" \
        --ir "$IR/graph.json" --out "$B_IR/graph.json" -B "$BATCH_DECODE" \
        --report "$RUN/ir_batch_report.json"
  fi
  for f in weights.npz io.npz; do ln -sfn "$IR/$f" "$B_IR/$f"; done
  IR="$B_IR"
  # A BATCHED GRAPH IS NOT SAFE AS A REPLAY IMAGE: generate_skeleton bakes test_input/
  # test_golden at io.npz's B=1 size into a graph declaring B times that, so --replay would
  # read past the end of its own input and compare against a short golden -- and produce a
  # number.  ir_batch reports replay_safe:false; this is the refusal.
  [ "$REPLAY" -eq 0 ] || die "--replay and --batch-decode $BATCH_DECODE are incompatible: the baked test vectors are B=1 sized (ir_batch report replay_safe:false)"
fi
# driver_meta.h FROM THE IR THAT IS ACTUALLY BEING BUILT.  STEP_END is a list of DISPATCH
# INDICES; the CSE rewrite renumbers them, and a stale one is wrong tokens with nothing raising.
run "$PY" "$MOON/emit_driver_meta.py" --ir "$IR/graph.json" --out "$RUN/driver_meta.h"
echo "$IR" > "$RUN/ir_used.txt"
echo "${IR_UNBATCHED:-$IR}" > "$RUN/ir_unbatched.txt"

lane_align_buffers "$WANT_MAGIC"
rm -rf "$GEN"; mkdir -p "$GEN"
ln -sfn "$IR" "$RUN/ir"
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_skeleton \
    --ir "$IR/graph.json" --weights "$IR/weights.npz" --io "$IR/io.npz" \
    --out-dir "$GEN" --backend roccmoon ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_skeleton failed"; }
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_kernels \
    --ir "$IR/graph.json" --out-dir "$GEN" --backend reference --target roccmoon \
    --quant int8 --io "$IR/io.npz" --repo-root "$MB" --build-dir "$RUN/gen.kverify" \
    --harness-dir "$MB/harness" --cache-dir "$RUN/gen.cache" --algorithms all \
    --global-curated-dir "$CUR" ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_kernels failed"; }
need_file "$GEN/kernels.c" "codegen produced no kernels"
cp "$RUN/driver_meta.h" "$GEN/driver_meta.h"
"$PY" - "$GEN/kernel_picks.json" "$SILU_INT" "${E2E_ENC:-}" "$LN_LANE" "${LN_SPLIT:-}" <<'PYP' || die "the curated tree did not select what this lab needs"
import json, sys
p = json.load(open(sys.argv[1]))["picks"]
want = {"softmax_s8": "pext_int_memo2", "permute4_s8": "pext_block",
        "linear_s8": "roccmoon_engine",
        "silu_s8": "pext_int_lut" if int(sys.argv[2]) else "pext_memo_lut",
        "cat2_c1_s8": "pext_memo_lut"}
# B114: the encoder half's five, asserted BOTH ways.  A merged image that quietly took a
# different kernel for conv2d, the LUT ops or the attention lane would produce a clean number
# for a machine nobody configured -- and `layernorm_s8` is asserted at the DECODER bank's pick
# precisely because the encoder bank's is the other one.
if sys.argv[3]:
    want.update({"conv2d_s8": "roccmoon_engine", "gelu_s8": "roccmoon_lut",
                 "tanh_s8": "roccmoon_lut", "attention_s8": "roccmoon_lane",
                 "groupnorm_s8": "pext_int_rsqrt"})
# B115: layernorm_s8 is the one pick the two banks disagree on, so it is asserted from the
# FLAG and in both directions -- never defaulted.  --ln-lane 1 is the ENCODER bank's kernel
# (roccmoon_lane), 0 is the DECODER bank's (pext_int_rsqrt).  An arm that silently took the
# other one is the whole failure this lab exists to measure against.
# Guarded on presence only so a graph WITHOUT the op cannot be failed by an assertion about
# a kernel it never selects; when the op is there the assertion is unconditional.
if "layernorm_s8" in p:
    want["layernorm_s8"] = "roccmoon_lane" if int(sys.argv[4]) else "pext_int_rsqrt"
# B116: WITH THE SPLIT, BOTH KINDS ARE ASSERTED AND THEY MUST DISAGREE.  That is the whole
# point of the pass, so an arm in which they agree -- either because the rename did not happen
# or because the curated tree offered only one of the two kernels -- is a refusal here.
if len(sys.argv) > 5 and sys.argv[5]:
    if "layernorm_pc_s8" not in p:
        print("    THE SPLIT DID NOT REACH THE CODEGEN: no layernorm_pc_s8 in kernel_picks.json")
        sys.exit(1)
    want["layernorm_pc_s8"] = "roccmoon_lane"
    want["layernorm_s8"] = "pext_int_rsqrt"
bad = [(k, v, p.get(k, {}).get("algorithm")) for k, v in want.items()
       if p.get(k, {}).get("algorithm") != v]
for k, v in sorted(p.items()):
    print("    %-18s %-14s %s" % (k, v.get("source"), v.get("algorithm")))
for k, v, got in bad:
    print("    WRONG PICK %s: wanted %s, got %s" % (k, v, got))
sys.exit(1 if bad else 0)
PYP
# THE SELECTION, WRITTEN DOWN SO A DIFF CAN SEE IT -- scripts/57:1108's rule, which this
# script did not follow: "Anything that selects a KERNEL rather than a MACRO belongs here."
# B99 spent a board round attributing a 7.79x silu difference to DATA when it was memo_lut
# against int_lut, and scripts/58:560 records the same trap from 2026-09-18: two arms matching
# on soc_magic, bitstream_md5 AND roccmoon_md5, each asserting its own silu pick, both
# assertions passing, and nothing comparing the arms to each other.  An assertion checks one
# arm against its own intent; this file is what lets two arms be compared.
{ echo "silu_sel=$([ "$SILU_INT" -eq 1 ] && echo pext_int_lut || echo pext_memo_lut)"
  echo "layernorm_sel=$([ "$LN_LANE" -eq 1 ] && echo roccmoon_lane || echo pext_int_rsqrt)"
  echo "ln_split=${LN_SPLIT:-none}"
  echo "lmsplit=$DO_LMSPLIT"
  echo "vperm=$DO_VPERM"
  echo "batch_decode=$BATCH_DECODE"
  echo "regbatch=${REGBATCH:-none}"
  echo "cse=$DO_CSE"
  echo "ir=$IR"
  # HASH THE SELECTION, NOT THE FILE: kernel_picks.json embeds an absolute path per op that
  # carries the run name, so its md5 differs for every run and compares nothing.
  echo "kernel_picks_digest=$("$PY" -c 'import hashlib,json,sys;p=json.load(open(sys.argv[1]))["picks"];print(hashlib.md5(";".join("%s=%s/%s"%(o,p[o].get("source"),p[o].get("algorithm")) for o in sorted(p)).encode()).hexdigest())' "$GEN/kernel_picks.json" 2>/dev/null || echo unavailable)"
} > "$RUN/kernel_selectors.txt"
info "kernel_selectors: $(tr '\n' ' ' < "$RUN/kernel_selectors.txt")"

fi

# ============================================================================================
# 2  THE HOST REFERENCE -- the token sequences the board must reproduce
# ============================================================================================
if [ "$DO_HOSTREF" -eq 1 ]; then
# THE HOST REFERENCE IS A B=1 PROGRAM AND MUST COME FROM A B=1 GEN.
# dec_driver.c reads step k's logits at `outbuf + k*VOCAB` and writes step k+1's embedding at
# `inbuf + H_OFF[k+1]` -- one row, no B anywhere.  Built against a --batch-decode gen it gets
# MODEL_INPUT_SIZE = B*577,152 and writes in.bin records B times too large, which then slices
# into images B times too large.  B99 hit exactly that: a 443 MB in.bin for 96 utterances and
# a 147 MB slice for 32.  Refused here rather than left to surface as a size mismatch three
# stages later.
if [ "$BATCH_DECODE" -gt 1 ]; then
  die "--hostref and --batch-decode $BATCH_DECODE are incompatible: dec_driver.c is a B=1
       program and needs a B=1 gen.  Build the reference in its own run WITHOUT
       --batch-decode (same --lmsplit/--vperm/--silu-int so the kernels match) and copy
       hostref/{in.bin,tok.bin,tok.bin.vals,emb.f32} across.  The gate is that the board at
       B reproduces the host at B=1 per sequence, so the reference MUST be B=1."
fi
step "2/5  the host reference: dec_driver on $N_UTT utterances"
PRO_FLAG=""; [ "$PRO_INT8" -eq 0 ] || PRO_FLAG="--pro-int8"
# B114: with the encoder IN the graph there is no `enc` field to pack and no --enc to run --
# the host driver runs the whole chain from the audio window, exactly as the board does.
if [ -n "$E2E_ENC" ]; then
  PRO_FLAG="--e2e"
  [ -z "$ENC_GEN" ] || die "--e2e and --enc are exclusive: the encoder is IN the graph, so a
       second encoder run would be packed over its own output"
fi
need_file "$GEN/model.c" "run --gen first"
need_file "$GEN/driver_meta.h"
# dec_driver_tok.c: dec_driver.c's loop, byte for byte, plus a sidecar file carrying the
# per-step argmax VALUE as well as its index -- the thing that makes a token match checkable
# rather than coincidental.
cp "$MOON/dec_driver_tok.c" "$HREF/dec_driver_tok.c"
CCSW="$IISWC_ROOT/fpga/pynq-z2/sw"
SHIM="$IISWC_ROOT/fpga/pynq-z2/modelblaster/check/shim"
if [ ! -f "$HREF/weights.o" ] || [ "$HREF/weights.o" -ot "$GEN/weights.c" ]; then
  run cc -O0 -c -w -I"$GEN" "$GEN/weights.c" -o "$HREF/weights.o"
fi
run cc -O2 -w -std=gnu11 -ffp-contract=off -DMB_PEXT_HW=0 \
    -I"$SHIM" -I"$GEN" -I"$CCSW" \
    "$HREF/dec_driver_tok.c" "$GEN/model.c" "$GEN/kernels.c" "$GEN/buffers.c" "$GEN/test_io.S" \
    "$HREF/weights.o" -o "$HREF/dec_driver_tok" -lm
# transformers 4.48.0 is the version that HAS MoonshineForConditionalGeneration, and it lives
# in $MOONSHINE_DIR/pylib rather than in the conda env (which carries 4.47.1 and does not).
# scripts/50 and scripts/53 reach it the same way; putting it FIRST is what makes the import
# resolve to it rather than to the env's older copy.
( cd "$MOON" && PYTHONPATH="$MOONSHINE_DIR/pylib:$PYTHONPATH" \
  "$PY" "$MOON/model_dec_run.py" --n "$N_UTT" --ir "$RUN/ir" \
    --exe "$HREF/dec_driver_tok" --work "$HREF" --json "$HREF/host_dec_run.json" \
    ${ENC_GEN:+--enc "$ENC_GEN"} ${PRO_FLAG} ) 2>&1 | tee "$RUN/hostref.log"
need_file "$HREF/in.bin"; need_file "$HREF/tok.bin"; need_file "$HREF/emb.f32"
need_file "$HREF/tok.bin.vals"
fi

# ============================================================================================
# 3  THE IMAGE -- the same generated graph, with the driver on the board
# ============================================================================================
if [ "$DO_IMAGE" -eq 1 ]; then
step "3/5  $([ "$REPLAY" -eq 1 ] && echo 'the REPLAY image (baked golden, max_abs_err)' || echo 'the autoregressive image')"
if [ "$REPLAY" -eq 1 ]; then
  # No ar_io.S, no embedding table, no baked utterances: the replay image carries the
  # generated model and its own baked input/golden (test_io.S) and nothing else, so it is
  # ~20 MB rather than ~121 and cannot reach the engine arena.
  need_file "$GEN/model.c" "run --gen first"
  CF=$(cd "$ZCS" && "$PY" -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['roccmoon'].kernel_cflags))")
  if [ -n "$E2E_ENC" ]; then
    CF="$CF -DMBXR_RT_LUT=1 $KCF_ALL -DMBP_B74=1 -DMBP_B86=1 -DMBP_B87=1 -DMBP_B86D=1 -DMBP_B101L=1 -DMBP_B102=1 -DMBP_B101U=1 -DMBP_B103=1 $CAP_CFLAG$NCH_CFLAG_SP $PLACE_EARLY_CFLAG${MB_KCF_EXTRA:+ $MB_KCF_EXTRA}"
  else
    CF="$CF -DMBXR_LUT_LANE=0 $KCF_ALL $CAP_CFLAG$NCH_CFLAG_SP $PLACE_EARLY_CFLAG${MB_KCF_EXTRA:+ $MB_KCF_EXTRA}"
  fi
  run west build -p "$PRISTINE" -b "$BOARD" "$IISWC_ROOT/samples/modelblaster_pext" \
      -d "$AR/build_replay" -- \
      ${E2E_ENC:+-DMB_HARNESS_CFLAGS="-DMBXR_RT_LUT=1"} \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$GEN" -DMB_ITERS="$REPLAY_ITERS" \
      -DMB_WARMUP="$REPLAY_WARMUP" \
      -DMB_JOIN_TIMEOUT_S=7200 -DMODELBLASTER_KERNEL_CFLAGS="$CF" >> "$RUN/build.log" 2>&1 \
    || { tail -60 "$RUN/build.log"; die "west build (replay) failed"; }
  cp "$AR/build_replay/zephyr/zephyr.elf" "$AR/zephyr_replay.elf"
  cp "$AR/build_replay/zephyr/zephyr.bin" "$AR/zephyr_replay.bin"
  echo "$CF" > "$AR/kernel_cflags.txt"
  grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ\$" "$AR/build_replay/zephyr/.config" \
    || die "guest clock mismatch on the replay image: board '$BOARD' built $(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$AR/build_replay/zephyr/.config"), --fclk $FCLK_CORE needs $GUEST_KHZ"
  info "replay image: $(fsize "$AR/zephyr_replay.bin") ($(stat -c %s "$AR/zephyr_replay.bin") bytes)"
else
need_file "$HREF/in.bin" "run --hostref first"
IN_BYTES=$("$PY" -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(m['provenance']['packed_bytes_per_utterance'])" "$HREF/host_dec_run.json")
SFX=""; [ -z "$BATCH" ] || SFX="_b$BATCH"
"$PY" - "$HREF/in.bin" "$HREF/emb.f32" "$AR/ar_io$SFX.S" "$N_UTT" "$IN_BYTES" "$RUN/driver_meta.h" \
      "$AR/footprint$SFX.json" "${BATCH:--1}" "${BATCH_SIZE:--1}" "$AR/in$SFX.bin" \
      "$AR/batch$SFX.json" "$BATCH_DECODE" "$(cat "$RUN/ir_unbatched.txt" 2>/dev/null || echo "$IR")" \
      "$HREF/tok.bin" <<'PYS' || die "could not bake the AR io"
import json, os, re, sys
import numpy as np
inp, emb, outs, n, nb, meta, fp = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6], sys.argv[7]
batch, bsize, slicep, bjson = int(sys.argv[8]), int(sys.argv[9]), sys.argv[10], sys.argv[11]
B, ir_unbatched, tokbin = int(sys.argv[12]), sys.argv[13], sys.argv[14]
inp0 = inp                      # the WHOLE in.bin, before any slicing -- the batched baker
                                # re-reads it by global utterance id, not by slice position
m = dict(re.findall(r"#define (\w+)\s+(\d+)", open(meta).read()))
vocab, dhid = int(m["VOCAB"]), int(m["DHID"])
N_STEPS_META = int(m["N_STEPS"])
want_emb = vocab * dhid * 4
got_emb = os.path.getsize(emb)
if got_emb != want_emb:
    sys.exit("emb.f32 is %d bytes, not VOCAB*DHID*4 = %d" % (got_emb, want_emb))
got_in = os.path.getsize(inp)
if n and got_in != n * nb:
    sys.exit("in.bin is %d bytes, not %d utterances x %d = %d" % (got_in, n, nb, n * nb))
if got_in % nb:
    sys.exit("in.bin is %d bytes, not a whole number of %d-byte utterances" % (got_in, nb))
n_all = got_in // nb
# THE SLICE.  Written as its own file rather than an offset into in.bin because .incbin takes
# a whole file: the image must carry these utterances and no others, and a wrong offset would
# be a silent comparison against the wrong host tokens.
if batch >= 0:
    off = batch * bsize
    if off >= n_all:
        sys.exit("batch %d starts at utterance %d and there are only %d" % (batch, off, n_all))
    cnt = min(bsize, n_all - off)
    with open(inp, "rb") as fi, open(slicep, "wb") as fo:
        fi.seek(off * nb)
        fo.write(fi.read(cnt * nb))
    # `ids` IS THE JOIN KEY, AND IT IS WRITTEN EVEN THOUGH IT IS THE IDENTITY TODAY.
    # The scorer used to place a board utterance at `offset + u`, which is the global id only
    # while this slice is contiguous and in corpus order.  A baker that REORDERS utterances
    # (length-sorted batching, B99) keeps that arithmetic unique and makes it wrong, so the
    # duplicate guard still passes and the board is scored against another utterance's host
    # tokens with nothing raising.  Writing the permutation the baker actually used -- here
    # range(off, off+cnt) -- means the reordering baker only has to fill this list, and the
    # scorer never has to infer a position again.
    ids = list(range(off, off + cnt))
    assert len(set(ids)) == len(ids) == cnt, "batch %d: ids are not %d unique" % (batch, cnt)
    json.dump({"batch": batch, "offset": off, "count": cnt, "of": n_all, "ids": ids},
              open(bjson, "w"))
    inp, n = slicep, cnt
    print("    batch %d: utterances %d..%d of %d" % (batch, off, off + cnt - 1, n_all))
else:
    n = n_all
    ids = list(range(n_all))

# ---- B > 1: THE GROUPED, LENGTH-SORTED LAYOUT -------------------------------------------
# Two things change at once and they are independent:
#   (a) LAYOUT.  At B the graph's packed input holds, per field, the group's B sequences
#       ADJACENT -- it is NOT B per-utterance blobs concatenated.  So a group is written by
#       walking the 36 fields of the B=1 table and emitting each field for every member.
#   (b) ORDER.  A batch runs until its LONGEST member finishes, so grouping by length is
#       what keeps the waste near 1 (B99 step 2: 1.0035 sorted against 1.1773 arbitrary at
#       B=2).  The step counts come from the HOST driver's tok.bin, which exists before the
#       image is built, so the sort is free and needs no extra pass.
# The permutation goes into `ids`, which the scorer joins on -- never on position.
if B > 1:
    if n % B:
        sys.exit("this image carries %d utterances, not a whole number of batches of %d" % (n, B))
    fields = json.load(open(os.path.join(ir_unbatched, "graph.json")))["input"]["packed_inputs"]
    if sum(f["size"] for f in fields) != nb:
        sys.exit("the B=1 field table sums to %d, not the %d-byte utterance stride"
                 % (sum(f["size"] for f in fields), nb))
    raw = np.fromfile(tokbin, dtype=np.int32).reshape(-1, 1 + N_STEPS_META)
    if raw.shape[0] != n_all:
        sys.exit("tok.bin has %d utterances, the set has %d" % (raw.shape[0], n_all))
    steps = {g: int(raw[g, 0]) for g in ids}
    order = sorted(ids, key=lambda g: (steps[g], g))      # ties by id: deterministic
    src = open(inp0, "rb")
    with open(slicep, "wb") as fo:
        for gi in range(0, len(order), B):
            grp = order[gi:gi + B]
            for f in fields:
                for g in grp:
                    src.seek(g * nb + f["offset"])
                    blk = src.read(f["size"])
                    if len(blk) != f["size"]:
                        sys.exit("short read for utterance %d field %s" % (g, f["name"]))
                    fo.write(blk)
    src.close()
    ids = order
    assert len(set(ids)) == len(ids) == n, "batched ids are not %d unique" % n
    d = json.load(open(bjson)) if os.path.exists(bjson) else {"batch": batch, "of": n_all}
    d.update({"count": n, "ids": ids, "batch_decode": B,
              "group_steps": [max(steps[g] for g in order[i:i + B]) for i in range(0, n, B)]})
    json.dump(d, open(bjson, "w"))
    inp = slicep
    print("    batch-decode B=%d: %d utterances in %d groups, length-sorted; "
          "batch-steps %d against %d sequence-steps"
          % (B, n, n // B, sum(d["group_steps"]), sum(steps[g] for g in ids)))
with open(outs, "w") as f:
    f.write("""/* @generated by scripts/74_rocket_moonshine_tokens_board.sh -- do not edit.
 *
 * The two things an autoregressive decoder image needs that the replay image does not:
 * the utterances to decode, and the embedding table a chosen token is looked up in.
 * .incbin rather than C literals -- the table is %d x %d float32 = %.1f MB, which is
 * ~%.0f MB of C source and a compile nobody wants to sit through.
 */
    .section .rodata
    .align 4
    .globl  mb_ar_in
    .type   mb_ar_in, @object
mb_ar_in:
    .incbin "%s"
    .size   mb_ar_in, . - mb_ar_in
    .align 4

    .globl  mb_ar_emb
    .type   mb_ar_emb, @object
mb_ar_emb:
    .incbin "%s"
    .size   mb_ar_emb, . - mb_ar_emb
    .align 4
""" % (vocab, dhid, want_emb / 1e6, want_emb * 4 / 1e6, os.path.abspath(inp), os.path.abspath(emb)))
json.dump({"emb_bytes": got_emb, "inputs_bytes": n * nb, "utterances": n,
           "bytes_per_utterance": nb, "vocab": vocab, "dhid": dhid,
           "batch": batch if batch >= 0 else None}, open(fp, "w"), indent=1)
print("    ar_io.S: %.2f MB embedding + %d x %d B inputs = %.2f MB of .rodata"
      % (got_emb / 1e6, n, nb, (got_emb + n * nb) / 1e6))
PYS
THIS_N="$("$PY" -c "import json,sys;print(json.load(open(sys.argv[1]))['utterances'])" "$AR/footprint$SFX.json")"

CF=$(cd "$ZCS" && "$PY" -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['roccmoon'].kernel_cflags))")
# MB_KCF_EXTRA: THE KERNEL FEATURE MACROS THIS HARNESS DOES NOT KNOW ABOUT.
# scripts/57 and 58 pass per-campaign -DMBP_* defines (MBP_B76, MBP_MMB_M1_UNROLL8, ...) that
# today's generated kernels.c reads in 51 places and that B57's did not contain at all.  This
# script set none of them, so it compiled the macro-OFF default branch of every one -- a branch
# no board arm exercises, because every arm turns them on.  That is B96's stale-CAP-list shape
# one macro along: the same script name selecting a different lever.  Until the defines are
# tracked properly, they are at least REACHABLE and RECORDED in kernel_cflags.txt.
# B114: ONE IMAGE, ONE SET OF KERNEL CFLAGS, AND IT IS THE UNION -- PRE-REGISTERED, NOT DISCOVERED.
#   from the ENCODER bank (out/b103_fold_0035_f40): -DMBXR_RT_LUT=1 (compiles the LUT-lane arm
#     into the hart-1 worker -- gelu_s8 and tanh_s8 need it and the decoder has neither op, but
#     it grows mbxr_rt_worker and therefore touches EVERY engine dispatch), MBP_B74/B87/B103
#     (rope_s8 and add_s8 -- ops the DECODER also runs, so these are the flags that move the
#     decoder half), MBP_B86/B86D/B101L/B101U (attention_s8 only: the decoder has none),
#     MBP_B102 (conv2d_s8 arms it; inert elsewhere).
#   from the DECODER bank: -DMBP_MMB_M1_UNROLL8=1 (matmul_b_s8's M=1 path; the encoder's
#     matmul_b are all fused into attention_s8, so inert there), -DMBP_B76=1 (both).
#   -DMBXR_LUT_LANE=0 IS NOT PASSED, which is the whole point: with it, gelu and tanh still
#     PICK roccmoon_lut and then take the fallback at 19.34 cycles/element.
if [ -n "$E2E_ENC" ]; then
  LUT_CFLAG="-DMBXR_RT_LUT=1"
  E2E_KCF="-DMBP_B74=1 -DMBP_B86=1 -DMBP_B87=1 -DMBP_B86D=1 -DMBP_B101L=1 -DMBP_B102=1 -DMBP_B101U=1 -DMBP_B103=1"
  HARNESS_CF="-DMBXR_RT_LUT=1"
else
  LUT_CFLAG="-DMBXR_LUT_LANE=0"
  E2E_KCF=""
  HARNESS_CF=""
fi
# MB_HCF_EXTRA: THE HARNESS (main.c) DEFINES THIS SCRIPT DOES NOT KNOW ABOUT.
# MB_KCF_EXTRA has existed since B96 for the KERNEL side and there was no counterpart for the
# driver, so a lab that needed one (B126 reached -DMB_B126 through b126_repair.sh's own west
# build, outside this file) had to bypass this script entirely -- and then its kernel cflags,
# its gates and its report were a different program's.  B129 needs -DMB_ENC_DISPATCHES and
# -DMB_ENC_BUF to reach main.c and nothing else, so it gets a hook rather than a fork.
# It is RECORDED in kernel_selectors.txt below, because a define that is not written down is
# a lever with no name.
HARNESS_CF="${HARNESS_CF}${MB_HCF_EXTRA:+ $MB_HCF_EXTRA}"
HARNESS_CF="$(echo $HARNESS_CF)"
CF="$CF $LUT_CFLAG $KCF_ALL${E2E_KCF:+ $E2E_KCF} $CAP_CFLAG$NCH_CFLAG_SP $PLACE_EARLY_CFLAG${MB_KCF_EXTRA:+ $MB_KCF_EXTRA}"
run west build -p "$PRISTINE" -b "$BOARD" "$IISWC_ROOT/samples/modelblaster_pext" -d "$AR/build" -- \
    ${HARNESS_CF:+-DMB_HARNESS_CFLAGS="$HARNESS_CF"} \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$GEN" -DMB_ITERS=1 -DMB_WARMUP=0 \
    -DMB_JOIN_TIMEOUT_S=7200 -DMB_DEC_AR=1 -DMB_AR_UTTS="$THIS_N" -DMB_AR_ROWS_UTT="$ROWS_UTT" \
    -DMB_AR_BATCH="$BATCH_DECODE" \
    -DMB_AR_IO="$AR/ar_io$SFX.S" -DMODELBLASTER_KERNEL_CFLAGS="$CF" >> "$RUN/build.log" 2>&1 \
  || { tail -60 "$RUN/build.log"; die "west build failed"; }
cp "$AR/build/zephyr/zephyr.elf" "$AR/zephyr$SFX.elf"
cp "$AR/build/zephyr/zephyr.bin" "$AR/zephyr$SFX.bin"
# B96: ONLY WHEN THERE IS A SUFFIX.  SFX is "" unless --batch is given (L330), so on the
# UN-BATCHED path these two lines were `cp X X`, which cp refuses, and set -e killed the
# run at stage 3/5 before the board was ever touched.  The batched path -- the only one
# B85 ever used -- was fine, so this sat unnoticed: a line that was correct for the path
# it was written for and silently broke the other one.
[ -z "$SFX" ] || { cp "$AR/zephyr$SFX.elf" "$AR/zephyr.elf"; cp "$AR/zephyr$SFX.bin" "$AR/zephyr.bin"; }
echo "$CF" > "$AR/kernel_cflags.txt"
# B118: THE TWO STAGING FLAGS, IN kernel_selectors.txt, READ OUT OF THE LINKED ELF.
#
# scripts/57:1113 has emitted `drain_strided=` since B26 and THIS FILE NEVER DID, so the one
# line that would have shown the encoder bank and the combined image to be differently
# configured was missing from exactly one of the two records.  B114 built the combined image
# from "the union of the two banks' kernel cflags" and the union it took was the MBP_* macros
# and MBXR_RT_LUT; -DMBXR_RT_DRAIN_STRIDED=1 and -DMBXR_RT_STAGE_BLOCK=1 live in scripts/57's
# KCF_ALL, are carried by every encoder arm (b103, b114_enc_ctl_board) and by b112_pro_stage,
# and were dropped.  That is the whole of B114's "engine and staging regression", and no diff
# of the two runs' kernel_selectors.txt could have shown it because the line did not exist.
#
# READ FROM THE ELF, NOT FROM $CF, for mbxr_rt.h:266's reason: mbxr_rt_pick() asks the engine
# for MBXR_ID_STRIDE at run time and takes the FLAT drain on silicon that lacks it, so the
# flag that asked is not the fact.  MBXR_RT_STAGE_BLOCK has no ABI stamp; its own fact is the
# size of the generated conv kernel (744 B without it, ~1,802 B with it and MBP_B102), which
# b118_stage.py reads.  Rewritten rather than appended so --image twice is idempotent.
{ grep -v '^drain_strided=\|^kernel_cflags_md5=\|^harness_cflags=' "$RUN/kernel_selectors.txt" 2>/dev/null
  echo "drain_strided=$(grep -ao 'MBXR_ABI:v2:strided=[01]' "$AR/zephyr$SFX.elf" 2>/dev/null | head -1 | sed 's/.*=//')"
  echo "kernel_cflags_md5=$(printf '%s' "$CF" | md5sum | cut -d' ' -f1)"
  echo "harness_cflags=${HARNESS_CF:-none}"
} > "$RUN/kernel_selectors.txt.new" && mv -f "$RUN/kernel_selectors.txt.new" "$RUN/kernel_selectors.txt"
printf '%s\n' "${HARNESS_CF:-}" > "$AR/harness_cflags.txt"
info "kernel_selectors: $(tr '\n' ' ' < "$RUN/kernel_selectors.txt")"
# THE IMAGE CARRIES THE UTTERANCES IT SAYS IT DOES.  With --no-pristine a stale .incbin is the
# obvious way to compare a board run against the wrong host tokens and see nothing wrong, so
# the symbol's SIZE in the linked ELF is checked against the slice that was just written.
# THE IMAGE CARRIES THE BYTES IT SAYS IT DOES -- checked by CONTENT, not by size.
# Every batch is the same number of utterances, so a size check cannot tell batch 1's slice
# from batch 0's, and with --no-pristine a stale .incbin is precisely how a board run gets
# compared against the wrong host tokens with nothing raising.  So the `mb_ar_in` bytes are
# read back out of the linked flat image and md5'd against the slice that was just written.
# B96: THE SLICE ONLY EXISTS WHEN BATCHED.  The ar_io baker writes "$AR/in$SFX.bin" under
# `if batch >= 0`, so on the un-batched path there is no slice and the bytes the image
# carries are the WHOLE "$HREF/in.bin".  This guard read the slice unconditionally and
# died with FileNotFoundError -- the second un-batched break from the same batching
# change, in the same guard, and like the first it never reached the board.
# B99: AND THE BATCHED BAKER ALSO WRITES A SLICE WITHOUT A SUFFIX.  At --batch-decode > 1 the
# baker rewrites the whole set into the GROUPED, length-sorted layout and puts it in
# "$AR/in.bin", so "$HREF/in.bin" is no longer what the image carries -- same bytes, different
# order.  This guard md5s the image against its reference and CAUGHT that, correctly: the size
# check passed (the total is unchanged) and only the content check could see it.
IMG_IN="$AR/in$SFX.bin"
{ [ -n "$SFX" ] || [ "$BATCH_DECODE" -gt 1 ]; } || IMG_IN="$HREF/in.bin"
"$PY" - "$AR/zephyr$SFX.elf" "$AR/zephyr$SFX.bin" "$IMG_IN" "$NM" \
      "$(( THIS_N * IN_BYTES ))" "$THIS_N" <<'PYV' || die "the linked image does not carry the
       batch that was just written -- see above.  Rebuild with -p always."
import hashlib, subprocess, sys
elf, binf, slicef, nm, want, n = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
sym = [l.split() for l in subprocess.run([nm, "-S", elf], capture_output=True, text=True)
       .stdout.splitlines() if l.split()[-1:] == ["mb_ar_in"]]
if not sym:
    sys.exit("    no mb_ar_in symbol in %s" % elf)
addr, size = int(sym[0][0], 16), int(sym[0][1], 16)
if size != want:
    sys.exit("    mb_ar_in is %d bytes in the ELF, wanted %d (%d utterances)" % (size, want, n))
def md5_range(path, off, nbytes):
    h = hashlib.md5()
    with open(path, "rb") as f:
        f.seek(off)
        while nbytes:
            b = f.read(min(1 << 22, nbytes))
            if not b:
                sys.exit("    %s is shorter than mb_ar_in claims" % path)
            h.update(b); nbytes -= len(b)
    return h.hexdigest()
a = md5_range(binf, addr - 0x80000000, size)
b = md5_range(slicef, 0, size)
if a != b:
    sys.exit("    mb_ar_in in the image is %s and the slice just written is %s -- the image "
             "carries SOMEONE ELSE'S utterances" % (a[:12], b[:12]))
print("    mb_ar_in: %d bytes = %d utterances, md5 %s -- the image carries this batch"
      % (size, n, a[:12]))
PYV
# --board and --fclk are a PAIR, and this is the check that makes them one.  Was pinned to the
# literal 34483; the hazard is the MISMATCH and not the value.  CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC
# is both mtime's tick and the SiFive UART's baud divisor, so the wrong board here yields a
# GARBLED CONSOLE and an mtime off by the clock ratio, not an error.
grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ\$" "$AR/build/zephyr/.config" \
  || die "guest clock mismatch: board '$BOARD' built CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$AR/build/zephyr/.config"), --fclk $FCLK_CORE needs $GUEST_KHZ"
# ===========================================================================================
# THE ENGINE'S ARENA, AND WHY THIS IMAGE HAS A CEILING AT 128 MB AND NOT 256.
#
# fpga/pynq-z2/sw/roccmoon/mbxr_rt.h:109-115 reserves FIXED PHYSICAL WINDOWS for the engine,
# under a comment that says "far above any ModelBlaster image (256 MB of DRAM at 0x8000_0000)":
#
#   MBXR_RT_IMG_BASE   0x8800_0000   64 MB of cached planar weight images   <-- the ceiling
#   MBXR_RT_IMG_END /
#   MBXR_RT_IN_STAGE   0x8C00_0000   8 MB
#   MBXR_RT_SCRATCH    0x8C80_0000   8 MB, the drain's destination
#   MBXR_RT_OUT_STAGE  0x8D00_0000   8 MB
#   MBXR_RT_ROW_STAGE  0x8D80_0000   8 MB
#
# That comment was true of every image this repository had built: the decoder replay image is
# 19,988,480 bytes and ends at 0x8424_11D0.  It is NOT true of an autoregressive image, which
# carries a 37.75 MB embedding table plus 577,152 bytes per baked utterance.  MEASURED, Lab
# B57: a 255-utterance image ends at 0x8CA5_7650 and therefore puts `mb_ar_emb` at 0x88D5_1A30
# -- INSIDE the weight-image arena the engine writes -- with .bss and the worker stack inside
# IN_STAGE and SCRATCH.  The symptom is not a crash: the engine overwrites the embedding table
# and the model's buffers as it runs, so the board decodes STRUCTURED, PLAUSIBLE, WRONG tokens,
# differently on each run, and only 8 of 255 utterances matched the host.  The guest's own
# checksums of .rodata matched the host's exactly, which is what proved the image was fine and
# the corruption was live.
#
# So this is a HARD REFUSAL, not a warning: an image that reaches 0x8800_0000 must not be run.
# ===========================================================================================
MBXR_IMG_BASE=$((0x88000000))
END_ADDR=$("$NM" "$AR/zephyr$SFX.elf" | awk '$3 == "_end" || $3 == "__bss_end" {print strtonum("0x" $1)}' | sort -n | tail -1)
[ -n "$END_ADDR" ] || die "cannot read _end/__bss_end from $AR/zephyr$SFX.elf"
if [ "$END_ADDR" -ge "$MBXR_IMG_BASE" ]; then
  die "$(printf 'this image ends at 0x%X and the engine writes its weight-image arena from
       0x88000000 (mbxr_rt.h:110).  They OVERLAP, and the failure is silent: the engine
       overwrites the embedding table and the model buffers while it runs, and the board
       decodes plausible wrong tokens.  MEASURED on 2026-09-18 with a 255-utterance image --
       8 of 255 utterances matched the host, and the guest read .rodata correctly, so it is
       live corruption and not a bad image.
       Fixed cost of an AR image is ~65.05 MB, so the ceiling is (0x88000000 - 0x80000000 -
       65.05 MB) / 577,152 = 119 utterances.  Use --batch/--batch-size to stay under it.' "$END_ADDR")"
fi
info "$(printf 'image ends at 0x%X, %.1f MB clear of the engine arena at 0x88000000'         "$END_ADDR" "$(echo "($MBXR_IMG_BASE - $END_ADDR)/1000000" | bc -l)")"

# THE FOOTPRINT, MEASURED RATHER THAN ASSUMED.  The guest's RAM is ram0 = 256 MB at
# 0x8000_0000 (dts/riscv/chipyard/chipyard-riscv.dtsi), not the card's 512 MB.
SIZE_TOOL=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-size' 2>/dev/null | head -1)
MB_SIZE_TOOL="$SIZE_TOOL" "$PY" - "$AR/zephyr$SFX.elf" "$AR/zephyr$SFX.bin" "$AR/footprint$SFX.json" \
    "$RUN/build.log" <<'PYF' || true
import json, os, re, subprocess, sys
elf, binf, fp, blog = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(fp)) if os.path.exists(fp) else {}
d["image_bytes"] = os.path.getsize(binf)
# The AUTHORITATIVE number is the linker's own: it is what would refuse to fit, and it is what
# the map's "Memory region / RAM" line reports against the dts's ram0.  Sections are recorded
# beside it so a reader can see WHERE the bytes are without re-deriving them.
d["ram0_bytes"] = 0x10000000
# THE LAST match, not the first: build.log is appended to across builds, and reporting the
# first one silently attributes an earlier image's footprint to this one.
m = re.findall(r"^\s*RAM:\s+(\d+) B\s+\S+ \S+\s+([\d.]+)%", open(blog).read(), re.M)
if m:
    d["ram_used_bytes"] = int(m[-1][0])
    d["ram_used_pct"] = float(m[-1][1])
tool = os.environ.get("MB_SIZE_TOOL") or "size"
try:
    out = subprocess.run([tool, "-A", elf], capture_output=True, text=True).stdout
    secs = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 2 and not p[0].startswith(".debug") and p[0] not in ("section", "Total"):
            try:
                secs[p[0]] = int(p[1])
            except ValueError:
                pass
    d["sections"] = secs
except Exception as e:
    d["sections_error"] = str(e)
json.dump(d, open(fp, "w"), indent=1)
print("    image %.2f MB; guest RAM %.2f MB of ram0's 256.00 MB (%.2f %%) -- ram0 is 256 MB, "
      "not the card's 512" % (d["image_bytes"] / 1e6, d.get("ram_used_bytes", 0) / 1e6,
                              d.get("ram_used_pct", 0.0)))
PYF
info "image: $(fsize "$AR/zephyr.bin") ($(stat -c %s "$AR/zephyr.bin") bytes)"
"$NM" -S "$AR/zephyr.elf" | awk 'NF == 4 {
    if ($4 == "z_sys_post_kernel") print $4 ":" $1 ":1:u8";
    else if ($4 == "riscv_cpu_boot_flag" || $4 == "riscv_cpu_wake_flag") print $4 ":" $1 ":8:u64";
  }' | tr '\n' ' ' > "$AR/peek_spec.txt"
fi
fi

# ============================================================================================
# 4  THE BOARD
# ============================================================================================
if [ "$DO_BOARD" -eq 1 ]; then
# ===========================================================================================
# THE GOLDEN PRE-FLIGHT -- BEFORE THE BOARD, BECAUSE IT DOES NOT NEED ONE.
#
# Lab B97, 2026-09-19: this arm reported max_abs_err = 70 and I spent FOUR BOARD ARMS on two
# bitstreams at two clocks establishing that the number was identical every time -- which was
# the evidence, not the mystery.  One host compile showed the model does not reproduce its own
# golden with MB_PEXT_HW=0 either.  The board was never the variable, and a `max_abs_err`
# against a golden nobody validated is worse than no number because it looks like a result.
#
# So: a replay arm may not take the board until its gen has reproduced its own golden ON THE
# HOST.  The check is free, it needs no lock, and it names WHICH golden it is holding.
# ===========================================================================================
if [ "$REPLAY" -eq 1 ]; then
  step "4/5  golden pre-flight (host, no board, no lock)"
  "$PY" "$IISWC_ROOT/scripts/lib/golden_preflight.py" "$GEN" \
        --json "$RUN/golden_preflight.json" \
    || die "the golden pre-flight FAILED -- see above.  The board is NOT taken: a board
       max_abs_err would measure this mismatch rather than the machine.  This is B97's
       lesson and it cost four board arms."
fi
step "4/5  the board"
SFX=""; [ -z "$BATCH" ] || SFX="_b$BATCH"
[ "$REPLAY" -eq 0 ] || SFX="_replay"
need_file "$AR/zephyr$SFX.bin" "run --image first"
board_identify
board_gate
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_mic.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_micrgb.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$PYNQ_HOST:$PYNQ_DIR/"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"
# PER-RUN OVERRIDE, NOT A WIDENING.  scripts/lib/bitstream_id.sh is untouched.  1bae0310c1 is
# 0x5A5A002D roccmoonlut2, the build Labs B45, B49..B56 measured this decoder on -- including
# both decoder A/Bs whose records say "4,212 dispatches, max_abs_err = 0, matched".  It is the
# build this image's numerics were validated against; it is not in the shared accepted list
# because that list is the speech labs' and nobody has re-run them against it.
# ROCCMOON_ACCEPTED, the same lever scripts/50, 51, 57 and 58 use, and for the same reason:
# a per-SESSION acceptance for the one build this run measures, never a widening of
# scripts/lib/bitstream_id.sh's shared list and never a global BIT_ACCEPTED.  It was a bare
# hardcoded md5 until 2026-09-19, which is the same stale-list shape B96 found in the CAP
# table two lines up -- one name for the lever, or the next config silently gets the last
# one's gate.  The default is 002D so every B57/B85 rerun gates exactly as it did.
BIT_ACCEPTED="${BIT_ACCEPTED:-} ${ROCCMOON_ACCEPTED:-1bae0310c1e13048b22b4da9c72901ab}"
bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "$GEN/kernel_picks.json" "$(cat "$AR/kernel_cflags.txt" 2>/dev/null)"
run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  >> "$RUN/boot.log" 2>&1 || { tail -20 "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
info "transferring $(fsize "$AR/zephyr$SFX.bin") to the board"
T0=$(date +%s)
run scp -q "$AR/zephyr$SFX.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
info "scp took $(( $(date +%s) - T0 )) s"
info "running (up to $MAXREAD s; the reader stops at the RESULT line)"
# A STALE CONSOLE READER STEALS BYTES FROM THE NEW ONE, AND THE RESULT LOOKS LIKE A BOARD FAULT.
# console.py is started with nohup and a --seconds budget, so a run that is interrupted -- a
# timeout, a Ctrl-C, a killed driver -- leaves it reading /dev/ttyPS1 for up to 90 minutes.  Two
# readers on one serial port each get SOME of the bytes: MEASURED on 2026-09-18, four stale
# readers turned a clean 110-utterance run into `MB_DEC_STEP u=109 k=9 tok==2` and a RESULT line
# split in half, which the driver then waited out as "no result".  The data is not wrong, it is
# SHREDDED, which is worse -- a truncated `ids=` list still parses.
# The bracket in /[c]onsole\.py/ is what stops awk's own command line from matching itself.
"${SSH[@]}" "ps -eo pid,args | awk '/[c]onsole\\.py/ {print \$1}' | xargs -r kill" 2>/dev/null || true
sleep 1
STALE=$("${SSH[@]}" "ps -eo pid,args | awk '/[c]onsole\\.py/ {print \$1}' | wc -l" 2>/dev/null || echo 0)
[ "${STALE:-0}" -eq 0 ] || die "a console reader is still running on the board after a kill --
       two readers on one serial port shred each other's bytes.  Clear it before running."
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $MAXREAD > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $MAXREAD ] && ! grep -q \"^RESULT:\" console.out; do sleep 5; t=\$((t+5)); done
  sleep 2
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t console_bytes=\$(wc -c < console.out)
'" > "$AR/board_side.log" 2>&1 || true
cat "$AR/board_side.log" >> "$RUN/boot.log"
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$AR/console$SFX.txt" 2>/dev/null || true
cp "$RUN/fclk.json" "$AR/fclk.json"
echo "$BIT_MD5" > "$AR/bitstream_md5.txt"
BYTES=$(wc -c < "$AR/console$SFX.txt" 2>/dev/null || echo 0)
[ "${BYTES:-0}" -gt 0 ] || { cat "$AR/board_side.log"
  die "0 console bytes -- the board is wedged or the console path is broken.  STOP board work."; }
info "console: $BYTES bytes, $(grep -c '^MB_DEC_TOKS' "$AR/console$SFX.txt" || true) utterances reported"
[ "$REPLAY" -eq 0 ] || info "replay arm: the utterance count above is 0 by construction -- this image replays a baked trajectory and reports max_abs_err instead"
grep -q '^RESULT:' "$AR/console$SFX.txt" || die "no RESULT line in the console.  Either the guest
       did not finish, or the console was SHREDDED by a second reader on the same serial port --
       check for a truncated last line before blaming the board."
fi

# ============================================================================================
# 5  THE COMPARISON, THE RECORD AND THE VERDICT
# ============================================================================================
if [ "$DO_BOARD" -eq 1 ] && [ "$REPLAY" -eq 1 ]; then
# Handled inside the board stage above for a board run; this guard covers --report-only.
:
fi
if [ "$DO_REPORT" -eq 1 ] && [ "$REPLAY" -eq 1 ]; then
step "5/5  the replay arm: max_abs_err against the baked golden"
export BIT_MD5="${BIT_MD5:-$(cat "$AR/bitstream_md5.txt" 2>/dev/null)}" WANT_MAGIC
"$PY" - "$AR/console_replay.txt" "$RUN/replay.json" "$WANT_MAGIC" "${BIT_MD5:-}" \
      "${IISWC_BOARD:-}" "$CLK_HZ" "$REPLAY_WARMUP" <<'PYR' || die "the replay arm FAILED -- see above"
import json, re, sys
con, out, magic, md5, board, clk = sys.argv[1:7]
warmup = int(sys.argv[7]) if len(sys.argv) > 7 else 0
t = open(con, errors="replace").read()
fail = []
run = re.search(r"^MB_PEXT_RUN .*$", t, re.M)
bld = re.search(r"^MB_PEXT_BUILD model=(\S+) quant=(\S+) ops=(\d+) iters=(\d+) hw=(\d+)", t, re.M)
eng = [dict(re.findall(r"(\w+)=(-?\w+)", l[len("MB_ROCCMOON "):]))
       for l in t.splitlines() if l.startswith("MB_ROCCMOON ")]
tot = next((e for e in eng if e.get("phase") == "total"), {})
mae = None
if not run:
    fail.append("no MB_PEXT_RUN line -- the model never reported")
else:
    m = re.search(r"max_abs_err=(-?\d+)", run.group(0))
    if not m:
        fail.append("MB_PEXT_RUN carries no max_abs_err field")
    else:
        mae = int(m.group(1))
        # -1 is what the AR build reports: "no golden".  A replay image reporting it means
        # the image was built with MB_DEC_AR after all, and 0 of 0 bytes is not a pass.
        if mae < 0:
            fail.append("max_abs_err=%d -- that is the AR build's 'no golden' sentinel, so "
                        "this image is not a replay and nothing was compared" % mae)
        elif mae != 0:
            fail.append("max_abs_err=%d against the baked int8 golden" % mae)
if not bld:
    fail.append("no MB_PEXT_BUILD banner")
if "MB_DEC_TOKS" in t:
    fail.append("this console carries MB_DEC_TOKS lines -- it is an AR image, not a replay")
if not tot:
    fail.append("no MB_ROCCMOON phase=total line -- the engine counters were not captured")
else:
    if int(tot.get("calls_engine", "0") or 0) == 0:
        fail.append("calls_engine = 0 while linear_s8 is dispatched to roccmoon_engine")
    if int(tot.get("calls_fallback", "0") or 0):
        fail.append("the engine fell back %s times" % tot.get("calls_fallback"))
if not re.search(r"^RESULT: PASS", t, re.M):
    fail.append("no 'RESULT: PASS' line")
# THE PER-DISPATCH ROWS.  MB_PEXT_OP is printed by the image and was being thrown away by
# this parser, so a replay arm could say WHETHER the engine was reached and never what any
# dispatch cost.  They are the LAST call of model_run_test(), so with --warmup >= 1 they are
# steady and with --warmup 0 they are COLD and carry the one-time weight-image build; the
# record says which rather than leaving a reader to assume.
rows = [{"dispatch": int(m.group(1)), "name": m.group(2), "op": m.group(3),
         "shape": m.group(4), "cycles": int(m.group(5))}
        for m in re.finditer(r"^MB_PEXT_OP id=(\d+) name=(\S+) op=(\S+) shape=(\S+) "
                             r"cycles=(\d+)", t, re.M)]
warm = next((e for e in eng if e.get("phase") == "warm"), {})
rec = {"arm": "replay (baked trajectory, baked golden)", "board": board or None,
       "soc_magic": magic, "bitstream_md5": md5 or None, "clock_hz": float(clk),
       "max_abs_err": mae,
       "max_abs_err_meaning": "MEASURED against the generated int8 golden over the model's "
       "full output, on a FIXED 24-step trajectory the host chose.  This is the arithmetic "
       "claim and it does NOT imply the token claim: int6 was bit-exact against its own "
       "golden and still moved the tokens.",
       "model": bld.group(1) if bld else None, "quant": bld.group(2) if bld else None,
       "dispatches": int(bld.group(3)) if bld else None,
       "iters": int(bld.group(4)) if bld else None,
       "pext_hw": int(bld.group(5)) if bld else None,
       "engine": tot, "engine_warm": warm, "console_bytes": len(t),
       "warmup": warmup,
       "rows": rows, "rows_are": ("STEADY -- the last of %d timed calls, the one-time engine "
                                  "weight-image build paid in the warm-up before it" % 1
                                  if warmup else
                                  "COLD -- MB_WARMUP=0, so these rows CARRY the one-time "
                                  "engine weight-image build and are not a steady cost"),
       "dispatch_cycles_total": sum(r["cycles"] for r in rows),
       "run_line": run.group(0) if run else None,
       "failures": fail, "verdict": "PASS" if not fail else "FAIL"}
json.dump(rec, open(out, "w"), indent=1)
print("    replay: max_abs_err=%s over %s dispatches, calls_engine=%s calls_fallback=%s -> %s"
      % (mae, rec["dispatches"], tot.get("calls_engine"), tot.get("calls_fallback"),
         rec["verdict"]))
for f in fail:
    print("    FAILURE: %s" % f)
print("    %d per-dispatch rows, %s" % (len(rows), rec["rows_are"][:40]))
sys.exit(0 if not fail else 1)
PYR
snapshot_once
info "out/$NAME/replay.json"
elif [ "$DO_REPORT" -eq 1 ]; then
step "5/5  board tokens against the host driver's"
export BIT_MD5="${BIT_MD5:-$(cat "$AR/bitstream_md5.txt" 2>/dev/null)}" WANT_MAGIC
export MB_WINDOW_S="$WINDOW_S_OPT" N_UTT ROWS_UTT
# TIER 2, BEFORE THE REPORT so the record carries it: WER from the tokens the board chose.
# It needs the tokenizer, which lives in transformers 4.48.0 under $MOONSHINE_DIR/pylib.
if [ "$DO_WER" -eq 1 ]; then
  ( cd "$MOON" && PYTHONPATH="$MOONSHINE_DIR/pylib:$PYTHONPATH" \
    "$PY" "$MOON/b57_board_wer.py" "$RUN" --out "$RUN/board_wer.json" ) \
    2>&1 | tee -a "$RUN/wer.log" || die "the board-token WER step failed"
fi
PRC=0
"$PY" "$IISWC_ROOT/scripts/lib/b57_report.py" "$RUN" || PRC=$?
snapshot_once
RC=0
[ "$PRC" -eq 0 ] || die "report failed (exit $PRC); the run is archived at archive/runs/$NAME"
"$PY" -c "
import json,sys
v=json.load(open(sys.argv[1]))['verdict']
print('    verdict:', v)
sys.exit(0 if v.startswith('PASS') else 1)" "$RUN/run.json" || RC=$?
[ "$RC" -eq 0 ] || die "verdict FAIL -- see out/$NAME/report.txt"
info "out/$NAME/{run.json,report.txt} and archive/runs/$NAME"
fi
