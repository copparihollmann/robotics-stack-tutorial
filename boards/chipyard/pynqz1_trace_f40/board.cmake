# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator.  The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem, then releasing the SoC from reset -- see
# fpga/pynq-z2/host/run_rocket.py.
#
# THE SILICON: 0x5A5A0039, tcl/build_rocket.tcl variant `tracepanelcam`, config
# PynqZ2RocketBigLittlePextTacitMicRgbI2cBtnCamConfig, built by Lab B138.
#
# THIS BOARD IS chipyard_pynqz1_panel_f40 PLUS THE CAMERA'S CAPTURE PERIPHERAL, on silicon
# that also DROPS THE RoCC ENGINE and KEEPS TACIT ON BOTH HARTS.  Of those three differences
# exactly one is visible in devicetree:
#
#   ospi@10080000 added   -> PLIC source 13; riscv,ndev 12 -> 13.  The I2C is still 1, the
#                            CONSOLE is still 2 and the GPIO is still 3..12.
#   TACIT present         -> four MMIO regions, no DT node, no PLIC source (tacit.h).
#   RoCC engine absent    -> NOTHING IN DEVICETREE.  A RoCC has no node; it is reached by
#                            executing custom-1.  Hart 1 has no RoCC decode table on this
#                            silicon, so every ModelBlaster dispatch raises mcause 2.
#
# SO DEVICETREE CANNOT PROTECT YOU FROM THE ONE MISTAKE THAT MATTERS HERE.  An image built
# for chipyard_pynqz1_panel_f40 boots on this silicon with a correct console -- and then
# traps the first time it dispatches to the engine.  The MAGIC at GP0 offset 0x08 is what
# refuses the wrong bitstream; nothing but the runner's EXPECT_BY_RUNNER row refuses the
# wrong IMAGE.  Add a row for this MAGIC before any board session.
#
# WHAT IS UNCHANGED, so that samples move over without a source edit: the clock (40 MHz
# exactly), both harts, the ISA strings, the console baud, the microphone at 0x1009_0000,
# the I2C at 0x1004_0000 with the OLED at 0x3c, BTN0..BTN3 on GPIO pins 6..9, and GPIO pins
# 0..5 -- the two RGB LEDs -- with their led0..led5 aliases.
