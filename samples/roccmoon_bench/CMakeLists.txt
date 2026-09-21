# SPDX-License-Identifier: Apache-2.0
#
# The decoupled RoCC engine on the board (ROCC_DECOUPLED.md section 8), bitstream 0x5A5A0010.
#   scripts/with_board.sh ./scripts/51_rocket_roccmoon.sh
#
# Five halves: placement (hart 1 answers custom-1, hart 1 still TRAPS on MBP's custom-0,
# hart 0 traps on custom-1); bit-exactness on the silicon (the engine against ModelBlaster's
# reference kernel AND the curated MBP kernel hart 0 runs); Moonshine Tiny's linear shapes
# timed both ways; the engine's own fill port at 1..8 outstanding; and the curated kernel
# files a ModelBlaster model links, compiled into one translation unit after the same
# `kernel_<op>` -> `kernel_<op>_<id>` rename generate_kernels.py applies.
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(roccmoon_bench)

get_filename_component(SW "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw" ABSOLUTE)
get_filename_component(KERN "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/modelblaster/kernels" ABSOLUTE)

# A stand-in for ModelBlaster's kernels.c: the two roccmoon kernel files, renamed.
set(RM_TU "${CMAKE_CURRENT_BINARY_DIR}/rm_kernels.c")
file(WRITE "${RM_TU}" "/* generated: the roccmoon curated kernels, renamed as generate_kernels.py does */\n")
foreach(op linear_s8 conv2d_s8)
  file(READ "${KERN}/roccmoon/roccmoon_${op}_roccmoon_engine.c" _src)
  string(REGEX REPLACE "kernel_${op}([^_a-zA-Z0-9])" "rm_kernel_${op}\\1" _src "${_src}")
  file(APPEND "${RM_TU}" "${_src}\n")
endforeach()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${KERN}/roccmoon/roccmoon_linear_s8_roccmoon_engine.c"
  "${KERN}/roccmoon/roccmoon_conv2d_s8_roccmoon_engine.c")

target_include_directories(app PRIVATE ${SW} ${SW}/roccmoon)
# mbxr.c arrives through mbxr_rt.h inside rm_kernels.c, exactly as it would in kernels.c
target_sources(app PRIVATE src/main.c src/rocc.S src/ref_linear.c "${RM_TU}"
                           ${KERN}/pext/pext_linear_s8_pext_row_dot8.c
                           ${KERN}/pext_nl/pext_nl_matmul_b_s8_pext_dot8_exact.c)
set_source_files_properties(${KERN}/pext/pext_linear_s8_pext_row_dot8.c PROPERTIES
  COMPILE_DEFINITIONS "kernel_linear_s8=pext_kernel_linear_s8;MB_PEXT_HW=1")
# section 6: the attention matmul, the file a ModelBlaster model links, renamed the same way
set_source_files_properties(${KERN}/pext_nl/pext_nl_matmul_b_s8_pext_dot8_exact.c PROPERTIES
  COMPILE_DEFINITIONS "kernel_matmul_b_s8=pext_kernel_matmul_b_s8;MB_PEXT_HW=1")
# ...and a SECOND copy of the same file with the hoisted nest compiled out, so section 6 can time
# both on one machine with one set of buffers and compare their outputs BYTE FOR BYTE.  A tolerance
# would hide exactly the kind of mistake a hoist makes, so the gate is identity (MATMUL_B_COST.md
# section 14, P5).  Its statics are file-static, so the two copies do not collide.
set(MMB_REF_TU "${CMAKE_CURRENT_BINARY_DIR}/mmb_ref.c")
file(WRITE "${MMB_REF_TU}"
  "/* generated: pext_nl_matmul_b_s8_pext_dot8_exact.c with the specialised nest compiled out */\n"
  "#define MBP_MMB_NO_SPECIALIZE 1\n"
  "#define kernel_matmul_b_s8 pext_ref_matmul_b_s8\n"
  "#include \"${KERN}/pext_nl/pext_nl_matmul_b_s8_pext_dot8_exact.c\"\n")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${KERN}/pext_nl/pext_nl_matmul_b_s8_pext_dot8_exact.c")
target_sources(app PRIVATE "${MMB_REF_TU}")
set_source_files_properties("${MMB_REF_TU}" PROPERTIES COMPILE_DEFINITIONS "MB_PEXT_HW=1")
set_source_files_properties(src/main.c "${RM_TU}" PROPERTIES COMPILE_DEFINITIONS "MB_PEXT_HW=1")
