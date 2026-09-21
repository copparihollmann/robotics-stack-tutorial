#!/usr/bin/env bash
# The HM01B0 camera (ospi capture + DMA + TLI2C) in 0x5A5A001E's own RTL, in Verilator, before
# any bitstream.
#
#   scripts/65_cam_rtl_sim.sh            build the simulator if needed, run, expect a PASS
#   scripts/65_cam_rtl_sim.sh --rebuild  rebuild the simulator first
#
# PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig's TestHarness binds a model sensor
# (fpga/pynq-z2/sim/hm01b0_sim_model.v, via WithHM01B0SimModel in PynqZ2Configs.scala) to
# ChipTop's camera and I2C ports.  samples/cam_rtl_sim drives the real SoC against it with
# sw/cam/ospi_cam.c -- the same driver samples/cam_capture runs on the board -- and checks the
# register map, the idle diagnostics, I2C (ACK, NACK, model ID, a write, SCL period), the DMA's
# armed/timeout path, four whole frames byte-exact through the L2 on both harts, a masked tail
# beat, the error response, the MMIO drain and overflow, and PCLK stopping.  See
# fpga/pynq-z2/docs/CAMERA_Z1.md section 5.
#
# The simulator is compiled into out/ from the elaboration already in $CHIPYARD_DIR, 52's way,
# with the engine BlackBoxes from the camera variant's own snapshot (src/cam_engine_rev1), the mic
# Verilog and the sensor model added.  It runs no sbt and writes nothing into the Chipyard tree.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
CONFIG=PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig
[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set (the TestHarness is not vendored)"
G="$CHIPYARD_DIR/sims/verilator/generated-src/chipyard.harness.TestHarness.$CONFIG"
[ -f "$G/sim_files.common.f" ] || die "no elaboration of $CONFIG in $CHIPYARD_DIR (make -C sims/verilator CONFIG=$CONFIG verilog, under scripts/lib/with_lock.sh chipyard)"
OUT="$IISWC_OUT/cam_rtl_sim"; mkdir -p "$OUT"
R="$IISWC_ROOT/fpga/pynq-z2"
S="$R/src/cam_engine_rev1"
EXTRA="$S/mbxr_engine.v $S/mbxr_tseq.v $S/mbxr_datapath.v $S/mbxr_st.v $S/mbxd_dma.v $S/mbxd_spad.v $S/mbx_mac.v $R/src/pdm_mic_core.v $R/src/pdm_mic_capture.v $R/src/pdm_cic4.v $R/src/pdm_fir_mac.v $R/src/pdm_dcblock.v $R/src/pdm_mic_fifo.v $R/sim/hm01b0_sim_model.v"

[ "${1-}" = "--rebuild" ] && rm -rf "$OUT/simulator" "$OUT/obj"
if [ ! -x "$OUT/simulator" ] || [ "$R/sim/hm01b0_sim_model.v" -nt "$OUT/simulator" ]; then
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
fi

step "build samples/cam_rtl_sim"
CC="$CHIPYARD_DIR/.conda-env/riscv-tools/bin/riscv64-unknown-elf-gcc"
T="$IISWC_ROOT/samples/cam_rtl_sim"
P="$IISWC_ROOT/samples/pext_rtl_selftest"   # the two-hart crt.S and link.ld, unchanged
run "$CC" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -mno-relax -O2 -std=gnu11 -Wall -Wextra -Werror \
    -ffreestanding -fno-builtin -fno-common -fno-stack-protector -I"$R/sw/cam" \
    -nostdlib -nostartfiles -static -T "$P/link.ld" -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
    -o "$OUT/cam_rtl_sim.elf" "$P/crt.S" "$T/main.c" "$R/sw/cam/ospi_cam.c" -lgcc

step "run"
( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1; cd "$OUT"
  ./simulator +permissive +dramsim +dramsim_ini_dir="$CHIPYARD_DIR/generators/testchipip/src/main/resources/dramsim2_ini" \
    +max-cycles=${MAX_CYCLES:-80000000} +permissive-off cam_rtl_sim.elf </dev/null ) 2>&1 | tee "$OUT/sim.log"
grep -q "CAM_RTL_SIM: PASS" "$OUT/sim.log" || die "cam_rtl_sim did not pass -- see $OUT/sim.log"
echo "CAM_RTL_SIM_GATE: PASS"
