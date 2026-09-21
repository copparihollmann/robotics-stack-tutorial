#!/usr/bin/env bash
# Lab B121 -- the GTSRB int8 sign classifier on the roccmoon bitstream, and an HONEST
# accounting of how little of it the accelerator can take.
#
#   scripts/with_board.sh ./scripts/78_rocket_gtsrb_board.sh \
#       --ir archive/b121/ir_shipped/signnet_lite_gray --name b121_gray_unfolded --iters 2
#   scripts/with_board.sh ./scripts/78_rocket_gtsrb_board.sh \
#       --ir archive/b121/fold_ab/signnet_lite_gray_folded --name b121_gray_folded --iters 2
#   ./scripts/78_rocket_gtsrb_board.sh --build-only ...
#
# DERIVED FROM scripts/75 (Lab B106) AND DELIBERATELY KEPT IDENTICAL TO IT except where
# marked B121: the curated-tree composition, the kernel cflags, the host-C golden bake, the
# ABI/clock/bitstream gates and the board step are 75's verbatim, so a cycle measured here is
# comparable to one measured there.  THREE THINGS DIFFER, and each is commented at its site:
#
#   B121-1  THE CONVOLUTION GATE IS GENERALISED.  75 dies unless conv2d_s8 picks
#           roccmoon_engine.  This lab's AS-SHIPPED graph has no conv2d_s8 at all: its
#           BatchNorm was not folded, so the backbone is the COMPOSITE conv2d_batchnorm2d_s8,
#           which has no curated kernel on any of (roccmoon, pext_nl, pext) and runs
#           reference C.  That is the finding, not a misconfiguration, so the gate asserts
#           WHICH of the two shapes the graph has and refuses only the genuinely broken
#           third case: a conv2d_s8 present but NOT on the engine kernel.
#   B121-2  conv_shape_digest DESCENDS INTO sub_ops, so the folded and unfolded arms get
#           digests that are comparable rather than one of them being empty.
#   B121-3  --golden-mutate flips one byte of the baked golden.  A max_abs_err of 0 is only
#           evidence if the instrument can report non-zero; this is the negative control,
#           and it must FAIL.  It is never passed on a measurement arm.
#
# WHAT IT REPORTS, per arm: cycles, MAC/cycle achieved against the engine's 44.409,
# calls_engine / calls_fallback, and the per-kind table -- including the kinds that have NO
# curated kernel and run reference C.
#
# NO NEW BITSTREAM AND NO RTL.  Everything here is software on 0x5A5A0035, already on the bench.
set -euo pipefail

: "${BIT_ACCEPTED:=995798bedfb15cff077ab58710af3bf8}"
export BIT_ACCEPTED
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="b121_gtsrb"
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
LAB_REQUIRES="${LAB_REQUIRES:-rocc_engine pext}"
FCLK_CORE=40.0
ITERS=1
GOLDEN_MUTATE=0
BOARD_ONLY=0
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
    --golden-mutate) GOLDEN_MUTATE=1; shift ;;   # B121-3 negative control
    --board-only) BOARD_ONLY=1; shift ;;         # B121-5 reuse a --build-only image
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$IR" ] || die "--ir is required (an extract_graph output dir: graph.json, weights.npz, io.npz)"
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

# B121-5  BOARD ETIQUETTE.  Every step above the board is CPU work on this host and needs no
# board at all, but scripts/75 does them in the same invocation -- so wrapping the whole thing
# in with_board.sh holds the one physical PYNQ for the length of five west builds.
# --build-only does the work; --board-only then reuses that image and takes the lock for just
# the load and the run.  The two halves are tied by the run directory name, and --board-only
# REFUSES to invent one: the image, its cflags and its selectors must already be on disk, so a
# board number can never be reported against an image this flag silently rebuilt.
if [ "$BOARD_ONLY" -eq 1 ]; then
need_file "$D/zephyr.bin" "--board-only: no image -- run --build-only with this --name first"
need_file "$D/kernel_cflags.txt" "--board-only: no kernel_cflags.txt"
need_file "$D/kernel_selectors.txt" "--board-only: no kernel_selectors.txt"
need_file "$D/gen/kernel_picks.json" "--board-only: no kernel_picks.json"
info "--board-only: reusing $D/zephyr.bin ($(stat -c %s "$D/zephyr.bin") bytes)"
grep -E '^(ir_graph_md5|kernel_picks_digest|conv_shape_digest|golden_mutate|lut_lane)=' \
    "$D/kernel_selectors.txt" | sed 's/^/    /'
else
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
# B121-1  WHICH BACKBONE DID THIS GRAPH HAND US, AND WHAT PICKED IT UP.
# 75 dies here unless conv2d_s8 picked roccmoon_engine.  That is right for a graph whose
# BatchNorm is folded; it is wrong as a gate for this lab, whose whole subject is a graph
# whose BatchNorm is NOT folded and therefore has no conv2d_s8 to pick.  The three cases:
#
#   conv2d_s8 -> roccmoon_engine          FOLDED arm.  The engine kernel is linked, so
#                                         calls_fallback can distinguish "consulted and
#                                         declined" from "never consulted".
#   conv2d_batchnorm2d_s8 -> reference    AS-SHIPPED arm.  The composite has no curated
#                                         kernel on roccmoon, pext_nl or pext, so the
#                                         backbone is reference C and the engine is NEVER
#                                         CONSULTED AT ALL -- calls_fallback stays 0 for the
#                                         convolution, and that 0 must not be read as success.
#   conv2d_s8 -> anything else            BROKEN.  Refused.
"$PY" -c "
import json,sys
p=json.load(open(sys.argv[1]))['picks']
c=p.get('conv2d_s8'); b=p.get('conv2d_batchnorm2d_s8')
if c is not None:
    if c.get('algorithm')!='roccmoon_engine':
        sys.exit('conv2d_s8 picked %s/%s, not roccmoon_engine -- the engine would never be '
                 'consulted' % (c.get('source'), c.get('algorithm')))
    print('    backbone: conv2d_s8 -> roccmoon_engine  (FOLDED; the guard is consulted per dispatch)')
elif b is not None:
    if b.get('source')!='reference':
        sys.exit('conv2d_batchnorm2d_s8 picked %s/%s -- a curated composite appeared since '
                 'this lab was written; re-price the arm' % (b.get('source'), b.get('algorithm')))
    print('    backbone: conv2d_batchnorm2d_s8 -> reference/direct  (AS-SHIPPED; BatchNorm NOT')
    print('              folded, so the engine kernel is not even linked for the convolution)')
else:
    sys.exit('this graph has neither conv2d_s8 nor conv2d_batchnorm2d_s8 -- not a GTSRB arm')
" "$D/gen/kernel_picks.json" || die "the curated tree did not select a backbone this lab can price"

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

# B121-3  THE NEGATIVE CONTROL.  max_abs_err == 0 is evidence only if this instrument is
# capable of printing something else.  --golden-mutate flips the low bit of one non-zero
# golden byte AFTER the host-C bake, so the image carries a golden that is wrong by exactly
# 1 in exactly one place.  The board MUST then report max_abs_err >= 1.  Never passed on a
# measurement arm; run.json records the flag either way.
if [ "$GOLDEN_MUTATE" -eq 1 ]; then
  "$PY" - "$D/gen/test_golden.bin" <<'PYMUT'
import sys, numpy as np
p = sys.argv[1]
a = np.fromfile(p, dtype=np.int8)
nz = np.nonzero(a)[0]
if nz.size == 0:
    raise SystemExit('golden is all zero -- nothing to mutate')
i = int(nz[0])
before = int(a[i]); a[i] = np.int8(before ^ 1)
a.tofile(p)
print('    NEGATIVE CONTROL: golden[%d] %d -> %d (expect max_abs_err >= 1)' % (i, before, int(a[i])))
PYMUT
fi

step "3/5  build the image"
CF=$(cd "$ZCS" && "$PY" -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['roccmoon'].kernel_cflags))")
# B121-4  THE LUT LANE IS CONDITIONAL, BECAUSE THIS GRAPH MAY NOT HAVE AN OP FOR IT.
# 75 hardcodes -DMBXR_RT_LUT=1: YOLOv8n dispatches seven cat2_c1_s8 and the lane kernel that
# serves them DEFINES mbxr_lut_stats, which main.c then reads.  GTSRB has no cat2_c1_s8, no
# gelu_s8 and no tanh_s8, so nothing defines that symbol and the image fails to LINK.  Set it
# only when the graph actually contains a LUT-lane kind, and record which way it went.
LUT_KINDS=$("$PY" -c '
import json,sys
g=json.load(open(sys.argv[1]))
k={o["op"] for o in g["ops"]} & {"cat2_c1_s8","gelu_s8","tanh_s8"}
print(",".join(sorted(k)))' "$IR/graph.json")
if [ -n "$LUT_KINDS" ]; then LUT_CFLAG="-DMBXR_RT_LUT=1"; LUT_ON=1
else LUT_CFLAG=""; LUT_ON=0; info "no LUT-lane kind in this graph -- MBXR_RT_LUT off"; fi
CF="$CF $LUT_CFLAG $KCF_ALL $CAP_CFLAG $NCH_CFLAG $PLACE_EARLY_CFLAG"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$ITERS" -DMB_WARMUP=0 \
    -DMB_JOIN_TIMEOUT_S=7200 -DMODELBLASTER_KERNEL_CFLAGS="$CF" \
    -DMB_HARNESS_CFLAGS="$LUT_CFLAG" >> "$RUN/build.log" 2>&1 \
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
  echo "lut_lane=$LUT_ON"
  echo "lut_kinds=${LUT_KINDS:-none}"
  echo "golden_mutate=$GOLDEN_MUTATE"
  echo "drain_strided=$(grep -ao 'MBXR_ABI:v2:strided=[01]' "$D/zephyr.elf" 2>/dev/null | head -1 | sed 's/.*=//')"
  echo "kernel_picks_digest=$("$PY" -c 'import hashlib,json,sys;p=json.load(open(sys.argv[1]))["picks"];print(hashlib.md5(";".join("%s=%s/%s"%(o,p[o].get("source"),p[o].get("algorithm")) for o in sorted(p)).encode()).hexdigest())' "$D/gen/kernel_picks.json")"
  # THE CONV SHAPES, DIGESTED.  The two arms of this lab are IDENTICAL in picks and in
  # cflags by construction, so the selector that tells them apart has to be the IR itself.
  # B121-2  descend into sub_ops: the as-shipped arm's convolutions live inside the
  # conv2d_batchnorm2d_s8 composite, and a digest over top-level conv2d_s8 alone is EMPTY
  # for it -- which would make two different graphs digest identically.
  echo "conv_shape_digest=$("$PY" -c 'import hashlib,json,sys
g=json.load(open(sys.argv[1]))
def convs(ops):
    for o in ops:
        for s in (o.get("sub_ops") or [o]):
            if s.get("op")=="conv2d_s8": yield s
h=";".join(str(sorted(s["shape"].items())) for s in convs(g["ops"]))
print(hashlib.md5(h.encode()).hexdigest())' "$IR/graph.json")"
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

fi

step "4/5  the board"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
# B121-6  RECORD WHICH PHYSICAL BOARD ANSWERED.  There are two, they run the same bitstream
# md5, and scripts/75 records neither -- so a run.json from it cannot be attributed to a
# machine.  PYNQ_HOST decides; boards.csv names it.  Appended HERE, in the board step, rather
# than in the build step where it would be a guess, and it survives --board-only.
B121_BOARD="$("$PY" -c '
import csv,sys
h=sys.argv[1]
for r in csv.DictReader(l for l in open(sys.argv[2]) if not l.startswith("#")):
    if r["pynq_host"]==h: print(r["board"]); break
else: print("UNKNOWN")' "$PYNQ_HOST" "$IISWC_ROOT/fpga/pynq-z2/bwlab/boards.csv")"
{ echo "pynq_host=$PYNQ_HOST"; echo "board=$B121_BOARD"; } >> "$D/kernel_selectors.txt"
info "board: $B121_BOARD ($PYNQ_HOST)"
[ "$B121_BOARD" = UNKNOWN ] && die "PYNQ_HOST=$PYNQ_HOST is not a row in bwlab/boards.csv"
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
"$PY" "$IISWC_ROOT/fpga/pynq-z2/modelblaster/gtsrb/report_gtsrb.py" \
    "$D/console.txt" "$IR/graph.json" "$D/kernel_selectors.txt" "$D/kernel_cflags.txt" \
    "$RUN/run.json" | tee "$RUN/report.txt"
snapshot_once
info "out/$NAME/{run.json,report.txt} and archive/runs/$NAME"
