# SPDX-License-Identifier: Apache-2.0
#
# Does a button press reach the SoC?  The only question this sample answers, and it answers
# it honestly: a stable reading is reported as a stable reading, never as a working button.
#
#   west build -b chipyard_pynqz1_panel_f40 samples/panel_buttons -- -DBOARD_ROOT=$IISWC_ROOT
#
# Needs a board with sw0..sw3 aliases, i.e. chipyard_pynqz1_panel_f40 (0x5A5A0037).  It will
# not compile for chipyard_pynqz1_oled_f40 or chipyard_pynqz1_micrgb_f40, on purpose: those
# SoCs' GPIO controllers have six pins and no button is wired to any of them, so an image
# that polled pin 6 there would read a bit that does not exist.  src/main.c's BUILD_ASSERT
# says so at compile time rather than at the bench.
#
# scripts/81_rocket_panel_board.sh runs it.  fpga/pynq-z2/docs/RGB_LEDS.md section 8 has the
# balls and the vendor's polarity statement.
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(panel_buttons)

target_sources(app PRIVATE src/main.c)
