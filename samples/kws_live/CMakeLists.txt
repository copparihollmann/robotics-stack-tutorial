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
#
# KWS_MB_PEXT_HW AND KWS_PIN_CPU -- ADDITIVE, AND THEIR DEFAULTS ARE THE OLD BEHAVIOUR.
#
# This sample was born pinned to hart 0 with the real custom-0 encodings, because those
# are the only place the MBP datapath exists: RocketALU_1.sv carries none of fn codes
# 5'h14..5'h17 and a custom-0 word on tile 1 is an illegal instruction.  Lab B151 wants
# the SAME network on the LITTLE hart, which means pext.h's software model -- the one
# PEXT_SPEC.md 3.5 makes the normative definition -- and a pin to CPU 1.
#
# Both are build-time only and both default to what scripts/38 has always produced, so
# every existing invocation of this sample compiles byte for byte as before:
#
#   KWS_MB_PEXT_HW=1  real encodings   (default)   KWS_MB_PEXT_HW=0  software model
#   KWS_PIN_CPU=0     hart 0           (default)   KWS_PIN_CPU=1     hart 1
#
# The two are not independent in a way the source can check, so the build does:
# MB_PEXT_HW=1 on a hart that is not MB_PEXT_BIG_HART would trap on the first DOT8, and
# it is far better to refuse that image here than to watch it halt on the bench.
if(NOT DEFINED KWS_MB_PEXT_HW)
  set(KWS_MB_PEXT_HW 1)
endif()
if(NOT DEFINED KWS_PIN_CPU)
  set(KWS_PIN_CPU 0)
endif()
if(KWS_MB_PEXT_HW AND NOT KWS_PIN_CPU EQUAL 0)
  message(FATAL_ERROR
    "KWS_MB_PEXT_HW=1 with KWS_PIN_CPU=${KWS_PIN_CPU}: the MBP encodings only exist on "
    "hart 0. Build with -DKWS_MB_PEXT_HW=0 to run this network on the little hart.")
endif()

target_compile_definitions(app PRIVATE
    FE_ARITH_PEXT=1 MB_PEXT_HW=${KWS_MB_PEXT_HW}
    KWS_PIN_CPU=${KWS_PIN_CPU}
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
