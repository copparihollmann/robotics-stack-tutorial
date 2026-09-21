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
