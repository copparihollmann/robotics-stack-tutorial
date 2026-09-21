pext_selftest -- MBP packed-SIMD differential test
##################################################

What it is
==========

One source file, built three ways, printing the same bytes each time:

=========================================  =====================================
``MB_PEXT_HW=1``, ``spike_riscv64``        the four custom-0 encodings, executed
                                           by the patched TACIT Spike
``MB_PEXT_HW=0``, ``spike_riscv64``        the software model in ``pext.h``
``MB_PEXT_HW=0``, host ``cc``              the same model, different compiler,
                                           different ISA
=========================================  =====================================

Each case is also checked inside the binary against ``mb_pext_*_sw()``, so a wrong
implementation prints ``MISMATCH`` with the exact operands rather than showing up as a
diff between two long logs.

Run it
======

.. code-block:: console

   scripts/11_pext_selftest.sh

That builds all three, runs the two Zephyr builds on Spike, diffs the console output,
and reports the ``minstret`` delta over the counted kernel for each -- which is the
instruction-count saving from the extension, measured on the same simulator that
produced the projections in ``fpga/pynq-z2/docs/PEXT_SPEC.md``.

To decode a trace of it instead:

.. code-block:: console

   scripts/10_tacit_hello.sh --sample samples/pext_selftest --name pext_selftest

The contract
============

``fpga/pynq-z2/sw/pext.h`` is the specification. If Spike, the RTL and that header ever
disagree, the header is right.
