#!/usr/bin/env bash
# Build the two TACIT tools from the pinned submodules:
#   third_party/riscv-isa-sim  (+ patches/) -> the TACIT spike
#   third_party/tacit-decoder              -> ltrace-decoder
#
#   scripts/05_build_tacit_tools.sh              # build both
#   scripts/05_build_tacit_tools.sh --decoder    # decoder only (fast)
#   scripts/05_build_tacit_tools.sh --spike      # spike only (the slow one: it builds at
#                                               # -j$(nproc) -- 35 s on 48 cores, tens of
#                                               # minutes on a laptop)
#
# If TACIT_SPIKE / TACIT_DECODER already point at working binaries elsewhere, this
# script is optional -- env.sh will use whatever you export.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Apply one patch to one submodule, idempotently and without lying about it.
#
#   reverse applies cleanly  -> already in, nothing to do
#   forward applies cleanly  -> apply it
#   neither                  -> the tree is not what the patch was written against; stop,
#                               because applying half of it is worse than not building
apply_patch() {
  local dir="$1" p="$2" base; base="$(basename "$p")"
  if git -C "$dir" apply --reverse --check "$p" 2>/dev/null; then
    info "already applied: $base"
  elif git -C "$dir" apply --check "$p" 2>/dev/null; then
    info "applying $base"
    git -C "$dir" apply "$p"
  else
    die "patch neither applies nor is already applied: $p
    (revert the submodule with: git -C $dir checkout . && git -C $dir clean -fd)"
  fi
}

DO_SPIKE=1; DO_DECODER=1
case "${1-}" in
  --spike)   DO_DECODER=0 ;;
  --decoder) DO_SPIKE=0 ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

SIM_DIR="$IISWC_ROOT/third_party/riscv-isa-sim"
DEC_DIR="$IISWC_ROOT/third_party/tacit-decoder"

if [ "$DO_SPIKE" = 1 ]; then
  step "TACIT spike: apply patches"
  [ -d "$SIM_DIR/riscv" ] || die "submodule not checked out: $SIM_DIR"

  # The pin (0ee3058d, riscv-tacit/l_trace) predates two things a Zephyr guest needs: the
  # MMIO re-map (0001) and the MBP packed-SIMD instructions (0006).
  #
  # Idempotency is per patch, not per tree: `git apply --reverse --check` succeeding means
  # that patch is already in, which is the only test that stays correct as patches are
  # added. (It replaced a single "does riscv/trace_encoder_mmio.h exist?" probe, which
  # gated ALL spike patches on the first one and so silently skipped every later one.)
  for p in "$IISWC_ROOT"/patches/*-spike-*.patch; do
    [ -e "$p" ] || continue
    apply_patch "$SIM_DIR" "$p"
  done

  step "TACIT spike: configure + build  (this is the slow one)"
  mkdir -p "$SIM_DIR/build"
  if [ ! -f "$SIM_DIR/build/Makefile" ]; then
    ( cd "$SIM_DIR/build" && ../configure --prefix="$SIM_DIR/install" )
  fi
  ( cd "$SIM_DIR/build" && make -j"$(nproc)" )
  need_exec "$SIM_DIR/build/spike" "spike build produced no binary"
  info "spike -> $SIM_DIR/build/spike"
fi

if [ "$DO_DECODER" = 1 ]; then
  step "TACIT decoder: apply patches"
  [ -f "$DEC_DIR/Cargo.toml" ] || die "submodule not checked out: $DEC_DIR"

  # The pin (34e54441, ucb-bar/misc_decoders) parses the sync and trap packets that
  # SPIKE's trace_encoder_l emits. The RTL encoder in generators/tacit emits an older,
  # shorter layout, so a trace captured off the FPGA is unreadable without this. The
  # patch adds `--encoder rtl` and leaves the spike path (the default) untouched.
  # 0007 names the MBP packed-SIMD ops instead of printing `unknown`, and 0010 adds
  # `--trace FILE:HART:LABEL` so a multi-hart capture decodes into ONE Perfetto file
  # with a named track per hart. All three leave the single-trace output byte-identical.
  # Same per-patch idempotency as the spike side above.
  for p in "$IISWC_ROOT"/patches/*-decoder-*.patch; do
    [ -e "$p" ] || continue
    apply_patch "$DEC_DIR" "$p"
  done

  step "TACIT decoder: cargo build --release"
  command -v cargo >/dev/null 2>&1 || die "cargo not found -- install a Rust toolchain (https://rustup.rs)"
  ( cd "$DEC_DIR" && cargo build --release )
  need_exec "$DEC_DIR/target/release/ltrace-decoder" "decoder build produced no binary"
  info "decoder -> $DEC_DIR/target/release/ltrace-decoder"
fi

step "TACIT tools ready"
info "verify with: scripts/01_doctor.sh"
