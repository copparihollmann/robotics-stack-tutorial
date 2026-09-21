#!/usr/bin/env bash
# Prove the axiceil testbench catches the bugs it exists to catch: inject each one into a
# snapshot of the RTL and require at least one FAILED check.  Verilator; no board.
#
#   sim/axiceil/run_axiceil_mutations.sh [outdir]
#
# The mutations are the classes that hang or corrupt an AXI port:
#   idbook      a B response frees the wrong ID (concurrent-ID bookkeeping)
#   wlast       WLAST one beat early at a 13-beat burst (burst-length counting, non-power-of-2)
#   rlast       the read side expects RLAST one beat late at 5-beat bursts
#   abortvalid  abort drops AWVALID before AWREADY (a handshake withdrawn)
#   wbeforeaw   W released before its AW is accepted at the PS pins
#   guard4k     the guard's 4 KiB-page check removed
set -uo pipefail
cd "$(dirname "$0")/../.."
V="${VERILATOR:-$(command -v verilator 2>/dev/null || true)}"
[ -n "$V" ] && [ -x "$V" ] || { echo "verilator not found: set \$VERILATOR" >&2; exit 1; }
OUT=${1:-/tmp/axiceil_mutations}
rm -rf "$OUT"; mkdir -p "$OUT/snap"
cp src/axiceil/axiceil_core.v src/axiceil/axiceil_port.v src/axiceil/axiceil_guard.v \
   sim/axiceil/tb_axiceil.sv sim/axiceil/axi3_hp_model.sv "$OUT/snap/"

mutate () {   # <name> <file> <python replace old> <new>
  python3 - "$@" <<'EOF'
import sys
name, f, old, new = sys.argv[1:5]
s = open(f).read()
if s.count(old) != 1:
    sys.exit(f"mutation {name}: pattern found {s.count(old)} times in {f}")
open(f, "w").write(s.replace(old, new))
EOF
}

run_one () {
  local m="$1" d="$OUT/$1"
  "$V" --binary --timing -O2 -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
       -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-fatal --Mdir "$d/obj" --top-module tb_axiceil \
       "$d/tb_axiceil.sv" "$d/axi3_hp_model.sv" "$d/axiceil_core.v" "$d/axiceil_port.v" "$d/axiceil_guard.v" \
       > "$d/build.log" 2>&1 || { echo "$m: BUILD FAILED"; return 1; }
  timeout 1800 "$d/obj/Vtb_axiceil" > "$d/run.log" 2>&1
  local n; n=$(grep -c '  FAIL' "$d/run.log")
  if grep -q "ALL CHECKS PASSED" "$d/run.log"; then
    echo "  NOT CAUGHT  $m"; return 1
  fi
  echo "  caught      $m  ($n failed checks; first: $(grep -m1 '  FAIL' "$d/run.log" | sed 's/^ *FAIL *//' | cut -c1-110))"
}

missed=0
for m in idbook wlast rlast abortvalid wbeforeaw guard4k; do
  d="$OUT/$m"; mkdir -p "$d"; cp "$OUT/snap/"* "$d/"
  case $m in
    idbook) mutate $m "$d/axiceil_port.v" \
      "& ~(b_known ? (16'd1 << bid1[3:0]) : 16'd0);" \
      "& ~(b_known ? (16'd1 << (bid1[3:0] ^ 4'd1)) : 16'd0);" ;;
    wlast) mutate $m "$d/axiceil_port.v" \
      "m_wlast  <= (wg_beat == {1'b0, q_len_m1});" \
      "m_wlast  <= (wg_beat == {1'b0, q_len_m1}) || (q_len_m1 == 4'd12 && wg_beat == 5'd11);" ;;
    rlast) mutate $m "$d/axiceil_port.v" \
      "rlx2 <= (s2_beat == {1'b0, q_len_m1});" \
      "rlx2 <= (s2_beat == {1'b0, q_len_m1} + ((q_len_m1 == 4'd4) ? 5'd1 : 5'd0));" ;;
    abortvalid) mutate $m "$d/axiceil_port.v" \
      "      end else if (m_awvalid && m_awready) begin
        m_awvalid <= 1'b0;" \
      "      end else if ((m_awvalid && m_awready) || abort) begin
        m_awvalid <= 1'b0;" ;;
    wbeforeaw) mutate $m "$d/axiceil_port.v" \
      "wire        w_pop  = w_need & ~wq_empty & (aw_taken != w_started);" \
      "wire        w_pop  = w_need & ~wq_empty;" ;;
    guard4k) mutate $m "$d/axiceil_guard.v" \
      "&& (endpage <= 13'd4096);" \
      ";" ;;
  esac || { missed=1; continue; }
  run_one "$m" || missed=1
done
[ "$missed" -eq 0 ] && echo "ALL MUTATIONS CAUGHT" || { echo "SOME MUTATIONS NOT CAUGHT"; exit 1; }
