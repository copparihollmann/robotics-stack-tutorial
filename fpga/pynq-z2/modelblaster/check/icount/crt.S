/* SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal startup for the spike instruction-count harness.  Deliberately tiny: the
 * thing being measured is a per-dispatch minstret delta, so anything this file does
 * before main() is outside every measurement window and only has to be correct.
 *
 * Machine mode, no traps installed, no interrupts enabled, no FPU touched (the SoC is
 * WithoutFPU and the build is -march=rv64imac_zicsr_zifencei, so there is no FS state to
 * enable and an fp instruction would be illegal here exactly as it is on the board).
 */

    .section .text.init, "ax"
    .globl _start
    .type  _start, @function
_start:
    la      sp, _stack_top

    /* .bss, which holds the generated model's intermediate buffers and the kernels'
     * scratch.  The C makes no assumption that it is zero, but spike does not zero
     * memory either and an uninitialised read would make a measurement irreproducible
     * for a reason that has nothing to do with the kernel. */
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:
    call    main
    call    htif_exit_ok
3:  j       3b
    .size   _start, . - _start
