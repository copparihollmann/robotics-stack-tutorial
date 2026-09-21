#!/usr/bin/env bash
# SIMULATION ONLY.  Follow-up sweeps (12-MSHR RTL, 256 KB RTL, latency sensitivity, per-Get phases) into out2/.
#   for c in lever1 mshr12 cap256; do ./build.sh $c; done
#   OBJ=$PWD/obj_rackfirst EXTRA=$PWD/rtl_variants/rackfirst/TLCacheCork.sv ./build.sh lever1
#   ./run_followup.sh && ./summary2.py > out2/SUMMARY2.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/out2"; mkdir -p "$O"
CAL="S=0 mode=parallel G=0 M=8"
D="blocks=65536 warm=65536"
run() { local bin=$1 name=$2; shift 2; "$HERE/$bin/Vl2tb_top" "$@" > "$O/$name.txt" 2>&1; echo "done $name"; }

# 1. 12-MSHR RTL next to lever-1 (and the 256 KB RTL, same sweeps)
for c in lever1 mshr12 cap256; do
  run obj_$c ${c}_hits           S=0 hits:1,2,3,4,6,8 &
  run obj_$c ${c}_dram_L10.65    $CAL L=10.65 $D dram:1,2,3,4,5,6,7,8 &
done
# 2. 128 KiB working set, fresh region, 1 untimed pass + 33 timed passes
for c in lever1 cap256; do
  run obj_$c ${c}_ws128k_L10.65  $CAL L=10.65 wsbytes=131072 wsreps=33 ws:1,2,3,4,6,8 &
done
# 3. latency sensitivity, lever-1 RTL and the ReleaseAck-first cork, PARALLEL
for L in 10.65 11.5 12.35 13.3 15 21.3; do
  run obj_lever1    lsweep_lever1_L$L    $CAL L=$L $D dram:1,2,3,4,6,8 &
  run obj_rackfirst lsweep_rackfirst_L$L $CAL L=$L $D dram:1,2,3,4,6,8 &
done
# 4. per-Get phase timeline at 1 in flight
for c in lever1 mshr12 cap256; do
  run obj_$c phases_${c}_L10.65 $CAL L=10.65 blocks=16384 warm=65536 phases=1 dram:1 &
done
run obj_lever1 phases_lever1_L11 $CAL L=11 blocks=16384 warm=65536 phases=1 dram:1 &
run obj_lever1 phases_lever1_L0  $CAL L=0  blocks=16384 warm=65536 phases=1 dram:1 &
wait
grep -h "^RESULT" $(ls "$O"/*.txt | grep -v 'ALL_RESULTS\|SUMMARY\|ATTR_\|build_\|smoke\|regress') > "$O/ALL_RESULTS.txt"
echo "wrote $O/ALL_RESULTS.txt"
