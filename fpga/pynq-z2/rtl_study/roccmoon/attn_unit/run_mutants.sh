#!/usr/bin/env bash
# Every mutant below is a SINGLE non-equivalent change to the RTL that the testbench must
# catch.  A mutant that passes is a hole in the testbench, not a harmless edit.
#
#   rtl_study/roccmoon/attn_unit/run_mutants.sh
#
# Env: ATTN_BUILD (default $TMPDIR/attn_mut), VERILATOR, ATTN_ACTS.
# Expect a final line beginning ATTN_MUT_OK.  NO BOARD, NO VIVADO, NO MAGIC.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
B="${ATTN_BUILD:-${TMPDIR:-/tmp}/attn_mut}"
mkdir -p "$B"

# name | file | sed expression | what it breaks
mutants=(
"rq_renorm|mbxa_rq.v|s@renm ? {1'b0, q_inc\[24:1\]} : q_inc@q_inc@|fx32_round's 2^24 renormalise is dropped"
"rq_expo|mbxa_rq.v|s@(plen > 6'd24) ? (plen - 6'd24)@(plen > 6'd24) ? (plen - 6'd23)@|the product is rounded to 25 significant bits, not 24"
"rq_final|mbxa_rq.v|s@{25'd0, 1'b1} << (dsm - 5'd1)@26'd0@|the final rounding truncates instead of rounding half away from zero"
"rq_sat|mbxa_rq.v|s@wire        mbig = d_sat @wire        mbig = 1'b0 @|a magnitude that overflows the exponent no longer saturates"
"rq_sign|mbxa_rq.v|s@wire signed \[9:0\] val5 = neg4 ?@wire signed [9:0] val5 = 1'b0 ?@|the sign is dropped from the rounded magnitude"
"seq_bias|mbxa_unit.v|s@assign s0_clr   = (g == 8'd0);@assign s0_clr   = (g == 8'd1);@|the accumulator is cleared one step late, so a group of products is lost"
"seq_act|mbxa_unit.v|s@if (g != 8'd0) a_ptr <= a_ptr + 1'b1;@a_ptr <= a_ptr + 1'b1;@|the activation pointer advances on the bias step, shifting every row by one word"
"seq_reset|mbxa_unit.v|s@        a_ptr <= a_base;@        a_ptr <= a_ptr;@|the activation pointer is not rewound between quads"
"drop_scores|mbxa_unit.v|s@wire        sc_ok   = sc_v \&\& (sn < c_nsc);@wire        sc_ok   = sc_v;@|the surplus scores of the last quad reach the softmax lane instead of being dropped"
"score_last|mbxa_unit.v|s@wire        sc_last = sc_ok \&\& (sn + 16'd1 == c_nsc);@wire        sc_last = sc_ok \&\& (sn + 16'd2 == c_nsc);@|the row end is signalled one score early"
"pring_slot|mbxa_unit.v|s@        p_wr_slot <= p_wr_slot + 2'd1;@        p_wr_slot <= p_wr_slot;@|every p row is written into slot 0, so a row in flight is overwritten"
"lookahead|mbxa_unit.v|s@((rs - rp) < 16'd3)@((rs - rp) < 16'd8)@|the score row runs eight ahead of the p.v row: the four-slot ring wraps onto a live row"
"pack_last|mbxa_unit.v|s@      end else if (in_last) begin@      end else if (1'b0) begin@|a row whose length is not a multiple of eight loses its tail word"
"pack_shift|mbxa_unit.v|s@        out_word  <= nsh >> {(3'd7 - cnt), 3'd0};@        out_word  <= nsh;@|the tail word is not brought down to byte 0"
)

# Mutants that are NOT distinguishable, kept here with the evidence rather than deleted.
# They are expected to PASS; one that started failing would mean the design moved.
equivalent=(
"rq_sticky|mbxa_rq.v|s@((rem == halfv) \&\& q_sh\[0\])@((rem == halfv) \&\& 1'b1)@|round-half-to-EVEN becomes half-up on the product. PROVABLY equivalent (ATTENTION_UNIT.md s3.4): at a tie the modes differ iff q is even, the final rounding splits q from q+1 iff q == 2^(d-1)-1 mod 2^d which is odd for every d >= 2, and at d = 1 the magnitude is >= 2^22 and saturates. The evidence that first recorded it: 28.5 M requantises in tb_rq and 1,050,906 targeted host samples including 6,866 EXACT ties change no byte. The tie needs P to have exactly sh2-1 trailing zeros, and mt is odd for both Moonshine constant sets, so it needs |acc| to be a near power of two -- and then the +-1 in q must also cross the final rounding boundary. The RTL rounds half-to-even because fx32_round does, not because a test forces it."
"actmux|mbxa_unit.v|s@wire \[63:0\] a_word = s1_sel ? p_rdata : rd_data\[63:0\];@wire [63:0] a_word = act_sel ? p_rdata : rd_data[63:0];@|selecting the activation source with the unregistered phase. Equivalent BECAUSE the FSM drains the pipeline between jobs: the phase is constant over every cycle in which a step's data is selected, so the register is defensive, not required. It would stop being equivalent the moment two jobs overlapped in the pipeline."
"ring_check|mbxa_unit.v|s@if (run \&\& ((p_done - rp) > 16'd3)) e_ring <= 1'b1;@e_ring <= 1'b0;@|removing a run-time assertion. Equivalent by construction in a correct design -- it can only fire when something else is already wrong, which is what the `lookahead` mutant shows."
)

pass=0; caught=0
for m in "${mutants[@]}"; do
  IFS='|' read -r name file expr why <<< "$m"
  d="$B/$name"
  rm -rf "$d"; mkdir -p "$d"
  cp "$here"/mbxa_rq.v "$here"/mbxa_unit.v "$here"/mbxa_glue.v "$d/"
  before=$(md5sum "$d/$file" | cut -d' ' -f1)
  sed -i "$expr" "$d/$file"
  after=$(md5sum "$d/$file" | cut -d' ' -f1)
  if [ "$before" = "$after" ]; then
    echo "ATTN_MUT_FAIL $name: the substitution matched nothing (the RTL moved under it)"
    pass=$((pass + 1)); continue
  fi
  if ATTN_BUILD="$d/b" ATTN_RTLDIR="$d" "$here/run_tb.sh" --quick > "$d/log" 2>&1; then
    echo "ATTN_MUT_FAIL $name PASSED the testbench -- $why"
    pass=$((pass + 1))
  else
    echo "ATTN_MUT_CAUGHT $name -- $why"
    caught=$((caught + 1))
  fi
done

eqbad=0; eqok=0
for m in "${equivalent[@]}"; do
  IFS='|' read -r name file expr why <<< "$m"
  d="$B/eq_$name"
  rm -rf "$d"; mkdir -p "$d"
  cp "$here"/mbxa_rq.v "$here"/mbxa_unit.v "$here"/mbxa_glue.v "$d/"
  before=$(md5sum "$d/$file" | cut -d' ' -f1)
  sed -i "$expr" "$d/$file"
  if [ "$before" = "$(md5sum "$d/$file" | cut -d' ' -f1)" ]; then
    echo "ATTN_MUT_FAIL eq_$name: the substitution matched nothing (the RTL moved under it)"
    eqbad=$((eqbad + 1)); continue
  fi
  if ATTN_BUILD="$d/b" ATTN_RTLDIR="$d" "$here/run_tb.sh" --quick > "$d/log" 2>&1; then
    echo "ATTN_MUT_EQUIV $name passes, as recorded -- $why"
    eqok=$((eqok + 1))
  else
    echo "ATTN_MUT_FAIL eq_$name now FAILS: it was recorded as indistinguishable and is not"
    eqbad=$((eqbad + 1))
  fi
done

echo "$([ $((pass + eqbad)) -eq 0 ] && echo ATTN_MUT_OK || echo ATTN_MUT_FAILED): $caught of $((caught + pass)) non-equivalent mutants fail the testbench; $eqok of $((eqok + eqbad)) recorded-equivalent mutants pass as recorded"
[ $((pass + eqbad)) -eq 0 ]
