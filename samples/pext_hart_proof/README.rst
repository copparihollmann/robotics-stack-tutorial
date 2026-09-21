.. _pext_hart_proof:

MBP packed SIMD: the extension on one hart, and the trap on the other
#####################################################################

Overview
********

The hardware acceptance test for MBP, the four-op packed-SIMD extension built into
Rocket's ALU on **hart 0 only** of the PYNQ-Z1 big.LITTLE SoC.

This is ``samples/pext_rtl_selftest`` ported to Zephyr SMP, with the same golden tables,
the same case selection and the same xorshift seed -- so a divergence between the
Verilator model and the routed part is a difference in the hardware and not in the test.

Three things it establishes, none of which is answerable anywhere else:

#. **The routed ALU computes what** ``fpga/pynq-z2/sw/pext.h`` **says it computes**, byte
   for byte, including ``MBP.QMUL``'s round-half-up boundary. Simulation proves the logic;
   only hardware proves the logic closed timing.
#. **The negative test.** Hart 1 is a LITTLE Rocket built without the MBP decode table and
   without the datapath, so the same four *encodings* must raise an illegal-instruction
   exception there and must not write ``rd``. This is the whole heterogeneity claim.
   Without it, a build that mapped the extension over both tiles -- which elaborates,
   routes and boots -- would satisfy everything else here.
#. **Both harts report the same ISA letters in** ``misa`` **and different privilege bits.**
   MBP is in the custom-0 opcode space and has no ``misa`` bit, which is exactly why 2 has
   to execute an instruction rather than read a register.

Requirements
************

The ``chipyard_pynqz1_pext`` board and the bitstream that matches it
(``MAGIC = 0x5A5A0004``, 34.4828 MHz). Running this image against any other Rocket
bitstream makes hart 0 trap on the first MBP instruction, which looks exactly like the
heterogeneity test failing; ``scripts/29_rocket_pext_run.sh`` refuses that case by name.

Building and Running
********************

.. code-block:: console

   scripts/with_board.sh ./scripts/29_rocket_pext_run.sh

Sample Output
*************

.. code-block:: console

   -- 1. MBP on hart 0 (BIG): the four ops against sw/pext.h
      3041 checks, 0 failures

   -- 3. THE NEGATIVE TEST: the same four encodings on hart 1 (LITTLE)
      hart1 DOT8  trapped: mcause=2 mepc=0x00000000800003b0 mtval=0x0115878b rd=0xa5a5a5a5a5a5a5a5 (unwritten)

   CHECKS pext_ops=1 hart0_legal=1 hart1_traps=1 isa_match=1 priv_split=1
   TOTAL 3071 checks, 0 failures
   PEXT_HART_PROOF: PASS

The ``mepc`` values and the register fields inside ``mtval`` move with the compiler's
allocation; the low twelve bits of ``mtval`` -- funct3 and opcode ``0x0b`` -- are the part
that identifies the instruction.

Notes
*****

``src/trap.S`` installs a private ``mtvec`` for the length of four instructions, because
Zephyr routes a CPU exception to ``z_fatal_error()`` and the only sanctioned recovery from
there is aborting the thread -- which loses ``mcause``/``mepc``/``mtval`` and cannot go on
to the next encoding. ``irq_lock()`` spans the window, and both ``mtvec`` and ``mscratch``
are saved and restored. See ``fpga/pynq-z2/docs/PEXT_BITSTREAM.md`` section 4.
