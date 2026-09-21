#!/usr/bin/env bash
# SIMULATION ONLY.  Every run behind MEMORY_BANDWIDTH.md section 9.2's simulated numbers.  Output in results/.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
B=./obj/Vwintb_top; R=results; mkdir -p $R
run() { local name="$1"; shift; ( $B "$@" > $R/$name.txt 2> $R/$name.err; echo "rc=$?" >> $R/$name.txt ) & }
run sweep_win_lat20   --rows 4096 --lat 20 --outs 1,2,3,4,5,6,8 win
run sweep_ap_lat20    --rows 4096 --lat 20 --outs 1,2,3,4,6,8 ap
run tile_src1_lat20   --lat 20 --tsrc 1 tile
run drain_lat20       --rows 4096 --lat 20 drain
run lsweep            --rows 4096 --lats 5,10,15,20,25,30,40 lsweep
run sweep_win_f1_909  --rows 4096 --lat 20 --p1 11000 --outs 1,4,8 --sets L0,L0123 win
wait
grep -h 'rc=' $R/*.txt | sort | uniq -c
