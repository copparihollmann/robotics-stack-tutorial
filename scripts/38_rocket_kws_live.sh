#!/usr/bin/env bash
# Lab B18 -- a keyword spotter listening to the board's own microphone, and its
# duty cycle MEASURED rather than projected.
#
#   scripts/with_board.sh ./scripts/38_rocket_kws_live.sh
#   scripts/with_board.sh ./scripts/38_rocket_kws_live.sh --arch cnn_tiny --seconds 30
#
# Everything below is on the SoC: the PDM microphone, the CIC+FIR decimator, Zephyr's
# DMIC driver, the fixed-point MFCC front end, and an int8 CNN executed with the MBP
# instructions on hart 0. Nothing streams to the host and nothing is computed on it --
# the host loads a bitstream, loads an image, and reads a console.
#
# WHY THIS LAB EXISTS SEPARATELY FROM B16.  Lab B17 measures one inference on a baked
# test vector, eleven times, with interrupts locked. That is the right way to get a
# cycle count and the wrong way to get a duty cycle: it excludes the DMIC driver, the
# block copies, the ring bookkeeping and the console, and it says nothing about whether
# the pipeline keeps up with a microphone that does not wait. This runs the whole thing
# against real time for KWS_SECONDS and divides cycles-in-work by cycles-elapsed.
#
# THE CLAIM THIS REPLACES.  fpga/pynq-z2/docs/ROCC_STUDY.md section 12 says a keyword
# spotter is "under 3% duty cycle". That was a projection from a MAC count. The measured
# number is in out/<name>/run.json and it is not 3%.
#
# Produces out/<name>/{zephyr.elf,console.txt,run.json}.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

# cnn_tiny and not cnn, and the reason is the finding this lab made.
#
# ONE INFERENCE MUST FIT IN THE MICROPHONE'S FIFO, and that is a constraint on LATENCY,
# not on duty cycle. The PDM peripheral's FIFO holds 1024 samples = 64.0 ms. A kws_cnn
# inference is 103.2 ms = 1,632 samples (Lab B17), so while it runs the FIFO fills and
# overruns -- EVERY TIME, however rarely inference is scheduled, and with the hart only
# 48.5% busy. Measured: "W: FIFO overran" on the console and elapsed/audio = 1.211.
#
#   kws_cnn        103.2 ms   1,632 samples   OVERRUNS
#   kws_dscnn      353.1 ms   5,647 samples   OVERRUNS
#   kws_cnn_tiny    28.6 ms     458 samples   fits, with 2.2x of margin
#
# So the default is the model that fits. `--arch cnn` still works and still produces the
# overrun; SPEECH_ON_ROCKET.md section 4.4 reports both, because the failing one is the
# more useful measurement.
ARCH="cnn_tiny"
NAME=""
BOARD="chipyard_pynqz1_mic"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_mic_z1/pynqz1_rocket_mic.bit"
SAMPLE="$IISWC_ROOT/samples/kws_live"
KWS_RUN="$IISWC_OUT/rocket_kws"
SECONDS_LISTEN=20
INFER_EVERY=10
LOAD_BIT=1
DO_BOARD=1
EXPECT="$IISWC_ROOT/expected/kws_live.json"
WANT_MTIME_HZ=34483
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --seconds) SECONDS_LISTEN="${2:?}"; shift 2 ;;
    --infer-every) INFER_EVERY="${2:?}"; shift 2 ;;
    --kws-run) KWS_RUN="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --build-only) DO_BOARD=0; shift ;;
    --no-check) EXPECT=""; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
NAME="${NAME:-rocket_kws_live_$ARCH}"
GEN="$KWS_RUN/$ARCH/pext/gen"
META="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kws/weights/${ARCH}_meta.json"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"; rm -rf "$RUN"; mkdir -p "$RUN"

step "1/4  the model and the feature map"
[ -d "$GEN" ] || die "no generated model at $GEN -- run scripts/37_rocket_kws_board.sh first
       (it is what code-generates the pext build this image links against)"
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
    -DKWS_SECONDS="$SECONDS_LISTEN" -DKWS_INFER_EVERY="$INFER_EVERY" \
    -DMODELBLASTER_KERNEL_CFLAGS="-DMB_PEXT_HW=1" > "$RUN/build.log" 2>&1 \
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
CONSOLE_S=$((SECONDS_LISTEN + 40))
info "listening for ${SECONDS_LISTEN} s -- say 'yes', 'no', 'up', 'down', 'stop', 'go' at the board"
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
grep -vE '^KWS_HIT ' "$RUN/console.txt" | head -30
HITS=$(grep -c '^KWS_HIT ' "$RUN/console.txt" || true)
printf '    (%s KWS_HIT lines suppressed above; see console.txt)\n' "${HITS:-0}"
printf '%s\n' "----------------------------------------------------------------"

step "4/4  the duty cycle"
python3 - "$RUN" "$ARCH" "$BOARD" "$META" <<'PY' | tee "$RUN/report.txt"
import collections, json, os, re, sys
run, arch, board, metap = sys.argv[1:5]
txt = open(os.path.join(run, "console.txt")).read()
meta = json.load(open(metap))


def kv(pfx):
    l = next((l for l in txt.splitlines() if l.startswith(pfx)), "")
    return dict(re.findall(r'(\w+)=([-\w.]+)', l))


out = {"arch": arch, "board": board, "macs": meta["macs"],
       "params": meta["params"], "acc_fp32": meta["test_acc_fp32"]}
try:
    out["image_bytes"] = os.path.getsize(os.path.join(run, "zephyr.bin"))
except OSError:
    pass
s, d, c, pm, pu, au = (kv("KWS_LIVE start"), kv("KWS_DUTY"), kv("KWS_CYCLES"),
                       kv("KWS_PERMILLE"), kv("KWS_PER_UNIT"), kv("KWS_AUDIO"))
lv = kv("KWS_LEVEL")
out["rms_counts"] = int(lv.get("rms", 0))
out["peak_counts"] = int(lv.get("peak", 0))
out["rms_dbfs"] = int(lv.get("rms_dbfs_x10", 0)) / 10.0
out["peak_dbfs"] = int(lv.get("peak_dbfs_x10", 0)) / 10.0
out["done"] = "KWS_LIVE done" in txt
out["selftest_ok"] = "FE_SELFTEST" in txt and " fails=0" in txt
mc = kv("KWS_MODEL_CHECK")
out["model_max_abs_err"] = int(mc.get("max_abs_err", -1))
out["mic_rate_hz"] = int(kv("KWS_LIVE mic").get("rate", 0))
out["hart"] = int(s.get("hart", -1))
out["mb_pext_hw"] = int(s.get("mb_pext_hw", 0))
out["infer_every"] = int(s.get("infer_every", 0))
for k in ("blocks", "frames", "inferences", "detections"):
    out[k] = int(d.get(k, 0))
for k in ("total", "frontend", "model"):
    out["cycles_" + k] = int(c.get(k, 0))
out["permille_frontend"] = int(pm.get("frontend", -1))
out["permille_model"] = int(pm.get("model", -1))
out["permille_busy"] = int(pm.get("busy", -1))
out["frame_cycles"] = int(pu.get("frame_cycles", 0))
out["infer_cycles"] = int(pu.get("infer_cycles", 0))
out["audio_seconds"] = int(au.get("seconds_x1000", 0)) / 1000.0
hits = collections.Counter(
    m.group(1) for m in re.finditer(r'^KWS_HIT .*label=(\S+)', txt, re.M))
out["hits_by_label"] = dict(hits)

print("\n   %s, %s MACs, %d parameters, fp32 test accuracy %.2f%%"
      % (arch, "{:,}".format(meta["macs"]), meta["params"],
         100 * meta["test_acc_fp32"]))
print("   microphone %d Hz, %d blocks = %.2f s of audio, %d MFCC frames, %d inferences"
      % (out["mic_rate_hz"], out["blocks"], out["audio_seconds"],
         out["frames"], out["inferences"]))
print("\n-- measured duty cycle, over real time, on hart 0")
print("   front end   %6.2f%%   (%d cycles per 30 ms frame, %d frames)"
      % (out["permille_frontend"] / 10.0, out["frame_cycles"], out["frames"]))
print("   model       %6.2f%%   (%d cycles per inference, %d inferences)"
      % (out["permille_model"] / 10.0, out["infer_cycles"], out["inferences"]))
print("   BUSY        %6.2f%%   -- and the other %.2f%% is the DMIC driver, the block"
      % (out["permille_busy"] / 10.0, 100 - out["permille_busy"] / 10.0))
print("                          copies, the ring bookkeeping, the console and idle.")
if out["audio_seconds"]:
    rt = out["cycles_total"] / 34482759.0
    out["realtime_ratio"] = round(rt / out["audio_seconds"], 4)
    print("\n   elapsed %.2f s of cycles for %.2f s of audio -- ratio %.3f"
          % (rt, out["audio_seconds"], out["realtime_ratio"]))
    print("   (must be ~1.00: the microphone sets the pace, so anything else means the")
    print("    pipeline fell behind and the DMIC FIFO absorbed or dropped it.)")
print("\n   model vs the baked int8 golden on this silicon: max_abs_err = %s"
      % out["model_max_abs_err"])

print("\n-- signal level, which is the thing that could differ from the corpus")
print("   rms %d counts (%.1f dBFS), peak %d (%.1f dBFS) over %s samples"
      % (out["rms_counts"], out["rms_dbfs"], out["peak_counts"], out["peak_dbfs"],
         lv.get("samples", "?")))
print("   (a quiet room measures -60.9 dBFS rms on this microphone; the training corpus")
print("    is recorded close and loud. MFCC c1..c9 are level-invariant, c0 is not.)")

print("\n-- what it heard")
if hits:
    for k, v in hits.most_common():
        print("   %-12s %d" % (k, v))
else:
    print("   nothing above the margin (a quiet room is a valid outcome)")
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
    print("    %-5s %-26s expected %-22s got %s" % ("ok" if ok else "FAIL", k, s, have))
    bad += (not ok)
print("    %s" % ("PASS  reproduces the golden run" if not bad
                  else "FAIL  %d field(s) differ" % bad))
sys.exit(1 if bad else 0)
PY
fi
