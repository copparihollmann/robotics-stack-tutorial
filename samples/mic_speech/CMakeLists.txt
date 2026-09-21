# SPDX-License-Identifier: Apache-2.0
#
# Lab B122 -- play a known utterance through the bench speaker and capture it on the board's
# microphone.
#   ./scripts/79_rocket_mic_speech.sh --build-only
#   scripts/with_board.sh ./scripts/79_rocket_mic_speech.sh --prebuilt out/rocket_mic_speech_prebuilt
#
# b119_resamp.h AND b119_rs_coeffs.h ARE NOT COPIED HERE.  They are included straight out of
# samples/mic_window/src, so the resampler this lab measures is byte-for-byte the one Lab B119
# designed and the one fpga/pynq-z2/modelblaster/moonshine/b119_resamp.py --verify-c compiles.
# A copy would be a second source of truth, and this lab's whole claim is that the arithmetic
# did not change.
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(mic_speech)
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE src ${CMAKE_CURRENT_SOURCE_DIR}/../mic_window/src)

# Lab B130 -- a build-time hook for the ONE control that proves the extra windows are arm A's
# own computation at another offset:
#
#   west build ... -- -DBOARD_ROOT=$ROOT -DMS_DEFS="ONSET_LEAD_B=6400 ONSET_LEAD_C=6400"
#
# built that way, MS_FNV == MS_FNV_B == MS_FNV_C and MSD == MSE == MSF byte for byte.  Passing
# nothing -- which is what scripts/79 does, unmodified -- leaves main.c's own defaults.
if(DEFINED MS_DEFS)
  separate_arguments(MS_DEFS_LIST UNIX_COMMAND "${MS_DEFS}")
  target_compile_definitions(app PRIVATE ${MS_DEFS_LIST})
  message(STATUS "mic_speech: MS_DEFS = ${MS_DEFS}")
endif()
