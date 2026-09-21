#!/usr/bin/env python3
"""Bring up the DUAL-CORE big.LITTLE Rocket on the PYNQ-Z1.

    sudo python3 run_rocket_smp.py --bitstream pynqz1_rocket_smp.bit --hold
    sudo python3 run_rocket_smp.py --no-load --elf zephyr.bin

This is run_rocket.py with one value changed: the MAGIC it expects at GP0 offset 0x08.

WHY THAT MATTERS. The single-core and dual-core bitstreams are built from the same
structural top, the same AXI4->AXI3 bridge and the same XDC -- the generated ChipTop port
lists are identical, because the second hart lives entirely inside ChipTop. So the
dual-core Zephyr image loads, boots and prints perfectly well against the single-core PL.
It just runs on one hart, reports arch_num_cpus() = 2, and hangs the moment anything waits
on the second CPU. That is precisely the "it silently ran single-core" failure this
exists to prevent, so the two designs report different MAGICs:

    0x5A5A0001   DRAM self-test
    0x5A5A0002   single-core Rocket + TACIT      (run_rocket.py)
    0x5A5A0003   dual-core big.LITTLE + TACIT    (this script)

Everything else -- the address fold, the reset/custom_boot sequence, the image load and
read-back -- is unchanged and shared, including the fact that releasing reset is not
enough: the bootrom parks hart 0 in wfi_loop until the custom boot pin pokes its MSIP.

THE SECOND HART needs no extra poke from here. Once hart 0 is released it runs the
bootrom's `_start`, whose interrupt_loop writes MSIP for every other hart before clearing
its own; each secondary hart then leaves `boot_core` and mrets to the same BootAddrReg
value. See generators/testchipip/.../bootrom/bootrom.S and docs/DUAL_CORE.md.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rocket  # noqa: E402

run_rocket.EXPECT_MAGIC = 0x5A5A_0003

if __name__ == "__main__":
    run_rocket.main()
