#!/usr/bin/env bash
# Negative controls: mutate mbxr_ln.v one edit at a time and require the testbench to reject
# every non-equivalent mutant.  A suite that passes a broken lane is not evidence.
#
#   rtl_study/roccmoon/ln_lane/mutants.sh            all mutants, run_tb.sh --quick each
#
# Env: LN_MUT_BUILD (default $TMPDIR/ln_mut), LN_MUT_ONLY (space-separated mutant names).
# Each line of output is  MUT <name> <expect> <result>.  Expect "kill" for a mutant that must
# fail and "equiv" for one that is genuinely the same circuit.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
B="${LN_MUT_BUILD:-${TMPDIR:-/tmp}/ln_mut}"
mkdir -p "$B"
SRC="$here/mbxr_ln.v"

# name | expect | sed script
mutants=(
"t_shift_43|kill|s@wire signed \[53:0\] t5    = pr5\[97:44\];@wire signed [53:0] t5    = pr5[96:43];@"
"round_2p31m1|kill|s@49'sh0_8000_0000@49'sh0_7FFF_FFFF@"
"div_start_2|kill|s@acc <= 97'd1; dq <= 122'd0;@acc <= 97'd2; dq <= 122'd0;@"
"sqrt_trial_10|kill|s@root\[60:0\], 2'b01}@root[60:0], 2'b10}@"
"kq_19_to_18|kill|s@rcnt   <= 7'd19;@rcnt   <= 7'd18;@"
"s2_43_to_42|equiv|s@rcnt <= 7'd43; rs <= RS_S2;@rcnt <= 7'd42; rs <= RS_S2;@"
"s2_start_36|kill|s@rcnt <= 7'd43; rs <= RS_S2;@rcnt <= 7'd36; rs <= RS_S2;@"
"pr_align_16|kill|s@{{18{m4b\[62\]}}, m4b, 17'd0}@{{19{m4b[62]}}, m4b, 16'd0}@"
"clamp_126|kill|s@28'sd127;@28'sd126;@"
"s_zero_ext|kill|s@{a_sb\[k3\]\[43\], a_sb\[k3\]}@{1'b0, a_sb[k3]}@"
"q_drop_lsb|kill|s@{8'd0, uu3}@{9'd0, uu3[65:1]}@"
"no_out_credit|kill|s@wire a_credit = (o_res != OCAP);@wire a_credit = 1'b1;@"
"ring_5_rows|kill|s@(i_rid - a_rid) != 3'd4@(i_rid - a_rid) != 3'd5@"
"no_ring_check|kill|s@wire i_room  = c_tp | ((i_rid - a_rid) != 3'd4);@wire i_room  = 1'b1;@"
"no_ir_reserve|kill|s@(q_ir_res != 2'd2)@1'b1@"
"early_take_always|kill|s@(a_lastf \& (|c_k\[19:3\]))@a_lastf@"
"eps_slice_noop|equiv|s@{33'd0, c_eps} :@{33'd0, c_eps[63:0]} :@"
"ofifo_32deep|equiv|s@parameter OFW = 4 @parameter OFW = 5 @"
)
if [ -n "${LN_MUT_ONLY:-}" ]; then
  keep=(); for m in "${mutants[@]}"; do
    n="${m%%|*}"; case " $LN_MUT_ONLY " in *" $n "*) keep+=("$m");; esac; done
  mutants=("${keep[@]}")
fi
nk=0; nf=0; ne=0; nbad=0
for m in "${mutants[@]}"; do
  name="${m%%|*}"; rest="${m#*|}"; expect="${rest%%|*}"; script="${rest#*|}"
  mkdir -p "$B/$name"
  mut="$B/$name/mbxr_ln.v"      # the file must keep its name, or Verilator's -Wall
  sed -e "$script" "$SRC" > "$mut"   # DECLFILENAME would kill every mutant for free
  if cmp -s "$mut" "$SRC"; then
    echo "MUT $name $expect NO-OP (the sed script did not match; fix it)"; nbad=$((nbad+1)); continue
  fi
  if LN_BUILD="$B/$name" LN_RTL="$mut" "$here/run_tb.sh" --quick > "$B/$name.log" 2>&1; then
    res=pass
  else
    res=fail
  fi
  echo "MUT $name $expect $res"
  if [ "$expect" = kill ]; then
    if [ "$res" = fail ]; then nk=$((nk+1)); else nf=$((nf+1)); fi
  else
    if [ "$res" = pass ]; then ne=$((ne+1)); else nbad=$((nbad+1)); fi
  fi
done
echo "MUT_SUMMARY killed $nk, survived $nf, equivalent-and-passed $ne, broken-script $nbad"
[ "$nf" -eq 0 ] && [ "$nbad" -eq 0 ]
