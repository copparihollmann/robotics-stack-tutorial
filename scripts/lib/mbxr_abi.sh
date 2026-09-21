#!/usr/bin/env bash
# THE PAIRING NOBODY COULD SEE: a guest image and a bitstream have an ABI between them, and
# neither can check the other at runtime.  This refuses an incompatible pair BEFORE a board
# lock is taken, which is the difference between a build error and a burned board session.
#
#   . scripts/lib/mbxr_abi.sh
#   mbxr_abi_gate <guest.elf|guest.bin> <0x5A5A....>
#
# WHY IT EXISTS, and the cost of not having it.  The engine's `st` command carries the drain's
# descriptor in rs2.  Before 0x5A5A002E that was `nblocks[15:0]` and nothing else; from 002E it
# is {row_stride[63:32], row_bytes[31:16], nrows[15:0]}.  The row count is deliberately in the
# low sixteen bits so a FLAT descriptor means the same thing to both engines (mbxr.h) -- but
# only for an image built from a tree that knows that.  The two ways to get it wrong are both
# SILENT: each ends in MBXR_E_TIMEOUT after 20 M fence polls, with no error bit set and nothing
# on the console to say why.
#
#   a v2 image on a pre-002E engine   the engine read `nblocks` out of the wrong field
#   a pre-v2 image on a 002E engine   the engine reads row_bytes = 0 and never starts the drain
#
# The first of those cost FOUR BOARD RUNS across two boards and two workstreams on 2026-09-18,
# each looking like a different local problem (a mid-edit race on one board, "the engine never
# ran on illixr" on the other) because the symptom is identical wherever it happens and the
# guest cannot report it.
#
# HOW AN IMAGE SAYS WHAT IT SPEAKS.  mbxr.h's MBXR_ABI_STAMP puts one string in the image:
# "MBXR_ABI:v2:strided=0" or "...=1".  No stamp at all means a tree from before this existed.
# That is read with `strings`, not by running anything, so this gate costs nothing and needs no
# board.  It is the same class of protection as tcl/build_rocket.tcl's AA_SIZE_MISSING, one
# level down: there the BITSTREAM is checked against its collateral, here the GUEST is checked
# against the bitstream.

# MAGICs whose engine carries the 2-D drain descriptor.  Add a MAGIC here in the same commit
# that claims it in fpga/pynq-z2/MAGIC_REGISTRY.md.
#
# 0x5A5A0031 AND 0x5A5A0032 WERE MISSED WHEN THEY WERE CLAIMED, and the omission cost B83 two
# board arms: both encoder arms were refused with MBXR_ABI_MISMATCH ("0x5A5A0032 has no 2-D
# descriptor") while the decoder arms, whose cflags do not ask for the strided drain, passed.
# Both ARE 2-D, and the evidence is not a reading of this table:
#   * both pin their engine RTL by md5 to fpga/pynq-z2/src/lanes_engine_002f/, whose
#     mbxr_st.v is 36870fb3b757a74197c4a8cd4d0f5767 -- BYTE-IDENTICAL to
#     src/lanes_engine_002e/mbxr_st.v, and 0x5A5A002E (d6112edd) is the build that
#     introduced the 2-D descriptor;
#   * MAGIC_FEATURES.tsv carries `drain_2d` on both rows;
#   * THE SILICON REPORTS IT.  samples/roccmoon_bench on 0x5A5A0032 md5 d37b9abb printed
#     `RMB_ENGINE_SIG sig=4d53 drain=2d asked=0` -- a runtime readback off the PL, the same
#     signature 0x5A5A0030 prints.  archive/runs/b83_all_levers/.
#
# THIS IS THE THIRD MAGIC-KEYED ALLOWLIST a newly claimed MAGIC has to be added to, and
# nothing enumerates them for whoever claims the next one.  The other two are
# EXPECT_BY_RUNNER in fpga/pynq-z2/host/run_rocket_roccmoon.py (a missing entry reads the
# MAGIC correctly off the PL and then refuses it, so the failure looks like a bad bitstream)
# and the CAP=4 `case` in scripts/57 and scripts/58 (whose WILDCARD DEFAULT is CAP=3, so a
# missing entry silently changes the engine's outstanding cap instead of failing).  Those two
# fail loudly and silently respectively; this one fails loudly.  A MAGIC claim is not finished
# until all three are updated.
# 0x5A5A0034 ADDED 2026-09-19 (B98), AND THIS IS THE THIRD TIME THIS LIST HAS BEEN STALE.
#   0x5A5A0031/0032 cost B83 two board arms (see above); 0x5A5A0034 refused B98's shipping-config
#   encoder arm the same way, with the same message, for the same reason.
#   THE EVIDENCE, to the standard this file already sets:
#     * src/lanes_engine_b98nch8/mbxr_st.v is md5 36870fb3b757a74197c4a8cd4d0f5767 -- BYTE FOR
#       BYTE lanes_engine_002f/mbxr_st.v, which is 0x5A5A002F/0030/0031/0032's drain, already
#       on this list.  The `st` rs2 decode in mbxr_engine.v differs only in line numbers.
#     * THE ENGINE REPORTS IT: Verilator on the exact b98nch8 sources prints engine id
#       0000000804024d53 -- signature 0x4D53 = MBXR_ID_STRIDE = 'MS' (the 2-D descriptor),
#       NCH 8.  archive/b98_nch8_width/D_engine8_host8_pport4bit.log.
#   0x5A5A0033 is deliberately NOT added: it HAS the descriptor, but it is in bitstream_refused()
#   for discarding weight plane 7, so no image should ever be paired with it.
MBXR_ABI_2D_MAGICS="${MBXR_ABI_2D_MAGICS:-0x5A5A002E 0x5A5A002F 0x5A5A0030 0x5A5A0031 0x5A5A0032 0x5A5A0034 0x5A5A0035}"

mbxr_abi_stamp_of () {          # prints v2:strided=N, or "none"
  local img="$1"
  [ -f "$img" ] || { echo "none"; return; }
  local s
  s=$(strings -a "$img" 2>/dev/null | grep -m1 -o 'MBXR_ABI:v2:strided=[01]' || true)
  if [ -n "$s" ]; then echo "${s#MBXR_ABI:}"; else echo "none"; fi
}

mbxr_abi_is_2d () {             # is this MAGIC a 2-D-descriptor engine?
  local m
  for m in $MBXR_ABI_2D_MAGICS; do
    [ "$(echo "$1" | tr 'a-f' 'A-F')" = "$(echo "$m" | tr 'a-f' 'A-F')" ] && return 0
  done
  return 1
}

# mbxr_abi_gate <image> <magic>.  Prints one line on success; dies with the reason otherwise.
mbxr_abi_gate () {
  local img="$1" magic="$2"
  [ -n "$img" ] && [ -n "$magic" ] || { echo "mbxr_abi_gate: need <image> <magic>" >&2; return 2; }
  local stamp; stamp=$(mbxr_abi_stamp_of "$img")

  if mbxr_abi_is_2d "$magic"; then
    case "$stamp" in
      none)
        echo "MBXR_ABI_MISMATCH: $magic carries the 2-D drain descriptor, and $(basename "$img")" >&2
        echo "  has NO MBXR_ABI stamp -- it was built from a tree older than the descriptor, so" >&2
        echo "  its flat \`st\` word leaves row_bytes = 0, the drain never starts, and every" >&2
        echo "  dispatch returns MBXR_E_TIMEOUT with no error bit.  Rebuild the guest from a" >&2
        echo "  tree at or after commit b18823c, or point this lab at a pre-002E bitstream." >&2
        return 1 ;;
      v2:strided=*)
        echo "MBXR_ABI_OK: $magic (2-D drain) with $stamp" ; return 0 ;;
    esac
  else
    case "$stamp" in
      v2:strided=1)
        echo "MBXR_ABI_MISMATCH: $(basename "$img") was built with the STRIDED drain asked for" >&2
        echo "  (strided=1) and $magic has no 2-D descriptor.  The runtime's id check would fall" >&2
        echo "  back to the flat drain and the answers would be right, but the arm would not be" >&2
        echo "  the arm you think you are measuring.  Build with strided=0 for this bitstream." >&2
        return 1 ;;
      v2:strided=0|none)
        echo "MBXR_ABI_OK: $magic (flat drain) with ${stamp}" ; return 0 ;;
    esac
  fi
  echo "MBXR_ABI_MISMATCH: unrecognised stamp '$stamp'" >&2
  return 1
}
