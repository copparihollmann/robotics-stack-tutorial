# SPDX-License-Identifier: Apache-2.0
#
# The MBP-accelerated ModelBlaster network with a TACIT encoder bracketed around ONE
# inference, so the thing that gets decoded is the curated kernels themselves rather
# than a synthetic loop.
#
#   west build -b chipyard_pynqz1_pext samples/tacit_mb_lenet_pext \
#       -- -DBOARD_ROOT=$IISWC_ROOT -DMODEL_DIR=<out>/model/gen        # the board
#   west build -b spike_riscv64       samples/tacit_mb_lenet_pext \
#       -- -DBOARD_ROOT=$IISWC_ROOT -DMODEL_DIR=<out>/model/gen        # the ground truth
#
# TWO BOARDS, ONE SOURCE, AND THAT IS THE POINT.  The board build streams the encoded
# trace into DRAM through TraceSinkDMA; the spike build points the same encoder at
# target 0, which is spike's file sink, and spike ALSO writes tacit.debug -- its own
# per-instruction ground truth for exactly the window the encoder was enabled over.
# Decoding the spike capture and diffing the PC sequence against tacit.debug is what
# makes "the decoder is right about this kernel" a measurement instead of a reading.
# The board/spike difference is one Kconfig symbol (TACIT_MB_SINK_DMA) and the
# boards/spike_riscv64.conf fragment; the C is identical.
#
# Deliberately a SEPARATE app from samples/modelblaster_pext rather than a flag on it:
# that one is Lab B10's bit-exactness and cycle measurement and must keep measuring an
# untraced inference.  Tracing costs nothing in the core (the encoder is a tap) but the
# app around it differs -- one traced inference instead of eleven timed ones, an encoder
# bracket, a sink, and an L2 flush.
#
# THE ONE THING THIS ADDS TO THE BUILD, same as samples/modelblaster_pext:
# fpga/pynq-z2/sw is on the include path so the generated kernels.c can
# `#include "pext.h"`.  That path lives in THIS repo, not in the ModelBlaster
# submodule.

cmake_minimum_required(VERSION 3.20.0)

if(NOT DEFINED MODEL_DIR)
    message(FATAL_ERROR
        "MODEL_DIR not set. Pass -DMODEL_DIR=<abs path to a modelblaster "
        "generated/<target>/ directory built for the pext target>.")
endif()
get_filename_component(MODEL_DIR "${MODEL_DIR}" ABSOLUTE)
if(NOT IS_DIRECTORY "${MODEL_DIR}")
    message(FATAL_ERROR "MODEL_DIR='${MODEL_DIR}' is not a directory.")
endif()

# pext.h is the shared ISA contract: fpga/pynq-z2/sw/pext.h, four directories up from
# samples/tacit_mb_lenet_pext/.
get_filename_component(PEXT_INCLUDE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw" ABSOLUTE)
if(NOT EXISTS "${PEXT_INCLUDE_DIR}/pext.h")
    message(FATAL_ERROR
        "pext.h not found at ${PEXT_INCLUDE_DIR} -- this sample must be built from "
        "inside the iiswc-tutorial tree.")
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(tacit_mb_lenet_pext)

foreach(_required model.c model.h kernels.c kernels.h weights.c weights.h
                  buffers.c test_io.h test_io.S test_input.bin test_golden.bin)
    if(NOT EXISTS "${MODEL_DIR}/${_required}")
        message(FATAL_ERROR
            "MODEL_DIR='${MODEL_DIR}' is missing ${_required}. Run the modelblaster "
            "codegen stages first (scripts/32_rocket_tacit_mb_lenet_pext.sh).")
    endif()
endforeach()

message(STATUS "tacit_mb_lenet_pext MODEL_DIR=${MODEL_DIR}")
message(STATUS "tacit_mb_lenet_pext PEXT_INCLUDE_DIR=${PEXT_INCLUDE_DIR}")

target_sources(app PRIVATE
    src/main.c
    ${MODEL_DIR}/model.c
    ${MODEL_DIR}/kernels.c
    ${MODEL_DIR}/weights.c
    ${MODEL_DIR}/buffers.c
    ${MODEL_DIR}/test_io.S
)
set_source_files_properties(${MODEL_DIR}/test_io.S PROPERTIES LANGUAGE ASM)

target_include_directories(app PRIVATE src ${MODEL_DIR} ${PEXT_INCLUDE_DIR})

# Backend-supplied flags for the kernel TU only, exactly as modelblaster/harness does.
# Empty is fine: CONFIG_MB_PEXT already makes pext.h emit the real encodings.
if(DEFINED MODELBLASTER_KERNEL_CFLAGS)
    separate_arguments(_mb_kernel_cflags NATIVE_COMMAND "${MODELBLASTER_KERNEL_CFLAGS}")
    set_source_files_properties(${MODEL_DIR}/kernels.c PROPERTIES
        COMPILE_OPTIONS "${_mb_kernel_cflags}")
    message(STATUS "tacit_mb_lenet_pext kernels.c cflags: ${_mb_kernel_cflags}")
endif()

# Same reason as the other two modelblaster samples: the packed int8 weight arrays push
# .sdata past the +/-2 KB window the linker tries to fold into gp-relative loads, and the
# link fails with "relocation truncated to fit".
zephyr_link_libraries(-Wl,--no-relax)

if(DEFINED TACIT_BUF_ADDR)
    target_compile_definitions(app PRIVATE TACIT_BUF_ADDR=${TACIT_BUF_ADDR})
endif()
