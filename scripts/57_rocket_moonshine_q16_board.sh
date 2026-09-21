#!/usr/bin/env bash
# Lab B30 -- a per-kind dispatch profile of a Moonshine encoder quantisation that TRANSCRIBES,
# on the decoupled RoCC engine.  The measurement ROCC_DECOUPLED.md s8.14's table has never had.
#
#   ./scripts/57_rocket_moonshine_q16_board.sh --build-only                         # 1. no board
#   scripts/with_board.sh ./scripts/57_rocket_moonshine_q16_board.sh --board-only   # 2. board only
#   ./scripts/57_rocket_moonshine_q16_board.sh --selftest fail                      # 3. no board
#   ... --no-place-early   incremental placement OFF; needed to collect against a
#                          placement-off baseline (L302).  ON by default since 2026-09-18
#
# WHY THIS LAB EXISTS.  Every per-kind number the accelerator programme is priced against comes
# from Lab B26's `enc_on` (`b28_enc_run.json`, 518,530,641 steady cycles, RTF 3.759).  That is
# the AS-EXTRACTED int8 encoder, which s8.13 measures at ~120 % WER: it does not transcribe.
# Every RTF for a model that does transcribe -- s8.13's R, R3, F3PR and s8.14's whole re-priced
# table -- is an ESTIMATE, because the q16 candidates are host-only (Lab B27, scripts/53).
# So a lane priced against the as-extracted table is priced against a model nobody would ship.
#
# WHY CANDIDATE R AND NOT F3PR.  F3PR is the best of the three on WER (7.89 % dev against R's
# 8.46 %, `q16_fidelity_*_dev.json`), and it was the obvious ask.  It cannot run on the engine:
# its linears are `linear_s8_pc` and its stem `conv2d_s16_pc`, and the `roccmoon` backend
# registers kernels for exactly two ops -- `linear_s8` and `conv2d_s8`.  An F3PR image is all
# hart 0, which composes with nothing.  Making F3PR engine-capable IS s8.14's (b1), which is not
# built.  R uses `linear_s8` x36 and `conv2d_s8` x24 -- exactly what the engine takes -- and its
# linear shapes (165x288x288, 165x288x1152, 165x1152x288) are the same three Lab B25 measured.
# s8.14 calls it "R: split-dispatch stem, today's engine (a)": this lab measures that row.
#
# WHAT IS MEASURED AND WHAT IS HANDICAPPED.  Reported per kind as ABSOLUTE CYCLES and
# CYCLES PER ELEMENT, not only as shares -- a share moves when any other row moves, and R's
# split stem is large by design (s8.14: "computes every convolution four times").  Two rows are
# handicaps rather than measurements, and the report names them:
#   * layernorm_pc_s8 (13 dispatches) runs as REFERENCE C.  No curated kernel exists for it --
#     `pext_nl_layernorm_pc_s8_*.c` is not in the tree, and every q16 kernel_picks.json selects
#     `reference`.  So this row prices a kernel nobody has written, and the first thing to read
#     off it is whether writing one -- 0 LUT -- captures a large share of what a LayerNorm LANE
#     (2,251 LUT, 20 DSP, 3.0 BRAM) would buy.  That is a different decision from s8.14's.
#   * the stem's NCHW staging.  The engine's conv kernel gathers and scatters at ~32.6
#     cycles/byte (Lab B25 run 8) and R's stem is 24 dispatches.  assign_layouts on R yields 24
#     SINGLE-DISPATCH islands (checked), so the NHWC island that removed staging for the
#     as-extracted stem does not apply here.  `cycles_stage` is reported on its own.
# Everything else is the curated kernel a board would run: softmax at `pext_int_memo2` and
# permute at `pext_block`, both selected the way scripts/50 selects them (a copy of the curated
# tree with the earlier algorithm's file removed, because the curated probe walks
# spec.algorithms in order and does not apply --algorithms).
#
# THE ARCHIVE COMES FIRST.  docs/EXPERIMENT_LOG_RULES.md: a lab's snapshot and health check run
# whatever the verdict says, and 31 of 33 labs never archive at all.  Here the snapshot is on an
# EXIT trap, installed as soon as the run directory exists and idempotent, so a `die` anywhere
# after that point -- in the board step, in the parser, in the scorer -- still leaves the
# evidence in archive/runs/.  The scorer is written INTO the run directory as score.py so how a
# verdict was computed is archived with it, and its status is taken with `|| RC=$?` so no
# pipeline decides this script's fate.  `--selftest fail` exercises exactly that path.
#
# Produces out/<name>/{run.json,report.txt,verdict.txt,score.py,report.py,console.txt,...}.
# It writes NO results.csv row: neither does scripts/50, which is why check_board_column.sh has
# never had anything of Lab B26's to check.  A future row here must go through bwlab_row.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="rocket_moonshine_q16r"
CAND="R"
IR=""
BOARD="chipyard_pynqz1_micrgb"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonall_z1/pynqz1_rocket_micrgb_roccmoonall.bit"
RUNNER="run_rocket_roccmoonall.py"
SAMPLE="$IISWC_ROOT/samples/modelblaster_pext"
WANT_MAGIC="0x5A5A0028"
# THE FEATURE DECLARATION.  Required -- scripts/lib/feature_gate.sh refuses an empty one --
# and it sits here because WANT_MAGIC and this line are the pair that has to agree.  It is
# the WEAKER half of the gate: the half that catches b30_lnab_on is the kernel_picks.json
# this lab hands to feature_gate below, because selection is what decides which hardware
# an image touches.  Override with --requires for an arm that needs more.
LAB_REQUIRES="${LAB_REQUIRES:-rocc_engine pext}"
LUT_LANE=0                         # --lut-lane: gelu_s8 and tanh_s8 on T4's LUT lane
LN_LANE_SEL=0                      # --ln-lane: PER-TENSOR layernorm_s8 on the LayerNorm lane
# The board and the runner go together with the bitstream, and both differ from scripts/50's
# defaults: 0x5A5A0028 is a micrgb SoC, and run_rocket_roccmoonall.py keys its EXPECT_MAGIC off
# its OWN FILENAME (it is a symlink to run_rocket_roccmoon.py).  Using scripts/50's mic defaults
# reads the right MAGIC off the PL and then rejects it -- which is what the first run of this lab
# did, loudly, and the snapshot survived it.
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
ITERS=1
MAXREAD=5400
DO_BOARD=1
BOARD_ONLY=0
REPORT_ONLY=0
SELFTEST=""
KCF_ALL="-falign-loops=4"          # the code-placement mode Lab B26's 0x5A5A0028 session used
# INCREMENTAL PLACEMENT: ON BY DEFAULT.  --no-place-early turns it off.
#
# Measured 2026-09-18 (L302), A/B in one session on 0x5A5A0028 md5 32d10e5d47, candidate R,
# two images differing by exactly this define, both max_abs_err 0 / last_rc 0 / calls_fallback 0
# and the engine work byte-identical (pairs 10,594, loads_wgt 428, fill_beats 12,252,064):
#
#   cycles_h0    164,461,890 -> 126,872,148   -37,589,742  (-22.9 %)
#   per iteration    737.0 M ->     699.5 M   RTF 5.343 -> 5.071  (-5.09 %)
#   cyc_wait      88,438,199 ->  30,804,679   placement moves inside the engine busy window
#   cyc_place     62,153,880 ->  81,980,468   it COSTS MORE per byte: 19.43 interleaved vs 13.31 late
#   placed_early           0 ->   3,238,464   69.4 % of 4,669,632 output bytes
#
# L260 decided in 2026-09-17 that "incremental placement is on for every later build" and no
# script ever set it: KCF_ALL copied -falign-loops=4 from that same session without it.  It was
# then held one round longer to protect in-flight A/B baselines; that hold is lifted because the
# flag is OPT-OUT rather than removed, so an arm collecting against a placement-off baseline can
# still ask for it.
#
# ANY ARM COLLECTING AGAINST A place_early-OFF BASELINE MUST PASS --no-place-early.  The
# attention unit's uncollected number (4.002 -> 2.249, band [2.24, 2.35]) was measured with
# placement off in every arm; its collecting run needs --no-place-early or it is not that A/B.
#
# Pricing note: placement interleaved costs 19.43 cycles per output byte against 13.31 late
# (+46 %), NOT the +23.6 % inherited from b58a15c.  docs/EXPERIMENT_LOG_RULES.md carries that.
PLACE_EARLY_CFLAG="-DMBXR_RT_PLACE_EARLY=1"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --candidate) CAND="${2:?}"; shift 2 ;;
    --ir) IR="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --requires) LAB_REQUIRES="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --maxread) MAXREAD="${2:?}"; shift 2 ;;
    --window-s) WINDOW_S_OPT="${2:?}"; shift 2 ;;
    --kernel-cflags) KCF_ALL="${2}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    --board-only) BOARD_ONLY=1; shift ;;
    --report-only) BOARD_ONLY=1; REPORT_ONLY=1; shift ;;
    --selftest) SELFTEST="${2:?}"; shift 2 ;;
    --place-early) PLACE_EARLY_CFLAG="-DMBXR_RT_PLACE_EARLY=1"; shift ;;   # now the default
    --no-place-early) PLACE_EARLY_CFLAG=""; shift ;;
    # T4's LUT LANE for gelu_s8 and tanh_s8 (T4_LANES.md s12, LANE_DISPATCH_RULES.md).  OFF by
    # default and SCOPED TO THIS RUN: it removes the competing curated files from this run's own
    # copy of the kernel tree and adds -DMBXR_RT_LUT=1 to this run's kernel cflags.  Neither half
    # works alone -- a pick with the guard off takes the curated path inside the lane kernel, and
    # the guard on with the old pick never reaches the lane kernel at all -- so they are one flag.
    # Needs a bitstream with `lut_lane`: pass --requires "rocc_engine pext lut_lane".
    --lut-lane) LUT_LANE=1; shift ;;
    --ln-lane) LN_LANE_SEL=1; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ============================================================================================
# THE CLOCK, DERIVED ONCE, FROM --fclk, AND ASSERTED IN FOUR PLACES.
#
# FCLK0 = IO PLL / (DIVISOR0 * DIVISOR1) with both divisors integers and the IO PLL at
# 50 MHz * 20 = 1000 MHz, so the clock the PS7 can actually deliver is 1000/N MHz for an
# integer N -- 1000/29 = 34.4828 for every build before 0x5A5A0030, 1000/25 = 40 exactly for
# that one.  Derive the Hz from N rather than from the rounded MHz, which is where the repo's
# 34482759 came from in the first place (round(1e9/29)), so an existing run's number is
# reproduced to the Hz and a new one is exact.
#
# GUEST_KHZ is CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC, the ONE symbol through which this clock
# reaches software -- mtime's tick AND the SiFive UART's baud divisor.  Wrong, it garbles the
# console rather than failing, so it is checked against the built image before the board is taken.
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
info "clock: FCLK0 $FCLK_CORE MHz = $CLK_HZ Hz; guest CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ"

MB="$ZCS/modelblaster"
MOON="$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
KERNELS_T1="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels_t1"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
[ -n "$IR" ] || IR="$IISWC_OUT/q16/$CAND/ir"
RUN="$IISWC_OUT/$NAME"
D="$RUN/enc_q16"
# The engine's outstanding cap is a property of the bitstream's L2 (scripts/50's note).
case "$WANT_MAGIC" in
  # every MAGIC below carries 0092's skipped clean Release in the L2, which is the
  # precondition for cap 4 (mbxr_rt.h:175).  The lane-bearing MAGICs were missing from
  # this list and fell to the wildcard, so an A/B between a 0x5A5A0028 record and a
  # lane-bearing one silently changed the engine's fill cap as well as the lanes.
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
OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)

# ============================================================================================
# THE SNAPSHOT, ON AN EXIT TRAP.  Idempotent, and installed before anything can fail.
# ============================================================================================
SNAP_DONE=0
snapshot_once () {
  [ "$SNAP_DONE" -eq 0 ] || return 0
  [ -d "$RUN" ] || return 0
  SNAP_DONE=1
  local rn; rn="$(basename "$RUN")"
  printf '\n    [archive] snapshotting %s before anything else\n' "$rn"
  "$IISWC_ROOT/archive/tools/archive_run.py" "$rn" 2>&1 | sed 's/^/    /' || \
    printf '    [archive] WARNING: archive_run.py failed; out/%s is still on disk\n' "$rn"
  # the health check: say what the evidence actually contains, whatever the verdict will say
  "$PY" - "$RUN" <<'PYH' 2>&1 | sed 's/^/    /' || true
import json, os, sys
run = sys.argv[1]
def has(p):  return "yes" if os.path.exists(os.path.join(run, p)) else "NO"
c = os.path.join(run, "enc_q16", "console.txt")
n = os.path.getsize(c) if os.path.exists(c) else 0
ops = 0
if os.path.exists(c):
    ops = sum(1 for l in open(c, errors="replace") if l.startswith("MB_PEXT_OP "))
print("[health] run.json=%s report.txt=%s console=%d bytes MB_PEXT_OP lines=%d boot.log=%s"
      % (has("run.json"), has("report.txt"), n, ops, has("boot.log")))
PYH
}
trap snapshot_once EXIT

# ============================================================================================
# --selftest: exercise the failing path with no board and no build
# ============================================================================================
if [ -n "$SELFTEST" ]; then
  step "selftest ($SELFTEST): the scorer's failing path, and the snapshot that must survive it"
  RUN="$IISWC_OUT/${NAME}_selftest_$SELFTEST"; D="$RUN/enc_q16"
  rm -rf "$RUN"; mkdir -p "$D"; SNAP_DONE=0
  case "$SELFTEST" in
    fail) MAE=7 ;;   # a nonzero max_abs_err: the board disagreed with the host-C golden
    pass) MAE=0 ;;
    # THE CASE THAT WOULD HAVE CAUGHT IT.  A DECODER graph contains kinds an encoder never has --
    # silu_s8 (the MLP gate) and cat2_c1_s8 (the K/V cache concatenate) -- and work()'s list was
    # complete for every model this lab had run and incomplete for the first one it had not.  The
    # guard is right to refuse an unknown kind; what was wrong is that raising discarded the whole
    # record, twice, the second time 3.4 MB that had to be recovered from the console.  This case
    # asserts BOTH halves: the record is written, and the exit code still fails.
    unknown) MAE=0 ;;
    # 438eb27's case, as an EXECUTABLE selftest rather than only a field: max_abs_err = 0 over
    # zero profiled dispatches must FAIL, and the verdict must say why.
    nothing) MAE=0 ;;
    *) die "--selftest takes 'fail', 'pass', 'unknown' or 'nothing'" ;;
  esac
  MEANING=matched; ROWS="[{'op':'linear_s8','cycles':1,'elements':1,'name':'x'}]"; NPROF=1
  [ "$MAE" -eq 0 ] || MEANING=differs
  [ "$SELFTEST" != "nothing" ] || { MEANING=not_compared; ROWS="[]"; NPROF=0; }
  "$PY" -c "
import json, os, sys
json.dump({'lab':'B30 selftest','models':{'enc_q16':{'ran':True,'max_abs_err':$MAE,
  'max_abs_err_meaning':'$MEANING',
  'dispatches_in_ir':1,'dispatches_profiled':$NPROF,'console_records':$NPROF,
  'dispatch_cycles_total':1,'per_kind':{'linear_s8':{'dispatches':1,'cycles':1,'elements':1}},
  'rows':$ROWS}}},
  open(sys.argv[1],'w'), indent=1)" "$RUN/run.json"
  printf 'selftest\n' > "$D/console.txt"
fi

# ============================================================================================
# the scorer and the parser, written INTO the run directory so they are archived with it
# ============================================================================================
emit_tools () {
  mkdir -p "$RUN"
  # THE CLOCK TRAVELS WITH THE RUN, not with the script that wrote it.  report.py reads this
  # file (and only falls back to the old 34482759.0 literal when it is absent, i.e. for a run
  # directory written before 2026-09-18).  It is written HERE, in emit_tools, because that is
  # the one place reached by every path -- a full run, --board-only, --report-only and the
  # selftests -- so a re-report of an archived run divides by the clock that run was taken at.
  printf '%s\n' "$CLK_HZ" > "$RUN/clock_hz.txt"
  cat > "$RUN/report.py" <<'PYR'
#!/usr/bin/env python3
"""Parse one Lab B30 board run into run.json and report.txt.

work() prices a dispatch from its IR shape.  It RAISES on a kind it does not know, because the
alternative -- scripts/50's `return 0, 0` -- prices the unknown kind as free and is invisible in
the output.  On candidate R that silently zeroed groupnorm_s16 (287,712 elements),
mrcombine_s16 (3 x 287,712) and lut16_pc_s8 (47,520): the stem, the most expensive part.
"""
import json, os, re, sys

# THE CLOCK EVERY CYCLE COUNT HERE IS DIVIDED BY, READ FROM THE RUN DIRECTORY.
#
# It was the literal `CLK = 34482759.0` until 2026-09-18 (Lab B81), and it is the one constant
# in this file that CANNOT FAIL LOUDLY.  model_rtf_e2e.py takes `clock_hz` out of the record and
# only checks that the two halves AGREE -- and two halves at the same WRONG clock agree
# perfectly.  So a run on 0x5A5A0030 (FCLK0 40.0000 MHz) scored against a stale 34482759 does
# not error: it reports the OLD RTF at the NEW clock, and nothing downstream refuses it.
#
# The lab writes the clock it asked the board for into clock_hz.txt beside this file, fclk.py
# reads the SLCR back to confirm the board agrees, and the guest's own
# CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC is checked against the same number before the board is
# taken.  Three statements of one fact, and this reads the archived one.  The old constant
# survives ONLY as the fallback for a run directory written before the file existed -- which is
# exactly the set of runs it was the right number for.
def _clock_hz(run_dir, default=34482759.0):
    p = os.path.join(run_dir, "clock_hz.txt")
    if os.path.exists(p):
        return float(open(p).read().split()[0])
    return default


CLK = _clock_hz(sys.argv[1] if len(sys.argv) > 1 else ".")


class UnknownKind(Exception):
    pass


def work(op, s):
    """(MACs, output elements) of one dispatch, from its IR shape."""
    if op in ("linear_s8", "linear_s8_pc"):
        return s["M"] * s["K"] * s["N"], s["M"] * s["N"]
    if op in ("conv2d_s8", "conv2d_s8_pc", "conv2d_s16_pc"):
        return (s["OC"] * s["OH"] * s["OW"] * s["IC"] * s["KH"] * s["KW"],
                s["N"] * s["OC"] * s["OH"] * s["OW"])
    if op == "matmul_b_s8":
        return s["B"] * s["M"] * s["K"] * s["N"], s["B"] * s["M"] * s["N"]
    if op == "attention_s8":
        # The fused SDPA (patches/0112).  Its MACs are the two products it replaces --
        # q.k^T is B*M*Dk*S and probs.v is B*M*S*Dv -- and its OUTPUT elements are B*M*Dv,
        # NOT the intermediates', because the two [B,M,S] tensors are never materialised.
        # That asymmetry is the point of the op, so the c/el column here is not comparable
        # with the unfused matmul_b_s8 + softmax_s8 rows: those price 1.59 M + 1.31 M
        # elements against this op's 47,520.  Compare CYCLES, not cycles/element.
        return (s["B"] * s["M"] * s["Dk"] * s["S"] + s["B"] * s["M"] * s["S"] * s["Dv"],
                s["B"] * s["M"] * s["Dv"])
    if op in ("permute4_s8", "permute4_s16"):
        return 0, s["d0"] * s["d1"] * s["d2"] * s["d3"]
    if op in ("groupnorm_s8", "groupnorm_s16"):
        return 0, s["N"] * s["C"] * s["H"] * s["W"]
    if op == "rope_s8":
        return 0, s["T"] * s["H"] * s["D"]
    if op == "lut16_pc_s8":
        return 0, s["N"] * s["C"] * s["HW"]
    if op == "mrcombine_s16":
        return 0, s["N"] * s["OC"] * s["OH"] * s["OW"]
    if op in ("layernorm_pc_s8", "layernorm_s16_s8", "layernorm_s8", "softmax_s8"):
        return 0, s["M"] * s["K"]
    if op in ("add_pc_s8", "add_s16_pc_s8", "add_s8", "gelu_s8", "tanh_s8", "lut16_s16",
              "split16_s8", "mul_s8",
              # the DECODER's own pointwise kinds: the encoder has neither, so this list was
              # complete for every model this lab had seen and incomplete for the first one it
              # had not.  silu_s8 is the MLP gate, cat2_c1_s8 the K/V cache concatenate.
              "silu_s8", "cat2_c1_s8"):
        return 0, s["n"]
    raise UnknownKind(
        "work(): no rule for op %r with shape keys %s. Add one -- do NOT let it price as 0."
        % (op, sorted(s)))


# kinds whose kernel is not what a tuned board would run: named in the report, not hidden
HANDICAP = {
    "layernorm_pc_s8": "reference C: no curated kernel exists for this op",
    "layernorm_s16_s8": "reference C: no curated kernel exists for this op",
    "lut16_s16": "reference C",
    "lut16_pc_s8": "reference C",
    "split16_s8": "reference C",
    "permute4_s16": "reference C",
}



def _roccmoon_md5():
    """THE RUNTIME STATE THIS RUN WAS BUILT FROM.  Four board runs on 2026-09-18 were lost to
    fpga/pynq-z2/sw/roccmoon/ being rewritten while three workstreams built from it, and they
    could not be attributed afterwards without reconstructing file mtimes by hand -- which is
    what eventually found it.  `board` (added the same day) answers WHICH MACHINE; this answers
    WHICH SOFTWARE.  A run that records neither is a number nobody can place.

    NEVER RAISES and never blocks a build: a run that cannot compute it records None."""
    import hashlib
    try:
        roots = [os.getcwd()]
        try:
            roots.append(os.path.dirname(os.path.abspath(__file__)))
        except NameError:
            pass
        roots.append(os.environ.get("IISWC_ROOT", ""))
        for base in roots:
            d = base
            for _ in range(6):
                rt = os.path.join(d, "fpga", "pynq-z2", "sw", "roccmoon")
                if os.path.isdir(rt):
                    h = hashlib.md5()
                    for name in sorted(os.listdir(rt)):
                        if not name.endswith((".c", ".h")):
                            continue
                        p = os.path.join(rt, name)
                        if not os.path.isfile(p):
                            continue
                        h.update(name.encode())
                        with open(p, "rb") as f:
                            h.update(f.read())
                    return h.hexdigest()[:12]
                nd = os.path.dirname(d)
                if nd == d:
                    break
                d = nd
    except Exception:
        return None
    return None


def _board_name():
    """WHICH PHYSICAL BOARD produced this run.  Two PYNQ-Z1s are registered in
    fpga/pynq-z2/bwlab/boards.csv (garden, illixr) and nothing in a run.json has ever named
    which one ran -- so the (config + bitstream_md5) join blends two machines under one key,
    which is exactly the failure that file was created to stop.  Resolved from $IISWC_BOARD,
    else by matching $PYNQ_HOST against the registry.  NEVER RAISES and never touches the
    board: a run that cannot name its board records None, and `pynq_host` beside it is what a
    reader uses to tell "unregistered host" from "resolver broken"."""
    b = os.environ.get("IISWC_BOARD")
    if b:
        return b
    host = (os.environ.get("PYNQ_HOST") or "").strip()
    if not host:
        return None
    roots = [os.getcwd()]
    try:
        roots.append(os.path.dirname(os.path.abspath(__file__)))
    except NameError:
        pass
    roots.append(os.environ.get("IISWC_ROOT", ""))
    for base in roots:
        d = base
        for _ in range(6):
            csv = os.path.join(d, "fpga", "pynq-z2", "bwlab", "boards.csv")
            if os.path.exists(csv):
                try:
                    for line in open(csv):
                        if line.startswith("#") or "," not in line:
                            continue
                        f = line.split(",")
                        if len(f) > 1 and f[1].strip() == host:
                            return f[0].strip()
                except OSError:
                    pass
                return None
            nd = os.path.dirname(d)
            if nd == d:
                break
            d = nd
    return None


def _kernel_manifest(rows, kinds):
    """WHICH KERNEL EVERY OP RESOLVED TO, plus one digest over the whole mapping.

    WHY.  Two decoder arms on 2026-09-18 matched on `soc_magic`, on `bitstream_md5` AND on
    `roccmoon_md5` and still differed in a kernel worth 18 % of the decoder: `silu_s8` resolved
    to `pext_memo_lut` in one arm and `pext_int_lut` in the other -- 369.27 against 47.20
    cycles/element -- because this script's `--silu-int` was off by default and only one arm
    passed it.  A wrong conclusion ("0x5A5A002E is slower for the decoder") had already been
    drafted before an op-by-op diff of two archived runs found it.

    AND THE SELECTION MACHINERY WAS NOT AT FAULT: each arm asserted its own `silu_s8` pick and
    both assertions PASSED.  An assertion checks one arm against its own intent; nothing
    compared the two arms against EACH OTHER.  That is the gap this field closes, and it is why
    the digest matters as much as the mapping -- two records can be compared at a glance
    instead of by diffing their `rows[]`.  `board` and `roccmoon_md5` are the same kind of
    field and each caught a real error within hours of landing.

    Derived from `rows[]`, which carries the kernel per DISPATCH and is the authoritative
    record; `per_kind` is the fallback for a record with no rows.  An op whose dispatches do
    not agree is recorded as "a+b" and listed in `mixed`, which MOVES the digest rather than
    hiding behind whichever row happened to be written last.  An op with no pick at all is "-",
    so a reference -> curated change moves the digest too.

    NEVER RAISES and never blocks a build: a run that cannot compute it records None."""
    import hashlib
    try:
        seen = {}
        for r in (rows or []):
            seen.setdefault(r.get("op"), set()).add(r.get("kernel") or "-")
        if not seen:
            for op, k in (kinds or {}).items():
                seen[op] = {(k or {}).get("kernel") or "-"}
        if not seen:
            return None
        m = {op: ("+".join(sorted(v)) if len(v) > 1 else sorted(v)[0])
             for op, v in seen.items() if op}
        if not m:
            return None
        line = ";".join("%s=%s" % (op, m[op]) for op in sorted(m))
        return {"ops": m, "n_ops": len(m),
                "digest": hashlib.md5(line.encode()).hexdigest()[:12],
                "digest_over": "md5 of \"op=kernel\" joined by \";\", ops sorted, first 12 hex",
                "mixed": sorted(op for op, v in seen.items() if op and len(v) > 1),
                "source": "rows" if rows else "per_kind"}
    except Exception:
        return None


def main(run):
    d = os.path.join(run, "enc_q16")
    g = json.load(open(os.path.join(d, "ir", "graph.json")))
    picks = json.load(open(os.path.join(d, "gen", "kernel_picks.json")))["picks"]
    txt = open(os.path.join(d, "console.txt"), errors="replace").read()

    # -- JOIN ON dispatch id, NOT ON op NAME -----------------------------------------------
    # This parser used to build `{name: cycles}` and look each IR op up by name.  The console
    # record carries `id=` -- the dispatch id -- and the name is NOT unique: the 24-step
    # unrolled decoder has 80 names borne by 24 ops each, so 1,840 of its 4,488 dispatches
    # (41 %) were silently given the cycles of the LAST op sharing their name, and the run
    # still reported "4,488 of 4,488 profiled" with nothing missing.  Measured 2026-09-18: the
    # decoder's published total was 530,934,497 where the id-joined truth is 943,026,821, and
    # the 412 M shortfall sat so close to the weight image build (416.7 M) that it made the rows
    # look DISJOINT from the build and produced a plausible, wrong convention.  A name is a
    # label; the id is the key the record was emitted with.  The encoder's 159 names happen to
    # be unique, which is the only reason its figures were unaffected -- not a property anyone
    # chose, and not one a decoder-shaped graph run through this lab keeps.
    ops, dup_ids, n_records = {}, [], 0
    for l in txt.splitlines():
        if l.startswith("MB_PEXT_OP "):
            o = dict(re.findall(r"(\w+)=(\S+)", l))
            if "id" not in o:
                raise SystemExit("MB_PEXT_OP has no id= field; this parser joins on the "
                                 "dispatch id and will not fall back to the name: " + l[:120])
            n_records += 1
            did = int(o["id"])
            if did in ops:
                dup_ids.append(did)
            ops[did] = int(o["cycles"])
    m = re.search(r"^MB_PEXT_RUN .*$", txt, re.M)
    runline = m.group(0) if m else ""
    mae = int(re.search(r"max_abs_err=(\d+)", runline).group(1)) if "max_abs_err=" in runline else None
    # The engine's own counters.  Without them the per-kind table misleads: the ONE-TIME weight
    # image build sits inside the linear_s8 and conv2d_s8 rows (the runtime does not split it
    # between them), and the NCHW staging sits inside conv2d_s8.  Lab B26 nets the image build
    # at the total only, and so does `steady_cycles` here.
    eng = {}
    me = re.search(r"^MB_ROCCMOON phase=total (.*)$", txt, re.M)
    if me:
        eng = {k: int(v) for k, v in re.findall(r"(\w+)=(-?\d+)", me.group(1))}

    rows, kinds, missing, unknown = [], {}, [], []
    for o in g["ops"]:
        if o.get("dispatch_id") is None:
            continue
        if o["dispatch_id"] not in ops:
            missing.append("%s (dispatch %s)" % (o["name"], o["dispatch_id"]))
            continue
        try:
            macs, els = work(o["op"], o["shape"])
        except UnknownKind as e:
            # THE GUARD IS RIGHT AND THE CONSEQUENCE WAS NOT.  Refusing to price an unknown kind
            # at 0 is correct -- a silent 0 would understate a model and nobody would see it.  But
            # raising here discarded the whole run.json, twice this session, the second time a
            # 3.4 MB record that had to be recovered by parsing the console.  Collect instead: the
            # record is written with the unknown kinds named in it, and the exit code still fails.
            unknown.append(str(e))
            macs, els = 0, 0
        cyc = ops[o["dispatch_id"]]
        p = picks.get(o["op"], {})
        kern = p.get("algorithm") or p.get("source")
        rows.append({"dispatch": o["dispatch_id"], "name": o["name"], "op": o["op"],
                     "shape": o["shape"], "cycles": cyc, "macs": macs, "elements": els,
                     "kernel": kern, "source": p.get("source")})
        k = kinds.setdefault(o["op"], {"dispatches": 0, "cycles": 0, "macs": 0, "elements": 0,
                                       "kernel": kern, "source": p.get("source"),
                                       "handicap": HANDICAP.get(o["op"])})
        k["dispatches"] += 1
        k["cycles"] += cyc
        k["macs"] += macs
        k["elements"] += els
    for k in kinds.values():
        k["cycles_per_element"] = (k["cycles"] / k["elements"]) if k["elements"] else None
        k["cycles_per_mac"] = (k["cycles"] / k["macs"]) if k["macs"] else None

    total = sum(k["cycles"] for k in kinds.values())

    # -- THE ACCOUNTING, DERIVED AND LABELLED RATHER THAN ASSUMED --------------------------
    # THE ENCODER'S OWN NUMBERS ARE NOT WRONG AND THIS DOES NOT CHANGE THEM.  On every real
    # encoder record the rows reconcile with the wall clock to -0.01 % and the weight image
    # build is INSIDE them (mbxr_rt.h builds an image lazily, on first use, within a
    # dispatch), so `steady = total - image` is the right formula here and `rtf_steady` 4.002
    # on b34_qatu_lnhoist stands.  What is being fixed is that the formula was ASSUMED: this
    # lab also runs decoder-shaped graphs under the enc_q16 key (b30's lm_head split did), and
    # nothing checked that the assumption still held.  Derive it from the run's own wall clock,
    # SAY which convention closed, and refuse to report an RTF when neither does.
    wall = None
    mw = re.search(r"median=(\d+)", runline)
    if mw:
        wall = int(mw.group(1))
    img = eng.get("image_cycles")
    acct = {"wall_cycles_median": wall, "rows_cycles": total, "image_cycles": img}
    defn, per_iter, cold = "unresolved", None, None
    if wall and img is not None:
        r_incl = abs(total - wall) / wall            # the image is INSIDE the rows
        r_excl = abs(total + img - wall) / wall      # the rows and the image are DISJOINT
        acct["rows_vs_wall_pct"] = 100.0 * (total - wall) / wall
        acct["rows_plus_image_vs_wall_pct"] = 100.0 * (total + img - wall) / wall
        TOL = 0.05
        if r_incl <= TOL and r_incl < r_excl:
            defn = "rows_include_image"
            per_iter, cold = total - img, total
        elif r_excl <= TOL and r_excl < r_incl:
            defn = "rows_exclude_image"
            per_iter, cold = total, total + img
    acct["definition"] = defn
    acct["meaning"] = {
        "rows_include_image": "the per-dispatch rows DO contain the one-time weight image "
                              "build; per-iteration cost is rows - image and the cold first "
                              "iteration is the row total",
        "rows_exclude_image": "the per-dispatch rows do NOT contain the one-time weight image "
                              "build; per-iteration cost is the row total and the cold first "
                              "iteration is rows + image",
        "unresolved": "neither convention reconciles the rows and the image build with the "
                      "wall clock to within 5 % -- the per-iteration figure is NOT derivable "
                      "from this record and no RTF is reported",
    }[defn]
    out = {"lab": "B30 moonshine_q16_enc", "run": os.path.basename(run),
           "candidate": open(os.path.join(run, "candidate.txt")).read().strip()
                        if os.path.exists(os.path.join(run, "candidate.txt")) else None,
           "soc_magic": os.environ.get("WANT_MAGIC"),
           "requires": os.environ.get("LAB_REQUIRES"),
           "features": os.environ.get("LAB_FEATURES"),
           "bitstream_md5": os.environ.get("BIT_MD5"),
           "clock_hz": CLK, "window_s": float(os.environ.get("MB_WINDOW_S", "4.0")),
           "kernel_cflags": open(os.path.join(d, "kernel_cflags.txt")).read().strip()
                            if os.path.exists(os.path.join(d, "kernel_cflags.txt")) else None,
           # SELECTORS, not macros: --ln-lane and friends change which KERNEL serves an op and
           # leave kernel_cflags byte-identical.  Comparing two runs on kernel_cflags alone
           # reported matching configurations that differed by 35.7 M cycles (TODO.md, B98).
           "kernel_selectors": dict(
               (ln.split("=", 1)[0], ln.split("=", 1)[1])
               for ln in open(os.path.join(d, "kernel_selectors.txt")).read().splitlines()
               if "=" in ln) if os.path.exists(os.path.join(d, "kernel_selectors.txt")) else None,
           "run_line": runline, "max_abs_err": mae,
           # A ZERO THAT MEANS "NOTHING WAS COMPARED" MUST NOT READ AS "EVERYTHING MATCHED".
           # 2026-09-18: a run that stopped after 16 of 117 dispatches printed
           # `max_abs_err=0` -- true, and only because no dispatch reached a comparison.  In
           # every summary that is indistinguishable from a pass.  This field says which:
           #   "matched"      the board agreed with its host-C golden over real dispatches
           #   "not_compared" nothing was profiled, so the 0 carries no information
           # Three of this lab's four instrument failures today presented as silence rather
           # than as error; a distinct value is what stops the next one being read as a pass.
           "max_abs_err_meaning": ("not_compared" if not rows
                                   else ("matched" if mae == 0 else "differs")),
           "dispatches_in_ir": sum(1 for o in g["ops"] if o.get("dispatch_id") is not None),
           "dispatches_profiled": len(rows), "dispatches_missing": missing,
           # How the rows were joined, and whether the join threw anything away.  A parser that
           # drops records and still prints "N of N profiled" is the failure this names.
           "join_key": "dispatch_id",
           "console_records": n_records,
           "console_duplicate_ids": sorted(set(dup_ids)),
           "dispatch_cycles_total": total,
           "rtf": total / (CLK * float(os.environ.get("MB_WINDOW_S", "4.0"))),
           "engine": eng,
           "image_cycles_once": eng.get("image_cycles"),
           "cycles_stage": eng.get("cycles_stage"),
           "cycles_stage_in": eng.get("cycles_stage_in"),
           "cycles_stage_out": (eng["cycles_stage"] - eng["cycles_stage_in"])
                               if ("cycles_stage" in eng and "cycles_stage_in" in eng) else None,
           "cycles_accounting": acct,
           "cycles_per_iteration": per_iter,
           "rtf_per_iteration": (per_iter / (CLK * float(os.environ.get("MB_WINDOW_S", "4.0"))))
                                if per_iter is not None else None,
           "cycles_cold": cold,
           "rtf_cold": (cold / (CLK * float(os.environ.get("MB_WINDOW_S", "4.0"))))
                       if cold is not None else None,
           # Same values as before on every encoder record (its convention is
           # rows_include_image), now derived rather than assumed.
           "steady_cycles": per_iter,
           "rtf_steady": (per_iter / (CLK * float(os.environ.get("MB_WINDOW_S", "4.0"))))
                         if per_iter is not None else None,
           "kernel_manifest": _kernel_manifest(rows, kinds),
           "per_kind": kinds, "rows": rows}
    out["unknown_kinds"] = unknown
    json.dump({"models": {"enc_q16": out}, "lab": out["lab"],
               "board": _board_name(), "pynq_host": os.environ.get("PYNQ_HOST"),
               "roccmoon_md5": _roccmoon_md5(),
               "kernel_digest": (out.get("kernel_manifest") or {}).get("digest"),
               "soc_magic": out["soc_magic"], "bitstream_md5": out["bitstream_md5"]},
              open(os.path.join(run, "run.json"), "w"), indent=1)

    L = []
    L.append("Lab B30  candidate %s on %s  (%s)" % (out["candidate"], out["soc_magic"],
                                                    out["bitstream_md5"]))
    L.append("%s" % runline)
    km = out.get("kernel_manifest") or {}
    L.append("kernel manifest: digest %s over %s ops%s"
             % (km.get("digest") or "(unavailable)", km.get("n_ops"),
                ("  MIXED: " + ", ".join(km["mixed"])) if km.get("mixed") else ""))
    L.append("dispatches: %d of %d profiled%s" % (out["dispatches_profiled"],
             out["dispatches_in_ir"],
             ("; MISSING: " + ", ".join(missing[:6])) if missing else ""))
    L.append("total dispatch cycles %d  = RTF %.3f over a %.1f s window"
             % (total, out["rtf"], out["window_s"]))
    L.append("accounting: %s  (rows %d, image %d, wall %s; rows vs wall %+.2f %%, "
             "rows+image vs wall %+.2f %%)"
             % (acct["definition"], total, img or 0, acct.get("wall_cycles_median"),
                acct.get("rows_vs_wall_pct", float("nan")),
                acct.get("rows_plus_image_vs_wall_pct", float("nan"))))
    if out["cycles_per_iteration"] is None:
        L.append("  NO RTF REPORTED: %s" % acct["meaning"])
    else:
        L.append("  per iteration (weights already imaged) %d = RTF %.3f over a %.1f s window"
                 % (out["cycles_per_iteration"], out["rtf_per_iteration"], out["window_s"]))
        L.append("  cold (first iteration, image build included) %d = RTF %.3f"
                 % (out["cycles_cold"], out["rtf_cold"]))
    if out["steady_cycles"] is not None:
        L.append("  of which NCHW staging inside conv2d_s8: %d (%s of the cold total)"
                 % (out["cycles_stage"],
                    ("%.2f %%" % (100.0 * out["cycles_stage"] / total)) if total else "n/a"))
        if out["cycles_stage_in"] is not None:
            L.append("    gather (input)  %d ; scatter (output) %d"
                     % (out["cycles_stage_in"], out["cycles_stage_out"]))
        L.append("  engine: %d calls, %d fallback; h0 %d, h1 %d cycles"
                 % (eng.get("calls_engine", 0), eng.get("calls_fallback", 0),
                    eng.get("cycles_h0", 0), eng.get("cycles_h1", 0)))
        # ---- B101 REGIME TEST.  Read this BEFORE building an op-level arm. ------------
        # An op-level saving reaches steady only when the engine is not parked on DRAM.
        # `cyc_tseq / cyc_fill` says which regime this shape is in, and it is a property of
        # the SHAPE, not of "encoder" vs "decoder":
        #   > 1  array-bound   -- savings TRANSFER.  Eleven encoder arms, ratio 6.40,
        #                         transfer 0.9124 .. 1.0589, mean 0.99 (TODO.md B101).
        #   < 1  fill-bound    -- savings are ABSORBED.  Decoder, ratio 0.29, B62 B->C
        #                         transfer -0.009 on a 4,681,354-cycle op-level saving.
        # Second line is B93's byte-lever test: bytes_wgt/image_bytes == 1.0 means every
        # weight byte is read once in the one-time image build and NOTHING is left to cut.
        _ts, _fl = eng.get("cyc_tseq"), eng.get("cyc_fill")
        if _ts is not None and _fl:
            _r = float(_ts) / float(_fl)
            L.append("  REGIME (B101): cyc_tseq/cyc_fill = %.2f -- %s" % (
                _r,
                "ARRAY-BOUND, op-level savings TRANSFER to steady (~0.99)" if _r >= 1.0 else
                "FILL-BOUND, op-level savings are ABSORBED (B62 B->C: -0.009) -- "
                "predict ~0 transfer BEFORE building an arm"))
        _bw, _ib = eng.get("bytes_wgt"), eng.get("image_bytes")
        if _bw is not None and _ib:
            _b = float(_bw) / float(_ib)
            L.append("    bytes_wgt/image_bytes = %.3f -- %s" % (
                _b, "no byte lever: every weight byte is read once, in the image build (B93)"
                    if _b < 1.01 else "steady re-reads weights; a byte lever acts here"))
        _busy, _st = eng.get("cyc_busy"), out.get("cycles_per_iteration")
        if _busy is not None and _st:
            L.append("    engine idle %d = %.2f %% of steady -- hart 0 running alone (B101)"
                     % (_st - _busy, 100.0 * (_st - _busy) / _st))
        # -------------------------------------------------------------------------------
    L.append("")
    L.append("%-18s %4s %14s %7s %10s %9s  %-22s %s"
             % ("kind", "n", "cycles", "share%", "elements", "cyc/el", "kernel", "note"))
    for op, k in sorted(kinds.items(), key=lambda kv: -kv[1]["cycles"]):
        L.append("%-18s %4d %14d %7.2f %10d %9.2f  %-22s %s"
                 % (op, k["dispatches"], k["cycles"], 100.0 * k["cycles"] / total if total else 0,
                    k["elements"], k["cycles_per_element"] or 0, str(k["kernel"]),
                    k["handicap"] or ""))
    hand = sum(k["cycles"] for op, k in kinds.items() if k["handicap"])
    L.append("")
    L.append("handicapped kinds (reference C, no curated kernel): %d cycles = %.2f %% of the total"
             % (hand, 100.0 * hand / total if total else 0))
    if acct["definition"] == "rows_include_image":
        L.append("NOTE: the linear_s8 and conv2d_s8 rows are COLD -- they carry the one-time"
                 " weight image build, which the runtime reports only as a single total."
                 "  Compare them against Lab B26's GROSS figures, never its steady ones.")
    elif acct["definition"] == "rows_exclude_image":
        L.append("NOTE: the weight image build (%d cycles) is DISJOINT from the rows above."
                 "  The per-kind table is per-iteration and does NOT contain the build."
                 % (img or 0))
    open(os.path.join(run, "report.txt"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))
    if unknown:
        print("UNKNOWN KINDS (priced 0 in the rows above, and the record says so):")
        for u in unknown[:6]:
            print("   " + u)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1])
PYR
  cat > "$RUN/score.py" <<'PYS'
#!/usr/bin/env python3
"""Lab B30's verdict, archived beside the run it scored.

PASS requires: the image ran, the board agreed with its own host-C golden byte for byte
(max_abs_err == 0), and every dispatch in the IR produced a cycle record.  Exit 1 on FAIL --
and the caller takes that with `|| RC=$?` so this never decides the script's fate.
"""
import json, os, sys

run = sys.argv[1]
p = os.path.join(run, "run.json")
bad = []
if not os.path.exists(p):
    bad.append("no run.json")
    m = {}
else:
    m = json.load(open(p))["models"]["enc_q16"]
    if not m.get("dispatch_cycles_total"):
        bad.append("no dispatch cycles")
    if m.get("max_abs_err_meaning") == "not_compared":
        bad.append("max_abs_err = %s is NOT a pass: nothing was profiled, so no dispatch "
                   "reached a comparison" % m.get("max_abs_err"))
    if m.get("max_abs_err") is None:
        bad.append("no max_abs_err on the console: the harness never reported a result")
    elif m["max_abs_err"] != 0:
        bad.append("max_abs_err = %s: the board does not match its host-C golden" % m["max_abs_err"])
    if m.get("dispatches_missing"):
        bad.append("%d dispatches produced no record" % len(m["dispatches_missing"]))
    if (m.get("cycles_accounting") or {}).get("definition") == "unresolved":
        bad.append("the rows and the weight image build do not reconcile with the wall clock "
                   "under either convention: no per-iteration figure can be read off this run")
    if m.get("dispatches_profiled") != m.get("dispatches_in_ir"):
        bad.append("%s of %s dispatches profiled" % (m.get("dispatches_profiled"),
                                                     m.get("dispatches_in_ir")))
    if m.get("console_duplicate_ids"):
        bad.append("%d dispatch ids appear twice on the console: the join is ambiguous"
                   % len(m["console_duplicate_ids"]))
    if (m.get("console_records") is not None
            and m.get("console_records") != m.get("dispatches_in_ir")):
        bad.append("the console carries %s records for %s dispatches in the IR"
                   % (m.get("console_records"), m.get("dispatches_in_ir")))
v = "FAIL: " + "; ".join(bad) if bad else "PASS"
open(os.path.join(run, "verdict.txt"), "w").write(v + "\n")
print("verdict: " + v)
sys.exit(1 if bad else 0)
PYS
  chmod +x "$RUN/report.py" "$RUN/score.py"
}

if [ -n "$SELFTEST" ]; then
  emit_tools
  # THE CASE THAT WOULD HAVE CAUGHT IT.  A DECODER graph has kinds an encoder never has --
  # silu_s8 (the MLP gate), cat2_c1_s8 (the K/V concatenate) -- and report.py's work() raises on a
  # kind it does not know, which is RIGHT: scripts/50's `return 0, 0` prices the unknown at free
  # and hides it.  What was wrong is that raising discarded the whole record, twice this session,
  # the second time 3.4 MB recovered by parsing the console.  This asserts both halves: report.py
  # still FAILS, and it writes a record that NAMES the unknown kind.  It uses an INVENTED kind
  # rather than silu_s8: a test keyed to the op that happened to expose the bug stops testing the
  # mechanism the moment that op is taught, which is exactly what happened on the first attempt.
  if [ "$SELFTEST" = unknown ]; then
    mkdir -p "$D/ir" "$D/gen"
    "$PY" -c "
import json, os, sys
json.dump({'ops':[{'name':'x','op':'linear_s8','shape':{'M':1,'K':288,'N':288},'dispatch_id':0},
                  {'name':'g','op':'no_such_kind_s8','shape':{'n':1152},'dispatch_id':1}]},
          open(sys.argv[1],'w'))
json.dump({'picks':{'linear_s8':{'algorithm':'roccmoon_engine','source':'curated'},
                    'no_such_kind_s8':{'algorithm':'x','source':'curated'}}},
          open(sys.argv[2],'w'))" "$D/ir/graph.json" "$D/gen/kernel_picks.json"
    {
      printf 'MB_PEXT_OP id=0 name=x op=linear_s8 shape=M=1;K=288;N=288 cycles=1000\n'
      printf 'MB_PEXT_OP id=1 name=g op=silu_s8 shape=n=1152 cycles=2000\n'
      printf 'MB_PEXT_RUN cpu=0 mhartid=0 median=3000 min=3000 max=3000 warm=0 mtime=3 max_abs_err=0\n'
    } > "$D/console.txt"
    rm -f "$RUN/run.json"
    PRC=0; "$PY" "$RUN/report.py" "$RUN" > "$RUN/selftest.log" 2>&1 || PRC=$?
    snapshot_once
    [ "$PRC" -ne 0 ] || die "selftest unknown: report.py should have FAILED on an unknown kind"
    [ -s "$RUN/run.json" ] || die "selftest unknown: the record was discarded -- the defect is back"
    "$PY" -c "
import json, os, sys
d = json.load(open(sys.argv[1]))['models']['enc_q16']
u = d.get('unknown_kinds') or []
assert any('no_such_kind_s8' in x for x in u), 'the record does not name the unknown kind: %r' % u
assert d['dispatch_cycles_total'] == 3000, d['dispatch_cycles_total']
print('    report.py failed as it must, AND wrote a record naming %d unknown kind(s)' % len(u))
" "$RUN/run.json" || die "selftest unknown: the record is wrong"
    info "selftest OK: the guard still fails and the record survives"
    exit 0
  fi
  RC=0
  "$PY" "$RUN/score.py" "$RUN" || RC=$?
  snapshot_once
  info "selftest: scorer exit status $RC, verdict '$(cat "$RUN/verdict.txt")'"
  case "$SELFTEST" in
    fail) [ "$RC" -ne 0 ] || die "selftest fail: the scorer PASSED a run it must fail" ;;
    pass) [ "$RC" -eq 0 ] || die "selftest pass: the scorer FAILED a clean run" ;;
    nothing)
      [ "$RC" -ne 0 ] || die "selftest nothing: the scorer PASSED a run in which nothing was compared"
      grep -q "nothing was profiled" "$RUN/verdict.txt" || \
        die "selftest nothing: the verdict does not SAY why the zero is not a pass" ;;
  esac
  [ -d "$IISWC_ROOT/archive/runs/$(basename "$RUN")" ] || \
    die "selftest: the snapshot did not survive the failing scorer -- the defect this lab exists not to have"
  info "selftest OK: the verdict was $SELFTEST and archive/runs/$(basename "$RUN")/ exists anyway"
  exit 0
fi

# ============================================================================================
if [ "$BOARD_ONLY" -eq 0 ]; then rm -rf "$RUN"; mkdir -p "$RUN"; fi
mkdir -p "$RUN" "$D"
echo "$CAND" > "$RUN/candidate.txt"
emit_tools

if [ "$BOARD_ONLY" -eq 1 ]; then
  [ "$REPORT_ONLY" -eq 1 ] || need_file "$D/zephyr.bin" "run --build-only first"
  info "--board-only: using the image in $RUN"
else

step "0/5  the q16 IR, the patch stack, and the curated tree"
need_file "$IR/graph.json" "no q16 IR for candidate $CAND (run scripts/53 first)"
need_file "$IR/weights.npz"; need_file "$IR/io.npz"
MB_STACK="0100-modelblaster-moonshine-ops 0102-modelblaster-roccmoon-backend 0103-modelblaster-q16-lowering 0104-modelblaster-softmax-memo 0105-modelblaster-moonshine-stem-nhwc 0106-modelblaster-softmax-memo2 0107-modelblaster-permute-block"
MB_TOP="$IISWC_ROOT/patches/${MB_STACK##* }.patch"
if git -C "$MB" apply --reverse --check "$MB_TOP" >/dev/null 2>&1; then
  info "patch stack through ${MB_STACK##* } already applied"
else
  for P in 0009-modelblaster-pext-backend 0060-modelblaster-pext-pc-and-int-nonlin; do
    F="$IISWC_ROOT/patches/$P.patch"
    if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"; fi
  done
  for P in $MB_STACK; do
    F="$IISWC_ROOT/patches/$P.patch"
    if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"
    elif git -C "$MB" apply --reverse --check "$F" >/dev/null 2>&1; then info "$P already applied"
    else die "patches/$P neither applies nor is already applied to $MB"; fi
  done
fi
# The curated tree a board would run: memo2 softmax and the block permute, chosen the way
# scripts/50 chooses them -- the curated probe walks spec.algorithms in order, so removing the
# earlier file is how a later algorithm wins.
CUR="$RUN/kernels_board"
rm -rf "$CUR"; cp -r "$KERNELS" "$CUR"
rm -f "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_row.c" "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_memo.c"
need_file "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_memo2.c" "no pext_int_memo2 kernel"
cp "$KERNELS_T1/pext_nl/pext_nl_permute4_s8_pext_block.c" "$CUR/pext_nl/"
info "curated tree: softmax -> pext_int_memo2, permute4_s8 -> pext_block"
# gelu_s8 AND tanh_s8: WHICH FILES THIS RUN'S COPY CONTAINS IS THE WHOLE OF THE CHOICE, and it
# is steered in BOTH directions rather than only one.  Measured while landing this: registering
# `roccmoon_lane` in the shared spec made the probe prefer it over the pext candidates for every
# run, because its target_affinity is the build's own target and theirs is not -- so a control
# arm built with no flag came back picking the lane.  A selection change that leaks into every
# other lab's image is exactly what a per-run curated copy exists to prevent, so the default
# branch removes the lane kernels and --lut-lane removes the pext ones.  Every lab that does not
# ask for the lane sees the tree it saw before this flag existed.
#
# Neither removal can remove a FALLBACK: the lane kernels call int_gelu_s8() out of
# sw/int_nonlin.c, which is not in this tree at all.
if [ "$LUT_LANE" = 1 ]; then
  rm -f "$CUR/pext_nl/pext_nl_gelu_s8_pext_int_lut.c" "$CUR/pext/pext_gelu_s8_pext_memo_lut.c"
  rm -f "$CUR/pext/pext_tanh_s8_pext_memo_lut.c"
  need_file "$CUR/roccmoon/roccmoon_gelu_s8_roccmoon_lut.c" "no roccmoon_lane gelu kernel"
  need_file "$CUR/roccmoon/roccmoon_tanh_s8_roccmoon_lut.c" "no roccmoon_lane tanh kernel"
  info "curated tree: gelu_s8 and tanh_s8 -> roccmoon_lut (T4's LUT lane)"
else
  rm -f "$CUR/roccmoon/roccmoon_gelu_s8_roccmoon_lut.c" \
        "$CUR/roccmoon/roccmoon_tanh_s8_roccmoon_lut.c"
  need_file "$CUR/pext_nl/pext_nl_gelu_s8_pext_int_lut.c" "no pext_int_lut gelu kernel"
fi
# THE SAME STEERING FOR PER-TENSOR layernorm_s8, and it needs it for the same reason: the
# roccmoon_lane candidate carries target_affinity=("roccmoon",), so the probe prefers it over
# pext_int_rsqrt for ANY roccmoon run whose tree carries the file -- a control arm would come
# back picking the lane and the A/B would compare one thing with itself.
#
# NOTE THIS TOUCHES ONLY THE PER-TENSOR OP.  layernorm_pc_s8 (candidate R) has exactly one
# curated kernel, the lane one, and its A/B is switched by -DMBXR_LN_LANE inside that kernel
# rather than by which file is present.  The two ops therefore use DIFFERENT mechanisms, which
# is worth knowing before someone "unifies" them.
if [ "$LN_LANE_SEL" = 1 ]; then
  rm -f "$CUR/pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c"
  need_file "$CUR/roccmoon/roccmoon_layernorm_s8_roccmoon_lane.c" "no roccmoon_lane layernorm_s8 kernel"
  info "curated tree: layernorm_s8 -> roccmoon_lane (the LayerNorm lane, per-tensor)"
else
  rm -f "$CUR/roccmoon/roccmoon_layernorm_s8_roccmoon_lane.c"
  need_file "$CUR/pext_nl/pext_nl_layernorm_s8_pext_int_rsqrt.c" "no pext_int_rsqrt layernorm kernel"
fi

# BUFFER ALIGNMENT, BEFORE CODEGEN, because it changes the generated buffers and the
# host-C golden baked from them must match.  mbxd_dma wants 64-byte sources and
# destinations and refuses nothing; a lane dispatch drains into a MODEL INTERMEDIATE
# (mbxr_attn_dispatch passes mbxa_pa(ob)), which no attribute in a kernel file can
# reach.  lane_align_buffers sets MB_BUF_ALIGN64=1 when the target MAGIC provides a
# lane; an explicit MB_BUF_ALIGN64 in the environment always wins.  Measured cost on
# encoder steady: +0.020 %.
lane_align_buffers "$WANT_MAGIC"
step "1/5  codegen for the engine (backend roccmoon) from $IR"
ln -sfn "$IR" "$D/ir"
mkdir -p "$D/gen"
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_skeleton \
    --ir "$IR/graph.json" --weights "$IR/weights.npz" --io "$IR/io.npz" \
    --out-dir "$D/gen" --backend roccmoon ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_skeleton failed"; }
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_kernels \
    --ir "$IR/graph.json" --out-dir "$D/gen" --backend reference --target roccmoon \
    --quant int8 --io "$IR/io.npz" --repo-root "$MB" --build-dir "$D/gen.kverify" \
    --harness-dir "$MB/harness" --cache-dir "$D/gen.cache" --algorithms all \
    --global-curated-dir "$CUR" ) >> "$RUN/codegen.log" 2>&1 \
  || { tail -30 "$RUN/codegen.log"; die "generate_kernels failed"; }
need_file "$D/gen/kernels.c" "codegen produced no kernels"
cp "$D/gen/test_golden.bin" "$D/gen/test_golden_python.bin"
"$PY" -c "
import json,sys
p=json.load(open(sys.argv[1]))['picks']
for k in sorted(p): print('    %-18s %-14s %s'%(k,p[k].get('source'),p[k].get('algorithm')))" \
  "$D/gen/kernel_picks.json"
# the two choices this lab exists to make, asserted rather than hoped for
LUT_LANE="$LUT_LANE" LN_LANE_SEL="$LN_LANE_SEL" "$PY" - "$D/gen/kernel_picks.json" "$IR/graph.json" <<'PYP' || die "the curated tree did not select what this lab needs"
import json, os, sys
p = json.load(open(sys.argv[1]))["picks"]
# WHAT THIS LAB NEEDS DEPENDS ON THE GRAPH, not on a fixed list.  The four below are the encoder's
# ops; a DECODER graph has no conv2d_s8 at all, and requiring one made the gate fail on a model it
# was not written for -- "wanted roccmoon_engine, got None" for an op that is legitimately absent.
# Require the right pick for every op in `want` that the graph actually contains, and say which
# ones were skipped so an op silently missing from the IR is visible rather than excused.
ops = {o["op"] for o in json.load(open(sys.argv[2]))["ops"]}
want = {"softmax_s8": "pext_int_memo2", "permute4_s8": "pext_block",
        "linear_s8": "roccmoon_engine", "conv2d_s8": "roccmoon_engine"}
# --lut-lane is the one flag that CHANGES a pick, so it is the one that must assert it landed.
# A run that asked for the lane and silently got the curated kernel would produce a clean,
# plausible, entirely conventional number -- which is this campaign's signature failure.
if os.environ.get("LN_LANE_SEL") == "1":
    want["layernorm_s8"] = "roccmoon_lane"
else:
    # BOTH WAYS, for the reason the LUT lane found the hard way: a control arm that quietly
    # picked the lane makes the A/B a comparison of one thing with itself.
    want["layernorm_s8"] = "pext_int_rsqrt"
if os.environ.get("LUT_LANE") == "1":
    want["gelu_s8"] = "roccmoon_lut"
    want["tanh_s8"] = "roccmoon_lut"
else:
    # ASSERTED IN BOTH DIRECTIONS.  A control arm that quietly picked the lane would make the
    # A/B a comparison of one thing with itself -- which is how this flag was caught leaking in
    # the first place, and only because the control's own picks were printed.
    want["gelu_s8"] = "pext_int_lut"
    want["tanh_s8"] = "pext_memo_lut"
skipped = sorted(k for k in want if k not in ops)
bad = [(k, v, p.get(k, {}).get("algorithm")) for k, v in want.items()
       if k in ops and p.get(k, {}).get("algorithm") != v]
for k, v, got in bad:
    print("    WRONG PICK %s: wanted %s, got %s" % (k, v, got))
if skipped:
    print("    (not in this graph, so not required: %s)" % ", ".join(skipped))
sys.exit(1 if bad else 0)
PYP

step "2/5  bake this image's own host-C golden"
( cd "$MOON" && "$PY" -c "
import hostrun, numpy as np, sys
g = sys.argv[1]
exe = hostrun.build(g, sys.argv[2])
d = hostrun.dump(exe, g, sys.argv[2] + '/dump.bin')
d['__output__'].astype(np.int8).tofile(g + '/test_golden.bin')
py = np.fromfile(g + '/test_golden_python.bin', dtype=np.int8)
print('    host-C golden: %d of %d elements differ from the Python golden (max %d)' % (
    int((py != d['__output__']).sum()), py.size, int(abs(py.astype(int) - d['__output__']).max())))
" "$D/gen" "$RUN/host" ) || die "host run failed (the host-C golden could not be baked)"

step "3/5  build the image"
CF=$(cd "$ZCS" && "$PY" -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['roccmoon'].kernel_cflags))")
# BOTH DIRECTIONS, so the cflags tell feature_gate.py the truth.  With --lut-lane the runtime
# arm is compiled in; without it MBXR_LUT_LANE=0 says so explicitly, rather than leaving the
# kernel's own default of 1 to imply that an image needs `lut_lane` silicon it never dispatches
# to.  A gate reads the cflags, not the source.
# MODELBLASTER_KERNEL_CFLAGS reaches kernels.c ONLY, by design (samples/modelblaster_pext/
# CMakeLists.txt:73).  The harness prints the runtime counters, so it needs the same define to
# know the LUT lane's exist -- and it gets it ONLY when --lut-lane is given, so an image that
# does not ask for the lane preprocesses main.c exactly as it did before this flag.
LUT_HARNESS_DEF=""
if [ "$LUT_LANE" = 1 ]; then
  CF="$CF -DMBXR_RT_LUT=1"
  LUT_HARNESS_DEF="-DMB_HARNESS_CFLAGS=-DMBXR_RT_LUT=1"
else
  CF="$CF -DMBXR_LUT_LANE=0"
fi
CF="$CF $KCF_ALL $CAP_CFLAG$NCH_CFLAG_SP $PLACE_EARLY_CFLAG"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$ITERS" -DMB_WARMUP=0 \
    -DMB_JOIN_TIMEOUT_S=7200 -DMODELBLASTER_KERNEL_CFLAGS="$CF" $LUT_HARNESS_DEF >> "$RUN/build.log" 2>&1 \
  || { tail -40 "$RUN/build.log"; die "west build failed"; }
cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
# THE GUEST AND THE BITSTREAM HAVE AN ABI, AND NEITHER CAN CHECK THE OTHER AT RUNTIME.  The
# engine's drain descriptor changed shape at 0x5A5A002E; a mismatched pair does not fail loudly,
# it returns MBXR_E_TIMEOUT with no error bit from the first dispatch.  Four board sessions were
# spent on that on 2026-09-18.  Refuse the pair HERE, before with_board.sh is called.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mbxr_abi.sh"
mbxr_abi_gate "$D/zephyr.elf" "$WANT_MAGIC" || die "guest/bitstream ABI mismatch -- refusing to take the board"

echo "$CF" > "$D/kernel_cflags.txt"
# THE SELECTORS, BESIDE THE CFLAGS, BECAUSE A CFLAG STRING IS NOT A CONFIGURATION.
# 2026-09-19: two labs compared kernel_cflags across ELEVEN defines, found them byte-identical,
# and reported the configurations as matching.  They were not.  `--ln-lane` moves layernorm_s8
# from pext_int_rsqrt to the LayerNorm lane -- 41,823,624 cycles against 5,768,175, 7.25x, the
# ENTIRE 35.7 M discrepancy between the two runs -- and it does it through kernel_picks.json,
# leaving $CF untouched.  The distinguishing field was not merely unread: it was ABSENT from the
# record being compared, so no amount of care with the cflag string could have caught it.
# Anything that selects a KERNEL rather than a MACRO belongs here.
{ echo "ln_lane_sel=$LN_LANE_SEL"
  echo "lut_lane=$LUT_LANE"
  echo "candidate=$CAND"
  echo "ir=$IR"
  echo "drain_strided=$(grep -ao 'MBXR_ABI:v2:strided=[01]' "$D/zephyr.elf" 2>/dev/null | head -1 | sed 's/.*=//')"
  # HASH THE SELECTION, NOT THE FILE.  kernel_picks.json embeds an absolute `path` per op
  # that carries the run name, so its md5 differs for every run and compares nothing.  This
  # digest is op -> source/algorithm only: equal digests mean the same kernel serves every op.
  echo "kernel_picks_digest=$("$PY" -c 'import hashlib,json,sys;p=json.load(open(sys.argv[1]))["picks"];print(hashlib.md5(";".join("%s=%s/%s"%(o,p[o].get("source"),p[o].get("algorithm")) for o in sorted(p)).encode()).hexdigest())' "$D/gen/kernel_picks.json" 2>/dev/null || echo unavailable)"
} > "$D/kernel_selectors.txt"
# THE GUEST'S CLOCK, CHECKED AGAINST THIS RUN'S.  Was pinned to the literal 34483; it is now
# whatever --fclk asked for, because the hazard is the MISMATCH and not the value.  On this port
# CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC is the only route the PL's clock takes into software and it
# sets mtime's tick AND the SiFive UART's baud divisor, so the wrong board here yields a GARBLED
# CONSOLE and an mtime off by the clock ratio, not an error.  --board and --fclk are a pair.
grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ\$" "$D/build/zephyr/.config" \
  || die "guest clock mismatch: board '$BOARD' built CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$D/build/zephyr/.config"), --fclk $FCLK_CORE needs $GUEST_KHZ.
       Pass the board variant built for this clock (boards/chipyard/) -- do NOT edit an existing one."
"$OBJDUMP" -d "$D/zephyr.elf" > "$D/dis.txt"
"$PY" - "$D/dis.txt" <<'PYG'
import re, sys
t = open(sys.argv[1]).read()
sf = sorted(set(re.findall(r'<(__(?:add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)[a-z0-9]*(?:sf|df)[0-9a-z]*)>', t)))
lm = sorted(set(re.findall(r'<(expf?|erff?|logf?|sqrtf?|tanhf?|powf?|roundf?)>', t)))
w = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
print("    custom-0=%d custom-1=%d  soft-float=%s  libm=%s"
      % (sum(1 for x in w if (int(x,16) & 0x7f) == 0x0b),
         sum(1 for x in w if (int(x,16) & 0x7f) == 0x2b),
         ",".join(sf) or "none", ",".join(lm) or "none"))
PYG
"$NM" -S "$D/zephyr.elf" | awk 'NF == 4 {
    if ($4 == "z_sys_post_kernel") print $4 ":" $1 ":1:u8";
    else if ($4 == "riscv_cpu_boot_flag" || $4 == "riscv_cpu_wake_flag") print $4 ":" $1 ":8:u64";
    else if ($4 == "big") print "big:" $1 ":32:big";
    else if ($4 == "records_") print "records_:" $1 ":" strtonum("0x" $2) ":recs";
    else if ($4 ~ /^mbxa_res_(hit|miss|full|bypass)$/) print $4 ":" $1 ":4:u32";
  }' | tr '\n' ' ' > "$D/peek_spec.txt"
info "image: $(fsize "$D/zephyr.bin") ($(stat -c %s "$D/zephyr.bin") bytes)"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }
fi   # BOARD_ONLY

if [ "$REPORT_ONLY" -eq 0 ]; then
step "4/5  the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_mic.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_micrgb.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$MOON/peek_ram.py" "$PYNQ_HOST:$PYNQ_DIR/"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"
BIT_ACCEPTED="${BIT_ACCEPTED:-} ${ROCCMOON_ACCEPTED:-32d10e5d47a4ca1f120f6f6d34e04b4e}"
bitstream_gate
# THE FEATURE GATE.  bitstream_gate has just said this build is one a lab has been
# validated against; it cannot say whether the build CONTAINS what this image will
# dispatch to.  b30_lnab_on passed bitstream_gate cleanly and then sent LayerNorm to a
# lane 0x5A5A0028 does not have.  The picks file is THIS build's.
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "$D/gen/kernel_picks.json" "$(cat "$D/kernel_cflags.txt" 2>/dev/null)"
run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  >> "$RUN/boot.log" 2>&1 || { tail -20 "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
H0=$(date +%s.%N); B0=$("${SSH[@]}" "date +%s.%N" 2>/dev/null || echo ""); H1=$(date +%s.%N)
"$PY" -c "import json,sys,datetime; h0,h1=float(sys.argv[1]),float(sys.argv[2]); b=sys.argv[3]
json.dump({'workstation_time': datetime.datetime.fromtimestamp((h0+h1)/2).astimezone().isoformat(timespec='seconds'),
  'board_time_epoch_s': float(b) if b else None,
  'board_minus_workstation_s': (float(b)-(h0+h1)/2) if b else None,
  'ssh_round_trip_s': h1-h0}, open(sys.argv[4],'w'), indent=1)" "$H0" "$H1" "$B0" "$RUN/clocks.json"

run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
PEEK="$(cat "$D/peek_spec.txt" 2>/dev/null)"
info "running (up to $MAXREAD s; the reader stops at the RESULT line)"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $MAXREAD > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  sleep 5
  echo xilinx | sudo -S python3 peek_ram.py t5 $PEEK 2>/dev/null
  t=5
  while [ \$t -lt $MAXREAD ] && ! grep -q \"^RESULT:\" console.out; do sleep 5; t=\$((t+5)); done
  echo xilinx | sudo -S python3 peek_ram.py end $PEEK 2>/dev/null
  sleep 2
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t console_bytes=\$(wc -c < console.out)
'" > "$D/board_side.log" 2>&1 || true
cat "$D/board_side.log" >> "$RUN/boot.log"
grep '^{"tag"' "$D/board_side.log" > "$D/peeks.jsonl" || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$D/console.txt" 2>/dev/null || true
cp "$RUN/fclk.json" "$D/fclk.json"
echo "$BIT_MD5" > "$D/bitstream_md5.txt"
if grep -q 'MB_PEXT_RUN' "$D/console.txt" 2>/dev/null; then
  info "$(grep -E '^MB_PEXT_RUN' "$D/console.txt" | head -1)"
else
  warn "no result ($(grep -oE 'waited=[0-9]+ console_bytes=[0-9]+' "$D/board_side.log" || true)); RAM: $(tail -1 "$D/peeks.jsonl" 2>/dev/null | cut -c1-200)"
fi
fi   # REPORT_ONLY

step "5/5  per-kind cycles"
export BIT_MD5="${BIT_MD5:-$(cat "$D/bitstream_md5.txt" 2>/dev/null)}" WANT_MAGIC
export MB_WINDOW_S="$WINDOW_S_OPT"
PRC=0
"$PY" "$RUN/report.py" "$RUN" || PRC=$?
[ "$PRC" -eq 0 ] || warn "report.py exited $PRC -- the snapshot below still runs"
# and the symptom checks, which hold whatever anybody declared: an arm that timed out
# with fallbacks, a stuck cyc_busy, or a poll count at its budget is not a measurement.
[ "$PRC" -eq 0 ] && feature_audit "$RUN/run.json"

# --------------------------------------------------------------------------------------------
# THE SNAPSHOT AND THE HEALTH CHECK, BEFORE THE VERDICT IS ACTED ON.
# --------------------------------------------------------------------------------------------
snapshot_once

step "verdict"
RC=0
"$PY" "$RUN/score.py" "$RUN" || RC=$?
[ "$PRC" -eq 0 ] || die "report.py failed (exit $PRC); the run is archived at archive/runs/$NAME"
[ "$RC" -eq 0 ] || die "verdict FAIL: $(cat "$RUN/verdict.txt"); the run is archived at archive/runs/$NAME"
info "out/$NAME/{run.json,report.txt,verdict.txt} and archive/runs/$NAME"
