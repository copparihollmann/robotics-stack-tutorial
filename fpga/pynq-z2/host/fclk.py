#!/usr/bin/env python3
"""Read the Zynq PS fabric clocks back from the SLCR, and optionally refuse to proceed.

    sudo python3 fclk.py                         # print IO PLL + FCLK0..3 as JSON
    sudo python3 fclk.py --expect FCLK1=100      # exit 3 unless FCLK1 is within tolerance

WHY THIS EXISTS. A lab can verify it loaded the right bitstream -- MAGIC names the config,
md5 names the build (scripts/lib/bitstream_id.sh) -- and still measure the wrong machine,
because the PS clocks are not part of the bitstream. Nothing in this repo set FCLK1..3,
and they keep whatever the PYNQ boot image's FSBL programmed. On the bench board that is
FCLK1 = 142.8571 MHz (FPGA1_CLK_CTRL = 0x00100700, divisors 7/1), FCLK2 = 200, FCLK3 = 100.

Lever 2 (bitstream 0x5A5A0008, md5 f507f18f...) put the memory domain on FCLK1 and was
timed at 10.000 ns -- and every one of its runs logged `fclk_mem_mhz = 100`, which was the
design's intent, not a reading. The memory domain actually ran at 142.8571 MHz, ~33 % past
its timing closure. The checksums held and the null result survives, but the logged
condition was wrong for 21 rows and nothing could have caught it.

So: a clock a measurement depends on is a measured value, read here, recorded next to the
numbers it produced -- never the value somebody meant to set. Setting still goes through
pynq.ps.Clocks as run_dramtest.py does for FCLK0; this only reads, so it is safe to call
from anywhere, at any time, including while a design is running.

Register layout (UG585, SLCR at 0xF800_0000):
  IO_PLL_CTRL     0x108  [18:12] FDIV       IO PLL = PS_CLK (50 MHz on PYNQ-Z1) x FDIV
  FPGAn_CLK_CTRL  0x170 / 0x180 / 0x190 / 0x1A0
                         [25:20] DIVISOR1, [13:8] DIVISOR0, [5:4] SRCSEL (0/1 = IO PLL)
"""
import argparse
import json
import mmap
import os
import struct
import sys

SLCR_BASE = 0xF8000000
PS_CLK_MHZ = 50.0            # PYNQ-Z1 crystal; BOARD_FINDINGS.md records the 33.33 MHz mistake
IO_PLL_CTRL = 0x108
FPGA_CLK_CTRL = {0: 0x170, 1: 0x180, 2: 0x190, 3: 0x1A0}
SRC_NAME = {0: "IO_PLL", 1: "IO_PLL", 2: "ARM_PLL", 3: "DDR_PLL"}


def read_fclks():
    """Return the IO PLL and FCLK0..3 as read from the SLCR right now."""
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    try:
        m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=SLCR_BASE)
        rd = lambda off: struct.unpack("<I", m[off:off + 4])[0]
        io = rd(IO_PLL_CTRL)
        fdiv = (io >> 12) & 0x7F
        io_pll_mhz = PS_CLK_MHZ * fdiv
        out = {"io_pll_ctrl": f"0x{io:08X}", "io_pll_mhz": io_pll_mhz}
        for n, off in FPGA_CLK_CTRL.items():
            v = rd(off)
            d0, d1, src = (v >> 8) & 0x3F, (v >> 20) & 0x3F, (v >> 4) & 0x3
            # Only the IO PLL source is decoded; the others are not used on this board and
            # guessing their frequency would be exactly the kind of number this file exists
            # to stop anyone writing down.
            mhz = io_pll_mhz / (d0 * d1) if (d0 and d1 and src in (0, 1)) else None
            out[f"fclk{n}"] = {"ctrl": f"0x{v:08X}", "divisor0": d0, "divisor1": d1,
                               "src": SRC_NAME[src],
                               "mhz": round(mhz, 4) if mhz is not None else None}
        m.close()
        return out
    finally:
        os.close(fd)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--expect", action="append", default=[], metavar="FCLKn=MHZ",
                    help="refuse (exit 3) unless FCLKn is within --tol of MHZ; repeatable")
    ap.add_argument("--tol", type=float, default=0.5,
                    help="tolerance in percent (default 0.5)")
    a = ap.parse_args()

    clocks = read_fclks()
    print(json.dumps(clocks, indent=1))

    bad = []
    for spec in a.expect:
        try:
            name, want = spec.split("=")
            n = int(name.upper().replace("FCLK", ""))
            want = float(want)
        except ValueError:
            print(f"bad --expect '{spec}' (want e.g. FCLK1=100)", file=sys.stderr)
            return 2
        got = clocks[f"fclk{n}"]["mhz"]
        if got is None or abs(got - want) > want * a.tol / 100.0:
            bad.append((n, want, got, clocks[f"fclk{n}"]["ctrl"]))

    for n, want, got, ctrl in bad:
        print(f"FCLK{n} is {got} MHz (FPGA{n}_CLK_CTRL {ctrl}), expected {want} MHz. "
              f"The bitstream is not running at the clock it was built for, so any "
              f"measurement taken now describes a different machine. Set it through "
              f"pynq.ps.Clocks.fclk{n}_mhz and re-check before measuring.", file=sys.stderr)
    return 3 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
