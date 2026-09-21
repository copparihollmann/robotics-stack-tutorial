#!/usr/bin/env python3
"""Dump a physical memory range to a file, from the PS side, over /dev/mem.

    sudo python3 read_mem.py --phys 0x18000000 --bytes 262144 --out tacit.out

This is how the TACIT trace gets off the board. The DMA sink writes it into the SoC's
DRAM window at Rocket's 0x8000_0000+, and the FPGA top folds that window into PS physical
0x1000_0000+ ({4'd1, addr[27:0]}), so a buffer Rocket sees at 0x8800_0000 is PS physical
0x1800_0000.

Only DRAM is read here. The TACIT MMIO registers at 0x0300_0000 / 0x0301_0000 live in
*Rocket's* address space and are NOT reachable from Linux: M_AXI_GP0 reaches only
soc_ctrl_regs at 0x4000_0000, and the Zynq GP ports have no bus timeout, so poking at an
unbacked PL address locks the CPU until the watchdog fires. Configure the encoder and the
sink from code running on Rocket instead.

mmap() offsets must be page aligned, so the mapping is rounded down and the requested
range sliced out of it.
"""
import argparse
import mmap
import os
import sys

PAGE = mmap.PAGESIZE


def read_phys(phys: int, nbytes: int) -> bytes:
    base = phys & ~(PAGE - 1)
    skew = phys - base
    span = (skew + nbytes + PAGE - 1) & ~(PAGE - 1)
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    try:
        m = mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
        try:
            return bytes(m[skew:skew + nbytes])
        finally:
            m.close()
    finally:
        os.close(fd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phys", required=True, help="physical address, e.g. 0x18000000")
    ap.add_argument("--bytes", required=True, help="how many bytes to read")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    phys = int(a.phys, 0)
    n = int(a.bytes, 0)
    if n <= 0:
        sys.exit(f"nothing to read: --bytes {a.bytes}")

    data = read_phys(phys, n)
    with open(a.out, "wb") as f:
        f.write(data)
    nz = sum(1 for b in data if b)
    print(f"read {len(data)} bytes from phys 0x{phys:08X} -> {a.out} "
          f"({nz} nonzero, first 16 = {data[:16].hex(' ')})")


if __name__ == "__main__":
    main()
