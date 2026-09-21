#!/usr/bin/env bash
# Mutants that MUST fail.  A suite that cannot fail has not been shown to check anything; the
# attention unit's and the LayerNorm lane's gates both carry one of these and both found real
# defects with it.  Each entry is (name, sed expression) applied to a copy of the RTL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${MUT_WORK:-${TMPDIR:-/tmp}/mbxl_mut.$$}"
mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

names=(); exprs=()
add(){ names+=("$1"); exprs+=("$2"); }

add "index-nibble-swap"     's|assign y\[8\*g +: 8\] = tbl\[rd_data\[8\*g +: 8\]\];|assign y[8*g +: 8] = tbl[{rd_data[8*g +: 4], rd_data[8*g+4 +: 4]}];|'
add "position-collapsed"    's|assign y\[8\*g +: 8\] = tbl\[rd_data\[8\*g +: 8\]\];|assign y[8*g +: 8] = tbl[rd_data[7:0]];|'
add "skid-dropped"          's|if (w_o1) begin o1_d <= y; o1_v <= 1.b1; end|if (1'"'"'b0) begin o1_d <= y; o1_v <= 1'"'"'b1; end|'
add "range-check-removed"   's|wire        rng_bad = rng_end > 17.d1024;|wire        rng_bad = 1'"'"'b0;|'
add "range-check-too-tight" 's|wire        rng_bad = rng_end > 17.d1024;|wire        rng_bad = rng_end > 17'"'"'d512;|'
add "length-off-by-one"     's|if (a_left == 16.d1) run <= 1.b0;|if (a_left == 16'"'"'d0) run <= 1'"'"'b0;|'
add "cfg-while-busy-allowed" 's|if (cfg_hit \&\& busy) begin|if (1'"'"'b0) begin|'
add "issue-guard-dropped"   's|wire can_issue = run \&\& (a_left != 16.d0) \&\& !o1_v \&\& (!pend .. w_o0);|wire can_issue = run \&\& (a_left != 16'"'"'d0);|'
add "table-write-const"     's|if (t_we) tbl\[t_a\] <= t_d;|if (t_we) tbl[t_a] <= 8'"'"'d7;|'
add "hold-ignored"          's|wire o0_fire = o0_v \&\& !out_hold;|wire o0_fire = o0_v;|'
add "zero-length-allowed"   's|if (c_words == 16.d0) begin|if (1'"'"'b0) begin|'

pass=0; fail=0; indist=0
for i in "${!names[@]}"; do
  n="${names[$i]}"; e="${exprs[$i]}"
  f="$WORK/$n.v"
  sed "$e" "$HERE/mbxl_lut.v" > "$f"
  if cmp -s "$f" "$HERE/mbxl_lut.v"; then
    echo "  !! $n : sed matched nothing -- the mutant was never applied"; fail=$((fail+1)); continue
  fi
  if TB_BUILD="$WORK/obj_$n" RTL="$f" "$HERE/run_tb.sh" > "$WORK/$n.log" 2>&1; then
    echo "  INDISTINGUISHABLE  $n  (suite passed the mutant)"; indist=$((indist+1))
  else
    echo "  killed             $n"; pass=$((pass+1))
  fi
done
echo
echo "mutants: $pass killed, $indist indistinguishable, $fail not applied"
[ "$fail" = 0 ] && [ "$indist" = 0 ]
