#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The curated kernel tree and the ModelBlaster codegen for the GTSRB sign demo, in ONE place
# because two scripts need them to be the same object: scripts/82_sign_host_tests.sh builds
# the host-C model from this gen, and scripts/83_rocket_sign_live.sh links the very same gen
# into the guest.  If they drifted, the host's accuracy number and the board's class would be
# statements about two different networks and nobody would be able to tell.
#
#   sign_compose_kernels <dest-dir>            the curated tree
#   sign_codegen <ir-dir> <gen-dir> <cur-dir> <log>
#   sign_kernel_gate <gen-dir>/kernel_picks.json
#
# THE TREE IS scripts/78's, LINE FOR LINE, and that is the point: Lab B121 measured this
# network at 13,920,859 cycles with exactly these kernels, and a demo built with a different
# selection would not be comparable with it.  The two removals 78 makes for its own graph
# (the softmax row/memo variants, the permute block kernel) are kept even though this graph
# has no permute, because taking them out would change which softmax kernel is picked.
set -euo pipefail

sign_compose_kernels () {
  local cur="$1"
  local kernels="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels"
  local kernels_t1="$IISWC_ROOT/fpga/pynq-z2/modelblaster/kernels_t1"

  rm -rf "$cur"; cp -r "$kernels" "$cur"
  rm -f "$cur/pext_nl/pext_nl_softmax_s8_pext_int_row.c" \
        "$cur/pext_nl/pext_nl_softmax_s8_pext_int_memo.c"
  cp "$kernels_t1/pext_nl/pext_nl_permute4_s8_pext_block.c" "$cur/pext_nl/"
  rm -f "$cur/pext_nl/pext_nl_gelu_s8_pext_int_lut.c" \
        "$cur/pext/pext_gelu_s8_pext_memo_lut.c" \
        "$cur/pext/pext_tanh_s8_pext_memo_lut.c" \
        "$cur/roccmoon/roccmoon_layernorm_s8_roccmoon_lane.c"
  need_file "$cur/roccmoon/roccmoon_conv2d_s8_roccmoon_engine.c" "no roccmoon engine conv kernel"
  need_file "$cur/pext/pext_conv2d_s8_pext_patch_dot8.c" \
      "no curated MBP convolution -- it is the kernel the engine falls back TO, and without it
       a declined dispatch would land on reference C without saying so"
}

sign_codegen () {
  local ir="$1" gen="$2" cur="$3" log="$4"
  local mb="$ZCS/modelblaster"
  local py="$ZCS/tools/miniforge3/envs/zephyr/bin/python"
  [ -x "$py" ] || py=python3

  mkdir -p "$gen"
  ( cd "$ZCS" && "$py" -m modelblaster.pipeline.generate_skeleton \
      --ir "$ir/graph.json" --weights "$ir/weights.npz" --io "$ir/io.npz" \
      --out-dir "$gen" --backend roccmoon ) > "$log" 2>&1 \
    || { tail -30 "$log"; die "generate_skeleton failed"; }
  ( cd "$ZCS" && "$py" -m modelblaster.pipeline.generate_kernels \
      --ir "$ir/graph.json" --out-dir "$gen" --backend reference --target roccmoon \
      --quant int8 --io "$ir/io.npz" --repo-root "$mb" --build-dir "$gen.kverify" \
      --harness-dir "$mb/harness" --cache-dir "$gen.cache" --algorithms all \
      --global-curated-dir "$cur" ) >> "$log" 2>&1 \
    || { tail -30 "$log"; die "generate_kernels failed"; }
  need_file "$gen/kernels.c" "codegen produced no kernels"
}

# WHICH KERNEL WILL SERVE EACH OP, PRINTED AND THEN GATED.
#
# This demo is required to run on the accelerator, so the gate has to be able to tell three
# things apart that all look alike in a cycle count (Lab B121 lost nothing to this only
# because it went looking):
#
#   conv2d_s8 -> roccmoon/roccmoon_engine   ACCEPTED.  The engine kernel is linked, so it is
#                                           CONSULTED on every dispatch and calls_fallback
#                                           counts the ones it declines.  It declines a 3x3
#                                           spatial convolution by construction (its guard is
#                                           IH==1 && KH==1 && PH==0) and hands the dispatch to
#                                           the curated MBP patch/DOT8 kernel.  That is the
#                                           P-extension, and it is what this demo runs on.
#   conv2d_batchnorm2d_s8 -> reference      REFUSED HERE, unlike in scripts/78 where it is the
#                                           subject.  The composite has no curated kernel on
#                                           any backend, so the backbone would be reference C
#                                           with soft-float in it -- 26x slower, and the engine
#                                           never even consulted, with calls_fallback sitting
#                                           at 0 looking like success.
#   anything else                           REFUSED.
sign_kernel_gate () {
  local picks="$1"
  local py="$ZCS/tools/miniforge3/envs/zephyr/bin/python"
  [ -x "$py" ] || py=python3

  "$py" -c "
import json,sys
p=json.load(open(sys.argv[1]))['picks']
for k in sorted(p): print('    %-24s %-18s %s'%(k,p[k].get('source'),p[k].get('algorithm')))" "$picks"
  "$py" -c "
import json,sys
p=json.load(open(sys.argv[1]))['picks']
c=p.get('conv2d_s8'); b=p.get('conv2d_batchnorm2d_s8')
if b is not None:
    sys.exit('this IR has conv2d_batchnorm2d_s8: its BatchNorm is NOT folded, so the backbone '
             'has no curated kernel on any backend and would run reference C with soft-float. '
             'Use the folded IR (archive/b121/fold_ab/signnet_lite_gray_FIXED_folded).')
if c is None:
    sys.exit('this graph has no conv2d_s8 -- not a SignNet arm')
if c.get('algorithm')!='roccmoon_engine':
    sys.exit('conv2d_s8 picked %s/%s, not roccmoon_engine -- the engine would never be '
             'consulted and calls_fallback would not count the convolutions'
             % (c.get('source'), c.get('algorithm')))
for op in ('maxpool2d_s8','linear_s8','softmax_s8'):
    if op in p and p[op].get('source')=='reference':
        sys.exit('%s fell back to reference C; this lab is written for the curated tree' % op)
print('    backbone: conv2d_s8 -> roccmoon_engine  (the guard is consulted per dispatch;')
print('              a 3x3 spatial convolution is declined and served by the curated MBP')
print('              patch/DOT8 kernel, which is what calls_fallback counts)')
" "$picks" || die "the curated tree did not select a backbone this lab can report honestly"
}

# The input scale, the output scale and the class count, read from the IR and handed to the
# guest as -D flags.  sign_pre.c quantises with SIGN_IN_SCALE_RECIP and main.c turns the
# softmax output into a percentage with SL_OUT_SCALE_PPB; taking both from graph.json means an
# IR with a different grid cannot be fed a tensor quantised for this one.
sign_scale_defs () {
  local ir="$1"
  local py="$ZCS/tools/miniforge3/envs/zephyr/bin/python"
  [ -x "$py" ] || py=python3

  "$py" -c "
import json,sys
g=json.load(open(sys.argv[1]))
t=g['tensors']
qi=t[g['input']['tensor']]['quant']; qo=t[g['output']['tensor']]['quant']
r=1.0/float(qi['scale'])
if int(qi['zero_point'])!=0 or abs(r-round(r))>1e-6:
    sys.exit('input grid is not a symmetric integer reciprocal: %r' % qi)
n=t[g['output']['tensor']]['shape'][-1]
if n!=43: sys.exit('this graph has %d outputs, not 43' % n)
print('SIGN_IN_SCALE_RECIP=%d SL_OUT_SCALE_PPB=%du' % (round(r), round(float(qo['scale'])*1e9)))
" "$ir/graph.json"
}
