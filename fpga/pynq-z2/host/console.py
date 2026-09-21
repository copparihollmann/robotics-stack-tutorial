#!/usr/bin/env python3
"""Read Rocket's console off /dev/ttyPS1.

Rocket's SiFive UART is cross-connected in the PL to PS UART1 on EMIO, so the SoC's
console arrives on the Linux side as a normal tty. Run this on the board:

    ./console.py                 # read until idle
    ./console.py --seconds 30    # read for a fixed time
    ./console.py --hex           # also dump raw bytes
    ./console.py --stamps F      # ... and write "<t> <line>" to F, host clock

--stamps exists so a guest can be timed against something that is not its own clock.
Everything a guest reports about its own frequency is circular -- k_busy_wait counts the
same mtime ticks that CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC defines -- so the only
independent check is how long a self-declared interval actually took out here. It writes a
SEPARATE file and leaves stdout byte-for-byte unchanged, because stdout is what the golden
console checks compare.

Uses termios rather than pyserial so it has no dependencies beyond stock Python.

If output is garbled rather than absent, the baud divisor is wrong: the SiFive UART takes
its divisor from CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * CONFIG_RTC_CLOCK_DIVIDER_VALUE, which
must equal the real PL clock -- 40 MHz for the single-core and dual-core bitstreams,
34.4828 MHz for the P-ext one. Silence instead means the core never started -- check
saw_mem in run_rocket.py's STATUS output.
"""
import argparse, os, sys, termios, time, tty


def open_tty(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    speed = getattr(termios, f"B{baud}")
    iflag = 0                                   # no translation, no flow control
    oflag = 0
    lflag = 0                                   # raw: no echo, no canonical mode
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW,
                      [iflag, oflag, cflag, lflag, speed, speed, cc])
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/ttyPS1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=0.0,
                    help="read for this long; 0 means stop after --idle of silence")
    ap.add_argument("--idle", type=float, default=3.0)
    ap.add_argument("--hex", action="store_true", help="also print a hex dump")
    ap.add_argument("--stamps", help="write '<seconds> <line>' per line to this file, "
                                     "timed on the HOST clock; stdout is unaffected")
    a = ap.parse_args()

    fd = open_tty(a.dev, a.baud)
    buf = bytearray()
    t0 = last = time.time()
    stamps = open(a.stamps, "w", buffering=1) if a.stamps else None
    line = bytearray()
    line_t0 = t0
    try:
        while True:
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                chunk = b""
            if chunk:
                buf += chunk
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()
                last = time.time()
                if stamps is not None:
                    # Stamp each line with the arrival time of its FIRST byte: the last
                    # byte's time would fold the line's own 115200-baud transmission into
                    # the measurement.
                    for byte in chunk:
                        if not line:
                            line_t0 = time.time()
                        if byte == 0x0a:
                            stamps.write("%.4f %s\n" % (
                                line_t0 - t0,
                                line.decode("utf-8", "replace").rstrip("\r")))
                            line = bytearray()
                        else:
                            line.append(byte)
            else:
                time.sleep(0.01)
            now = time.time()
            if a.seconds and now - t0 >= a.seconds:
                break
            if not a.seconds and buf and now - last >= a.idle:
                break
            if not a.seconds and not buf and now - t0 >= a.idle * 3:
                break
    finally:
        os.close(fd)
        if stamps is not None:
            if line:
                stamps.write("%.4f %s\n" % (line_t0 - t0,
                                             line.decode("utf-8", "replace").rstrip("\r")))
            stamps.close()

    print(f"\n--- {len(buf)} bytes in {time.time()-t0:.1f}s ---", file=sys.stderr)
    if a.hex and buf:
        for i in range(0, min(len(buf), 512), 16):
            row = buf[i:i+16]
            print(f"  {i:04x}  {row.hex(' '):<47}  "
                  f"{''.join(chr(c) if 32 <= c < 127 else '.' for c in row)}",
                  file=sys.stderr)
    return 0 if buf else 1


if __name__ == "__main__":
    sys.exit(main())
