# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator. The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem, then releasing the SoC from reset -- see
# fpga/pynq-z2/host/run_rocket.py.
#
# This board is chipyard_pynqz1_pext plus one peripheral: the PL-side PDM microphone
# decimator at 0x1009_0000. Everything else -- both harts, the ISA strings, the UART, the
# clock -- is identical, so an image built for chipyard_pynqz1_pext runs here unchanged.
# See fpga/pynq-z2/docs/MICROPHONE.md.
