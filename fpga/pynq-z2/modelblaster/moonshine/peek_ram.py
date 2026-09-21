#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read Rocket's RAM from the Zynq PS while a guest runs -- evidence that does not depend on
the UART.  Runs ON THE BOARD (as root, for /dev/mem).

Rocket's ExtMem base 0x8000_0000 is physical 0x1000_0000 on the PS side (ROCKET.md), so a
guest symbol at address A is at 0x1000_0000 + (A - 0x8000_0000).  scripts/50 resolves the
symbols from the image's ELF on the host and passes them here:

    sudo python3 peek_ram.py TAG name:hexaddr:size:kind ...

    kind   u8     one byte                     (z_sys_post_kernel: kernel init finished)
           u64    one 64-bit word              (riscv_cpu_wake_flag / riscv_cpu_boot_flag)
           nz     count of non-zero bytes      (an activation buffer: has that dispatch run?)
           big    samples/modelblaster_pext's `big` struct head: ran, cpu_id, warm, cyc[0]
           recs   `records_`: the cycles field of every model_op_record_t (40 bytes each)

Prints one JSON object per call.  Read-only; safe while the guest runs.

STALENESS.  This reads DRAM, behind Rocket's own caches: a line the guest wrote recently can
still be dirty in its L1/L2 and read here as its old value.  Seen on 0x5A5A0010: ctrl_ffn's
cyc[0] read 0 ten seconds after the console had printed median=100021651.  A non-zero value
is evidence that it was written; a zero is not evidence that it was not.
"""
import json
import mmap
import os
import struct
import sys
import time

PHYS, BASE = 0x10000000, 0x80000000


def main():
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    out = {"tag": sys.argv[1], "board_time": time.time()}
    for spec in sys.argv[2:]:
        name, addr, size, kind = spec.split(":")
        addr, size = int(addr, 16), int(size)
        phys = PHYS + (addr - BASE)
        page = phys & ~0xFFF
        m = mmap.mmap(fd, (phys - page) + size, mmap.MAP_SHARED, mmap.PROT_READ, offset=page)
        b = m[phys - page:phys - page + size]
        m.close()
        if kind == "u8":
            out[name] = b[0]
        elif kind == "u64":
            out[name] = struct.unpack("<Q", b[:8])[0]
        elif kind == "u32":
            out[name] = struct.unpack("<I", b[:4])[0]
        elif kind == "nz":
            out[name] = sum(1 for x in b if x)
        elif kind == "big":
            out[name] = {"ran": b[0], "cpu_id": struct.unpack("<I", b[4:8])[0],
                         "warm_cycles": struct.unpack("<Q", b[16:24])[0],
                         "cyc0": struct.unpack("<Q", b[24:32])[0]}
        elif kind == "recs":
            out[name] = [struct.unpack("<Q", b[i + 32:i + 40])[0] for i in range(0, size - 39, 40)]
    os.close(fd)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
