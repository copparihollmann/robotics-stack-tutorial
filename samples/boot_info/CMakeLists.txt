# SPDX-License-Identifier: Apache-2.0
#
# The board's network identity, on the glass, permanently.
#
#   west build -b chipyard_pynqz1_all_f40 samples/boot_info -- -DBOARD_ROOT=$IISWC_ROOT
#   sudo python3 run_rocket_<variant>.py --bitstream <bit> --fclk 40 --elf zephyr.bin --status
#
# The --status is the point: without it the loader zeroes the block's magic and this shows
# NO STATUS rather than a stale address.  See fpga/pynq-z2/sw/boot_status.h.
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(boot_info)

get_filename_component(OLED_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../oled_status/src" ABSOLUTE)
target_sources(app PRIVATE src/main.c ${OLED_SRC}/oled_status.c
    ${OLED_SRC}/font5x8.c ${OLED_SRC}/font10x16.c ${OLED_SRC}/font15x24.c)
target_include_directories(app PRIVATE src ${OLED_SRC} $ENV{IISWC_ROOT}/fpga/pynq-z2/sw)
