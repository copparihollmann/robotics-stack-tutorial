# SPDX-License-Identifier: Apache-2.0
#
# The HM01B0 camera on 0x5A5A001E: register check, bring-up diagnostics, the sensor over I2C,
# and one whole frame into DDR through the capture core's DMA master.  Runs with or without the
# shield; which one it found is the first thing it reports.
#
#   scripts/with_board.sh ./scripts/66_rocket_cam.sh
#
# The register-level driver is fpga/pynq-z2/sw/cam/ospi_cam.c, the file scripts/65_cam_rtl_sim.sh
# runs against the RTL.  I2C is Zephyr's own i2c_sifive driver on the board's i2c0 node.
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(cam_capture)

set(CAM_SW ${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw/cam)
target_include_directories(app PRIVATE ${CAM_SW})
target_sources(app PRIVATE src/main.c ${CAM_SW}/ospi_cam.c)

# -DCAM_MCLKDIV=n from the lab: MCLK = 34.4828 MHz / (2 * (n + 1)).  2 -> 5.747 MHz.
foreach(v CAM_MCLKDIV CAM_STREAM_MS)
  if(DEFINED ${v})
    target_compile_definitions(app PRIVATE ${v}=${${v}})
  endif()
endforeach()
