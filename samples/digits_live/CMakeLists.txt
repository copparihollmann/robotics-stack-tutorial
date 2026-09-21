# SPDX-License-Identifier: Apache-2.0
#
# Offline connected-digit transcription from the board's own microphone: record 4 s,
# then post-process.  scripts/with_board.sh ./scripts/41_rocket_digits.sh
cmake_minimum_required(VERSION 3.20.0)
if(NOT DEFINED MODEL_DIR)
  message(FATAL_ERROR "MODEL_DIR not set")
endif()
get_filename_component(MODEL_DIR "${MODEL_DIR}" ABSOLUTE)
if(NOT DEFINED KWS_FEATMAP)
  message(FATAL_ERROR "KWS_FEATMAP not set")
endif()
get_filename_component(KWS_FEATMAP_DIR "${KWS_FEATMAP}" DIRECTORY)
set(SW ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(digits_live)
target_sources(app PRIVATE src/main.c ${SW}/audio_fe.c ${SW}/audio_fe_tables_kws.c
    ${MODEL_DIR}/model.c ${MODEL_DIR}/kernels.c ${MODEL_DIR}/weights.c
    ${MODEL_DIR}/buffers.c ${MODEL_DIR}/test_io.S)
target_include_directories(app PRIVATE ${SW} ${MODEL_DIR} ${KWS_FEATMAP_DIR})
target_compile_definitions(app PRIVATE FE_ARITH_PEXT=1 MB_PEXT_HW=1
    FE_NFFT=512 FE_FRAME_LEN=480 FE_HOP_LEN=320)
if(DEFINED MODELBLASTER_KERNEL_CFLAGS)
  separate_arguments(_mbcf NATIVE_COMMAND "${MODELBLASTER_KERNEL_CFLAGS}")
  target_compile_options(app PRIVATE ${_mbcf})
endif()
if(DEFINED DG_UTTERANCES)
  target_compile_definitions(app PRIVATE DG_UTTERANCES=${DG_UTTERANCES})
endif()
