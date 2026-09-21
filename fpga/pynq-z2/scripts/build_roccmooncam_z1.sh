#!/usr/bin/env bash
# Build 0x5A5A0010 plus the HM01B0 camera on the Z1 shield: the ospi capture core with its DMA
# master, a TLI2C, and the shield's 16 pins.  PYNQ-Z1, 34.4828 MHz.  MAGIC 0x5A5A001E.
# docs/CAMERA_Z1.md.
#
# build_roccmoon_z1.sh plus the camera and nothing else: same top level with PYNQZ2_CAM added,
# the same XDC files plus src/pynqz2_cam.xdc, and the engine RTL from the camera variant's own
# snapshot (src/cam_engine_rev1, checked against its MD5SUMS by build_rocket.tcl).
#
# THE GATES BEFORE VIVADO:
#   * the four PL simulations every Rocket build runs;
#   * the engine snapshot is byte-identical to MD5SUMS (the files 0x5A5A0010 was built from);
#   * scripts/65_cam_rtl_sim.sh: the camera, DMA and I2C in this config's own RTL in Verilator.
#     A passing log newer than the elaboration is accepted (CAM_RTL_SIM_LOG); otherwise it runs.
#
#   scripts/build_roccmooncam_z1.sh          full build, through to a bitstream
#   scripts/build_roccmooncam_z1.sh synth    stop after synthesis
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
STAGE="${1:-all}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"
CFG=PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig

RGB_TABLE="rgb_led[0]:L15 rgb_led[1]:G17 rgb_led[2]:N15 rgb_led[3]:G14 rgb_led[4]:L14 rgb_led[5]:M15"
CAM_TABLE="cam_d[0]:T14 cam_d[1]:U12 cam_d[2]:V13 cam_d[3]:V15 cam_d[4]:T15 cam_d[5]:R16 cam_d[6]:U17 cam_d[7]:V17 cam_pclk:U10 cam_fvld:W11 cam_lvld:V11 cam_int:T5 cam_mclk:V18 cam_trig:T16 cam_sda:P15 cam_scl:P16"

run_sim () {
  local name="$1" script="$2"
  echo "=== [$3] $name ==="
  "./sim/$script" "$LOG/${script%.sh}" > "$LOG/${script%.sh}.log" 2>&1 || {
    echo "FAILED: $name"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  grep -q "ALL CHECKS PASSED" "$LOG/${script%.sh}.log" || {
    echo "FAILED: $name did not report a pass"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  echo "  $(grep -c '  pass  ' "$LOG/${script%.sh}.log") checks passed"
}

run_sim "GP0 register file (DRAM self-test)" run_ctrl_sim.sh     "0/6"
run_sim "GP0 register file (Rocket/SoC)"     run_soc_ctrl_sim.sh "0b/6"
run_sim "datapath integration"               run_dram_sim.sh     "0c/6"
run_sim "PDM microphone decimator"           run_pdm_sim.sh      "0d/6"

echo "=== [0e/6] engine RTL snapshot (src/cam_engine_rev1) against MD5SUMS ==="
( cd src/cam_engine_rev1 && md5sum --strict -c MD5SUMS ) || { echo "FAILED: engine snapshot differs from MD5SUMS"; exit 1; }

echo "=== [0f/6] camera + DMA + I2C in this config's own RTL (scripts/65_cam_rtl_sim.sh) ==="
# The RTL the simulation ran must be the RTL Vivado is about to read.  A passing log is accepted
# when it is NEWER than the sources this build reads: the vendored bundle (the normal case, with
# CHIPYARD_DIR unset) or a live elaboration.
GSRC="${CHIPYARD_DIR:-/nonexistent}/sims/verilator/generated-src/chipyard.harness.TestHarness.$CFG"
BUNDLE="chipyard/gensrc/$CFG.tar.gz"
if [ -n "${CAM_RTL_SIM_LOG:-}" ] && grep -q "CAM_RTL_SIM: PASS" "$CAM_RTL_SIM_LOG" \
   && { { [ -d "$GSRC" ] && [ "$CAM_RTL_SIM_LOG" -nt "$GSRC/$(ls "$GSRC" | grep -m1 '\.top\.f$')" ]; } \
        || { [ ! -d "$GSRC" ] && [ -f "$BUNDLE" ] && [ "$CAM_RTL_SIM_LOG" -nt "$BUNDLE" ]; }; }; then
  echo "  accepted: $CAM_RTL_SIM_LOG (newer than the sources this build reads)"
elif [ -z "${CHIPYARD_DIR:-}" ]; then
  echo "FAILED: CHIPYARD_DIR is not set and no passing CAM_RTL_SIM_LOG newer than $BUNDLE was given"; exit 1
else
  "$REPO/scripts/65_cam_rtl_sim.sh" > "$LOG/cam_rtl_sim.log" 2>&1 || {
    echo "FAILED: cam_rtl_sim"; tail -30 "$LOG/cam_rtl_sim.log"; exit 1; }
  grep -q "CAM_RTL_SIM: PASS" "$LOG/cam_rtl_sim.log" || { echo "FAILED: cam_rtl_sim did not pass"; exit 1; }
fi

. ./scripts/require_vivado.sh

echo "=== [1/1] full-feature Rocket + RoCC engine + HM01B0 camera ($STAGE) ==="
vivado -mode batch -nojournal -nolog -source tcl/build_rocket_roccmooncam.tcl -tclargs "$STAGE" \
  2>&1 | tee "$LOG/z1_rocket_roccmooncam.log" | tail -8

BUILD=build_rocket_micrgb_roccmooncam_z1

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$LOG/z1_rocket_roccmooncam.log" || {
    echo "FAILED: synthesis"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmooncam.log"; exit 1; }
  grep -E "MIC_PIN|RGB_PIN_SYNTH|CAM_PIN_SYNTH|ENGINE_RTL_SNAPSHOT" "$LOG/z1_rocket_roccmooncam.log" || true
  echo "SYNTH_DONE"
  exit 0
fi

grep -q "BITSTREAM_OK" "$LOG/z1_rocket_roccmooncam.log" || {
  echo "FAILED: roccmooncam build"; grep -m3 "^ERROR" "$LOG/z1_rocket_roccmooncam.log"; exit 1; }

echo "=== [2/2] the RGB and camera pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }

bad=0
check_table () {
  local tag="$1"; shift
  for entry in "$@"; do
    port="${entry%%:*}"; want="${entry##*:}"
    line=$(grep -F "${tag}: $port -> " "$LOG/z1_rocket_roccmooncam.log" | head -1 || true)
    if [ -z "$line" ]; then
      echo "  FAIL  $port: build_rocket.tcl printed no post-route ${tag} line"; bad=1; continue
    fi
    got=$(printf '%s\n' "$line" | awk '{print $4}')
    # index, not a regex: port names contain [ and ]
    rpt=$(awk -v p="$port" 'index($0, "| " p " ") { print }' "$IO_RPT" | head -1 || true)
    if [ -z "$rpt" ] || ! printf '%s\n' "$rpt" | grep -qE "(^|[^A-Za-z0-9])$want([^A-Za-z0-9]|$)"; then
      echo "  FAIL  $port: $IO_RPT does not put it on $want"; bad=1; continue
    fi
    if [ "$got" != "$want" ]; then
      echo "  FAIL  $port: routed design says $got, this script's table says $want"; bad=1; continue
    fi
    echo "  ok    $port -> $want"
  done
}
check_table RGB_PIN $RGB_TABLE
check_table CAM_PIN $CAM_TABLE
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$LOG/z1_rocket_roccmooncam.log" || { echo "FAILED: RGB pins not verified post-route"; exit 1; }
grep -q "CAM_PINS_VERIFIED_POST_ROUTE: 16" "$LOG/z1_rocket_roccmooncam.log" || { echo "FAILED: camera pins not verified post-route"; exit 1; }
grep -q "CAM_PUDC_B_U13: unassigned" "$LOG/z1_rocket_roccmooncam.log" || { echo "FAILED: U13 (PUDC_B) check missing"; exit 1; }
# U13 must not appear with a signal name in report_io either
awk -F'|' '{p=$2; s=$3; gsub(/ /,"",p); gsub(/ /,"",s); if (p=="U13" && s!="") {print "U13 carries " s; exit 1}}' "$IO_RPT" \
  || { echo "FAILED: U13 (PUDC_B) carries a port in report_io"; exit 1; }
[ "$bad" -eq 0 ] || { echo "FAILED: pin mismatch"; exit 1; }
grep -E "^TIMING_(WNS|WHS|CLOCK)" "$LOG/z1_rocket_roccmooncam.log" || true
# TIMING_WNS is the worst slack over ALL clocks, and for this variant that is the camera's INPUT
# BUDGET against a 36 MHz cam_pclk -- the HM01B0 datasheet maximum, which this design cannot drive:
# its MCLK tops out at 17.241 MHz (MCLKDIV 0) and the 8-bit mode runs near 6 MHz.  Judge cam_pclk at
# the clock the hardware can produce (docs/CAMERA_Z1.md section 7.5); clk_fpga_0 is the SoC's own
# number and is reported per clock above.
echo "TIMING_NOTE: TIMING_WNS above is the worst over all clocks. For this variant a negative value"
echo "TIMING_NOTE: is the camera input budget at 36 MHz (cam_pclk), NOT the SoC clock. Read"
echo "TIMING_NOTE: TIMING_CLOCK: clk_fpga_0 for the SoC, and docs/CAMERA_Z1.md section 7.5 before"
echo "TIMING_NOTE: citing either number."
md5sum "$BUILD/pynqz1_rocket_micrgb_roccmooncam.bit"

echo "ROCCMOONCAM_BUILD_DONE"
