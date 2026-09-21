#!/usr/bin/env bash
# Lab B106 -- YOLOv8n on the roccmoon accelerator, and the ONE PREDICATE that decides how
# much of a modern detector a 1-D convolution engine can take.
#
#   scripts/with_board.sh ./scripts/75_rocket_yolo_board.sh --ir archive/b106/ir160 --name b106_yolo_base
#   scripts/with_board.sh ./scripts/75_rocket_yolo_board.sh --ir archive/b106/ir160_flat --name b106_yolo_flat
#   ./scripts/75_rocket_yolo_board.sh --build-only ...
#
# THE QUESTION.  The engine measures 44.409 MAC/cycle on the Moonshine encoder, 69.4 % of
# the NCH = 8 peak of 64.  The curated MBP convolution on hart 0 measures 0.588-0.767
# MAC/cycle dense.  That is 58x to 75x PER MAC -- *where a layer maps*.  YOLOv8n is where
# it does not, and this lab measures by how much rather than arguing about it.
#
# THE TWO ARMS DIFFER IN THE IR AND IN NOTHING ELSE.  kernel_picks, kernel_cflags, the
# bitstream, the curated tree and every weight byte are identical; 24 conv2d_s8 shapes are
# rewritten from (IH, IW) to (1, IH*IW) by fpga/pynq-z2/modelblaster/yolo/ir_flatten1x1.py,
# which for a 1x1 stride-1 unpadded convolution in NCHW names the same bytes in the same
# order.  ***So kernel_selectors.txt CANNOT distinguish these arms and is not asked to.***
# The distinguishing counter is MB_ROCCMOON's `calls_engine`, and it is pre-registered.
#
# WHAT IT REPORTS, per arm:  cycles, MAC/cycle achieved against the engine's 44.409,
# calls_engine / calls_fallback, bytes_wgt and image_bytes (the weight stream), and the
# per-kind table -- including the kinds that have NO curated kernel and run reference C.
#
# NO NEW BITSTREAM AND NO RTL.  0x5A5A0035 is 13,256 of 13,300 slices with forty-four
# spare (B103); everything here is software on the bitstream that is already on the bench.
set -euo pipefail

: "${BIT_ACCEPTED:=995798bedfb15cff077ab58710af3bf8}"
export BIT_ACCEPTED
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="b106_yolo"
IR=""
BOARD="chipyard_pynqz1_micrgb_f40"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98b_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98b.bit"
# THE RUNNER IS KEYED BY THE BITSTREAM'S NAME, NOT CHOSEN.  fpga/pynq-z2/host/run_rocket_*.py
# is ONE file per build whose MAGIC is decided by its own filename, and a runner that does not
# match refuses a perfectly good bitstream with "*** MISMATCH ***" on the very MAGIC it just
# read correctly.  Derived from --bit so the two cannot drift; RUNNER= in the environment wins.
RUNNER=""
SAMPLE="$IISWC_ROOT/samples/modelblaster_pext"
WANT_MAGIC="0x5A5A0035"
LAB_REQUIRES="${LAB_REQUIRES:-rocc_engine pext lut_lane}"
FCLK_CORE=40.0
ITERS=1
MAXREAD=3600
DO_BOARD=1
# THE KERNEL FLAGS THE MOONSHINE ARM WAS MEASURED WITH, VERBATIM.  The 44.409 MAC/cycle
# this lab quotes against was measured on out/b103_fold_0035_f40, whose kernel_cflags carry
# B102's staging pipeline, the strided drain and the hart-0 kernel folds.  An arm built
# without them would be compared against a number produced with them, which is the error
# family this log keeps cataloguing.  Overridable with --kernel-cflags.
KCF_ALL="-falign-loops=4 -DMBXR_RT_DRAIN_STRIDED=1 -DMBXR_RT_STAGE_BLOCK=1 -DMBP_B74=1 -DMBP_B76=1 -DMBP_B86=1 -DMBP_B87=1 -DMBP_B86D=1 -DMBP_B101L=1 -DMBP_B102=1 -DMBP_B101U=1 -DMBP_B103=1"
PLACE_EARLY_CFLAG="-DMBXR_RT_PLACE_EARLY=1"
# The engine's reported rate on the Moonshine encoder (B101/B103), the number the achieved
# MAC/cycle here is quoted against.  A constant, carried in the script so the report does
# not depend on a file some other lab may rewrite.
ENGINE_REF_MACC=44.409

while [ $# -gt 0 ]; do
  case "$1" in
    --ir) IR="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --kernel-cflags) KCF_ALL="${2}"; shift 2 ;;
    --seconds-read) MAXREAD="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$IR" ] || die "--ir is required (the extracted YOLOv8n IR directory)"
if [ -z "${RUNNER:-}" ]; then
  _bn="$(basename "$BIT" .bit)"; _bn="${_bn#pynqz1_rocket_micrgb_}"; _bn="${_bn#pynqz1_rocket_}"
  RUNNER="run_rocket_${_bn}.py"
fi
case "$IR" in /*) : ;; *) IR="$IISWC_ROOT/$IR" ;; esac
need_file "$IR/graph.json"; need_file "$IR/weights.npz"; need_file "$IR/io.npz"

read -r CLK_HZ GUEST_KHZ <<EOF_CLK
$(python3 -c "
import sys
f = float(sys.argv[1]); n = round(1000.0 / f)
if n < 1 or abs(1000.0 / n - f) > 0.02 * f:
    sys.exit('the PS7 cannot deliver %g MHz' % f)
print('%d %d' % (round(1e9 / n), round(1e6 / n)))" "$FCLK_CORE")
EOF_CLK
[ -n "${CLK_HZ:-}" ] || die "could not derive the core clock from --fclk $FCLK_CORE"
info "clock: FCLK0 $FCLK_CORE MHz = $CLK_HZ Hz; guest CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ"

case "$WANT_MAGIC" in
  0x5A5A0034|0x5A5A0035) CAP_CFLAG="-DMBXR_RT_CAP=4"; NCH_CFLAG="-DMBXR_NCH=8" ;;
  *) die "this lab is written for 0x5A5A0034/0x5A5A0035 (NCH = 8, cap 4); got $WANT_MAGIC" ;;
esac

MB="$ZCS/modelblaster"
MOON="$IISWC_ROOT/fpga/pynq-z2/modelblaster/moonshine"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
KERNELS_T1="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels_t1"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
RUN="$IISWC_OUT/$NAME"; D="$RUN/yolo"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_ROOT
PY="$ZCS/tools/miniforge3/envs/zephyr/bin/python"; [ -x "$PY" ] || PY=python
OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)
NM=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-nm' 2>/dev/null | head -1)

SNAP_DONE=0
snapshot_once () {
  [ "$SNAP_DONE" -eq 0 ] || return 0; [ -d "$RUN" ] || return 0; SNAP_DONE=1
  local a="$IISWC_ROOT/archive/runs/$(basename "$RUN")"
  mkdir -p "$a" 2>/dev/null || return 0
  for f in run.json report.txt console.txt boot.log kernel_cflags.txt kernel_selectors.txt \
           codegen.log feature_gate.json fclk.json board_side.log ir_digest.txt; do
    [ -f "$RUN/$f" ] && cp "$RUN/$f" "$a/" 2>/dev/null
    [ -f "$D/$f" ] && cp "$D/$f" "$a/" 2>/dev/null
  done
  cp "$D/gen/kernel_picks.json" "$a/" 2>/dev/null || true
  info "archived -> archive/runs/$(basename "$RUN")"
}
trap snapshot_once EXIT

rm -rf "$RUN"; mkdir -p "$D/gen" "$RUN/host"
ln -sfn "$IR" "$D/ir"

step "0/5  the curated tree"
# Composed exactly as scripts/57 composes it for a 0x5A5A0035 arm, so the kernel a
# dispatch reaches here is the kernel the Moonshine numbers were measured with.
CUR="$RUN/kernels_board"; cp -r "$KERNELS" "$CUR"
rm -f "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_row.c" "$CUR/pext_nl/pext_nl_softmax_s8_pext_int_memo.c"
cp "$KERNELS_T1/pext_nl/pext_nl_permute4_s8_pext_block.c" "$CUR/pext_nl/"
# LUT lane ON: cat2_c1_s8's only curated kernel is the lane one, and YOLOv8n dispatches
# seven of them.  gelu/tanh are not in this graph at all; their files are removed anyway so
# the tree is the same object scripts/57 --lut-lane builds.
rm -f "$CUR/pext_nl/pext_nl_gelu_s8_pext_int_lut.c" "$CUR/pext/pext_gelu_s8_pext_memo_lut.c" \
      "$CUR/pext/pext_tanh_s8_pext_memo_lut.c" "$CUR/roccmoon/roccmoon_layernorm_s8_roccmoon_lane.c"
need_file "$CUR/roccmoon/roccmoon_cat2_c1_s8_roccmoon_lut.c" "no roccmoon LUT-lane cat2 kernel"
need_file "$CUR/roccmoon/roccmoon_conv2d_s8_roccmoon_engine.c" "no roccmoon engine conv kernel"
lane_align_buffers "$WANT_MAGIC"

step "1/5  codegen (backend roccmoon) from $IR"
( cd "$ZCS" && "$PY" -m modelblaster.pipeline.generate_skeleton \
    --ir "$IR/graph.json" --weights "$IR/weights.npz" --io "$IR/io.npz" \
    --out-dir "$D/gen" --backend roccmoon ) > "$RUN/codegen.log" 2>&1 \
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
for k in sorted(p): print('    %-22s %-18s %s'%(k,p[k].get('source'),p[k].get('algorithm')))" \
  "$D/gen/kernel_picks.json"
# THE CONVOLUTION MUST REACH THE ENGINE KERNEL.  It is the whole subject of the lab, and a
# tree that silently handed conv2d_s8 to the curated MBP kernel directly would measure the
# SAME cycles for a completely different reason -- the engine never consulted rather than
# consulted and declined.  calls_fallback separates those two only if the engine kernel is
# the one that was linked.
"$PY" -c "
import json,sys
p=json.load(open(sys.argv[1]))['picks']
c=p.get('conv2d_s8',{})
if c.get('algorithm')!='roccmoon_engine':
    sys.exit('conv2d_s8 picked %s/%s, not roccmoon_engine -- the engine would never be consulted'
             % (c.get('source'), c.get('algorithm')))
print('    conv2d_s8 -> roccmoon_engine  (the guard is consulted per dispatch)')" \
  "$D/gen/kernel_picks.json" || die "the curated tree did not select the engine convolution"

step "2/5  bake this image's own host-C golden"
( cd "$MOON" && "$PY" -c "
import hostrun, numpy as np, sys
g = sys.argv[1]
exe = hostrun.build(g, sys.argv[2])
d = hostrun.dump(exe, g, sys.argv[2] + '/dump.bin')
d['__output__'].astype(np.int8).tofile(g + '/test_golden.bin')
py = np.fromfile(g + '/test_golden_python.bin', dtype=np.int8)
o = d['__output__']
n = int((py != o).sum())
print('    host-C golden: %d of %d elements differ from the Python golden (max %d)' % (
    n, py.size, int(abs(py.astype(int) - o.astype(int)).max())))
# A golden of all one value would compare equal to a kernel that wrote all one value.
print('    golden: %d of %d bytes nonzero, range [%d, %d]' % (
    int((o != 0).sum()), o.size, int(o.min()), int(o.max())))
if int((o != 0).sum()) * 20 < o.size:
    raise SystemExit('the golden is almost entirely zero -- it cannot discriminate')
" "$D/gen" "$RUN/host" ) || die "host run failed (the host-C golden could not be baked)"

step "3/5  build the image"
CF=$(cd "$ZCS" && "$PY" -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['roccmoon'].kernel_cflags))")
CF="$CF -DMBXR_RT_LUT=1 $KCF_ALL $CAP_CFLAG $NCH_CFLAG $PLACE_EARLY_CFLAG"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$ITERS" -DMB_WARMUP=0 \
    -DMB_JOIN_TIMEOUT_S=7200 -DMODELBLASTER_KERNEL_CFLAGS="$CF" \
    -DMB_HARNESS_CFLAGS=-DMBXR_RT_LUT=1 >> "$RUN/build.log" 2>&1 \
  || { tail -40 "$RUN/build.log"; die "west build failed"; }
cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/mbxr_abi.sh"
mbxr_abi_gate "$D/zephyr.elf" "$WANT_MAGIC" || die "guest/bitstream ABI mismatch"
echo "$CF" > "$D/kernel_cflags.txt"
grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ\$" "$D/build/zephyr/.config" \
  || die "guest clock mismatch: board '$BOARD' is not built for --fclk $FCLK_CORE"
{ echo "ir=$IR"
  echo "ir_graph_md5=$(md5sum "$IR/graph.json" | cut -d' ' -f1)"
  echo "ir_weights_md5=$(md5sum "$IR/weights.npz" | cut -d' ' -f1)"
  echo "lut_lane=1"
  echo "drain_strided=$(grep -ao 'MBXR_ABI:v2:strided=[01]' "$D/zephyr.elf" 2>/dev/null | head -1 | sed 's/.*=//')"
  echo "kernel_picks_digest=$("$PY" -c 'import hashlib,json,sys;p=json.load(open(sys.argv[1]))["picks"];print(hashlib.md5(";".join("%s=%s/%s"%(o,p[o].get("source"),p[o].get("algorithm")) for o in sorted(p)).encode()).hexdigest())' "$D/gen/kernel_picks.json")"
  # THE CONV SHAPES, DIGESTED.  The two arms of this lab are IDENTICAL in picks and in
  # cflags by construction, so the selector that tells them apart has to be the IR itself.
  echo "conv_shape_digest=$("$PY" -c 'import hashlib,json,sys;g=json.load(open(sys.argv[1]));print(hashlib.md5(";".join(str(sorted(o["shape"].items())) for o in g["ops"] if o["op"]=="conv2d_s8").encode()).hexdigest())' "$IR/graph.json")"
} > "$D/kernel_selectors.txt"
sed 's/^/    /' "$D/kernel_selectors.txt"
"$OBJDUMP" -d "$D/zephyr.elf" > "$D/dis.txt"
"$PY" - "$D/dis.txt" <<'PYG'
import re, sys
t = open(sys.argv[1]).read()
sf = sorted(set(re.findall(r'<(__(?:add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)[a-z0-9]*(?:sf|df)[0-9a-z]*)>', t)))
w = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
print("    custom-0=%d  soft-float=%s" % (
    sum(1 for x in w if (int(x, 16) & 0x7f) == 0x0b), ",".join(sf) or "none"))
PYG
"$NM" -S "$D/zephyr.elf" | awk 'NF == 4 {
    if ($4 == "z_sys_post_kernel") print $4 ":" $1 ":1:u8";
    else if ($4 == "riscv_cpu_boot_flag" || $4 == "riscv_cpu_wake_flag") print $4 ":" $1 ":8:u64";
  }' | tr '\n' ' ' > "$D/peek_spec.txt"
info "image: $(fsize "$D/zephyr.bin") ($(stat -c %s "$D/zephyr.bin") bytes)"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }

step "4/5  the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_micrgb.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$PYNQ_HOST:$PYNQ_DIR/"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"
bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "$D/gen/kernel_picks.json" "$(cat "$D/kernel_cflags.txt")"
run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  >> "$RUN/boot.log" 2>&1 || { tail -20 "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
info "running (up to $MAXREAD s; the reader stops at the RESULT line)"
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
'" > "$D/board_side.log" 2>&1 || true
cat "$D/board_side.log" >> "$RUN/boot.log"
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$D/console.txt" 2>/dev/null || true
cp "$RUN/fclk.json" "$D/fclk.json"; echo "$BIT_MD5" > "$D/bitstream_md5.txt"
grep -c . "$D/console.txt" >/dev/null 2>&1 || die "0-byte console -- STOP and report (board etiquette)"
grep -q 'MB_PEXT_RUN' "$D/console.txt" \
  || die "no MB_PEXT_RUN line ($(grep -oE 'waited=[0-9]+ console_bytes=[0-9]+' "$D/board_side.log" || true))"
info "$(grep -E '^MB_PEXT_RUN' "$D/console.txt" | head -1)"

step "5/5  the table"
BIT_MD5="${BIT_MD5:-$(cat "$D/bitstream_md5.txt" 2>/dev/null)}" \
CLK_HZ="$CLK_HZ" ENGINE_REF_MACC="$ENGINE_REF_MACC" WANT_MAGIC="$WANT_MAGIC" NAME="$NAME" \
"$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/yolo/report_yolo.py" \
    "$D/console.txt" "$IR/graph.json" "$D/kernel_selectors.txt" "$D/kernel_cflags.txt" \
    "$RUN/run.json" | tee "$RUN/report.txt"
snapshot_once
info "out/$NAME/{run.json,report.txt} and archive/runs/$NAME"
