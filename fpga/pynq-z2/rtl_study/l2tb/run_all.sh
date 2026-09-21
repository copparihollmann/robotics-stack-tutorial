#!/usr/bin/env bash
# SIMULATION ONLY.  Re-run every sweep reported for the L2 miss-path study into out/.
#   ./build.sh && OBJ=$PWD/obj_rackfirst EXTRA=$PWD/rtl_variants/rackfirst/TLCacheCork.sv ./build.sh && ./run_all.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HERE/obj/Vl2tb_top"
O="$HERE/out"
mkdir -p "$O"
OUTS=1,2,3,4,6,8
D="S=0 blocks=65536 warm=16384"

run() { local name=$1; shift; "$B" "$@" > "$O/$name.txt" 2>&1; echo "done $name"; }

# calibration + headline sweeps
run hits_S0                 S=0 hits:$OUTS &
run dram_serial_L10.65      $D mode=serial   L=10.65 dram:$OUTS &
run dram_parallel_L10.65    $D mode=parallel L=10.65 dram:$OUTS &
run dram_parallel_L0        $D mode=parallel L=0     dram:$OUTS &
run dram_serial_L0          $D mode=serial   L=0     dram:$OUTS &
run dram_fifo_L10.65        $D mode=fifo     L=10.65 dram:$OUTS &
# sensitivity
run dram_parallel_L10       $D mode=parallel L=10    dram:$OUTS &
run dram_parallel_L11       $D mode=parallel L=11    dram:$OUTS &
run dram_parallel_L5        $D mode=parallel L=5     dram:$OUTS &
run dram_parallel_L21.3     $D mode=parallel L=21.3  dram:$OUTS &
run dram_parallel_L10.65_G1 $D mode=parallel L=10.65 G=1 dram:$OUTS &
run dram_parallel_L0_G1     $D mode=parallel L=0     G=1 dram:$OUTS &
run dram_parallel_L10.65_M2 $D mode=parallel L=10.65 M=2 dram:$OUTS &
run dram_parallel_L10.65_M4 $D mode=parallel L=10.65 M=4 dram:$OUTS &
run hits_S1                 S=1 attr=0 hits:1,2 &
# RTL what-if (NOT silicon RTL): TLCacheCork copy with ReleaseAck ahead of outer data on inner D
if [ -x "$HERE/obj_rackfirst/Vl2tb_top" ]; then
  RB="$HERE/obj_rackfirst/Vl2tb_top"
  ( "$RB" $D mode=parallel L=10.65 dram:$OUTS > "$O/rackfirst_dram_parallel_L10.65.txt" 2>&1; echo "done rackfirst L10.65" ) &
  ( "$RB" $D mode=parallel L=0     dram:$OUTS > "$O/rackfirst_dram_parallel_L0.txt" 2>&1; echo "done rackfirst L0" ) &
  ( "$RB" $D mode=serial   L=10.65 dram:$OUTS > "$O/rackfirst_dram_serial_L10.65.txt" 2>&1; echo "done rackfirst serial" ) &
  ( "$RB" S=0 attr=0 hits:1,2,8 > "$O/rackfirst_hits_S0.txt" 2>&1; echo "done rackfirst hits" ) &
fi
wait
grep -h "^RESULT" $(ls "$O"/*.txt | grep -v ALL_RESULTS) > "$O/ALL_RESULTS.txt"
echo "wrote $O/ALL_RESULTS.txt"
