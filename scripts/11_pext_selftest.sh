#!/usr/bin/env bash
# Lab A2 -- prove the MBP packed-SIMD instructions on Spike, and count them.
#
# samples/pext_selftest is one source file. This builds it three ways and checks that all
# three agree byte for byte:
#
#   hw   MB_PEXT_HW=1, spike_riscv64, run on the patched TACIT spike   <- the instructions
#   sw   MB_PEXT_HW=0, spike_riscv64, run on the same spike            <- the C model
#   host MB_PEXT_HW=0, the build host's cc                             <- the C model again,
#                                                                         different compiler,
#                                                                         different ISA
#
# If the Spike implementation and fpga/pynq-z2/sw/pext.h ever disagree, two things happen:
# the hw binary prints MISMATCH with the exact operands (it computes every case both ways
# internally), and the hw/sw console logs diverge. Either is a hard failure here.
#
# It also reports the minstret delta over the counted kernel in each Zephyr build, which
# is the instruction-count saving from the extension -- measured on the same simulator
# that produced the projections in fpga/pynq-z2/docs/PEXT_SPEC.md section 5.
#
# Usage:
#   scripts/11_pext_selftest.sh
#   scripts/11_pext_selftest.sh --name X
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

NAME="pext_selftest"
SAMPLE="$IISWC_ROOT/samples/pext_selftest"
BOARD="spike_riscv64"
while [ $# -gt 0 ]; do
  case "$1" in
    --name)   NAME="${2:?}";   shift 2 ;;
    --sample) SAMPLE="${2:?}"; shift 2 ;;
    --board)  BOARD="${2:?}";  shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_exec "$TACIT_SPIKE" "run scripts/05_build_tacit_tools.sh, or export TACIT_SPIKE"
command -v west >/dev/null 2>&1 || die "west not on PATH -- run scripts/00_bootstrap.sh"
[ -d "$SAMPLE" ] || die "no such sample: $SAMPLE"

RUN="$IISWC_OUT/$NAME"
rm -rf "$RUN"; mkdir -p "$RUN"

# The lines the three builds must agree on. `start hw=` names the build and the INSTRET
# line is the measurement, so both are reported rather than diffed.
RESULTS_RE='^(DOT8 |MAX8 |RELU8|QMUL |CLIP8|RQ   |MISMATCH|PEXT_SELFTEST (kernel|done|PASS|FAIL))'

step "1/4  host reference  (MB_PEXT_HW=0, $(command -v cc || echo cc))"
run cc -O2 -Wall -Wextra -Werror -DMB_PEXT_HW=0 -DPEXT_VERBOSE=1 \
  -I "$IISWC_ROOT/fpga/pynq-z2/sw" \
  -o "$RUN/pext_host" "$SAMPLE/src/main.c" || die "host reference failed to build"
"$RUN/pext_host" > "$RUN/host.raw" || true
grep -E "$RESULTS_RE" "$RUN/host.raw" > "$RUN/host.txt"
info "$(wc -l < "$RUN/host.txt") result lines"

for HW in 1 0; do
  case "$HW" in 1) TAG=hw ;; 0) TAG=sw ;; esac
  step "2/4  build + run  $TAG  (MB_PEXT_HW=$HW, $BOARD)"
  run west build -p always -b "$BOARD" "$SAMPLE" -d "$RUN/build_$TAG" \
    -- -DMB_PEXT_HW=$HW -DPEXT_VERBOSE=1 \
    > "$RUN/build_$TAG.log" 2>&1 \
    || { tail -30 "$RUN/build_$TAG.log"; die "build failed -- log at $RUN/build_$TAG.log"; }
  cp "$RUN/build_$TAG/zephyr/zephyr.elf" "$RUN/zephyr_$TAG.elf"

  # No --trace=l here. This run is about arithmetic and instruction counts, and the
  # L-encoder would write a 5 GB tacit.debug for an 80 M instruction verbose run. The
  # TACIT path is exercised on the quiet build by scripts/10_tacit_hello.sh; the guest's
  # writes to the encoder MMIO block are absorbed when no encoder exists.
  mkdir -p "$RUN/spike_$TAG"
  ( cd "$RUN/spike_$TAG" && run "$TACIT_SPIKE" "$RUN/zephyr_$TAG.elf" ) \
    > "$RUN/$TAG.raw" 2>&1 || { tail -20 "$RUN/$TAG.raw"; die "spike failed -- log at $RUN/$TAG.raw"; }
  # The Zephyr console ends every line with CRLF and the host's stdout does not, so the
  # CR has to go before anything is diffed against the host reference.
  tr -d '\r' < "$RUN/$TAG.raw" | grep -E "$RESULTS_RE" > "$RUN/$TAG.txt" || true
  [ -s "$RUN/$TAG.txt" ] || { tail -20 "$RUN/$TAG.raw"; die "$TAG build produced no results"; }
  info "$(wc -l < "$RUN/$TAG.txt") result lines   $(grep -c MISMATCH "$RUN/$TAG.txt" || true) mismatch lines"
done

step "3/4  compare"
FAIL=0
for TAG in hw sw; do
  if grep -q 'PEXT_SELFTEST PASS' "$RUN/$TAG.txt"; then
    info "ok    $TAG: self-check PASS  ($(grep -m1 'PEXT_SELFTEST done' "$RUN/$TAG.txt"))"
  else
    printf '    \033[1;31mFAIL\033[0m  %s: self-check did not pass\n' "$TAG"
    grep -m5 MISMATCH "$RUN/$TAG.txt" | sed 's/^/          /' || true
    FAIL=1
  fi
done
for PAIR in "hw sw" "hw host"; do
  set -- $PAIR
  if diff -u "$RUN/$2.txt" "$RUN/$1.txt" > "$RUN/diff_$1_vs_$2.txt"; then
    info "ok    $1 == $2  (all $(wc -l < "$RUN/$1.txt") result lines identical)"
  else
    printf '    \033[1;31mFAIL\033[0m  %s differs from %s:\n' "$1" "$2"
    head -30 "$RUN/diff_$1_vs_$2.txt" | sed 's/^/          /'
    FAIL=1
  fi
done

step "4/4  instruction counts  (minstret, over the counted kernel)"
for TAG in hw sw; do
  LINE=$(tr -d '\r' < "$RUN/$TAG.raw" | grep -m1 '^PEXT_SELFTEST_INSTRET ' || true)
  [ -n "$LINE" ] || { warn "$TAG: no minstret line -- instruction counting is broken"; FAIL=1; continue; }
  PROBE=$(sed -n 's/.*probe=\([0-9]*\).*/\1/p' <<<"$LINE")
  KERN=$(sed -n 's/.*kernel=\([0-9]*\).*/\1/p' <<<"$LINE" | sed 's/^0*//')
  TOTAL=$(sed -n 's/.*total=\([0-9]*\).*/\1/p' <<<"$LINE" | sed 's/^0*//')
  [ "${PROBE:-0}" -gt 0 ] 2>/dev/null \
    || { warn "$TAG: minstret probe read $PROBE over 4 nops -- the counter is stuck"; FAIL=1; }
  eval "INSTRET_$TAG=${KERN:-0}"
  info "$TAG: minstret probe=$PROBE (4 nops + 2 csrr)   kernel=${KERN:-0} instructions   whole run=${TOTAL:-0}"
done
if [ "${INSTRET_hw:-0}" -gt 0 ] && [ "${INSTRET_sw:-0}" -gt 0 ]; then
  info "speedup (instructions): $(awk "BEGIN{printf \"%.2fx\", $INSTRET_sw/$INSTRET_hw}")  \
($INSTRET_sw software-model instructions -> $INSTRET_hw with MBP)"
fi

cat > "$RUN/run.json" <<JSON
{
  "name": "$NAME",
  "generated": "$(date -Is)",
  "sample": "$SAMPLE",
  "board": "$BOARD",
  "pins": {
    "zephyr-chipyard-sw": "$(git -C "$ZCS" rev-parse HEAD 2>/dev/null)",
    "riscv-isa-sim": "$(git -C "$IISWC_ROOT/third_party/riscv-isa-sim" rev-parse HEAD 2>/dev/null)"
  },
  "results": {
    "result_lines": $(wc -l < "$RUN/hw.txt"),
    "hw_matches_sw": $( [ -s "$RUN/diff_hw_vs_sw.txt" ] && echo false || echo true ),
    "hw_matches_host": $( [ -s "$RUN/diff_hw_vs_host.txt" ] && echo false || echo true ),
    "mismatches": $(grep -c MISMATCH "$RUN/hw.txt" || true),
    "kernel_instret_hw": ${INSTRET_hw:-0},
    "kernel_instret_sw": ${INSTRET_sw:-0}
  }
}
JSON
cat "$RUN/run.json"

if [ "$FAIL" -ne 0 ]; then
  printf '\n    \033[1;31mFAIL\033[0m  see %s\n' "$RUN"
  exit 1
fi
step "Done"
printf '    \033[1;32mPASS\033[0m  Spike matches fpga/pynq-z2/sw/pext.h on all %s cases\n' \
  "$(sed -n 's/.*cases=\([0-9]*\).*/\1/p' "$RUN/hw.txt" | head -1)"
