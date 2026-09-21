#!/usr/bin/env bash
# Lab B102.  The cross-hart ordering gate: ON plus both poison arms, and the build that must
# REFUSE to compile.  No board and no Verilator -- this is the one piece of B102 that can be
# falsified today.
#
#   fpga/pynq-z2/modelblaster/check/b102_order_gate.sh
#
# A green ON arm ALONE is not evidence: it is also what a dead path produces.  The gate exits 0
# only if ON is byte-identical AND was exercised, AND each poison changed the result on every
# shape where it had a measured opportunity, AND the MBP_B102=0 build refuses.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$HERE/../../sw"
B="${B102_BUILD:-${TMPDIR:-/tmp}/b102_gate.$$}"
mkdir -p "$B"; trap 'rm -rf "$B"' EXIT
CC="${CC:-cc}"
rc=0

echo "== the guard: MBP_B102 off must not build =="
if "$CC" -O2 -std=gnu11 -pthread -D_GNU_SOURCE -I "$SW" \
        "$HERE/b102_pipeline_order.c" -o "$B/off" 2>"$B/off.log"; then
  echo "  FAIL: it built with MBP_B102=0 -- an arm named for a configuration must assert it"; rc=1
else
  grep -q 'build this check with -DMBP_B102=1' "$B/off.log" \
    && echo "  ok: refused, with the right #error" \
    || { echo "  FAIL: it refused for some OTHER reason:"; head -3 "$B/off.log"; rc=1; }
fi

for arm in "on:" "pois1:-DMBP_B102_POISON=1" "pois2:-DMBP_B102_POISON=2"; do
  n="${arm%%:*}"; f="${arm#*:}"
  echo "== arm $n =="
  # shellcheck disable=SC2086
  "$CC" -O2 -std=gnu11 -pthread -D_GNU_SOURCE -DMBP_B102=1 -DMBXR_RT_STAGE_BLOCK=1 $f -I "$SW" \
       "$HERE/b102_pipeline_order.c" -o "$B/$n" 2>"$B/$n.log" || {
    echo "  FAIL: build"; head -5 "$B/$n.log"; rc=1; continue; }
  "$B/$n" | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || rc=1
done

[ $rc = 0 ] && echo "B102_GATE_OK" || echo "B102_GATE_FAIL"
exit $rc
