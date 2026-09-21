# SPDX-License-Identifier: Apache-2.0
#
# The MBP acceptance test, on hardware.
#
#   scripts/with_board.sh ./scripts/29_rocket_pext_run.sh
#
# MB_PEXT_HW=1 is passed on the command line rather than taken from a Kconfig symbol,
# because this sample has exactly one mode: it MUST emit the real custom-0 encodings. A
# build that silently fell back to the software model would pass every positive check in
# main.c while proving nothing about the silicon, and the negative test on hart 1 would
# pass by never trapping. main.c #errors if it is not set.
#
# The contract header lives with the RTL and the spec, not in this sample: it is shared
# with the Rocket integration, samples/pext_rtl_selftest and the ModelBlaster kernels, and
# there must be exactly one copy of it.

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(pext_hart_proof)

target_sources(app PRIVATE src/main.c src/trap.S)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw)
target_compile_definitions(app PRIVATE MB_PEXT_HW=1)
