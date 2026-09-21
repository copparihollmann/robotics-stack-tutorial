# SPDX-License-Identifier: Apache-2.0
#
# What a speech front end costs on a Rocket with no FPU -- measured, three ways.
#
#   scripts/with_board.sh ./scripts/36_rocket_audio_fe_bench.sh
#
# FE_ARITH selects which arithmetic audio_fe.c is compiled with: float (the straw man),
# int (fixed point on the core's own iterative multiplier) or pext (fixed point with
# MBP.QMUL).  The runner builds all three from this one CMakeLists and compares them.
#
# MB_PEXT_HW is set ONLY for FE_ARITH=pext, and the sample pins itself to hart 0, because
# hart 1 has no MBP decode and would take an illegal-instruction trap.
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(audio_fe_bench)

set(FE_ARITH "int" CACHE STRING "float | int | pext")
set(FE_GEOM  "asr" CACHE STRING "asr (512/400/160, 100 fps) | kws (512/480/320, 50 fps)")
set(SW ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw)

target_sources(app PRIVATE src/main.c ${SW}/audio_fe.c ${SW}/audio_fe_tables_${FE_GEOM}.c)
target_include_directories(app PRIVATE ${SW})

# The geometry has to reach BOTH the kernel and the table, and audio_fe_tables_*.c
# carries a _Static_assert that they agree -- a table built for one framing and a kernel
# compiled for another produces a plausible spectrum that is simply wrong.
if(FE_GEOM STREQUAL "asr")
  target_compile_definitions(app PRIVATE FE_NFFT=512 FE_FRAME_LEN=400 FE_HOP_LEN=160)
elseif(FE_GEOM STREQUAL "kws")
  target_compile_definitions(app PRIVATE FE_NFFT=512 FE_FRAME_LEN=480 FE_HOP_LEN=320)
else()
  message(FATAL_ERROR "FE_GEOM must be asr or kws (got '${FE_GEOM}')")
endif()

if(FE_ARITH STREQUAL "float")
  target_compile_definitions(app PRIVATE FE_ARITH_FLOAT=1)
elseif(FE_ARITH STREQUAL "pext")
  target_compile_definitions(app PRIVATE FE_ARITH_PEXT=1 MB_PEXT_HW=1)
elseif(FE_ARITH STREQUAL "int")
  target_compile_definitions(app PRIVATE FE_ARITH_INT=1 MB_PEXT_HW=0)
else()
  message(FATAL_ERROR "FE_ARITH must be float, int or pext (got '${FE_ARITH}')")
endif()
message(STATUS "audio_fe_bench: FE_ARITH=${FE_ARITH} FE_GEOM=${FE_GEOM}")
