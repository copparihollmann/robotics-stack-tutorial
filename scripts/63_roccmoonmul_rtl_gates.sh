#!/usr/bin/env bash
# The fast multiplier's RTL gates, in the SoC's OWN RTL in Verilator, before any bitstream.
#
#   scripts/63_roccmoonmul_rtl_gates.sh
#
# PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonMulConfig (0x5A5A0011) is 0x5A5A0010 with
# PipelinedMultiplier on hart 0 (ROCC_DECOUPLED.md section 8.15.3).  Four gates on its
# TestHarness, all on hart 0 unless stated otherwise:
#   1. riscv-tests rv64um-p-*, all 13, plus a negative control: mul.S with one expected value
#      corrupted must FAIL, so a pass means something.
#   2. samples/pext_rtl_selftest: MBP on hart 0, the four encodings trap on hart 1.
#   3. samples/roccmoon_rtl_sim: the RoCC engine on hart 1, unchanged.
#   4. rtl_study/muldiv/golden: softmax_s8 pext_int_row and pext_int_memo2, and layernorm_s8
#      pext_int_rsqrt, on real encoder rows, plus an RV64M back-to-back stress.  Every output
#      byte is compared with the same source compiled for the host.
# If 0x5A5A0010's simulator exists (scripts/52_roccmoon_rtl_sim.sh), gate 4 also runs there, and
# both runs' per-kernel mcycle deltas are printed side by side.
#
# The simulator is built 52's way, from the dry-run of Chipyard's recipe into out/, and this
# script runs no sbt, so it needs no chipyard lock.  It does need riscv-tests SOURCE:
# RISCV_TESTS_DIR (isa/rv64um, isa/macros, env/p), default
# $CHIPYARD_DIR/toolchains/riscv-tools/riscv-tests.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
CONFIG=PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonMulConfig
[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set (the TestHarness is not vendored)"
G="$CHIPYARD_DIR/sims/verilator/generated-src/chipyard.harness.TestHarness.$CONFIG"
[ -f "$G/sim_files.common.f" ] || die "no elaboration of $CONFIG in $CHIPYARD_DIR (scripts/62_patch_chipyard_roccmoon.sh, then make ... verilog)"
OUT="$IISWC_OUT/roccmoonmul_rtl_sim"; mkdir -p "$OUT"
R="$IISWC_ROOT/fpga/pynq-z2"
SIMARGS=(+permissive +dramsim "+dramsim_ini_dir=$CHIPYARD_DIR/generators/testchipip/src/main/resources/dramsim2_ini")
# engine revision 1, as 0x5A5A0011 was built (rtl_study/ holds revision 2a since 2026-09-17)
E="$R/src/cam_engine_rev1"
EXTRA="$E/mbxr_engine.v $E/mbxr_tseq.v $E/mbxr_datapath.v $E/mbxr_st.v $E/mbxd_dma.v $E/mbxd_spad.v $E/mbx_mac.v $R/src/pdm_mic_core.v $R/src/pdm_mic_capture.v $R/src/pdm_cic4.v $R/src/pdm_fir_mac.v $R/src/pdm_dcblock.v $R/src/pdm_mic_fifo.v"

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
fi

# sim <simulator dir> <elf> <log>: exit status of the simulator
sim () { ( set +u +e; cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1; cd "$1"
           ./simulator "${SIMARGS[@]}" +max-cycles=200000000 +permissive-off "$2" </dev/null ) > "$3" 2>&1; }

CC="$CHIPYARD_DIR/.conda-env/riscv-tools/bin/riscv64-unknown-elf-gcc"
# libgcc for lp64 (the golden's 128-bit divides) is in the Zephyr SDK's multilib, not conda's
ZCC="${ZEPHYR_SDK_INSTALL_DIR:+$ZEPHYR_SDK_INSTALL_DIR/gnu/riscv64-zephyr-elf/bin/}riscv64-zephyr-elf-gcc"
command -v "$ZCC" >/dev/null 2>&1 || die "riscv64-zephyr-elf-gcc not found -- source env.sh"
fail=0

step "1. riscv-tests rv64um-p on hart 0"
RT="${RISCV_TESTS_DIR:-$CHIPYARD_DIR/toolchains/riscv-tools/riscv-tests}"
[ -f "$RT/isa/rv64um/mul.S" ] || die "no riscv-tests source at $RT (set RISCV_TESTS_DIR)"
T="$OUT/rv64um"; mkdir -p "$T"
sed 's/TEST_RR_OP( 4,  mul, 0x00000015,/TEST_RR_OP( 4,  mul, 0x00000016,/' "$RT/isa/rv64um/mul.S" > "$T/mul_negctl.S"
cmp -s "$RT/isa/rv64um/mul.S" "$T/mul_negctl.S" && die "negative control: the corruption did not apply"
TESTS="mul mulh mulhsu mulhu mulw div divu divuw divw rem remu remuw remw"
for t in $TESTS mul_negctl; do
  src="$RT/isa/rv64um/$t.S"; [ "$t" = mul_negctl ] && src="$T/mul_negctl.S"
  "$CC" -march=rv64im_zicsr -mabi=lp64 -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
        -I"$RT/env/p" -I"$RT/isa/macros/scalar" -T"$RT/env/p/link.ld" "$src" -o "$T/rv64um-p-$t" || die "build $t"
done
for t in $TESTS mul_negctl; do sim "$OUT" "$T/rv64um-p-$t" "$T/$t.log" & done
wait
for t in $TESTS; do
  if grep -qF 'Verilog $finish' "$T/$t.log" && ! grep -qF -e '$stop' -e FAILED -e Aborting "$T/$t.log"; then info "pass  rv64um-p-$t"
  else info "FAIL  rv64um-p-$t (see $T/$t.log)"; fail=1; fi
done
if grep -qF -e '$stop' -e Aborting "$T/mul_negctl.log"; then info "pass  negative control (corrupted mul.S fails)"
else info "FAIL  negative control did not fail"; fail=1; fi

step "2. samples/pext_rtl_selftest"
S="$IISWC_ROOT/samples/pext_rtl_selftest"
"$CC" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -mno-relax -O2 -std=gnu11 -Wall -Wextra -Werror \
      -ffreestanding -fno-builtin -fno-common -fno-stack-protector -DMB_PEXT_HW=1 -I"$R/sw" \
      -nostdlib -nostartfiles -static -T "$S/link.ld" -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
      -o "$OUT/pext_rtl_selftest.elf" "$S/crt.S" "$S/main.c" -lgcc || die "build pext_rtl_selftest"
sim "$OUT" "$OUT/pext_rtl_selftest.elf" "$OUT/pext_rtl_selftest.log" || true
grep -E "^(TOTAL|PEXT_RTL_SELFTEST)" "$OUT/pext_rtl_selftest.log" | sed 's/^/    /'
grep -q "PEXT_RTL_SELFTEST: PASS" "$OUT/pext_rtl_selftest.log" || fail=1

step "3. samples/roccmoon_rtl_sim"
S="$IISWC_ROOT/samples/roccmoon_rtl_sim"
"$CC" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -mno-relax -O2 -std=gnu11 -Wall \
      -ffreestanding -fno-builtin -fno-common -fno-stack-protector -I"$R/sw/roccmoon" \
      -nostdlib -nostartfiles -static -T "$S/link.ld" -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
      -o "$OUT/roccmoon_rtl_sim.elf" "$S/crt.S" "$S/main.c" "$R/sw/roccmoon/mbxr.c" -lgcc || die "build roccmoon_rtl_sim"
sim "$OUT" "$OUT/roccmoon_rtl_sim.elf" "$OUT/roccmoon_rtl_sim.log" || true
grep -E "ROCCMOON_RTL_SIM" "$OUT/roccmoon_rtl_sim.log" | sed 's/^/    /'
grep -q "ROCCMOON_RTL_SIM: PASS" "$OUT/roccmoon_rtl_sim.log" || fail=1

step "4. encoder-dispatch golden: RTL against host C, byte for byte"
GD="$R/rtl_study/muldiv/golden"
S="$IISWC_ROOT/samples/pext_rtl_selftest"
gcc -O2 -std=gnu11 -Wall -Wno-unused-function -I"$GD" -I"$R/sw" -o "$OUT/golden_host" "$GD/golden_host.c" || die "host build"
"$OUT/golden_host" > "$OUT/golden_host.txt" || die "host golden failed"
"$ZCC" -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -mno-relax -O2 -std=gnu11 -Wall -Wno-unused-function \
       -ffreestanding -fno-builtin -fno-common -fno-stack-protector -I"$GD" -I"$R/sw" \
       -nostdlib -nostartfiles -static -T "$S/link.ld" -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
       -o "$OUT/golden.elf" "$S/crt.S" "$GD/golden_target.c" -lgcc || die "target build"
OLD="$IISWC_OUT/roccmoon_rtl_sim"
sim "$OUT" "$OUT/golden.elf" "$OUT/golden_0011.log" &
[ -x "$OLD/simulator" ] && sim "$OLD" "$OUT/golden.elf" "$OUT/golden_0010.log" &
wait || true
for v in 0011 0010; do
  [ -f "$OUT/golden_$v.log" ] || continue
  if grep -q "GOLDEN done" "$OUT/golden_$v.log" &&
     diff <(grep -E "^[DH] " "$OUT/golden_host.txt") <(grep -E "^[DH] " "$OUT/golden_$v.log") > "$OUT/golden_$v.diff"; then
    info "pass  0x5A5A$v RTL == host C: $(grep -c '^D ' "$OUT/golden_$v.log") dump lines, $(grep -E '^H ' "$OUT/golden_$v.log" | tr '\n' ' ')"
  else
    info "FAIL  0x5A5A$v golden (see $OUT/golden_$v.diff)"; [ "$v" = 0011 ] && fail=1
  fi
done
if [ -f "$OUT/golden_0010.log" ]; then
  printf '    %-16s %14s %14s %8s\n' kernel "0010 cycles" "0011 cycles" ratio
  for k in softmax_row softmax_memo2 layernorm mstress; do
    a=$(awk -v k="$k" '$1=="C" && $2==k {print $3}' "$OUT/golden_0010.log")
    b=$(awk -v k="$k" '$1=="C" && $2==k {print $3}' "$OUT/golden_0011.log")
    printf '    %-16s %14s %14s %8s\n' "$k" "$a" "$b" "$(awk -v a="$a" -v b="$b" 'BEGIN{ if (b > 0) printf "%.3f", a/b }')"
  done
fi

[ "$fail" = 0 ] || die "one or more gates failed"
step "ALL GATES PASS"
echo "ROCCMOONMUL_RTL_GATES: PASS"
