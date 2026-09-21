#!/usr/bin/env bash
# Lab B21 -- offline connected-digit TRANSCRIPTION from the board's own microphone.
#
#   scripts/with_board.sh ./scripts/41_rocket_digits.sh
#
# Labs B17 and B18 classify: the output is one of twelve slots. This TRANSCRIBES -- a
# variable-length digit string out of a 4.01 s recording, decoded with CTC and scored
# with edit distance. It is the smallest thing on this SoC that is honestly
# transcription, and Lab B19 is why nothing larger is: a transformer MLP block measured
# 16.868 s here, 84.4% of it in float kernels.
#
# RECORD, THEN POST-PROCESS. Lab B18 found the constraint on a LIVE spotter is inference
# latency against the microphone's 64 ms FIFO. Recording first removes that by
# construction, and what is left is the wait: 4.01 s of audio in a few hundred ms.
#
# The graph is four conv2d_s8 dispatches and nothing else -- no softmax, no LayerNorm,
# no attention. A greedy CTC decode needs no softmax at all, because argmax is invariant
# under it. None of the 28 float-tainted kernels is reachable from this model.
#
# WHAT IS MEASURED HERE AND WHAT IS NOT. This measures the time, and that the model in
# the image is bit-for-bit the verified one. The WORD ERROR RATE comes from the held-out
# corpus sweep (fpga/pynq-z2/modelblaster/kws/int8_wer.py -- 12.98% int8 over 800
# utterances), on corpus audio, not from an empty room.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

# digit_ctc_t: the transposed layout. Identical MACs and identical K per layer to
# digit_ctc_wide, and 16.93x fewer cycles -- 1.24 cycles/MAC against 20.92, because the
# curated MBP conv kernel's NCHW gather walks contiguous runs of KW bytes and this model
# has KW = 5 where the other has KW = 1. `--arch digit_ctc_wide` reproduces the slow one,
# which is the more instructive of the two. SPEECH_ON_ROCKET.md section 11.4.
ARCH="digit_ctc_t"
NAME=""
BOARD="chipyard_pynqz1_mic"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_mic_z1/pynqz1_rocket_mic.bit"
SAMPLE="$IISWC_ROOT/samples/digits_live"
KWS_RUN="$IISWC_OUT/rocket_kws"
SECONDS_LISTEN=20
UTTERANCES=4
# The curated conv kernel's repacked-weight block, as a build flag -- the kernel declares
# it `#ifndef MB_PEXT_CONV_WBYTES / #define ... 8192`, so this overrides it without
# touching the frozen file in kernels/pext/.
#
# 8192 is the shipped default and is right for LeNet, whose largest repacked row set is
# 2,432 B. This model is a different shape: c3 has K = 640, so an 8 KB block holds 12 of
# its 128 output channels and the kernel re-gathers that layer's reduction vector eleven
# times per output pixel. The first run of this lab measured 165,103,691 cycles -- 21.4
# cycles per MAC, near the SCALAR rate -- for exactly that reason. Lab B13 found the same
# thing on DroNet and for the same reason.
CONV_WBYTES=65536
INFER_EVERY=10
LOAD_BIT=1
DO_BOARD=1
EXPECT="$IISWC_ROOT/expected/digits.json"
WANT_MTIME_HZ=34483
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --seconds) SECONDS_LISTEN="${2:?}"; shift 2 ;;
    --utterances) UTTERANCES="${2:?}"; shift 2 ;;
    --conv-wbytes) CONV_WBYTES="${2:?}"; shift 2 ;;
    --infer-every) INFER_EVERY="${2:?}"; shift 2 ;;
    --kws-run) KWS_RUN="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only) DO_BOARD=0; shift ;;
    --no-check) EXPECT=""; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
NAME="${NAME:-rocket_digits_$ARCH}"
GEN="$KWS_RUN/$ARCH/pext/gen"
META="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kws/weights/${ARCH}_meta.json"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"

step "1/4  the model and the feature map"
# Code-generate here rather than leaning on Lab B17's output directory: that lab builds
# the three CLASSIFIERS and runs a classification accuracy sweep, and this model is a
# transcriber whose score is an edit distance. Re-running it just to get a gen/ would
# spend half an hour on the board for nothing.
if [ ! -f "$GEN/model.c" ]; then
  GEN="$RUN/gen"
  MB="$ZCS/modelblaster"
  KERNELS="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
  export PYTHONPATH="$ZCS${PYTHONPATH:+:$PYTHONPATH}"
  export CPATH="$IISWC_ROOT/fpga/pynq-z2/sw${CPATH:+:$CPATH}"
  export IISWC_ROOT
  F="$IISWC_ROOT/patches/0009-modelblaster-pext-backend.patch"
  if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"; fi
  F="$IISWC_ROOT/patches/0020-modelblaster-kws-models.patch"
  if git -C "$MB" apply --check "$F" >/dev/null 2>&1; then run git -C "$MB" apply "$F"; fi
  mkdir -p "$RUN/ir" "$GEN" "$RUN/cache"
  info "code-generating kws_$ARCH for the pext target"
  ( cd "$ZCS" && python -m modelblaster.pipeline.extract_graph \
      --model "kws_$ARCH" --out-dir "$RUN/ir" --quant int8 \
      --num-calibration 64 --fusion-target pext ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -20 "$RUN/codegen.log"; die "extract_graph failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_skeleton \
      --ir "$RUN/ir/graph.json" --weights "$RUN/ir/weights.npz" --io "$RUN/ir/io.npz" \
      --out-dir "$GEN" --backend pext ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -20 "$RUN/codegen.log"; die "generate_skeleton failed"; }
  ( cd "$ZCS" && python -m modelblaster.pipeline.generate_kernels \
      --ir "$RUN/ir/graph.json" --out-dir "$GEN" --backend reference --target pext \
      --quant int8 --io "$RUN/ir/io.npz" --repo-root "$MB" \
      --build-dir "$RUN/kverify" --harness-dir "$MB/harness" \
      --cache-dir "$RUN/cache" --algorithms all \
      --global-curated-dir "$KERNELS" ) >> "$RUN/codegen.log" 2>&1 \
    || { tail -20 "$RUN/codegen.log"; die "generate_kernels failed"; }
  # The premise of this lab is that the graph contains NO float-tainted operator. That
  # is checked, not assumed: a stray softmax_s8 or layernorm_s8 would still run and
  # would still transcribe, three orders of magnitude slower (Lab B19).
  OPS=$(python3 -c "import json,collections;g=json.load(open('$RUN/ir/graph.json'));print(' '.join(sorted({o['op'] for o in g['ops'] if o['op']!='view'})))")
  info "graph ops: $OPS"
  for op in $OPS; do
    case "$op" in
      conv2d_s8|linear_s8|maxpool2d_s8|avgpool2d_s8|relu_s8|relu6_s8|depthwise_conv2d_s8) ;;
      *) die "graph contains '$op', which is not one of the float-free kernels --
       Lab B19 measured what that costs and this lab's premise does not survive it" ;;
    esac
  done
fi
need_file "$GEN/model.c" "incomplete codegen at $GEN"
need_file "$META" "no trained metadata for arch '$ARCH'"
# The Q8 -> int8 feature map is generated from the SAME meta.json the trainer wrote.
# An offset that disagrees by one between training and inference is a silent accuracy
# loss with no symptom on the board, so it is derived rather than retyped.
run python3 "$IISWC_ROOT/fpga/pynq-z2/sw/tools/gen_feat_map.py" \
    --meta "$META" --out "$RUN/kws_featmap.h"
run python3 "$IISWC_ROOT/fpga/pynq-z2/sw/tools/gen_fe_tables.py" --check

step "2/4  build"
run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" -DMODEL_DIR="$GEN" \
    -DKWS_FEATMAP="$RUN/kws_featmap.h" \
    -DDG_UTTERANCES="$UTTERANCES" \
    -DMODELBLASTER_KERNEL_CFLAGS="-DMB_PEXT_HW=1 -DMB_PEXT_CONV_WBYTES=$CONV_WBYTES" \
    > "$RUN/build.log" 2>&1 \
  || { tail -40 "$RUN/build.log"; die "build failed -- see $RUN/build.log"; }
cp "$RUN/build/zephyr/zephyr.elf" "$RUN/build/zephyr/zephyr.bin" "$RUN/"
cfg="$RUN/build/zephyr/.config"
grep -q '^CONFIG_MB_PEXT=y' "$cfg" || die "CONFIG_MB_PEXT is not set -- this image would
       run pext.h's SOFTWARE MODEL and the duty cycle would be a different number"
grep -q '^CONFIG_AUDIO_DMIC_PDM_MMIO=y' "$cfg" || die "the PDM driver did not build --
       the devicetree node did not match, and device_is_ready() would fail on the board"
grep -q "^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$WANT_MTIME_HZ\$" "$cfg" \
  || die "board clock is not $WANT_MTIME_HZ"
OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)
"$OBJDUMP" -d "$RUN/zephyr.elf" > "$RUN/dis.txt"
python3 - "$RUN/dis.txt" <<'PYG'
import re, sys
t = open(sys.argv[1]).read()
words = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
c0 = [int(w, 16) for w in words if (int(w, 16) & 0x7f) == 0x0b]
f3 = {}
for w in c0:
    f3[(w >> 12) & 7] = f3.get((w >> 12) & 7, 0) + 1
sf = sorted(set(re.findall(
    r'<(__(?:add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)'
    r'[a-z0-9]*(?:sf|df)[0-9a-z]*)>', t)))
print("    custom-0 sites=%d by funct3 %s (0=DOT8 1=MAX8 2=QMUL 3=CLIP8)" % (len(c0), f3))
print("    libgcc soft-float symbols: %s" % (",".join(sf) if sf else "none"))
if not c0:
    raise SystemExit("FAIL: the image carries no MBP encodings")
if sf:
    raise SystemExit("FAIL: the image calls libgcc soft-float: %s" % sf)
PYG
info "image: $(fsize "$RUN/zephyr.bin")"
[ "$DO_BOARD" -eq 1 ] || { info "--build-only: stopping before the board"; exit 0; }

step "3/4  listen"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_mic.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$RUN/zephyr.bin" "$PYNQ_HOST:$PYNQ_DIR/"
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
  M=$(grep -oE 'MAGIC = 0x5A5A000[0-9]' "$RUN/boot.log" | head -1 || true)
  cat "$RUN/boot.log"; die "wrong bitstream: $M (want the mic+P-ext one, 0x5A5A0005)"; }
CONSOLE_S=$((UTTERANCES * 14 + 60))
info "recording $UTTERANCES x 4.01 s -- say digit strings when prompted"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $CONSOLE_S > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u run_rocket_mic.py --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  wait \$CPID
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
printf '%s\n' "----------------------------------------------------------------"
grep -vE '^$' "$RUN/console.txt" | head -40
printf '%s\n' "----------------------------------------------------------------"

step "4/4  the transcript, and what it cost"
python3 - "$RUN" "$ARCH" "$BOARD" "$META" <<'PYD' | tee "$RUN/report.txt"
import json, os, re, sys
run, arch, board, metap = sys.argv[1:5]
txt = open(os.path.join(run, "console.txt")).read()
meta = json.load(open(metap))


def kv(pfx):
    l = next((l for l in txt.splitlines() if l.startswith(pfx)), "")
    return dict(re.findall(r'(\w+)=([-\w.]+)', l))


out = {"arch": arch, "board": board, "macs": meta["macs"], "params": meta["params"],
       "fp32_wer": meta["test_wer_fp32"], "done": "DIGITS done" in txt,
       "selftest_ok": " fails=0" in txt}
s = kv("DIGITS start")
out["hart"] = int(s.get("hart", -1))
out["mb_pext_hw"] = int(s.get("mb_pext_hw", 0))
out["out_frames"] = int(s.get("out_t", 0))
out["model_max_abs_err"] = int(kv("DIGITS_MODEL_CHECK").get("max_abs_err", -1))
out["mic_rate_hz"] = int(kv("DIGITS mic").get("rate", 0))
res = [dict(re.findall(r'(\w+)=([-\w.]+)', l)) for l in txt.splitlines()
       if l.startswith("DIGITS_TIME")]
texts = re.findall(r'^DIGITS_RESULT utterance=(\d+) ndigits=(\d+) text=(.*)$', txt, re.M)
out["utterances"] = len(res)
if res:
    fe = sorted(int(r["frontend"]) for r in res)
    md = sorted(int(r["model"]) for r in res)
    out["frontend_cycles"] = fe[len(fe) // 2]
    out["model_cycles"] = md[len(md) // 2]
    out["total_ms"] = round(1000.0 * (out["frontend_cycles"] + out["model_cycles"])
                            / 34482759, 1)
    out["audio_ms"] = int(res[0].get("audio_ms", 0))
    out["rtf"] = round(out["total_ms"] / max(out["audio_ms"], 1), 4)
    out["rms_counts"] = int(res[0].get("rms", 0))
print("\n   %s: %s MACs, %s parameters, fp32 WER %.2f%%"
      % (arch, "{:,}".format(meta["macs"]), "{:,}".format(meta["params"]),
         100 * meta["test_wer_fp32"]))
print("   model vs the baked int8 golden, on this silicon: max_abs_err = %s"
      % out["model_max_abs_err"])
print("\n-- what it transcribed")
for u, n, s2 in texts:
    print("   utterance %s: %s digit(s)  ->  %s" % (u, n, s2))
if res:
    print("\n-- what it cost, per 4.01 s utterance (median of %d)" % len(res))
    print("   front end (%d frames)  %10s cycles  %7.1f ms"
          % (200, "{:,}".format(out["frontend_cycles"]),
             1000.0 * out["frontend_cycles"] / 34482759))
    print("   model (4 conv2d_s8)   %10s cycles  %7.1f ms"
          % ("{:,}".format(out["model_cycles"]),
             1000.0 * out["model_cycles"] / 34482759))
    print("   TOTAL                 %10s  %16.1f ms   for %d ms of audio"
          % ("", out["total_ms"], out["audio_ms"]))
    print("   real-time factor      %10.3f  -- offline, so this is the WAIT, not a limit"
          % out["rtf"])
    print("\n   microphone rms %d counts over the capture." % out["rms_counts"])
print("\n   The word error rate is NOT measured here: an empty room is not a test set.")
print("   It comes from the held-out corpus sweep -- fpga/pynq-z2/modelblaster/kws/")
print("   int8_wer.py, 12.98% int8 over 800 utterances -- on corpus audio through this")
print("   same front end.")
# The silicon and the numbers travel together: SOC_MAGIC names the CONFIG and
# every build of it reports the same value, so the md5 of the file actually
# loaded is the only thing that identifies the build.
out["bitstream_md5"] = os.environ.get("BIT_MD5", "unknown")
out["bitstream_note"] = os.environ.get("BIT_NOTE", "")
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=2)
PYD

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
    print("    %-5s %-26s expected %-22s got %s" % ("ok" if ok else "FAIL", k, s, have))
    bad += (not ok)
print("    %s" % ("PASS  reproduces the golden run" if not bad
                  else "FAIL  %d field(s) differ" % bad))
sys.exit(1 if bad else 0)
PY
fi
