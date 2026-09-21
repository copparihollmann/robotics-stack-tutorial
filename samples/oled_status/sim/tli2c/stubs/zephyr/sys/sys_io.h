/* SPDX-License-Identifier: Apache-2.0 */
/* Host stub: MMIO goes to the Verilator testbench, one TileLink-UL transaction per access. */
#pragma once
#include <stdint.h>
typedef uintptr_t mem_addr_t;
uint8_t sys_read8(mem_addr_t addr);
void sys_write8(uint8_t data, mem_addr_t addr);
