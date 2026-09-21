# SPDX-License-Identifier: Apache-2.0
#
# Build the MBP differential self-test for a Zephyr target.
#
#   west build -b spike_riscv64 samples/pext_selftest -- -DMB_PEXT_HW=1   # instructions
#   west build -b spike_riscv64 samples/pext_selftest -- -DMB_PEXT_HW=0   # software model
#
# MB_PEXT_HW is passed on the command line rather than taken from CONFIG_MB_PEXT so that
# the two builds differ in exactly one preprocessor symbol and in nothing else -- same
# board, same Kconfig, same compiler flags. That is what makes the minstret delta between
# them an instruction-count measurement rather than a comparison of two configurations.
#
# The contract header lives with the RTL and the spec, not in this sample: it is shared
# with the Rocket integration and with the ModelBlaster kernels, and there must be exactly
# one copy of it.

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(pext_selftest)

if(NOT DEFINED MB_PEXT_HW)
    set(MB_PEXT_HW 1)
endif()

# PEXT_VERBOSE=0 drops the per-case console line and keeps every case, every comparison
# and every MISMATCH. Printing dominates: on spike's HTIF console one line costs ~300k
# instructions against ~160 for the case it describes, so the verbose build is an 80 M
# instruction run and the quiet one is a 2 M instruction run. Trace the quiet one.
if(NOT DEFINED PEXT_VERBOSE)
    set(PEXT_VERBOSE 1)
endif()
message(STATUS "pext_selftest MB_PEXT_HW=${MB_PEXT_HW} PEXT_VERBOSE=${PEXT_VERBOSE}")

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw)
target_compile_definitions(app PRIVATE MB_PEXT_HW=${MB_PEXT_HW} PEXT_VERBOSE=${PEXT_VERBOSE})
