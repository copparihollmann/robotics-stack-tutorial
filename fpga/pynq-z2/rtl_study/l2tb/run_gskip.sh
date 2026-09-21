#!/usr/bin/env bash
# SIMULATION ONLY.  Generated skip-clean-Release RTL (L2SkipConfig, "000F") vs the hand-edited skipclean variant,
# the hazard tests next to lever-1 and the generated cork ("000E"), a dirty-victim-heavy pre-write pattern,
# and positive controls that must make the L2 TL monitors fire.  Outputs in out5/.
#   R=$PWD/rtl_variants
#   ./build.sh lever1; ./build.sh cork; OBJ=$PWD/obj_gskip ./build.sh skip
#   OBJ=$PWD/obj_skipvar EXTRA="$R/skipclean/MSHR.sv" ./build.sh lever1
#   ./run_gskip.sh && ./summary5.py > out5/SUMMARY5.txt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
O="$HERE/out5"; mkdir -p "$O"
CAL="S=0 mode=parallel G=0 M=8"
D="blocks=65536 warm=65536"
OUTS=1,2,3,4,5,6,7,8
run() { local bin=$1 name=$2; shift 2; "$HERE/$bin/Vl2tb_top" "$@" > "$O/$name.txt" 2>&1; echo "done $name rc=$?"; }

# 1. generated vs hand-edited, identical command lines
for b in gskip skipvar; do
  run obj_$b ${b}_hits S=0 hits:$OUTS &
  for L in 10.65 12.35 15; do run obj_$b ${b}_dram_L$L $CAL L=$L $D dram:$OUTS & done
  run obj_$b ${b}_phases_L10.65 $CAL L=10.65 blocks=16384 warm=65536 phases=1 dram:1 &
done
# 1+2. write-mixed and alt patterns; lever-1 and the generated cork for the hazard table
for b in gskip skipvar lever1 cork; do
  run obj_$b ${b}_dramw1_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:1 &
  run obj_$b ${b}_dramw4_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:4 &
  run obj_$b ${b}_dramw8_put8   $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 dramw:8 &
  run obj_$b ${b}_dramw8_put64  $CAL L=10.65 $D wr_size=6 wr_lag=32 wr_cap=2 dramw:8 &
  run obj_$b ${b}_dramw4_put64  $CAL L=10.65 $D wr_size=6 wr_lag=32 wr_cap=2 dramw:4 &
  run obj_$b ${b}_alt8_clean    $CAL L=10.65 alt_pairs=512 alt_dirty=0 alt:8 &
  run obj_$b ${b}_alt8_dirty    $CAL L=10.65 alt_pairs=512 alt_dirty=1 wr_cap=2 alt:8 &
  run obj_$b ${b}_alt4_dirty    $CAL L=10.65 alt_pairs=512 alt_dirty=1 wr_cap=2 alt:4 &
# 4. dirty-victim-heavy: pre-dirty 4 MiB with 64-byte PutFulls, read it at 8 in flight with a lag writer, read it back
  run obj_$b ${b}_pw8           $CAL L=10.65 $D wr_size=3 wr_lag=32 wr_cap=2 pw:8 &
done
wait
# 3. positive controls: each run MUST abort with the named monitor's assertion
L2TB_VIOLATE_MINLAT=1 "$HERE/obj_gskip/Vl2tb_top" $CAL L=0 blocks=256 warm=256 attr=0 dram:1 > "$O/control_minlat_gskip.txt" 2>&1; echo "control_minlat rc=$?"
L2TB_BAD_SOURCE=1     "$HERE/obj_gskip/Vl2tb_top" $CAL L=10.65 attr=0 alt_pairs=1 alt:1 > "$O/control_badsource_gskip.txt" 2>&1; echo "control_badsource rc=$?"
L2TB_VIOLATE_MINLAT=1 "$HERE/obj_lever1/Vl2tb_top" $CAL L=0 blocks=256 warm=256 attr=0 dram:1 > "$O/control_minlat_lever1.txt" 2>&1; echo "control_minlat lever1 rc=$?"
L2TB_BAD_SOURCE=1     "$HERE/obj_lever1/Vl2tb_top" $CAL L=10.65 attr=0 alt_pairs=1 alt:1 > "$O/control_badsource_lever1.txt" 2>&1; echo "control_badsource lever1 rc=$?"
grep -h "^RESULT" $(ls --color=never "$O"/*.txt | grep -v 'ALL_RESULTS\|SUMMARY\|control_') > "$O/ALL_RESULTS.txt"
echo "wrote $O/ALL_RESULTS.txt"
