# SPDX-License-Identifier: Apache-2.0
#
# Two TACIT-traced harts running two different instruction sets.
#
#   west build -b chipyard_pynqz1_pext samples/tacit_pext_smp -- -DBOARD_ROOT=$IISWC_ROOT
#
# THE ONE THING THIS ADDS over samples/tacit_smp's CMakeLists: fpga/pynq-z2/sw is on the
# include path, so src/main.c can `#include "pext.h"`.  That path lives in THIS repo and
# the header is the frozen ISA contract -- it is included, never modified.
#
# No MODELBLASTER_KERNEL_CFLAGS and no -DMB_PEXT_HW here: prj.conf sets CONFIG_MB_PEXT=y
# and pext.h reaches MB_PEXT_HW=1 on its own from Zephyr's autoconf.h.  ONE image carries
# both bodies -- the `mb_pext_*` intrinsics (real custom-0 encodings, hart 0) and the
# `mb_pext_*_sw` software model (plain rv64imac, hart 1) -- because the header defines the
# `_sw` entry points unconditionally.

cmake_minimum_required(VERSION 3.20.0)

get_filename_component(PEXT_INCLUDE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw" ABSOLUTE)
if(NOT EXISTS "${PEXT_INCLUDE_DIR}/pext.h")
    message(FATAL_ERROR
        "pext.h not found at ${PEXT_INCLUDE_DIR} -- this sample must be built from "
        "inside the iiswc-tutorial tree.")
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(tacit_pext_smp)

message(STATUS "tacit_pext_smp PEXT_INCLUDE_DIR=${PEXT_INCLUDE_DIR}")

target_sources(app PRIVATE src/main.c)
target_include_directories(app PRIVATE ${PEXT_INCLUDE_DIR})

if(DEFINED MB_PEXT_ROUNDS)
    target_compile_definitions(app PRIVATE MB_PEXT_ROUNDS=${MB_PEXT_ROUNDS})
endif()
