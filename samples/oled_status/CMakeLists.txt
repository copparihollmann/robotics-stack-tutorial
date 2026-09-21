# SPDX-License-Identifier: Apache-2.0
#
# A five-line status screen on a 0.96" SSD1306 that shares the HM01B0 camera's I2C bus.
#
#   west build -b <board> samples/oled_status -- -DBOARD_ROOT=$IISWC_ROOT \
#       -DEXTRA_DTC_OVERLAY_FILE=$IISWC_ROOT/samples/oled_status/oled.overlay
#
# Stock Zephyr all the way down: i2c_sifive (the TLI2C), ssd1306 and CFB. The only code of
# ours is src/oled_status.c (probe, thread, rendering, bar graph) and a 5x8 font.
# fpga/pynq-z2/docs/OLED_SSD1306.md is the design note; scripts/54, 55 and 56 test it on
# the host, in RTL simulation and on the board.
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(oled_status)

target_sources(app PRIVATE src/main.c src/oled_status.c src/font5x8.c)
