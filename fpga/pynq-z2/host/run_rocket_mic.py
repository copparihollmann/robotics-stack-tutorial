#!/usr/bin/env python3
"""Bring up the dual-core big.LITTLE Rocket + MBP P-ext WITH the PDM microphone.

    sudo python3 run_rocket_mic.py --bitstream pynqz1_rocket_mic.bit --hold
    sudo python3 run_rocket_mic.py --no-load --elf zephyr.bin

This is run_rocket_pext.py with one value changed: the MAGIC at GP0 offset 0x08.

WHY A SEPARATE MAGIC. This design is PynqZ2RocketBigLittlePextTacitConfig plus one MMIO
peripheral on the periphery bus. Both harts, both ISA strings, the UART, the clock, the
address fold and the reset sequence are identical -- so an image built for the P-ext board
boots perfectly well here, and an image built for THIS board boots perfectly well on the
P-ext bitstream and then reads 0x00000000 from a microphone that is not there. Neither
would say anything. Hence:

    0x5A5A0001   DRAM self-test
    0x5A5A0002   single-core Rocket + TACIT           (run_rocket.py)
    0x5A5A0003   dual-core big.LITTLE + TACIT         (run_rocket_smp.py)
    0x5A5A0004   ... + MBP packed SIMD on hart 0      (run_rocket_pext.py)
    0x5A5A0005   ... + the PDM microphone at 0x1009_0000   (this script)

The clock is unchanged at 34.4828 MHz: the microphone's worst routed path is 9.881 ns out
of context against a design whose critical path is 27.873 ns, so it does not move the
clock. See fpga/pynq-z2/docs/MICROPHONE.md.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_0005
# 1000 MHz / 29, to four places. Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)

if __name__ == "__main__":
    run_rocket.main()
