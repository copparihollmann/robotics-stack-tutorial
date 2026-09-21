# SPDX-License-Identifier: Apache-2.0
#
# Host test for samples/oled_status on native_sim/native/64:
#   the stock ssd1306 driver + CFB + src/oled_status.c, over Zephyr's I2C emulator, into
#   model/ssd1306_model.c. Asserts the init sequence against the datasheet and dumps the
#   rendered GDDRAM so scripts/54_oled_host_tests.sh can hash it against
#   expected/oled_status.json. The overlay is the sample's own oled.overlay: native_sim's
#   I2C emulator controller is also labelled i2c0.
cmake_minimum_required(VERSION 3.20.0)

set(EXTRA_DTC_OVERLAY_FILE ${CMAKE_CURRENT_SOURCE_DIR}/../../oled.overlay)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(oled_status_host_test)

set(S ${CMAKE_CURRENT_SOURCE_DIR}/../..)
target_include_directories(app PRIVATE ${S}/src ${S}/model)
target_sources(app PRIVATE
  src/test_oled.c
  src/ssd1306_emul.c
  ${S}/src/oled_status.c
  ${S}/src/font5x8.c
  ${S}/model/ssd1306_model.c)
