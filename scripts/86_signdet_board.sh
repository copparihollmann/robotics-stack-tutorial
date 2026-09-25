#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# LAB B145 -- the FIRST BOARD MEASUREMENT of SignDetLite, the colour localising detector
# Lab B144 trained and lowered.
#
#   PYNQ_HOST=xilinx@<your board> scripts/with_board.sh ./scripts/86_signdet_board.sh
#   ./scripts/86_signdet_board.sh --build-only            # no board, no lock
#
# WHAT IS BEING REPLACED.  B144 quotes 240.2 ms at 40 MHz for this network.  That number is
# an ESTIMATE and its own commit says so: 7,532,544 MAC x 1.2755 cyc/MAC, where 1.2755 is
# SignNetLite's MEASURED rate (out/sign_live_g4/run.json: 13,760,858 cycles over 10,788,224
# MAC).  A different network with a different shape mix -- 3 input channels instead of 1,
# five convolutions instead of six, a 1x1 head, an 8x8x3 grid instead of 43 logits -- has no
# obligation to hit another network's cycles per MAC.  This lab measures it.
#
# NOT THE LIVE DEMO.  samples/sign_live's main.c expects 43 classes and one softmax row and
# is untouched here.  A PERFORMANCE number needs neither camera nor OLED: this builds
# samples/modelblaster_pext -- the profiling harness that prints one MB_PEXT_OP row per
# dispatch -- against B144's generated tree, on a baked frame.
#
# THE NUMERICAL GATE, AND WHY IT IS NOT DECORATION.  A cycle count from an image that
# computed the wrong answer is worthless, so the harness diffs all 192 output bytes against a
# baked golden and reports FAIL on any difference.  The golden this lab bakes is the HOST-C
# one -- ModelBlaster's generated model.c/kernels.c compiled against pext.h's software model
# of the MBP instructions (MB_PEXT_HW=0), which is the same arithmetic B144's host_gate.py
# validated 8/8 against float torch.  The Python reference golden is kept beside it and the
# two are compared, so "the board agrees with the host" and "the host agrees with the
# reference" are two statements and not one.  A NEGATIVE CONTROL is computed as well: the
# host-C output for a DIFFERENT input, so the report can show how many of the 192 bytes a
# wrong answer would have moved.  A gate that cannot fail is not a gate.
#
# calls_engine.  This graph is quantised per channel, so its op is conv2d_s8_pc, for which
# there is NO roccmoon engine kernel -- scripts/84 says so and the picks confirm it.  The
# engine is therefore not merely declining these dispatches (as it does on the grey arm,
# where its IH==1 && KH==1 && PH==0 guard rejects every 3x3 convolution and calls_engine is 0
# in every out/sign_live*/run.json); it is not linked at all.  That is checked on the ELF
# rather than assumed, and it is why a missing MB_ROCCMOON line here is a RESULT and not a
# parse failure.
#
# B143 IS OPTIMISING THE KERNEL THIS MEASURES.  Nothing under
# fpga/pynq-z2/modelblaster/kernels/ is touched by this script: it builds against the frozen
# curated snapshot B144 left in out/signdet/kernels_board, and records the md5 of every
# kernel source that served a dispatch.  This number is the BEFORE for B143's conv work on
# this network, and it can be re-taken against the same provenance once B143 lands.
#
# NO NEW BITSTREAM AND NO RTL.  0x5A5A0038 at 40 MHz -- the same bitstream and the same clock
# out/sign_live_g4 was measured on, so the comparison against 1.2755 cyc/MAC is like for like.
set -euo pipefail

: "${BIT_ACCEPTED:=ced0aab0c7b52f25338eeffe8f678e4f}"
export BIT_ACCEPTED
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="b145_signdet"
GEN_SRC="$IISWC_ROOT/out/signdet/gen"
IR="$IISWC_ROOT/out/signdet/ir"
CUR="$IISWC_ROOT/out/signdet/kernels_board"
# The 256 real preprocessed frames B144 calibrated the PTQ on.  Used here ONLY as the
# numerical gate's control set -- see step 2.
# THE CONTROL SET COMES FROM THE LOWERING.  scripts/84_signdet_lower.sh copies whichever
# calibration array produced this graph's scales -- real or random -- to out/<name>/calib_X.npy,
# so this lab never has to know which mode ran.
CALIB="${SIGNDET_CALIB:-$IISWC_OUT/signdet/calib_X.npy}"
# WHICH FRAME THE IMAGE CARRIES.  Empty = the one generate_skeleton baked (calibration
# frame 0, which this network reads as almost entirely background: 5 distinct output
# bytes).  A number swaps in that calibration frame instead, so the gate can be run
# against an output that actually contains a detection -- and so the cycle count can be
# checked for data dependence, which the softmax memo kernel really does have.
INPUT_FRAME=""
SAMPLE="$IISWC_ROOT/samples/modelblaster_pext"
BOARD="chipyard_pynqz1_all_f40"
BUILDDIR="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98ball_z1"
BIT="$BUILDDIR/pynqz1_rocket_micrgb_roccmoonnch8f40b98ball.bit"
RUNNER="run_rocket_roccmoonnch8f40b98ball.py"
WANT_MAGIC="0x5A5A0038"
FCLK_CORE=40.0
CLK_HZ=40000000
LAB_REQUIRES="${LAB_REQUIRES:-pext}"
ITERS=11
MAXREAD=900
DO_BOARD=1
BOARD_ONLY=0
# THE ESTIMATE THIS LAB IS TESTING, and the rate it was built from.  Carried in the script so
# the report does not depend on a file another lab may rewrite.
#
# THE DENOMINATOR, because 1.2755 and 1.2762 are the same claim counted two ways.  B139's
# SignNetLite ran 13,760,858 cycles.  Over its CONVOLUTION MACs alone (10,782,720) that is
# 1.27620; over conv PLUS its one linear_s8 (10,788,224) it is 1.27554.  This lab uses the
# conv-only rate, because SignDetLite has no linear layer at all -- so conv-only is the
# like-for-like denominator, and the difference between the two is 0.05 %, an order below
# anything it is used to decide.
EST_RATE=1.2762
EST_MS=240.3
# B121/B139's kernel flags, VERBATIM from scripts/83, minus -DMBXR_RT_DRAIN_STRIDED=1 which
# lib/mbxr_abi.sh refuses on 0x5A5A0038 (no 2-D descriptor).  See scripts/83 for the full
# argument; it cannot move a cycle here either, because no engine kernel is linked at all.
KCF_ALL="-falign-loops=4 -DMBXR_RT_STAGE_BLOCK=1 -DMBP_B74=1 -DMBP_B76=1 -DMBP_B86=1 -DMBP_B87=1 -DMBP_B86D=1 -DMBP_B101L=1 -DMBP_B102=1 -DMBP_B101U=1 -DMBP_B103=1"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --gen)  GEN_SRC="${2:?}"; shift 2 ;;
    --ir)   IR="${2:?}"; shift 2 ;;
    --curated) CUR="${2:?}"; shift 2 ;;
    --calib) CALIB="${2:?}"; shift 2 ;;
    --input-frame) INPUT_FRAME="${2:?}"; shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --kernel-cflags) KCF_ALL="${2}"; shift 2 ;;
    --seconds-read) MAXREAD="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    --board-only) BOARD_ONLY=1; shift ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$GEN_SRC" in /*) : ;; *) GEN_SRC="$IISWC_ROOT/$GEN_SRC" ;; esac
case "$IR" in /*) : ;; *) IR="$IISWC_ROOT/$IR" ;; esac
need_file "$IR/graph.json"; need_file "$IR/io.npz"
need_file "$CALIB" "no calibration frames -- the numerical gate would have no control set,
       and a gate nobody has shown can fail is not evidence"
for f in model.c model.h kernels.c kernels.h weights.c weights.h buffers.c \
         test_io.h test_io.S test_input.bin test_golden.bin kernel_picks.json; do
  need_file "$GEN_SRC/$f" "B144's lowered tree is incomplete -- run scripts/84_signdet_lower.sh"
done

RUN="$IISWC_OUT/$NAME"; D="$RUN/img"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
PY="$ZCS/tools/miniforge3/envs/zephyr/bin/python"; [ -x "$PY" ] || PY=python3
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_ROOT
OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)
NM=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-nm' 2>/dev/null | head -1)

# UNCONDITIONAL, AND BEFORE THE VERDICT IS ACTED ON.  common.sh sets -e and pipefail; a
# failing run is the one whose evidence is most worth keeping and the likeliest to lose it.
SNAP_DONE=0
snapshot_once () {
  [ "$SNAP_DONE" -eq 0 ] || return 0; [ -d "$RUN" ] || return 0; SNAP_DONE=1
  local a="$IISWC_ROOT/archive/runs/$(basename "$RUN")"
  mkdir -p "$a" 2>/dev/null || return 0
  for f in run.json report.txt console.txt boot.log build.log kernel_cflags.txt \
           kernel_selectors.txt feature_gate.json fclk.json board_side.log \
           golden.json report_b145.py; do
    [ -f "$RUN/$f" ] && cp "$RUN/$f" "$a/" 2>/dev/null
    [ -f "$D/$f" ] && cp "$D/$f" "$a/" 2>/dev/null
  done
  cp "$D/gen/kernel_picks.json" "$a/" 2>/dev/null || true
  info "archived -> archive/runs/$(basename "$RUN")"
}
trap snapshot_once EXIT

if [ "$BOARD_ONLY" -eq 1 ]; then
  need_file "$D/zephyr.bin" "--board-only: no image -- run --build-only with this --name first"
else
rm -rf "$RUN"; mkdir -p "$D" "$RUN/host"

# ---------------------------------------------------------------------------
step "1/6  stage B144's generated tree, unmodified but for the two baked-in paths"
# COPIED, NOT USED IN PLACE.  This lab bakes its own host-C golden into test_golden.bin and
# out/signdet/gen is B144's record; a measurement must not rewrite the artifact it measures.
# test_io.S is the one generated file carrying absolute paths (.incbin of the two .bin), so
# it is rewritten to point at this copy and nothing else changes.
cp -r "$GEN_SRC" "$D/gen"
sed -i "s|$GEN_SRC/|$D/gen/|g" "$D/gen/test_io.S"
grep -q "$D/gen/test_input.bin" "$D/gen/test_io.S" || die "could not repoint test_io.S at $D/gen"
grep -q "$D/gen/test_golden.bin" "$D/gen/test_io.S" || die "could not repoint test_io.S at $D/gen"
if grep -q "$GEN_SRC/" "$D/gen/test_io.S"; then die "test_io.S still names $GEN_SRC -- the
       image would bake B144's bytes while this run gates on its own copy"; fi
cmp -s "$GEN_SRC/kernels.c" "$D/gen/kernels.c" || die "kernels.c changed in the copy"
if [ -n "$INPUT_FRAME" ]; then
  # THE WEIGHTS, THE KERNELS AND THE GRAPH ARE UNTOUCHED -- only the 12,288 input bytes
  # change, and test_io.S incbin's them at assembly time.  Quantised exactly as
  # signdet/host_gate.py quantises its held-out set, so the frame the board sees is the
  # frame the host model sees.
  "$PY" - "$CALIB" "$INPUT_FRAME" "$D/gen/test_input.bin" <<'PYIN'
import numpy as np, sys
X = np.load(sys.argv[1]); i = int(sys.argv[2])
if not 0 <= i < len(X):
    sys.exit("calibration frame %d is out of range (0..%d)" % (i, len(X) - 1))
q = np.clip((2 * 127 * X[i:i + 1].astype(np.uint32) + 255) // 510, 0, 127)
q.astype(np.int8).transpose(0, 3, 1, 2).reshape(-1).tofile(sys.argv[3])
print("    baked calibration frame %d as the input (%d bytes)" % (i, q.size))
PYIN
fi
"$PY" -c "
import json,sys
p=json.load(open(sys.argv[1]))['picks']
for k in sorted(p): print('    %-18s %-18s %s'%(k,p[k].get('source'),p[k].get('algorithm')))
bad=[k for k in p if p[k].get('source')=='reference']
if bad: sys.exit('reference-C fallback for: %s'%', '.join(sorted(bad)))
print('    all %d ops curated, no reference-C fallback'%len(p))" "$D/gen/kernel_picks.json" \
  || die "the lowered tree is not the zero-fallback tree B144 gated"

# ---------------------------------------------------------------------------
step "2/6  the golden this run is gated on, and the proof it could have failed"
cp "$D/gen/test_golden.bin" "$D/gen/test_golden_python.bin"
( cd "$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine" && "$PY" - \
    "$D/gen" "$RUN/host" "$RUN/golden.json" "$CALIB" "${INPUT_FRAME:--1}" <<'PYGOLD'
import hostrun, json, numpy as np, sys
gen, work, out, calib = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# The Python reference golden generate_skeleton baked belongs to ITS input.  When this
# run swapped the input for a calibration frame, that golden is a golden for a different
# picture and comparing against it would be a false statement, not a loose one.
swapped = int(sys.argv[5]) >= 0
exe = hostrun.build(gen, work)
d = hostrun.dump(exe, gen, work + "/dump.bin")
o = np.asarray(d["__output__"]).astype(np.int8)
o.tofile(gen + "/test_golden.bin")
py = np.fromfile(gen + "/test_golden_python.bin", dtype=np.int8)

# HOW MUCH ROOM THE GATE HAD TO FAIL IN.  This output is low entropy by construction -- 64
# cells of a 3-way softmax, most of them a saturated background -- so "how many of the 192
# bytes a wrong answer moves" cannot be argued from the byte count alone.  It is MEASURED,
# against the 256 real preprocessed frames B144 calibrated the PTQ on, quantised exactly as
# host_gate.py quantises them.  The question the gate has to answer is "is this THIS frame's
# answer", and the number below says how well it answers it.
x = np.fromfile(gen + "/test_input.bin", dtype=np.int8)
X = np.load(calib)
q = np.clip((2 * 127 * X.astype(np.uint32) + 255) // 510, 0, 127)
q = q.astype(np.int8).transpose(0, 3, 1, 2).reshape(len(X), -1)
O = hostrun.batch(exe, q, o.size, work)
nd = (O != o).sum(1)
md = np.abs(O.astype(int) - o.astype(int)).max(1)
same = [int(i) for i in range(len(X)) if np.array_equal(q[i], x)]
collide = [int(i) for i in np.flatnonzero(nd == 0) if i not in same]

rec = {
    "golden_source": "host-C (MB_PEXT_HW=0, pext.h software model)",
    "n": int(o.size),
    "distinct_values": int(len(np.unique(o))),
    "range": [int(o.min()), int(o.max())],
    "nonzero": int((o != 0).sum()),
    "python_golden_applies": not swapped,
    "input_frame": (int(sys.argv[5]) if swapped else None),
    "python_golden_n_differ": (None if swapped else int((py != o).sum())),
    "python_golden_max_abs": (None if swapped else
                              int(abs(py.astype(int) - o.astype(int)).max())),
    "control_frames": int(len(X)),
    "control_is_baked_input": same,
    "control_distinguished": int((nd != 0).sum()),
    "control_collisions": collide,
    "control_n_differ_median": float(np.median(nd)),
    "control_n_differ_min": int(nd.min()),
    "control_n_differ_max": int(nd.max()),
    "control_max_abs_median": float(np.median(md)),
    "golden": [int(v) for v in o],
}
json.dump(rec, open(out, "w"), indent=1)
print("    host-C golden: %d bytes, %d distinct values, range [%d, %d], %d nonzero"
      % (rec["n"], rec["distinct_values"], rec["range"][0], rec["range"][1], rec["nonzero"]))
if rec["python_golden_applies"]:
    print("    vs the Python reference golden: %d of %d bytes differ (max |d| = %d)"
          % (rec["python_golden_n_differ"], rec["n"], rec["python_golden_max_abs"]))
else:
    print("    vs the Python reference golden: n/a -- this run swapped the input for "
          "calibration frame %d," % rec["input_frame"])
    print("      and that golden belongs to the generator's own frame.")
print("    HOW DISCRIMINATING: over %d real calibration frames the same host-C model gives a"
      % rec["control_frames"])
print("      DIFFERENT 192-byte output on %d of them (median %d bytes differ, median max |d| %d);"
      % (rec["control_distinguished"], rec["control_n_differ_median"],
         rec["control_max_abs_median"]))
print("      the only frame that reproduces it is the baked input itself (index %s)."
      % (rec["control_is_baked_input"] or "NONE"))
if rec["distinct_values"] < 3:
    raise SystemExit("the golden takes fewer than 3 distinct values -- it cannot discriminate")
if not rec["control_is_baked_input"]:
    raise SystemExit("the baked test input is not one of the calibration frames -- this "
                     "control cannot speak to the gate's discrimination")
if rec["control_collisions"]:
    raise SystemExit("%d frames OTHER than the baked one reproduce the golden byte for byte: "
                     "%s -- the gate does not identify this frame's answer"
                     % (len(rec["control_collisions"]), rec["control_collisions"]))
PYGOLD
) || die "the host-C golden could not be baked (see above)"

# ---------------------------------------------------------------------------
step "3/6  build the image"
CF=$(cd "$ZCS" && "$PY" -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['roccmoon'].kernel_cflags))")
CF="$CF $KCF_ALL"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$ITERS" -DMB_WARMUP=1 \
    -DMB_JOIN_TIMEOUT_S=1800 -DMODELBLASTER_KERNEL_CFLAGS="$CF" \
    > "$RUN/build.log" 2>&1 \
  || { tail -40 "$RUN/build.log"; die "west build failed"; }
cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mbxr_abi.sh"
mbxr_abi_gate "$D/zephyr.elf" "$WANT_MAGIC" || die "guest/bitstream ABI mismatch"
echo "$CF" > "$D/kernel_cflags.txt"
grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=40000\$" "$D/build/zephyr/.config" \
  || die "guest clock mismatch: board '$BOARD' is not built for $FCLK_CORE MHz"

# WHAT SERVED EACH DISPATCH, DIGESTED.  kernel_picks_digest is necessary and not sufficient:
# it names algorithms, not graphs and not kernel SOURCE, so the IR md5 and a per-kernel-file
# md5 go beside it.  B143 is editing these very files; this is what makes the number
# attributable and re-takeable.
{ echo "gen_src=$GEN_SRC"
  echo "ir=$IR"
  echo "ir_graph_md5=$(md5sum "$IR/graph.json" | cut -d' ' -f1)"
  echo "ir_weights_md5=$(md5sum "$IR/weights.npz" | cut -d' ' -f1)"
  echo "gen_kernels_c_md5=$(md5sum "$D/gen/kernels.c" | cut -d' ' -f1)"
  echo "gen_weights_c_md5=$(md5sum "$D/gen/weights.c" | cut -d' ' -f1)"
  echo "test_input_md5=$(md5sum "$D/gen/test_input.bin" | cut -d' ' -f1)"
  echo "kernel_cflags_md5=$(md5sum "$D/kernel_cflags.txt" | cut -d' ' -f1)"
  echo "kernel_picks_digest=$("$PY" -c 'import hashlib,json,sys;p=json.load(open(sys.argv[1]))["picks"];print(hashlib.md5(";".join("%s=%s/%s"%(o,p[o].get("source"),p[o].get("algorithm")) for o in sorted(p)).encode()).hexdigest())' "$D/gen/kernel_picks.json")"
  "$PY" -c '
import json, hashlib, os, sys
p = json.load(open(sys.argv[1]))["picks"]
cur = sys.argv[2]
for op in sorted(p):
    f = os.path.join(cur, *p[op]["path"].split("/")[-2:])
    h = hashlib.md5(open(f, "rb").read()).hexdigest() if os.path.exists(f) else "MISSING"
    print("kernel_src_md5[%s]=%s %s" % (op, h, os.path.basename(f)))' \
    "$D/gen/kernel_picks.json" "$CUR"
  echo "kernels_git_head=$(git -C "$IISWC_ROOT" rev-parse HEAD)"
  echo "kernels_tree_dirty=$(git -C "$IISWC_ROOT" status --porcelain -- fpga/pynq-z2/modelblaster/kernels | wc -l)"
} > "$D/kernel_selectors.txt"
sed 's/^/    /' "$D/kernel_selectors.txt"

# THE ELF, ASKED RATHER THAN ASSUMED.  Three questions: are the custom-0 encodings there
# (the MBP kernels really compiled to the extension), is there soft float in the image (there
# must not be), and is the roccmoon engine runtime linked at all -- because "calls_engine = 0"
# and "there are no engine counters in this image" are different facts and only one of them
# is what this graph produces.
"$OBJDUMP" -d "$D/zephyr.elf" > "$D/dis.txt"
"$PY" - "$D/dis.txt" <<'PYG'
import re, sys
t = open(sys.argv[1]).read()
sf = sorted(set(re.findall(r'<(__(?:add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)[a-z0-9]*(?:sf|df)[0-9a-z]*)>', t)))
w = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
print("    custom-0=%d  soft-float=%s" % (
    sum(1 for x in w if (int(x, 16) & 0x7f) == 0x0b), ",".join(sf) or "none"))
PYG
if "$NM" "$D/zephyr.elf" 2>/dev/null | grep -qw "mbxr_rt_stats"; then
  echo "engine_runtime_linked=1" >> "$D/kernel_selectors.txt"
  info "roccmoon engine runtime: LINKED (MB_ROCCMOON counters will print)"
else
  echo "engine_runtime_linked=0" >> "$D/kernel_selectors.txt"
  info "roccmoon engine runtime: NOT LINKED -- conv2d_s8_pc has no engine kernel, so the
    engine is not consulted at all on this graph.  calls_engine is structurally 0 and no
    MB_ROCCMOON line will appear.  That is this lab's answer to question 3, not a gap."
fi
info "image: $(fsize "$D/zephyr.bin") ($(stat -c %s "$D/zephyr.bin") bytes)"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }
fi

# ---------------------------------------------------------------------------
step "4/6  the board"
require_pynq_host
board_identify || true
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_micrgb.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$PYNQ_HOST:$PYNQ_DIR/"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"
bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "$D/gen/kernel_picks.json" "$(cat "$D/kernel_cflags.txt")"
run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  >> "$RUN/boot.log" 2>&1 || { tail -20 "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
info "running (up to $MAXREAD s; the reader stops at the RESULT line)"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $MAXREAD > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  sudo -n bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $MAXREAD ] && ! grep -q \"^RESULT:\" console.out; do sleep 5; t=\$((t+5)); done
  sleep 2
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  if kill -0 \$CPID 2>/dev/null; then R=\$CPID-ALIVE; else R=none; fi
  echo waited=\$t console_bytes=\$(wc -c < console.out) reader_left=\$R
'" > "$D/board_side.log" 2>&1 || true
cat "$D/board_side.log" >> "$RUN/boot.log"
sed 's/^/    /' "$D/board_side.log"
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$D/console.txt" 2>/dev/null || true
cp "$RUN/fclk.json" "$D/fclk.json"; echo "$BIT_MD5" > "$D/bitstream_md5.txt"
[ -s "$D/console.txt" ] || die "0-byte console -- STOP and report (board etiquette): look at
       $PYNQ_DIR/console.out over ssh, not this copy."
grep -q 'MB_PEXT_RUN' "$D/console.txt" \
  || die "no MB_PEXT_RUN line ($(grep -oE 'waited=[0-9]+ console_bytes=[0-9]+' "$D/board_side.log" || true))"
info "$(grep -E '^MB_PEXT_RUN' "$D/console.txt" | head -1)"

# ---------------------------------------------------------------------------
step "5/6  the table"
cat > "$RUN/report_b145.py" <<'PYEOF'
"""B145's parser.  Copied into the run directory so a later reader can check the arithmetic
and not just the number (EXPERIMENT_LOG_RULES.md)."""
import json, os, re, sys

console, graph_p, sel_p, cf_p, gold_p, out_p = sys.argv[1:7]
clk = float(os.environ.get("CLK_HZ", "40000000"))
est_rate = float(os.environ.get("EST_RATE", "1.2755"))
est_ms = float(os.environ.get("EST_MS", "240.2"))
txt = open(console, errors="replace").read()
sel = dict(l.split("=", 1) for l in open(sel_p).read().splitlines() if "=" in l)
gold = json.load(open(gold_p))
g = json.load(open(graph_p))

def kv(line):
    return dict(re.findall(r"(\w+)=(\S+)", line))

run = next((kv(l) for l in txt.splitlines() if l.startswith("MB_PEXT_RUN")), None)
if run is None:
    sys.exit("no MB_PEXT_RUN line on the console")
build = next((kv(l) for l in txt.splitlines() if l.startswith("MB_PEXT_BUILD model=")), {})
ops = [kv(l) for l in txt.splitlines() if l.startswith("MB_PEXT_OP ")]
rocc = [kv(l) for l in txt.splitlines() if l.startswith("MB_ROCCMOON ")]
smx = next((kv(l) for l in txt.splitlines() if l.startswith("MB_SMX2 ")), {})

m = re.search(r"^MB_PEXT_OUT((?: -?\d+)+)", txt, re.M)
board_out = [int(v) for v in m.group(1).split()] if m else []

# MAC per dispatch, from the IR -- the denominator of every rate below.
mac_of, shape_of = {}, {}
for n in g["ops"]:
    d = n.get("dispatch_id")
    if d is None:
        continue
    s = n.get("shape", {})
    shape_of[int(d)] = s
    mac_of[int(d)] = (s["OH"] * s["OW"] * s["OC"] * s["IC"] * s["KH"] * s["KW"]
                      if n["op"].startswith("conv2d") else 0)
mac_total = sum(mac_of.values())

median = int(run["median"])
rows = []
for o in ops:
    i, c = int(o["id"]), int(o["cycles"])
    mac = mac_of.get(i, 0)
    rows.append({"id": i, "name": o["name"], "op": o["op"], "shape": o["shape"],
                 "cycles": c, "mac": mac,
                 "cyc_per_mac": (c / mac) if mac else None,
                 "pct": 100.0 * c / median if median else None})
row_sum = sum(r["cycles"] for r in rows)

# THE GATE.  Three separate facts: the harness's own max_abs_err against the baked golden,
# a byte-for-byte comparison done HERE against the same golden (so a harness that stopped
# comparing could not hide it), and what the negative control says the gate had to lose.
gate = {
    "harness_max_abs_err": int(run["max_abs_err"]),
    "board_bytes": len(board_out),
    "golden_bytes": gold["n"],
    "n_differ": None, "max_abs_err": None,
    "golden_distinct_values": gold["distinct_values"],
    "golden_range": gold["range"],
    "golden_nonzero": gold["nonzero"],
    "python_golden_applies": gold["python_golden_applies"],
    "python_golden_n_differ": gold["python_golden_n_differ"],
    "python_golden_max_abs": gold["python_golden_max_abs"],
    "input_frame": gold["input_frame"],
    "control_frames": gold["control_frames"],
    "control_distinguished": gold["control_distinguished"],
    "control_collisions": gold["control_collisions"],
    "control_is_baked_input": gold["control_is_baked_input"],
    "control_n_differ_median": gold["control_n_differ_median"],
    "control_n_differ_max": gold["control_n_differ_max"],
    "control_max_abs_median": gold["control_max_abs_median"],
}
if len(board_out) == gold["n"]:
    gate["n_differ"] = sum(1 for a, b in zip(board_out, gold["golden"]) if a != b)
    gate["max_abs_err"] = max(abs(a - b) for a, b in zip(board_out, gold["golden"]))
gate["pass"] = (gate["harness_max_abs_err"] == 0 and gate["n_differ"] == 0
                and gate["board_bytes"] == gate["golden_bytes"])

rate = median / mac_total
ms = median / clk * 1e3
rec = {
    "lab": "B145 signdet board",
    "name": os.environ.get("NAME", ""),
    "board": os.environ.get("IISWC_BOARD", ""),
    "pynq_host": os.environ.get("PYNQ_HOST", ""),
    "soc_magic": os.environ.get("WANT_MAGIC", ""),
    "bitstream_md5": os.environ.get("BIT_MD5", ""),
    "clk_hz": int(clk),
    "model": build.get("model"), "quant": build.get("quant"),
    "op_count": int(build["ops"]) if "ops" in build else None,
    "iters": int(build["iters"]) if "iters" in build else None,
    "pext_hw": int(build["hw"]) if "hw" in build else None,
    "selectors": sel,
    "mac_total": mac_total,
    "cycles": {"median": median, "min": int(run["min"]), "max": int(run["max"]),
               "warm_first": int(run["warm"]), "row_sum": row_sum,
               "row_sum_minus_median": row_sum - median},
    "ms_at_clk": ms,
    "cyc_per_mac": rate,
    "estimate": {"basis_cyc_per_mac": est_rate, "ms": est_ms,
                 "cycles": est_rate * mac_total,
                 "measured_over_estimate": rate / est_rate},
    "engine": {
        "runtime_linked": sel.get("engine_runtime_linked") == "1",
        "phases": {r.get("phase"): {k: int(v) for k, v in r.items()
                                    if k != "phase" and re.fullmatch(r"-?\d+", v)}
                   for r in rocc},
        "calls_engine": (int(rocc[-1]["calls_engine"]) if rocc else 0),
        "calls_fallback": (int(rocc[-1]["calls_fallback"]) if rocc else 0),
    },
    "softmax_memo": {k: int(v) for k, v in smx.items() if re.fullmatch(r"\d+", v)},
    "gate": gate,
    "ops": rows,
    "result_line": next((l for l in txt.splitlines() if l.startswith("RESULT:")), ""),
}
json.dump(rec, open(out_p, "w"), indent=1)

W = 78
p = print
p("=" * W)
p("Lab B145 -- SignDetLite on the board, %s @ %.3f MHz, %s"
  % (rec["soc_magic"], clk / 1e6, rec["board"] or rec["pynq_host"]))
p("=" * W)
p("")
p("  THE HEADLINE")
p("    measured   %12d cycles   %8.2f ms   %.4f cyc/MAC" % (median, ms, rate))
p("    estimate   %12d cycles   %8.2f ms   %.4f cyc/MAC   (B144, SignNetLite's rate)"
  % (round(est_rate * mac_total), est_rate * mac_total / clk * 1e3, est_rate))
p("               SignNetLite: 13,760,858 cyc / 10,782,720 conv MAC.  Counting its linear_s8")
p("               too gives 1.27554 and 240.20 ms -- 0.05 % away, and it changes nothing.")
p("    measured / estimated = %.4fx   (%+.1f ms)" % (rate / est_rate, ms - est_ms))
p("    %d MAC, %d dispatches, %d timed iterations, input = %s"
  % (mac_total, len(rows), rec["iters"] or 0,
     "calibration frame %d" % gate["input_frame"] if gate["input_frame"] is not None
     else "the generator's baked frame (calibration frame 0)"))
p("")
p("  SPREAD (the measurement is a measurement, not one sample)")
p("    min %d   median %d   max %d   max-min %d (%.3f%%)"
  % (rec["cycles"]["min"], median, rec["cycles"]["max"],
     rec["cycles"]["max"] - rec["cycles"]["min"],
     100.0 * (rec["cycles"]["max"] - rec["cycles"]["min"]) / median))
p("    first (cold, untimed warm-up) %d = %.4fx the warm median"
  % (rec["cycles"]["warm_first"], rec["cycles"]["warm_first"] / median))
p("")
p("  PER DISPATCH (the last timed iteration -- warm)")
p("    %-3s %-10s %-14s %10s %6s %10s  %s" %
  ("id", "name", "op", "cycles", "%", "cyc/MAC", "shape"))
for r in rows:
    p("    %-3d %-10s %-14s %10d %6.2f %10s  %s" %
      (r["id"], r["name"][:10], r["op"][:14], r["cycles"], r["pct"],
       ("%.4f" % r["cyc_per_mac"]) if r["cyc_per_mac"] is not None else "-", r["shape"]))
p("    %-3s %-10s %-14s %10d %6.2f %10.4f" %
  ("", "sum", "", row_sum, 100.0 * row_sum / median, row_sum / mac_total))
p("    rows sum to %d; the timed bracket is %d -- %+d cycles (%.3f%%) of dispatch overhead"
  % (row_sum, median, median - row_sum, 100.0 * (median - row_sum) / median))
p("")
p("  THE ACCELERATOR")
if rec["engine"]["runtime_linked"]:
    p("    calls_engine=%d  calls_fallback=%d" % (rec["engine"]["calls_engine"],
                                                  rec["engine"]["calls_fallback"]))
else:
    p("    calls_engine=0  calls_fallback=0 -- and NOT because the engine declined.")
    p("    This graph's op is conv2d_s8_pc (per-channel), for which no roccmoon engine")
    p("    kernel exists, so the engine runtime is not linked into this image at all")
    p("    (mbxr_rt_stats absent from the ELF; no MB_ROCCMOON line on the console).")
    p("    Every MAC above ran on hart 0 through the curated MBP DOT8 kernel.")
p("")
p("  THE NUMERICAL GATE")
p("    board output vs the host-C golden: %s of %s bytes differ, max |d| = %s"
  % (gate["n_differ"], gate["board_bytes"], gate["max_abs_err"]))
p("    the harness's own check on the board: max_abs_err = %d" % gate["harness_max_abs_err"])
p("    COULD IT HAVE FAILED?  the golden takes %d distinct values over [%d, %d], %d nonzero."
  % (gate["golden_distinct_values"], gate["golden_range"][0], gate["golden_range"][1],
     gate["golden_nonzero"]))
p("      Run the same host-C model on the %d real calibration frames: %d of them give a"
  % (gate["control_frames"], gate["control_distinguished"]))
p("      DIFFERENT 192-byte output (median %d bytes differ, up to %d; median max |d| %d)."
  % (gate["control_n_differ_median"], gate["control_n_differ_max"],
     gate["control_max_abs_median"]))
p("      The ONLY frame reproducing these 192 bytes is the baked input itself (index %s),"
  % (gate["control_is_baked_input"] or "NONE"))
p("      and %d other frames collide with it. So the gate identifies THIS frame's answer"
  % len(gate["control_collisions"]))
p("      out of 256 real ones -- a board computing anything else would have been caught.")
if gate["python_golden_applies"]:
    p("    host-C vs the Python reference golden: %d of %d bytes differ (max |d| = %d)"
      % (gate["python_golden_n_differ"], gold["n"], gate["python_golden_max_abs"]))
else:
    p("    host-C vs the Python reference golden: n/a -- the input was swapped for")
    p("      calibration frame %d, whose Python golden the generator never baked."
      % gate["input_frame"])
p("    VERDICT: %s" % ("PASS" if gate["pass"] else "FAIL"))
p("")
p("  PROVENANCE")
for k in ("ir_graph_md5", "ir_weights_md5", "gen_kernels_c_md5", "test_input_md5",
          "kernel_picks_digest", "kernel_cflags_md5", "kernels_git_head",
          "kernels_tree_dirty"):
    if k in sel:
        p("    %-22s %s" % (k, sel[k]))
for k in sorted(sel):
    if k.startswith("kernel_src_md5"):
        p("    %-22s %s" % (k, sel[k]))
p("    %-22s %s" % ("bitstream_md5", rec["bitstream_md5"]))
p("    %-22s %s" % ("kernel_cflags", open(cf_p).read().strip()))
p("")
p("  This is the BEFORE for Lab B143's conv2d_s8_pc optimisation on this network.")
p("=" * W)
if not gate["pass"]:
    sys.exit("B145: the numerical gate FAILED -- the cycle numbers above are not a "
             "measurement of this network")
PYEOF
BIT_MD5="${BIT_MD5:-$(cat "$D/bitstream_md5.txt" 2>/dev/null)}" \
CLK_HZ="$CLK_HZ" EST_RATE="$EST_RATE" EST_MS="$EST_MS" WANT_MAGIC="$WANT_MAGIC" NAME="$NAME" \
"$PY" "$RUN/report_b145.py" "$D/console.txt" "$IR/graph.json" "$D/kernel_selectors.txt" \
    "$D/kernel_cflags.txt" "$RUN/golden.json" "$RUN/run.json" | tee "$RUN/report.txt"

step "6/6  done"
snapshot_once
info "out/$NAME/{run.json,report.txt} and archive/runs/$NAME"
