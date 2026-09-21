#!/usr/bin/env bash
# Lab B38 -- the LayerNorm lane A/B, ON SILICON THAT CONTAINS THE LANE.
#
#   ./scripts/70_rocket_ln_lane_ab.sh --build-only                                  # no board
#   scripts/with_board.sh ./scripts/70_rocket_ln_lane_ab.sh --board-only            # board only
#   ./scripts/70_rocket_ln_lane_ab.sh --report-only                                 # re-score
#
# WHY IT EXISTS.  The previous attempt at this measurement -- `b30_lnab_on_run.json` -- ran the
# lane-on arm on `0x5A5A0028`, which MAGIC_REGISTRY.md describes in its own words as the thing
# `0x5A5A0029` is "plus the two lanes".  The lane was not in that bitstream.  The arm reports
# `last_rc = -4` (MBXR_E_TIMEOUT) with `calls_fallback = 49`, and its "740.67 cycles/element" is
# 60.70 of reference C plus ~680 of timeout; `linear_s8`, which touches no lane at all, went
# 15.9x slower in the same run, because one armed and unfed drain makes every later
# `mbxr_wait(MBXR_S_BUSY)` spin to its budget.  `layernorm_s8` is 10.7 % of encoder steady and
# 4.5 % of decoder steady and was written off on that measurement.
#
# WHICH BITSTREAM, AND WHY NOT THE ONE THE TASK NAMED.  Verified against the registry rather
# than taken on trust: `ln_lane` is in `0x5A5A0029`, `002A`, `002B` and `002C`, and is NOT in
# `0x5A5A0028`.  This lab defaults to **`0x5A5A002A`** -- `0029` plus ten lines of LN streamer,
# same lane, same engine revision, same clock -- because it is the build present in the tree
# (`build_rocket_micrgb_roccmoonlanes_z1`, md5 `1e8ea02d47`) and the one with a runner.  `0029`
# is archived and can be passed with --bit/--magic/--runner; its LayerNorm path is identical.
#
# WHAT IS DIFFERENT FROM THE 0x5A5A0028 RUNS, STATED BEFORE THE NUMBERS.  scripts/57's cap
# case-statement names only `0x5A5A0028|0x5A5A0013`, so every lane-bearing MAGIC falls to
# `-DMBXR_RT_CAP=3` even though all of them carry 0092 in the L2 and support cap 4.  Both arms
# here therefore run at cap 3 and the A/B between them is clean, but the ENGINE rows
# (`linear_s8`, `conv2d_s8`) are NOT comparable with Lab B30's cap-4 rows.  The LayerNorm rows
# are, because reference C runs on hart 0 and never asks the engine for anything.
#
# THE GATE IS THE POINT OF THE SHAPE OF THIS SCRIPT.  Both arms are built off the board, both
# are put through scripts/lib/feature_gate.sh BEFORE the board is touched, and both run.json
# records are replayed through the same checks afterwards.  The gate is given each arm's OWN
# `kernel_picks.json`, freshly generated: the same candidate with the same cflags was served
# `reference` for `layernorm_pc_s8` in Lab B30 and `roccmoon_lane` a day later, so a cached
# answer from a previous run of the same configuration passes both.
# ============================================================================================
# THE PREDICTION, COMMITTED BEFORE THE BOARD.  Scored by the code at the bottom of this file,
# so it cannot be quietly restated afterwards.
# ============================================================================================
#
# THE TWO SHAPES FIRST, BECAUSE A RATE THAT DOES NOT TRANSFER IS THIS CAMPAIGN'S MOST REPEATED
# ERROR.  `b33_lane_smoke`'s **1.095 cycles/element** and this model's LayerNorm are not the
# same measurement of the same thing:
#
#   b33_lane_smoke     ONE dispatch of 28 rows x K 288 = 8,064 elements = 1,008 scratchpad
#                      words, 8,827 cycles.  Data ALREADY RESIDENT -- the bench issues no SD
#                      and no LD, deliberately, because the lane's timing does not depend on
#                      the data -- so it pays NO fill and NO drain.  It configures K and eps
#                      only, so it pays NO affine table.  Its output bytes were never checked.
#                      Its two-point fit gives 0.99826 c/el marginal and ~196 cycles of
#                      wrapper; 1.095 is that slope plus the fixed cost spread over 8,064.
#
#   this model's op    `layernorm_pc_s8`, 13 dispatches of M 165 x K 288 = 47,520 elements =
#                      5,940 words each.  That is 5.8x the 1,024-word activation buffer, so it
#                      CANNOT be one lane dispatch -- B33's own guard refused exactly this
#                      shape (`LS_GUARD M=165 K=288 rc=-70 SPAN(would wrap)`).  It is SIX
#                      tiles (5 x 28 rows + one of 26, the last padded up because 288 x odd is
#                      never a whole number of 64-byte drain blocks), each preceded by the
#                      affine table's 5 x K = 1,440 `lcfg` writes, each fed by a DMA fill and
#                      drained back to memory, and checked byte-for-byte against the host-C
#                      golden.
#
# So the predicted rate is NOT 1.095.  It is ROCC_DECOUPLED.md 8.15.26's build-up, which adds
# back exactly the terms B33's harness could not see:
#
#   lane + wrapper, 6 tiles            52,201 cycles
#   affine table, 1,440 lcfg           17,280
#   fill,  47,808 B at 6.3 B/cycle      7,589
#   drain, 47,808 B                     7,589
#   ---------------------------------  ------
#   per model dispatch                 84,658 cycles / 47,520 elements = 1.782 c/el
#
# PREDICTION 1 -- THE CONTROL, which decides whether the comparison means anything.
#   `layernorm_pc_s8` with -DMBXR_LN_LANE=0 is reference C on hart 0 and must reproduce Lab
#   B30's own measurement: **60.78 c/el, band 51.7-69.9**.  IF IT DOES NOT, THE COMPARISON IS
#   NOT INTERPRETED.  Two arms wrong in the same way is what a control exists to catch.
#
# CAN THE LANE SERVE THE SHIPPING CANDIDATE'S LAYERNORM?  ESTABLISHED BY RUNNING THE LOWERING,
# not by inspection -- inspection has been wrong four times on this interface.  Two answers, and
# the second is the one that decides what the lane is worth:
#
#   1. YES on the OPERATOR.  "Per-tensor" in `layernorm_s8` names the ACTIVATION scales, not the
#      affine: it carries per-channel gamma/beta like `layernorm_pc_s8`, and normalises over the
#      same axis.  patches/0103's `layernorm()` branches on the INPUT DTYPE, not on the
#      quantisation kind -- `elif dt == "i8": new["op"] = "layernorm_pc_s8"` -- and `_chan_vec()`
#      returns, in its own docstring, "a per-tensor scale repeated".  So a per-tensor int8
#      LayerNorm lowers to the very op this lane serves, with umul the constant 2^24: inside
#      mbxr_ln_consts_fit's 2^25, and K*umul = 288 * 2^24 inside its 2^40.  It fits with room.
#
#   2. BUT IT IS A GRAPH LOWERING, NOT A KERNEL REGISTRATION, and registering a `roccmoon_lane`
#      kernel for `layernorm_s8` would be the wrong change three times over: kernel_layernorm_s8
#      takes FLOATS (gamma, beta, scale_in, scale_out, eps) and would push the float -> Q16
#      derivation onto the board per dispatch; its arithmetic is a mantissa/shift core
#      (nl_f2ms/nl_scale), not the _Q16_NORM_CORE that mbxr_ln.v implements, so substituting it
#      CHANGES THE MODEL and needs a WER re-check rather than a max_abs_err one -- and
#      max_abs_err would pass trivially, because the host golden is rebuilt from the same new
#      kernel.  Two arms wrong in the same way is the failure a control exists to catch.
#
#   3. AND QATU CANNOT BE LOWERED AS PLANNED -- the obstacle is the STEM'S GROUPNORM, not
#      LayerNorm.  Run directly (scripts/53's own 0103 check is a false negative: it tests that
#      patch alone with `apply --reverse --check` and 0107, applied after it, has drifted its
#      context, so the stack IS applied and the lab refuses anyway):
#          extract_q16 --model moonshine_enc --plan q16_plan_QATU.json
#          -> NotImplementedError: stem.groupnorm: groupnorm lowering needs int16 in and out
#      q16_plan_QATU.json keeps the unsplit stem at per-tensor int8 (stem_tanh and
#      stem_groupnorm both {'kind': 'pt', 'bits': 8}), while candidate R's plan has both at
#      bits 16 -- which is why R lowers and QATU does not.  So the 10.7 % needs either a
#      re-planned QATU with an int16 stem (a different model: re-measure WER, do not assume it)
#      or an int8 path in 0103's groupnorm().  Neither is this measurement, and neither is free.
#
#   WHAT TRANSFERS FROM THIS LAB IS THE RATE, NOT THE SHARE: 6.5527 c/el at M=165, K=288, six
#   tiles, against 60.69 for reference C on the same silicon.
#
#   4. BUT q16 LOWERING IS NOT "THE" ROUTE TO A LANE, AND QATU ALREADY REACHES ONE.  Settled
#      from committed board records rather than from the extractor: b35_armE_fused_lane_hart1
#      is a QATU-policy image on 0x5A5A002C with **attention_s8 -> roccmoon_lane** and
#      max_abs_err 0, and b34/b35_armA run QATU's linear_s8 and conv2d_s8 on roccmoon_engine.
#      The lane-bearing route is extract_graph (plain int8) + the attention fusion pass + the
#      roccmoon curated tree -- out/attnfuse_on is exactly that, a p99.9-calibrated graph
#      carrying attention_s8 x6 beside layernorm_s8 x13.  So:
#
#        engine          linear_s8, conv2d_s8   QATU reaches it TODAY, measured
#        attention unit  attention_s8           QATU reaches it TODAY, measured, mae 0
#        LUT lane        gelu_s8 (x8 in QATU)   op present; NO KERNEL FILE EXISTS for it
#        LayerNorm lane  layernorm_pc_s8        the ONLY one QATU cannot reach
#
#      An int8 path in 0103's groupnorm() would therefore unstrand ONE lane, not three.
#
#   5. AND THE CHEAPEST ROUTE TO THIS LANE ON QATU IS A KERNEL, NOT AN EXTRACTOR CHANGE.
#      Every input 0103's layernorm() consumes is already an argument of kernel_layernorm_s8:
#      gamma, beta, scale_in, scale_out, eps.  For a per-tensor input _chan_vec is constant, so
#      umul is the constant 2^24 and the rest is gmul = rint(gamma/scale_out * 65536),
#      badd = rint(beta/scale_out * 65536), eps_q = rint(eps * K^2 * (2^24/scale_in)^2).
#      Against QATU's OWN numbers: umul 16,777,216 < 2^25; K*umul 4.83e9 < 2^40; eps_q
#      983,582,551,378,402, above MBXR_LN_EPS_MIN and inside int64; activation_min/max -128/127
#      on all 13, which is the lane's native clamp; and the shape is M=165 K=288 -- THE EXACT
#      SHAPE THIS LAB MEASURED.  The derivation is per-layer and hoistable, exactly as
#      pext_int_rsqrt already caches it, so it is not a per-dispatch cost.
#
#      THE ONE GENUINELY NEW RISK, TESTED RATHER THAN ASSERTED: per-CHANNEL puts only the
#      largest channel at umul = 2^24, while per-TENSOR puts ALL K there at once and Q
#      accumulates K terms of u^2 -- a strictly harsher load on the lane's Q accumulator than
#      candidate R has ever produced.  tb_mbxr --lanes now carries that case with QATU's own
#      eps_q at 165x288 through the six-tile sequence: bad = 0 of 47,520, max_abs_err 0.
#      The lane CAN serve per-tensor.
#
#      All three routes -- a layernorm_s8 kernel, an int8 groupnorm lowering, a re-planned
#      int16-stem QATU -- change the operator's arithmetic from pext_int_rsqrt's mantissa/shift
#      core to _Q16_NORM_CORE, so ALL THREE need a WER re-measurement and that is not a
#      discriminator between them.  (I argued against the kernel route earlier partly on the
#      WER cost; that argument was wrong, because the other two carry it too.)  The kernel is
#      ~60 lines, needs no extractor change and no re-plan, and serves EVERY candidate that
#      emits layernorm_s8 -- the whole b26/b28/b34/b35 family -- not only QATU.
#
#      WORTH, at the rate measured on the identical shape: QATU's layernorm_s8 is 59,108,269
#      cycles, 10.71 % of its encoder steady, at 95.68 c/el over the same 617,760 elements.
#      At 6.5527 it is 4,047,996 -- a 55.1 M saving, 9.97 points, and encoder rtf_steady
#      **4.0021 -> 3.6029**.  Against candidate R with the lane at 5.0908, that is where this
#      lane's value actually lives.  It is an estimate: it applies a measured rate to a
#      measured element count on an identical shape, and assumes nothing else in QATU moves.
#
# ROUND 3 (B40) -- THE FILL'S 64-BYTE ALIGNMENT, which was the second half of the wrong bytes.
#
#   B39's cfg fix took max_abs_err 241 -> 96 and made the rest-of-model contamination vanish
#   entirely (linear_s8 -0.2 %), so the stale-buffer diagnosis was right and INCOMPLETE.  The
#   residue is a second precondition the board violated and no simulator could see:
#   mbxd_dma.v:71 takes "the byte address of the first block, 64-BYTE ALIGNED" and :38 states
#   there is no byte funnel -- "the scratchpad is a 1:1 image of 64-byte-aligned memory".  The
#   kernel staged ONLY the padded tile, so five tiles in six filled straight from
#   `input + m0*K`, which this model's generator emits 8-byte aligned (mod 64 = 8/24/40/56,
#   read out of the ELF).  A misaligned fill reads the enclosing block: a plausible wrong
#   answer, rc = 0, no error bit.  tb_mbxr's LN_SRC is MEM_BASE + 8 MB -- aligned by
#   construction -- which is exactly why 94 lane cases passed while the board did not.
#
#   Two changes: mbxr_ln_dispatch REFUSES an unaligned fill or drain with MBXR_E_ALIGN (so the
#   next caller gets a return code, not a transcript), and the kernel stages whenever the tile
#   is padded OR the source is not 64-byte aligned.  Gates: tb_mbxr --quick 80 cases,
#   --lanes 99 cases 0 failing, including a new one-table/six-tile/assembled-165-row case that
#   is bit-exact and five unaligned-dispatch cases that must all be refused.
#
#   P1 CONTROL unchanged, 60.78 c/el, band 51.7-69.9.
#   P2 **max_abs_err = 0.**  This is the last precondition the board is known to violate.  If
#      it is still non-zero, the diagnosis is incomplete AGAIN and that is what gets reported
#      -- not another round of guessing.
#   P3 RATE **6.0 c/el, band 5.0-7.5** -- a DELIBERATE REGRESSION from B39's 5.1226, because
#      correctness costs a staging copy on all six tiles instead of one.  Basis: B38 -> B39
#      changed only the copy width, 562,062 -> 243,428 cycles per dispatch over the same
#      55,008 byte-ops, so the 8-byte copy costs ~45,500 (6.6 cycles per 8-byte iteration) and
#      the fixed part is ~197,900.  All-tile staging adds 40,320 byte-ops = 5,040 iterations
#      = ~33,400 cycles, giving ~276,900 and 5.83 c/el; the band's top allows the added copy
#      to run 2x slower than the existing one, since it reads a tensor rather than scratch.
#      Against the control that is 10.1x on the operator, band 8.1-12.1.
#   P4 THE REST OF THE MODEL STAYS FLAT, as it did in B39 once the buffer was right.
#
# ROUND 2 (B39), AFTER THE TWO FIXES.  Everything below this block is the B38 prediction and
# its basis, kept as written; this is what is predicted for the run that follows the fixes.
#
#   THE FIXES.  (1) mbxr_ln_dispatch now issues `cfg` with rs2[40] = the caller's abuf.  It
#   filled the buffer its caller named and READ whichever buffer the last engine dispatch had
#   selected -- one defect with two symptoms, the attention unit's err[2] and this lane's
#   silent wrong bytes.  (2) The copy-out and the staging copy move 8 bytes at a time instead
#   of one, and the drain is pointed at the caller's rows outright when the tile is unpadded
#   AND the destination is 64-byte aligned.  MEASURED: this model's buffers are 8-byte
#   aligned (mod 64 = 8/24/40/56), so on this build the direct path never fires.
#
#   P1 CONTROL: unchanged, 60.78 c/el, band 51.7-69.9.  Neither fix touches the reference
#      fallback.  If it moves, something other than these two changes did it.
#   P2 CORRECTNESS: **max_abs_err = 0 in the lane arm.**  This is the falsifiable core of the
#      stale-buffer diagnosis.  Still non-zero and the diagnosis is wrong or incomplete, and
#      the next suspect is the fill/streamer seam rather than the buffer.
#   P3 RATE: **5.5 c/el, band 4.0-8.0.**  B38 measured the copy at 408,513 of 562,062 cycles
#      (72.7 %) over 55,008 byte-ops = 7.43 c/byte.  The 8-byte loop does an eighth of the
#      iterations: fully per-access-bound gives ~51,000 and 4.31 c/el, fully per-byte-bound
#      gives ~204,000 and 7.53 c/el.  The band spans both because which one it is IS the
#      open question.  Against the control that is 11.0x on the operator, band 7.6-15.2.
#   P4 THE SIDE EFFECT PERSISTS: B38's rest-of-model +15.7 M cycles (linear_s8 +1.7 %) is not
#      addressed by either fix, so predict +1.5-2.0 % again.  If it VANISHES it was caused by
#      the stale reads, which nothing in the engine counters predicted -- report either way.
#
# PREDICTION 2 -- THE LANE ARM.  **1.782 c/el, band 1.462-2.10.**  The low end is fill and
#   drain fully hidden (they are not: the driver fences between each); the high end is both
#   serialised at two thirds of the port's rate, WIDENED from 8.15.26's 1.973 because this lab
#   is forced to `-DMBXR_RT_CAP=3` by scripts/57's stale cap case-statement and fill+drain is
#   17.9 % of the budget.  Against the control that is a predicted **34.1x on this operator**,
#   band 24.6-47.8.
#
# PREDICTION 3 -- WHAT IT IS WORTH, and the honest denominator.  On candidate R,
#   `layernorm_pc_s8` is **37,496,230 cycles = 5.09 % of encoder steady** (b30_lnab_off).  At
#   1.782 c/el it becomes 1.10 M, a saving of 4.94 points: **encoder rtf_steady 5.3386 ->
#   5.075**.  NOT 10.7 %: that figure is QATU's **`layernorm_s8`** (per-tensor, 95.68 c/el,
#   `pext_int_rsqrt`, b34_qatu_lnhoist), and the lane kernel is registered for
#   **`layernorm_pc_s8`** only, so the shipping candidate never reaches it.  The lane's value
#   to RTF_e2e is gated on registering it for the op the shipping candidate actually emits,
#   which is a kernel change and not this measurement.
#
# FALSIFIERS -- any one of these and the number is not a lane measurement:
#   F1  the control lands outside 51.7-69.9 c/el                -> do not interpret the A/B
#   F2  max_abs_err != 0 in either arm                          -> the lane did not compute it
#   F3  the lane arm has last_rc = -4, or calls_fallback > 0,   -> the cost of giving up, which
#       or polls at the 20,000,000 budget                          is exactly what 740.67 was
#   F4  `linear_s8` moves more than +-5 % between the arms      -> the RUN is degraded, not the
#       (it touches no lane; in b30_lnab_on it moved 15.9x)        op; this is the tell nobody
#                                                                  read the first time
#   F5  the lane arm's kernel reads `reference` and not         -> a silent fallback reporting a
#       `roccmoon_lane`                                            successful encoder that never
#                                                                  touched the lane
#   F6  above 2.10 c/el: a MISS, and the first places to look are the fill (B33 dispatched over
#       resident data; this arm pays a DMA per tile) and the affine table (1,440 `lcfg` per
#       dispatch, 20 % of the predicted budget).  Report the miss and its cause; do not rescale.
#   F7  below 1.462 c/el: check the tile count before claiming it.  Fewer tiles than the shape
#       requires is a wrong answer that happens to be fast.
# ============================================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bitstream_id.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/feature_gate.sh"

# THE DECLARATION.  Required, and it sits beside WANT_MAGIC because that is the pair that has
# to agree.  scripts/lib/feature_gate.sh refuses an empty one.
LAB_REQUIRES="rocc_engine ln_lane pext"

NAME="rocket_ln_lane_ab"
CAND="R"
IR=""
LN_SEL=0        # --ln-lane-select: steer the per-tensor layernorm_s8 pick (QATU)
LUT_SEL=0       # --lut-lane-select: ALSO put gelu_s8/tanh_s8 on T4's LUT lane, one image
BIT="$IISWC_ROOT/fpga/pynq-z2/build_rocket_micrgb_roccmoonlanes_z1/pynqz1_rocket_micrgb_roccmoonlanes.bit"
RUNNER="run_rocket_roccmoonlanes2.py"
WANT_MAGIC="0x5A5A002A"
DO_BUILD=1; DO_BOARD=1; REPORT_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --candidate) CAND="${2:?}"; shift 2 ;;
    # a candidate whose IR is not under out/q16/<cand>/ir -- QATU lives in out/qatu_long/ir
    --ir) IR="${2:?}"; shift 2 ;;
    --ln-lane-select) LN_SEL=1; shift ;;
    --lut-lane-select) LUT_SEL=1; shift ;;
    --bit) BIT="${2:?}"; shift 2 ;;
    --magic) WANT_MAGIC="${2:?}"; shift 2 ;;
    --runner) RUNNER="${2:?}"; shift 2 ;;
    --build-only) DO_BOARD=0; shift ;;
    --board-only) DO_BUILD=0; shift ;;
    --report-only) DO_BUILD=0; DO_BOARD=0; REPORT_ONLY=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

B30="$IISWC_ROOT/scripts/57_rocket_moonshine_q16_board.sh"
need_exec "$B30"
# 64-byte intermediates, because this lab dispatches to a lane.  See the function.
lane_align_buffers "$WANT_MAGIC"
IR_ARG=(); [ -n "$IR" ] && IR_ARG=(--ir "$IR")
OFF="${NAME}_off"; ON="${NAME}_on"
# The two arms differ in ONE define and in nothing else.  MBXR_LN_LANE is written out in BOTH
# arms, including the arm where it takes its default value: a define that selects hardware when
# it is absent is not a default, it is a trap, and a lab that relies on it cannot be read back.
KCF_OFF="-falign-loops=4 -DMBXR_LN_LANE=0"
KCF_ON="-falign-loops=4 -DMBXR_LN_LANE=1"
# 0x5A5A002A and 0x5A5A0029, so an image built for either is loadable; bitstream_gate still
# refuses anything else and the feature gate still refuses anything unregistered.
export BIT_ACCEPTED="${BIT_ACCEPTED:-} 1e8ea02d47dc9c2c7590a879de6c1d77 3710420ad34e9cd93eacb2ca84b4e991 32d10e5d47a4ca1f120f6f6d34e04b4e"

if [ "$DO_BUILD" -eq 1 ]; then
  step "1/4  build both arms off the board"
  for arm in off on; do
    [ "$arm" = off ] && { rn="$OFF"; kcf="$KCF_OFF"; } || { rn="$ON"; kcf="$KCF_ON"; }
    # PER-TENSOR ONLY.  A layernorm_s8 graph (QATU) needs its pick STEERED, because the two
    # arms are different kernel FILES; a layernorm_pc_s8 graph (candidate R) does not, because
    # both its arms are the same file switched by -DMBXR_LN_LANE.  scripts/57 asserts the pick
    # both ways either way, so a leak is a build failure and not a silent self-comparison.
    LN_ARG=(); [ "$arm" = on ] && [ "$LN_SEL" = 1 ] && LN_ARG=(--ln-lane)
    [ "$arm" = on ] && [ "$LUT_SEL" = 1 ] && LN_ARG+=(--lut-lane)
    info "arm $arm: $kcf"
    run "$B30" --name "$rn" --candidate "$CAND" --magic "$WANT_MAGIC" --bit "$BIT" \
        --runner "$RUNNER" "${IR_ARG[@]}" "${LN_ARG[@]}" --kernel-cflags "$kcf" --build-only \
        > "$IISWC_OUT/${rn}.build.log" 2>&1 \
      || { tail -25 "$IISWC_OUT/${rn}.build.log"; die "arm $arm did not build"; }
    info "  image: $(fsize "$IISWC_OUT/$rn/enc_q16/zephyr.bin")"
  done
fi

step "2/4  the feature gate, before the board is touched"
need_file "$BIT" "no bitstream at $BIT"
bitstream_identify "$BIT"; bitstream_gate
for arm in off on; do
  [ "$arm" = off ] && rn="$OFF" || rn="$ON"
  D="$IISWC_OUT/$rn/enc_q16"
  need_file "$D/gen/kernel_picks.json" "arm $arm has no selection record -- build it first"
  need_file "$D/kernel_cflags.txt"
  # The lane-off arm requires no lane: it is the known-answer control and must be gated as
  # what it is, not as what the lab as a whole wants.
  if [ "$arm" = off ]; then
    LAB_REQUIRES="rocc_engine pext"
  else
    LAB_REQUIRES="rocc_engine ln_lane pext"
    [ "$LUT_SEL" = 1 ] && LAB_REQUIRES="$LAB_REQUIRES lut_lane"
  fi
  FEATURE_GATE_OUT="$D/feature_gate.json" NAME="$rn arm=$arm" \
    feature_gate "$D/gen/kernel_picks.json" "$(cat "$D/kernel_cflags.txt")"
done
LAB_REQUIRES="rocc_engine ln_lane pext"

if [ "$DO_BOARD" -eq 1 ]; then
  step "3/4  the board, both arms back to back"
  for arm in off on; do
    [ "$arm" = off ] && rn="$OFF" || rn="$ON"
    info "arm $arm -> out/$rn"
    run "$B30" --name "$rn" --candidate "$CAND" --magic "$WANT_MAGIC" --bit "$BIT" \
        --runner "$RUNNER" "${IR_ARG[@]}" "${LN_ARG[@]}" --board-only \
        > "$IISWC_OUT/${rn}.board.log" 2>&1 \
      || { tail -40 "$IISWC_OUT/${rn}.board.log"; warn "arm $arm exited non-zero -- the record is still scored below"; }
  done
fi

if [ "$DO_BOARD" -eq 0 ] && [ "$REPORT_ONLY" -eq 0 ]; then
  info "--build-only: both arms built and both gated, no board touched.  Now:"
  info "  scripts/with_board.sh $0 --board-only"
  exit 0
fi

step "4/4  replay both records through the gate, then score the A/B"
for arm in off on; do
  [ "$arm" = off ] && rn="$OFF" || rn="$ON"
  need_file "$IISWC_OUT/$rn/run.json" "arm $arm produced no record"
  feature_audit "$IISWC_OUT/$rn/run.json"
done
CANDIDATE="$CAND" LUT_SEL="$LUT_SEL" python3 - "$IISWC_OUT/$OFF/run.json" "$IISWC_OUT/$ON/run.json" "$IISWC_OUT/$NAME.json" <<'PY' \
  | tee "$IISWC_OUT/$NAME.txt"
import json, os, sys

CLK = 34482759.0
# WHICH OP: candidate R emits layernorm_pc_s8, QATU emits per-tensor layernorm_s8, and the
# lane serves both (kernels/roccmoon/roccmoon_layernorm_{pc_,}s8_roccmoon_lane.c).  Picked from
# the record rather than hard-wired, because hard-wiring it is how this scorer would have
# silently found no row at all on the first QATU arm.
OP = None
# committed before the board -- docs/ROCC_DECOUPLED.md 8.15.26's restated prediction, widened
# for the cap-3 fill this lab is forced to run at.  See the prediction block in the report.
PRED = {"lane_c_per_el": 9.23, "lo": 7.0, "hi": 12.0,
        "control_c_per_el": 96.40, "control_lo": 80.0, "control_hi": 115.0,
        "encoder_rtf_steady": 3.26, "encoder_lo": 3.15, "encoder_hi": 3.38,
        "round": "B45: QATU, BOTH lanes in ONE image (layernorm_s8 + gelu_s8/tanh_s8)",
        "superseded": [
          {"round": "B38", "lane_c_per_el": 1.782, "lo": 1.462, "hi": 2.10,
           "measured": 11.8279, "max_abs_err": 241, "verdict": "FALSIFIED by 6.6x",
           "cause": "72.7 % of the dispatch was a byte-at-a-time copy-out at 7.43 c/byte, "
                    "and the bytes were wrong because mbxr_ln_dispatch never named the "
                    "buffer the lane reads"},
          {"round": "B40", "lane_c_per_el": 6.0, "lo": 5.0, "hi": 7.5,
           "measured": 6.5527, "max_abs_err": 0, "verdict": "WITHIN; all six falsifiers pass",
           "cause": "the first measured lane win: 9.26x, bit-exact.  51.6 % of the dispatch "
                    "was still the two copies, which exist only because the model's buffers "
                    "are 8-byte aligned while mbxd_dma.v:71 requires 64"},
          {"round": "B39", "lane_c_per_el": 5.5, "lo": 4.0, "hi": 8.0,
           "measured": 5.1226, "max_abs_err": 96, "verdict": "rate WITHIN, bytes still wrong",
           "cause": "the cfg fix took max_abs_err 241 -> 96 and removed the whole "
                    "rest-of-model contamination; the residue is the DMA fill's 64-byte "
                    "source alignment, which only the padded tile satisfied"}]}

def arm(p):
    global OP
    m = json.load(open(p))["models"]["enc_q16"]
    if OP is None:
        for cand in ("layernorm_pc_s8", "layernorm_s8"):
            if cand in (m.get("per_kind") or {}):
                OP = cand
                break
        else:
            raise SystemExit("no layernorm row in %s: this lab scores a LayerNorm A/B" % p)
    k = (m.get("per_kind") or {}).get(OP) or {}
    return {"path": p, "magic": m.get("soc_magic"), "md5": (m.get("bitstream_md5") or "")[:10],
            "cflags": m.get("kernel_cflags"), "mae": m.get("max_abs_err"),
            "rtf_steady": m.get("rtf_steady"), "steady": m.get("steady_cycles"),
            "engine": m.get("engine") or {},
            "kernel": k.get("kernel"), "dispatches": k.get("dispatches"),
            "cycles": k.get("cycles"), "elements": k.get("elements"),
            "c_per_el": k.get("cycles_per_element"),
            "per_kind": {o: (v.get("cycles"), v.get("cycles_per_element"))
                         for o, v in (m.get("per_kind") or {}).items()}}

off, on = arm(sys.argv[1]), arm(sys.argv[2])
L = []
def P(s=""): L.append(s); print(s)

P("Lab B38  the LayerNorm lane A/B on silicon that contains the lane")
P("  model Moonshine tiny int8, candidate %s -- the encoder, which transcribes"
  % (os.environ.get("CANDIDATE") or "?"))
P("  clock 34.4828 MHz FCLK0   eval one 4.0 s speech window   steady, not cold")
P("  stage encoder, whole graph   scope one operator: %s" % OP)
P("")
for nm, a in (("lane OFF (control)", off), ("lane ON", on)):
    P("  %-19s %s md5 %s  %s" % (nm, a["magic"], a["md5"], a["cflags"]))
    P("      %-16s %s  %s dispatches  %s elements  %s cycles  %.4f c/el"
      % (OP, a["kernel"], a["dispatches"], a["elements"], a["cycles"], a["c_per_el"] or 0))
    e = a["engine"]
    P("      max_abs_err %s   last_rc %s   calls_fallback %s   rtf_steady %s"
      % (a["mae"], e.get("last_rc"), e.get("calls_fallback"),
         None if a["rtf_steady"] is None else round(a["rtf_steady"], 4)))
P("")
ok_control = PRED["control_lo"] <= (off["c_per_el"] or 0) <= PRED["control_hi"]
ok_lane = PRED["lo"] <= (on["c_per_el"] or 0) <= PRED["hi"]
speedup = (off["c_per_el"] / on["c_per_el"]) if (on["c_per_el"] or 0) > 0 else None
P("  PREDICTION, committed before the board (for THIS round -- %s):" % PRED.get("round", "?"))
P("    control  %.2f c/el, band %.1f-%.1f   -> measured %.2f  %s"
  % (PRED["control_c_per_el"], PRED["control_lo"], PRED["control_hi"],
     off["c_per_el"] or 0, "WITHIN" if ok_control else "FALSIFIED"))
P("    lane     %.3f c/el, band %.3f-%.3f -> measured %.3f  %s"
  % (PRED["lane_c_per_el"], PRED["lo"], PRED["hi"], on["c_per_el"] or 0,
     "WITHIN" if ok_lane else "FALSIFIED"))
P("    speed-up on this operator: %s" % (None if speedup is None else round(speedup, 2)))
if PRED.get("encoder_lo") is not None and on["rtf_steady"] is not None:
    _e_ok = PRED["encoder_lo"] <= on["rtf_steady"] <= PRED["encoder_hi"]
    P("    ENCODER rtf_steady %.3f, band %.3f-%.3f -> measured %.4f  %s"
      % (PRED["encoder_rtf_steady"], PRED["encoder_lo"], PRED["encoder_hi"],
         on["rtf_steady"], "WITHIN" if _e_ok else "FALSIFIED"))
    P("      control %.4f -> lane %.4f = %+.2f %%"
      % (off["rtf_steady"], on["rtf_steady"],
         100 * (on["rtf_steady"] - off["rtf_steady"]) / off["rtf_steady"]))
P("")
# THE softmax_s8 TRIPWIRE, and it is the only byte-level check this arm has.
# max_abs_err CANNOT see a wrong-bytes regression here: the lab's host-C golden is rebuilt from
# whatever kernel is selected, so once a lane kernel exists the check compares the new
# arithmetic against itself and passes at 0.  softmax_s8's kernel is `pext_int_memo2`, which
# MEMOISES -- its cost depends on the values it sees -- so its CYCLE COUNT is a side channel for
# "the data changed".  Measured four for four across this lab's own rounds, on the row with the
# second-smallest layout term (0.12 %):
#     B38 mae 241 -> +1.09 %   B39 mae 96 -> +1.72 %   B40 mae 0 -> -0.01 %   B41 mae 0 -> +0.00 %
# BAND AND THRESHOLD, STATED BEFORE THE RUN so a move is a finding and not an explanation:
#   < 0.5 %   expected.  The arms DO change LayerNorm's arithmetic by design (q16 core against
#             pext_int_rsqrt's mantissa/shift core), but ln_pt_check.py measures that at <= 1 LSB
#             on 0.17-0.24 % of elements -- orders below the mae 96-241 that produced 1-2 %.
#   0.5-1.0 % AMBIGUOUS: too big for a 1 LSB perturbation, too small to match a known-bad round.
#             Do not interpret the speed-up until the WER run says which it is.
#   >= 1.0 %  TRIPPED.  That is the scale seen at mae 96 and mae 241.  Treat the arm as
#             wrong-bytes until shown otherwise, whatever max_abs_err says.
sm_off = (off["per_kind"].get("softmax_s8") or (0, 0))[0] or 0
sm_on = (on["per_kind"].get("softmax_s8") or (0, 0))[0] or 0
sm_d = (sm_on / sm_off - 1.0) if sm_off else None
sm_band = ("no softmax_s8 row" if sm_d is None else
           "EXPECTED" if abs(sm_d) < 0.005 else
           "AMBIGUOUS -- do not interpret the speed-up yet" if abs(sm_d) < 0.010 else
           "*** TRIPPED: treat as wrong bytes ***")

# the falsifiers, scored rather than described
lin_off = (off["per_kind"].get("linear_s8") or (0, 0))[0] or 0
lin_on = (on["per_kind"].get("linear_s8") or (0, 0))[0] or 0
lin_drift = (lin_on / lin_off - 1.0) if lin_off else None
eon = on["engine"]
F = [("F1 control in %.1f-%.1f c/el" % (PRED["control_lo"], PRED["control_hi"]), ok_control),
     ("F2 max_abs_err = 0 in both arms", off["mae"] == 0 and on["mae"] == 0),
     ("F3 lane arm did not time out or fall back",
      eon.get("last_rc") != -4 and not eon.get("calls_fallback")
      and (eon.get("polls") or 0) < 20000000),
     ("F4 linear_s8 within +-5 %% between arms (%s)"
      % ("n/a" if lin_drift is None else "%+.1f %%" % (100 * lin_drift)),
      lin_drift is not None and abs(lin_drift) <= 0.05),
     ("F5 the lane arm's kernel is roccmoon_lane (%s)" % on["kernel"],
      on["kernel"] == "roccmoon_lane"),
     ("F6/F7 lane rate inside %.3f-%.3f c/el" % (PRED["lo"], PRED["hi"]), ok_lane),
     ("F8 softmax_s8 tripwire %s -> %s"
      % ("n/a" if sm_d is None else "%+.2f %%" % (100 * sm_d), sm_band),
      sm_d is not None and abs(sm_d) < 0.005)]
# EVERY PICK, DIFFED -- not just the op under test.  The LUT candidates now carry
# target_affinity=("roccmoon",), so the probe prefers them for any roccmoon run whose tree has
# the file; an arm that picked up the LUT lane on gelu_s8 while the other did not would put
# ~10.5 % of somebody else's win inside this operator's delta.  Asserting the two named ops is
# not enough when the mix is moving: diff the whole set and require exactly one difference.
import os as _os
_pk = {}
for _lbl, _p in (("off", sys.argv[1]), ("on", sys.argv[2])):
    _f = _os.path.join(_os.path.dirname(_p), "enc_q16", "gen", "kernel_picks.json")
    _pk[_lbl] = ({k: v.get("algorithm") for k, v in json.load(open(_f))["picks"].items()}
                 if _os.path.exists(_f) else None)
if _pk["off"] and _pk["on"]:
    _d = sorted(k for k in set(_pk["off"]) | set(_pk["on"])
                if _pk["off"].get(k) != _pk["on"].get(k))
    # THE REQUIREMENT DEPENDS ON THE OP, because the two forms use different A/B mechanisms:
    #   layernorm_s8    (per-tensor, QATU)  arms are different FILES -> exactly ONE pick differs
    #   layernorm_pc_s8 (per-channel, R)    arms are the same file switched by -DMBXR_LN_LANE
    #                                       -> the picks must be IDENTICAL, and a difference
    #                                          would mean selection moved under the A/B
    # THE EXPECTED SET COMES FROM WHAT THIS RUN SELECTED, not from a fixed rule.  Hard-wiring
    # it to layernorm_s8 called the both-lanes arm "NOT AN A/B" -- the third time today a rule
    # was pinned to whichever configuration happened to be in front of it.
    #   per-tensor layernorm_s8 : arms are different FILES  -> that op must differ
    #   per-channel layernorm_pc_s8 : same file, -DMBXR_LN_LANE -> NOTHING may differ
    #   --lut-lane-select adds gelu_s8 and tanh_s8 to the expected set
    _exp = set()
    if OP == "layernorm_s8":
        _exp.add(OP)
    if _os.environ.get("LUT_SEL") == "1":
        _exp |= {"gelu_s8", "tanh_s8"}
    _want_one = bool(_exp)
    _ok = (set(_d) == _exp)
    P("  PICKS DIFFERING BETWEEN THE ARMS: %s  -> %s"
      % (", ".join(_d) or "none",
         ("isolates exactly the %d selected op(s)" % len(_exp) if _ok
          else "*** NOT AN A/B: expected %s ***" % ", ".join(sorted(_exp)))
         if _want_one else
         ("identical, as this op's A/B requires (the define switches it, not the file)" if _ok
          else "*** selection MOVED under an A/B that switches on a define ***")))
    for _k in _d:
        P("     %-16s %s -> %s" % (_k, _pk["off"].get(_k), _pk["on"].get(_k)))
else:
    P("  PICKS: no kernel_picks.json beside a record -- the arms are NOT verified matched")
P("")
P("  FALSIFIERS, committed before the board:")
for name, ok in F:
    P("    %-52s %s" % (name, "ok" if ok else "*** FAILED ***"))
P("")
P("  THE THREE THINGS THAT TOGETHER SAY A LANE COMPUTED A MODEL'S OPERATOR (8.15.25):")
P("    1. byte-identical output in both arms       %s / %s  -> %s"
  % (off["mae"], on["mae"], "yes" if off["mae"] == 0 and on["mae"] == 0 else "NO"))
P("    2. the control reproduces its own baseline (%.2f)  %.2f -> %s"
  % (PRED["control_c_per_el"], off["c_per_el"] or 0, "yes" if ok_control else "NO"))
P("    3. the lane arm near its predicted rate     %.3f -> %s"
  % (on["c_per_el"] or 0, "yes" if ok_lane else "NO"))
P("")
P("  every other kind, so a whole-run degradation cannot hide inside one row:")
P("    %-18s %14s %14s %8s" % ("kind", "off cycles", "on cycles", "on/off"))
for o in sorted(set(off["per_kind"]) | set(on["per_kind"])):
    a = off["per_kind"].get(o, (0, 0))[0] or 0
    b = on["per_kind"].get(o, (0, 0))[0] or 0
    P("    %-18s %14d %14d %8s" % (o, a, b, "%.2f" % (b / a) if a else "-"))
json.dump({"lab": "B38 ln_lane A/B", "op": OP, "prediction": PRED,
           "control": off, "lane": on, "speedup": speedup,
           "control_within": ok_control, "lane_within": ok_lane,
           "linear_s8_drift": lin_drift,
           "softmax_tripwire": {"delta": sm_d, "verdict": sm_band,
                                "why": "pext_int_memo2 memoises, so its cycle count is a side "
                                       "channel for a change in the data; max_abs_err cannot "
                                       "see one once the golden is rebuilt from the kernel "
                                       "under test"},
           "falsifiers": {n: bool(v) for n, v in F},
           "verdict": "PASS" if all(v for _, v in F) else "FALSIFIED"},
          open(sys.argv[3], "w"), indent=1)
PY
info "wrote out/$NAME.json and out/$NAME.txt"
