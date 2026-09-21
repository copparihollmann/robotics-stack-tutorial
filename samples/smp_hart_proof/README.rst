Two-hart proof
##############

Proves that a Zephyr SMP image is really executing on both harts of the dual-core
big.LITTLE Rocket, rather than booting and quietly running everything on hart 0.

"It booted" is evidence of nothing here: the dual-core image boots perfectly well against
the single-core bitstream, and a ``CONFIG_MP_MAX_NUM_CPUS=1`` image boots perfectly well
against the dual-core one. Both produce a console that looks healthy.

So this measures four independent things, each of which fails distinguishably if hart 1
never left the bootrom:

1. **identity** -- each pinned worker reads the ``mhartid`` CSR, the hardware's own answer
2. **barrier** -- both workers ``atomic_inc`` a shared counter and spin until it reaches 2,
   which cannot complete unless both are executing at the same instant
3. **overlap** -- each worker's execution window on ``mtime``, the one counter both harts
   share, plus a wall clock of ~1x the job rather than ~2x
4. **ping-pong** -- a sequence number handed back and forth through one shared word

Each has a deadline, so a single-core failure reports rather than hanging the board.

Build and run::

    scripts/with_board.sh ./scripts/22_rocket_smp_run.sh

Requires the dual-core bitstream (``fpga/pynq-z2/scripts/build_smp_z1.sh``) and the
``chipyard_pynqz1_smp`` board. See ``fpga/pynq-z2/docs/DUAL_CORE.md``.
