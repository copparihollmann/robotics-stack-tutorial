#!/usr/bin/env bash
# The decoupled RoCC engine in the SoC's OWN RTL, in Verilator -- before any bitstream.
#
#   scripts/52_roccmoon_rtl_sim.sh
#
# samples/roccmoon_rtl_sim on Chipyard's TestHarness for
# PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig: the RoCC shim in hart 1's tile, the
# BundleBridge across the tile boundary, both engine clients on the real system bus, the
# real 64 KB InclusiveCache and DRAMSim behind it, driven by the board's driver
# (sw/roccmoon/mbxr.c).  It checks placement both ways (custom-1 traps on hart 0; MBP.DOT8
# still traps on hart 1, which is patches/0101) and one linear dispatch byte for byte.
#
# The simulator is compiled into out/, from the elaboration already in $CHIPYARD_DIR, with
# the BlackBox Verilog added and MBXR_BEHAVIOURAL defined (no DSP48E1 in Verilator).  It
# runs no sbt and writes nothing into the Chipyard tree, so it needs no chipyard lock.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
CONFIG=PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonConfig
[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set (the TestHarness is not vendored)"
G="$CHIPYARD_DIR/sims/verilator/generated-src/chipyard.harness.TestHarness.$CONFIG"
[ -f "$G/sim_files.common.f" ] || die "no elaboration of $CONFIG in $CHIPYARD_DIR (scripts/62_patch_chipyard_roccmoon.sh, then make ... verilog)"
OUT="$IISWC_OUT/roccmoon_rtl_sim"; mkdir -p "$OUT"
R="$IISWC_ROOT/fpga/pynq-z2"
EXTRA="$R/rtl_study/roccmoon/mbxr_engine.v $R/rtl_study/roccmoon/mbxr_tseq.v $R/rtl_study/roccmoon/mbxr_datapath.v $R/rtl_study/roccmoon/mbxr_st.v $R/rtl_study/roccmoon/mbxd_spad2.v $R/rtl_study/rocc/mbxd_dma.v $R/rtl_study/rocc/mbx_mac.v $R/src/pdm_mic_core.v $R/src/pdm_mic_capture.v $R/src/pdm_cic4.v $R/src/pdm_fir_mac.v $R/src/pdm_dcblock.v $R/src/pdm_mic_fifo.v"

# The simulator compiles the engine RTL in: rebuild it whenever any of those files changed
# (rtl_study/ moved to engine revision 2a on 2026-09-17).
EXTRA_SUM=$(md5sum $EXTRA | md5sum | cut -d' ' -f1)
if [ -x "$OUT/simulator" ] && [ "$(cat "$OUT/extra.md5" 2>/dev/null)" != "$EXTRA_SUM" ]; then
  info "engine RTL changed since the simulator was built: rebuilding it"
  rm -rf "$OUT/simulator" "$OUT/obj"
fi
if [ ! -x "$OUT/simulator" ]; then
  step "verilate the SoC (from the dry-run of Chipyard's own recipe)"
  ( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1
    make -n -C sims/verilator CONFIG="$CONFIG" EXTRA_SIM_PREPROC_DEFINES="+define+MBXR_BEHAVIOURAL" \
         EXTRA_SIM_SOURCES="__EXTRA__" 2>/dev/null | grep -m1 -E "^verilator --main" || true ) > "$OUT/vcmd.txt"
  [ -s "$OUT/vcmd.txt" ] || die "could not recover the verilator command"
  sed -i -e "s|__EXTRA__|$EXTRA +incdir+$R/src|" \
         -e "s|-o [^ ]*simulator-chipyard[^ ]*|-o $OUT/simulator|" \
         -e "s|-Mdir [^ ]*|-Mdir $OUT/obj|" "$OUT/vcmd.txt"
  ( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1; cd "$OUT"
    bash -c "$(cat "$OUT/vcmd.txt")" > "$OUT/verilate.log" 2>&1 &&
    make -C "$OUT/obj" -f VTestDriver.mk -j"${JOBS:-16}" > "$OUT/make.log" 2>&1 ) || die "simulator build failed (see $OUT)"
  echo "$EXTRA_SUM" > "$OUT/extra.md5"
fi

step "build samples/roccmoon_rtl_sim"
# the second dispatch's golden, computed on the host
run cc -O2 -o "$OUT/gen_golden2" "$IISWC_ROOT/samples/roccmoon_rtl_sim/gen_golden2.c"
"$OUT/gen_golden2" > "$OUT/golden2.h" || die "gen_golden2 failed"
CC="$CHIPYARD_DIR/.conda-env/riscv-tools/bin/riscv64-unknown-elf-gcc"
S="$IISWC_ROOT/samples/roccmoon_rtl_sim"
run "$CC" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -mno-relax -O2 -std=gnu11 -Wall \
    -ffreestanding -fno-builtin -fno-common -fno-stack-protector -I"$R/sw/roccmoon" -I"$OUT" \
    -nostdlib -nostartfiles -static -T "$S/link.ld" -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
    -o "$OUT/roccmoon_rtl_sim.elf" "$S/crt.S" "$S/main.c" "$R/sw/roccmoon/mbxr.c" -lgcc

step "run"
( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1; cd "$OUT"
  ./simulator +permissive +dramsim +dramsim_ini_dir="$CHIPYARD_DIR/generators/testchipip/src/main/resources/dramsim2_ini" \
    +max-cycles=60000000 +permissive-off roccmoon_rtl_sim.elf </dev/null ) 2>&1 | tee "$OUT/sim.log"
grep -q "ROCCMOON_RTL_SIM: PASS" "$OUT/sim.log" || die "roccmoon_rtl_sim did not pass -- see $OUT/sim.log"
