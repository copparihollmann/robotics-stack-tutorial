.. SPDX-License-Identifier: Apache-2.0

pext_rtl_selftest
#################

The RTL acceptance test for **MBP**, the four-op packed-SIMD extension built into
Rocket's ALU on hart 0. It is bare metal on the Chipyard Verilator ``TestHarness``
for ``PynqZ2RocketBigLittlePextTacitConfig`` — no Zephyr, no newlib, no SDK.

Run it::

   export CHIPYARD_DIR=/path/to/chipyard
   scripts/27_pext_rtl_sim.sh

Expected tail::

   hart 0: 3042 checks, 0 failures
   hart 1 (LITTLE): the same four encodings must raise illegal-instruction
     hart1 DOT8: mcause=2 mepc=0x... mtval=0x00d5070b rd=0xa5a5a5a5a5a5a5a5
     hart1 MAX8: mcause=2 mepc=0x... mtval=0x00d5170b rd=0xa5a5a5a5a5a5a5a5
     hart1 QMUL: mcause=2 mepc=0x... mtval=0x00d5270b rd=0xa5a5a5a5a5a5a5a5
     hart1 CLIP8: mcause=2 mepc=0x... mtval=0x0007378b rd=0xa5a5a5a5a5a5a5a5
   TOTAL 3055 checks, 0 failures
   PEXT_RTL_SELFTEST: PASS

``mepc`` and the register fields inside ``mtval`` move with whatever registers the compiler
picked; the low twelve bits of ``mtval`` — funct3 and opcode ``0x0b`` — are the part that
identifies the instruction, and they are what the four lines above are worth reading.

What this is, and what it is not
================================

``samples/pext_selftest`` is the *differential* test: one source, three builds
(patched Spike with the real encodings, the software model on the same target, the
software model on the host), diff the logs. It pins the semantics.

**This** one is the test only real RTL can run, and it answers two questions a
functional simulator cannot:

1. **Does the synthesised ALU compute what the spec says?** The instructions execute
   in the EX stage with the core's own bypass network feeding the operands. A lane
   swap, a sign extension off by one bit, or a result silently truncated at bit 31
   by the ALU's ``DW_32`` path shows up here and nowhere earlier.

2. **Does hart 1 trap?** Hart 1 is a LITTLE Rocket elaborated *without* ``usePExt``,
   so it has no ``PExtDecode`` table and no SIMD datapath, and the same four
   encodings must raise an illegal-instruction exception. That is the heterogeneity
   mechanism (``PEXT_SPEC.md`` §7.6), not a degradation path, so it is a mandatory
   *positive* test that the trap happens — with ``mcause == 2``, ``mepc`` at the
   instruction, ``mtval`` carrying the instruction word, and ``rd`` **unwritten**.
   It is only checkable on a two-hart machine that really lacks the unit on one hart.

The reference, and why there are also goldens
=============================================

Every hardware result is compared against ``mb_pext_*_sw()`` from
``fpga/pynq-z2/sw/pext.h``, which *is* the specification.

On top of that, the cases marked ``golden`` carry an **absolute expected value
written out by hand**, because hardware compared against a reference compiled from
the same header into the same binary cannot catch an error that is *in* the
reference. Writing the goldens out and checking them against an independent
evaluator found five arithmetic errors in the first draft of this file — including
that ``1 × 2^30`` in Q0.31 is itself an exact tie and rounds to **1**, not 0.

What the cases cover, deliberately
==================================

``DOT8``
   The full ±131072 range: all eight lanes ``-128 × -128 = +131072`` and
   ``-128 × +127 = -130048``. One live lane in each of the eight positions, which is
   what catches a lane index or byte shift off by one. Mixed signs. 256 random pairs.

``MAX8``
   ``-128`` against ``+127`` in both operand orders; equal lanes; a patterned word
   with a different winner in every lane, chosen so that an *unsigned* comparison
   would pick the other operand; 256 random pairs. Plus the ReLU form with
   ``rs2 = x0``, which is a **different encoding** from ``max8(x, 0)`` and so is
   exercised separately.

``QMUL``
   The rounding boundary. ``p = +2^30`` and ``p = -2^30`` are exact half-LSB ties:

   =========================  =========
   rule                       (+, -)
   =========================  =========
   round-half-up              (+1,  0)
   round-half-away-from-zero  (+1, -1)
   round-half-to-even         ( 0,  0)
   =========================  =========

   Only half-up produces the pair the reference produces, so **those two cases alone
   separate all three rules** — and getting it wrong is 1 LSB on roughly half of all
   negative outputs. Also both int32 extremes, where the product needs all 62 bits;
   a 64-case sweep through the tie neighbourhood; and operands with garbage in bits
   63:32, which the instruction must ignore because the reference casts to ``int32``.

``CLIP8``
   Saturation at both ends: -130/-129/-128/-127 and +126/+127/+128/+129, a walk over
   the whole in-range interval with a margin, the int64 extremes, and values that
   differ only above the byte.

composition
   ``QMUL`` → scalar rounding shift → ``CLIP8`` against ``mb_pext_requant_sw`` over
   six multipliers × seven shifts × 24 accumulators. That is the shape a quantised
   kernel's output stage actually has, and the thing the fused ``MBP.RQS`` was split
   into.

Files
=====

===========  ====================================================================
``main.c``   the cases, the HTIF console, and the hart-1 probe
``crt.S``    two-hart startup and the trap handler that retires the faulting
             instruction so four traps can be taken in a row
``link.ld``  bare-metal link at ``0x8000_0000`` with ``tohost``/``fromhost``
===========  ====================================================================

Both harts arrive at ``_start`` — Chipyard's bootrom ``mret``\ s every hart to
``DRAM_BASE`` with ``a0 = mhartid`` — which is what makes the negative test possible
from a bare-metal image at all. Three orderings in ``crt.S`` are load-bearing and
are commented there: ``mtvec`` before anything can fault, ``.bss`` cleared by hart 0
only with hart 1 spinning on a flag that lives in ``.data``, and the bootrom's MSIP
enable cleared so that the only thing which can reach the handler afterwards is a
synchronous exception.

The build is ``rv64imac_zicsr_zifencei`` / ``lp64``: the SoC is ``WithoutFPU``, so an
``lp64d`` build would emit FP instructions that trap on **both** harts and make the
negative test meaningless.
