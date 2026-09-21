#!/usr/bin/env python3
"""
Console for the PYNQ-Z1's FT2232 over libusb/usbfs, for hosts where the user is
not in `dialout` but the Digilent udev rule (MODE:="666") applies.

Only ever touches the Digilent device by serial number; never the U250's FT4232H.

  ftdicon.py probe                     -- open, read, report what arrives
  ftdicon.py read  [secs]              -- passive read
  ftdicon.py send  "cmd" [wait_secs]   -- send a line, read the reply
  ftdicon.py expect "cmd" "pat" [secs] -- send, read until regex matches
"""
import os, re, sys, time

SERIAL = os.environ.get("FTDI_SERIAL", "003017A8BE57")
IFACE  = int(os.environ.get("FTDI_IFACE", "2"))
BAUD   = int(os.environ.get("FTDI_BAUD", "115200"))
URL    = "ftdi://ftdi:0x6010:%s/%d" % (SERIAL, IFACE)

from pyftdi.ftdi import Ftdi

# --- hard guard: this tool must never claim anything but the board's Digilent FT2232 ---
ALLOWED_VID, ALLOWED_PID, ALLOWED_SERIAL = 0x0403, 0x6010, "003017A8BE57"
FORBIDDEN = {"213207334008"}   # the U250's FT4232H on ttyUSB1-3. Never touch.

def _guard():
    import usb.core, usb.util
    if SERIAL in FORBIDDEN:
        sys.exit("REFUSING: serial %s is the U250, not our board" % SERIAL)
    if SERIAL != ALLOWED_SERIAL:
        sys.exit("REFUSING: serial %s is not the Digilent board (%s)" % (SERIAL, ALLOWED_SERIAL))
    d = usb.core.find(idVendor=ALLOWED_VID, idProduct=ALLOWED_PID)
    if d is None:
        sys.exit("REFUSING: no %04x:%04x present" % (ALLOWED_VID, ALLOWED_PID))
    ser = usb.util.get_string(d, d.iSerialNumber)
    mfg = usb.util.get_string(d, d.iManufacturer)
    if ser != ALLOWED_SERIAL or mfg != "Digilent":
        sys.exit("REFUSING: %04x:%04x is mfg=%r serial=%r, not the Digilent board"
                 % (ALLOWED_VID, ALLOWED_PID, mfg, ser))
    return d


def reattach():
    """Give ttyUSB0/ttyUSB4 back to ftdi_sio."""
    import usb.core, usb.util
    d = _guard()
    done = []
    for i in (0, 1):
        try:
            if not d.is_kernel_driver_active(i):
                d.attach_kernel_driver(i)
                done.append(i)
        except Exception as e:
            print("  iface %d: %s" % (i, e))
    usb.util.dispose_resources(d)
    print("re-attached ftdi_sio on interfaces %s" % (done or "none needed"))


def open_port():
    _guard()
    f = Ftdi()
    f.open_from_url(URL)
    f.set_line_property(8, 1, 'N')
    f.set_baudrate(BAUD)
    f.set_flowctrl('')
    f.purge_buffers()
    return f


def drain(f, secs, quiet_stop=None):
    """Read for `secs`; if quiet_stop set, return early after that many idle secs."""
    buf = bytearray()
    t0 = time.time()
    last = t0
    while time.time() - t0 < secs:
        chunk = f.read_data(4096)
        if chunk:
            buf += chunk
            last = time.time()
        else:
            if quiet_stop and buf and (time.time() - last) > quiet_stop:
                break
            time.sleep(0.02)
    return bytes(buf)


def show(b, label):
    print("--- %s: %d bytes ---" % (label, len(b)))
    if not b:
        print("(nothing)")
        return
    sys.stdout.write(b.decode('utf-8', 'replace'))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "probe"
    if cmd == "reattach":
        reattach(); return
    f = open_port()
    try:
        if cmd == "probe":
            print("opened %s at %d 8N1" % (URL, BAUD))
            show(drain(f, 3.0), "passive 3s")
            f.write_data(b"\r\n")
            show(drain(f, 3.0), "after CR-LF")
        elif cmd == "read":
            secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0
            show(drain(f, secs), "read %.1fs" % secs)
        elif cmd == "send":
            line = sys.argv[2]
            secs = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
            f.purge_buffers()
            f.write_data(line.encode() + b"\r")
            show(drain(f, secs), "reply")
        elif cmd == "expect":
            line, pat = sys.argv[2], sys.argv[3]
            secs = float(sys.argv[4]) if len(sys.argv) > 4 else 20.0
            f.purge_buffers()
            if line:
                f.write_data(line.encode() + b"\r")
            buf = bytearray(); t0 = time.time(); rx = re.compile(pat)
            while time.time() - t0 < secs:
                c = f.read_data(4096)
                if c:
                    buf += c
                    if rx.search(buf.decode('utf-8', 'replace')):
                        break
                else:
                    time.sleep(0.02)
            show(bytes(buf), "expect %r" % pat)
            sys.exit(0 if rx.search(bytes(buf).decode('utf-8', 'replace')) else 3)
        else:
            print("unknown: %s" % cmd); sys.exit(2)
    finally:
        f.close()


if __name__ == "__main__":
    main()
