# SPDX-License-Identifier: Apache-2.0
#
# The system-bus side of the memory architecture, measured on 0x5A5A001C (bwwin):
# MEMORY_BANDWIDTH.md section 9.  Run one ladder step per board session:
#   scripts/with_board.sh ./scripts/49_rocket_bwwin_lab.sh --step N --fclk1 100
# (the lab passes EXTRA_CFLAGS=-DBWWIN_STEP=N).
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(bwwin_bench)

# mb_read / mb_write come from samples/membench, unmodified and not copied: the harts' numbers here
# (through the L2 and through the DMA aperture) are the same instruction stream as Lab B6's.
target_sources(app PRIVATE src/main.c ${CMAKE_CURRENT_SOURCE_DIR}/../membench/src/kernels.S)
