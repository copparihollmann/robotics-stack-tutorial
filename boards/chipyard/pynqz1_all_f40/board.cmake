# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator. The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem, then releasing the SoC from reset -- see
# fpga/pynq-z2/host/run_rocket.py, invoked as run_rocket_roccmoonnch8f40b98ball.py so that
# its EXPECT_BY_RUNNER entry refuses anything but MAGIC 0x5A5A0038.
#
# THE SILICON: 0x5A5A0038, tcl/build_rocket.tcl variant `roccmoonnch8f40b98ball`,
# bitstream md5 ced0aab0c7b52f25338eeffe8f678e4f, built by Lab B137.
#
# THIS BOARD IS chipyard_pynqz1_panel_f40 PLUS THE CAMERA AND MINUS TACIT:
#
#   ospi@10080000 added   -> PLIC source 13; riscv,ndev 12 -> 13.  Nothing before it moves:
#                            i2c is still 1, THE CONSOLE IS STILL 2, gpio still 3..12.
#   TACIT removed         -> no trace-encoder-controller@3000000/@3001000 and no
#                            trace-sink-dma@3010000/@3011000.  samples/tacit_boot and
#                            samples/membench need a TACIT board; 0x5A5A0035, 0x5A5A0036 and
#                            0x5A5A0037 all still have one and are unchanged.
#
# UNLIKE chipyard_pynqz1_panel_f40, THIS BOARD IS NOT A CONSOLE HAZARD IN EITHER DIRECTION.
# A panel_f40 image boots here with a working console and simply cannot see the camera; an
# image built here boots on 0x5A5A0037 with a working console and its camera writes reach an
# unmapped address. Both are recoverable at the bench. Say so rather than copying panel_f40's
# stronger warning, which was true for that board and is not true for this one.
#
# WHAT IS UNCHANGED, so that samples move over without a source edit: the clock (40 MHz
# exactly), both harts, the ISA strings, the console baud, the microphone at 0x1009_0000,
# the RoCC engine, GPIO pins 0..5 (the two RGB LEDs) with their led0..led5 aliases, and
# BTN0..BTN3 on pins 6..9 with sw0..sw3. MEASURED: samples/hello_world, samples/cam_capture,
# samples/panel_buttons, samples/oled_status and samples/mic_led_record all build for this
# board unchanged, and samples/moonshine_live produces the SAME __kernel_ram_end as it does
# for chipyard_pynqz1_panel_f40 -- 0x84fbd7c8 plain, 0x84fc31f8 with ML_OLED=1 ML_BUTTON=1.
#
# WHAT IS NOT PROVEN: nothing here has been on silicon. See the B137 entry in TODO.md.
