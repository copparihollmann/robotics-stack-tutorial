# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator. The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem, then releasing the SoC from reset -- see
# fpga/pynq-z2/host/run_rocket.py, invoked as run_rocket_roccmoonnch8f40b98bpanel.py so
# that its EXPECT_BY_RUNNER entry refuses anything but MAGIC 0x5A5A0037.
#
# THE SILICON: 0x5A5A0037, tcl/build_rocket.tcl variant `roccmoonnch8f40b98bpanel`,
# bitstream md5 f1f076322d221eceb6f096bbe42cf45f, built by Lab B135.
#
# THIS BOARD IS chipyard_pynqz1_micrgb_f40 PLUS TWO PERIPHERAL CHANGES, and both of them
# move interrupt numbers:
#
#   a TLI2C at 0x1004_0000          -> PLIC source 1; the UART moves 1 -> 2
#   the GPIO widened from 6 to 10   -> PLIC sources 3..12; riscv,ndev 12
#
# IT IS NOT INTERCHANGEABLE WITH chipyard_pynqz1_micrgb_f40, IN EITHER DIRECTION, and this
# is the whole reason it is a board and not an overlay. An image built for micrgb_f40 and
# run here points the console's IRQ at the I2C controller; an image built for THIS board
# and run on 0x5A5A0035 points it one source past the UART, at nothing. Neither crashes.
# Both look like a dead board at the bench, which FPGA_END_TO_END.md section 4.1 warns is
# the hardest symptom to attribute. The MAGIC at GP0 offset 0x08 is what stops the wrong
# bitstream being loaded; nothing but this board file stops the wrong IMAGE.
#
# WHAT IS UNCHANGED, so that samples move over without a source edit: the clock (40 MHz
# exactly), both harts, the ISA strings, the console baud, the microphone at 0x1009_0000,
# the RoCC engine, and GPIO pins 0..5 -- the two RGB LEDs -- with their led0..led5 aliases.
# samples/mic_led_record and samples/moonshine_live build for this board unchanged.
