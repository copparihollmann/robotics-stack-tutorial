#!/usr/bin/env bash
# SIMULATION ONLY.  Generated ReleaseAck-first cork (L2CorkConfig) vs the hand-edited rackfirst variant,
# starvation-reversal checks, and the 1-in-flight core-like stream.  Outputs in out3/.
#   ./build.sh lever1 && ./build.sh cork && OBJ=$PWD/obj_rackfirst EXTRA=$PWD/rtl_variants/rackfirst/TLCacheCork.sv ./build.sh lever1
#   ./run_cork.sh && ./summary3.py > out3/SUMMARY3.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/out3"; mkdir -p "$O"
CAL="S=0 mode=parallel G=0 M=8"
D="blocks=65536 warm=65536"
run() { local bin=$1 name=$2; shift 2; "$HERE/$bin/Vl2tb_top" "$@" > "$O/$name.txt" 2>&1; echo "done $name"; }

# 1. generated cork vs hand-edited variant, identical command lines
for b in cork rackfirst; do
  run obj_$b ${b}_hits        S=0 hits:1,2,3,4,5,6,7,8 &
  run obj_$b ${b}_dram_L10.65 $CAL L=10.65 $D dram:1,2,3,4,5,6,7,8 &
  for L in 12.35 15 21.3; do
    run obj_$b ${b}_dram_L$L  $CAL L=$L $D dram:1,2,3,4,6,8 &
  done
done
# 2. starvation-reversal checks, lever-1 (data-first) vs generated cork (ReleaseAck-first)
for b in lever1 cork; do
  run obj_$b ${b}_dramw8_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:8 &
  run obj_$b ${b}_dramw8_put64  $CAL L=10.65 $D wr_size=6 wr_lag=32 wr_cap=2 dramw:8 &
  run obj_$b ${b}_dramw4_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:4 &
  run obj_$b ${b}_dramw1_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:1 &
  run obj_$b ${b}_alt8_clean    $CAL L=10.65 alt_pairs=512 alt_dirty=0 alt:8 &
  run obj_$b ${b}_alt8_dirty    $CAL L=10.65 alt_pairs=512 alt_dirty=1 wr_cap=2 alt:8 &
  run obj_$b ${b}_alt4_dirty    $CAL L=10.65 alt_pairs=512 alt_dirty=1 wr_cap=2 alt:4 &
  run obj_$b ${b}_alt8_dirty_L0 $CAL L=0     alt_pairs=512 alt_dirty=1 wr_cap=2 alt:8 &
  run obj_$b ${b}_dramw8_put8_L0 $CAL L=0    $D wr_size=3 wr_lag=32 wr_cap=2 dramw:8 &
done
# 3. core-like single-outstanding miss stream with the phase timeline
for b in lever1 cork; do
  run obj_$b ${b}_phases_L10.65 $CAL L=10.65 blocks=16384 warm=65536 phases=1 dram:1 &
done
wait
grep -h "^RESULT" $(ls --color=never "$O"/*.txt | grep -v 'ALL_RESULTS\|SUMMARY\|smoke\|regress') > "$O/ALL_RESULTS.txt"
echo "wrote $O/ALL_RESULTS.txt"
