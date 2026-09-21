#!/usr/bin/env bash
# Build samples/pext_rtl_selftest and run it on the Verilator model of the P-ext SoC.
#
#   scripts/27_pext_rtl_sim.sh                 build the binary, build the sim if needed, run
#   scripts/27_pext_rtl_sim.sh --build-only    just produce the .elf
#   scripts/27_pext_rtl_sim.sh --sim-only      skip the compile, run what is already built
#   scripts/27_pext_rtl_sim.sh --config CFG    a different Chipyard config
#
# WHAT THIS PROVES, AND WHY IT NEEDS RTL
#
# MBP is four instructions in Rocket's ALU on hart 0 only. Two claims can only be checked
# against real RTL: that the synthesised datapath computes what fpga/pynq-z2/sw/pext.h says
# it computes, byte for byte -- including MBP.QMUL's round-half-up, which is 1 LSB on
# roughly half of all negative outputs if it is wrong -- and that the same four encodings
# raise an illegal-instruction exception on hart 1, which has neither the decode table nor
# the datapath. The second is the heterogeneity mechanism, not a degradation path, so it is
# a mandatory positive test that a trap HAPPENS. See fpga/pynq-z2/docs/PEXT_SPEC.md 7.6.
#
# NEEDS A CHIPYARD TREE. Unlike a bitstream build, this cannot run off the vendored
# generated Verilog: Verilator compiles the TestHarness, which the bundles deliberately do
# not carry (fpga/pynq-z2/chipyard/README.md, "What is in a bundle"). Set CHIPYARD_DIR.
#
# The first run compiles the Verilator model and takes tens of minutes. Later runs reuse it.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CONFIG=PynqZ2RocketBigLittlePextTacitConfig
DO_BUILD=1
DO_SIM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) DO_SIM=0; shift ;;
    --sim-only)   DO_BUILD=0; shift ;;
    --config)     CONFIG="${2:?--config needs a value}"; shift 2 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

SRC="$IISWC_ROOT/samples/pext_rtl_selftest"
OUT="$IISWC_OUT/pext_rtl_selftest"
ELF="$OUT/pext_rtl_selftest.elf"
mkdir -p "$OUT"

# ---------------------------------------------------------------- build ----
if [ "$DO_BUILD" = 1 ]; then
  step "build samples/pext_rtl_selftest"

  CC="${PEXT_CC:-}"
  if [ -z "$CC" ]; then
    # Prefer the Chipyard conda toolchain: it is the one that built the sim, and the
    # tutorial's Zephyr SDK compiler (riscv64-zephyr-elf-gcc) works equally well.
    for c in \
      "${RISCV:-}/bin/riscv64-unknown-elf-gcc" \
      "${CHIPYARD_DIR:-}/.conda-env/riscv-tools/bin/riscv64-unknown-elf-gcc" \
      riscv64-unknown-elf-gcc riscv64-zephyr-elf-gcc riscv64-linux-gnu-gcc
    do
      [ -n "$c" ] || continue
      if command -v "$c" >/dev/null 2>&1; then CC="$(command -v "$c")"; break; fi
    done
  fi
  [ -n "$CC" ] || die "no RISC-V compiler found.
    Tried \$RISCV/bin, \$CHIPYARD_DIR/.conda-env, and \$PATH.
    Point PEXT_CC at one, or source the Chipyard env:  cd \$CHIPYARD_DIR && source env.sh"
  info "cc: $CC"

  # rv64imac / lp64: the SoC is WithoutFPU, so an lp64d build would emit FP instructions
  # that take an illegal-instruction trap on BOTH harts and make the negative test
  # meaningless. -mno-relax keeps gp-relaxation from rewriting the la in crt.S before
  # __global_pointer$ is set.
  CFLAGS="-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -mno-relax
          -O2 -std=gnu11 -Wall -Wextra -Werror
          -ffreestanding -fno-builtin -fno-common -fno-stack-protector
          -DMB_PEXT_HW=1 -I$IISWC_ROOT/fpga/pynq-z2/sw"
  LDFLAGS="-nostdlib -nostartfiles -static -T $SRC/link.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments"

  # shellcheck disable=SC2086
  run "$CC" $CFLAGS $LDFLAGS -o "$ELF" "$SRC/crt.S" "$SRC/main.c" -lgcc || \
    die "compile failed"
  need_file "$ELF"

  OBJDUMP="${CC%gcc}objdump"
  if [ -x "$OBJDUMP" ]; then
    "$OBJDUMP" -d "$ELF" > "$OUT/pext_rtl_selftest.dis"
    # The four encodings must appear as raw .insn words -- no assembler knows the
    # mnemonics, so objdump prints them as ".insn 4, 0x........". Count them so a build
    # that silently fell back to the software model cannot pass unnoticed.
    n=$(grep -cE '0x[0-9a-f]{6}0b\b|\.insn' "$OUT/pext_rtl_selftest.dis" || true)
    info "custom-0 words in the disassembly: $n"
    [ "$n" -gt 0 ] || die "no custom-0 instructions in $ELF -- did MB_PEXT_HW=1 take?"
  fi
  info "elf: $ELF  ($(fsize "$ELF"))"
fi

[ "$DO_SIM" = 1 ] || exit 0

# ------------------------------------------------------------------ sim ----
step "verilator: $CONFIG"
[ -n "${CHIPYARD_DIR:-}" ] || die "CHIPYARD_DIR is not set.
    This target compiles Chipyard's simulation TestHarness, which the vendored
    generated-Verilog bundles do not carry. Point CHIPYARD_DIR at a Chipyard tree."
[ -d "$CHIPYARD_DIR" ] || die "CHIPYARD_DIR does not exist: $CHIPYARD_DIR"

SIM="$CHIPYARD_DIR/sims/verilator/simulator-chipyard.harness-$CONFIG"
if [ ! -x "$SIM" ]; then
  info "no simulator yet -- building it (tens of minutes, once)"
  # Capped rather than -j$(nproc): the machines this runs on are shared, and Verilator's
  # C++ compile will happily take every core on the box for half an hour.
  J="${PEXT_JOBS:-$(n=$(nproc); [ "$n" -gt 16 ] && echo 16 || echo "$n")}"
  # The conda hooks reference unset variables, so this subshell must not be -u.
  ( set +u +e
    cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1
    make -C sims/verilator CONFIG="$CONFIG" -j"$J" ) || die "verilator build failed"
fi
need_exec "$SIM" "run: make -C \$CHIPYARD_DIR/sims/verilator CONFIG=$CONFIG"

LOG="$OUT/sim.log"
info "log: $LOG"

# Run through Chipyard's own recipe rather than invoking the simulator by hand: SIM_FLAGS
# carries +dramsim, its ini directory and +max-cycles, and getting those wrong is a class
# of failure that looks like an RTL bug. run-binary-fast skips the per-instruction
# disassembly log, which is a large multiple of the runtime here.
set +e
( set +u +e
  cd "$CHIPYARD_DIR" && . ./env.sh >/dev/null 2>&1
  make -C sims/verilator CONFIG="$CONFIG" BINARY="$ELF" \
       TIMEOUT_CYCLES="${PEXT_MAX_CYCLES:-100000000}" run-binary-fast ) 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

echo
if grep -q "PEXT_RTL_SELFTEST: PASS" "$LOG"; then
  step "PASS"
  grep -E "^(hart 0|hart 1|TOTAL|  hart1)" "$LOG" || true
  exit 0
fi
grep -E "^FAIL" "$LOG" | head -40 || true
die "pext_rtl_selftest did not pass (make exit $rc) -- see $LOG"
