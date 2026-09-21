#!/usr/bin/env python3
"""Load the camera bitstream (0x5A5A001E) and run a program on it.

run_rocket_roccmoon.py with a different MAGIC.  The SoC is 0x5A5A0010 plus a TLI2C at
0x1004_0000 and the HM01B0 capture peripheral at 0x1008_0000, and adding the TLI2C RENUMBERED the
PLIC: the UART is source 2 here, not 1.  So an image built for chipyard_pynqz1_micrgb boots here
with its console interrupt on the I2C controller's source, and an image built for
chipyard_pynqz1_cam does the reverse on 0x5A5A0006/0010.  The MAGIC is what keeps the two apart.

MAGIC registry (fpga/pynq-z2/MAGIC_REGISTRY.md):
  0x5A5A0010  full-feature + the decoupled RoCC engine on hart 1
  0x5A5A001E  + the HM01B0 camera: ospi capture with DMA, TLI2C (docs/CAMERA_Z1.md)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_001E
# 1000 MHz / 29, to four places. Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)

if __name__ == "__main__":
    run_rocket.main()
