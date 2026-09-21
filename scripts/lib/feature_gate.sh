# SPDX-License-Identifier: Apache-2.0
#
# THE FEATURE GATE, for labs.  Source it next to bitstream_id.sh:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/bitstream_id.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/feature_gate.sh"
#
#   LAB_REQUIRES="rocc_engine ln_lane"      # <- at the top of the lab, beside WANT_MAGIC
#   ...
#   bitstream_identify "$BIT"; bitstream_gate
#   feature_gate "$D/gen/kernel_picks.json" "$CF"
#
# WHAT IT ADDS TO bitstream_id.sh, which it does not replace.  bitstream_id.sh answers "is this
# build one a lab has been validated against" and refuses builds nobody has measured.  It cannot
# answer "does this build CONTAIN the thing I am about to dispatch to", because an md5 in
# BIT_ACCEPTED is a statement about a lab's history, not about silicon.  b30_lnab_on passed
# bitstream_gate cleanly and then dispatched LayerNorm to a lane that 0x5A5A0028 does not have.
#
# LAB_REQUIRES IS REQUIRED, not optional.  Unset or empty is a refusal; a lab that genuinely
# needs no accelerator writes LAB_REQUIRES="none" and that shows up in its run record.  A
# declaration a lab can omit is one it will omit.
#
# AND THE DECLARATION IS THE WEAKER HALF.  The half that actually caught b30_lnab_on is the
# kernel_picks.json argument: selection, having run, names the kernel that will be compiled in,
# and a `roccmoon_lane` pick requires a lane whoever wrote the lab and whatever they believed.
# PASS THE PICKS FILE FROM *THIS* BUILD.  The same candidate with the same cflags was served
# `reference` for layernorm_pc_s8 in Lab B30 and `roccmoon_lane` a day later: nothing in the
# configuration moved, only what selection resolved to, so a cached or assumed answer from a
# previous run of the same config passes both.
#
# Exports, for the lab to put in its run record:
#   LAB_FEATURES   what the loaded build contains
#   FEATURE_GATE   the gate's JSON record (path), written into the run directory
feature_gate () {
  local picks="${1:-}" cflags="${2:-}" out="${FEATURE_GATE_OUT:-}"
  local py="$IISWC_ROOT/fpga/pynq-z2/scripts/feature_gate.py"
  [ -x "$py" ] || die "feature gate: $py is missing -- no lab may dispatch without it"
  [ -n "${LAB_REQUIRES:-}" ] || die "feature gate: this lab declares no LAB_REQUIRES.
       Say which hardware features it needs -- e.g. LAB_REQUIRES=\"rocc_engine ln_lane\" --
       or LAB_REQUIRES=\"none\" if it needs none.  Omitting it is a refusal: this is the
       check b30_lnab_on did not have."
  [ -n "${BIT_MD5:-}" ] || die "feature gate: call bitstream_identify before feature_gate --
       the feature set is keyed on the md5 of the file you loaded, never on WANT_MAGIC."
  local args=(gate --md5 "$BIT_MD5" --magic "${WANT_MAGIC:-}" --requires "$LAB_REQUIRES"
              "--cflags=$cflags" --where "${NAME:-this lab}")
  [ -n "$picks" ] && { [ -f "$picks" ] || die "feature gate: no kernel_picks.json at $picks --
       selection is what decides which hardware this image touches, and without it this gate
       is checking intent instead of behaviour"; args+=(--picks "$picks"); }
  [ -n "$out" ] && args+=(--emit-json "$out")
  python3 "$py" "${args[@]}" || die "the feature gate refused this run (see above)"
  LAB_FEATURES="$(python3 "$py" features "$BIT_MD5" | head -1 | awk '{print $NF}')"
  FEATURE_GATE="$out"
  export LAB_FEATURES FEATURE_GATE LAB_REQUIRES
}

# Replay a finished run record through the same checks -- the feature gate AND the symptom
# checks (MBXR_E_TIMEOUT with fallbacks, a stuck cyc_busy, a poll count at its budget).  A lab
# calls this on its own run.json after the parser, so a run that dispatched into a hole cannot
# be reported as a measurement.
feature_audit () {
  local py="$IISWC_ROOT/fpga/pynq-z2/scripts/feature_gate.py"
  python3 "$py" audit "$@" || die "the run audit refused this record (see above):
       the numbers in it are not a measurement of what the lab set out to measure."
}

# Does the MAGIC this lab is aiming at provide a feature?  A HINT, NOT THE GATE, and the
# difference matters: this is keyed on WANT_MAGIC -- which the lab sets -- because it has to be
# answerable BEFORE codegen, and codegen is what produces the picks the real gate needs.  Use it
# only for build-time choices that are safe to get wrong (MB_BUF_ALIGN64), never to decide
# whether a dispatch may happen.  feature_gate() still keys on the md5 of the file loaded, and
# still refuses if the two disagree.
magic_provides () {
  local magic="${1:?}" feat="${2:?}"
  local py="$IISWC_ROOT/fpga/pynq-z2/scripts/feature_gate.py"
  [ -x "$py" ] || return 1
  python3 "$py" features "$magic" 2>/dev/null | awk 'NR==1{print $NF}' | tr ',' '\n' \
    | grep -qx "$feat"
}

# 64-BYTE-ALIGNED INTERMEDIATES, for labs that dispatch to a lane.  mbxd_dma.v:71 requires the
# fill source and drain destination to be 64-byte aligned and generate_skeleton.py emits them
# 8-byte aligned, so without this a lane kernel must STAGE -- and LANE_DISPATCH_RULES.md rule 0
# prices that copy at 380x the lane.  Measured at +0.020 % of encoder steady once the one
# layout-sensitive row is set aside (Lab B41), against 6.5527 -> 3.8632 c/el on the LayerNorm
# lane.  Scoped to lane labs on purpose: a graph that does not ask still emits a byte-identical
# buffers.c, which is the first of the flag author's two reasons and still holds.
lane_align_buffers () {
  local magic="${1:-${WANT_MAGIC:-}}"
  [ -n "${MB_BUF_ALIGN64+x}" ] && return 0          # an explicit setting always wins
  for f in ln_lane attn_lane lut_lane; do
    if magic_provides "$magic" "$f"; then
      export MB_BUF_ALIGN64=1
      info "MB_BUF_ALIGN64=1 ($magic provides $f; mbxd_dma.v:71 wants 64-byte buffers)"
      return 0
    fi
  done
  return 0
}
