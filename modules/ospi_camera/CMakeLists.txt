# SPDX-License-Identifier: Apache-2.0
#
# The out-of-tree driver for ucbbar,ospi-hm01b0.  Reached as a Zephyr module: see
# zephyr/module.yml, and samples/cam_capture/CMakeLists.txt for how an application asks for
# it.
#
# EVERYTHING HERE IS INSIDE if(CONFIG_OSPI_HM01B0), so a build for a board with no camera
# node compiles nothing and links nothing from this directory -- which is what makes the
# module safe to name unconditionally.  CONFIG_OSPI_HM01B0 is default-y from the devicetree
# (Kconfig, and the note in it), so on a board that has the node nobody has to ask.
#
# ospi_cam.c IS COMPILED HERE AND NOWHERE ELSE for an image that uses this driver.  It is the
# same file samples/cam_rtl_sim builds for Verilator and scripts/65_cam_rtl_sim.sh runs
# against the RTL: one copy of the register sequences, two hosts.  An application that lists
# it in its own target_sources as well would get duplicate symbols, so the camera samples no
# longer do.

if(CONFIG_OSPI_HM01B0)
  get_filename_component(OSPI_CAM_SW "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw/cam"
                         ABSOLUTE)
  if(NOT EXISTS "${OSPI_CAM_SW}/ospi_cam.c")
    message(FATAL_ERROR "ospi_camera: no ospi_cam.c at ${OSPI_CAM_SW} -- this module is "
                        "in-tree beside fpga/pynq-z2/sw/cam and cannot be moved on its own.")
  endif()

  zephyr_library_named(ospi_camera)
  zephyr_library_sources(drivers/ospi_camera.c ${OSPI_CAM_SW}/ospi_cam.c)

  # Both directories are public: ospi_camera.h is the driver's API, and ospi_cam.h beside it
  # is the register map, which register-level diagnostics in samples/cam_capture still read.
  zephyr_library_include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include ${OSPI_CAM_SW})
  zephyr_include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include ${OSPI_CAM_SW})
endif()
