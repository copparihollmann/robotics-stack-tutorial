#!/usr/bin/env bash
# Lab B4 -- TACIT off real silicon, from the reset vector.
#
# Lab B2 (scripts/21_rocket_tacit.sh) captures the workload: samples/tacit_dma brackets
# workload() with start/stop, so the trace opens inside main(). Lab A's Spike trace opens
# on z_prep_c. This closes that gap on hardware -- the encoder is enabled in
# arch/riscv/core/reset.S, so the trace covers the whole guest lifecycle.
#
# The flow is identical to Lab B2 and this script deliberately reuses it rather than
# forking it; the difference is entirely in the guest:
#
#   samples/tacit_boot/prj.conf    CONFIG_STARTUP_TACIT=y
#                                  CONFIG_STARTUP_TACIT_TARGET=1
#                                  CONFIG_STARTUP_TACIT_SINK_DMA_ADDR=0x88000000
#
# and in reset.S, which those two new options make program the DMA sink's address and the
# encoder's target BEFORE asserting enable. Stock CONFIG_STARTUP_TACIT writes TR_TE_CTRL
# = 0x2 and nothing else; with target still 0 and no sink at target 0 on this SoC,
# TraceSinkArbiter accepts every byte and drops it. See
# fpga/pynq-z2/docs/TACIT_ON_FPGA.md section 7.
#
# That reset.S change lives in a checkout this repo does not track, so it is carried as
# patches/0003-zephyr-startup-tacit-dma-sink.patch and applied here, idempotently, before
# the build.
#
# The board is shared. Run this under the lock:
#   scripts/with_board.sh ./scripts/23_rocket_tacit_boot.sh
#   scripts/with_board.sh ./scripts/23_rocket_tacit_boot.sh --no-bitstream
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

case "${1-}" in -h|--help) sed -n '2,29p' "$0"; exit 0 ;; esac

"$IISWC_ROOT/scripts/06_patch_zephyr.sh"

exec "$IISWC_ROOT/scripts/21_rocket_tacit.sh" \
  --sample "$IISWC_ROOT/samples/tacit_boot" \
  --name rocket_tacit_boot \
  "$@"
