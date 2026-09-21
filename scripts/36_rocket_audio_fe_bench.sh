#!/usr/bin/env bash
# Lab B16 -- what a speech front end costs on a Rocket with no FPU.
#
#   scripts/with_board.sh ./scripts/36_rocket_audio_fe_bench.sh
#
# Before any speech model can be priced on this SoC, the FEATURES have to be priced, and
# the answer is not obvious: a 512-point FFT at a 10 ms hop is ~5,000 multiplies per
# frame, and `WithoutFPU` turns every float one of them into a libgcc call. This lab
# builds ONE front end (fpga/pynq-z2/sw/audio_fe.c) THREE ways and runs all three on the
# same silicon in the same board session:
#
#   float   idiomatic floats, libm log2f            -- the straw man, measured not assumed
#   int     fixed point, twiddle multiply = `mul`   -- the core's iterative multiplier
#   pext    fixed point, twiddle multiply = MBP.QMUL -- the extension, reused
#
# THE POINT.  MBP.QMUL was designed for the int8 requantise stage: it computes
# (a*m + 2^30) >> 31 in one cycle, which is a rounded Q0.31 fixed-point multiply -- and
# that is exactly what an integer FFT butterfly needs. MBP.DOT8, the instruction the
# extension is usually advertised by, is useless here: an FFT wants int16/int32 operands,
# not eight int8 lanes. So the extension helps the front end, through a different door.
#
# WHAT "PASS" MEANS.  Not "it ran". The three builds must (a) all pass audio_fe_selftest
# on the silicon, (b) agree on the feature vector to within the divergence
# SPEECH_ON_ROCKET.md quotes -- int and pext BIT-IDENTICALLY, because they are the same
# expression -- and (c) produce a per-stage cycle breakdown. A front end that got faster
# by computing something else is what (b) catches.
#
# Also measured here, because every cost model in SPEECH_ON_ROCKET.md rests on it: the
# per-operation cost of `add`, `mul`, `mulw`, the software QMUL, MBP.QMUL and MBP.DOT8,
# as dependent chains on hart 0.
#
# Produces out/<name>/{float,int,pext}/{zephyr.elf,console.txt} and out/<name>/run.json.
#
# Usage:
#   scripts/with_board.sh ./scripts/36_rocket_audio_fe_bench.sh
#   scripts/with_board.sh ./scripts/36_rocket_audio_fe_bench.sh --no-bitstream
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"

SAMPLE="$IISWC_ROOT/samples/audio_fe_bench"
NAME="rocket_audio_fe"
BOARD="chipyard_pynqz1_mic"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_mic_z1/pynqz1_rocket_mic.bit"
EXPECT="$IISWC_ROOT/expected/audio_fe_bench.json"
LOAD_BIT=1
SECONDS_READ=25
VARIANTS="float int pext"
GEOMS="asr kws"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --variants) VARIANTS="${2:?}"; shift 2 ;;
    --geoms) GEOMS="${2:?}"; shift 2 ;;
    --no-bitstream) LOAD_BIT=0; shift ;;
    --no-check) EXPECT=""; shift ;;
    --build-only) LOAD_BIT=0; BUILD_ONLY=1; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
BUILD_ONLY="${BUILD_ONLY:-0}"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
rm -rf "$RUN"; mkdir -p "$RUN"

# ---------------------------------------------------------------------------------
step "1/5  the tables are what the generator says they are"
# audio_fe_tables.c is generated, and a hand edit to it would silently change every
# measurement below AND the features the model was trained on. Re-derive and diff.
run python3 "$IISWC_ROOT/fpga/pynq-z2/sw/tools/gen_fe_tables.py" --check

# ---------------------------------------------------------------------------------
step "2/5  build the front end three ways"
IMAGES=""
for G in $GEOMS; do for V in $VARIANTS; do
  ID="$G-$V"; IMAGES="$IMAGES $ID"
  D="$RUN/$ID"; mkdir -p "$D"
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$D/build" -- \
      -DBOARD_ROOT="$IISWC_ROOT" -DFE_ARITH="$V" -DFE_GEOM="$G" > "$D/build.log" 2>&1 \
    || { tail -30 "$D/build.log"; die "build failed for $ID -- see $D/build.log"; }
  need_file "$D/build/zephyr/zephyr.bin" "no image for $ID"
  cp "$D/build/zephyr/zephyr.elf" "$D/build/zephyr/zephyr.bin" "$D/"
  info "$ID: $(fsize "$D/zephyr.bin")"
done; done

# The ELF gate. This SoC is WithoutFPU, so a stray float in the INT or PEXT build is a
# measurement turned into one of __mulsf3 -- and it is INVISIBLE to an -march check,
# because soft-float calls are ordinary integer instructions. Grep for the symbols.
OBJDUMP=$(find "${ZEPHYR_SDK_INSTALL_DIR:-$ZCS/tools-manual}" -name 'riscv64-zephyr-elf-objdump' 2>/dev/null | head -1)
[ -n "$OBJDUMP" ] || die "no riscv64-zephyr-elf-objdump under the SDK"
for ID in $IMAGES; do
  V="${ID#*-}"
  D="$RUN/$ID"
  "$OBJDUMP" -d "$D/zephyr.elf" > "$D/dis.txt"
  python3 - "$D/dis.txt" "$ID" > "$D/elfgate.txt" <<'PY'
import re, sys
dis, v = sys.argv[1], sys.argv[2]
t = open(dis).read()
words = re.findall(r'^\s+[0-9a-f]+:\s+([0-9a-f]{8})\s', t, re.M)
c0 = [int(w, 16) for w in words if (int(w, 16) & 0x7f) == 0x0b]
f3 = {}
for w in c0:
    f3[(w >> 12) & 7] = f3.get((w >> 12) & 7, 0) + 1
sf = sorted(set(re.findall(r'<(__(?:add|sub|mul|div|eq|ne|lt|le|gt|ge|unord|float|fix|trunc|extend)[a-z0-9]*(?:sf|df)[0-9a-z]*)>', t)))
mul = len(re.findall(r'\t(?:mul|mulw|mulh|mulhu|mulhsu)\s', t))
print("variant=%s custom0=%d funct3=%s mulfam=%d softfloat=%s" %
      (v, len(c0), f3, mul, ",".join(sf) if sf else "none"))
PY
  cat "$D/elfgate.txt" | sed 's/^/    /'
  G=$(cat "$D/elfgate.txt")
  case "$V" in
    float) echo "$G" | grep -q 'softfloat=none' && die "the float build has NO soft-float calls -- it did not compile as float" ;;
    int)   echo "$G" | grep -q 'softfloat=none' || die "the int build calls libgcc soft-float: $G"
           echo "$G" | grep -q 'custom0=0' || die "the int build emitted MBP encodings: $G" ;;
    pext)  echo "$G" | grep -q 'softfloat=none' || die "the pext build calls libgcc soft-float: $G"
           echo "$G" | grep -q 'custom0=0 ' && die "the pext build emitted NO MBP encodings -- it fell back to the software model" ;;
  esac
done
[ "$BUILD_ONLY" -eq 1 ] && { info "--build-only: stopping before the board"; exit 0; }

# ---------------------------------------------------------------------------------
step "3/5  load the microphone PL"
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run "${SSH[@]}" "mkdir -p $PYNQ_DIR"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket_mic.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/console.py" "$PYNQ_HOST:$PYNQ_DIR/"
if [ "$LOAD_BIT" -eq 1 ]; then
  need_file "$BIT" "build it with fpga/pynq-z2/scripts/build_mic_z1.sh"
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
# The mic bitstream is the P-ext bitstream plus one peripheral, so an image built for
# either boots on the other and says nothing. The MAGIC is the only thing that does.
grep -q 'MAGIC = 0x5A5A0005' "$RUN/boot.log" || {
  M=$(grep -oE 'MAGIC = 0x5A5A000[0-9]' "$RUN/boot.log" | head -1 || true)
  cat "$RUN/boot.log"
  die "wrong bitstream: $M (want 0x5A5A0005, the mic+P-ext one). Re-run without --no-bitstream."
}
grep -E 'FCLK0' "$RUN/boot.log" | sed 's/^/    /' || true

# ---------------------------------------------------------------------------------
step "4/5  run all $(echo $IMAGES | wc -w) images, one after another, on this silicon"
for ID in $IMAGES; do
  D="$RUN/$ID"
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
  if grep -q 'AUDIO_FE_BENCH done' "$D/console.txt" 2>/dev/null; then
    info "$ID ran"
    grep -E 'FE_FRAME |FE_RTF|FE_SELFTEST arith' "$D/console.txt" | sed 's/^/    /'
  else
    warn "$ID did not finish -- see $D/console.txt"
  fi
done

# ---------------------------------------------------------------------------------
step "5/5  compare"
python3 - "$RUN" "$BOARD" "$IMAGES" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run, board, images = sys.argv[1], sys.argv[2], sys.argv[3].split()
geoms, variants = [], []
for i in images:
    g, v = i.split("-", 1)
    if g not in geoms:
        geoms.append(g)
    if v not in variants:
        variants.append(v)
out = {"board": board, "images": images}
per = {}
for i in images:
    p = os.path.join(run, i, "console.txt")
    t = open(p).read() if os.path.exists(p) else ""
    d = {"ran": "AUDIO_FE_BENCH done" in t}
    m = re.search(r'AUDIO_FE_BENCH done arith=(\w+) fails=(\d+)', t)
    if m:
        d["selftest_fails"] = int(m.group(2))
    m = re.search(r'FE_FRAME arith=\w+ stages_sum=(\d+) whole=(\d+)', t)
    if m:
        d["stage_sum_cycles"] = int(m.group(1))
        d["frame_cycles"] = int(m.group(2))
    m = re.search(r'FE_RTF arith=\w+ cycles_per_frame=(\d+) frames_per_s=(\d+) '
                  r'cycles_per_s_of_audio=(\d+) clock_hz=(\d+)', t)
    if m:
        d["frames_per_s"] = int(m.group(2))
        d["cycles_per_s_of_audio"] = int(m.group(3))
        d["clock_hz"] = int(m.group(4))
        d["frontend_rtf_x1000"] = round(1000 * int(m.group(3)) / int(m.group(4)))
    d["stages"] = {k: int(c) for k, c in
                   re.findall(r'^  (\w+)\s+(\d+) cycles/frame', t, re.M)}
    d["ops_x100"] = {k: int(c) for k, c in re.findall(
        r'^  (nop|add|mul|mulw|mul_small|qmul_sw|qmul_hw|dot8_hw|max8_hw)\s+(\d+)\s',
        t, re.M)}
    m = re.search(r'^FE_LOGMEL ((?:-?\d+ ?)+)$', t, re.M)
    d["logmel"] = [int(x) for x in m.group(1).split()] if m else []
    m = re.search(r'^FE_MFCC ((?:-?\d+ ?)+)$', t, re.M)
    d["mfcc"] = [int(x) for x in m.group(1).split()] if m else []
    per[i] = d
out["per_image"] = per

print("\n-- 1. what one operation costs (hart 0, dependent chain, 8x unrolled, cycles)")
ref = {}
for i in images:
    if per[i]["ops_x100"]:
        ref = per[i]["ops_x100"]
        if i.endswith("pext"):
            break
floor = ref.get("nop", 0)
for k in ("nop", "add", "mul", "mulw", "mul_small", "qmul_sw", "qmul_hw",
          "dot8_hw", "max8_hw"):
    if k in ref:
        print("   %-10s %6.2f   (%+.2f over the empty loop)" %
              (k, ref[k] / 100.0, (ref[k] - floor) / 100.0))
        out.setdefault("op_cycles_x100", {})[k] = ref[k]
if "mul" in ref and "qmul_hw" in ref:
    a, b = ref["mul"] - floor, ref["qmul_hw"] - floor
    out["mul_over_qmul_marginal_x100"] = round(100 * a / b)
    print("   -> a 64-bit `mul` costs %.2fx a single-cycle MBP.QMUL, marginally" % (a / b))

for g in geoms:
    print("\n== geometry %s ==" % g)
    ims = [i for i in images if i.startswith(g + "-")]
    vs = [i.split("-", 1)[1] for i in ims]
    print("\n-- 2. one frame, per stage (cycles)")
    stages = ["window", "cfft256", "split_real", "power", "melbank", "dct"]
    hdr = "   %-12s" % "stage" + "".join("%12s" % v for v in vs)
    print(hdr); print("   " + "-" * (len(hdr) - 3))
    for s in stages:
        print("   %-12s" % s + "".join("%12s" % per[i]["stages"].get(s, "-") for i in ims))
    print("   %-12s" % "WHOLE FRAME" + "".join(
        "%12s" % per[i].get("frame_cycles", "-") for i in ims))

    print("\n-- 3. the front end's own real-time factor")
    for i in ims:
        d = per[i]
        if "frontend_rtf_x1000" in d:
            print("   %-6s %8d cycles/frame x %3d frames/s = %11d cycles/s-of-audio"
                  "   RTF %6.3f  (%5.1f%% of one hart)"
                  % (i.split("-", 1)[1], d["frame_cycles"], d["frames_per_s"],
                     d["cycles_per_s_of_audio"], d["frontend_rtf_x1000"] / 1000.0,
                     d["frontend_rtf_x1000"] / 10.0))
            out.setdefault("rtf_x1000", {})[i] = d["frontend_rtf_x1000"]

    print("\n-- 4. do the builds compute the same features?")
    base = g + "-float" if (g + "-float") in per and per[g + "-float"]["logmel"] else ims[0]
    for i in ims:
        a, b = per[i]["logmel"], per[base]["logmel"]
        if not a or not b or len(a) != len(b):
            print("   %-6s no feature vector" % i); continue
        dmax = max(abs(x - y) for x, y in zip(a, b))
        am, bm = per[i]["mfcc"], per[base]["mfcc"]
        dm = max(abs(x - y) for x, y in zip(am, bm)) if am and bm and len(am) == len(bm) else -1
        print("   %-10s vs %-10s  max|dlogmel| %4d Q8 (%.4f log2)  max|dmfcc| %d Q8"
              % (i, base, dmax, dmax / 256.0, dm))
        out.setdefault("logmel_maxdiff", {})[i] = dmax
    ki, kp = g + "-int", g + "-pext"
    if ki in per and kp in per and per[ki]["logmel"] and per[kp]["logmel"]:
        same = (per[ki]["logmel"] == per[kp]["logmel"] and per[ki]["mfcc"] == per[kp]["mfcc"])
        out.setdefault("int_pext_bit_identical", {})[g] = bool(same)
        print("   int == pext, bit for bit: %s" % ("YES" if same else "NO"))
    kf = g + "-float"
    if kf in per and kp in per and per[kf].get("frame_cycles") and per[kp].get("frame_cycles"):
        r = round(100 * per[kf]["frame_cycles"] / per[kp]["frame_cycles"])
        out.setdefault("pext_over_float_x100", {})[g] = r
        print("   fixed point over float : %.2fx" % (r / 100.0))
    if ki in per and kp in per and per[ki].get("frame_cycles") and per[kp].get("frame_cycles"):
        r = round(100 * per[ki]["frame_cycles"] / per[kp]["frame_cycles"])
        out.setdefault("pext_over_int_x100", {})[g] = r
        print("   MBP.QMUL over `mul`    : %.2fx" % (r / 100.0))

out["all_selftests_pass"] = all(per[i].get("selftest_fails", 1) == 0 for i in images)
out["all_ran"] = all(per[i]["ran"] for i in images)
out["int_pext_bit_identical_everywhere"] = all(
    out.get("int_pext_bit_identical", {}).values()) and bool(out.get("int_pext_bit_identical"))
out["max_logmel_diff_vs_float"] = max(out.get("logmel_maxdiff", {0: 0}).values())
# Flatten the few fields expected/audio_fe_bench.json checks, so the checker stays a
# plain key-by-key compare rather than growing a path language.
for k in ("qmul_hw", "dot8_hw", "mul", "nop"):
    if k in out.get("op_cycles_x100", {}):
        out["%s_x100" % k] = out["op_cycles_x100"][k]
for g in ("asr", "kws"):
    if g in out.get("pext_over_float_x100", {}):
        out["pext_over_float_x100_%s" % g] = out["pext_over_float_x100"][g]
    if g in out.get("pext_over_int_x100", {}):
        out["pext_over_int_x100_%s" % g] = out["pext_over_int_x100"][g]
    for v in ("float", "int", "pext"):
        i = "%s-%s" % (g, v)
        if i in out.get("rtf_x1000", {}):
            out["rtf_%s_%s_x1000" % (g, v)] = out["rtf_x1000"][i]
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
    elif isinstance(want, list) and len(want) == 2 and all(isinstance(x, (int, float)) for x in want):
        ok = have is not None and want[0] <= have <= want[1]
        s = "in [%s, %s]" % tuple(want)
    else:
        ok = (have == want); s = repr(want)
    print("    %-5s %-34s expected %-24s got %s" % ("ok" if ok else "FAIL", k, s, have))
    bad += (not ok)
print("    %s" % ("PASS  reproduces the golden run" if not bad else "FAIL  %d field(s) differ" % bad))
sys.exit(1 if bad else 0)
PY
fi
