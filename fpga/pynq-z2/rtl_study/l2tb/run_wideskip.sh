#!/usr/bin/env bash
# SIMULATION ONLY.  WideSkip RTL (lever 4 128-bit sbus + WithEdgeDataBits(128) + patch 0092): the L2 and cork are
# 128-bit on both sides.  The memory supplies at most one 128-bit outer D beat every P cycles:
#   supply=2  width widget over a 64-bit AXI on the L2's clock (8 B/cycle of supply)
#   supply=1  memory path >= 2x faster (one 128-bit beat per cycle)
#   ./build.sh wideskip && ./run_wideskip.sh && ./summary6.py > out6/SUMMARY6.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/out6"; mkdir -p "$O"
CAL="S=0 mode=parallel G=0 M=8"
D="blocks=65536 warm=65536"
OUTS=1,2,3,4,5,6,7,8
run() { local name=$1; shift; "$HERE/obj_wideskip/Vl2tb_top" "$@" > "$O/$name.txt" 2>&1; echo "done $name rc=$?"; }
run ws_hits S=0 hits:$OUTS &
for P in 1 2; do
  for L in 10.65 12.35 0; do
    run ws_dram_P${P}_L$L $CAL L=$L supply=$P $D dram:$OUTS &
  done
  run ws_phases_P${P}_L10.65 $CAL L=10.65 supply=$P blocks=16384 warm=65536 phases=1 dram:1 &
done
wait
grep -h "^RESULT" $(ls --color=never "$O"/ws_*.txt) > "$O/ALL_RESULTS.txt"
echo "wrote $O/ALL_RESULTS.txt"
