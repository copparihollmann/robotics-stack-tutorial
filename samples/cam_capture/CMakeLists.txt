# SPDX-License-Identifier: Apache-2.0
#
# The HM01B0 camera on 0x5A5A001E: register check, bring-up diagnostics, the sensor over I2C,
# and one whole frame into DDR through the capture core's DMA master.  Runs with or without the
# shield; which one it found is the first thing it reports.
#
#   scripts/with_board.sh ./scripts/66_rocket_cam.sh
#
# THE CAMERA IS A ZEPHYR DEVICE HERE, and modules/ospi_camera is the driver.  It is an
# out-of-tree Zephyr MODULE, which is how a driver that is not in the Zephyr tree still binds
# a compatible: naming it in ZEPHYR_EXTRA_MODULES before find_package(Zephyr) merges its
# Kconfig into the configuration tree and its CMakeLists.txt into the build.
#
# NOTHING IN prj.conf ASKS FOR THE DRIVER.  CONFIG_OSPI_HM01B0 is `default y` gated on
# DT_HAS_UCBBAR_OSPI_HM01B0_ENABLED, so it switches on because the board declares an enabled
# ospi@10080000 node -- exactly the way CONFIG_I2C_SIFIVE switches on for the i2c@10040000
# node beside it.  `grep OSPI_HM01B0 <build>/zephyr/.config` after a build is the check.
#
# The module compiles fpga/pynq-z2/sw/cam/ospi_cam.c -- the measured register sequences, the
# same file scripts/65_cam_rtl_sim.sh runs against the RTL in Verilator -- so this file must
# NOT list it again.  It also puts that directory and the driver's own include/ on the app's
# include path, so src/main.c finds <ospi_camera.h> and the register map beside it.
cmake_minimum_required(VERSION 3.20.0)

list(APPEND ZEPHYR_EXTRA_MODULES ${CMAKE_CURRENT_SOURCE_DIR}/../../modules/ospi_camera)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(cam_capture)

target_sources(app PRIVATE src/main.c)

# -DCAM_MCLKDIV=n from the lab: MCLK = 34.4828 MHz / (2 * (n + 1)).  2 -> 5.747 MHz.
# B161: the upstream sensor settings, all opt-in (see src/main.c, "the upstream sensor
# settings").  Absent = the historical arm, unchanged.
foreach(v CAM_MCLKDIV CAM_STREAM_MS CAM_BLC_CFG CAM_DPC_CTRL CAM_FRAME_LEN CAM_MAX_INTG CAM_INTEG)
  if(DEFINED ${v})
    target_compile_definitions(app PRIVATE ${v}=${${v}})
  endif()
endforeach()
