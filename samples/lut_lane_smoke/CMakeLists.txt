# SPDX-License-Identifier: Apache-2.0
#
# M1/M2/M3: the first dispatch ever issued to T4's LUT lane (T4_LANES.md s8.4-8.5, s10).
#   ./scripts/71_rocket_lut_lane.sh --build-only
#   scripts/with_board.sh ./scripts/71_rocket_lut_lane.sh --prebuilt out/rocket_lut_lane_prebuilt
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(lut_lane_smoke)
set(SW ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw)
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${SW} ${SW}/roccmoon)
