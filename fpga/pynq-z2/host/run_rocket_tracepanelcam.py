#!/usr/bin/env python3
"""Bring up 0x5A5A0039 -- THE TRACE BITSTREAM.  Lab B138, variant `tracepanelcam`.

    sudo python3 run_rocket_tracepanelcam.py --bitstream pynqz1_rocket_micrgb_tracepanelcam.bit --hold
    sudo python3 run_rocket_tracepanelcam.py --no-load --elf zephyr.bin

This is run_rocket_micrgb.py with two values changed: the MAGIC at GP0 offset 0x08 and the
clock.  Everything else -- the address fold, the reset/custom_boot sequence, the image load
and read-back -- is run_rocket.py's and is shared.

WHAT THIS SILICON IS.  Two harts, a TacitEncoder and a TraceSinkDMA on EACH of them
(0x300_0000 / 0x300_1000 and 0x301_0000 / 0x301_1000), the MBP P-extension on hart 0, the
PDM microphone, the six RGB pins, a TLI2C at 0x1004_0000, BTN0..BTN3 on GPIO pins 6..9, and
the HM01B0 capture DMA at 0x1008_0000 -- and NO RoCC ENGINE.  40.0000 MHz (1000/25).

WHY IT NEEDS ITS OWN RUNNER AND NOT run_rocket_roccmoon.py's family.  That script's
EXPECT_BY_RUNNER table is the ENGINE family, and this machine has no engine: hart 1 has no
RoCC decode table at all, so every custom-1 dispatch raises an illegal instruction
(mcause 2) rather than running anything.  An engine-family runner name here would claim a
machine that does not exist.

WHY A SEPARATE MAGIC AT ALL.  An image built for chipyard_pynqz1_panel_f40 (0x5A5A0037)
boots here with a CORRECT CONSOLE -- the two SoCs put the UART on the same PLIC source 2 --
and then traps the first time it dispatches to the engine.  Nothing in devicetree can see
the difference, because a RoCC has no devicetree node.  The MAGIC is the only gate.

MAGIC registry (fpga/pynq-z2/MAGIC_REGISTRY.md):
  0x5A5A0035  the Nch = 8 engine machine, 40 MHz              (the measurement bitstream)
  0x5A5A0037  ... + TLI2C + the four buttons: the panel
  0x5A5A0038  ... + the camera's ospi capture DMA, TACIT dropped
  0x5A5A0039  the panel + the camera, TACIT KEPT, ENGINE DROPPED  (this script)

Its Zephyr board is boards/chipyard/pynqz1_trace_f40 (chipyard_pynqz1_trace_f40).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_0039
# 1000 MHz / 25, exactly 40.  Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = round(1000.0 / 25.0, 4)

if __name__ == "__main__":
    run_rocket.main()
