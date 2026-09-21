#!/usr/bin/env python3
"""Read what the PL is driving at the six RGB LED pins, from the ARM, over M_AXI_GP0.

    sudo python3 read_rgb_status.py            one sample
    sudo python3 read_rgb_status.py --watch 12 --interval 0.25

WHY THIS EXISTS.

An output pin has no readback. Nothing on this board can tell you that LD4 went red. What
it CAN do is observe the same six signals from somewhere other than the guest that wrote
them -- which is worth more than it sounds, because the failure this whole exercise is
guarding against is a bit vector getting permuted or dropped somewhere between Zephyr and
the package balls, and nobody involved can see the board.

So the FPGA top puts `rgb_oval & rgb_oe` -- the six signals on their way to the OBUFs,
before the brightness chopper -- into STATUS bits [9:4] at GP0 offset 0x04. Rocket writes
output_value over TileLink; the ARM reads it back here over a different bus, as a different
master, with no cooperation from the guest at all. Two independent observers of the same
wires.

WHAT IT STILL DOES NOT PROVE: which package ball each of those six wires reaches, or what
colour comes out. The ball is asserted against the ROUTED design at build time
(tcl/build_rocket.tcl, `RGB_PIN:` lines); the colour is the eye's job. See
fpga/pynq-z2/docs/RGB_LEDS.md section 6.

Bit order, low to high, is the vendor's -- LD4{B,G,R} then LD5{B,G,R}. It is the same
order as the GPIO controller's pins and as `rgb_led[5:0]`.
"""
import argparse
import mmap
import os
import struct
import sys
import time

sys.stdout.reconfigure(line_buffering=True)

GP0_BASE = 0x4000_0000
STATUS, MAGIC = 0x04, 0x08
EXPECT_MAGIC = 0x5A5A_0006

# Low bit first. Matches src/pynqz2_rgb.xdc and the board's gpio-leds node.
NAMES = ["LD4.blue", "LD4.green", "LD4.red", "LD5.blue", "LD5.green", "LD5.red"]
BALLS = ["L15", "G17", "N15", "G14", "L14", "M15"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", type=float, default=0.0,
                    help="sample for this many seconds instead of once")
    ap.add_argument("--interval", type=float, default=0.25)
    ap.add_argument("--no-magic-check", action="store_true")
    a = ap.parse_args()

    f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, 0x1000, offset=GP0_BASE)

    def rd(off):
        return struct.unpack("<I", m[off:off + 4])[0]

    magic = rd(MAGIC)
    print(f"MAGIC = 0x{magic:08X}", "OK" if magic == EXPECT_MAGIC else "*** MISMATCH ***")
    if magic != EXPECT_MAGIC and not a.no_magic_check:
        m.close(); os.close(f)
        sys.exit("this is not the RGB bitstream -- STATUS[9:4] means nothing here")

    def sample():
        st = rd(STATUS)
        rgb = (st >> 4) & 0x3F
        lit = ",".join(NAMES[i] for i in range(6) if rgb & (1 << i)) or "-none-"
        # Printed MSB-first so it reads like the guest's own console line.
        bits = "".join("1" if rgb & (1 << (5 - i)) else "0" for i in range(6))
        return st, rgb, bits, lit

    if a.watch > 0.0:
        t_end = time.time() + a.watch
        seen = {}
        n = 0
        while time.time() < t_end:
            st, rgb, bits, lit = sample()
            seen[rgb] = seen.get(rgb, 0) + 1
            n += 1
            print(f"RGB_STATUS t={time.time():.3f} status=0x{st:08X} rgb=0b{bits} {lit}")
            time.sleep(a.interval)
        print(f"RGB_STATUS_SAMPLES {n}")
        print("RGB_STATUS_DISTINCT " +
              " ".join(f"0b{v:06b}x{c}" for v, c in sorted(seen.items())))
    else:
        st, rgb, bits, lit = sample()
        print(f"RGB_STATUS status=0x{st:08X} rgb=0b{bits} value={rgb} lit={lit}")
        print("RGB_STATUS_MAP " +
              " ".join(f"bit{i}={NAMES[i]}@{BALLS[i]}" for i in range(6)))

    m.close(); os.close(f)


if __name__ == "__main__":
    main()
