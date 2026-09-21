#!/usr/bin/env bash
# Build and run tb_ln: the LayerNorm/GroupNorm lane (mbxr_ln.v) against the q16 normalisation
# reference, element for element.
#
#   rtl_study/roccmoon/ln_lane/run_tb.sh            full run, sharded over LN_SHARDS processes
#   rtl_study/roccmoon/ln_lane/run_tb.sh --quick    a few seconds
#   rtl_study/roccmoon/ln_lane/run_tb.sh --perf     the cycles-per-row table (shard 0 only)
#
# Env: LN_BUILD (build and log directory, default $TMPDIR/ln_tb), LN_SHARDS (default 16),
#      VERILATOR, LN_IR (the q16 lowering's IR directory: graph.json, acts.npz, weights.npz),
#      LN_RTL (the RTL to build, default ln_lane/mbxr_ln.v -- mutants.sh overrides it),
#      LN_VFLAGS (extra Verilator flags, e.g. -GKL2=10).
# Expect a final line beginning LN_TB_OK.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../../.." && pwd)"
mb="$here/../../../modelblaster"
B="${LN_BUILD:-${TMPDIR:-/tmp}/ln_tb}"
NS="${LN_SHARDS:-16}"
VERILATOR="${VERILATOR:-verilator}"
IR="${LN_IR:-$repo/out/q16/F3PR/ir}"
RTL="${LN_RTL:-$here/mbxr_ln.v}"
mkdir -p "$B"

echo "=== build"
python3 "$here/gen_golden.py" > "$B/gen_golden.log"
cc -O2 -std=gnu11 -ffp-contract=off -I"$mb/kernels/pext_nl" -c "$here/ln_golden.c" \
   -o "$B/ln_golden.o"
"$VERILATOR" --lint-only -Wall ${LN_VFLAGS:-} --top-module mbxr_ln "$RTL" > "$B/lint.log" 2>&1 || {
  echo "FAILED: verilator lint"; cat "$B/lint.log"; exit 1; }
"$VERILATOR" --cc --exe --build -j 16 -O3 -Wno-fatal ${LN_VFLAGS:-} --Mdir "$B/obj" \
  --top-module mbxr_ln -CFLAGS "-O2" "$RTL" "$here/tb_ln.cpp" "$B/ln_golden.o" -o Vtb \
  > "$B/build.log" 2>&1 || { echo "FAILED: build"; tail -40 "$B/build.log"; exit 1; }

margs=()
if [ -f "$IR/graph.json" ]; then
  python3 - "$IR" "$B/moonshine.bin" <<'EOF'
import json, os, struct, sys
import numpy as np
ir, out = sys.argv[1], sys.argv[2]
g = json.load(open(os.path.join(ir, "graph.json")))
a = np.load(os.path.join(ir, "acts.npz")); w = np.load(os.path.join(ir, "weights.npz"))
ops = [n for n in g["ops"] if n["op"] in
       ("layernorm_pc_s8", "layernorm_s16_s8", "groupnorm_s16")]
with open(out, "wb") as f:
    f.write(b"LNM1" + struct.pack("<I", len(ops)))
    for n in ops:
        op = n["op"]
        if op == "groupnorm_s16":
            C = n["shape"]["C"]; HW = n["shape"]["H"] * n["shape"]["W"]
            M, K, nc, wf, tp = n["shape"]["N"], C * HW, C, 3, 1
            umul = np.ones(nc, dtype=np.int32)
        else:
            M, K = n["shape"]["M"], n["shape"]["K"]
            HW, nc, tp = 1, K, 0
            wf = 1 if op == "layernorm_s16_s8" else 0
            umul = (w[n["umul"]].astype(np.int32) if "umul" in n
                    else np.ones(nc, dtype=np.int32))
        gm = w[n["gmul"]].astype(np.int64); bd = w[n["badd"]].astype(np.int64)
        x = a[n["inputs"][0]].reshape(-1).astype(np.int64)
        y = a[n["outputs"][0]].reshape(-1).astype(np.int64)
        assert x.size == M * K and y.size == M * K, (op, x.size, M * K)
        assert abs(x).max() < 32768 and abs(y).max() < 32768
        f.write(struct.pack("<6i", M, K, HW, nc, wf, tp))
        f.write(struct.pack("<q", int(n["quant"]["eps_q"])))
        f.write(umul.astype("<i4").tobytes())
        f.write(gm.astype("<i8").tobytes()); f.write(bd.astype("<i8").tobytes())
        f.write(x.astype("<i2").tobytes()); f.write(y.astype("<i2").tobytes())
print("moonshine: %d norm dispatches from %s" % (len(ops), ir))
EOF
  margs=(--moonshine "$B/moonshine.bin")
else
  echo "moonshine: $IR/graph.json not found; the real-shape case is skipped"
fi

echo "=== run"
if [ "${1:-}" = "--quick" ]; then
  "$B/obj/Vtb" --quick "${margs[@]}" | tee "$B/tb_quick.log"
  grep -q "^LN_TB_OK" "$B/tb_quick.log"
  exit $?
fi
pids=()
for i in $(seq 0 $((NS - 1))); do
  "$B/obj/Vtb" --shard "$i" --nshards "$NS" "${margs[@]}" "$@" > "$B/tb_shard$i.log" 2>&1 &
  pids+=($!)
done
fail=0
for i in "${!pids[@]}"; do wait "${pids[$i]}" || fail=1; done
grep -h "LN_TB_PERF" "$B/tb_shard0.log" || true
python3 - "$B" "$NS" <<'EOF'
import re, sys
B, ns = sys.argv[1], int(sys.argv[2])
tot, ok = {}, True
for i in range(ns):
    txt = open("%s/tb_shard%d.log" % (B, i)).read()
    ok &= bool(re.search(r"^LN_TB_OK", txt, re.M))
    for m in re.finditer(r"^LN_TB_CASE (\w+)\s+(\d+) dispatches \(\s*(\d+) with back-pressure\) "
                         r"\s*(\d+) rows,\s*(\d+) elements, (\d+) differ", txt, re.M):
        c = tot.setdefault(m.group(1), [0, 0, 0, 0, 0])
        for k in range(5): c[k] += int(m.group(k + 2))
    for m in re.finditer(r"^LN_TB_(MISMATCH|FAIL).*$", txt, re.M):
        print(m.group(0)); ok = False
all_ = [sum(c[k] for c in tot.values()) for k in range(5)]
for name, c in sorted(tot.items()):
    print("case %-12s %8d dispatches (%7d back-pressured) %9d rows %12d elements, %d differ"
          % (name, *c))
print("%s %d shards: %d dispatches (%d with back-pressure), %d rows, %d elements, %d differ "
      "from the q16 normalisation reference"
      % ("LN_TB_OK" if ok and all_[4] == 0 else "LN_TB_FAILED", ns, *all_))
sys.exit(0 if ok and all_[4] == 0 else 1)
EOF
