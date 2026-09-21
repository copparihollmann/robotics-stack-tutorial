#!/usr/bin/env python3
"""
DOES NOT WORK AS A POWER TEST. KEPT AS A DOCUMENTED NEGATIVE RESULT.

This scan returns 0xFFFFFFFF on a PYNQ-Z1 that is powered, booted and running Linux --
confirmed on 2026-09-17 against a board whose shell prompt was on screen at the time.
The raw-MPSSE path on the Digilent FT2232's channel A does not reach the Zynq TAP, and no
ACBUS buffer-enable setting changes that (jtag_sweep.py tries all 49 and every one is
stuck high). The MPSSE bad-opcode probe answering 0xFA 0xAA proves only that the FTDI's
MPSSE ENGINE is alive -- not that the JTAG PATH reaches the chip. Conflating those two is
what produced a confident, wrong "the board is unpowered".

So: 0xFFFFFFFF from this tool means NOTHING. To check whether the board is alive, use the
console (host/ftdicon.py). Nothing in this repo programs the FPGA over JTAG anyway --
run_rocket.py uses pynq.Bitstream().download() from Linux on the board.

See fpga/pynq-z2/docs/BRINGUP_ILLIXR.md section 4.

Original (incorrect) intent follows.

Sweep ACBUS (high-byte) buffer-enable settings looking for a live JTAG chain.

Digilent onboard FT2232 JTAG routes TCK/TDI/TDO/TMS through buffers whose output
enable sits on ACBUS. With the wrong high-byte setting TDO reads stuck-high even on
a perfectly healthy board, so 0xFFFFFFFF alone does not mean 'unpowered'.
"""
import os, sys, time
if os.environ.get("PYFTDI_PATH"):
    sys.path.insert(0, os.environ["PYFTDI_PATH"])
import usb.core, usb.util
from pyftdi.ftdi import Ftdi

SER = "003017A8BE57"
d = usb.core.find(idVendor=0x0403, idProduct=0x6010)
if d is None or usb.util.get_string(d, d.iSerialNumber) != SER \
   or usb.util.get_string(d, d.iManufacturer) != "Digilent":
    sys.exit("REFUSING: not the Digilent board")
usb.util.dispose_resources(d)


def idcode(f, hi_val, hi_dir):
    f.write_data(bytes([
        0x8A, 0x97, 0x8D,
        0x86, 0x1D, 0x00,
        0x80, 0x08, 0x0B,          # ADBUS: TMS high, TCK/TDI low
        0x82, hi_val, hi_dir,      # ACBUS: the thing under test
        0x85,
    ]))
    time.sleep(0.03)
    f.purge_buffers()
    f.write_data(bytes([
        0x4B, 0x04, 0x1F,          # -> Test-Logic-Reset
        0x4B, 0x03, 0x02,          # -> Shift-DR
        0x39, 0x03, 0x00, 0, 0, 0, 0,
        0x87,
    ]))
    buf = bytearray(); t0 = time.time()
    while len(buf) < 4 and time.time() - t0 < 1.0:
        c = f.read_data(4 - len(buf))
        if c: buf += c
        else: time.sleep(0.01)
    if len(buf) != 4:
        return None
    return int.from_bytes(bytes(buf), "little")


f = Ftdi()
f.open_from_url("ftdi://ftdi:0x6010:%s/1" % SER)
hits = []
try:
    f.set_bitmode(0x00, Ftdi.BitMode.RESET)
    f.set_bitmode(0x0B, Ftdi.BitMode.MPSSE)
    time.sleep(0.05)

    cands = []
    for hi_dir in (0x00, 0x0F, 0x20, 0x30, 0x60, 0xF0, 0xFF):
        for hi_val in (0x00, 0x0F, 0x20, 0x30, 0x60, 0xF0, 0xFF):
            cands.append((hi_val, hi_dir))
    for hi_val, hi_dir in cands:
        v = idcode(f, hi_val, hi_dir)
        tag = ""
        if v is None:
            tag = "no data"
        elif v in (0x00000000, 0xFFFFFFFF):
            tag = "stuck"
        else:
            tag = "*** LIVE 0x%08X ***" % v
            hits.append((hi_val, hi_dir, v))
        print("ACBUS val=0x%02X dir=0x%02X -> %s" % (hi_val, hi_dir,
              tag if v is None or tag.startswith("***") else "0x%08X %s" % (v, tag)))

    # also read the idle pin levels, which says whether TDO is floating high
    f.write_data(bytes([0x81, 0x83, 0x87]))
    time.sleep(0.05)
    pins = f.read_data(2)
    print("\nidle pin levels: ADBUS=0x%02X ACBUS=0x%02X" %
          (pins[0], pins[1]) if len(pins) == 2 else "\nidle pins: %s" % pins.hex())
finally:
    f.set_bitmode(0x00, Ftdi.BitMode.RESET)
    f.close()

print("\nSUMMARY: %d live combination(s)" % len(hits))
for hv, hd, v in hits:
    print("  ACBUS val=0x%02X dir=0x%02X IDCODE=0x%08X" % (hv, hd, v))
