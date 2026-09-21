# SPDX-License-Identifier: Apache-2.0
#
# Real hardware: no emulator. The image is loaded by the Zynq PS writing zephyr.bin into
# DDR through /dev/mem, then releasing the SoC from reset -- see
# fpga/pynq-z2/host/run_rocket.py. There is no Zephyr flash runner for that path.
#
# Both harts start from the same image: the Chipyard bootrom releases hart 0, hart 0 then
# pokes every other hart's MSIP, and each hart mrets to the same BootAddrReg value. Zephyr
# sorts them out in reset.S by mhartid. See fpga/pynq-z2/docs/DUAL_CORE.md.
