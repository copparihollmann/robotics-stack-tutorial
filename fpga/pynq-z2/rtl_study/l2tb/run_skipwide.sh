#!/usr/bin/env bash
# SIMULATION ONLY.  A: skip clean Releases (MSHR.sv variant) with/without the ReleaseAck-first cork.
#                   B: lever 4's 128-bit system bus (BwWideConfig), alone / + rackfirst cork / + skip-clean.
# Builds (see build.sh): obj_lever1 obj_cork obj_skipvar obj_cork_skip obj_wide obj_wide_rackfirst obj_wide_skip obj_wide_rackfirst_skip
#   R=$PWD/rtl_variants
#   ./build.sh lever1; ./build.sh cork; ./build.sh wide
#   OBJ=$PWD/obj_skipvar   EXTRA="$R/skipclean/MSHR.sv" ./build.sh lever1
#   OBJ=$PWD/obj_cork_skip EXTRA="$R/skipclean/MSHR.sv" ./build.sh cork
#   OBJ=$PWD/obj_wide_rackfirst      EXTRA="$R/rackfirst_wide/TLCacheCork.sv" ./build.sh wide
#   OBJ=$PWD/obj_wide_skip           EXTRA="$R/skipclean_wide/MSHR.sv" ./build.sh wide
#   OBJ=$PWD/obj_wide_rackfirst_skip EXTRA="$R/rackfirst_wide/TLCacheCork.sv $R/skipclean_wide/MSHR.sv" ./build.sh wide
#   ./run_skipwide.sh && ./summary4.py > out4/SUMMARY4.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/out4"; mkdir -p "$O"
CAL="S=0 mode=parallel G=0 M=8"
D="blocks=65536 warm=65536"
OUTS=1,2,3,4,5,6,7,8
run() { local bin=$1 name=$2; shift 2; "$HERE/$bin/Vl2tb_top" "$@" > "$O/$name.txt" 2>&1; echo "done $name"; }
for b in lever1 cork skipvar cork_skip wide wide_rackfirst wide_skip wide_rackfirst_skip; do
  n=${b/skipvar/skip}
  run obj_$b ${n}_hits S=0 hits:$OUTS &
  run obj_$b ${n}_dram_L10.65 $CAL L=10.65 $D dram:$OUTS &
done
for b in lever1 cork skip cork_skip; do
  for L in 12.35 15; do run obj_${b/#skip/skipvar} ${b}_dram_L$L $CAL L=$L $D dram:$OUTS & done
  # dirty-victim path: evictions become ReleaseData -> Put through the cork's A path
  run obj_${b/#skip/skipvar} ${b}_dramw1_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:1 &
  run obj_${b/#skip/skipvar} ${b}_dramw4_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:4 &
  run obj_${b/#skip/skipvar} ${b}_dramw8_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:8 &
  run obj_${b/#skip/skipvar} ${b}_dramw8_put64  $CAL L=10.65 $D wr_size=6 wr_lag=32 wr_cap=2 dramw:8 &
  run obj_${b/#skip/skipvar} ${b}_alt8_clean    $CAL L=10.65 alt_pairs=512 alt_dirty=0 alt:8 &
  run obj_${b/#skip/skipvar} ${b}_alt8_dirty    $CAL L=10.65 alt_pairs=512 alt_dirty=1 wr_cap=2 alt:8 &
done
for b in lever1 skip cork_skip; do run obj_$b ${b}_phases_L10.65 $CAL L=10.65 blocks=16384 warm=65536 phases=1 dram:1 & done
wait
grep -h "^RESULT" $(ls --color=never "$O"/*.txt | grep -v 'ALL_RESULTS\|SUMMARY\|smoke\|regress') > "$O/ALL_RESULTS.txt"
echo "wrote $O/ALL_RESULTS.txt"
