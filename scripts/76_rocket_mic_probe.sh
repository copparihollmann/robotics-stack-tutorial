#!/usr/bin/env bash
# Lab B110 -- IS THE PDM MICROPHONE ALIVE ON 0x5A5A0035?
#
#   ./scripts/76_rocket_mic_probe.sh --build-only
#   scripts/with_board.sh ./scripts/76_rocket_mic_probe.sh --prebuilt out/rocket_mic_probe_prebuilt
#
# WHY.  fpga/pynq-z2/docs/MICROPHONE.md is dated 2026-09-16 and predates 0x5A5A0035.  `mic`
# is in that build's MAGIC_FEATURES.tsv row and the RTL is pinned by md5, but NO ARM IN THIS
# TREE HAS READ THE PERIPHERAL ON THIS BITSTREAM.  The session goal is RTF and WER measured
# on the board running directly from audio data, so the microphone is on the critical path
# and this is the cheapest thing that can falsify it -- under a minute of board time.
#
# WHAT IT CHECKS, and why each one can fail.
#   ID    = 0x504D4331 and DEPTH = 1024.  An unmapped read on this pbus returns ZEROS, not a
#          fault, so "the read returned 0" and "there is no peripheral" are the same event.
#          These two are the discriminator: a hole cannot produce either value.
#   LEVEL advances after enable.  A register file can answer while the decimator is not
#          clocking; "it responds" is not "it works".
#   DATA   moves, with the DC blocker on AND off in the same run -- bypassed, the 0.5164 PDM
#          density is ~1074 counts of DC (MICROPHONE.md s3.5), so a near-zero mean is then a
#          measured property of the filter rather than of a stuck value.
#   THE RATE, counted against mtime over exactly IW = 64000 samples.
#
# THE RATE IS THE POINT.  RATE (0x28) is the Verilog parameter RATE_MHZ, a CONSTANT, and
# PynqZ2Configs.scala takes PdmMicParams' defaults -- 15993859 millihertz, computed for
# FCLK0 = 34.4828 MHz.  The hardware's rate is FCLK0/(2*7 * 22 * 7) = FCLK0/2156 and nothing
# else.  0x5A5A0035 runs at 40.000000 MHz, so PREDICTED 40e6/2156 = 18552.8757 Hz, +16.00 %
# on what the register reports, and 64,000 samples is 3.4496 s of audio and not 4.0016 s.
#
# NO RTL AND NO NEW BITSTREAM: the part is full (13,295 of 13,300 slices, five spare).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

NAME="rocket_mic_probe"
BOARD="chipyard_pynqz1_micrgb_f40"
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonnch8f40b98b_z1/pynqz1_rocket_micrgb_roccmoonnch8f40b98b.bit"
RUNNER="run_rocket_roccmoonnch8f40b98b.py"
SAMPLE="$IISWC_ROOT/samples/mic_probe"
WANT_MAGIC="0x5A5A0035"; FCLK_CORE=40; SECONDS_READ=120
# This lab dispatches to nothing.  It reads one peripheral, and `mic` is the feature that
# says that peripheral is in the build -- the whole of what it needs and the whole of what
# it may run on.  No codegen, so no kernel_picks.json: the declaration is the only half of
# the gate available to it.
LAB_REQUIRES="${LAB_REQUIRES:-mic}"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --board) BOARD="${2:?}"; shift 2 ;;
    --fclk) FCLK_CORE="${2:?}"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --prebuilt) PREBUILT="${2:?}"; shift 2 ;;
    # Re-score a console this lab already captured, with no board and no build.
    # The scorer is offline by construction; a bug in it must never cost a second hold.
    --score-only) SCORE_ONLY="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PYNQ_HOST")
RUN="$IISWC_OUT/$NAME"
[ -n "${BUILD_ONLY:-}" ] && RUN="$IISWC_OUT/${NAME}_prebuilt"
if [ -n "${SCORE_ONLY:-}" ]; then
  RUN="$SCORE_ONLY"; need_file "$RUN/console.txt" "nothing to score"
else
  rm -rf "$RUN"; mkdir -p "$RUN"
fi

# FCLK0 = 1000 MHz / N for an integer N on this PS7, and mtime ticks at FCLK0/1000 -- which
# is what CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC has to be, or the rate measured here is wrong
# by the same factor the console is garbled by.
GUEST_KHZ=$(python3 -c "
import sys
f=float('$FCLK_CORE')*1e6
n=round(1000e6/f)
hz=1000e6/n
print(int(round(hz/1000.0)))
")
CLK_HZ=$(python3 -c "
n=round(1000e6/(float('$FCLK_CORE')*1e6)); print(int(round(1000e6/n)))")
info "clock: FCLK0 $FCLK_CORE MHz = $CLK_HZ Hz; guest CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$GUEST_KHZ"
info "predicted PCM rate = $CLK_HZ / 2156 = $(python3 -c "print('%.4f' % ($CLK_HZ/2156.0))") Hz"

if [ -n "${SCORE_ONLY:-}" ]; then
  bitstream_identify "$BIT" >/dev/null
else
step "1/3  build the guest ($BOARD)"
if [ -n "${PREBUILT:-}" ]; then
  need_file "$PREBUILT/zephyr.bin" "no prebuilt image in $PREBUILT (run --build-only first)"
  cp "$PREBUILT/zephyr.bin" "$PREBUILT/zephyr.elf" "$RUN/"
  cp "$PREBUILT/build.log" "$RUN/build.log" 2>/dev/null || true
  cp "$PREBUILT/guest_khz.txt" "$RUN/guest_khz.txt" 2>/dev/null || true
  info "prebuilt image from $PREBUILT (built off the board lock)"
else
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build" -- -DBOARD_ROOT="$IISWC_ROOT" \
      > "$RUN/build.log" 2>&1 || { tail -30 "$RUN/build.log"; die "build failed"; }
  cp "$RUN/build/zephyr/zephyr.bin" "$RUN/build/zephyr/zephyr.elf" "$RUN/"
  sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$RUN/build/zephyr/.config" > "$RUN/guest_khz.txt"
fi
HZ=$(cat "$RUN/guest_khz.txt" 2>/dev/null || echo 0)
[ "$HZ" = "$GUEST_KHZ" ] || die "guest clock mismatch: board '$BOARD' built
       CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=$HZ, --fclk $FCLK_CORE needs $GUEST_KHZ.  That
       constant also sets the UART divisor, so a mismatch GARBLES THE CONSOLE rather than
       failing, and would make the mtime-based rate wrong by the same factor."
info "image: $(fsize "$RUN/zephyr.bin")   mtime: $HZ Hz"
if [ -n "${BUILD_ONLY:-}" ]; then
  info "built, no board touched.  Now:  scripts/with_board.sh $0 --prebuilt $RUN"
  exit 0
fi

step "2/3  load the PL and run"
need_file "$BIT" "no bitstream"
bitstream_identify "$BIT"; bitstream_gate
FEATURE_GATE_OUT="$RUN/feature_gate.json" feature_gate "" ""
"${SSH[@]}" true 2>/dev/null || die "cannot ssh to $PYNQ_HOST"
run scp -q "$IISWC_ROOT/fpga/pynq-z2/host/run_rocket.py" "$IISWC_ROOT/fpga/pynq-z2/host/$RUNNER" \
      "$IISWC_ROOT/fpga/pynq-z2/host/zynq_preflight.py" "$IISWC_ROOT/fpga/pynq-z2/host/console.py" \
      "$IISWC_ROOT/fpga/pynq-z2/host/fclk.py" "$RUN/zephyr.bin" "$BIT" "$PYNQ_HOST:$PYNQ_DIR/"
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S bash -lc '$PYNQ_ENV python3 -u $RUNNER --bitstream $(basename "$BIT") --fclk $FCLK_CORE --hold'" \
  > "$RUN/boot.log" 2>&1 || { cat "$RUN/boot.log"; die "could not load the PL"; }
grep -q "MAGIC = $WANT_MAGIC" "$RUN/boot.log" || { cat "$RUN/boot.log"; die "wrong bitstream: this lab needs $WANT_MAGIC"; }
"${SSH[@]}" "cd $PYNQ_DIR && echo xilinx | sudo -S python3 fclk.py --expect FCLK0=$FCLK_CORE" \
  > "$RUN/fclk.json" 2> "$RUN/fclk.err" || { cat "$RUN/fclk.json" "$RUN/fclk.err"; die "FCLK0 is not $FCLK_CORE MHz"; }
cat "$RUN/fclk.json"
"${SSH[@]}" "bash -lc '
  cd $PYNQ_DIR
  rm -f console.out
  nohup python3 -u console.py --seconds $SECONDS_READ --idle 90 > console.out 2>/dev/null &
  CPID=\$!
  sleep 1.5
  echo xilinx | sudo -S bash -lc \"$PYNQ_ENV python3 -u $RUNNER --no-load --elf zephyr.bin\" 2>&1 | grep -v sudo
  t=5
  while [ \$t -lt $SECONDS_READ ] && ! grep -q MP_DONE console.out; do sleep 5; t=\$((t+5)); done
  kill \$CPID 2>/dev/null; wait \$CPID 2>/dev/null
  echo waited=\$t bytes=\$(wc -c < console.out)
'" >> "$RUN/boot.log" 2>&1 || true
"${SSH[@]}" "cat $PYNQ_DIR/console.out" > "$RUN/console.txt" 2>/dev/null || true
[ -s "$RUN/console.txt" ] || { cat "$RUN/boot.log"; die "0 console bytes -- stop and report"; }
grep -q MP_DONE "$RUN/console.txt" || { tail -30 "$RUN/console.txt"; die "the probe did not finish"; }
grep -E "^MP_" "$RUN/console.txt" | sed 's/^/    /'
fi

step "3/3  the verdict"
export BIT_MD5 WANT_MAGIC LAB_REQUIRES LAB_FEATURES CLK_HZ
python3 - "$RUN" <<'PY' | tee "$RUN/report.txt"
import json, os, re, sys
run = sys.argv[1]
txt = open(os.path.join(run, "console.txt"), errors="replace").read()
clk = float(os.environ.get("CLK_HZ", "0") or 0)
pred = clk / 2156.0            # FCLK0 / (2*PDM_HALF * CIC_R * FIR_DECIM)
REG_NOMINAL = 15993.859

def g(pat, cast=str, grp=1):
    m = re.search(pat, txt)
    return cast(m.group(grp)) if m else None

out = {"lab": "B110 mic_probe", "bitstream_md5": os.environ.get("BIT_MD5"),
       "soc_magic": os.environ.get("WANT_MAGIC"), "clock_hz": clk,
       "requires": os.environ.get("LAB_REQUIRES"), "features": os.environ.get("LAB_FEATURES"),
       "board": os.environ.get("IISWC_BOARD")}
try:
    out["fclk"] = json.load(open(os.path.join(run, "fclk.json")))
except Exception:
    out["fclk"] = None

out["id"]        = g(r"MP_REGS id=0x([0-9a-f]+)", lambda s: int(s, 16))
out["depth"]     = g(r"MP_REGS .*depth=(\d+)", int)
out["rate_reg_millihz"] = g(r"rate_reg_millihz=(\d+)", int)
out["gate1"]     = "MP_GATE1 PASS" in txt
out["gate2"]     = "MP_GATE2 PASS" in txt
out["off_level"] = [g(r"MP_OFF .*level_a=(\d+)", int), g(r"MP_OFF .*level_b=(\d+)", int)]
out["off_status"]= g(r"MP_OFF status=0x([0-9a-f]+)", lambda s: int(s, 16))
out["settle_us"] = g(r"MP_SETTLE ticks=\d+ us=(\d+)", int)
out["levels"]    = [{"ticks": int(t), "level": int(l), "status": int(s, 16)}
                    for t, l, s in re.findall(r"MP_LEVEL step=\d+ ticks=(\d+) level=(\d+) status=0x([0-9a-f]+)", txt)]
out["stats"]     = {tag: {"n": int(n), "min": int(mn), "max": int(mx),
                          "mean": int(me) / 1000.0, "mean_abs": int(ma) / 1000.0,
                          "zeros": int(z), "distinct": int(d)}
                    for tag, n, mn, mx, me, ma, z, d in re.findall(
        r"MP_STATS (\S+) n=(\d+) min=(-?\d+) max=(-?\d+) mean_milli=(-?\d+) "
        r"meanabs_milli=(-?\d+) zeros=(\d+) distinct=(\d+)", txt)}
out["rates"]     = {tag: {"n": int(n), "ticks": int(tk), "elapsed_us": int(us),
                          "hz": int(r) / 1000.0}
                    for tag, n, _hz, tk, us, r in re.findall(
        r"MP_RATE (\S+) n=(\d+) mtime_hz=(\d+) ticks=(\d+) elapsed_us=(\d+) rate_millihz=(\d+)", txt)}
out["window_status_after"] = g(r"MP_WINDOW rc=-?\d+ status_after=0x([0-9a-f]+)", lambda s: int(s, 16))
out["verdict_line"] = g(r"MP_VERDICT (\S+)")
out["predicted_hz"] = pred

lvl_ok = len(out["levels"]) >= 2 and out["levels"][-1]["level"] > out["levels"][0]["level"] > 0
w = out["rates"].get("window")
ws = out["stats"].get("window")
out["level_advances"] = bool(lvl_ok)
out["responds"] = bool(out["gate1"])
out["produces_samples"] = bool(lvl_ok and ws and ws["distinct"] > 20 and ws["max"] > ws["min"])
if w:
    out["observed_hz"] = w["hz"]
    out["err_vs_predicted_pct"] = 100.0 * (w["hz"] - pred) / pred if pred else None
    out["err_vs_register_pct"] = 100.0 * (w["hz"] - REG_NOMINAL) / REG_NOMINAL
    out["seconds_per_64000"] = 64000.0 / w["hz"]
json.dump(out, open(os.path.join(run, "run.json"), "w"), indent=1)

print("   board %s   magic %s   md5 %s" % (out["board"], out["soc_magic"], out["bitstream_md5"]))
print("   ID    0x%08X   %s" % (out["id"] or 0, "= 'PMC1', the peripheral is MAPPED"
                                if out["id"] == 0x504D4331 else "NOT the PMC1 magic"))
print("   DEPTH %s        %s" % (out["depth"], "= 1024, not a value an unmapped read produces"
                                 if out["depth"] == 1024 else "NOT 1024 -- peripheral not mapped"))
print("   disabled: status 0x%02x, LEVEL %s -> %s" % (out["off_status"] or 0, *out["off_level"]))
print("   settling cleared after %s us" % out["settle_us"])
for i, l in enumerate(out["levels"]):
    print("   LEVEL step %d  t=%s ticks  level=%-5d status=0x%02x" % (i, l["ticks"], l["level"], l["status"]))
for tag in ("dc_bypass", "dc_on", "window"):
    s = out["stats"].get(tag)
    if s:
        print("   %-9s n=%-6d min=%-7d max=%-7d mean=%9.3f mean|x|=%8.3f zeros=%-5d distinct=%d"
              % (tag, s["n"], s["min"], s["max"], s["mean"], s["mean_abs"], s["zeros"], s["distinct"]))
if w:
    print("   RATE over %d samples: %.4f Hz in %.6f s" % (w["n"], w["hz"], w["elapsed_us"] / 1e6))
    print("        predicted FCLK0/2156 = %.4f Hz   ->  %+.4f %%" % (pred, out["err_vs_predicted_pct"]))
    print("        RATE register says     %.3f Hz   ->  %+.3f %%" % (REG_NOMINAL, out["err_vs_register_pct"]))
    print("        64,000 samples = %.4f s of audio" % out["seconds_per_64000"])
print("   RESPONDS %s   PRODUCES SAMPLES %s"
      % ("YES" if out["responds"] else "NO", "YES" if out["produces_samples"] else "NO"))
PY
info "run.json written to $RUN/run.json"
