# SPDX-License-Identifier: Apache-2.0
#
# SIGNDET LIVE (Lab B146): camera -> SignDetLite on the P-extension -> the 8x8x3 grid decoded
# to one class on the OLED, all on the board.
#
#   west build -p always -b chipyard_pynqz1_all_f40 samples/signdet_live -d <dir> -- \
#       -DBOARD_ROOT=$IISWC_ROOT -DMODEL_DIR=out/signdet/gen \
#       -DSD_FRAMES_DIR=<bake_live_frames.py --out> \
#       -DMODELBLASTER_KERNEL_CFLAGS="..." -DSD_DEFS="SD_THR_PCT=50 SD_FRAMES=0"
#
# WHY A SEPARATE APP AND NOT A FLAG ON samples/sign_live.  sign_live is Lab B139's validated
# demo and other records depend on it; its main.c reads one 43-class softmax row and cannot be
# taught a 64-cell grid by a define.  samples/cam_snap was forked from it the same way.
#
# NOTHING IS COPIED.  ospi_cam.c and sign_pre_rgb.c are compiled out of
# fpga/pynq-z2/sw/cam/ -- the same sign_pre_rgb.c B144 drove through ctypes and checked byte
# for byte against signpre_rgb.py, and the same file bake_live_frames.py compiles for the
# host so the replay gate compares like with like.  The display's fonts, bar graph, CFB setup
# and BUS MUTEX come out of samples/oled_status/src/.  One of each, everywhere.
cmake_minimum_required(VERSION 3.20.0)

if(NOT DEFINED MODEL_DIR)
    message(FATAL_ERROR "MODEL_DIR not set (a modelblaster gen: model.c, kernels.c, weights.c, buffers.c).")
endif()
get_filename_component(MODEL_DIR "${MODEL_DIR}" ABSOLUTE)

get_filename_component(CAM_SW   "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw/cam" ABSOLUTE)
get_filename_component(PEXT_INC "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw"     ABSOLUTE)
get_filename_component(OLED_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../oled_status/src"        ABSOLUTE)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(signdet_live)

foreach(_required model.c model.h kernels.c kernels.h weights.c weights.h buffers.c)
    if(NOT EXISTS "${MODEL_DIR}/${_required}")
        message(FATAL_ERROR "MODEL_DIR='${MODEL_DIR}' is missing ${_required}.")
    endif()
endforeach()

# THE SHAPE GATE, at configure time rather than on a console.  A gen whose input is not
# 12,288 int8 or whose output is not 192 is not this demo's network, and an image built from
# one would boot, run, and decode a grid out of a tensor of the wrong size.
file(READ "${MODEL_DIR}/model.h" _mh)
if(NOT _mh MATCHES "MODEL_[A-Z0-9_]+_INPUT_SIZE[ \t]+12288")
    message(FATAL_ERROR "MODEL_DIR='${MODEL_DIR}': INPUT_SIZE is not 12288 (3 x 64 x 64 int8).")
endif()
if(NOT _mh MATCHES "MODEL_[A-Z0-9_]+_OUTPUT_SIZE[ \t]+192")
    message(FATAL_ERROR "MODEL_DIR='${MODEL_DIR}': OUTPUT_SIZE is not 192 (an 8x8 grid of 3 classes).")
endif()

target_sources(app PRIVATE
    src/main.c
    ${CAM_SW}/ospi_cam.c
    ${CAM_SW}/sign_pre_rgb.c
    ${OLED_SRC}/oled_status.c
    ${OLED_SRC}/font5x8.c
    ${OLED_SRC}/font10x16.c
    ${OLED_SRC}/font15x24.c
    ${MODEL_DIR}/model.c
    ${MODEL_DIR}/kernels.c
    ${MODEL_DIR}/weights.c
    ${MODEL_DIR}/buffers.c
)
target_include_directories(app PRIVATE src ${CAM_SW} ${PEXT_INC} ${OLED_SRC} ${MODEL_DIR})

# The baked replay frames are OPTIONAL: without them the image still runs live, and says so
# on the console rather than pretending it proved something.
if(DEFINED SD_FRAMES_DIR)
    get_filename_component(SD_FRAMES_DIR "${SD_FRAMES_DIR}" ABSOLUTE)
    if(NOT EXISTS "${SD_FRAMES_DIR}/signdet_frames.c")
        message(FATAL_ERROR "SD_FRAMES_DIR='${SD_FRAMES_DIR}' has no signdet_frames.c "
                            "(make it with fpga/pynq-z2/modelblaster/signdet/bake_live_frames.py).")
    endif()
    target_sources(app PRIVATE ${SD_FRAMES_DIR}/signdet_frames.c)
    target_include_directories(app PRIVATE ${SD_FRAMES_DIR})
    target_compile_definitions(app PRIVATE SD_REPLAY=1)
    message(STATUS "signdet_live: replay frames from ${SD_FRAMES_DIR}")
else()
    message(STATUS "signdet_live: no replay frames -- the image cannot check itself against "
                   "a known answer, and says so on the console")
endif()

# The kernels are compiled with the lab's flags, exactly as scripts/86 compiles them, so a
# millisecond measured here is comparable with Lab B145's 237.78.
if(DEFINED MODELBLASTER_KERNEL_CFLAGS)
    separate_arguments(_mb_kernel_cflags NATIVE_COMMAND "${MODELBLASTER_KERNEL_CFLAGS}")
    set_source_files_properties(${MODEL_DIR}/kernels.c PROPERTIES
        COMPILE_OPTIONS "${_mb_kernel_cflags}")
    message(STATUS "signdet_live kernels.c cflags: ${_mb_kernel_cflags}")
endif()

if(DEFINED SD_DEFS)
    separate_arguments(_sd_defs NATIVE_COMMAND "${SD_DEFS}")
    foreach(_d ${_sd_defs})
        target_compile_definitions(app PRIVATE ${_d})
    endforeach()
    message(STATUS "signdet_live defs: ${_sd_defs}")
endif()

# Same reason as every other model sample here: the packed int8 weight arrays push .sdata
# past the +/-2 KB gp-relative window and the link fails with "relocation truncated to fit".
zephyr_link_libraries(-Wl,--no-relax)
