#!/usr/bin/env python3
"""Load and run the L2-miss-path bitstreams (MEMORY_BANDWIDTH.md section 6) -- and any
other bandwidth-lab bitstream whose correctness depends on FCLK1.

    0x5A5A000B  (a) 12 L2 MSHRs                                   FCLK0 only
    0x5A5A000C  (a) 256 KB L2                                     FCLK0 only
    0x5A5A000D  (b) tiles on FCLK0, the L2 and the uncore on FCLK1  FCLK0 + FCLK1
    0x5A5A0008  lever 2, re-run at a verified FCLK1                 FCLK0 + FCLK1

WHY THE CLOCK COMES FROM A FILE AND NOT FROM AN ARGUMENT.  scripts/43_rocket_bwlab.sh calls
its runner twice over ssh with a fixed argument list, and env.sh resets PYNQ_ENV, so
there is no channel for a per-run value.  scripts/45_rocket_bwl2lab.sh therefore writes
bwl2_run.json next to this file on the board immediately before the lab and deletes it
immediately after; this runner REFUSES to run without it, so a stale or missing file is a
loud failure rather than a silently wrong clock.

WHY IT SETS FCLK1 AT ALL.  Nothing in this repo used to.  The PS keeps whatever the PYNQ
boot image programmed -- FCLK1 = 142.8571 MHz on the bench board -- and lever 2's
0x5A5A0008 ran its memory domain there while every row logged 100
(fpga/pynq-z2/bwlab/errata.csv).  So FCLK1 is SET through pynq.ps.Clocks, then READ BACK
from the SLCR with host/fclk.py (not an inline decode), and the readback is printed as
one `FCLK_READBACK {json}` line for the lab to record beside the md5.  A readback outside
0.5 % of the request stops the run before the SoC leaves reset.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(HERE, "bwl2_run.json")


def verify(want0, want1):
    """Read the PS clocks back with host/fclk.py; exit before measuring if either is off."""
    import fclk
    clocks = fclk.read_fclks()
    print("FCLK_READBACK " + json.dumps(clocks, separators=(",", ":")))
    checks = [(0, want0)] + ([(1, float(want1))] if want1 is not None else [])
    for n, want in checks:
        got = clocks[f"fclk{n}"]["mhz"]
        if got is None or abs(got - want) > want * 0.005:
            sys.exit(f"FCLK{n} reads {got} MHz, expected {want}: refusing to measure")
        print(f"FCLK{n} verified: {got:.4f} MHz")


def main():
    if not os.path.exists(CFG_PATH):
        sys.exit(f"{CFG_PATH} is missing: run this through scripts/45_rocket_bwl2lab.sh, "
                 f"which writes the MAGIC and FCLK1 this run is for")
    cfg = json.load(open(CFG_PATH))
    run_rocket.EXPECT_MAGIC = int(cfg["magic"], 16)
    # 1000 MHz / 29, to four places: the tiles' clock on every bitstream here.
    run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)
    want1 = cfg.get("fclk1_mhz")
    loading = "--no-load" not in sys.argv

    if not loading:
        # The SoC is about to leave reset: the clocks must already be right.
        verify(run_rocket.DEFAULT_FCLK, want1)
        run_rocket.main()
        return

    # Loading: run_rocket downloads the bitstream, sets FCLK0 and (with --hold) leaves the
    # SoC in reset.  FCLK1 is changed only then, while nothing in the PL is running on it.
    run_rocket.main()
    if want1 is not None:
        from pynq.ps import Clocks
        before = Clocks.fclk1_mhz
        Clocks.fclk1_mhz = float(want1)
        print(f"FCLK1: {before:.4f} -> {Clocks.fclk1_mhz:.4f} MHz (asked for {want1})")
    verify(run_rocket.DEFAULT_FCLK, want1)


if __name__ == "__main__":
    main()
