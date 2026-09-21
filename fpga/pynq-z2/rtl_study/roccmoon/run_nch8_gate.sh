#!/usr/bin/env bash
# THE GATE THAT MUST PASS BEFORE PLACE-AND-ROUTE, NOT AFTER IT.
#
#   fpga/pynq-z2/rtl_study/roccmoon/run_nch8_gate.sh [snapshot-dir]
#
# WHY IT EXISTS, AND WHY IT NOW HAS FOUR ARMS.
#
# 0x5A5A0033 is why there is a gate at all: three sessions of area and timing arithmetic and one
# six-hour place-and-route produced an NCH = 8 bitstream that closed at +0.208, booted, passed its
# feature gate -- and computed every output channel n % 8 == 7 as zero, because `pport` was three
# bits and plane 7's port index (8) wrapped to 0.  The first version of this script found that in
# under three minutes.
#
# 0x5A5A0034 is why one arm was not enough.  It PASSED that gate -- 119 cases, every output byte
# equal to kernel_linear_s8 -- and then spent 84 % of a board session in an attention fallback,
# because mbxa_unit.v:248 validates `{qs,2'd0} >= nsc`, i.e. qs * 4, a BAKED-IN NCH = 4 in the one
# module B96 had parameterised for NCH.  The bench could not have caught it: tb_mbxr's cases are
# linear_s8-shaped and the attention lane is not in it.  A gate that covers one of three dispatch
# kinds is not a gate.
#
# THE FOUR ARMS, each a kind of dispatch the runtime can actually issue:
#   engine NCH=8   linear_s8 / conv2d_s8 must COMPUTE RIGHT          tb_mbxr
#   engine NCH=4   ... and must not REGRESS the shipping machine     tb_mbxr, exact Gets/Puts/cycles
#   attention      mbxa_unit against the curated kernels             tb_attn, at BOTH widths
#   lanes          LN + LUT dispatch through mbxr_lanes into mbxr_st tb_lutint, at BOTH widths
#
# The NCH = 4 engine arm is exact rather than a range for compat/run_compat_tb.sh's reason: a
# change to a shared engine file that moves the shipping machine at all has changed silicon in the
# field.  The other arms are pass/fail: they are checking arithmetic, not a cycle budget.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${1:-$HERE/../../src/lanes_engine_b98nch8}"
SW="$HERE/../../sw/roccmoon"
MB="$HERE/../../modelblaster"
V="${VERILATOR:-verilator}"
B="${GATE_BUILD:-${TMPDIR:-/tmp}/nch8_gate.$$}"
KEEP="${GATE_KEEP:-0}"
trap '[ "$KEEP" = 1 ] || rm -rf "$B"' EXIT
J="${J:-8}"

WANT_4_GETS=1132401; WANT_4_PUTS=122186; WANT_4_CYC=64529872; WANT_CASES=119

[ -f "$SNAP/MD5SUMS" ] || { echo "GATE FAIL: no $SNAP/MD5SUMS"; exit 1; }
( cd "$SNAP" && md5sum -c --quiet MD5SUMS ) \
  || { echo "GATE FAIL: $SNAP does not match its own MD5SUMS"; exit 1; }
echo "snapshot $SNAP matches MD5SUMS"
mkdir -p "$B"
rc=0

ENGINE_RTL=("$SNAP"/mbxr_engine.v "$SNAP"/mbxr_lanes.v "$SNAP"/mbxa_unit.v "$SNAP"/mbxa_rq.v
            "$SNAP"/mbxr_smx.v "$SNAP"/mbxr_ln.v "$SNAP"/mbxl_lut.v "$SNAP"/mbxr_st.v
            "$SNAP"/mbxr_tseq.v "$SNAP"/mbxr_datapath.v "$SNAP"/mbxd_spad2.v "$SNAP"/mbxd_dma.v
            "$SNAP"/mbx_mac.v)

build_engine () {   # $1 = NCH, $2 = tb .cpp, $3 = objdir
  "$V" --cc "${ENGINE_RTL[@]}" +define+MBXR_BEHAVIOURAL --top-module mbxr_engine -GNCH="$1" \
       --exe "$2" "$HERE/mbxr_drv_tb.cpp" -Wno-fatal --Mdir "$3" -O2 \
       -CFLAGS "-O2 -DMBXR_TB_REV2 -DMBXR_NCH=$1 -I$SW" --build -j "$J" > "$3/build.log" 2>&1
}

# ---- arm 1/2: the engine, both widths -------------------------------------------------------
for n in 8 4; do
  d="$B/eng$n"; mkdir -p "$d"
  build_engine "$n" "$HERE/tb_mbxr.cpp" "$d" \
    || { echo "engine NCH=$n  FAIL (verilator build)"; tail -20 "$d/build.log"; rc=1; continue; }
  "$d/Vmbxr_engine" --quick > "$d/run.log" 2>&1 || true
  if [ "$n" = 8 ]; then
    if grep -q "^MBXR_TB_OK $WANT_CASES cases" "$d/run.log"; then
      echo "engine NCH=8  PASS  $(grep -m1 '^MBXR_TB_OK' "$d/run.log")"
    else
      echo "engine NCH=8  FAIL  $(tail -1 "$d/run.log")"
      grep -m3 'RMB_ID_BAD' "$d/run.log" || true
      echo "  The widened array does not compute.  DO NOT place and route this snapshot."; rc=1
    fi
  else
    read -r g p c < <(sed -nE 's/^TileLink: ([0-9]+) Gets, ([0-9]+) Puts, [0-9]+ protocol errors, ([0-9]+) cycles.*/\1 \2 \3/p' "$d/run.log")
    if grep -q "^MBXR_TB_OK $WANT_CASES cases" "$d/run.log" \
       && [ "${g:-}" = "$WANT_4_GETS" ] && [ "${p:-}" = "$WANT_4_PUTS" ] && [ "${c:-}" = "$WANT_4_CYC" ]; then
      echo "engine NCH=4  PASS  $g Gets, $p Puts, $c cycles -- identical to the shipping machine"
    else
      echo "engine NCH=4  FAIL  got ${g:-<none>}/${p:-<none>}/${c:-<none>}, want $WANT_4_GETS/$WANT_4_PUTS/$WANT_4_CYC"
      echo "  $(tail -1 "$d/run.log")"
      echo "  This snapshot moves 0x5A5A0032's silicon.  DO NOT place and route it."; rc=1
    fi
  fi
done

# ---- arm 3: the ATTENTION lane, both widths -------------------------------------------------
# mbxa_unit against attn_golden (kernel_matmul_b_s8 / kernel_softmax_s8 / kernel_matmul_b_s8).
# THE ARM 0x5A5A0034 NEEDED.  It fails in about two minutes on a snapshot whose quad-to-score
# arithmetic assumes four finals per quad.
#
# -DMBXA_NCH=$n IS NOT OPTIONAL AND THE FIRST VERSION OF THIS ARM OMITTED IT.  The bench builds
# the weight image; the RTL consumes it.  Setting -GNCH on the hardware and leaving the bench at
# its default of four is the SAME guest/silicon width mismatch this whole gate exists to catch,
# committed inside the gate -- it reported the fixed snapshot as broken with the pre-fix byte
# counts to the digit.  Both halves take the width or neither does.
if [ -f "$HERE/attn_unit/tb_attn.cpp" ]; then
  ( cd "$MB" && cc -O2 -std=gnu11 -ffp-contract=off -Ikernels/pext_nl -I../sw \
      -c "$HERE/attn_unit/attn_golden.c" -o "$B/attn_golden.o" ) 2>/dev/null \
    || { echo "attention     FAIL (golden would not compile)"; rc=1; }
  for n in 8 4; do
    d="$B/attn$n"; mkdir -p "$d"
    "$V" --cc --exe --build -j "$J" -O3 -Wno-fatal -DMBXR_BEHAVIOURAL -GNCH="$n" \
         --Mdir "$d" --top-module mbxa_unit -CFLAGS "-O2 -DMBXA_NCH=$n" \
         "$SNAP/mbxa_rq.v" "$SNAP/mbxa_unit.v" "$HERE/smx_lane/mbxr_smx.v" \
         "$HERE/mbxr_datapath.v" "$HERE/../rocc/mbx_mac.v" \
         "$HERE/attn_unit/tb_attn.cpp" "$B/attn_golden.o" -o Vattn > "$d/build.log" 2>&1 \
      || { echo "attention NCH=$n  FAIL (verilator build)"; tail -12 "$d/build.log"; rc=1; continue; }
    "$d/Vattn" --quick > "$d/run.log" 2>&1 || true
    if grep -q '^ATTN_TB_OK' "$d/run.log"; then
      echo "attention NCH=$n  PASS  $(grep -m1 '^ATTN_TB_OK' "$d/run.log" | cut -c1-96)"
    else
      echo "attention NCH=$n  FAIL  $(grep -m1 '^ATTN_TB_FAILED' "$d/run.log" | cut -c1-96)"
      [ "$n" = 8 ] && echo "  The attention lane refuses or miscomputes at NCH = 8.  A fused-attention" \
                   && echo "  graph will fall back to software on EVERY dispatch with max_abs_err = 0."
      rc=1
    fi
  done
else
  echo "attention     SKIP (attn_unit/tb_attn.cpp not present)"
fi

# ---- arm 4: the LN and LUT lane dispatchers, both widths -------------------------------------
# tb_lutint drives a lane THROUGH mbxr_lanes INTO mbxr_st -- the integration a lane's own unit
# bench does not cover, and the one 0x5A5A002C hung in.
for n in 8 4; do
  d="$B/lanes$n"; mkdir -p "$d"
  build_engine "$n" "$HERE/lut_lane/tb_lutint.cpp" "$d" \
    || { echo "lanes NCH=$n  FAIL (verilator build)"; tail -12 "$d/build.log"; rc=1; continue; }
  ok=1
  for mode in --lut --lanes; do
    "$d/Vmbxr_engine" "$mode" > "$d/run$mode.log" 2>&1 || true
    case "$(tail -1 "$d/run$mode.log")" in MBXR_LUT_OK*|MBXR_LANES_OK*) ;; *) ok=0 ;; esac
  done
  if [ "$ok" = 1 ]; then echo "lanes NCH=$n  PASS  $(tail -1 "$d/run--lanes.log" | cut -c1-80)"
  else echo "lanes NCH=$n  FAIL  $(tail -1 "$d/run--lanes.log" | cut -c1-96)"; rc=1; fi
done

# ---- arm 5: THE GUEST KERNEL ITSELF, which arms 1-4 never compile or execute ------------------
# TWO HOLES, BOTH FOUND THE HARD WAY ON 0x5A5A0035 AND BOTH OF THIS GATE'S OWN SHAPE:
#
#  (a) THE HOST-C GOLDEN.  Arms 1-4 build tb_attn, kstage.inc and the snapshot RTL.  None of them
#      compiles roccmoon_attention_s8_roccmoon_lane.c, so a comment terminated mid-block and an
#      MBXA_NCH that did not survive ModelBlaster's codegen both reached a board build.  The host
#      golden is compiled with MB_PEXT_HW=0, where roccmoon/mbxr_rt.h is never included -- a
#      definition derived from MBXR_NCH without a fallback cannot work there and arms 1-4 cannot
#      see it.
#
#  (b) THE DISPATCH PRECONDITION.  tb_attn drives mbxa_unit with THE BENCH'S OWN staging; it never
#      executes the kernel's `fits` guard or mbxr_attn_dispatch.  `(4 * qs >= S)` -- the software
#      mirror of mbxa_unit.v's cfg_ok, the THIRD copy of that comparison -- refused every head at
#      NCH = 8 while this gate reported ATTN_TB_OK, 0 differ.  On the board that reads attn_lane 0
#      AND attn_fallback 0 with max_abs_err 0: the lane never attempted, every engine counter
#      perfect.  A width the hardware takes and the guest's GUARD does not is still a mismatch.
K="$HERE/../../modelblaster/kernels/roccmoon/roccmoon_attention_s8_roccmoon_lane.c"
if [ -f "$K" ]; then
  for n in 8 4; do
    if cc -fsyntax-only -std=gnu11 -DMB_PEXT_HW=0 -DMBXA_NCH=$n \
         -I"$HERE/../../modelblaster/check/shim" -I"$HERE/../../sw" \
         -I"$HERE/../../modelblaster/kernels/pext_nl" "$K" > "$B/kern$n.log" 2>&1; then
      echo "kernel host-C NCH=$n  PASS"
    else
      echo "kernel host-C NCH=$n  FAIL"; head -6 "$B/kern$n.log"; rc=1
    fi
  done
  # The guard must ACCEPT Moonshine's own attention shape at the width being built.  S = 165,
  # Dv = 36 is what every encoder head asks for; qs = ceil(S/NCH) and the guard is NCH*qs >= S.
  for n in 8 4; do
    if awk -v n="$n" 'BEGIN{S=165;Dv=36;qs=int((S+n-1)/n);qp=int((Dv+n-1)/n);
                            exit !(n*qs>=S && n*qp>=Dv)}'; then
      echo "kernel fits-guard NCH=$n  PASS  (S=165 Dv=36 accepted)"
    else
      echo "kernel fits-guard NCH=$n  FAIL  the dispatch guard refuses Moonshine's own shape"; rc=1
    fi
  done
  if grep -qE '\(4 \* qs >= |\(4 \* qp >= |w_img\[4 \* |w_img1\[4 \* ' "$K"; then
    echo "kernel literal-4 scan  FAIL  a NCH=4 literal survives in the dispatch path:"
    grep -nE '\(4 \* qs >= |\(4 \* qp >= |w_img\[4 \* |w_img1\[4 \* ' "$K" | sed 's/^/    /'
    rc=1
  else
    echo "kernel literal-4 scan  PASS  no NCH=4 literal in the dispatch path"
  fi
else
  echo "kernel        SKIP (attention kernel not present)"
fi

echo
[ $rc = 0 ] && echo "MBXR_NCH8_GATE_OK -- $SNAP computes at NCH=8 on every dispatch kind and is bit-identical at NCH=4" \
            || echo "MBXR_NCH8_GATE_FAIL -- do not place and route this snapshot"
exit $rc
