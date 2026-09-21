# SPDX-License-Identifier: Apache-2.0
#
# MOONSHINE, LIVE: record from the board's own microphone and transcribe, on the board,
# with nothing on the host.
#
#   west build -b chipyard_pynqz1_micrgb_f40 samples/moonshine_live \
#       -- -DBOARD_ROOT=$IISWC_ROOT -DMODEL_DIR=<a B=1 gen> -DLIVE_GEN=<emit_* output dir>
#
# WHY A SEPARATE APP AND NOT A FLAG ON samples/modelblaster_pext.  That sample is the
# measurement harness: eleven labs' numbers come out of it and its main.c is 1,285 lines of
# accounting that a demo does not want and must not perturb.  This app links the SAME
# generated model, the SAME kernels and the SAME embedding table -- so the arithmetic is
# identical -- and replaces only where the audio comes from and what happens to the tokens.
#
# THE MODEL_DIR MUST BE A B = 1 GEN.  At B > 1 the graph decodes a GROUP and model_output is
# N_STEPS x B x VOCAB; a live image has one utterance and no group to fill.  out/b126_rtf_n8/gen
# is the B = 1 gen whose kernel_picks_digest and kernel_cflags_md5 match the B = 4 gen the
# measured results use, so the kernels are the same ones.  The check below is on the SIZE,
# which is the thing that would silently mis-decode.

cmake_minimum_required(VERSION 3.20.0)

if(NOT DEFINED MODEL_DIR)
    message(FATAL_ERROR "MODEL_DIR not set (needs a B = 1 modelblaster gen).")
endif()
if(NOT DEFINED LIVE_GEN)
    message(FATAL_ERROR
        "LIVE_GEN not set. Run emit_vocab.py --out <dir> and emit_live_io.py --out <dir>.")
endif()
get_filename_component(MODEL_DIR "${MODEL_DIR}" ABSOLUTE)
get_filename_component(LIVE_GEN  "${LIVE_GEN}"  ABSOLUTE)

get_filename_component(PEXT_INCLUDE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw" ABSOLUTE)
# b119_resamp.h and b122_capture.h are NOT copied: there is one of each and they are the ones
# the host verifier (b119_resamp.py --verify-c) compiles.  Same rule samples/mic_speech follows.
get_filename_component(MIC_WINDOW_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../mic_window/src" ABSOLUTE)
get_filename_component(MIC_SPEECH_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../mic_speech/src" ABSOLUTE)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(moonshine_live)

foreach(_required model.c model.h kernels.c kernels.h weights.c weights.h buffers.c
                  driver_meta.h)
    if(NOT EXISTS "${MODEL_DIR}/${_required}")
        message(FATAL_ERROR "MODEL_DIR='${MODEL_DIR}' is missing ${_required}.")
    endif()
endforeach()
foreach(_required mb_vocab.c mb_vocab.h ar_io_live.S mb_ar_tail.c)
    if(NOT EXISTS "${LIVE_GEN}/${_required}")
        message(FATAL_ERROR "LIVE_GEN='${LIVE_GEN}' is missing ${_required}.")
    endif()
endforeach()

# THE B = 1 GATE.  A B = 4 gen has MODEL_OUTPUT_SIZE 3,145,728 and would decode this image's
# single utterance out of a group layout that is not there -- booting, running, and emitting
# plausible tokens that are wrong.  Lab B99 lost a board round to exactly that class of
# mismatch, so it is refused at configure time rather than debugged on a console.
file(READ "${MODEL_DIR}/model.h" _mh)
if(NOT _mh MATCHES "MODEL_MOONSHINE_E2E_OUTPUT_SIZE[ \t]+786432")
    message(FATAL_ERROR
        "MODEL_DIR='${MODEL_DIR}' is not a B = 1 gen: MODEL_OUTPUT_SIZE must be 786432 "
        "(= N_STEPS 24 x VOCAB 32768). A B = 4 gen reads 3145728.")
endif()

target_sources(app PRIVATE
    src/main.c
    ${MODEL_DIR}/model.c
    ${MODEL_DIR}/kernels.c
    ${MODEL_DIR}/weights.c
    ${MODEL_DIR}/buffers.c
    ${LIVE_GEN}/mb_vocab.c
    ${LIVE_GEN}/mb_ar_tail.c
    ${LIVE_GEN}/ar_io_live.S
)
set_source_files_properties(${LIVE_GEN}/ar_io_live.S PROPERTIES LANGUAGE ASM)

# The 5x8 font is samples/oled_status's and is NOT copied: one file, one glyph set.  Added
# only for an OLED build, since without CONFIG_CHARACTER_FRAMEBUFFER it has nothing to feed.
if(ML_DEFS MATCHES "ML_OLED=1")
    get_filename_component(OLED_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../oled_status/src" ABSOLUTE)
    if(NOT EXISTS "${OLED_SRC}/font5x8.c")
        message(FATAL_ERROR "ML_OLED=1 needs ${OLED_SRC}/font5x8.c")
    endif()
    target_sources(app PRIVATE ${OLED_SRC}/font5x8.c)
    message(STATUS "moonshine_live: OLED enabled, font from ${OLED_SRC}")
endif()

if(EXISTS "${LIVE_GEN}/mb_selftest.c")
    target_sources(app PRIVATE ${LIVE_GEN}/mb_selftest.c)
    target_compile_definitions(app PRIVATE ML_SELFTEST=1)
    message(STATUS "moonshine_live: boot self-test record present")
endif()

target_include_directories(app PRIVATE
    src ${MODEL_DIR} ${LIVE_GEN} ${PEXT_INCLUDE_DIR} ${MIC_WINDOW_SRC} ${MIC_SPEECH_SRC})

if(DEFINED MODELBLASTER_KERNEL_CFLAGS)
    separate_arguments(_mb_kernel_cflags NATIVE_COMMAND "${MODELBLASTER_KERNEL_CFLAGS}")
    set_source_files_properties(${MODEL_DIR}/kernels.c PROPERTIES
        COMPILE_OPTIONS "${_mb_kernel_cflags}")
    message(STATUS "moonshine_live kernels.c cflags: ${_mb_kernel_cflags}")
endif()

if(DEFINED ML_DEFS)
    separate_arguments(_ml_defs NATIVE_COMMAND "${ML_DEFS}")
    foreach(_d ${_ml_defs})
        target_compile_definitions(app PRIVATE ${_d})
    endforeach()
endif()

# Same reason as the other model samples: the packed int8 weight arrays push .sdata past the
# +/-2 KB gp-relative window and the link fails with "relocation truncated to fit".
zephyr_link_libraries(-Wl,--no-relax)
