#!/usr/bin/env bash
# Lab B17 -- keyword spotters on this silicon, and the one where depthwise loses.
#
#   scripts/with_board.sh ./scripts/37_rocket_kws_board.sh
#   scripts/with_board.sh ./scripts/37_rocket_kws_board.sh --archs cnn
#   ./scripts/37_rocket_kws_board.sh --build-only
#
# Three 12-class Google Speech Commands v2 keyword spotters, all taking the SAME
# 49x10 int8 MFCC from fpga/pynq-z2/sw/audio_fe.c, all trained on features produced by
# that same C compiled for the host:
#
#   dscnn     MLPerf Tiny / Hello Edge DS-CNN-S.  2,656,768 MACs, 23,180 params.
#   cnn       the same MAC budget in DENSE convolutions.  2,729,728 MACs, 123,324 params.
#   cnn_tiny  a quarter of it.  679,616 MACs, 61,340 params.
#
# THE QUESTION THIS LAB ANSWERS.  Depthwise-separable convolution is the standard way to
# make a keyword spotter cheap, and the two big models here have the same MAC count and
# the same accuracy to within 0.13 points.  MBP.DOT8 accelerates a reduction along the
# INPUT-CHANNEL axis -- and a depthwise convolution does not have one.  So the question
# is not which model has fewer operations, it is which model's operations this ISA can
# execute, and the answer is a cycle count rather than an argument.
#
# Each arch is code-generated TWICE from one extract_graph run -- scalar and pext -- and
# both images run on the same bitstream in the same board session, so every speedup here
# is a cycle ratio on one piece of silicon at one clock.
#
# Runs on the MICROPHONE bitstream (MAGIC 0x5A5A0005), which is the P-ext bitstream plus
# one MMIO peripheral: same harts, same ISA, same clock.  That is deliberate -- Lab B17
# needs the microphone and this establishes the model numbers on the same PL, so the two
# can be added together without a cross-bitstream caveat.
#
# Produces out/<name>/<arch>/{scalar,pext}/ and out/<name>/run.json.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

ARCHS="cnn dscnn cnn_tiny"
QUANT="int8"
ITERS=11
# The scalar baseline runs the SAME network with ModelBlaster's reference kernels, which
# on DS-CNN is ~3 s per inference. Eleven of those on each of two harts does not fit in
# any reasonable console window, and it does not need to: the spread across 11 iterations
# measured 0.00% of the median. Three is enough to have a median at all.
SCALAR_ITERS=3
NAME="rocket_kws"
BOARD="chipyard_pynqz1_mic"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_mic_z1/pynqz1_rocket_mic.bit"
SAMPLE_PEXT="$IISWC_ROOT/samples/modelblaster_pext"
SAMPLE_SCALAR="$IISWC_ROOT/samples/modelblaster_hart_latency"
EXPECT="$IISWC_ROOT/expected/kws_board.json"
LOAD_BIT=1
DO_BOARD=1
SECONDS_READ=240
WANT_MTIME_HZ=34483
NCALIB=64
while [ $# -gt 0 ]; do
  case "$1" in
    --archs) ARCHS="${2:?}"; shift 2 ;;
    --name)  NAME="${2:?}";  shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit)   BIT="${2:?}";   shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --scalar-iters) SCALAR_ITERS="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only)   DO_BOARD=0; shift ;;
    --no-check)     EXPECT=""; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

MB="$ZCS/modelblaster"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB -- scripts/00_bootstrap.sh --modelblaster"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_ROOT

# ---------------------------------------------------------------------------------
step "1/6  the ModelBlaster patches"
for P in 0009-modelblaster-pext-backend 0020-modelblaster-kws-models; do
  F="$IISWC_ROOT/patches/$P.patch"
  need_file "$F" "missing patch"
  if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then
    run git -C "$MB" apply "$F"; info "applied $P"
  elif git -C "$MB" apply --reverse --check "$F" >/dev/null 2>&1; then
    info "$P already applied"
  else
    die "patches/$P.patch neither applies nor is applied to $MB"
  fi
done

step "2/6  codegen: $(echo $ARCHS | wc -w) architecture(s) x {scalar, pext}"
codegen () {   # $1 = arch, $2 = target
  local a="$1" t="$2" ir="$RUN/$1/$2/ir" gen="$RUN/$1/$2/gen" extra=()
  mkdir -p "$ir" "$gen" "$RUN/$1/$2/cache"
  [ "$t" = pext ] && extra=(--global-curated-dir "$KERNELS")
  ( cd "$ZCS" && python -m modelblaster.pipeline.extract_graph \
      --model "kws_$a" --out-dir "$ir" --quant "$QUANT" \
      --num-calibration "$NCALIB" --fusion-target "$t" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "extract_graph ($a/$t) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" \
      --out-dir "$gen" --backend "$t" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_skeleton ($a/$t) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target "$t" \
      --quant "$QUANT" --io "$ir/io.npz" --repo-root "$MB" \
      --build-dir "$RUN/$a/$t/kverify" --harness-dir "$MB/harness" \
      --cache-dir "$RUN/$a/$t/cache" --algorithms all "${extra[@]}" ) \
    >> "$RUN/codegen.log" 2>&1 \
    || { tail -30 "$RUN/codegen.log"; die "generate_kernels ($a/$t) failed"; }
  need_file "$gen/kernels.c" "codegen ($a/$t) produced no kernels"
}
for A in $ARCHS; do
  run codegen "$A" scalar
  run codegen "$A" pext
  # The two builds MUST be the same network, or nothing compared between them means
  # anything. Same check Lab B10 makes, for the same reason.
  cmp -s "$RUN/$A/scalar/ir/graph.json" "$RUN/$A/pext/ir/graph.json" \
    || die "$A: the scalar and pext IR differ"
  cmp -s "$RUN/$A/scalar/gen/test_golden.bin" "$RUN/$A/pext/gen/test_golden.bin" \
    || die "$A: the two baked int8 goldens differ"
  OPS=$(python3 -c "import json,collections;g=json.load(open('$RUN/$A/pext/ir/graph.json'));print(' '.join('%s x%d'%(k,v) for k,v in sorted(collections.Counter(o['op'] for o in g['ops']).items())))")
  info "$A: $OPS"
  # Which dispatches actually got a curated MBP kernel, read out of the generated C
  # rather than assumed. This is the whole point of the lab for dscnn.
  python3 - "$RUN/$A/pext/gen/kernels.c" "$RUN/$A/pext/ir/graph.json" "$A" \
    > "$RUN/$A/curated.txt" <<'PYK'
import collections, json, re, sys
src, irp, arch = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(src).read()
g = json.load(open(irp))
n = collections.Counter(o["op"] for o in g["ops"] if o["op"] != "view")


def body_end(i):
    d = 0
    while i < len(t):
        d += (t[i] == "{") - (t[i] == "}")
        if d == 0:
            return i
        i += 1
    return len(t)


# WHICH DISPATCHES ACTUALLY GOT AN MBP KERNEL, read out of the generated C.
#
# Attributed by TEXT REGION, not by the `/* algorithm: ... */` comments and not by the
# exported function's own body.  The comments are per curated FILE, so a reference
# kernel emitted after one inherits it to any reader doing nearest-preceding matching;
# and the curated kernels put their MBP instructions in static helpers that the exported
# function calls, so its own body contains none.  Each kernel therefore owns the text
# from the end of the previous kernel's body to the end of its own -- helpers included.
#
# For dscnn this is the whole point of the lab: depthwise_conv2d_s8's region is an
# ordinary `acc += iv*wv` loop with no MBP instruction anywhere in it.
defs = []
for op in n:
    m = re.search(r"\bkernel_" + re.escape(op) + r"[a-z0-9_]*\s*\([^;{]*\{", t)
    if m:
        defs.append((m.start(), body_end(m.end() - 1), op))
defs.sort()
prev = 0
for start, end, op in defs:
    region = t[prev:end]
    prev = end
    calls = collections.Counter(re.findall(r"mb_pext_(dot8|max8|qmul|clip8)\s*\(", region))
    print("%s %-22s dispatches=%-2d MBP=%-3s %s"
          % (arch, op, n[op], "yes" if calls else "NO",
             " ".join("%s=%d" % kv for kv in sorted(calls.items())) or "(scalar reference)"))
for op in sorted(n):
    if op not in [d[2] for d in defs]:
        print("%s %-22s dispatches=%-2d NO DEFINITION" % (arch, op, n[op]))
PYK
  sed 's/^/    /' "$RUN/$A/curated.txt"
done

step "3/6  int8 accuracy on the whole test set"
# ModelBlaster bakes ONE golden output for ONE input. That proves the codegen matches its
# own quantisation; it says nothing about whether the quantised network still recognises
# words. So the int8 graph is re-executed in numpy over all 5,274 held-out clips -- and
# the simulator is first required to reproduce the baked golden BIT-EXACTLY on the baked
# input, which is what makes it the same arithmetic rather than a second opinion.
python3 "$IISWC_ROOT/fpga/pynq-z2/modelblaster/kws/int8_accuracy.py" \
  --run "$RUN" --archs "$ARCHS" --feat "${KWS_FEAT:?set KWS_FEAT to the extracted Speech Commands feature directory}" \
  | tee "$RUN/accuracy.txt" || warn "int8 accuracy sweep failed (features present?)"

step "4/6  build the Zephyr images"
MB_KERNEL_CFLAGS=$(cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['pext'].kernel_cflags))" 2>/dev/null || echo "-DMB_PEXT_HW=1")
for A in $ARCHS; do
  for T in pext scalar; do
    S="$SAMPLE_PEXT"; N="$ITERS"
    [ "$T" = scalar ] && { S="$SAMPLE_SCALAR"; N="$SCALAR_ITERS"; }
    D="$RUN/$A/$T"
    run west build -p always -b "$BOARD" "$S" -d "$D/build" -- \
        -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$N" \
        -DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS" >> "$RUN/build.log" 2>&1 \
      || { tail -40 "$RUN/build.log"; die "west build failed for $A/$T"; }
    cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
    cfg="$D/build/zephyr/.config"
    if [ "$T" = pext ]; then
      grep -q '^CONFIG_MB_PEXT=y' "$cfg" || die "$A/pext: CONFIG_MB_PEXT is not set"
    else
      grep -q '^CONFIG_MB_PEXT=y' "$cfg" && die "$A/scalar: CONFIG_MB_PEXT leaked into the baseline"
    fi
    grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$WANT_MTIME_HZ\$" "$cfg" \
      || die "$A/$T: board clock is not $WANT_MTIME_HZ"
    info "$A/$T: $(fsize "$D/zephyr.bin")"
  done
done
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }

step "5/6  run every image on one piece of silicon"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_mic.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "no bitstream"
  bitstream_identify "$BIT"
  bitstream_gate
  run scp -q "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
  HOLD_ARGS="--bitstream $(basename "$BIT") --hold"
else
  bitstream_identify ""
  HOLD_ARGS="--no-load --hold"
fi
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u run_rocket_mic.py $HOLD_ARGS'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q 'MAGIC = 0x5A5A0005' "$RUN/boot.log" || {
  cat "$RUN/boot.log"; die "wrong bitstream -- want the mic+P-ext one (0x5A5A0005)"; }

for A in $ARCHS; do
  for T in pext scalar; do
    D="$RUN/$A/$T"
    run scp -q "$D/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/zephyr.bin"
    "${SSH[@]}" "bash -lc '
      cd $PYNQ_DIR
      rm -f console.out
      nohup python3 -u console.py --seconds $SECONDS_READ > console.out 2>/dev/null &
      CPID=\$!
      sleep 1.5
      echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_mic.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
      wait \$CPID
    '" >> "$RUN/boot.log" 2>&1 || true
    "${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$D/console.txt" 2>/dev/null || true
    if grep -qE 'MB_PEXT_RUN|MB_RATIO' "$D/console.txt" 2>/dev/null; then
      info "$A/$T ran"
    else
      warn "$A/$T produced no result -- see $D/console.txt"
    fi
  done
done

step "6/6  the table"
python3 - "$RUN" "$ARCHS" "$BOARD" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run, archs, board = sys.argv[1], sys.argv[2].split(), sys.argv[3]
CLK = 34482759
# The front end's own measured cost per second of audio, from Lab B16's golden. Read,
# not retyped, so the two labs cannot drift apart.
fe = 0
try:
    g = json.load(open(os.path.join(os.path.dirname(run), "rocket_audio_fe", "run.json")))
    fe = g["rtf_x1000"]["kws-pext"] / 1000.0
except Exception:
    pass

MACS = {}
for a in archs:
    try:
        MACS[a] = json.load(open(os.path.join(
            os.environ["IISWC_ROOT"], "fpga/pynq-z2/modelblaster/kws/weights",
            "%s_meta.json" % a)))
    except Exception:
        MACS[a] = {}

def kv(line):
    return dict(re.findall(r'(\w+)=([-\w.]+)', line or ""))

out = {"board": board, "clock_hz": CLK, "archs": archs,
       "frontend_rtf_kws_pext": fe, "per_arch": {}}
for a in archs:
    d = {}
    for t in ("pext", "scalar"):
        p = os.path.join(run, a, t, "console.txt")
        txt = open(p).read() if os.path.exists(p) else ""
        if t == "pext":
            r = kv(next((l for l in txt.splitlines() if l.startswith("MB_PEXT_RUN")), ""))
            d["pext_cycles"] = int(r.get("median", 0))
            d["pext_ops"] = [kv(l) for l in txt.splitlines() if l.startswith("MB_PEXT_OP ")]
            m = re.search(r'^MB_PEXT_OUT\s+(.*)$', txt, re.M)
            d["out"] = [int(x) for x in m.group(1).split()] if m else []
            d["max_abs_err"] = int(kv(next((l for l in txt.splitlines()
                                            if "max_abs_err" in l), "")).get("max_abs_err", -1))
            neg = kv(next((l for l in txt.splitlines() if l.startswith("MB_PEXT_NEG cpu=")), ""))
            d["neg_trapped"] = neg.get("trapped") == "1"
        else:
            ms = [kv(l) for l in txt.splitlines() if l.startswith("MB_HART ")]
            h0 = next((m for m in ms if m.get("mhartid") == "0"), {})
            d["scalar_cycles"] = int(h0.get("median", 0))
            d["scalar_ops"] = [kv(l) for l in txt.splitlines() if l.startswith("MB_OP ")]
    d["macs"] = MACS[a].get("macs", 0)
    d["params"] = MACS[a].get("params", 0)
    d["acc_fp32"] = MACS[a].get("test_acc_fp32", 0)
    out["per_arch"][a] = d

print("\n-- 1. one inference, measured on hart 0 of this bitstream")
print("   %-9s %10s %8s %12s %12s %8s %10s %10s" %
      ("arch", "MACs", "params", "scalar cyc", "MBP cyc", "speedup", "MBP ms", "MAC/cyc"))
print("   " + "-" * 88)
for a in archs:
    d = out["per_arch"][a]
    sp = d["scalar_cycles"] / d["pext_cycles"] if d["pext_cycles"] else 0
    mc = d["macs"] / d["pext_cycles"] if d["pext_cycles"] else 0
    d["speedup"] = round(sp, 3); d["macs_per_cycle"] = round(mc, 4)
    d["pext_ms"] = round(1000.0 * d["pext_cycles"] / CLK, 3)
    print("   %-9s %10d %8d %12s %12d %8s %10.3f %10.3f" %
          (a, d["macs"], d["params"],
           d["scalar_cycles"] or "-", d["pext_cycles"],
           ("%.2fx" % sp) if sp else "-", d["pext_ms"], mc))

print("\n-- 2. per dispatch, MBP build (cycles)")
for a in archs:
    d = out["per_arch"][a]
    print("   %s:" % a)
    tot = sum(int(o.get("cycles", 0)) for o in d["pext_ops"])
    byop = {}
    for o in d["pext_ops"]:
        byop.setdefault(o.get("op", "?"), [0, 0])
        byop[o["op"]][0] += int(o.get("cycles", 0))
        byop[o["op"]][1] += 1
    for op, (c, n) in sorted(byop.items(), key=lambda kv: -kv[1][0]):
        print("      %-22s x%-2d %10d cycles  %5.1f%%" % (op, n, c, 100.0 * c / max(tot, 1)))
    d["cycles_by_op"] = {k: v[0] for k, v in byop.items()}

print("\n-- 3. what it costs to keep listening")
print("   Front end (Lab B16, kws geometry, MBP): RTF %.3f  (%.1f%% of one hart)"
      % (fe, fe * 100))
print("   %-9s %12s %12s %12s %12s" %
      ("arch", "1 inf/s", "2 inf/s", "5 inf/s", "10 inf/s"))
print("   " + "-" * 64)
for a in archs:
    d = out["per_arch"][a]
    row = []
    for r in (1, 2, 5, 10):
        rtf = fe + r * d["pext_cycles"] / CLK
        row.append("%.3f%s" % (rtf, "" if rtf < 1.0 else " X"))
        d["rtf_at_%d_per_s" % r] = round(rtf, 4)
    print("   %-9s %12s %12s %12s %12s" % (a, *row))
print("   (RTF = front end + model, as a fraction of one hart. 'X' = does not keep up.)")

print("\n-- 4. correctness")
for a in archs:
    d = out["per_arch"][a]
    print("   %-9s max_abs_err vs the scalar codegen's golden = %s   hart-1 trap = %s   "
          "fp32 test acc = %.2f%%"
          % (a, d["max_abs_err"], d["neg_trapped"], 100 * d["acc_fp32"]))
out["all_bit_exact"] = all(out["per_arch"][a]["max_abs_err"] == 0 for a in archs)
out["all_neg_trapped"] = all(out["per_arch"][a]["neg_trapped"] for a in archs)

# The headline comparison, if both big models ran.
if "cnn" in out["per_arch"] and "dscnn" in out["per_arch"]:
    c, s = out["per_arch"]["cnn"], out["per_arch"]["dscnn"]
    if c["pext_cycles"] and s["pext_cycles"]:
        out["dscnn_over_cnn_cycles_x100"] = round(100 * s["pext_cycles"] / c["pext_cycles"])
        print("\n-- 5. the headline")
        print("   dscnn has %.1f%% of cnn's MACs and takes %.2fx its cycles."
              % (100.0 * s["macs"] / c["macs"], s["pext_cycles"] / c["pext_cycles"]))
        print("   Depthwise convolution has no input-channel axis for MBP.DOT8 to reduce")
        print("   along, so on this ISA the cheaper model is the slower one.")
try:
    acc = json.load(open(os.path.join(run, "int8_accuracy.json")))
    out["int8_accuracy"] = acc
except Exception:
    pass
# The silicon and the numbers travel together: SOC_MAGIC names the CONFIG and
# every build of it reports the same value, so the md5 of the file actually
# loaded is the only thing that identifies the build.
out["bitstream_md5"] = os.environ.get("BIT_MD5", "unknown")
out["bitstream_note"] = os.environ.get("BIT_NOTE", "")
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=2)
PY

if [ -n "$EXPECT" ] && [ -f "$EXPECT" ]; then
  step "check  (vs $(basename "$EXPECT"))"
  python3 - "$RUN/run.json" "$EXPECT" <<'PY'
import json, sys
got = json.load(open(sys.argv[1])); exp = json.load(open(sys.argv[2]))
bad = 0
for k, want in exp.items():
    if k.startswith("_"):
        continue
    have = got.get(k)
    if isinstance(want, dict) and set(want) == {"min", "max"}:
        ok = have is not None and want["min"] <= have <= want["max"]
        s = "in [%s, %s]" % (want["min"], want["max"])
    else:
        ok = (have == want); s = repr(want)
    print("    %-5s %-32s expected %-22s got %s" % ("ok" if ok else "FAIL", k, s, have))
    bad += (not ok)
print("    %s" % ("PASS  reproduces the golden run" if not bad
                  else "FAIL  %d field(s) differ" % bad))
sys.exit(1 if bad else 0)
PY
fi
