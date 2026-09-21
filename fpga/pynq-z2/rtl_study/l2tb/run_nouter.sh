#!/usr/bin/env bash
# SIMULATION ONLY.  One stripe of an N-stripe L2 (MEMORY_BANDWIDTH.md s6.12; nouter_model.py composes N of
# them).  The generated L2 + cork of 001A (64-bit, 7 MSHRs), 0018 (128/128, 7) and 0019 (128/128, 12), one
# outer channel each, memory bus on FCLK1 = 100 behind an async crossing: supply one outer beat per L2
# cycle (P=1) with first-beat latency L in L2 cycles -- 12.0 (lever 2's 1-in-flight fit), 12.35 (lever 2's
# plateau fit, s6.3) and, for the 128-bit L2s, 12.7 (+ the 128->64 widget's extra memory-bus cycle, s6.9).
#   OBJ=$PWD/obj_gskip ./build.sh skip; ./build.sh wideskip; ./build.sh wideskipm12
#   ./run_nouter.sh && ./nouter_model.py > results/SUMMARY8.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/out8"; mkdir -p "$O"
CAL="S=0 mode=parallel G=0 M=8"
D="blocks=65536 warm=65536"
OUTS=1,2,3,4,5,6,7,8
run() { local bin=$1 name=$2; shift 2; "$HERE/$bin/Vl2tb_top" "$@" > "$O/$name.txt" 2>&1; echo "done $name rc=$?"; }
for L in 12.0 12.35; do
  run obj_gskip        skip64_L$L   $CAL L=$L $D dram:$OUTS &
done
for L in 12.0 12.35 12.7; do
  run obj_wideskip     ws128m7_L$L  $CAL L=$L supply=1 $D dram:$OUTS &
  run obj_wideskipm12  ws128m12_L$L $CAL L=$L supply=1 $D dram:$OUTS &
done
run obj_gskip skip64_hits S=0 hits:$OUTS &
wait
for f in skip64_hits skip64_L12.0 skip64_L12.35 ws128m7_L12.0 ws128m7_L12.35 ws128m7_L12.7 \
         ws128m12_L12.0 ws128m12_L12.35 ws128m12_L12.7; do
  command grep "^RESULT" "$O/$f.txt" | sed "s/^/$f /"
done > "$O/.ALL_RESULTS8.tmp" && mv "$O/.ALL_RESULTS8.tmp" "$O/ALL_RESULTS8.txt"
for f in skip64_L12.35 ws128m7_L12.7 ws128m12_L12.7; do
  echo "=== $f, out=8 (saturation)"; awk '/^RESULT.*out=8 /{f=1} f' "$O/$f.txt" | command grep -E "^RESULT|^LAT|^ATTR"
done > "$O/ATTR8.txt"
echo "wrote $O/ALL_RESULTS8.txt $O/ATTR8.txt"
