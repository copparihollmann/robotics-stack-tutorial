# SPDX-License-Identifier: Apache-2.0
# The existing Zephyr device wraps the embedded camera backend. Register-level
# diagnostics retain the portable tutorial driver used by the RTL simulation.
if(CONFIG_OSPI_HM01B0)
  get_filename_component(OSPI_CAM_SW "${CMAKE_CURRENT_SOURCE_DIR}/../../fpga/pynq-z2/sw/cam"
                         ABSOLUTE)
  zephyr_library_named(ospi_camera)
  zephyr_library_sources(
    drivers/ospi_camera.c
    backend/src/ospi_camera.c
    backend/src/ospi_camera_dma.c
    ${OSPI_CAM_SW}/ospi_cam.c)
  zephyr_library_compile_definitions(OSPI_CAMERA_I2C_RESTART=1)
  zephyr_library_include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/backend/include
    ${OSPI_CAM_SW})
  zephyr_include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/backend/include
    ${OSPI_CAM_SW})
endif()
