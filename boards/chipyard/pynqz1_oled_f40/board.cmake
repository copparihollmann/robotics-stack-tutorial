# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator.  The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem -- fpga/pynq-z2/host/run_rocket.py, invoked as
# run_rocket_roccmoonnch8f40b98boled.py so its EXPECT_BY_RUNNER entry refuses anything but
# MAGIC 0x5A5A0036.
#
# THE SILICON: 0x5A5A0036, tcl/build_rocket.tcl variant `roccmoonnch8f40b98boled`, bitstream
# md5 6c4a33661dd811bd1716051eb7435ad7, built by Lab B135 as its step-1 fit probe.
#
# THIS BOARD IS chipyard_pynqz1_panel_f40 MINUS THE FOUR BUTTONS, which on the software side
# means a six-pin GPIO controller (PLIC sources 3..8, ngpios 6) instead of a ten-pin one
# (3..12, ngpios 10).  The TLI2C at 0x1004_0000 and the UART's move to PLIC source 2 are the
# same on both, and are why neither is interchangeable with chipyard_pynqz1_micrgb_f40.
#
# WHICH ONE TO BUILD FOR: the panel, unless the bitstream on the bench is 0x5A5A0036.
# 0x5A5A0037 is B135's deliverable and a strict superset.
