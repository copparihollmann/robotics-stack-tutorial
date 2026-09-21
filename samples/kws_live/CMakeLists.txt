# SPDX-License-Identifier: Apache-2.0
#
# Live keyword spotting: the board's own microphone -> fixed-point MFCC -> int8 CNN
# through the MBP instructions, continuously, with the duty cycle MEASURED.
#
#   scripts/with_board.sh ./scripts/38_rocket_kws_live.sh
#
# MODEL_DIR is a ModelBlaster generated/ directory built for the `pext` target; the
# runner produces it and passes it in, exactly as samples/modelblaster_pext does.
# KWS_FEATMAP is the header fpga/pynq-z2/sw/tools/gen_feat_map.py writes from the same
# meta.json the trainer emitted -- so the Q8 -> int8 map on the device is the map the
# model was trained with, rather than a constant retyped into two places.
cmake_minimum_required(VERSION 3.20.0)

if(NOT DEFINED MODEL_DIR)
  message(FATAL_ERROR "MODEL_DIR not set -- pass -DMODEL_DIR=<gen dir for target pext>")
endif()
get_filename_component(MODEL_DIR "${MODEL_DIR}" ABSOLUTE)
if(NOT DEFINED KWS_FEATMAP)
  message(FATAL_ERROR "KWS_FEATMAP not set -- pass -DKWS_FEATMAP=<kws_featmap.h>")
endif()
get_filename_component(KWS_FEATMAP_DIR "${KWS_FEATMAP}" DIRECTORY)

set(SW ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(kws_live)

target_sources(app PRIVATE
    src/main.c
    ${SW}/audio_fe.c
    ${SW}/audio_fe_tables_kws.c
    ${MODEL_DIR}/model.c
    ${MODEL_DIR}/kernels.c
    ${MODEL_DIR}/weights.c
    ${MODEL_DIR}/buffers.c
    ${MODEL_DIR}/test_io.S)
target_include_directories(app PRIVATE ${SW} ${MODEL_DIR} ${KWS_FEATMAP_DIR})

# The "kws" geometry: 30 ms window, 20 ms hop, 512-point transform, 49 frames per
# second -- MLPerf Tiny's keyword-spotting framing, and what the model was trained on.
target_compile_definitions(app PRIVATE
    FE_ARITH_PEXT=1 MB_PEXT_HW=1
    FE_NFFT=512 FE_FRAME_LEN=480 FE_HOP_LEN=320)

if(DEFINED MODELBLASTER_KERNEL_CFLAGS)
  separate_arguments(_mbcf NATIVE_COMMAND "${MODELBLASTER_KERNEL_CFLAGS}")
  target_compile_options(app PRIVATE ${_mbcf})
endif()
if(DEFINED KWS_SECONDS)
  target_compile_definitions(app PRIVATE KWS_SECONDS=${KWS_SECONDS})
endif()
if(DEFINED KWS_INFER_EVERY)
  target_compile_definitions(app PRIVATE KWS_INFER_EVERY=${KWS_INFER_EVERY})
endif()
message(STATUS "kws_live MODEL_DIR=${MODEL_DIR}")
