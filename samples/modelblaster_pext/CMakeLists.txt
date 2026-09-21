# SPDX-License-Identifier: Apache-2.0
#
# The MBP-accelerated ModelBlaster network, pinned to hart 0, plus the negative test
# that proves hart 1 refuses the same instruction.
#
#   west build -b chipyard_pynqz1_smp samples/modelblaster_pext \
#       -- -DBOARD_ROOT=$IISWC_ROOT -DMODEL_DIR=<out>/model/gen
#
# Deliberately a SEPARATE app from samples/modelblaster_hart_latency rather than a flag
# on it: this image is built with CONFIG_MB_PEXT=y, which that one must never be -- it is
# the scalar baseline every number here is measured against, and an image carrying
# custom-0 encodings would not run on its LITTLE hart at all.
#
# THE ONE THING THIS ADDS TO THE BUILD.  fpga/pynq-z2/sw is on the include path so
# kernels.c can `#include "pext.h"`.  That path lives in THIS repo, not in the
# ModelBlaster submodule, and the `pext` Backend deliberately does not hardcode it --
# the app that builds for the target supplies it.  MODELBLASTER_KERNEL_CFLAGS carries
# the backend's own flag (-DMB_PEXT_HW=1) when the driver script passes it; with
# CONFIG_MB_PEXT=y the header reaches the same conclusion on its own, so the two agree
# and either alone is sufficient.

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
# samples/modelblaster_pext/.
get_filename_component(PEXT_INCLUDE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw" ABSOLUTE)
if(NOT EXISTS "${PEXT_INCLUDE_DIR}/pext.h")
    message(FATAL_ERROR
        "pext.h not found at ${PEXT_INCLUDE_DIR} -- this sample must be built from "
        "inside the iiswc-tutorial tree.")
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(modelblaster_pext)

foreach(_required model.c model.h kernels.c kernels.h weights.c weights.h
                  buffers.c test_io.h test_io.S test_input.bin test_golden.bin)
    if(NOT EXISTS "${MODEL_DIR}/${_required}")
        message(FATAL_ERROR
            "MODEL_DIR='${MODEL_DIR}' is missing ${_required}. Run the modelblaster "
            "codegen stages first (scripts/28_rocket_modelblaster_pext.sh --build-only).")
    endif()
endforeach()

message(STATUS "modelblaster_pext MODEL_DIR=${MODEL_DIR}")
message(STATUS "modelblaster_pext PEXT_INCLUDE_DIR=${PEXT_INCLUDE_DIR}")

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
    message(STATUS "modelblaster_pext kernels.c cflags: ${_mb_kernel_cflags}")
endif()

# AND THE HARNESS ITSELF, separately, because the block above is deliberately scoped to
# kernels.c: a backend flag must not silently re-preprocess the whole application.  The one
# thing the harness needs to know about a kernel is which counters exist to print, and it gets
# told only when a caller asks.  Undefined -- which is every build that does not pass it -- this
# is a no-op and the image is byte for byte what it was.
if(DEFINED MB_HARNESS_CFLAGS)
    separate_arguments(_mb_harness_cflags NATIVE_COMMAND "${MB_HARNESS_CFLAGS}")
    target_compile_options(app PRIVATE ${_mb_harness_cflags})
    message(STATUS "modelblaster_pext harness cflags: ${_mb_harness_cflags}")
endif()

# Same reason as the scalar sample: the packed int8 weight arrays push .sdata past the
# +/-2 KB window the linker tries to fold into gp-relative loads, and the link fails with
# "relocation truncated to fit". medany still reaches +/-2 GB; only the gp shortcut goes.
zephyr_link_libraries(-Wl,--no-relax)

# ------------------------------------------------------------------------------------
# MB_DEC_AR: the autoregressive decoder image (Lab B57, scripts/74).
#
# The board chooses its own tokens instead of replaying a baked trajectory.  That needs
# two things this sample does not otherwise carry: the utterances to decode and the
# embedding table the driver looks a chosen token up in.  Both arrive as ONE generated
# assembly file full of .incbin, because the embedding is 32,768 x 288 float32 = 37.7 MB
# and C literals for it would be ~150 MB of source.
#
# MB_AR_IO is the path to that .S (scripts/74 writes it next to the generated model).
# Undefined -- which is every build that does not ask -- and this whole block is a no-op
# and the image is byte for byte what it was.
# ------------------------------------------------------------------------------------
if(DEFINED MB_DEC_AR)
    if(NOT DEFINED MB_AR_IO)
        message(FATAL_ERROR "MB_DEC_AR=1 needs -DMB_AR_IO=<abs path to ar_io.S>")
    endif()
    if(NOT EXISTS "${MB_AR_IO}")
        message(FATAL_ERROR "MB_AR_IO='${MB_AR_IO}' does not exist")
    endif()
    if(NOT EXISTS "${MODEL_DIR}/driver_meta.h")
        message(FATAL_ERROR
            "MB_DEC_AR=1 needs ${MODEL_DIR}/driver_meta.h -- emit it from the IR that is "
            "actually being built (fpga/pynq-z2/modelblaster/moonshine/emit_driver_meta.py). "
            "A stale STEP_END is wrong tokens with nothing raising.")
    endif()
    target_sources(app PRIVATE ${MB_AR_IO})
    set_source_files_properties(${MB_AR_IO} PROPERTIES LANGUAGE ASM)
    target_compile_definitions(app PRIVATE MB_DEC_AR=${MB_DEC_AR})
    if(DEFINED MB_AR_UTTS)
        target_compile_definitions(app PRIVATE MB_AR_UTTS=${MB_AR_UTTS})
    endif()
    # MB_AR_BATCH: B, how many independent utterances one pass of the graph decodes.
    # THIS FORWARD IS THE WHOLE POINT OF THE BLOCK.  `west build -- -DMB_AR_BATCH=2` sets a
    # CMAKE CACHE VARIABLE, not a compiler define; without a line here the guest compiles at
    # the #ifndef default of 1 and decodes a B=2 GRAPH one row at a time -- which boots, runs,
    # emits plausible tokens and is wrong.  Lab B99 lost a board round to exactly that.
    if(DEFINED MB_AR_BATCH)
        target_compile_definitions(app PRIVATE MB_AR_BATCH=${MB_AR_BATCH})
        if(DEFINED MB_AR_UTTS)
            math(EXPR _mb_ar_rem "${MB_AR_UTTS} % ${MB_AR_BATCH}")
            if(NOT _mb_ar_rem EQUAL 0)
                message(FATAL_ERROR
                    "MB_AR_UTTS=${MB_AR_UTTS} is not a whole number of batches of "
                    "${MB_AR_BATCH}: the last group would decode rows that were never baked")
            endif()
        endif()
    endif()
    if(DEFINED MB_AR_ROWS_UTT)
        target_compile_definitions(app PRIVATE MB_AR_ROWS_UTT=${MB_AR_ROWS_UTT})
    endif()
    if(DEFINED MB_AR_LIMIT)
        target_compile_definitions(app PRIVATE MB_AR_LIMIT=${MB_AR_LIMIT})
    endif()
    if(DEFINED MB_AR_SELFTEST)
        target_compile_definitions(app PRIVATE MB_AR_SELFTEST=${MB_AR_SELFTEST})
    endif()
    message(STATUS "modelblaster_pext MB_DEC_AR=${MB_DEC_AR} io=${MB_AR_IO}")
endif()

if(DEFINED MB_ITERS)
    target_compile_definitions(app PRIVATE MB_ITERS=${MB_ITERS})
endif()
if(DEFINED MB_WARMUP)
    target_compile_definitions(app PRIVATE MB_WARMUP=${MB_WARMUP})
endif()
if(DEFINED MB_JOIN_TIMEOUT_S)
    target_compile_definitions(app PRIVATE MB_JOIN_TIMEOUT_S=${MB_JOIN_TIMEOUT_S})
endif()
