/* SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal link for the Chipyard Verilator TestHarness.  The image is loaded into
 * ExtMem by TSI and the bootrom mrets both harts to DRAM_BASE with a0 = mhartid.
 *
 * .htif carries `tohost` / `fromhost`.  fesvr finds them by SYMBOL, not by section, but
 * riscv-tests puts them on their own page and so does this -- a page of their own keeps
 * them out of any cache line the program writes, which matters because the host polls
 * them through the TSI back door while the core is running.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY { ram (rwxa) : ORIGIN = 0x80000000, LENGTH = 16M }

SECTIONS
{
  . = 0x80000000;

  .text.init : { *(.text.init) } > ram

  . = ALIGN(0x1000);
  .htif : { PROVIDE(__htif_base = .); *(.htif) } > ram

  . = ALIGN(0x1000);
  .text : { *(.text.unlikely .text.unlikely.*) *(.text .text.*) } > ram

  . = ALIGN(16);
  .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } > ram

  . = ALIGN(16);
  .data : { *(.data .data.*) } > ram
  .sdata : {
    PROVIDE(__global_pointer$ = . + 0x800);
    *(.sdata .sdata.*)
  } > ram

  . = ALIGN(16);
  _bss_start = .;
  .sbss : { *(.sbss .sbss.*) } > ram
  .bss  : { *(.bss .bss.*) *(COMMON) } > ram
  . = ALIGN(16);
  _bss_end = .;

  /* 8 KiB of stack per hart, hart N at _stack_top - N*0x2000 */
  . = ALIGN(16);
  . = . + 0x4000;
  _stack_top = .;

  _end = .;
}
