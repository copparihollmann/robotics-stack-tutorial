# SPDX-License-Identifier: Apache-2.0
#
# What a memo table costs at a DECODER's dispatch size, on the silicon.
#   scripts/with_board.sh ./scripts/68_rocket_memo_table.sh
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(memo_table_bench)
set(SW ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw)
set(K ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/modelblaster/kernels/pext_nl)
# int_nonlin.c is NOT compiled separately: the curated kernel #includes it, so main.c gets
# both from one translation unit and there are no duplicate definitions.
target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${SW} ${K})
