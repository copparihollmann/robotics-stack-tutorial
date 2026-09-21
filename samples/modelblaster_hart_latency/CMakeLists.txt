# SPDX-License-Identifier: Apache-2.0
#
# Run one ModelBlaster-generated network on each hart of the dual-core big.LITTLE
# Rocket, ONE HART AT A TIME, and measure the inference latency on each.
#
# The generated C comes from modelblaster's codegen stages (extract_graph ->
# generate_skeleton -> generate_kernels) and is passed in whole:
#
#   west build -b chipyard_pynqz1_smp samples/modelblaster_hart_latency \
#       -- -DBOARD_ROOT=$IISWC_ROOT \
#          -DMODEL_DIR=<...>/examples/lenet/int8/generated/scalar
#
# This deliberately does NOT reuse modelblaster/harness/: that harness runs the
# model exactly once, on whatever hart it lands on, and its prj.conf sets
# CONFIG_FPU=y -- which is a build for a core that has an FPU. This SoC is
# WithoutFPU (riscv,isa = "rv64imaczicsr_zifencei_zihpm_xrocket"), so the app
# here is integer-only end to end and pins the work explicitly.
#
# MODELBLASTER_KERNEL_CFLAGS is accepted for parity with the modelblaster harness
# but must stay EMPTY for this board: every flag the other backends put in it
# (-march=rv64gcv, -mabi=lp64d, ...) names an extension this core does not have.

cmake_minimum_required(VERSION 3.20.0)

if(NOT DEFINED MODEL_DIR)
    message(FATAL_ERROR
        "MODEL_DIR not set. Pass -DMODEL_DIR=<abs path to a modelblaster "
        "generated/<target>/ directory>.")
endif()
get_filename_component(MODEL_DIR "${MODEL_DIR}" ABSOLUTE)
if(NOT IS_DIRECTORY "${MODEL_DIR}")
    message(FATAL_ERROR "MODEL_DIR='${MODEL_DIR}' is not a directory.")
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(modelblaster_hart_latency)

foreach(_required model.c model.h kernels.c kernels.h weights.c weights.h
                  buffers.c test_io.h test_io.S test_input.bin test_golden.bin)
    if(NOT EXISTS "${MODEL_DIR}/${_required}")
        message(FATAL_ERROR
            "MODEL_DIR='${MODEL_DIR}' is missing ${_required}. Run the "
            "modelblaster codegen stages first (STAGE_ONLY=1 ... run.sh).")
    endif()
endforeach()

message(STATUS "modelblaster_hart_latency MODEL_DIR=${MODEL_DIR}")

target_sources(app PRIVATE
    src/main.c
    ${MODEL_DIR}/model.c
    ${MODEL_DIR}/kernels.c
    ${MODEL_DIR}/weights.c
    ${MODEL_DIR}/buffers.c
    ${MODEL_DIR}/test_io.S
)
set_source_files_properties(${MODEL_DIR}/test_io.S PROPERTIES LANGUAGE ASM)

target_include_directories(app PRIVATE src ${MODEL_DIR})

# Same reason as the modelblaster harness: the packed int8 weight arrays push
# .sdata past the +/-2 KB window the linker tries to fold into gp-relative
# loads, and the link fails with "relocation truncated to fit". medany still
# reaches +/-2 GB; only the gp shortcut is lost.
zephyr_link_libraries(-Wl,--no-relax)

if(DEFINED MB_ITERS)
    target_compile_definitions(app PRIVATE MB_ITERS=${MB_ITERS})
endif()
