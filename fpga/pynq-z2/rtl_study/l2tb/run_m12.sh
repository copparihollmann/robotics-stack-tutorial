#!/usr/bin/env bash
# SIMULATION ONLY.  WideSkip (7 MSHRs, 5 take Gets) vs WideSkipM12 (12 MSHRs, 10 take Gets), 128-bit L2 on both sides.
#   ./build.sh wideskip; ./build.sh wideskipm12
#   (what-if) R=$PWD/rtl_variants; OBJ=$PWD/obj_wideskip_dirq2 EXTRA="$R/dirq2/Directory.sv $R/dirq2/Queue2_DirectoryWrite.sv" ./build.sh wideskip
#             OBJ=$PWD/obj_wideskipm12_dirq2 EXTRA="$R/dirq2/Directory.sv $R/dirq2/Queue2_DirectoryWrite.sv" ./build.sh wideskipm12
#   ./run_m12.sh && ./summary7.py > out7/SUMMARY7.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/out7"; mkdir -p "$O"
CAL="S=0 mode=parallel G=0 M=8"
D="blocks=65536 warm=65536"
OUTS=1,2,3,4,5,6,7,8
run() { local bin=$1 name=$2; shift 2; "$HERE/$bin/Vl2tb_top" "$@" > "$O/$name.txt" 2>&1; echo "done $name rc=$?"; }
BINS="${BINS:-wideskip wideskipm12}"
for b in $BINS; do
  run obj_$b ${b}_hits S=0 hits:$OUTS &
  for P in 1 2; do
    for L in 10.65 12.0 0; do
      run obj_$b ${b}_dram_P${P}_L$L $CAL L=$L supply=$P $D dram:$OUTS &
    done
  done
done
wait
grep -h "^RESULT" $(ls --color=never "$O"/*.txt | grep -v 'ALL_RESULTS\|SUMMARY\|smoke') > "$O/ALL_RESULTS.txt"
echo "wrote $O/ALL_RESULTS.txt"
