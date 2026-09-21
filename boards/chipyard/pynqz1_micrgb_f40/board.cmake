# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator. The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem, then releasing the SoC from reset -- see
# fpga/pynq-z2/host/run_rocket.py.
#
# This board is chipyard_pynqz1_mic plus one peripheral: a stock sifive GPIO controller at
# 0x1001_0000 whose six pins are the board's two RGB LEDs, LD4 and LD5. Everything else --
# both harts, the ISA strings, the UART, the clock, the microphone -- is identical.
#
# IT IS NOT INTERCHANGEABLE WITH chipyard_pynqz1_mic, in one direction. An image built for
# pynqz1_mic runs here unchanged (it simply never touches 0x1001_0000). An image built for
# THIS board on the mic bitstream would find no GPIO controller and a PLIC with one source
# instead of seven. The MAGIC at GP0 offset 0x08 is what stops that: 0x5A5A0006 here
# against 0x5A5A0005 there. See fpga/pynq-z2/docs/RGB_LEDS.md.

# THIS BOARD IS chipyard_pynqz1_micrgb AT 40 MHz, AND THAT IS ITS WHOLE DIFFERENCE.
# One Kconfig value moves -- CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC, 34483 -> 40000 -- because
# 0x5A5A0030 is 0x5A5A002E's SoC timed and run at FCLK0 = 40.0000 MHz
# (fpga/pynq-z2/tcl/build_rocket.tcl, variant roccmoonf40; archive/runs/b79_fclk0_ceiling/).
#
# IT IS A SEPARATE BOARD RATHER THAN AN EDIT because the mismatch is SILENT in the dangerous
# direction.  That symbol also sets the SiFive UART's baud divisor
# (SIFIVE_PERIPHERAL_CLOCK_FREQUENCY = SYS_CLOCK_HW_CYCLES_PER_SEC * RTC_CLOCK_DIVIDER_VALUE),
# so a 34483 guest on a 40 MHz PL asks for a divisor of 298 and gets 133,779 baud against the
# host's 115,200 -- +16.1 %, a GARBLED console, which FPGA_END_TO_END.md section 4.1 warns
# does not look like a clock problem -- and `mtime` runs 16 % fast while `mcycle` stays right.
# Every other board file here is chipyard_pynqz1_micrgb's, unchanged.
