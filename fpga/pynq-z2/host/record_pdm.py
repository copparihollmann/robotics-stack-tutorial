#!/usr/bin/env python3
"""Record the PYNQ-Z1's on-board PDM microphone, using PYNQ's own base overlay.

    sudo python3 record_pdm.py --seconds 1.0 --out mic.raw

RUNS ON THE BOARD, not on the host, and it LOADS THE PYNQ BASE OVERLAY -- which
overwrites whatever is in the PL, Rocket included.  Wrap the caller in
scripts/with_board.sh and reload your bitstream afterwards.

Why this exists.  Before designing a decimator it is worth knowing that the part is
there and running, and this is the cheapest possible way to find out: the PYNQ base
overlay already contains Digilent's `audio_direct` IP wired to F17/G18, and its
capture path hands the raw PDM bitstream straight to software.  What comes back is
NOT PCM -- it is one 16-bit group of PDM bits per 32-bit word, MSB first, at
100 MHz / 32 / 16 = 195.3 kwords/s, i.e. a 3.125 MHz PDM clock.

pynq.lib.audio.AudioDirect.record() is used as-is; the `.pdm` file it can write is a
WAV container with the PDM bits in the sample field, which is confusing, so this
writes the raw int32 words instead and leaves interpretation to the caller.
"""
import argparse
import sys

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=1.0)
    ap.add_argument("--out", default="mic.raw")
    ap.add_argument("--bits", default=None,
                    help="also write the unpacked bitstream as ASCII '0'/'1', one "
                         "character per PDM sample (what sim/tb_pdm_replay.sv reads)")
    args = ap.parse_args()

    from pynq.overlays.base import BaseOverlay
    ol = BaseOverlay("base.bit")
    au = ol.audio
    print("audio IP at 0x%08x" % au.mmio.base_addr)

    au.record(args.seconds)
    words = au.buffer.astype("<i4")
    words.tofile(args.out)

    w16 = (words.astype(np.uint32) & 0xFFFF).astype(">u2")
    bits = np.unpackbits(w16.view(np.uint8))
    print("words        %d" % words.size)
    print("pdm bits     %d" % bits.size)
    print("density      %.6f" % bits.mean())
    print("word rate    %.1f Hz (measured by the polling loop)" % au.sample_rate)
    print("wrote        %s (%d bytes)" % (args.out, words.nbytes))
    if args.bits:
        with open(args.bits, "wb") as f:
            f.write(bytes((bits + 48).astype(np.uint8)))
        print("wrote        %s (%d bytes)" % (args.bits, bits.size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
