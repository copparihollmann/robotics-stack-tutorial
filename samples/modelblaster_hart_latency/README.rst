Per-hart inference latency
##########################

Runs a ModelBlaster-generated, scalar-integer network on each hart of the dual-core
big.LITTLE Rocket and measures how long one inference takes on each.

**One hart at a time.** The harts share an inclusive 64 KB L2 and one AXI4 path to DDR, so
running both inferences concurrently would make each one's latency a function of the
other's memory traffic. Instead: create a worker, ``k_thread_cpu_pin`` it to CPU *h*,
start it, and join before creating the next. ``main()`` is pinned to CPU 0 and blocks on
the join semaphore throughout, so while a worker runs the other hart has nothing runnable
and sits in Zephyr's idle thread -- ``wfi``.

What it measures, per hart:

* **latency** -- ``rdcycle`` (the per-hart ``mcycle`` CSR, 40 MHz, 25 ns) around each of
  ``MB_ITERS`` inferences, median / min / max / mean reported. One warm-up inference runs
  first and is reported separately rather than averaged in.
* **a second clock** -- ``mtime``, the single CLINT counter shared by both harts, via the
  generated model's own ``model_wall_cycles()``. 40 kHz, so it cannot resolve a layer, but
  it catches a wrong core-clock assumption.
* **per-kernel cycles** -- ModelBlaster's own ``rdcycle`` profile array, one record per
  dispatch, copied out before the other hart's worker overwrites it.
* **correctness** -- integer-exact compare against the baked int8 golden, on *both* harts,
  plus a check that the two harts produced byte-identical output. A latency number from a
  run where that fails means nothing.

Interrupts are masked (``irq_lock``) for the duration of each timed iteration, so the
1 kHz tick ISR does not land inside the measurement. The mask is inside the loop, not
around it, so the console and the tick recover between iterations.

**No floating point anywhere.** This SoC is ``WithoutFPU`` -- ``riscv,isa =
"rv64imaczicsr_zifencei_zihpm_xrocket"`` on both harts -- so ``prj.conf`` states
``CONFIG_FPU=n`` and ``CONFIG_CBPRINTF_FP_SUPPORT=n`` explicitly rather than inheriting
them, and every number this app prints is computed and formatted in integers. That is also
why it exists instead of reusing ``modelblaster/harness``, whose ``prj.conf`` sets
``CONFIG_FPU=y`` and would override the board.

Build and run::

    scripts/with_board.sh ./scripts/24_rocket_modelblaster.sh

The app needs ``-DMODEL_DIR=<a modelblaster generated/<target>/ directory>``; the script
produces one with ``extract_graph`` / ``generate_skeleton`` / ``generate_kernels`` and
passes it in. ``-DMB_ITERS=<n>`` sets the iteration count (default 11).

Requires the dual-core bitstream (``fpga/pynq-z2/scripts/build_smp_z1.sh``) and the
``chipyard_pynqz1_smp`` board. See ``fpga/pynq-z2/docs/MODELBLASTER_ON_ROCKET.md``.
