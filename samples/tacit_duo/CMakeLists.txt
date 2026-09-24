# SPDX-License-Identifier: Apache-2.0
#
# TACIT DUO (Lab B151): samples/signdet_live on hart 0 and samples/kws_live on hart 1, in
# ONE image, both traced onto one timeline, so the L2 contention between two real sensor
# workloads can be measured against each running alone.
#
#   west build -p always -b chipyard_pynqz1_trace_f40 samples/tacit_duo -d <dir> -- \
#       -DBOARD_ROOT=$IISWC_ROOT \
#       -DSIGN_MODEL_DIR=out/signdet/gen -DKWS_MODEL_DIR=out/rocket_kws/cnn_tiny/pext/gen \
#       -DKWS_FEATMAP=<kws_featmap.h> -DSD_FRAMES_DIR=<bake_live_frames.py --out> \
#       -DSD_DEFS="..." -DDUO_DEFS="..."
#
# NEITHER WORKLOAD IS COPIED.  Both main.c files are compiled straight out of their own
# sample directories with SD_NO_MAIN / KWS_NO_MAIN -- a default-off hook that suppresses
# only their main() -- so samples/signdet_live and samples/kws_live still build byte for
# byte for scripts/38, scripts/83 and scripts/87, and there is no second copy of 35 KB of
# camera code to drift out of step.  samples/cam_snap was forked from sign_live the other
# way, by copying; this one does not have to, because the two bodies are already thread
# entry points.
#
# HOW TWO MODELBLASTER MODELS LIVE IN ONE IMAGE.  Every symbol the codegen emits is
# mangled with the model name -- run_model_signdet_b144 / run_model_kws_cnn_tiny,
# kernel_conv2d_s8_pc_signdet_b144 / kernel_conv2d_s8_kws_cnn_tiny,
# buf_signdet_b144_conv1 / buf_kws_cnn_tiny_c1_0 -- and the friendly unmangled names
# (run_model, MODEL_INPUT_SIZE, model_test_golden) are PREPROCESSOR MACROS in each tree's
# own model.h.  So the two trees collide only if a translation unit can see both headers.
# They cannot: the model directories are attached per source file with
# set_source_files_properties(INCLUDE_DIRECTORIES), never at target level.  That is the
# whole trick, and it is why neither generated tree needed a line changed.
#
# THE TWO SIDES ARE COMPILED AGAINST DIFFERENT ARITHMETIC, ALSO PER FILE.  Hart 0's
# kernels get MB_PEXT_HW=1 (real custom-0); hart 1's get MB_PEXT_HW=0 (pext.h's software
# model), because RocketALU_1.sv has no MBP datapath and a custom-0 word is illegal there.
# One image, two instruction sets, and the header that decides is frozen and untouched.
cmake_minimum_required(VERSION 3.20.0)

foreach(_v SIGN_MODEL_DIR KWS_MODEL_DIR KWS_FEATMAP)
    if(NOT DEFINED ${_v})
        message(FATAL_ERROR "${_v} not set -- see the header of this file.")
    endif()
endforeach()
get_filename_component(SIGN_MODEL_DIR "${SIGN_MODEL_DIR}" ABSOLUTE)
get_filename_component(KWS_MODEL_DIR  "${KWS_MODEL_DIR}"  ABSOLUTE)
get_filename_component(KWS_FEATMAP_DIR "${KWS_FEATMAP}" DIRECTORY)

get_filename_component(SIGN_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../signdet_live/src"     ABSOLUTE)
get_filename_component(KWS_SRC  "${CMAKE_CURRENT_SOURCE_DIR}/../kws_live/src"         ABSOLUTE)
get_filename_component(SW       "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw"   ABSOLUTE)
get_filename_component(CAM_SW   "${SW}/cam"                                           ABSOLUTE)
get_filename_component(OLED_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../oled_status/src"      ABSOLUTE)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(tacit_duo)

foreach(_required model.c model.h kernels.c kernels.h weights.c weights.h buffers.c)
    foreach(_d "${SIGN_MODEL_DIR}" "${KWS_MODEL_DIR}")
        if(NOT EXISTS "${_d}/${_required}")
            message(FATAL_ERROR "'${_d}' is missing ${_required}.")
        endif()
    endforeach()
endforeach()

# The shape gates, kept from both parents. A gen tree of the wrong shape would boot, run,
# and decode a grid (or a keyword) out of a tensor that is not this network's.
file(READ "${SIGN_MODEL_DIR}/model.h" _mh)
if(NOT _mh MATCHES "MODEL_[A-Z0-9_]+_INPUT_SIZE[ \t]+12288")
    message(FATAL_ERROR "SIGN_MODEL_DIR: INPUT_SIZE is not 12288 (3 x 64 x 64 int8).")
endif()
if(NOT _mh MATCHES "MODEL_[A-Z0-9_]+_OUTPUT_SIZE[ \t]+192")
    message(FATAL_ERROR "SIGN_MODEL_DIR: OUTPUT_SIZE is not 192 (an 8x8 grid of 3 classes).")
endif()
file(READ "${KWS_MODEL_DIR}/model.h" _kh)
if(NOT _kh MATCHES "MODEL_[A-Z0-9_]+_INPUT_SIZE[ \t]+490")
    message(FATAL_ERROR "KWS_MODEL_DIR: INPUT_SIZE is not 490 (49 frames x 10 MFCC).")
endif()

set(SIGN_GEN ${SIGN_MODEL_DIR}/model.c ${SIGN_MODEL_DIR}/kernels.c
             ${SIGN_MODEL_DIR}/weights.c ${SIGN_MODEL_DIR}/buffers.c)
set(KWS_GEN  ${KWS_MODEL_DIR}/model.c ${KWS_MODEL_DIR}/kernels.c
             ${KWS_MODEL_DIR}/weights.c ${KWS_MODEL_DIR}/buffers.c
             ${KWS_MODEL_DIR}/test_io.S)

target_sources(app PRIVATE
    src/main.c
    ${SIGN_SRC}/main.c
    ${KWS_SRC}/main.c
    ${CAM_SW}/ospi_cam.c
    ${CAM_SW}/sign_pre_rgb.c
    ${OLED_SRC}/oled_status.c
    ${OLED_SRC}/font5x8.c
    ${OLED_SRC}/font10x16.c
    ${OLED_SRC}/font15x24.c
    ${SW}/audio_fe.c
    ${SW}/audio_fe_tables_kws.c
    ${SIGN_GEN}
    ${KWS_GEN})

# TARGET-LEVEL INCLUDES CARRY EVERYTHING EXCEPT THE TWO MODEL TREES. Adding either
# model directory here would put both model.h files on one search path and the second
# translation unit to include "model.h" would get the wrong network's shapes -- silently,
# because both headers define the same friendly macro names.
target_include_directories(app PRIVATE
    src ${SIGN_SRC} ${KWS_SRC} ${CAM_SW} ${SW} ${OLED_SRC} ${KWS_FEATMAP_DIR})

foreach(_f ${SIGN_SRC}/main.c ${SIGN_GEN})
    set_source_files_properties(${_f} PROPERTIES INCLUDE_DIRECTORIES "${SIGN_MODEL_DIR}")
endforeach()
foreach(_f ${KWS_SRC}/main.c ${KWS_GEN})
    set_source_files_properties(${_f} PROPERTIES INCLUDE_DIRECTORIES "${KWS_MODEL_DIR}")
endforeach()

# Suppress each parent's main(); this sample owns the threads and the pins.  SD_STOP_HOOK /
# KWS_STOP_HOOK (Lab B156) are the second default-off hook in each parent: they make the
# detector's live loop and the spotter's block loop ask src/main.c whether the shared
# wall-clock window is still open, which is what lets two workloads of very different speeds
# stop TOGETHER.  Both are defined unconditionally here so this sample builds one image
# shape; with DUO_WINDOW_MS = 0 the predicate is a constant 0 and the run is bounded by
# completed work exactly as Lab B153 left it.
set_source_files_properties(${SIGN_SRC}/main.c PROPERTIES
                            COMPILE_DEFINITIONS "SD_NO_MAIN;SD_STOP_HOOK")
set_source_files_properties(${KWS_SRC}/main.c  PROPERTIES
                            COMPILE_DEFINITIONS "KWS_NO_MAIN;KWS_STOP_HOOK")

# The kws geometry, and the ARITHMETIC SPLIT. MB_PEXT_HW is set per file, not per target:
# hart 0's model and hart 1's model are the same header's two halves.
# audio_fe_tables_kws.c is in this list because it carries a _Static_assert against the
# geometry it was generated for: leave it out and the tables silently belong to a
# different window/hop than the front end that reads them.
set_property(SOURCE ${KWS_SRC}/main.c ${SW}/audio_fe.c ${SW}/audio_fe_tables_kws.c ${KWS_GEN}
             APPEND PROPERTY COMPILE_DEFINITIONS
             FE_ARITH_PEXT=1 MB_PEXT_HW=0
             FE_NFFT=512 FE_FRAME_LEN=480 FE_HOP_LEN=320)
set_property(SOURCE ${SIGN_SRC}/main.c ${SIGN_GEN}
             APPEND PROPERTY COMPILE_DEFINITIONS MB_PEXT_HW=1)

if(DEFINED KWS_SECONDS)
    set_property(SOURCE ${KWS_SRC}/main.c APPEND PROPERTY COMPILE_DEFINITIONS
                 KWS_SECONDS=${KWS_SECONDS})
endif()
if(DEFINED KWS_INFER_EVERY)
    set_property(SOURCE ${KWS_SRC}/main.c APPEND PROPERTY COMPILE_DEFINITIONS
                 KWS_INFER_EVERY=${KWS_INFER_EVERY})
endif()

# KWS_PIN_CPU does not create the thread here -- src/main.c does -- but kws_live's body
# prints a KWS_PIN self-check against it, and a correct run must not print ok=0. Default
# it to the hart this sample actually pins the keyword spotter to.
if(NOT DEFINED KWS_PIN_CPU)
    set(KWS_PIN_CPU 1)
endif()
set_property(SOURCE ${KWS_SRC}/main.c APPEND PROPERTY COMPILE_DEFINITIONS
             KWS_PIN_CPU=${KWS_PIN_CPU})

if(DEFINED SD_FRAMES_DIR)
    get_filename_component(SD_FRAMES_DIR "${SD_FRAMES_DIR}" ABSOLUTE)
    if(NOT EXISTS "${SD_FRAMES_DIR}/signdet_frames.c")
        message(FATAL_ERROR "SD_FRAMES_DIR='${SD_FRAMES_DIR}' has no signdet_frames.c.")
    endif()
    target_sources(app PRIVATE ${SD_FRAMES_DIR}/signdet_frames.c)
    target_include_directories(app PRIVATE ${SD_FRAMES_DIR})
    set_property(SOURCE ${SIGN_SRC}/main.c APPEND PROPERTY COMPILE_DEFINITIONS SD_REPLAY=1)
endif()

if(DEFINED SD_DEFS)
    separate_arguments(_sd_defs NATIVE_COMMAND "${SD_DEFS}")
    set_property(SOURCE ${SIGN_SRC}/main.c APPEND PROPERTY COMPILE_DEFINITIONS ${_sd_defs})
endif()
# The shared window, in milliseconds of wall clock measured from the RESET VECTOR.  0 (the
# default in src/main.c) is Lab B153's work-bounded run.  Also reachable through DUO_DEFS;
# named here because it is the knob a reader of this lab will look for.
if(DEFINED DUO_WINDOW_MS)
    set_property(SOURCE src/main.c APPEND PROPERTY COMPILE_DEFINITIONS
                 DUO_WINDOW_MS=${DUO_WINDOW_MS})
endif()
if(DEFINED DUO_DEFS)
    separate_arguments(_duo_defs NATIVE_COMMAND "${DUO_DEFS}")
    set_property(SOURCE src/main.c APPEND PROPERTY COMPILE_DEFINITIONS ${_duo_defs})
endif()

# Hart 0's kernels get the lab's flag list so a millisecond measured here is comparable
# with Lab B145's 237.78 and Lab B146's. Hart 1's kernels are NOT given them: they are a
# different model on a different core and MB_PEXT_HW=0 above is what defines them.
if(DEFINED MODELBLASTER_KERNEL_CFLAGS)
    separate_arguments(_kcf NATIVE_COMMAND "${MODELBLASTER_KERNEL_CFLAGS}")
    set_source_files_properties(${SIGN_MODEL_DIR}/kernels.c PROPERTIES
        COMPILE_OPTIONS "${_kcf}")
endif()

# The packed int8 weight arrays push .sdata past the +/-2 KB gp-relative window; with two
# models in one image there is twice as much of them.
zephyr_link_libraries(-Wl,--no-relax)
