# SPDX-License-Identifier: Apache-2.0
#
# Record the PYNQ-Z1's own microphone with the RGB LEDs as the cue, so a person knows when
# to speak without watching a chat window.
#
#   scripts/with_board.sh ./scripts/57_rocket_mic_led_record.sh
#
# The capture path is samples/dmic_capture's, unchanged in substance: Zephyr's DMIC API,
# PCM parked in DRAM at 0x8C00_0000, an L2 flush before the host reads it. What is new is
# the cue protocol on LD4/LD5 and that it records seconds rather than 2 s.
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(mic_led_record)

target_sources(app PRIVATE src/main.c)
