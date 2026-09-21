.. _tacit_boot:

TACIT from the reset vector
###########################

Same guest and same workload as ``samples/tacit_dma``, but the trace starts at the first
instruction Rocket retires instead of at ``main()``. ``arch/riscv/core/reset.S`` programs
the DMA sink's address and the encoder's target and *then* asserts enable, so the sync
packet the decoder locks onto is the very first thing the sink sees.

``main()`` only closes the capture: stop the encoder, let a few thousand instructions
retire so the trailing sync packet drains, flush the sink's partial beat, flush the
inclusive L2 into DRAM, and report where the bytes are.

Run it with::

   scripts/with_board.sh ./scripts/23_rocket_tacit_boot.sh

The decoded Perfetto trace opens on ``z_prep_c`` / ``arch_bss_zero`` / ``z_cstart`` /
``plic_init``, the same way Lab A's Spike trace does.
