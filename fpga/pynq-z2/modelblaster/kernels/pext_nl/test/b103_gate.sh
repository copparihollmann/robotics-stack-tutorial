#!/usr/bin/env bash
# B103's pre-board gate for the two kernels MBP_B103 touches.  Host only: no board, no
# bitstream, no lock.  FOUR CHECKS, all required, and the control arm is the SHIPPED arm
# (-DMBP_B74=1 -DMBP_B87=1, out/b101_combined_0035_f40/enc_q16/kernel_cflags.txt) rather
# than the files' defaults:
#
#   1 VALUE IDENTITY over a real element count -- 47,520 add and 47,520 rope elements a
#     case, at every scale this graph dispatches plus adversarial ones -- reusing
#     b87_gate.c unchanged, so the rows it labels `b87` are this script's B103 arms.
#   2 POISON ARMS, one per new route, each of which the gate MUST reject.  A byte-for-byte
#     gate is passed perfectly by a route that never fires, so each poison perturbs exactly
#     one route VISIBLY IN THE OUTPUT: 7 the folded add store, 8 the folded rope pair value.
#   3 INSTRUCTION COUNT for both arms, on spike at the board's own flags (b103_icount.sh).
#   4 INERTNESS: with MBP_B103 unset both kernels must be OPCODE-IDENTICAL to the reference
#     tree.  Point B103_INERT_REF at the commit BEFORE B103 landed once this is committed;
#     against HEAD it degrades to a working-tree drift check, as b87_gate.sh's note says.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../../../../.." && pwd)"
KD="$here/.."
SW="$root/fpga/pynq-z2/sw"
INC="-I$SW -I$here"
w="${B103_GATE_OUT:-$(mktemp -d)}"; mkdir -p "$w"
rc_all=0

KG="$KD/pext_nl_groupnorm_s8_pext_int_rsqrt.c"
KA="$KD/pext_nl_add_s8_pext_int_add.c"
KR="$KD/pext_nl_rope_s8_pext_int_rot.c"

build () {   # build <obj> <src> <rename=sym> <cc...> -- <extra -D...>
  local o="$1" src="$2" ren="$3"; shift 3
  local cc=""
  while [ "$1" != "--" ]; do cc="$cc $1"; shift; done
  shift
  # shellcheck disable=SC2086
  $cc -Wall -Wextra -Wno-unused-parameter $INC -DMB_PEXT_HW=0 "-D${ren}" \
      -Dpgn_f2mss="pf_${ren#*=}" -Dpgn_msmul="pm_${ren#*=}" "$@" -c "$src" -o "$w/$o.o"
  objcopy --keep-global-symbol="${ren#*=}" \
          --keep-global-symbol="add_slow_ctl" --keep-global-symbol="add_n_ctl" \
          --keep-global-symbol="add_slow_b87" --keep-global-symbol="add_n_b87" \
          --keep-global-symbol="rope_slow_ctl" --keep-global-symbol="rope_n_ctl" \
          --keep-global-symbol="rope_slow_b87" --keep-global-symbol="rope_n_b87" \
          "$w/$o.o"
}

arms () {    # arms <cc...> -- <extra -D for the B103 arm only>
  local cc=""
  while [ "$1" != "--" ]; do cc="$cc $1"; shift; done
  shift
  local FA="-Dpint_add_slow_count=add_slow_ctl -Dpint_add_count=add_n_ctl"
  local FB="-Dpint_add_slow_count=add_slow_b87 -Dpint_add_count=add_n_b87"
  local FRA="-Dpint_rope_slow_count=rope_slow_ctl -Dpint_rope_count=rope_n_ctl"
  local FRB="-Dpint_rope_slow_count=rope_slow_b87 -Dpint_rope_count=rope_n_b87"
  # groupnorm is not touched by B103; both arms are the SAME build, so any mismatch the
  # gate reports on it is the flag leaking rather than a saving.
  build gctl "$KG" kernel_groupnorm_s8=gn_ctl  $cc -- -DMBP_B87=1
  build gb87 "$KG" kernel_groupnorm_s8=gn_b87  $cc -- -DMBP_B87=1
  build actl "$KA" kernel_add_s8=add_ctl       $cc -- -DMBP_B74=1 -DMBP_B87=1 $FA
  build ab87 "$KA" kernel_add_s8=add_b87       $cc -- -DMBP_B74=1 -DMBP_B87=1 -DMBP_B103=1 $FB "$@"
  build rctl "$KR" kernel_rope_s8=rope_ctl     $cc -- -DMBP_B74=1 -DMBP_B87=1 $FRA
  build rb87 "$KR" kernel_rope_s8=rope_b87     $cc -- -DMBP_B74=1 -DMBP_B87=1 -DMBP_B103=1 $FRB "$@"
}

link () {  # link <out> <cc...>
  local o="$1"; shift
  "$@" -Wall $INC "$here/b87_gate.c" "$w"/gctl.o "$w"/gb87.o "$w"/actl.o "$w"/ab87.o \
      "$w"/rctl.o "$w"/rb87.o -lm -o "$w/$o"
}

echo "=== 1  value identity, shipped (B74+B87) vs + MBP_B103 ==="
arms gcc -O2 --
link gate gcc -O2
"$w/gate" || rc_all=1

echo
echo "=== 2  poison arms (each MUST be rejected) ==="
#   7 the folded add store        8 the folded rope pair value
for p in 7 8; do
  arms gcc -O2 -- -DMBP_B103_POISON=$p
  link "gate_p$p" gcc -O2
  if "$w/gate_p$p" >"$w/p$p.txt" 2>&1; then
    echo "  poison $p: NOT REJECTED  <<< GATE IS BLIND TO THIS ROUTE"; rc_all=1
  else
    echo "  poison $p: rejected      ($(grep -o 'mismatches=[0-9]*' "$w/p$p.txt" | tail -1))"
  fi
done

echo
echo "=== 2b  the SAME elements take the exact path (FX_STATS counters) ==="
# B103 is an IDENTITY, not a widening: it must mark neither more nor fewer elements than
# the shipped test.  b87_gate.c prints both arms' counts, so a difference is a failure here
# where in B87 it was the proof of life.
arms gcc -O2 -DFX_STATS=1 --
link gate_fx gcc -O2 -DFX_STATS=1
"$w/gate_fx" > "$w/fx.txt" 2>&1 || true
grep -E 'exact_path' "$w/fx.txt" || true
if python3 - "$w/fx.txt" <<'PYEOF'
import re, sys
t = open(sys.argv[1]).read()
rows = re.findall(r'exact_path\s+(\w+)\s+ctl=(\d+)\s+b87=(\d+)', t)
ok = len(rows) == 2 and all(int(c) == int(b) for _, c, b in rows)
for nm, c, b in rows:
    print("    %-5s ctl=%s b103=%s %s" % (nm, c, b, "same" if c == b else "DIFFER"))
sys.exit(0 if ok else 1)
PYEOF
then
  echo "  band identity: PASS - both arms take the exact path on the same elements"
else
  echo "  band identity: FAIL - the folded test does not select the same elements"; rc_all=1
fi

echo
echo "=== 2c  the same arms under ASan + UBSan ==="
SAN="gcc -O1 -g -fsanitize=address,undefined"
arms $SAN --
link gate_san $SAN
"$w/gate_san" | tail -2 || rc_all=1

echo
echo "=== 3  instruction account, on spike at the board's own flags ==="
if [ "${B103_SKIP_ICOUNT:-0}" = 1 ]; then
  echo "  (skipped: B103_SKIP_ICOUNT=1)"
else
  B103_ICOUNT_OUT="$w/icount" bash "$here/b103_icount.sh" 2>&1 | grep -E '^MB_B87 ' || rc_all=1
fi

echo
INERT_REF="${B103_INERT_REF:-HEAD}"
echo "=== 4  inertness (MBP_B103 unset vs $INERT_REF$([ "$INERT_REF" = HEAD ] && echo "  -- drift check; see the note in this script")) ==="
CROSS="${CROSS_COMPILE:-riscv64-zephyr-elf-}"
command -v "${CROSS}gcc" >/dev/null 2>&1 || \
  CROSS="$root/zephyr-chipyard-sw/tools-manual/zephyr-sdk-1.0.0-beta1/gnu/riscv64-zephyr-elf/bin/riscv64-zephyr-elf-"
CF="-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany -O2 -ffreestanding
    -fno-builtin-printf -ffunction-sections -fdata-sections -falign-loops=4
    -I$SW -I$root/fpga/pynq-z2/modelblaster/check/shim -DMB_PEXT_HW=1 -DMBP_B74=1 -DMBP_B87=1"
for f in pext_nl_add_s8_pext_int_add.c pext_nl_rope_s8_pext_int_rot.c; do
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
    echo "  $f: FAIL - MBP_B103 is NOT inert when unset:"
    diff "$w/ref_$f.dis" "$w/now_$f.dis" | head -20
    rc_all=1
  fi
done

echo
echo "workdir: $w"
[ $rc_all = 0 ] && echo "MB_B103_GATE OVERALL PASS" || echo "MB_B103_GATE OVERALL FAIL"
exit $rc_all
