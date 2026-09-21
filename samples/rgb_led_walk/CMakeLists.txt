# SPDX-License-Identifier: Apache-2.0
#
# Walk the PYNQ-Z1's two RGB LEDs through a sequence a person can check at a glance.
#
#   scripts/with_board.sh ./scripts/35_rocket_rgb_leds.sh
#
# The sample is written against <zephyr/drivers/gpio.h> and the board's gpio-leds node and
# nothing else: no register offsets, no board-specific header, no driver of ours. The pin
# numbers and the active-high polarity are devicetree's business. The brightness limit is
# the FPGA top's business. See fpga/pynq-z2/docs/RGB_LEDS.md.
cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(rgb_led_walk)

target_sources(app PRIVATE src/main.c)

# Overridable from the runner, so the lab can be re-run slower for a demo without editing
# the source:  west build ... -- -DRGB_STEP_MS=2000 -DRGB_CYCLES=5
foreach(v RGB_STEP_MS RGB_CYCLES)
  if(DEFINED ${v})
    target_compile_definitions(app PRIVATE ${v}=${${v}})
  endif()
endforeach()
