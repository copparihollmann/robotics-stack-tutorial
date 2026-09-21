#!/usr/bin/env bash
# OLED on the TLI2C, in RTL simulation -- before any bitstream.
#
#   scripts/55_oled_rtl_sim.sh --tli2c [--gensrc DIR] [--mmio-cycles N]
#   scripts/55_oled_rtl_sim.sh --soc   (the full TestHarness; needs the camera config -- see below)
#
# --tli2c  The generated TLI2C alone, verilated from a COPY of a Chipyard elaboration's
#          gen-collateral (default: $CHIPYARD_DIR's PynqZ2RocketTacitCamConfig, whose TLI2C
#          comes from the same rocket-chip-blocks generator the camera build uses), driven by
#          Zephyr's UNMODIFIED drivers/i2c/i2c_sifive.c compiled against host stubs, into the
#          bit-level target sim/i2c_target.c and the SSD1306 model. Settles
#          fpga/pynq-z2/docs/OLED_SSD1306.md predictions P1 (SCL timing) and P2 (what
#          i2c_burst_write puts on the wire), and runs the no-ACK, clock-stretch and
#          wedged-SCL cases. The full screen is replayed twice at each speed: shaped as
#          ssd1306.c sends it (i2c_burst_write: control byte and payload as two messages)
#          and as one message per transfer; each framebuffer is hashed against the host
#          golden (expected/oled_status.json, scripts/54 must have run).
#
# Writes nothing into the Chipyard tree: RTL is copied into out/oled_rtl_tli2c/rtl with
# its sha256s, and the simulator is built there. No chipyard lock is needed.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

MODE=""; GENSRC=""; MMIO=8; DRIVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tli2c) MODE=tli2c; shift ;;
    --soc) MODE=soc; shift ;;
    --gensrc) GENSRC="${2:?}"; shift 2 ;;
    --mmio-cycles) MMIO="${2:?}"; shift 2 ;;
    --driver) DRIVER="${2:?}"; shift 2 ;;   # test a CANDIDATE driver instead of the tree's
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$MODE" ] || die "say --tli2c or --soc"
S="$IISWC_ROOT/samples/oled_status"
EXP="$IISWC_ROOT/expected/oled_status.json"
GOLDEN_PGM="$IISWC_OUT/oled_host/status.pgm"

if [ "$MODE" = soc ]; then
  # The Zephyr sample on 0x5A5A001E's own TestHarness, with this SSD1306 model beside the
  # camera's sensor model. Everything runs from a COPY of the elaboration: the copy's .f
  # lists are rewritten to point into it, TestHarness.sv is patched there, and the Chipyard
  # tree is only read.
  [ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set (the TestHarness is not vendored)"
  CONFIG="${CAM_CONFIG:-PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig}"
  G="$CHIPYARD_DIR/sims/verilator/generated-src/chipyard.harness.TestHarness.$CONFIG"
  [ -f "$G/sim_files.common.f" ] || die "no elaboration of $CONFIG in $CHIPYARD_DIR"
  [ -f "$GOLDEN_PGM" ] || die "no host golden at $GOLDEN_PGM -- run scripts/54_oled_host_tests.sh"
  R="$IISWC_ROOT/fpga/pynq-z2"
  OUT="$IISWC_OUT/oled_soc_sim"; rm -rf "$OUT/run"; mkdir -p "$OUT/run"
  VERILATOR_ENV=("$CHIPYARD_DIR/env.sh")

  if [ ! -x "$OUT/simulator" ] || [ "${REBUILD:-0}" = 1 ]; then
    step "1/6  copy the elaboration ($CONFIG) and patch the harness in the copy"
    rm -rf "$OUT/gensrc" "$OUT/obj"; mkdir -p "$OUT/gensrc"
    run cp -a "$G/." "$OUT/gensrc/"
    # the .f lists carry absolute paths into the shared tree; point them at the copy
    grep -rl "$G" "$OUT/gensrc" --include='*.f' | while read -r f; do
      sed -i "s|$G|$OUT/gensrc|g" "$f"
    done
    python3 - "$OUT/gensrc/gen-collateral/TestHarness.sv" <<'PY' || die "could not patch the harness copy"
import re, sys
p = sys.argv[1]
s = open(p).read()
if "oled_i2c_target" in s:
    sys.exit(0)
decl = """  wire        _oled_scl_low;
  wire        _oled_sda_low;
  wire        _oled_scl_line = _m_scl_in & ~_oled_scl_low;
  wire        _oled_sda_line = _m_sda_in & ~_oled_sda_low;
"""
anchor = "  wire        _chiptop0_i2c_0_scl_out;"
assert anchor in s, "i2c wire declarations not found"
s = s.replace(anchor, decl + anchor, 1)
s = s.replace(".i2c_0_scl_in                  (_m_scl_in),", ".i2c_0_scl_in                  (_oled_scl_line),", 1)
s = s.replace(".i2c_0_sda_in                  (_m_sda_in),", ".i2c_0_sda_in                  (_oled_sda_line),", 1)
inst = """  oled_i2c_target #(
    .ADDR7(7'h3c)
  ) u_oled_target (
    .clock   (_source_clk),
    .reset   (reset),
    .scl     (_oled_scl_line),
    .sda     (_oled_sda_line),
    .scl_low (_oled_scl_low),
    .sda_low (_oled_sda_low)
  );
"""
i = s.rindex("endmodule")
s = s[:i] + inst + s[i:]
open(p, "w").write(s)
print("    TestHarness.sv patched in the copy: oled_i2c_target on the I2C lines, SoC clock")
PY

    step "2/6  verilate the SoC from the copy"
    EXTRA="$R/src/cam_engine_rev1/mbxr_engine.v $R/src/cam_engine_rev1/mbxr_tseq.v $R/src/cam_engine_rev1/mbxr_datapath.v $R/src/cam_engine_rev1/mbxr_st.v $R/src/cam_engine_rev1/mbxd_dma.v $R/src/cam_engine_rev1/mbxd_spad.v $R/src/cam_engine_rev1/mbx_mac.v $R/src/pdm_mic_core.v $R/src/pdm_mic_capture.v $R/src/pdm_cic4.v $R/src/pdm_fir_mac.v $R/src/pdm_dcblock.v $R/src/pdm_mic_fifo.v $R/sim/hm01b0_sim_model.v $S/sim/soc/oled_i2c_target.sv $S/sim/soc/oled_dpi.cpp"
    mkdir -p "$OUT/obj"
    for f in "$S/sim/i2c_target.c" "$S/model/ssd1306_model.c"; do
      gcc -std=gnu11 -O2 -Wall -I"$S/sim" -I"$S/model" -c "$f" -o "$OUT/obj/$(basename "${f%.c}").o" \
        || die "gcc failed on $f"
    done
    ar rcs "$OUT/obj/liboledmodel.a" "$OUT"/obj/i2c_target.o "$OUT"/obj/ssd1306_model.o
    ( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1
      make -n -C sims/verilator CONFIG="$CONFIG" EXTRA_SIM_PREPROC_DEFINES="+define+MBXR_BEHAVIOURAL" \
           EXTRA_SIM_SOURCES="__EXTRA__" 2>/dev/null | grep -m1 -E "^verilator --main" || true ) > "$OUT/vcmd.txt"
    [ -s "$OUT/vcmd.txt" ] || die "could not recover the verilator command"
    sed -i -e "s|$G|$OUT/gensrc|g" \
           -e "s|__EXTRA__|$EXTRA +incdir+$R/src|" \
           -e "s|-CFLAGS \" |-CFLAGS \" -I$S/sim -I$S/model |" \
           -e "s|-LDFLAGS \" |-LDFLAGS \" $OUT/obj/liboledmodel.a |" \
           -e "s|-o [^ ]*simulator[^ ]*|-o $OUT/simulator|" \
           -e "s|-Mdir [^ ]*|-Mdir $OUT/obj|" "$OUT/vcmd.txt"
    ( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1; cd "$OUT"
      bash -c "$(cat "$OUT/vcmd.txt")" > "$OUT/verilate.log" 2>&1 &&
      make -C "$OUT/obj" -f VTestDriver.mk -j"${JOBS:-16}" > "$OUT/make.log" 2>&1 ) \
      || { tail -30 "$OUT/verilate.log" "$OUT/make.log" 2>/dev/null; die "simulator build failed (see $OUT)"; }
  else
    info "reusing $OUT/simulator (REBUILD=1 to rebuild)"
  fi

  # CONFIG_OLED_STATUS_PERIOD_MS is 1 ms here, not the board's 1 s: the rate limit is guest
  # time, and a second of guest time is 500 M simulated cycles.
  step "3/6  build the guest (chipyard_pynqz1_cam, golden screen, HTIF console)"
  run west build -p always -b chipyard_pynqz1_cam "$S" -d "$OUT/build" -- \
    -DBOARD_ROOT="$IISWC_ROOT" \
    -DEXTRA_DTC_OVERLAY_FILE="$S/oled.overlay;$S/sim/soc/htif_console.overlay" \
    -DCONFIG_OLED_DEMO_GOLDEN=y -DCONFIG_UART_HTIF=y \
    -DCONFIG_OLED_STATUS_PERIOD_MS="${SIM_PERIOD_MS:-1}" \
    > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; die "guest build failed"; }
  need_file "$OUT/build/zephyr/zephyr.elf" "no guest ELF"
  grep -q 'One address phase per TRANSFER' "$ZEPHYR_BASE/drivers/i2c/i2c_sifive.c" \
    || warn "patches/0120 is NOT applied: this run will show the repeated-START failure"

  # DRAMSim2 is off by default here (SIM_DRAMSIM=1 turns it on): this test is about the I2C
  # bus, and the simple memory model runs several times faster.
  # `[ ... ] && VAR=...` would exit the script under set -e when the test is false.
  DRAMSIM=""
  if [ "${SIM_DRAMSIM:-0}" = 1 ]; then
    DRAMSIM="+dramsim +dramsim_ini_dir=$CHIPYARD_DIR/generators/testchipip/src/main/resources/dramsim2_ini"
  fi
  step "4/6  run the Zephyr sample on the TestHarness"
  ( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1; cd "$OUT/run"
    OLED_SIM_OUT="$OUT/run" timeout "${SIM_TIMEOUT:-5400}" "$OUT/simulator" +permissive $DRAMSIM \
      +max-cycles="${MAX_CYCLES:-120000000}" +permissive-off "$OUT/build/zephyr/zephyr.elf" </dev/null ) \
    2>&1 | tee "$OUT/run/sim.log"

  step "5/6  the same image with nothing at 0x3c (module not fitted)"
  ( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1; cd "$OUT/run"
    mkdir -p "$OUT/run/absent"
    OLED_SIM_OUT="$OUT/run/absent" OLED_SIM_PRESENT=0 timeout "${SIM_TIMEOUT:-5400}" "$OUT/simulator" \
      +permissive $DRAMSIM \
      +max-cycles="${MAX_CYCLES_ABSENT:-40000000}" +permissive-off "$OUT/build/zephyr/zephyr.elf" </dev/null ) \
    2>&1 | tee "$OUT/run/sim_absent.log" | grep -E '^(oled|OLED_)' || true

  step "6/6  compare with the host golden"
  python3 - "$OUT/run" "$EXP" <<'PY' | tee "$OUT/run/verdicts.txt"
import hashlib, json, os, re, sys
run, exp = sys.argv[1], json.load(open(sys.argv[2]))
log = open(os.path.join(run, "sim.log"), errors="replace").read()
ok = True
for line in re.findall(r"^(oled:.*|OLED_[A-Z]+:.*)$", log, re.M):
    print("   " + line)
pgm = os.path.join(run, "oled_soc.pgm")
if not os.path.exists(pgm):
    print("FAIL: the model wrote no framebuffer"); sys.exit(1)
h = hashlib.sha256(open(pgm, "rb").read()).hexdigest()
golden = exp["pgm_sha256"]
which = [k for k, v in golden.items() if v == h]
print("   framebuffer sha256 %s -> %s" % (h, which[0] if which else "NO MATCH"))
ok &= bool(which)
st = json.load(open(os.path.join(run, "oled_soc_stats.json")))
print("   model: %(data_bytes)s data bytes, %(cmd_bytes)s command bytes, %(starts)s starts, "
      "%(restarts)s repeated starts, display_on=%(display_on)s, charge_pump=%(charge_pump)s" % st)
print("   SCL in-byte period: %s" % st["period_in_byte"])
print("   last full frame on the wire: %s SoC cycles" % st["last_frame_cycles"])
ok &= st["restarts"] == 0 and st["bad_ctrl"] == 0 and st["display_on"] == 1
m = re.search(r"OLED_GOLDEN: status screen drawn=\d+ render_cycles=(\d+) xfer_cycles=(\d+)", log)
if m:
    print("   hart 0 cost of that refresh: render %s cycles, I2C transfer %s cycles" % (m.group(1), m.group(2)))
ok &= bool(m)
alog = os.path.join(run, "sim_absent.log")
if os.path.exists(alog):
    a = open(alog, errors="replace").read()
    absent_ok = ("not fitted" in a) and ("OLED_DEMO: done" in a)
    st2 = json.load(open(os.path.join(run, "absent", "oled_soc_stats.json")))
    print("   not-fitted run: reported not fitted %s, guest finished %s, probes NACKed %s, bus bytes after %s"
          % ("not fitted" in a, "OLED_DEMO: done" in a, st2["addr_nack"], st2["data_bytes"]))
    ok &= absent_ok and st2["data_bytes"] == 0
print("   VERDICT: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
  info "outputs: $OUT/run (sim.log, oled_soc.pgm, oled_soc_wire.txt, oled_soc_stats.json)"
  exit 0
fi

[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set (Verilator and the default gensrc come from it)"
VERILATOR="$CHIPYARD_DIR/.conda-env/bin/verilator"
[ -x "$VERILATOR" ] || die "no verilator at $VERILATOR"
[ -n "$GENSRC" ] || GENSRC="$CHIPYARD_DIR/sims/verilator/generated-src/chipyard.harness.TestHarness.PynqZ2RocketTacitCamConfig/gen-collateral"
[ -f "$GENSRC/TLI2C.sv" ] || die "no TLI2C.sv in $GENSRC"
[ -f "$GOLDEN_PGM" ] || die "no host golden image at $GOLDEN_PGM -- run scripts/54_oled_host_tests.sh first"
python3 - "$GOLDEN_PGM" "$EXP" <<'PY' || die "out/oled_host/status.pgm does not match the committed golden -- rerun scripts/54"
import hashlib, json, sys
h = hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest()
sys.exit(0 if h == json.load(open(sys.argv[2]))["pgm_sha256"]["status"] else 1)
PY

OUT="$IISWC_OUT/oled_rtl_tli2c"
rm -rf "$OUT"; mkdir -p "$OUT/rtl" "$OUT/obj" "$OUT/run"

step "1/4  copy the TLI2C and what it instantiates  ($GENSRC)"
python3 - "$GENSRC" "$OUT/rtl" <<'PY'
import os, re, shutil, sys, hashlib
src, dst = sys.argv[1], sys.argv[2]
mods = {}
for f in os.listdir(src):
    if f.endswith((".sv", ".v")):
        for m in re.findall(r"^\s*module\s+(\w+)", open(os.path.join(src, f), errors="replace").read(), re.M):
            mods.setdefault(m, f)
todo, done = ["TLI2C"], set()
while todo:
    m = todo.pop()
    if m in done or m not in mods:
        continue
    done.add(m)
    text = open(os.path.join(src, mods[m]), errors="replace").read()
    for cand in set(re.findall(r"^\s*(\w+)\s*(?:#\s*\([^;]*?\))?\s+\w+\s*\(", text, re.M)):
        if cand in mods and cand not in done and cand != m:
            todo.append(cand)
with open(os.path.join(dst, "SHA256SUMS"), "w") as sums:
    for f in sorted({mods[m] for m in done}):
        shutil.copy(os.path.join(src, f), os.path.join(dst, f))
        sums.write(f"{hashlib.sha256(open(os.path.join(src, f),'rb').read()).hexdigest()}  {f}\n")
print("   ", " ".join(sorted({mods[m] for m in done})))
PY
[ -n "$DRIVER" ] || DRIVER="$ZEPHYR_BASE/drivers/i2c/i2c_sifive.c"
cp "$DRIVER" "$OUT/obj/i2c_sifive_under_test.c"
DRV_MD5=$(md5sum "$OUT/obj/i2c_sifive_under_test.c" | cut -d' ' -f1)
info "driver under test: $DRIVER md5 $DRV_MD5"
git -C "$ZEPHYR_BASE" diff --quiet -- drivers/i2c/i2c_sifive.c || warn "i2c_sifive.c has local edits in the Zephyr tree"

# init bursts, from the host golden: "S 78+ 00+ AE+ P" -> "00 AE"; the first line is the probe
python3 - "$EXP" > "$OUT/run/init_bursts.txt" <<'PY'
import json, sys
lines = json.load(open(sys.argv[1]))["init_wire"][1:]
for l in lines:
    toks = [t.rstrip("+-") for t in l.split() if t not in ("S", "Sr", "P")]
    print(" ".join(toks[1:]))
PY

step "2/4  compile the driver and the target model (C), then verilate"
# The driver is C and must be compiled as C: Verilator hands .c files to the C++ compiler.
for c in "$OUT/obj/i2c_sifive_under_test.c:$S/sim/tli2c/sifive_glue.c" "$S/sim/i2c_target.c" "$S/model/ssd1306_model.c"; do
  f="${c##*:}"
  gcc -std=gnu11 -O2 -Wall -Wno-unused-function -I"$S/sim" -I"$S/model" -I"$S/sim/tli2c/stubs" -I"$OUT/obj" \
      -c "$f" -o "$OUT/obj/$(basename "${f%.c}").o" >> "$OUT/cc.log" 2>&1 || { cat "$OUT/cc.log"; die "gcc failed on $f"; }
done
ar rcs "$OUT/obj/libglue.a" "$OUT"/obj/*.o
( cd "$OUT/obj" && "$VERILATOR" --cc --exe --build -j "${JOBS:-8}" -O3 --top-module TLI2C \
    -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT \
    +define+PRINTF_COND=1 +define+STOP_COND=1 +define+ASSERT_VERBOSE_COND=1 \
    -CFLAGS "-O2 -I$S/sim -I$S/model" -LDFLAGS "$OUT/obj/libglue.a" \
    "$OUT"/rtl/*.sv $(ls "$OUT"/rtl/*.v 2>/dev/null) "$S/sim/tli2c/tb_tli2c.cpp" \
    -o tb_tli2c ) > "$OUT/verilate.log" 2>&1 || { tail -30 "$OUT/verilate.log"; die "verilator build failed"; }

step "3/4  run"
( cd "$OUT/run" && time "$OUT/obj/obj_dir/tb_tli2c" --out "$OUT/run" --init-bursts "$OUT/run/init_bursts.txt" \
    --golden-pgm "$GOLDEN_PGM" --mmio-cycles "$MMIO" ) 2>&1 | tee "$OUT/run/sim.log"
[ -f "$OUT/run/results.json" ] || die "no results.json"

step "4/4  compare against the committed predictions and the host golden"
python3 - "$OUT/run" "$EXP" "$DRV_MD5" <<'PY' | tee "$OUT/run/verdicts.txt"
import hashlib, json, sys, os
run, exp, drv = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3]
r = json.load(open(os.path.join(run, "results.json")))
golden = exp["pgm_sha256"]["status"]
F = 34482761.0
def h(p): return hashlib.sha256(open(os.path.join(run, p + ".pgm"), "rb").read()).hexdigest()
print(f"driver md5 {drv}; mmio_extra_cycles {r['mmio_extra_cycles']}")
# P1 -- prediction committed in ac98a90: 306/136/170 at 100k, 80/34/46 at 400k, exact
pred = {"100k": (67, 306, 136, 170), "400k": (16, 80, 34, 46), "345k": (67, 306, 136, 170)}  # 345k: i2c_map_dt_bitrate quantises anything but 400000 to Standard mode
for spd, (p, per, hi, lo) in pred.items():
    for shape in ("single", "burst"):
        if f"{shape}_{spd}_period_in_byte" not in r:
            continue
        ph = f"{shape}_{spd}"
        pb, hb, lb = r[ph + "_period_in_byte"], r[ph + "_high_in_byte"], r[ph + "_low_in_byte"]
        # the prediction allowed +-1 cycle on the period; t_HIGH and t_LOW are exact
        ok = abs(pb["min"] - per) <= 1 and abs(pb["max"] - per) <= 1 and abs(pb["mean"] - per) <= 1
        print(f"P1 {ph:12s} prescale {p}: period {pb['min']}..{pb['max']} (pred {per}, OpenCores {5*(p+1)})"
              f"  t_HIGH {hb['min']}..{hb['max']} (pred {hi})  t_LOW {lb['min']}..{lb['max']} (pred {lo})"
              f"  -> {F/pb['mean']/1000:.2f} kHz mean  [{'CONFIRMED (+-1 cycle)' if ok else 'NOT AS PREDICTED'}]")
# P2 and the framebuffer against the golden
for spd in ("100k", "400k", "345k"):
    if f"single_{spd}" not in r:
        continue
    s = r[f"single_{spd}"]
    b = r.get(f"burst_{spd}")
    if b is None:
        print(f"   single_{spd}: starts {s['starts']} restarts {s['restarts']} data {s['data_bytes']} rc_sum {s['rc_sum']}"
              f"  image {'== golden' if h('single_'+spd) == golden else '!= golden'}"
              f"  frame {r[f'single_{spd}_frame_cycles']} cycles = {r[f'single_{spd}_frame_cycles']/F*1000:.1f} ms")
        continue
    print(f"P2 burst_{spd}: starts {b['starts']} restarts {b['restarts']} stops {b['stops']} bad_ctrl {b['bad_ctrl']} data {b['data_bytes']}"
          f" rc_sum {b['rc_sum']}  image {'== golden' if h('burst_'+spd) == golden else '!= golden'}")
    print(f"   single_{spd}: starts {s['starts']} restarts {s['restarts']} stops {s['stops']} bad_ctrl {s['bad_ctrl']} data {s['data_bytes']}"
          f" rc_sum {s['rc_sum']}  image {'== golden' if h('single_'+spd) == golden else '!= golden'}"
          f"  frame {r[f'single_{spd}_frame_cycles']} cycles = {r[f'single_{spd}_frame_cycles']/F*1000:.1f} ms")
first = open(os.path.join(run, "wire_burst_100k.txt")).read().splitlines()[:3]
print("   first transfers on the wire, burst_100k:", " | ".join(first))
n = r["nack"]; w = r["wedged_scl"]
print(f"NACK: rc {n['rc_nack']}, scl_oe after {n['scl_oe_after_nack']}, sda_oe after {n['sda_oe_after_nack']}, next write to 0x3c rc {n['rc_next_write_to_3c']}")
print("PRESCALE SWEEP (divider programmed directly; the driver offers only two values):")
for c in r.get("prescale_sweep", []):
    print(f"   prescale {c['prescale']:>4}: period {c['period_min']}..{c['period_max']} mean {c['period_mean']:.2f}"
          f"  (OpenCores 5*(p+1) = {c['opencores']}, early-reload model = {c['predicted']}, shortfall {c['opencores'] - c['period_mean']:.2f})")
print("STRETCH (100 kHz, SCL held low from the fall after bit 4 of the control byte of 00 E3 E3; 50 ms budget per call):")
for c in r["stretch_sweep"]:
    print(f"   hold {c['hold_cycles']:>6} cycles ({c['hold_cycles']/F*1e6:8.1f} us): returned {c['returned']} rc {c['rc']:>3} cmds '{c['cmds_decoded']}'"
          f" scl_oe {c['scl_oe_at_end']} tip {c['tip_at_end']} t_HIGH {c.get('high_min')}..{c.get('high_max')}"
          f" | reconfigure+write returned {c['reconfigure_then_write_returned']} recovered {c['recovered']}")
print(f"WEDGED SCL (held low 50 ms): driver returned {w['returned']} after {w['cycles']} cycles, {w['mmio_polls']} polls;"
      f" after release, reconfigure+write returned {w['after_release_reconfigure_write_returned']} rc {w['rc2']}")
PY
info "outputs: $OUT/run (results.json, *.pgm, wire_*.txt, verdicts.txt)"
