#!/usr/bin/env python3
"""Bring up the DUAL-CORE big.LITTLE Rocket WITH the MBP packed-SIMD extension on hart 0.

    sudo python3 run_rocket_pext.py --bitstream pynqz1_rocket_pext.bit --hold
    sudo python3 run_rocket_pext.py --no-load --elf zephyr.bin

This is run_rocket.py with TWO values changed: the MAGIC it expects at GP0 offset 0x08,
and the FCLK0 it programs.

WHY THE MAGIC. All three Rocket bitstreams are built from the same structural top, the
same AXI4->AXI3 bridge and the same XDC -- the generated ChipTop port lists are identical,
because both the second hart and the MBP datapath live entirely inside ChipTop. So an
image built for this design loads, boots and prints perfectly well against either of the
others, and then takes an illegal-instruction trap the first time it executes an MBP op on
a core that was supposed to have one. That is the "it silently ran on the wrong bitstream"
failure, so the designs report different MAGICs:

    0x5A5A0001   DRAM self-test
    0x5A5A0002   single-core Rocket + TACIT           (run_rocket.py)
    0x5A5A0003   dual-core big.LITTLE + TACIT         (run_rocket_smp.py)
    0x5A5A0004   ... + MBP packed SIMD on hart 0      (this script)

WHY THE CLOCK, AND WHY IT IS NOT 35. This design is timed at 34.4828 MHz, not the 40 MHz
the other two use: PEXT_FEASIBILITY.md section 2.6 measures the P-ext EX stage at +9.38 ns
against an ALU-cone budget of 7.49 ns at 40 MHz. The intended target was 35 MHz and the
part cannot make it. FCLK0 = IO PLL / (DIVISOR0 * DIVISOR1) with integer divisors and the
IO PLL at 50 MHz * 20 = 1000 MHz, so the achievable neighbours of 35 are 1000/29 =
34.4828 and 1000/28 = 35.7143. Vivado's PS7 picks 29 for a request of 35 and so does
PYNQ's Clocks.fclk0_mhz setter -- but ASKING FOR 34.4828 EXPLICITLY is what makes that a
fact rather than a coincidence of two rounding rules.

GETTING THIS WRONG IS NOT SILENT AND NOT SAFE. --fclk 40 here would overclock a design
that closed with a thin margin at 29.000 ns, and the failure would be intermittent wrong
answers rather than a hang. --fclk 35 would ask for a frequency the PLL cannot make, and
PYNQ would warn and give 34.4828 anyway.

Everything else -- the address fold, the reset/custom_boot sequence, the image load and
read-back, and the fact that releasing reset is not enough -- is unchanged and shared.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_0004
# 1000 MHz / 29, to four places. Written as the division so the provenance is in the file.
run_rocket.DEFAULT_FCLK = round(1000.0 / 29.0, 4)

if __name__ == "__main__":
    run_rocket.main()
