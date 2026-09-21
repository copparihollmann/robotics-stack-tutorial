Memory hierarchy characteriser
##############################

Measures what each level of the dual-core big.LITTLE Rocket's memory hierarchy actually
delivers -- L1D, the shared L2, and DRAM through the AXI4-to-AXI3 shim -- per hart, and
with both harts streaming at once.

Everything below L1 in this SoC had only ever been quoted as a computed peak. This sweeps
it instead::

    scripts/with_board.sh ./scripts/25_rocket_membench.sh

Requires the dual-core bitstream (``fpga/pynq-z2/scripts/build_smp_z1.sh``) and the
``chipyard_pynqz1_smp`` board. Results and the full analysis:
``fpga/pynq-z2/docs/MEMORY_HIERARCHY.md``.

What it measures
================

* **Bandwidth against working-set size**, 2 KiB to 16 MiB, read and write separately.
  Both cache boundaries are crossed twice over, because the two harts do not have the
  same L1: hart 0 has 16 KiB 4-way, hart 1 has 4 KiB direct-mapped.
* **Load-to-use latency** by pointer chase over a randomised cyclic permutation of the
  cache lines (Sattolo's algorithm, built in place in the buffer itself). No stride, so
  nothing can predict it.
* **Contention**: both harts streaming their own 16 MiB region simultaneously, through one
  shared L2, one 64-bit AXI port and one DDR controller.

How it avoids measuring the wrong thing
=======================================

* **The inner loops are assembly** (``src/kernels.S``), 32 loads or stores per 256-byte
  iteration. The runner disassembles them out of the built ELF into ``inner_loops.txt``,
  so the numbers can be traced to instructions rather than to a compiler's mood. The 8x
  unrolling is not decoration: it puts the L1-resident ceiling at 7.53 B/cycle instead of
  the 3.8 a loop that also summed the data would allow.
* **Flushed between every repetition**, through the SiFive InclusiveCache ``Flush64``
  register. The L2 is inclusive, so that clears both L1s too. The run proves the flush
  works rather than assuming it: a cold pass must be measurably slower than the warm pass
  right behind it (``CHK flush ... ratio100``).
* **Timed on rdcycle**, 25 ns, with interrupts locked on the measuring hart -- but with
  ``arch_irq_lock()``, not ``irq_lock()``. Under ``CONFIG_SMP`` the latter is
  ``z_smp_global_lock()``, a lock shared by every CPU, and holding it across a measurement
  window makes the two harts take turns instead of contending. See the comment on
  ``LOCAL_IRQ_LOCK`` in ``src/main.c``; it cost a board run to find and it reported 100%
  scaling very convincingly.
* **The contention is witnessed, not assumed.** Each timed window samples whether the
  partner hart was also loading the memory system, and the two workers' windows are
  compared on the shared ``mtime`` counter. Both appear in ``run.json``.
* **No FPU.** The core is ``rv64imac``; the runner refuses to go near the board unless the
  ELF reports a soft-float ABI and no ``f``/``d``/``v`` in ``Tag_RISCV_arch``.
* **Ceilings are checked.** Nothing may exceed 8 B/cycle, or 320 MB/s through the shim. A
  result above the link ceiling is a broken measurement, not fast hardware, and the run
  says so.

Working sets live at fixed physical addresses high in DRAM -- 0x8100_0000 for hart 0 and
0x8200_0000 for hart 1, 16 MiB each -- rather than on the heap, so that the buffer's
alignment (and therefore its cache-set mapping) is a property of the benchmark and not of
an allocator. ``main()`` refuses to run if they would overlap ``_image_ram_end``.
