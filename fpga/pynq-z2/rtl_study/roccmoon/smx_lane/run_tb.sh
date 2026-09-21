#!/usr/bin/env bash
# Build and run tb_smx: the softmax lane (mbxr_smx.v) against kernel_softmax_s8, byte for byte.
#
#   rtl_study/roccmoon/smx_lane/run_tb.sh            full run, sharded over SMX_SHARDS processes
#   rtl_study/roccmoon/smx_lane/run_tb.sh --quick    a few seconds
#
# Env: SMX_BUILD (build and log directory, default $TMPDIR/smx_tb), SMX_SHARDS (default 16),
#      VERILATOR, SMX_ACTS (Moonshine acts.npz; its graph.json alongside gives the scales),
#      SMX_VFLAGS (extra Verilator flags, e.g. -GDIV_BPC=4).
# The golden is compiled as C with the host checks' flags, from fpga/pynq-z2/modelblaster.
# Expect a final line beginning SMX_TB_OK.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../../.." && pwd)"
mb="$here/../../../modelblaster"
B="${SMX_BUILD:-${TMPDIR:-/tmp}/smx_tb}"
NS="${SMX_SHARDS:-16}"
VERILATOR="${VERILATOR:-verilator}"
ACTS="${SMX_ACTS:-$repo/out/rocket_moonshine_enc_smx2/enc/ir/acts.npz}"
mkdir -p "$B"

echo "=== build"
( cd "$mb" && cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw -c "$here/smx_golden.c" \
    -o "$B/smx_golden.o" )
"$VERILATOR" --lint-only -Wall ${SMX_VFLAGS:-} --top-module mbxr_smx "$here/mbxr_smx.v" > "$B/lint.log" 2>&1 || {
  echo "FAILED: verilator lint"; cat "$B/lint.log"; exit 1; }
"$VERILATOR" --cc --exe --build -j 16 -O3 -Wno-fatal ${SMX_VFLAGS:-} --Mdir "$B/obj" --top-module mbxr_smx \
  -CFLAGS "-O2" "$here/mbxr_smx.v" "$here/tb_smx.cpp" "$B/smx_golden.o" -o Vtb > "$B/build.log" 2>&1 || {
  echo "FAILED: build"; tail -30 "$B/build.log"; exit 1; }

margs=()
if [ -f "$ACTS" ]; then
  python3 - "$ACTS" "$B/moonshine.bin" <<'EOF'
import json, os, struct, sys
import numpy as np
acts, out = sys.argv[1], sys.argv[2]
g = json.load(open(os.path.join(os.path.dirname(acts), "graph.json")))
a = np.load(acts)
ops = [n for n in g["ops"] if n["op"] == "softmax_s8"]
with open(out, "wb") as f:
    f.write(b"SMXM" + struct.pack("<I", len(ops)))
    for n in ops:
        M, K = n["shape"]["M"], n["shape"]["K"]
        x = a[n["inputs"][0]].astype(np.int8).reshape(-1)
        y = a[n["outputs"][0]].astype(np.int8).reshape(-1)
        assert x.size == M * K and y.size == M * K
        f.write(struct.pack("<ffii", n["quant"]["scale_in"], n["quant"]["scale_out"], M, K))
        f.write(x.tobytes()); f.write(y.tobytes())
print("moonshine: %d softmax dispatches from %s" % (len(ops), acts))
EOF
  margs=(--moonshine "$B/moonshine.bin")
else
  echo "moonshine: $ACTS not found; the real-activation case is skipped"
fi

echo "=== run"
if [ "${1:-}" = "--quick" ]; then
  "$B/obj/Vtb" --quick "${margs[@]}" | tee "$B/tb_quick.log"
  grep -q "^SMX_TB_OK" "$B/tb_quick.log"
  exit $?
fi
pids=()
for i in $(seq 0 $((NS - 1))); do
  "$B/obj/Vtb" --shard "$i" --nshards "$NS" "${margs[@]}" "$@" > "$B/tb_shard$i.log" 2>&1 &
  pids+=($!)
done
fail=0
for i in "${!pids[@]}"; do wait "${pids[$i]}" || fail=1; done
grep -h "SMX_TB_PERF\|SMX_TB_CASE errs\|SMX_TB_CASE moonshine" "$B/tb_shard0.log" || true
python3 - "$B" "$NS" <<'EOF'
import re, sys
B, ns = sys.argv[1], int(sys.argv[2])
tot, ok = {}, True
sh = [0] * 6
for i in range(ns):
    txt = open("%s/tb_shard%d.log" % (B, i)).read()
    ok &= bool(re.search(r"^SMX_TB_OK", txt, re.M))
    for m in re.finditer(r"^SMX_TB_CASE (\w+): (\d+) dispatches \((\d+) with back-pressure\), (\d+) rows, (\d+) bytes, (\d+) bytes differ", txt, re.M):
        c = tot.setdefault(m.group(1), [0, 0, 0, 0, 0])
        for k in range(5): c[k] += int(m.group(k + 2))
    m = re.search(r"^SMX_TB_SHIFT bytes by s: s=0 (\d+), 1..16 (\d+), 17 (\d+), 18..33 (\d+), 34..61 (\d+), 62..127 (\d+)", txt, re.M)
    if m: sh = [a + int(b) for a, b in zip(sh, m.groups())]
    for m in re.finditer(r"^SMX_TB_(MISMATCH|FAIL).*$", txt, re.M):
        print(m.group(0)); ok = False
all_ = [sum(c[k] for c in tot.values()) for k in range(5)]
print("bytes by s: s=0 %d, 1..16 %d, 17 %d, 18..33 %d, 34..61 %d, 62..127 %d" % tuple(sh))
for name, c in tot.items():
    print("case %-12s %8d dispatches (%7d back-pressured) %9d rows %11d bytes, %d differ" % (name, *c))
print("%s %d shards: %d dispatches (%d with back-pressure), %d rows, %d output bytes, %d differ from kernel_softmax_s8"
      % ("SMX_TB_OK" if ok and all_[4] == 0 else "SMX_TB_FAILED", ns, *all_))
sys.exit(0 if ok and all_[4] == 0 else 1)
EOF
