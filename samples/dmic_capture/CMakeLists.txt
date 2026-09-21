# SPDX-License-Identifier: Apache-2.0
#
# Capture audio from the PYNQ-Z1's on-board MEMS microphone through Zephyr's standard
# DMIC API, and prove on the console that it is real audio and not a stuck pin.
#
#   scripts/with_board.sh ./scripts/34_rocket_mic_capture.sh
#
# The sample is deliberately written against <zephyr/audio/dmic.h> and nothing else:
# no register offsets, no board-specific header. Everything it needs about the
# hardware -- the real sample rate included -- it learns from dmic_configure().
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(dmic_capture)

target_sources(app PRIVATE src/main.c)
