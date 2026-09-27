# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)
list(APPEND ZEPHYR_EXTRA_MODULES ${CMAKE_CURRENT_SOURCE_DIR}/../../modules/ospi_camera)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(cam_capture)
target_sources(app PRIVATE src/main.c)

# FCLK0 / (2 * (divider + 1)): 40 MHz / 6 on the tutorial board.
set(CAM_MCLKDIV 2 CACHE STRING "Camera master-clock divider")
target_compile_definitions(app PRIVATE CAM_MCLKDIV=${CAM_MCLKDIV})
