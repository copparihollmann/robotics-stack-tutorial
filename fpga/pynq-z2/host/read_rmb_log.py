#!/usr/bin/env python3
"""Read a text log a Rocket program keeps in DRAM, from the PS side, over /dev/mem.

    sudo python3 read_rmb_log.py --clear                 # zero the header before a run
    sudo python3 read_rmb_log.py --wait-idle 60 > log    # wait for done, print the text

The log lives at Rocket 0x87F0_0000 = PS physical 0x17F0_0000 (the FPGA top folds Rocket's
DRAM window into the PS's upper 256 MB): a 32-byte header {magic "RMBLOG01", length, done,
pad} followed by the text.  samples/roccmoon_bench writes every RMB_ line there as well as to
the UART, so a lab still has its result when the console returns nothing.

--clear zeroes the header, so a log left behind by an earlier run cannot be read as this
one's.  --wait-idle N returns when `done` is set, or when the length has not changed for N
seconds, or after --max seconds; the header is printed to stderr.
"""
import argparse
import mmap
import os
import struct
import sys
import time

PHYS = 0x17F00000
SPAN = 1 << 20


def _map(write):
    fd = os.open("/dev/mem", (os.O_RDWR if write else os.O_RDONLY) | os.O_SYNC)
    prot = mmap.PROT_READ | (mmap.PROT_WRITE if write else 0)
    return fd, mmap.mmap(fd, SPAN, mmap.MAP_SHARED, prot, offset=PHYS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clear", action="store_true")
    ap.add_argument("--wait-idle", type=float, default=0.0)
    ap.add_argument("--max", type=float, default=3600.0)
    a = ap.parse_args()
    if a.clear:
        fd, m = _map(True)
        m[0:32] = bytes(32)
        m.close()
        os.close(fd)
        return
    t0 = time.time()
    last, still_since = None, time.time()
    while True:
        fd, m = _map(False)
        magic, ln, done, _ = struct.unpack("<8sQQQ", m[0:32])
        text = bytes(m[32:32 + min(ln, SPAN - 32)])
        m.close()
        os.close(fd)
        if magic == b"RMBLOG01" and done:
            break
        if ln != last:
            last, still_since = ln, time.time()
        if a.wait_idle <= 0 or time.time() - still_since >= a.wait_idle or time.time() - t0 >= a.max:
            break
        time.sleep(2)
    sys.stdout.write(text.decode("utf-8", "replace"))
    sys.stderr.write("dram log: magic=%r len=%d done=%d after %.0f s\n" % (magic, ln, done, time.time() - t0))


if __name__ == "__main__":
    main()
