# SPDX-License-Identifier: Apache-2.0
#
# The camera path end to end: a 324x324 frame in DRAM -> frame_fe.c -> the network.
#
#   west build -b chipyard_pynqz1_micrgb samples/vision_replay \
#       -- -DBOARD_ROOT=$IISWC_ROOT -DMODEL_DIR=<out>/gen -DFRAMES_DIR=<out>/frames
#
# Two generated inputs, and they must agree about the architecture: MODEL_DIR is a
# ModelBlaster pext build of vww_<arch>, FRAMES_DIR is gen_replay_frames.py's output for
# the SAME arch.  The build checks that below rather than trusting the caller, because
# feeding a mono feature to the Bayer model still runs, still prints a class, and is
# wrong -- the same shape of bug SPEECH_ON_ROCKET.md section 9 item 15 records.

cmake_minimum_required(VERSION 3.20.0)

foreach(_v MODEL_DIR FRAMES_DIR)
    if(NOT DEFINED ${_v})
        message(FATAL_ERROR "${_v} not set.")
    endif()
    get_filename_component(${_v} "${${_v}}" ABSOLUTE)
    if(NOT IS_DIRECTORY "${${_v}}")
        message(FATAL_ERROR "${_v}='${${_v}}' is not a directory.")
    endif()
endforeach()

get_filename_component(SW_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw" ABSOLUTE)
if(NOT EXISTS "${SW_DIR}/frame_fe.c")
    message(FATAL_ERROR "frame_fe.c not found at ${SW_DIR}")
endif()

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(vision_replay)

foreach(_required model.c model.h kernels.c kernels.h weights.c weights.h
                  buffers.c test_io.h test_io.S test_input.bin test_golden.bin)
    if(NOT EXISTS "${MODEL_DIR}/${_required}")
        message(FATAL_ERROR "MODEL_DIR='${MODEL_DIR}' is missing ${_required}.")
    endif()
endforeach()
foreach(_required replay_frames.c replay_frames.h replay_frames.json)
    if(NOT EXISTS "${FRAMES_DIR}/${_required}")
        message(FATAL_ERROR "FRAMES_DIR='${FRAMES_DIR}' is missing ${_required}.")
    endif()
endforeach()

# The two generated trees must name the same architecture. VR_ARCH comes from the frame
# generator; MODEL_NAME from the codegen. A mismatch is a silent wrong answer.
file(READ "${FRAMES_DIR}/replay_frames.h" _fh)
string(REGEX MATCH "#define VR_ARCH[ \t]+\"([a-z0-9_]+)\"" _m "${_fh}")
set(_frames_arch "${CMAKE_MATCH_1}")
file(READ "${MODEL_DIR}/model.h" _mh)
string(REGEX MATCH "#define MODEL_[A-Z0-9_]*NAME[ \t]+\"vww_([a-z0-9_]+)\"" _m2 "${_mh}")
set(_model_arch "${CMAKE_MATCH_1}")
if(NOT _frames_arch STREQUAL _model_arch)
    message(FATAL_ERROR
        "architecture mismatch: FRAMES_DIR is for '${_frames_arch}' and MODEL_DIR is "
        "for '${_model_arch}'. Feeding one model another's feature tensor still runs.")
endif()
message(STATUS "vision_replay arch=${_model_arch}")

target_sources(app PRIVATE
    src/main.c
    ${SW_DIR}/frame_fe.c
    ${FRAMES_DIR}/replay_frames.c
    ${MODEL_DIR}/model.c
    ${MODEL_DIR}/kernels.c
    ${MODEL_DIR}/weights.c
    ${MODEL_DIR}/buffers.c
    ${MODEL_DIR}/test_io.S
)
set_source_files_properties(${MODEL_DIR}/test_io.S PROPERTIES LANGUAGE ASM)
target_include_directories(app PRIVATE src ${MODEL_DIR} ${FRAMES_DIR} ${SW_DIR})

if(DEFINED MODELBLASTER_KERNEL_CFLAGS)
    separate_arguments(_mb_kernel_cflags NATIVE_COMMAND "${MODELBLASTER_KERNEL_CFLAGS}")
    set_source_files_properties(${MODEL_DIR}/kernels.c PROPERTIES
        COMPILE_OPTIONS "${_mb_kernel_cflags}")
endif()

# Same reason as every other ModelBlaster sample here: the packed int8 weight arrays push
# .sdata past the +/-2 KB window the linker folds into gp-relative loads, and the link
# fails with "relocation truncated to fit". medany still reaches +/-2 GB.
zephyr_link_libraries(-Wl,--no-relax)
