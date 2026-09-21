#!/usr/bin/env bash
# Lab B43 -- ARE LAYOUT MODE PAIRS A PROPERTY OF ONE KERNEL OR OF THIS CODEGEN?
#
#   ./scripts/73_layout_modes.sh --build-only
#   scripts/with_board.sh ./scripts/73_layout_modes.sh --board-only
#
# WHY.  Lab B41 found `rope_s8` sitting in one of TWO MODES about 3.5 % apart, selected by a
# build flag and perfectly deterministic within a build -- the same image run twice gives
# bit-identical cycles.  One row of fourteen moved; the other thirteen stayed inside 0.24 %.
# That was the DATA-layout axis (MB_BUF_ALIGN64, which moves every intermediate buffer).
#
# The open question is whether that is one kernel's property or the codegen's, and the way to
# ask it is the OTHER axis: CODE layout.  `-falign-loops=4` was adopted across this campaign's
# labs for a measured reason, which already implies code placement moves something.  So: hold
# the data layout fixed, vary the loop alignment, keep the LANE OFF so every arm computes
# byte-identical output, and see how many rows move.
#
# THE TECHNIQUE, which is the reusable part:
#   1. DETERMINISM FIRST.  Re-run one image unchanged.  If it is not bit-identical, nothing
#      below means anything and the variance is the finding.  (B41: bit-identical.)
#   2. Vary ONE layout knob that cannot change the answer.  Every arm must produce the same
#      bytes -- max_abs_err = 0 -- or it is not a layout experiment.
#   3. Look for SEPARATION, not spread.  A mode pair is two tight clusters; ordinary jitter is
#      a continuum.  Report the clusters, not the min/max.
#
# PREDICTION, COMMITTED BEFORE THE BOARD: **at most 2 of the 14 rows move by more than 1 %**,
# and `rope_s8` is one of them.  Basis: the data-layout axis moved exactly one row, and the
# mechanism -- a hot inner loop or a hot buffer crossing a cache-line or page boundary -- should
# by its nature affect few kernels rather than all of them.  FALSIFIED if 5 or more rows move
# past 1 %, which would make layout sensitivity a property of the codegen and would mean every
# A/B in this campaign carries an unquantified layout term.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="layout_modes"
CAND="R"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonlanes_z1/pynqz1_rocket_micrgb_roccmoonlanes.bit"
RUNNER="run_rocket_roccmoonlanes2.py"
WANT_MAGIC="0x5A5A002A"
# the arms: loop alignment only.  align=4 is what every lab uses today and is already measured
# (B41/B42 control), so it is not rebuilt here -- it is read from out/rocket_ln_lane_ab4_off.
ARMS="none 16"
DO_BUILD=1; DO_BOARD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) DO_BOARD=0; shift ;;
    --board-only) DO_BUILD=0; shift ;;
    --arms) ARMS="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
B30="$IISWC_ROOT/scripts/57_rocket_moonshine_q16_board.sh"; need_exec "$B30"
lane_align_buffers "$WANT_MAGIC"          # data layout held FIXED at aligned, on purpose
export BIT_ACCEPTED="${BIT_ACCEPTED:-} 1e8ea02d47dc9c2c7590a879de6c1d77"

for a in $ARMS; do
  rn="${NAME}_fa$a"
  [ "$a" = none ] && kcf="-DMBXR_LN_LANE=0" || kcf="-falign-loops=$a -DMBXR_LN_LANE=0"
  if [ "$DO_BUILD" -eq 1 ]; then
    step "build arm -falign-loops=$a"
    run "$B30" --name "$rn" --candidate "$CAND" --magic "$WANT_MAGIC" --bit "$BIT" \
        --runner "$RUNNER" --kernel-cflags "$kcf" --build-only \
        > "$IISWC_OUT/$rn.build.log" 2>&1 || { tail -20 "$IISWC_OUT/$rn.build.log"; die "arm $a did not build"; }
  fi
  if [ "$DO_BOARD" -eq 1 ]; then
    step "board arm -falign-loops=$a"
    run "$B30" --name "$rn" --candidate "$CAND" --magic "$WANT_MAGIC" --bit "$BIT" \
        --runner "$RUNNER" --board-only > "$IISWC_OUT/$rn.board.log" 2>&1 \
      || warn "arm $a exited non-zero -- scored below anyway"
  fi
done
[ "$DO_BOARD" -eq 1 ] || { info "built; now: scripts/with_board.sh $0 --board-only"; exit 0; }

step "score: how many rows have a mode pair?"
python3 - "$IISWC_OUT" "$NAME" "$ARMS" <<'PY' | tee "$IISWC_OUT/$NAME.txt"
import json, os, sys
out, name, arms = sys.argv[1], sys.argv[2], sys.argv[3].split()
runs = [("fa4 (today's default)", os.path.join(out, "rocket_ln_lane_ab4_off"))]
runs += [("fa%s" % a, os.path.join(out, "%s_fa%s" % (name, a))) for a in arms]
per, mae = {}, {}
for lbl, d in runs:
    m = json.load(open(os.path.join(d, "run.json")))["models"]["enc_q16"]
    mae[lbl] = m["max_abs_err"]
    for k, v in m["per_kind"].items():
        per.setdefault(k, {})[lbl] = v["cycles"]
labels = [l for l, _ in runs]
print("Lab B43  layout mode pairs: CODE alignment swept, data alignment fixed, lane OFF")
print("  every arm must compute the same bytes: max_abs_err %s"
      % ", ".join("%s=%s" % (l, mae[l]) for l in labels))
print()
print("  %-18s %9s  %s" % ("kind", "spread", "  ".join("%-12s" % l for l in labels)))
moved = []
for k in sorted(per):
    vs = [per[k][l] for l in labels if l in per[k]]
    if len(vs) < 2:
        continue
    sp = (max(vs) - min(vs)) / float(min(vs))
    if sp > 0.01:
        moved.append((sp, k))
    print("  %-18s %8.3f%%  %s%s" % (k, 100 * sp,
          "  ".join("%-12.3f" % (v / 1e6) for v in vs), "  <== MODE PAIR" if sp > 0.01 else ""))
print()
print("  rows moving more than 1 %%: %d of %d  -> prediction (at most 2) %s"
      % (len(moved), len(per), "HELD" if len(moved) <= 2 else "FALSIFIED"))
for sp, k in sorted(moved, reverse=True):
    print("     %-16s %.2f %%" % (k, 100 * sp))
if not all(v == 0 for v in mae.values()):
    print("  *** an arm did not compute the same bytes: this is not a layout experiment ***")
json.dump({"lab": "B43 layout modes", "arms": labels, "max_abs_err": mae,
           "rows_moved_gt_1pct": [k for _, k in moved], "per_kind_cycles": per},
          open(os.path.join(out, name + ".json"), "w"), indent=1)
PY
