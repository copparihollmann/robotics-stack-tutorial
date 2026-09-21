#!/usr/bin/env python3
"""Load lever 4's second point: the bandwidth instrument on a 256-bit TileLink system bus.

Identical to run_rocket_bwwide.py except for the MAGIC it insists on.  Everything software
can see is register-compatible with 0x5A5A0007 and 0x5A5A000A -- the same UART, microphone,
GPIO, DRAM window and instrument registers -- so an image boots on any of them.  What
differs is the width of every beat on the system bus, and a lab that ran against the wrong
one would report a perfectly well-formed bytes-per-cycle figure for another machine.

MAGIC registry (tcl/build_rocket.tcl):
  0x5A5A0001  DRAM self-test
  0x5A5A0002  rocket + TACIT
  0x5A5A0003  dual-core
  0x5A5A0004  + MBP P-ext
  0x5A5A0005  + PDM microphone
  0x5A5A0006  + RGB LEDs                 (the full-feature build)
  0x5A5A0007  + the TileLink bandwidth instrument          (lever 1)
  0x5A5A0008  + the memory bus on FCLK1 at 100 MHz          (lever 2)
  0x5A5A0009  + a second memory channel into S_AXI_HP1     (lever 3)
  0x5A5A000A  + a 128-bit TileLink system bus              (lever 4)
  0x5A5A000E  + the L2 miss path agent's ReleaseAck-first cork
  0x5A5A000F  + a 256-bit TileLink system bus              (lever 4, second point)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_000F
# 1000 MHz / 29, to four places. Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)

if __name__ == "__main__":
    run_rocket.main()
