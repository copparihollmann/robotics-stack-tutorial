# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator. The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem, then releasing the SoC from reset -- see
# fpga/pynq-z2/host/run_rocket.py.
#
# This board is chipyard_pynqz1_micrgb for 0x5A5A001E (PynqZ2RocketBigLittlePextTacitMicRgbRoccMoonCamConfig):
# the same harts, clock, microphone and RGB LEDs, plus a sifive TLI2C at 0x1004_0000 and the
# HM01B0 capture peripheral at 0x1008_0000. fpga/pynq-z2/docs/CAMERA_Z1.md.
#
# IT IS NOT INTERCHANGEABLE WITH chipyard_pynqz1_micrgb IN EITHER DIRECTION. Adding the TLI2C
# renumbered the PLIC: the I2C took source 1, so the UART moved from 1 to 2 and the GPIO from
# 2..7 to 3..8. A micrgb image on this bitstream enables the UART on the wrong source, and an
# image built here on 0x5A5A0006 or 0x5A5A0010 does the same the other way. The MAGIC at GP0
# offset 0x08 is what stops that: 0x5A5A001E here.
