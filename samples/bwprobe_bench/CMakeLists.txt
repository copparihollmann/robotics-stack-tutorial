# SPDX-License-Identifier: Apache-2.0
#
# The memory port measured two ways on one bitstream: the core's own streaming read and
# the TileLink bandwidth instrument at 0x100A_0000.
#   scripts/with_board.sh ./scripts/43_rocket_bwlab.sh
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(bwprobe_bench)

# mb_read comes from samples/membench, unmodified and not copied.  That is the whole
# point of the calibration half: the core-side number has to be produced by the same
# instruction stream that produced Lab B6's 1.34 B/cycle, or "the instrument beats the
# core" is a statement about two different loops.
target_sources(app PRIVATE src/main.c ${CMAKE_CURRENT_SOURCE_DIR}/../membench/src/kernels.S)

# -DBWLAB_CHANNELS=1 (scripts/43_rocket_bwlab.sh --channels) adds two DRAM reads that differ
# only in which of WithNMemoryChannels(2)'s channels they touch: DRAM_1CH (stride 128,
# address[6] always 0) and DRAM_2CH (stride 192, address[6] alternating).  Off by default:
# every other run of this lab produces exactly the rows it did.
if(BWLAB_CHANNELS)
  target_compile_definitions(app PRIVATE BWLAB_CHANNELS=1)
endif()
