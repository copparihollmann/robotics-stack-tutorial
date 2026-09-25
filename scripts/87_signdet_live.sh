#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# LAB B146 -- SIGNDET LIVE: point the board's camera at a traffic sign and read the answer off
# the OLED.  B144's colour localising detector, B145's measured kernels, a driver that can
# read an 8x8x3 grid, and a display a person can read from across a bench.
#
#   PYNQ_HOST=xilinx@<your board> scripts/with_board.sh ./scripts/87_signdet_live.sh
#   ./scripts/87_signdet_live.sh --build-only            # no board, no lock
#   ./scripts/87_signdet_live.sh --frames 40 --thr 40    # a shorter, looser bench run
#
# THE BOARD MUST HAVE AN SSD1306 FITTED.  This lab's whole output is on the glass: on a board
# with nothing on the I2C bus the boot line reads `oled ABSENT / no_ack_at_0x3c_0x3d` and the
# run continues with the console as its only output.  PYNQ_HOST selects the board -- the lock
# does NOT.  See fpga/pynq-z2/docs/OLED_SSD1306.md for the wiring.
#
# WHAT IS NEW HERE AND WHAT IS NOT.  Nothing about the model, the kernels or the front end is
# new: the network is B144's (out/signdet/gen, zero reference-C), the kernel flags are B145's
# verbatim so a millisecond here is comparable with its 237.78, and the colour front end is
# the sign_pre_rgb.c B144 checked byte for byte against its Python definition.  What is new is
# samples/signdet_live -- the driver that turns 64 cells x 3 classes into one word on a 128x64
# panel, and declines to name a class when nothing is above the threshold.
#
# THE GATES, AND THAT THEY CAN FAIL:
#
#   1  sign_pre_rgb_selftest() runs at boot and its return code is on the console.  A
#      non-zero one stops the run before a single frame is captured.
#
#   2  REPLAY.  The 8 REAL captures in out/cam_snap/snaps are baked into the image with the
#      HOST's answer for each -- class, peak cell, confidence, and the whole 192-byte output
#      tensor.  The board must reproduce all of it from the raw DMA bytes.  One of the 8 is a
#      frame the host DECLINES (snap_015, 0.425 < 0.50); the board has to decline it too,
#      which is the only way to gate the behaviour this model exists for.  A mismatch on any
#      frame is a FINDING and this script reports it rather than tuning past it.
#
#   3  The usual image gates: custom-0 encodings present, no soft float, the ABI stamp
#      against 0x5A5A0038, the guest clock at 40 MHz, and the picks with no reference-C.
#
# NO NEW BITSTREAM AND NO RTL.  0x5A5A0038 at 40 MHz -- the same bitstream and the same clock
# B139 and B145 ran on, so the comparison against 237.78 ms is like for like.
set -euo pipefail

: "${BIT_ACCEPTED:=ced0aab0c7b52f25338eeffe8f678e4f}"
export BIT_ACCEPTED
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="b146_signdet_live"
GEN_SRC="$IISWC_ROOT/out/signdet/gen"
IR="$IISWC_ROOT/out/signdet/ir"
CUR="$IISWC_ROOT/out/signdet/kernels_board"
SNAPS="$IISWC_ROOT/out/cam_snap/snaps"
SAMPLE="$IISWC_ROOT/samples/signdet_live"
BOARD="chipyard_pynqz1_all_f40"
BUILDDIR="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98ball_z1"
BIT="$BUILDDIR/pynqz1_rocket_micrgb_roccmoonnch8f40b98ball.bit"
RUNNER="run_rocket_roccmoonnch8f40b98ball.py"
WANT_MAGIC="0x5A5A0038"
FCLK_CORE=40.0
CLK_HZ=40000000
OSPI_IRQ=13
LAB_REQUIRES="${LAB_REQUIRES:-pext}"
THR=50
# LIVE INFERENCES BEFORE THE IMAGE STOPS.  ~0.5 s each (238 ms of network, a capture, the L2
# sweep that makes the frame pullable, and an 82 ms screen), so 400 is about 3.5 minutes of
# somebody holding signs in front of the lens.  Raise it for a longer session; it has to END
# so the console reader sees SD_DONE and the report can be scored.
FRAMES=400
MCLKDIV=3
AE_TARGET=0x60
BUTTON=0
# Print cam_snap's SNAP line so scripts/85_cam_snap_pull.sh can pull every frame.  OFF by
# default: scripts/85 keys on the LINE and not on the app, so a puller somebody left running
# with another --name will file this demo's frames in ITS directory.  See samples/
# signdet_live/src/main.c, which has the incident that made this a flag.
PULL=0
MAXREAD=900
DO_BOARD=1
BOARD_ONLY=0
DO_REPLAY=1
# B145's flags, VERBATIM, so this lab's ms/frame is comparable with its 237.78 ms.  See
# scripts/86 for why -DMBXR_RT_DRAIN_STRIDED=1 is absent (0x5A5A0038 has no 2-D descriptor,
# and no engine kernel is linked on this graph in any case).
KCF_ALL="-falign-loops=4 -DMBXR_RT_STAGE_BLOCK=1 -DMBP_B74=1 -DMBP_B76=1 -DMBP_B86=1 -DMBP_B87=1 -DMBP_B86D=1 -DMBP_B101L=1 -DMBP_B102=1 -DMBP_B101U=1 -DMBP_B103=1"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --gen)  GEN_SRC="${2:?}"; shift 2 ;;
    --ir)   IR="${2:?}"; shift 2 ;;
    --curated) CUR="${2:?}"; shift 2 ;;
    --snaps) SNAPS="${2:?}"; shift 2 ;;
    --thr)  THR="${2:?}"; shift 2 ;;
    --frames) FRAMES="${2:?}"; shift 2 ;;
    --button) BUTTON=1; shift ;;
    --pull) PULL=1; shift ;;
    --mclkdiv) MCLKDIV="${2:?}"; shift 2 ;;
    --ae-target) AE_TARGET="${2:?}"; shift 2 ;;
    --no-replay) DO_REPLAY=0; shift ;;
    --kernel-cflags) KCF_ALL="${2}"; shift 2 ;;
    --seconds-read) MAXREAD="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    --board-only) BOARD_ONLY=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$GEN_SRC" in /*) : ;; *) GEN_SRC="$IISWC_ROOT/$GEN_SRC" ;; esac
case "$IR" in /*) : ;; *) IR="$IISWC_ROOT/$IR" ;; esac

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
  for f in run.json report.txt console.txt boot.log build.log bake.log kernel_cflags.txt \
           kernel_selectors.txt feature_gate.json fclk.json board_side.log dis_probe.txt \
           signdet_frames.json report_b146.py frame.pgm; do
    [ -f "$RUN/$f" ] && cp "$RUN/$f" "$a/" 2>/dev/null
    [ -f "$D/$f" ] && cp "$D/$f" "$a/" 2>/dev/null
  done
  cp "$D/gen/kernel_picks.json" "$a/" 2>/dev/null || true
  info "archived -> archive/runs/$(basename "$RUN")"
}
trap snapshot_once EXIT

if [ "$BOARD_ONLY" -eq 1 ]; then
  need_file "$D/zephyr.bin" "--board-only: no image -- run --build-only with this --name first"
  need_file "$D/kernel_selectors.txt" "--board-only: no kernel_selectors.txt"
  GEN="$D/gen"
  need_file "$GEN/kernel_picks.json" "--board-only: no $GEN/kernel_picks.json -- rebuild"
  info "--board-only: reusing $D/zephyr.bin ($(stat -c %s "$D/zephyr.bin") bytes)"
  sed 's/^/    /' "$D/kernel_selectors.txt"
else
rm -rf "$RUN"; mkdir -p "$D" "$RUN/host"

# ---------------------------------------------------------------------------
step "1/6  B144's lowered tree, staged and gated"
for f in model.c model.h kernels.c kernels.h weights.c weights.h buffers.c kernel_picks.json; do
  need_file "$GEN_SRC/$f" "B144's lowered tree is incomplete -- run scripts/84_signdet_lower.sh"
done
# COPIED, NOT USED IN PLACE: out/signdet/gen is B144's record and a demo must not rewrite the
# artifact it demonstrates.
cp -r "$GEN_SRC" "$D/gen"
GEN="$D/gen"
cmp -s "$GEN_SRC/kernels.c" "$GEN/kernels.c" || die "kernels.c changed in the copy"
"$PY" -c "
import json,sys
p=json.load(open(sys.argv[1]))['picks']
for k in sorted(p): print('    %-18s %-18s %s'%(k,p[k].get('source'),p[k].get('algorithm')))
bad=[k for k in p if p[k].get('source')=='reference']
if bad: sys.exit('reference-C fallback for: %s'%', '.join(sorted(bad)))
print('    all %d ops curated, no reference-C fallback'%len(p))" "$GEN/kernel_picks.json" \
  || die "the lowered tree is not the zero-fallback tree B144 gated"

# The output quantisation the guest must use to turn an int8 into a probability, READ FROM
# THE GRAPH rather than trusted: a model with a different output scale would otherwise be
# reported at a confidently wrong confidence.
SCALE_DEFS="$("$PY" -c "
import json,sys
g=json.load(open(sys.argv[1]))
t=g['tensors']; qi=t[g['input']['tensor']]['quant']; qo=t[g['output']['tensor']]['quant']
r=1.0/float(qi['scale'])
if int(qi['zero_point'])!=0 or abs(r-round(r))>1e-6:
    sys.exit('input grid is not a symmetric integer reciprocal: %r'%qi)
if int(qo['zero_point'])!=0:
    sys.exit('the output softmax has zero_point %d; main.c decodes assuming 0'%int(qo['zero_point']))
n=t[g['output']['tensor']]['shape'][-1]
if n!=3: sys.exit('this graph has %d classes per cell, not 3'%n)
print('SD_OUT_SCALE_PPB=%du'%round(float(qo['scale'])*1e9))
" "$IR/graph.json")"
info "scales from graph.json: $SCALE_DEFS"

# ---------------------------------------------------------------------------
step "2/6  the replay gate: the 8 real captures and the HOST's answer for each"
BAKE_ARG=()
if [ "$DO_REPLAY" -eq 1 ]; then
  [ -d "$SNAPS" ] || die "no bench captures at $SNAPS -- the board would make NO checkable
       claim about detection.  --no-replay says so deliberately."
  mkdir -p "$RUN/bake"
  run "$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/signdet/bake_live_frames.py" \
      --gen "$GEN" --ir "$IR" --snaps "$SNAPS" --thr "$("$PY" -c "print($THR/100.0)")" \
      --workdir "$RUN/host" --out "$RUN/bake" > "$RUN/bake.log" 2>&1 \
    || { tail -20 "$RUN/bake.log"; die "could not bake the replay frames"; }
  sed -n '/^gate set/,$p' "$RUN/bake.log" | sed 's/^/    /'
  cp "$RUN/bake/signdet_frames.json" "$RUN/signdet_frames.json"
  BAKE_ARG=(-DSD_FRAMES_DIR="$RUN/bake")
else
  warn "--no-replay: this image cannot check itself against a known answer"
fi

# ---------------------------------------------------------------------------
step "3/6  build the image ($BOARD, thr=${THR}%, frames=$FRAMES, button=$BUTTON)"
SD_DEFS="SD_THR_PCT=$THR SD_FRAMES=$FRAMES SD_MCLKDIV=$MCLKDIV SD_AE_TARGET=$AE_TARGET"
SD_DEFS="$SD_DEFS SD_BUTTON=$BUTTON SD_SNAP_LINE=$PULL $SCALE_DEFS"
CF=$(cd "$ZCS" && "$PY" -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['roccmoon'].kernel_cflags))")
CF="$CF $KCF_ALL"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$GEN" "${BAKE_ARG[@]}" \
    -DSD_DEFS="$SD_DEFS" -DMODELBLASTER_KERNEL_CFLAGS="$CF" \
    > "$RUN/build.log" 2>&1 \
  || { tail -40 "$RUN/build.log"; die "west build failed"; }
cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
cp "$D/build/zephyr/zephyr.dts" "$D/" 2>/dev/null || true
echo "$CF" > "$D/kernel_cflags.txt"

# ---------------------------------------------------------------------------
step "4/6  gates on the image, before any board is touched"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mbxr_abi.sh"
mbxr_abi_gate "$D/zephyr.elf" "$WANT_MAGIC" || die "guest/bitstream ABI mismatch"
grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=40000\$" "$D/build/zephyr/.config" \
  || die "guest clock mismatch: board '$BOARD' is not built for $FCLK_CORE MHz"
grep -q '^CONFIG_MB_PEXT=y' "$D/build/zephyr/.config" \
  || die "CONFIG_MB_PEXT is not y: the kernels would be pext.h's SOFTWARE MODEL, bit-identical
       and nowhere near the speed -- and nothing on the console would say so"
grep -q '^CONFIG_I2C_SIFIVE=y' "$D/build/zephyr/.config" \
  || die "CONFIG_I2C_SIFIVE is not set: neither the sensor nor the display would answer"
grep -q '^CONFIG_SSD1306=y' "$D/build/zephyr/.config" \
  || die "CONFIG_SSD1306 is not set: there is no display driver in this image"
"$PY" - "$D/zephyr.dts" "$OSPI_IRQ" <<'PYDT'
import re, sys
t = open(sys.argv[1]).read()
want = {"uart@10020000": 2, "i2c@10040000": 1, "ospi@10080000": int(sys.argv[2])}
for node, irq in want.items():
    m = re.search(re.escape(node) + r"\s*\{(.*?)\n\t\};", t, re.S)
    if not m:
        sys.exit("the built devicetree has no %s" % node)
    body = m.group(1)
    got = re.search(r"interrupts\s*=\s*<\s*(0x[0-9a-f]+|\d+)", body)
    if not got or int(got.group(1), 0) != irq:
        sys.exit("%s: interrupts = %s, expected %d" % (node, got and got.group(1), irq))
    if 'status = "okay"' not in body:
        sys.exit("%s is not okay in the built devicetree" % node)
print("    devicetree: uart 2, i2c 1, ospi %s -- this SoC's numbering" % sys.argv[2])
PYDT
"$OBJDUMP" -d "$D/zephyr.elf" > "$D/dis.txt"
"$PY" - "$D/dis.txt" > "$D/dis_probe.txt" <<'PYG'
import re, sys
t = open(sys.argv[1]).read()
sf = sorted(set(re.findall(
    r'<(__(?:add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)[a-z0-9]*(?:sf|df)[0-9a-z]*)>', t)))
w = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
n = sum(1 for x in w if (int(x, 16) & 0x7f) == 0x0b)
print("custom0=%d soft_float=%s" % (n, ",".join(sf) or "none"))
if n == 0:
    sys.exit("this ELF contains NO custom-0 (MBP) instruction: nothing would run on the "
             "P-extension, whatever kernel_picks.json says")
PYG
sed 's/^/    /' "$D/dis_probe.txt"
grep -q 'soft_float=none' "$D/dis_probe.txt" \
  || warn "soft-float symbols are linked in: $(cat "$D/dis_probe.txt") -- check which kernel
       pulled one in before quoting a millisecond."

{ echo "gen_src=$GEN_SRC"
  echo "ir=$IR"
  echo "ir_graph_md5=$(md5sum "$IR/graph.json" | cut -d' ' -f1)"
  echo "ir_weights_md5=$(md5sum "$IR/weights.npz" | cut -d' ' -f1)"
  echo "gen_kernels_c_md5=$(md5sum "$GEN/kernels.c" | cut -d' ' -f1)"
  echo "gen_weights_c_md5=$(md5sum "$GEN/weights.c" | cut -d' ' -f1)"
  echo "sign_pre_rgb_md5=$(md5sum "$IISWC_ROOT/fpga/pynq-z2/sw/cam/sign_pre_rgb.c" | cut -d' ' -f1)"
  echo "main_c_md5=$(md5sum "$SAMPLE/src/main.c" | cut -d' ' -f1)"
  echo "kernel_cflags_md5=$(md5sum "$D/kernel_cflags.txt" | cut -d' ' -f1)"
  echo "sd_defs=$SD_DEFS"
  echo "replay=$([ "$DO_REPLAY" -eq 1 ] && echo 1 || echo 0)"
  echo "$(tr ' ' '\n' < "$D/dis_probe.txt" | grep .)"
  echo "kernel_picks_digest=$("$PY" -c 'import hashlib,json,sys;p=json.load(open(sys.argv[1]))["picks"];print(hashlib.md5(";".join("%s=%s/%s"%(o,p[o].get("source"),p[o].get("algorithm")) for o in sorted(p)).encode()).hexdigest())' "$GEN/kernel_picks.json")"
  "$PY" -c '
import json, hashlib, os, sys
p = json.load(open(sys.argv[1]))["picks"]
cur = sys.argv[2]
for op in sorted(p):
    f = os.path.join(cur, *p[op]["path"].split("/")[-2:])
    h = hashlib.md5(open(f, "rb").read()).hexdigest() if os.path.exists(f) else "MISSING"
    print("kernel_src_md5[%s]=%s %s" % (op, h, os.path.basename(f)))' \
    "$GEN/kernel_picks.json" "$CUR"
  echo "git_head=$(git -C "$IISWC_ROOT" rev-parse HEAD)"
} > "$D/kernel_selectors.txt"
if "$NM" "$D/zephyr.elf" 2>/dev/null | grep -qw "mbxr_rt_stats"; then
  echo "engine_runtime_linked=1" >> "$D/kernel_selectors.txt"
else
  echo "engine_runtime_linked=0" >> "$D/kernel_selectors.txt"
  info "roccmoon engine runtime: NOT LINKED -- conv2d_s8_pc has no engine kernel, so the
    engine is not consulted at all on this graph.  That is B145's finding, not a gap."
fi
sed 's/^/    /' "$D/kernel_selectors.txt"
info "image: $(fsize "$D/zephyr.bin") ($(stat -c %s "$D/zephyr.bin") bytes)"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }
fi

# ---------------------------------------------------------------------------
step "5/6  the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to \$PYNQ_HOST.  THE LOCK DOES NOT SELECT THE BOARD:
       scripts/with_board.sh serialises access, PYNQ_HOST and nothing else says which
       machine.  See board.conf.example; there is no default on purpose."
# WHICH PHYSICAL BOARD, resolved the way scripts/lib/board_id.sh documents: an explicit
# IISWC_BOARD wins, then a lookup of PYNQ_HOST in the per-bench register, then a refusal.
# bwlab/boards.csv SHIPS EMPTY -- it is a register of the boards a given bench owns, not a
# list anyone has to join -- so on a fresh clone the export is the normal answer.
B146_BOARD="${IISWC_BOARD:-}"
[ -n "$B146_BOARD" ] || B146_BOARD="$("$PY" -c '
import csv,sys
h=sys.argv[1]
for r in csv.DictReader(l for l in open(sys.argv[2]) if not l.startswith("#")):
    if r["pynq_host"]==h: print(r["board"]); break
else: print("UNKNOWN")' "$PYNQ_HOST" "$IISWC_ROOT/fpga/pynq-z2/bwlab/boards.csv")"
{ echo "pynq_host=$PYNQ_HOST"; echo "board=$B146_BOARD"; } >> "$D/kernel_selectors.txt"
info "board: $B146_BOARD ($PYNQ_HOST)"
[ "$B146_BOARD" = UNKNOWN ] && die "PYNQ_HOST=$PYNQ_HOST is not a row in bwlab/boards.csv.
       Add one (it ships empty on purpose -- it is a per-bench register), or export
       IISWC_BOARD=<short-name>.  A run that cannot name its board must not write a row."
# THE OLED IS A PER-BENCH FITTING, and this lab's output is on it.  The board itself answers
# the question a few lines later -- `oled ABSENT / no_ack_at_0x3c_0x3d` on the boot line -- so
# it is not asserted here from a board name; everything but the glass runs either way and the
# console carries the same decisions.

need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"
bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "$GEN/kernel_picks.json" \
    "$(cat "$D/kernel_cflags.txt")"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_micrgb.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/read_mem.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  > "$RUN/boot.log" 2>&1 || { tail -20 "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && sudo -n python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
info "running (up to $MAXREAD s; the reader stops at SD_DONE)"
if [ "$PULL" -eq 1 ]; then
  info "--pull: this image prints cam_snap's SNAP line.  In ANOTHER shell, NOW:"
  info "    ./scripts/85_cam_snap_pull.sh --name $NAME --host $PYNQ_HOST"
  warn "any OTHER scripts/85 already tailing this board will also collect these frames,
       into ITS --name directory.  Check before you start: ps -eo args | grep 85_cam_snap"
else
  info "frame addresses are on every SD_INFER line; --pull adds the SNAP line scripts/85 reads"
fi
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $MAXREAD > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  sudo -n bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $MAXREAD ] && ! grep -q \"^SD_DONE\" console.out; do sleep 5; t=\$((t+5)); done
  sleep 2
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  if kill -0 \$CPID 2>/dev/null; then R=\$CPID-ALIVE; else R=none; fi
  echo waited=\$t console_bytes=\$(wc -c < console.out) reader_left=\$R
'" > "$D/board_side.log" 2>&1 || true
cat "$D/board_side.log" >> "$RUN/boot.log"
sed 's/^/    /' "$D/board_side.log"
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
cp "$RUN/fclk.json" "$D/fclk.json"; echo "$BIT_MD5" > "$D/bitstream_md5.txt"
BYTES=$(wc -c < "$RUN/console.txt" 2>/dev/null || echo 0)
if [ "${BYTES:-0}" -eq 0 ] || grep -q "PS_HOLDS" "$RUN/boot.log"; then
  cat "$RUN/boot.log"; snapshot_once
  die "0 console bytes or PS_HOLDS. STOP all board work and report (board etiquette,
       docs/EXPERIMENT_LOG_RULES.md).  Nothing from this run is a result."
fi
grep -q '^SD_BOOT' "$RUN/console.txt" \
  || { tail -40 "$RUN/console.txt"; die "no SD_ lines: the guest did not reach main"; }

# THE LAST FRAME THE CAMERA SAW, read back by the PS.  The guest swept the L2 before each
# SD_INFER, so these are the bytes the guest decoded.  Advisory: a failure is not a verdict.
PHYS=$(grep -oE '^SD_INFER .*addr=0x[0-9a-f]+' "$RUN/console.txt" | tail -1 \
       | grep -oE 'addr=0x[0-9a-f]+' | cut -d= -f2 || true)
if [ -n "${PHYS:-}" ]; then
  PS_PHYS=$("$PY" -c "a=int('$PHYS',16); print(hex(0x10000000 | (a & 0x0fffffff)))")
  "${SSH[@]}" "cd $PYNQ_DIR && sudo -n python3 read_mem.py --phys $PS_PHYS --bytes 105624 --out frame.raw" \
    >> "$RUN/boot.log" 2>&1 && scp -q "$PYNQ_HOST:$PYNQ_DIR/frame.raw" "$RUN/frame.raw" \
    && "$PY" -c "
import sys
d=open(sys.argv[1],'rb').read()
rows=[d[i*326+2:i*326+2+324] for i in range(324)]
open(sys.argv[2],'wb').write(b'P5\n324 324\n255\n'+b''.join(rows))
print('    frame.pgm: 324x324, the padding columns dropped')" "$RUN/frame.raw" "$RUN/frame.pgm" \
    || warn "the PS could not read the frame back (advisory, not a verdict)"
fi

# ---------------------------------------------------------------------------
step "6/6  the table"
cat > "$RUN/report_b146.py" <<'PYEOF'
"""B146's parser.  It travels with the run so a later reader can check the arithmetic and not
just the number (docs/EXPERIMENT_LOG_RULES.md)."""
import json, os, re, sys

console, sel_p, out_p = sys.argv[1:4]
clk = float(os.environ.get("CLK_HZ", "40000000"))
b145_ms = float(os.environ.get("B145_MS", "237.78"))
txt = open(console, errors="replace").read()
sel = dict(l.split("=", 1) for l in open(sel_p).read().splitlines() if "=" in l)


def kv(line):
    return dict(re.findall(r"(\w+)=(\S+)", line))


def first(prefix):
    return next((kv(l) for l in txt.splitlines() if l.startswith(prefix)), {})


boot = first("SD_BOOT")
res = first("SD_RESULT")
msl = first("SD_MS")
sel_t = first("SD_SELFTEST")
oled = next((l for l in txt.splitlines() if l.startswith("SD_OLED state=")), "")
if not boot:
    sys.exit("no SD_BOOT line")

replay = [kv(l) for l in txt.splitlines() if l.startswith("SD_REPLAY i=")]
infer = [kv(l) for l in txt.splitlines() if l.startswith("SD_INFER ")]
live = [d for d in infer if d.get("src") == "live"]
ms = sorted(int(d["ms"]) for d in live) or [0]

rec = {
    "lab": "B146",
    "board": sel.get("board"), "pynq_host": sel.get("pynq_host"),
    "model": boot.get("model"), "thr_pct": int(boot.get("thr_pct", 0)),
    "grid": boot.get("grid"), "out_scale_ppb": boot.get("out_scale_ppb"),
    "selftest_sign_pre_rgb": int(sel_t.get("sign_pre_rgb", -1)),
    "oled": oled, "clk_hz": clk,
    "replay_n": len(replay),
    "replay_decisions_ok": int(res.get("replay_decisions_ok", -1)),
    "replay_tensors_ok": int(res.get("replay_tensors_ok", -1)),
    "replay_correct_vs_truth": sum(int(d.get("correct", 0)) for d in replay),
    "replay_rows": replay,
    "live_inferences": len(live),
    "live_ok": int(res.get("live_ok", 0)),
    "ms_min": ms[0], "ms_median": ms[len(ms) // 2], "ms_max": ms[-1],
    "ms_mean": int(msl.get("ms_mean", 0)),
    "b145_ms": b145_ms,
    "kernel_selectors": sel,
}
json.dump(rec, open(out_p, "w"), indent=1)

W = 78
print("=" * W)
print("B146  SIGNDET LIVE -- camera -> SignDetLite -> the class on the OLED")
print("=" * W)
print("board          %s (%s)" % (rec["board"], rec["pynq_host"]))
print("model          %s  grid %s  threshold %d%%" % (rec["model"], rec["grid"], rec["thr_pct"]))
print("display        %s" % (oled or "no SD_OLED line"))
print("front end      sign_pre_rgb_selftest = %d %s" % (
    rec["selftest_sign_pre_rgb"], "(PASS)" if rec["selftest_sign_pre_rgb"] == 0 else "(FAIL)"))
print()
print("-" * W)
print("THE REPLAY GATE -- 8 real captures, the board against the HOST's answer")
print("-" * W)
print("%-20s %-6s %-14s %-14s %-9s %s" %
      ("capture", "truth", "host", "board", "decision", "tensor"))
for d in replay:
    print("%-20s %-6s %-14s %-14s %-9s %s (%s bytes differ, max |d| %s)" %
          (d.get("name", "?")[:20], d.get("truth"), d.get("host"), d.get("board"),
           d.get("decision"), d.get("tensor"), d.get("bytes_differ"), d.get("max_abs_err")))
print()
print("decisions match the host on %d/%d;  output tensors match on %d/%d" % (
    sum(d.get("decision") == "MATCH" for d in replay), len(replay),
    sum(d.get("tensor") == "MATCH" for d in replay), len(replay)))
declined = [d.get("name") for d in replay if d.get("board", "").startswith("none")]
print("board agrees with B144's hand labels on %d/%d.  The board is scored against the HOST "
      "above;" % (rec["replay_correct_vs_truth"], len(replay)))
print("this line is the MODEL's accuracy on 8 images and is not a reliability figure.")
if declined:
    print("declined (below the %d%% threshold, reported as NO SIGN rather than guessed): %s"
          % (rec["thr_pct"], ", ".join(declined)))
print()
print("-" * W)
print("LIVE")
print("-" * W)
print("inferences     %d (%d with a clean capture)" % (rec["live_inferences"], rec["live_ok"]))
if live:
    print("ms per frame   min %d  median %d  max %d  (mean %d)" %
          (rec["ms_min"], rec["ms_median"], rec["ms_max"], rec["ms_mean"]))
    print("B145 measured  %.2f ms for the same graph on the same bitstream and clock" % b145_ms)
    seen = {}
    for d in live:
        seen[d.get("name")] = seen.get(d.get("name"), 0) + 1
    print("what it saw    %s" % ", ".join("%s x%d" % (k, v) for k, v in sorted(seen.items())))
else:
    print("no live inferences on the console")
print()

bad = []
if rec["selftest_sign_pre_rgb"] != 0:
    bad.append("the colour front end's selftest failed")
if rec["replay_n"] and rec["replay_decisions_ok"] != 1:
    bad.append("the board and the host DISAGREE on a replay frame -- that is a finding")
if rec["replay_n"] and rec["replay_tensors_ok"] != 1:
    bad.append("a replay output tensor differs from the host's")
if not rec["replay_n"]:
    bad.append("no replay frames: this run makes no checkable claim about detection")
if rec["live_ok"] == 0:
    bad.append("no clean live capture")
print("VERDICT: %s" % ("PASS" if not bad else "FAIL"))
for b in bad:
    print("  - %s" % b)
sys.exit(1 if bad else 0)
PYEOF
RC=0
CLK_HZ=$CLK_HZ "$PY" "$RUN/report_b146.py" "$RUN/console.txt" "$D/kernel_selectors.txt" \
    "$RUN/run.json" > "$RUN/report.txt" 2>&1 || RC=$?
cat "$RUN/report.txt"
snapshot_once
# A TIMESTAMPED COPY, the same call scripts/83 makes.  Every run of this script uses the same
# --name and therefore the same out/ directory, so without this a second session silently
# overwrites the first one's console -- which is exactly how B146's own 400-frame run with a
# person holding signs in front of the lens lost its console.
"$IISWC_ROOT/archive/tools/archive_run.py" "$NAME" >/dev/null 2>&1 || true
[ "$RC" -eq 0 ] || die "verdict FAIL (rc=$RC) -- read out/$NAME/report.txt"
info "out/$NAME/{run.json,report.txt,console.txt,frame.pgm} and archive/runs/$NAME"
