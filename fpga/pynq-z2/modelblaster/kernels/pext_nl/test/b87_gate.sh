#!/usr/bin/env bash
# B87's pre-board gate for the three kernels MBP_B87 touches.  Host only: no board, no
# bitstream, no lock.  FOUR CHECKS, all of them required (L8622: the provenance layers are
# three and none is sufficient alone; the gate's own layers are four and the same rule
# applies):
#
#   1 VALUE IDENTITY over a real element count -- 287,712 groupnorm elements a case,
#     47,520 add, 47,520 rope, at every scale this graph dispatches plus adversarial ones.
#   2 POISON ARMS, one per new route, each of which the gate MUST reject.  A byte-for-byte
#     gate is passed perfectly by a route that never fires (B66 found its first guard
#     testing the wrong branch while passing all 6,462 comparisons), so each poison
#     perturbs exactly one route, VISIBLY IN THE OUTPUT -- not merely in an intermediate,
#     which is the mistake B74's first poison made.
#   3 INSTRUCTION COUNT for both arms, on spike at the board's own flags (b87_icount.sh).
#   4 INERTNESS: with MBP_B87 unset every one of the three kernels must be OPCODE-IDENTICAL
#     to the pre-B87 tree.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
KD="$here/.."
SW="$root/fpga/pynq-z2/sw"
INC="-I$SW -I$here"
w="${B87_GATE_OUT:-$(mktemp -d)}"; mkdir -p "$w"
rc_all=0

KG="$KD/pext_nl_groupnorm_s8_pext_int_rsqrt.c"
KA="$KD/pext_nl_add_s8_pext_int_add.c"
KR="$KD/pext_nl_rope_s8_pext_int_rot.c"

# The control arm is the HEADLINE arm: the shipped encoder runs -DMBP_B74=1.
build () {   # build <obj> <src> <rename=sym> <cc...> -- <extra -D...>
  local o="$1" src="$2" ren="$3"; shift 3
  local cc=""
  while [ "$1" != "--" ]; do cc="$cc $1"; shift; done
  shift
  # shellcheck disable=SC2086
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 "-D${ren}" \
      -Dpgn_f2mss="pf_${ren#*=}" -Dpgn_msmul="pm_${ren#*=}" "$@" -c "$src" -o "$w/$o.o"
  # int_nonlin.c defines non-static globals and both groupnorm arms include it, so the
  # objects would collide at link.  Keep ONE global per object -- the renamed entry --
  # and localise the rest.  Exact, unlike --allow-multiple-definition.
  objcopy --keep-global-symbol="${ren#*=}" \
          --keep-global-symbol="add_slow_ctl" --keep-global-symbol="add_n_ctl" \
          --keep-global-symbol="add_slow_b87" --keep-global-symbol="add_n_b87" \
          --keep-global-symbol="rope_slow_ctl" --keep-global-symbol="rope_n_ctl" \
          --keep-global-symbol="rope_slow_b87" --keep-global-symbol="rope_n_b87" \
          "$w/$o.o"
}

arms () {    # arms <cc...> -- <extra -D for BOTH arms>
  local cc=""
  while [ "$1" != "--" ]; do cc="$cc $1"; shift; done
  shift
  # FX_STATS' counters are non-static globals that BOTH arms define, so they are renamed
  # per arm -- the gate reads all four and compares them.
  local FA="-Dpint_add_slow_count=add_slow_ctl -Dpint_add_count=add_n_ctl"
  local FB="-Dpint_add_slow_count=add_slow_b87 -Dpint_add_count=add_n_b87"
  local FRA="-Dpint_rope_slow_count=rope_slow_ctl -Dpint_rope_count=rope_n_ctl"
  local FRB="-Dpint_rope_slow_count=rope_slow_b87 -Dpint_rope_count=rope_n_b87"
  build gctl "$KG" kernel_groupnorm_s8=gn_ctl  $cc -- "$@"
  build gb87 "$KG" kernel_groupnorm_s8=gn_b87  $cc -- -DMBP_B87=1 "$@"
  build actl "$KA" kernel_add_s8=add_ctl       $cc -- -DMBP_B74=1 $FA "$@"
  build ab87 "$KA" kernel_add_s8=add_b87       $cc -- -DMBP_B74=1 -DMBP_B87=1 $FB "$@"
  build rctl "$KR" kernel_rope_s8=rope_ctl     $cc -- -DMBP_B74=1 $FRA "$@"
  build rb87 "$KR" kernel_rope_s8=rope_b87     $cc -- -DMBP_B74=1 -DMBP_B87=1 $FRB "$@"
}

echo "=== 1  value identity, shipped vs MBP_B87 ==="
arms gcc -O2 --
gcc -O2 -Wall $INC "$here/b87_gate.c" "$w"/gctl.o "$w"/gb87.o "$w"/actl.o "$w"/ab87.o \
    "$w"/rctl.o "$w"/rb87.o -lm -o "$w/gate"
"$w/gate" || rc_all=1

echo
echo "=== 2  poison arms (each MUST be rejected) ==="
#   1 groupnorm DOT8 reduction   2 groupnorm hoisted LUT build   3 groupnorm unrolled apply
#   4 add unrolled store         5 rope pass-through table       6 rope hoisted G
for p in 1 2 3 4 5; do
  arms gcc -O2 -- -DMBP_B87_POISON=$p
  gcc -O2 -Wall $INC "$here/b87_gate.c" "$w"/gctl.o "$w"/gb87.o "$w"/actl.o "$w"/ab87.o \
      "$w"/rctl.o "$w"/rb87.o -lm -o "$w/gate_p$p"
  if "$w/gate_p$p" >"$w/p$p.txt" 2>&1; then
    echo "  poison $p: NOT REJECTED  <<< GATE IS BLIND TO THIS ROUTE"; rc_all=1
  else
    echo "  poison $p: rejected      ($(grep -o 'mismatches=[0-9]*' "$w/p$p.txt" | tail -1))"
  fi
done

echo
echo "=== 2b  poison 6, the hoisted G -- scored on a COUNTER, not on bytes ==="
# rope_s8's hoisted G is OUTPUT-NEUTRAL BY CONSTRUCTION: both sides of the tie band return
# the reference, so widening or narrowing the band moves no byte and NO byte poison can
# prove the route live.  (B74's first poison failed for the analogous reason.)  So the
# liveness proof is the exact-path COUNT: with the poison it must reach 100 %, and without
# it the B87 arm's count must be STRICTLY LARGER than the control's -- which is only
# possible if the hoisted, wider G is the one the pair loop reads.
fx () {   # fx <suffix> <extra -D...>
  local sfx="$1"; shift
  arms gcc -O2 -- -DFX_STATS=1 "$@"
  gcc -O2 -Wall $INC -DFX_STATS=1 "$here/b87_gate.c" "$w"/gctl.o "$w"/gb87.o "$w"/actl.o \
      "$w"/ab87.o "$w"/rctl.o "$w"/rb87.o -lm -o "$w/gate_fx$sfx"
  "$w/gate_fx$sfx" > "$w/fx$sfx.txt" 2>&1 || true
  grep -E 'exact_path|MB_B87_GATE cases' "$w/fx$sfx.txt"
}
fx _plain
fx _p6 -DMBP_B87_POISON=6
pat='s/.*exact_path rope ctl=\([0-9]*\) b87=\([0-9]*\) of \([0-9]*\) rotated \([0-9]*\).*/\1 \2 \3 \4/p'
read -r rc rb rn _ <<<"$(sed -n "$pat" "$w/fx_plain.txt")"
read -r _ p6b _ p6r <<<"$(sed -n "$pat" "$w/fx_p6.txt")"
if [ "${rb:-0}" -gt "${rc:-0}" ]; then
  echo "  liveness: PASS - the band widened, $rc -> $rb exact of $rn, and no byte moved"
else
  echo "  liveness: FAIL - the B87 exact-path count did not grow ($rc -> $rb)"; rc_all=1
fi
if [ "${p6b:-0}" = "${p6r:-1}" ]; then
  echo "  poison 6: rejected      (g = half drove all $p6b of $p6r rotated elements exact)"
else
  echo "  poison 6: NOT REJECTED  <<< the hoisted G is not the one the pair loop reads"
  rc_all=1
fi

echo
echo "=== 2c  the same arms under ASan + UBSan ==="
SAN="gcc -O1 -g -fsanitize=address,undefined"
arms $SAN --
$SAN -Wall $INC "$here/b87_gate.c" "$w"/gctl.o "$w"/gb87.o "$w"/actl.o "$w"/ab87.o \
    "$w"/rctl.o "$w"/rb87.o -lm -o "$w/gate_san"
"$w/gate_san" | tail -2 || rc_all=1

echo
echo "=== 3  instruction account, on spike at the board's own flags ==="
if [ "${B87_SKIP_ICOUNT:-0}" = 1 ]; then
  echo "  (skipped: B87_SKIP_ICOUNT=1)"
else
  B87_ICOUNT_OUT="$w/icount" bash "$here/b87_icount.sh" 2>&1 | grep -E '^MB_B87 ' || rc_all=1
fi

# === 4  INERTNESS =========================================================================
# READ THIS BEFORE TRUSTING THE LINE IT PRINTS.  Against a tree that PREDATES B87 this is a
# real proof that the define ships inert.  Once B87 is COMMITTED, HEAD contains it too and
# this degrades to a working-tree-vs-HEAD drift check.  To redo the real one, point at the
# commit before B87 landed:  B87_INERT_REF=<sha> b87_gate.sh
echo
INERT_REF="${B87_INERT_REF:-HEAD}"
echo "=== 4  inertness (MBP_B87 unset vs $INERT_REF$([ "$INERT_REF" = HEAD ] && echo "  -- drift check; see the note in this script")) ==="
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
CF="-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -ffunction-sections -fdata-sections -falign-loops=4
    -I$SW -I$root/fpga/pynq-z2/modelblaster/check/shim -DMB_PEXT_HW=1 -DMBP_B74=1"
for f in pext_nl_groupnorm_s8_pext_int_rsqrt.c pext_nl_add_s8_pext_int_add.c \
         pext_nl_rope_s8_pext_int_rot.c; do
  rel="fpga/pynq-z2/modelblaster/kernels/pext_nl/$f"
  if ! git -C "$root" show "$INERT_REF:$rel" > "$w/ref_$f" 2>/dev/null; then
    echo "  $f: (not in $INERT_REF; skipped)"; continue
  fi
  # shellcheck disable=SC2086
  "${CROSS}gcc" $CF -c "$w/ref_$f" -o "$w/ref_$f.o"
  # shellcheck disable=SC2086
  "${CROSS}gcc" $CF -c "$KD/$f" -o "$w/now_$f.o"
  for s in ref now; do
    "${CROSS}objdump" -d "$w/${s}_$f.o" | tail -n +3 | sed 's/^ *[0-9a-f]*://' \
      | sed 's/\t[0-9a-f ]*\t/\t/' > "$w/${s}_$f.dis"
  done
  n=$(grep -cE $'\t' "$w/ref_$f.dis" || true)
  if diff -q "$w/ref_$f.dis" "$w/now_$f.dis" >/dev/null; then
    echo "  $f: PASS - opcode-identical, $n instructions emitted in each"
  else
    echo "  $f: FAIL - MBP_B87 is NOT inert when unset:"
    diff "$w/ref_$f.dis" "$w/now_$f.dis" | head -20
    rc_all=1
  fi
done

echo
echo "workdir: $w"
[ $rc_all = 0 ] && echo "MB_B87_GATE OVERALL PASS" || echo "MB_B87_GATE OVERALL FAIL"
exit $rc_all
