#!/usr/bin/env bash
# Lab B19 -- what a transformer's NON-matmul operators actually cost on a core with no FPU.
#
#   scripts/with_board.sh ./scripts/39_rocket_xformer_cost.sh
#   scripts/with_board.sh ./scripts/39_rocket_xformer_cost.sh --models ffn_block
#
# SPEECH_ON_ROCKET.md section 6 prices every open-vocabulary model by its MULTIPLY-
# ACCUMULATES and says in as many words that those rows are a lower bound on the work
# rather than an estimate of the time, because 28 of ModelBlaster's 43 _s8 reference
# kernels dequantize to float and this SoC is `WithoutFPU`. For keyword spotting that
# caveat was harmless: conv2d, maxpool2d and linear_s8 are three of the fifteen kernels
# that are float-free, so a CNN never touches the other twenty-eight.
#
# For TRANSCRIPTION it is not harmless. Attention and normalisation are on the critical
# path of every model in that table, and their kernels are exactly the float-tainted
# ones: softmax_s8 is two expf per element, layernorm_s8 and rmsnorm_s8 are double with a
# sqrt, gelu_s8 is erff, add_s8 and mul_s8 are float per element.
#
# So this lab measures them, at transformer shapes, next to the MBP-accelerated linear
# that is the thing they are usually assumed to be a rounding error beside:
#
#   norm_block  d=64, M=1      layernorm_s8, rmsnorm_s8, gelu_s8, linear_s8
#   attn_block  d=32, s=8      matmul_s8 x2, softmax_s8, sin_s8, cos_s8, mul_s8, linear x5
#   ffn_block   seq=128, d=256, d_ff=1024   -- the REALISTIC one. Two 33.5 MMAC linears
#               against a 32,768-element layernorm, a 131,072-element gelu and a
#               32,768-element add. That is a real transformer MLP at a real size, and
#               it is the shape Whisper-tiny and Squeezeformer-XS are built out of.
#
# The output is cycles per ELEMENT for the pointwise ops and cycles per MAC for the
# GEMMs, which is what lets section 6's rows be re-priced from something measured.
#
# These three models are ModelBlaster's own (models/{norm,attn,ffn}_block.py) and were
# written upstream for exactly this purpose -- covering SmolVLA's uncovered op families
# on hardware. Nothing here is a synthetic stand-in.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

MODELS="norm_block attn_block ffn_block"
# Which MBP target to code-generate for.  `pext` is the bit-exact set of patches/0009;
# `pext_nl` is that plus the integer softmax / layer norm / GELU / matmul-requantise
# kernels of patches/0060, whose accuracy is numeric_drift and measured at 1-2 int8 LSB.
# Running the lab both ways on the same silicon is what turns "the float kernels are
# 84-98% of a transformer block" into a before-and-after rather than a claim.
TARGET="pext"
QUANT="int8"
ITERS=3
NAME="rocket_xformer_cost"
BOARD="chipyard_pynqz1_mic"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_mic_z1/pynqz1_rocket_mic.bit"
SAMPLE="$IISWC_ROOT/samples/modelblaster_pext"
LOAD_BIT=1
DO_BOARD=1
SECONDS_READ=300
WANT_MTIME_HZ=34483
WANT_MAGIC="0x5A5A0005"
while [ $# -gt 0 ]; do
  case "$1" in
    --models) MODELS="${2:?}"; shift 2 ;;
    --target) TARGET="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --seconds) SECONDS_READ="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only) DO_BOARD=0; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

MB="$ZCS/modelblaster"
KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
[ -d "$MB/pipeline" ] || die "no modelblaster checkout at $MB"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"
export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
export IISWC_ROOT

step "1/4  codegen  ($(echo $MODELS | wc -w) block(s), $TARGET target)"
for F in "$IISWC_ROOT/patches/0009-modelblaster-pext-backend.patch" \
         "$IISWC_ROOT/patches/0060-modelblaster-pext-pc-and-int-nonlin.patch"; do
  if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"; fi
done
for M in $MODELS; do
  ir="$RUN/$M/ir"; gen="$RUN/$M/gen"
  mkdir -p "$ir" "$gen" "$RUN/$M/cache"
  ( cd "$ZCS" && python -m modelblaster.pipeline.extract_graph \
      --model "$M" --out-dir "$ir" --quant "$QUANT" \
      --num-calibration 1 --fusion-target "$TARGET" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -20 "$RUN/codegen.log"; die "extract_graph ($M) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" \
      --out-dir "$gen" --backend "$TARGET" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -20 "$RUN/codegen.log"; die "generate_skeleton ($M) failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target "$TARGET" \
      --quant "$QUANT" --io "$ir/io.npz" --repo-root "$MB" \
      --build-dir "$RUN/$M/kverify" --harness-dir "$MB/harness" \
      --cache-dir "$RUN/$M/cache" --algorithms all \
      --global-curated-dir "$KERNELS" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -20 "$RUN/codegen.log"; die "generate_kernels ($M) failed"; }
  need_file "$gen/kernels.c" "codegen ($M) produced no kernels"
  # Which of this block's kernels are float, read out of the generated C. This is the
  # whole premise of the lab, so it is measured rather than taken from a doc.
  SF=$(grep -oE '\b(expf|erff|logf|log10f|sqrtf|tanhf|powf|roundf|lrintf|exp|tanh|sqrt|round)\s*\(' \
       "$gen/kernels.c" | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
  info "$M: libm call sites in kernels.c -> ${SF:-none}"
done

step "2/4  build"
MB_KERNEL_CFLAGS=$(cd "$ZCS" && python -c "
from modelblaster.pipeline import backends
print(' '.join(backends.BACKENDS['$TARGET'].kernel_cflags))" 2>/dev/null || echo "-DMB_PEXT_HW=1")
for M in $MODELS; do
  D="$RUN/$M"
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$D/gen" -DMB_ITERS="$ITERS" \
      -DMODELBLASTER_KERNEL_CFLAGS="$MB_KERNEL_CFLAGS" >> "$RUN/build.log" 2>&1 \
    || { tail -40 "$RUN/build.log"; die "west build failed for $M"; }
  cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
  grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$WANT_MTIME_HZ\$" "$D/build/zephyr/.config" \
    || die "$M: board clock is not $WANT_MTIME_HZ"
  # The soft-float symbols the image really links. For a transformer block this is NOT a
  # gate -- it is the measurement's premise, and an image with none of them would mean
  # the float-tainted kernels had been replaced behind our back.
  OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)
  "$OBJDUMP" -d "$D/zephyr.elf" > "$D/dis.txt"
  python3 - "$D/dis.txt" "$M" <<'PYG'
import re, sys
t = open(sys.argv[1]).read()
sf = sorted(set(re.findall(
    r'<(__(?:add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)'
    r'[a-z0-9]*(?:sf|df)[0-9a-z]*)>', t)))
lm = sorted(set(re.findall(r'<(expf?|erff?|logf?|sqrtf?|tanhf?|powf?)>', t)))
words = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
c0 = sum(1 for w in words if (int(w, 16) & 0x7f) == 0x0b)
print("    %s: custom-0=%d  libgcc soft-float=%s  libm=%s"
      % (sys.argv[2], c0, ",".join(sf) if sf else "none", ",".join(lm) if lm else "none"))
PYG
  info "$M image: $(fsize "$D/zephyr.bin")"
done
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }

step "3/4  run on hart 0"
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
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || {
  M=$(grep -oE 'MAGIC = 0x5A5A000[0-9]' "$RUN/boot.log" | head -1 || true)
  cat "$RUN/boot.log"; die "wrong bitstream: $M (want $WANT_MAGIC)"; }
for M in $MODELS; do
  D="$RUN/$M"
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
  if grep -q 'MB_PEXT_RUN' "$D/console.txt" 2>/dev/null; then info "$M ran"
  else warn "$M produced no result -- see $D/console.txt"; fi
done

step "4/4  cost per element"
python3 - "$RUN" "$MODELS" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run, models = sys.argv[1], sys.argv[2].split()
CLK = 34482759
# The fifteen float-free _s8 kernels, from SPEECH_ON_ROCKET.md section 3.2 (verified by
# parsing reference_kernels.py, not quoted).
INTEGER = {"conv2d_s8", "conv2d_pool_s8", "linear_s8", "maxpool2d_s8", "avgpool2d_s8",
           "depthwise_conv2d_s8", "relu_s8", "relu6_s8", "pad_s8", "upsample_nearest_s8",
           "cat2_c1_s8", "cat3_c1_s8", "cat4_c1_s8", "nchw_to_nhwc_s8", "nhwc_to_nchw_s8"}


def work(op, s):
    """(MACs, output elements) for one dispatch, from its IR shape."""
    if op.startswith("linear") or op.startswith("matmul"):
        return s.get("M", 1) * s.get("K", 0) * s.get("N", 0), s.get("M", 1) * s.get("N", 0)
    if op.startswith("conv2d") or op.startswith("depthwise"):
        g = s.get("OC", 1) if op.startswith("depthwise") else 1
        return (s.get("OC", 0) * s.get("OH", 0) * s.get("OW", 0) * s.get("IC", 0)
                * s.get("KH", 0) * s.get("KW", 0) // max(g, 1) if not op.startswith("depthwise")
                else s.get("OC", 0) * s.get("OH", 0) * s.get("OW", 0) * s.get("KH", 0) * s.get("KW", 0),
                s.get("OC", 0) * s.get("OH", 0) * s.get("OW", 0))
    if "n" in s:
        return 0, s["n"]
    if "M" in s and "K" in s:
        return 0, s["M"] * s["K"]
    return 0, 1


out = {"clock_hz": CLK, "models": models, "per_op": {}}
rows = []
for m in models:
    gp = os.path.join(run, m, "ir", "graph.json")
    cp = os.path.join(run, m, "console.txt")
    if not (os.path.exists(gp) and os.path.exists(cp)):
        continue
    g = json.load(open(gp))
    txt = open(cp).read()
    prof = {}
    for l in txt.splitlines():
        if l.startswith("MB_PEXT_OP "):
            d = dict(re.findall(r'(\w+)=(\S+)', l))
            prof[d.get("name")] = int(d.get("cycles", 0))
    # Which kernel each op ACTUALLY ran, read out of the codegen's own picks file
    # rather than from a static list of float-tainted operators.  With --target pext_nl
    # softmax_s8, layernorm_s8, gelu_s8 and matmul_s8 have curated integer kernels, and
    # a report that still called them FLOAT because the reference expression is float
    # would be describing the previous run.
    picks = {}
    pp = "%s/%s/gen/kernel_picks.json" % (run, m)
    if os.path.exists(pp):
        for k, v in json.load(open(pp)).get("picks", {}).items():
            if v.get("source", "reference") != "reference":
                picks[k] = v.get("algorithm") or "curated"
    for o in g["ops"]:
        if o["op"] == "view" or o["name"] not in prof:
            continue
        macs, els = work(o["op"], o.get("shape", {}))
        rows.append((m, o["name"], o["op"], macs, els, prof[o["name"]], picks.get(o["op"])))

print("\n-- every dispatch, measured on hart 0 (cycles)")
print("   %-11s %-22s %10s %9s %12s %10s %10s  %s"
      % ("block", "op", "MACs", "elements", "cycles", "cyc/MAC", "cyc/elem", "kernel"))
print("   " + "-" * 108)
agg = {}
for m, name, op, macs, els, cyc, pick in rows:
    kind = pick if pick else ("integer" if op in INTEGER else "FLOAT")
    print("   %-11s %-22s %10s %9s %12s %10s %10s  %s"
          % (m, op, f"{macs:,}" if macs else "-", f"{els:,}", f"{cyc:,}",
             "%.2f" % (cyc / macs) if macs else "-",
             "%.1f" % (cyc / els) if els else "-", kind))
    a = agg.setdefault(op, {"cyc": 0, "els": 0, "macs": 0, "kind": kind, "n": 0})
    a["cyc"] += cyc; a["els"] += els; a["macs"] += macs; a["n"] += 1

print("\n-- cost per output element, by operator")
print("   %-22s %4s %12s %10s %12s  %s" % ("op", "n", "cycles", "elements", "cyc/element", "kernel"))
print("   " + "-" * 76)
for op, a in sorted(agg.items(), key=lambda kv: -(kv[1]["cyc"] / max(kv[1]["els"], 1))):
    cpe = a["cyc"] / max(a["els"], 1)
    print("   %-22s %4d %12s %10s %12.1f  %s"
          % (op, a["n"], f"{a['cyc']:,}", f"{a['els']:,}", cpe, a["kind"]))
    out["per_op"][op] = {"cycles": a["cyc"], "elements": a["els"], "macs": a["macs"],
                         "cycles_per_element": round(cpe, 2), "kind": a["kind"],
                         "cycles_per_mac": round(a["cyc"] / a["macs"], 3) if a["macs"] else None}

# The headline: a real transformer MLP, and where its time goes.
if "ffn_block" in models:
    f = [r for r in rows if r[0] == "ffn_block"]
    tot = sum(r[5] for r in f)
    gemm = sum(r[5] for r in f if r[2].startswith("linear"))
    if tot:
        print("\n-- ffn_block: a transformer MLP at seq=128, d_model=256, d_ff=1024")
        for m, name, op, macs, els, cyc, pick in sorted(f, key=lambda r: -r[5]):
            print("      %-16s %-16s %12s cycles  %5.1f%%   %s"
                  % (name, op, f"{cyc:,}", 100 * cyc / tot,
                     pick if pick else ("integer" if op in INTEGER else "FLOAT")))
        print("      %-33s %12s cycles  %5.1f%%  = %.3f s"
              % ("TOTAL", f"{tot:,}", 100.0, tot / CLK))
        out["ffn_total_cycles"] = tot
        out["ffn_gemm_share_pct"] = round(100 * gemm / tot, 2)
        out["ffn_float_share_pct"] = round(100 * (tot - gemm) / tot, 2)
        print("\n   GEMM (the MBP-accelerated linears) : %5.1f%%" % (100 * gemm / tot))
        print("   everything else                   : %5.1f%%" % (100 * (tot - gemm) / tot))
        print("\n   The MAC count says the two linears are ~100%% of the arithmetic.")
        print("   Measured, they are %.1f%% of the time." % (100 * gemm / tot))
# The silicon and the numbers travel together: SOC_MAGIC names the CONFIG and
# every build of it reports the same value, so the md5 of the file actually
# loaded is the only thing that identifies the build.
out["bitstream_md5"] = os.environ.get("BIT_MD5", "unknown")
out["bitstream_note"] = os.environ.get("BIT_NOTE", "")
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=2)
PY
