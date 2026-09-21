#!/usr/bin/env bash
# THE L2 MISS PATH (MEMORY_BANDWIDTH.md section 6).  Build one of the three bwl2 variants:
#
#   scripts/build_bwl2_z1.sh bwl2mshr        (a) 12 MSHRs              MAGIC 0x5A5A000B
#   scripts/build_bwl2_z1.sh bwl2cap         (a) 256 KB L2             MAGIC 0x5A5A000C
#   scripts/build_bwl2_z1.sh bwl2cork        ReleaseAck-first cork     MAGIC 0x5A5A000E
#   scripts/build_bwl2_z1.sh bwl2skip        skip clean Release        MAGIC 0x5A5A001A
#   ROCKET_FCLK_MEM_MHZ=40 ROCKET_BUILD_TAG=f40 \
#   scripts/build_bwl2_z1.sh bwl2fast        (b) the L2 on FCLK1       MAGIC 0x5A5A000D
#
#   a second argument `synth` stops after synthesis.
#
# Everything is build_bwfast_z1.sh's -- the same simulation gates, the same RGB pin gate,
# the same report_cdc gate -- plus one thing the earlier builds did not need: a PER-CLOCK
# timing verdict.  build_rocket.tcl writes a bitstream whatever the slack is, and (b) is
# a sweep whose whole point is to find where the L2's clock stops closing.  So this prints
# WNS for each clock domain and the failing path's endpoints, and ends with
# BWL2_TIMING_MET or BWL2_TIMING_FAILED.  A bitstream from a FAILED build is kept -- the
# failing path is a result -- but scripts/45_rocket_bwl2lab.sh refuses to measure it.
#
# Run it through the counting lock, and give each build its own log directory:
#   BUILD_LOG_DIR=/tmp/bwl2_f40 scripts/lib/with_lock.sh vivado \
#     env ROCKET_FCLK_MEM_MHZ=40 ROCKET_BUILD_TAG=f40 fpga/pynq-z2/scripts/build_bwl2_z1.sh bwl2fast
set -eo pipefail
cd "$(dirname "$0")/.."
export PYNQ_BOARD=z1
VARIANT="${1:?usage: build_bwl2_z1.sh <bwl2mshr|bwl2cap|bwl2fast> [synth]}"
STAGE="${2:-all}"
case "$VARIANT" in bwl2mshr|bwl2cap|bwl2cork|bwl2skip|bwl2wsf|bwl2wsmf|bwl2fast) ;; *) echo "unknown variant $VARIANT"; exit 2 ;; esac
TAG="${ROCKET_BUILD_TAG:-}"
LOG="${BUILD_LOG_DIR:-${TMPDIR:-/tmp}/build_${VARIANT}${TAG:+_$TAG}}"
mkdir -p "$LOG"
REPO="$(cd ../.. && pwd)"
export ROCKET_VARIANT="$VARIANT"

RGB_TABLE="rgb_led[0]:L15 rgb_led[1]:G17 rgb_led[2]:N15 rgb_led[3]:G14 rgb_led[4]:L14 rgb_led[5]:M15"

run_sim () {
  local name="$1" script="$2"
  echo "=== [$3] $name ==="
  "./sim/$script" "$LOG/${script%.sh}" > "$LOG/${script%.sh}.log" 2>&1 || {
    echo "FAILED: $name"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  grep -q "ALL CHECKS PASSED" "$LOG/${script%.sh}.log" || {
    echo "FAILED: $name did not report a pass"; tail -20 "$LOG/${script%.sh}.log"; exit 1; }
  echo "  $(grep -c '  pass  ' "$LOG/${script%.sh}.log") checks passed"
}

run_sim "GP0 register file (DRAM self-test)" run_ctrl_sim.sh     "0/5"
run_sim "GP0 register file (Rocket/SoC)"     run_soc_ctrl_sim.sh "0b/5"
run_sim "datapath integration"               run_dram_sim.sh     "0c/5"
run_sim "PDM microphone decimator"           run_pdm_sim.sh      "0d/5"

echo "=== [0e/5] the fill engine, against an out-of-order memory model ==="
VERILATOR="${VERILATOR:-$(command -v verilator || true)}"
if [ -z "$VERILATOR" ] && [ -n "${CHIPYARD_DIR:-}" ]; then
  VERILATOR="$CHIPYARD_DIR/.conda-env/bin/verilator"
fi
if [ ! -x "$VERILATOR" ]; then
  echo "  SKIPPED: no verilator found (set VERILATOR=...)"
else
  rm -rf "$LOG/vmbxd"
  "$VERILATOR" --binary -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --Mdir "$LOG/vmbxd" \
     --top-module tb_mbxd rtl_study/rocc/tb_mbxd.sv rtl_study/rocc/mbxd_dma.v \
     rtl_study/rocc/mbxd_st.v > "$LOG/tb_mbxd.log" 2>&1 || {
    echo "FAILED: could not build tb_mbxd"; tail -20 "$LOG/tb_mbxd.log"; exit 1; }
  "$LOG/vmbxd/Vtb_mbxd" > "$LOG/tb_mbxd.run" 2>&1 || true
  grep -q "MBXD_TB_OK" "$LOG/tb_mbxd.run" || {
    echo "FAILED: tb_mbxd did not pass"; tail -20 "$LOG/tb_mbxd.run"; exit 1; }
  sed -n 's/^/  /p' "$LOG/tb_mbxd.run" | grep -E "MBXD" || true
fi

# ---- THE CHIPTOP CONTRACT, checked before Vivado sees it.  pynqz2_rocket_top.v wires a
# 64-bit AXI4 memory port with 4-bit IDs into a 64-bit AXI3 shim and S_AXI_HP0.  Verilog
# connects a mismatched port width with a WARNING, and the first 0x5A5A0018 build proved what
# that costs: WithEdgeDataBits(128) had made axi4_mem_0 128-bit, the SoC issued 16-byte-beat
# bursts into a 64-bit HP port, and the board saw 0 console bytes (MEMORY_BANDWIDTH.md s6.9).
echo "=== [0g/5] ChipTop's memory-port contract ==="
# Every width on ChipTop.axi4_mem_* -> top-level wire -> axi4_to_axi3 -> S_AXI_HPn, for this
# variant's defines (scripts/check_mem_contract.py; tcl/build_rocket.tcl runs the same check
# again inside Vivado, so a build started some other way is refused too).  Checked here first
# so a mismatch costs seconds rather than a Vivado slot.
CFG=$(awk -v v="$VARIANT" '$1 == v && $2 == "{" {f=1} f && $1 == "set" && $2 == "cfg" {gsub(/"/, "", $3); print $3; exit}' tcl/build_rocket.tcl)
GS="${CHIPYARD_GENSRC:-${CHIPYARD_GENSRC_ROOT:-$REPO/out/gensrc}/chipyard.harness.TestHarness.$CFG}"
[ -f "$GS/gen-collateral/ChipTop.sv" ] || { echo "FAILED: no $GS/gen-collateral/ChipTop.sv -- scripts/08_gensrc.sh --unpack $CFG"; exit 1; }
if ! python3 scripts/check_mem_contract.py --variant "$VARIANT" --gensrc "$GS" | sed 's/^/  /'; then
  echo "FAILED: the memory-port contract (above) -- the top level would truncate or float a memory-port signal"; exit 1
fi

. ./scripts/require_vivado.sh

echo "=== [1/3] $VARIANT${TAG:+ ($TAG)}, FCLK1=${ROCKET_FCLK_MEM_MHZ:-default} ($STAGE) ==="
VLOG="$LOG/z1_rocket_${VARIANT}${TAG:+_$TAG}.log"
vivado -mode batch -nojournal -nolog -source tcl/build_rocket.tcl -tclargs "$STAGE" \
  2>&1 | tee "$VLOG" | tail -8

BUILD=build_rocket_micrgb_${VARIANT}${TAG:+_$TAG}_z1

if [ "$STAGE" = "synth" ]; then
  grep -q "SYNTH_ONLY_DONE" "$VLOG" || { echo "FAILED: synthesis"; grep -m3 "^ERROR" "$VLOG"; exit 1; }
  echo "SYNTH_DONE"; exit 0
fi
grep -q "BITSTREAM_OK" "$VLOG" || { echo "FAILED: build"; grep -m3 "^ERROR" "$VLOG"; exit 1; }
grep -E "PS7 FCLK[01]" "$VLOG" | sed 's/^/  /' || true

echo "=== [2/3] the six RGB pins, in the routed design ==="
IO_RPT="$BUILD/reports/post_route_io.rpt"
[ -f "$IO_RPT" ] || { echo "FAILED: $IO_RPT was not written"; exit 1; }
bad=0
for entry in $RGB_TABLE; do
  port="${entry%%:*}"; want="${entry##*:}"
  line=$(grep -F "RGB_PIN: $port -> " "$VLOG" | head -1 || true)
  [ -n "$line" ] || { echo "  FAIL  $port: no post-route RGB_PIN line"; bad=1; continue; }
  got=$(printf '%s\n' "$line" | awk '{print $4}')
  rpt=$(awk -v p="$port" 'index($0, p) { print }' "$IO_RPT" | head -1 || true)
  if ! printf '%s\n' "$rpt" | grep -qE "(^|[^A-Za-z0-9])$want([^A-Za-z0-9]|$)" || [ "$got" != "$want" ]; then
    echo "  FAIL  $port: routed $got, report '$rpt', want $want"; bad=1; continue
  fi
  echo "  ok    $port -> $want"
done
grep -q "RGB_PINS_VERIFIED_POST_ROUTE: 6" "$VLOG" || { echo "FAILED: RGB pins not verified post-route"; exit 1; }
[ "$bad" -eq 0 ] || { echo "FAILED: RGB pin mismatch"; exit 1; }

echo "=== [3/3] clock-domain crossings, and timing per clock ==="
CDC="$BUILD/reports/cdc.rpt"
if [ -f "$CDC" ]; then
  read -r unsafe unknown <<EOT
$(awk '/^(Critical|Warning|Info) +/ {u+=$(NF-2); k+=$(NF-1)} END {print u+0, k+0}' "$CDC")
EOT
  echo "  report_cdc: $unsafe unsafe endpoint(s), $unknown unknown"
  awk '/^(Critical|Warning|Info) +/ {print "    " $0}' "$CDC"
  if [ "${unsafe:-0}" -gt 0 ] || [ "${unknown:-0}" -gt 0 ]; then
    echo "FAILED: unsafe or unknown clock-domain crossings -- run report_cdc -details on $BUILD/post_route.dcp"
    exit 1
  fi
fi

TIM="$BUILD/reports/timing_summary.rpt"
met=1
awk '/^\| Intra Clock Table/ {t=1} t && /^clk_fpga_[0-9]/ {print} /^\| Inter Clock Table/ {t=0}' "$TIM" |
while read -r clk wns tns nfail rest; do
  echo "  $clk  WNS $wns ns  TNS $tns ns  failing endpoints $nfail"
done
worst=$(awk '/^\| Intra Clock Table/ {t=1} t && /^clk_fpga_[0-9]/ {print $2} /^\| Inter Clock Table/ {t=0}' "$TIM" | sort -g | head -1)
whs=$(awk '/^\| Intra Clock Table/ {t=1} t && /^clk_fpga_[0-9]/ {print $6} /^\| Inter Clock Table/ {t=0}' "$TIM" | sort -g | head -1)
echo "  worst intra-clock WNS $worst ns, WHS $whs ns"
# The worst setup path, whichever clock it is on: source, destination, levels, delay.
awk '/^Max Delay Paths/ {m=1} m && /Slack|Source:|Destination:|Path Group:|Data Path Delay|Logic Levels/ {print "    " $0; n++} n>=6 {exit}' "$TIM"
if awk -v w="$worst" -v h="$whs" 'BEGIN {exit !((w+0) < 0 || (h+0) < 0)}'; then
  echo "BWL2_TIMING_FAILED"
else
  echo "BWL2_TIMING_MET"
fi
echo "BWL2_BUILD_DONE $BUILD"
