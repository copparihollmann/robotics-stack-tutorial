#!/usr/bin/env python3
"""Bring up the dual-core big.LITTLE Rocket + MBP P-ext + PDM microphone + RGB LEDs.

    sudo python3 run_rocket_micrgb.py --bitstream pynqz1_rocket_micrgb.bit --hold
    sudo python3 run_rocket_micrgb.py --no-load --elf zephyr.bin

This is run_rocket_mic.py with one value changed: the MAGIC at GP0 offset 0x08.

WHY A SEPARATE MAGIC. This design is PynqZ2RocketBigLittlePextTacitMicConfig plus a stock
sifive GPIO controller at 0x1001_0000 and six package balls. Both harts, both ISA strings,
the UART, the microphone, the clock, the address fold and the reset sequence are
identical -- so an image built for the mic board boots perfectly well here, and an image
built for the RGB board boots perfectly well on the MIC bitstream and then reads
0x00000000 out of a GPIO controller that is not there while every LED stays dark. Neither
would say anything. Hence:

    0x5A5A0001   DRAM self-test
    0x5A5A0002   single-core Rocket + TACIT               (run_rocket.py)
    0x5A5A0003   dual-core big.LITTLE + TACIT             (run_rocket_smp.py)
    0x5A5A0004   ... + MBP packed SIMD on hart 0          (run_rocket_pext.py)
    0x5A5A0005   ... + the PDM microphone at 0x1009_0000  (run_rocket_mic.py)
    0x5A5A0006   ... + the RGB LEDs at 0x1001_0000        (this script)

The two also differ in a way an image CAN see but will not check: the PLIC has seven
sources here (riscv,ndev = 7) against one there, because sifive's GPIO declares one
interrupt per pin. The UART keeps source 1 in both.

The clock is unchanged at 34.4828 MHz. The additions are a GPIO controller and an 8-bit
counter; see fpga/pynq-z2/docs/RGB_LEDS.md for what they measured.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_0006
# 1000 MHz / 29, to four places. Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)

if __name__ == "__main__":
    run_rocket.main()
