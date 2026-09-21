/* SPDX-License-Identifier: Apache-2.0
 *
 * Linker script for the bare-metal spike instruction-count harness.
 *
 * 0x8000_0000 is spike's default DRAM base and also the board's (out/rocket_mb_lenet_int8
 * reports "Entry point address: 0x80000000"), so the same address map is used for both.
 *
 * `tohost` and `fromhost` are found by spike BY SYMBOL NAME in the ELF, and it requires
 * them 8-byte aligned; .htif is given its own aligned output section so no other object
 * can be placed between them.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;

    .text : {
        *(.text.init)
        *(.text .text.*)
    }

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    }

    .htif : ALIGN(64) {
        PROVIDE(tohost = .);
        . += 8;
        PROVIDE(fromhost = .);
        . += 8;
    }

    .data : ALIGN(16) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    }

    .bss : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    . = ALIGN(16);
    . += 256 * 1024;          /* stack: the kernels keep their scratch in .bss, but the
                                 generated model.c puts its state struct on the stack */
    _stack_top = .;

    /DISCARD/ : { *(.comment) *(.note.*) *(.riscv.attributes) }
}
