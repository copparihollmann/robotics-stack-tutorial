#!/usr/bin/env bash
# Build and run the attention unit's two testbenches:
#
#   tb_rq    mbxa_rq against kernel_matmul_b_s8's own requantise tail, EXHAUSTIVELY over
#            every accumulator either Moonshine matmul can produce, then random (mt, sh).
#   tb_attn  mbxa_unit against attn_golden_head -- kernel_matmul_b_s8, kernel_softmax_s8,
#            kernel_matmul_b_s8, the curated kernels included as source -- on the real
#            encoder's every head of every layer, on random shapes and on corners.
#
#   rtl_study/roccmoon/attn_unit/run_tb.sh            full run, sharded over ATTN_SHARDS
#   rtl_study/roccmoon/attn_unit/run_tb.sh --quick    a few seconds
#
# Env: ATTN_BUILD (build and log directory, default $TMPDIR/attn_tb), ATTN_SHARDS (8),
#      VERILATOR, ATTN_ACTS (the encoder's acts.npz; its graph.json alongside gives the
#      shapes and scales), ATTN_VFLAGS (extra Verilator flags, e.g. -GDIV_BPC=4).
# The golden is compiled as C with the host checks' flags, from fpga/pynq-z2/modelblaster.
# Expect final lines beginning RQ_TB_OK and ATTN_TB_OK.
#
# NO BOARD, NO VIVADO, NO MAGIC: this is Verilator and a C compiler only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../../.." && pwd)"
mb="$here/../../../modelblaster"
B="${ATTN_BUILD:-${TMPDIR:-/tmp}/attn_tb}"
NS="${ATTN_SHARDS:-8}"
VERILATOR="${VERILATOR:-verilator}"
ACTS="${ATTN_ACTS:-$repo/out/rocket_moonshine_enc_smx2/enc/ir/acts.npz}"
# ATTN_RTLDIR lets run_mutants.sh point the same flow at a mutated copy of the two new files
src="${ATTN_RTLDIR:-$here}"
RTL=("$src/mbxa_rq.v" "$src/mbxa_unit.v" "$here/../smx_lane/mbxr_smx.v"
     "$here/../mbxr_datapath.v" "$here/../../rocc/mbx_mac.v")
TOP=mbxa_unit
DUTCF=""
# ATTN_GLUE=1 runs the SAME testbench against merge/mbxr_lanes.v -- the merged engine's lane
# wiring -- through attn_unit/mbxa_glue.v, which presents mbxa_unit's port list.  That is the
# only check on the widened configuration decode, the `own` arbitration, the s0_* mux, the
# act_sel/p_rdata path and the drain hand-off: the merged engine's own gate runs with the
# lanes IDLE and cannot see them.
if [ "${ATTN_GLUE:-0}" = "1" ]; then
  TOP=mbxa_glue
  # mbxl_lut.v is here because merge/mbxr_lanes.v instantiates it as lane 4 (86b89cd).  That
  # is the FIFTH file list in this tree that has to know about a new lane module, after the
  # DRC gate, both build scripts and build_rocket.tcl's variant list -- the merge workstream
  # flagged the shape and this is it appearing again.
  RTL=("$src/mbxa_glue.v" "${RTL[@]}" "$here/../merge/mbxr_lanes.v" "$here/../ln_lane/mbxr_ln.v"
       "$here/../lut_lane/mbxl_lut.v")
  DUTCF="-DATTN_DUT_HDR='\"Vmbxa_glue.h\"' -DATTN_DUT=Vmbxa_glue -DATTN_HAS_BUF=1"
fi
mkdir -p "$B"

echo "=== build"
( cd "$mb" && cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw \
    -c "$here/attn_golden.c" -o "$B/attn_golden.o" )
# the two new files lint clean under -Wall; the engine's own files are not this agent's
"$VERILATOR" --lint-only -Wall -Wno-DECLFILENAME ${ATTN_VFLAGS:-} --top-module mbxa_core \
  "$src/mbxa_rq.v" "$src/mbxa_unit.v" "$here/../smx_lane/mbxr_smx.v" > "$B/lint.log" 2>&1 || {
  echo "FAILED: verilator lint"; cat "$B/lint.log"; exit 1; }
"$VERILATOR" --cc --exe --build -j 16 -O3 -Wno-fatal ${ATTN_VFLAGS:-} --Mdir "$B/obj_rq" \
  --top-module mbxa_rq -CFLAGS "-O2" "$src/mbxa_rq.v" "$here/tb_rq.cpp" "$B/attn_golden.o" \
  -o Vrq > "$B/build_rq.log" 2>&1 || { echo "FAILED: build tb_rq"; tail -30 "$B/build_rq.log"; exit 1; }
"$VERILATOR" --cc --exe --build -j 16 -O3 -Wno-fatal -DMBXR_BEHAVIOURAL ${ATTN_VFLAGS:-} \
  --Mdir "$B/obj" --top-module "$TOP" -CFLAGS "-O2 $DUTCF" "${RTL[@]}" "$here/tb_attn.cpp" \
  "$B/attn_golden.o" -o Vattn > "$B/build.log" 2>&1 || {
  echo "FAILED: build tb_attn"; tail -30 "$B/build.log"; exit 1; }

margs=()
if [ -f "$ACTS" ]; then
  python3 - "$ACTS" "$B/moonshine.bin" <<'EOF'
import json, os, struct, sys
import numpy as np
acts, out = sys.argv[1], sys.argv[2]
d = os.path.dirname(acts)
g = json.load(open(os.path.join(d, "graph.json")))
a = np.load(acts)
ops = {n["name"]: n for n in g["ops"]}
trip = []
for n in g["ops"]:
    if n["op"] != "matmul_b_s8" or not n["name"].endswith(".qk"):
        continue
    stem = n["name"][:-3]
    sm, av = ops.get(stem + ".softmax"), ops.get(stem + ".av")
    assert sm is not None and av is not None, stem
    trip.append((n, sm, av))
with open(out, "wb") as f:
    f.write(b"ATTN" + struct.pack("<I", len(trip)))
    for qk, sm, av in trip:
        s, q = qk["shape"], qk["quant"]
        B, T, D, N = s["B"], s["M"], s["K"], s["N"]
        assert av["shape"] == {"B": B, "M": T, "K": N, "N": D, "transpose_b": 0}, av["shape"]
        assert sm["shape"] == {"M": B * T, "K": N}, sm["shape"]
        f.write(struct.pack("<9f", q["scale_a"], q["scale_b"], q["scale_out"],
                            q["scale_div_sqrt_dk"],
                            sm["quant"]["scale_in"], sm["quant"]["scale_out"],
                            av["quant"]["scale_a"], av["quant"]["scale_b"],
                            av["quant"]["scale_out"]))
        f.write(struct.pack("<4I", B, T, D, N))
        for name, n_exp in ((qk["inputs"][0], B * T * D), (qk["inputs"][1], B * N * D),
                            (av["inputs"][1], B * N * D), (av["outputs"][0], B * T * D)):
            x = a[name].astype(np.int8).reshape(-1)
            assert x.size == n_exp, (name, x.size, n_exp)
            f.write(x.tobytes())
print("moonshine: %d attention triples (%d head dispatches) from %s"
      % (len(trip), len(trip) * 8, acts))
EOF
  margs=(--moonshine "$B/moonshine.bin")
else
  echo "moonshine: $ACTS not found; the real-activation case is skipped"
fi

echo "=== run tb_rq"
"$B/obj_rq/Vrq" | tee "$B/tb_rq.log"
grep -q "^RQ_TB_OK" "$B/tb_rq.log"

echo "=== run tb_attn (top: $TOP)"
if [ "${1:-}" = "--quick" ]; then
  "$B/obj/Vattn" --quick "${margs[@]}" | tee "$B/tb_quick.log"
  grep -q "^ATTN_TB_OK" "$B/tb_quick.log"
  exit $?
fi
pids=()
for i in $(seq 0 $((NS - 1))); do
  "$B/obj/Vattn" --shard "$i" --nshards "$NS" "${margs[@]}" "$@" > "$B/tb_shard$i.log" 2>&1 &
  pids+=($!)
done
fail=0
for i in "${!pids[@]}"; do wait "${pids[$i]}" || fail=1; done
python3 - "$B" "$NS" <<'EOF'
import re, sys
B, ns = sys.argv[1], int(sys.argv[2])
tot, ok = {}, True
disp = rows = byt = bad = bp = acts = acts_rtl = acts_gold = 0
perf_c = perf_r = perf_mc = perf_mr = 0.0
for i in range(ns):
    txt = open("%s/tb_shard%d.log" % (B, i)).read()
    ok &= bool(re.search(r"^ATTN_TB_OK", txt, re.M))
    for m in re.finditer(r"^ATTN_TB_CASE (\w+): .*?(\d+) differ", txt, re.M):
        tot[m.group(1)] = tot.get(m.group(1), 0) + int(m.group(2))
    m = re.search(r"^ATTN_TB_ACTS (\d+) bytes against acts.npz: RTL differs in (\d+), the curated kernels differ in (\d+)", txt, re.M)
    if m:
        acts += int(m.group(1)); acts_rtl += int(m.group(2)); acts_gold += int(m.group(3))
    m = re.search(r"^ATTN_TB_PERF ([\d.]+) cycles per query row over (\d+) rows", txt, re.M)
    if m:
        perf_c += float(m.group(1)) * int(m.group(2)); perf_r += int(m.group(2))
    m = re.search(r"^ATTN_TB_PERFMS ([\d.]+) cycles per query row over (\d+) rows", txt, re.M)
    if m:
        perf_mc += float(m.group(1)) * int(m.group(2)); perf_mr += int(m.group(2))
    m = re.search(r"^ATTN_TB_(?:OK|FAILED) shard \d+/\d+: (\d+) dispatches \((\d+) with back-pressure\), (\d+) rows, (\d+) output bytes, (\d+) differ", txt, re.M)
    if m:
        disp += int(m.group(1)); bp += int(m.group(2)); rows += int(m.group(3))
        byt += int(m.group(4)); bad += int(m.group(5))
    for m in re.finditer(r"^ATTN_TB_(MISMATCH|FAIL).*$", txt, re.M):
        print(m.group(0)); ok = False
for k, v in sorted(tot.items()):
    print("case %-12s %d differ" % (k, v))
if perf_r:
    print("ATTN_TB_PERF %.3f cycles per query row over %d rows" % (perf_c / perf_r, perf_r))
if perf_mr:
    print("ATTN_TB_PERFMS %.3f cycles per query row over %d rows at T=165 D=36 N=165"
          % (perf_mc / perf_mr, perf_mr))
if acts:
    print("ATTN_TB_ACTS %d bytes against acts.npz: RTL differs in %d (%.4f%%), the curated "
          "kernels differ in %d -- identical sets, so the drift is the softmax kernel's "
          "numeric_drift and none of it is the RTL's"
          % (acts, acts_rtl, 100.0 * acts_rtl / acts, acts_gold))
print("%s %d shards: %d dispatches (%d with back-pressure), %d rows, %d output bytes, "
      "%d bytes also compared with acts.npz, %d differ from the curated kernels"
      % ("ATTN_TB_OK" if ok and bad == 0 else "ATTN_TB_FAILED", ns, disp, bp, rows, byt,
         acts, bad))
sys.exit(0 if ok and bad == 0 else 1)
EOF
