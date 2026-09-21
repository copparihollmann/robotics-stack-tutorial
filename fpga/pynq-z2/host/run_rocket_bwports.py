#!/usr/bin/env python3
"""Load the lever-3 bitstream: the bandwidth instrument with two memory channels.

Identical to run_rocket_micrgb.py except for the MAGIC it insists on.  The SoC is
register-compatible with 0x5A5A0006 for everything the other labs touch -- same UART,
same microphone, same GPIO, same DRAM window -- so an image built for either boots
happily on the other and says nothing about which one it is running on.  What differs is
a TileLink client on the system bus and an MMIO block at 0x100A_0000, and a bandwidth
lab that ran against 0x5A5A0006 would read zeros out of a device that is not there and
report a perfectly formed 0.00 B/cycle.

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
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_0009
# 1000 MHz / 29, to four places. Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)

if __name__ == "__main__":
    run_rocket.main()
