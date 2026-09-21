# SPDX-License-Identifier: Apache-2.0
#
# Lab B119 -- assemble the encoder's 64,000-sample int8 input window from the microphone.
#   ./scripts/77_rocket_mic_window.sh --build-only
#   scripts/with_board.sh ./scripts/77_rocket_mic_window.sh --prebuilt out/rocket_mic_window_prebuilt
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(mic_window)
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE src)
