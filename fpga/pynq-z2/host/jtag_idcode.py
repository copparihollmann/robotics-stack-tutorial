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

Read the JTAG IDCODE off the PYNQ-Z1's Zynq over the Digilent FT2232 channel A (MPSSE).

Decides one thing remotely that nothing else can: is the chip powered and clocking?
  0x?3727093  -> xc7z020 present and alive
  0x00000000  -> TDO stuck low   (chip unpowered / not driving)
  0xFFFFFFFF  -> TDO stuck high  (nothing on the chain)

Only ever opens vid:pid 0403:6010 serial 003017A8BE57 (Digilent). Never the U250.
"""
import os, sys, time
if os.environ.get("PYFTDI_PATH"):
    sys.path.insert(0, os.environ["PYFTDI_PATH"])
import usb.core, usb.util
from pyftdi.ftdi import Ftdi

SER = "003017A8BE57"
d = usb.core.find(idVendor=0x0403, idProduct=0x6010)
if d is None:
    sys.exit("no 0403:6010 present")
if usb.util.get_string(d, d.iSerialNumber) != SER or usb.util.get_string(d, d.iManufacturer) != "Digilent":
    sys.exit("REFUSING: 0403:6010 is not the Digilent board")
usb.util.dispose_resources(d)

f = Ftdi()
f.open_from_url("ftdi://ftdi:0x6010:%s/1" % SER)          # channel A = JTAG
try:
    f.set_bitmode(0x00, Ftdi.BitMode.RESET)
    f.set_bitmode(0x0B, Ftdi.BitMode.MPSSE)                # ADBUS0 TCK,1 TDI,3 TMS out; 2 TDO in
    time.sleep(0.05)
    f.purge_buffers()

    setup = bytes([
        0x8A,              # disable /5 prescaler  -> 60 MHz base
        0x97,              # disable adaptive clocking
        0x8D,              # disable 3-phase clocking
        0x86, 0x1D, 0x00,  # divisor 29 -> 1 MHz TCK
        0x80, 0x08, 0x0B,  # low byte: TMS=1, TCK=0, TDI=0; dir 0b1011
        0x85,              # disable loopback
    ])
    f.write_data(setup)
    time.sleep(0.05)

    # MPSSE sanity: 0xAA is a bogus opcode; a live MPSSE answers 0xFA 0xAA.
    f.purge_buffers()
    f.write_data(bytes([0xAA]))
    time.sleep(0.1)
    echo = f.read_data(8)
    print("MPSSE bad-opcode echo: %s  (expect fa aa if MPSSE is alive)" % echo.hex(" "))

    seq = bytes([
        0x4B, 0x04, 0x1F,        # 5 x TMS=1  -> Test-Logic-Reset (IDCODE loads into DR)
        0x4B, 0x03, 0x02,        # TMS 0,1,0,0 -> Run-Test/Idle, Select-DR, Capture-DR, Shift-DR
        0x39, 0x03, 0x00,        # clock 4 bytes in+out, LSB first, out -ve / in +ve
        0x00, 0x00, 0x00, 0x00,
        0x87,                    # flush
    ])
    f.purge_buffers()
    f.write_data(seq)

    buf = bytearray()
    t0 = time.time()
    while len(buf) < 4 and time.time() - t0 < 2.0:
        c = f.read_data(4 - len(buf))
        if c: buf += c
        else: time.sleep(0.01)

    print("raw TDO bytes: %s" % (bytes(buf).hex(" ") or "(none)"))
    if len(buf) == 4:
        idcode = int.from_bytes(bytes(buf), "little")
        print("IDCODE = 0x%08X" % idcode)
        if idcode in (0x00000000, 0xFFFFFFFF):
            print("VERDICT: TDO stuck -> chip not powered or not on the chain")
        else:
            ver = (idcode >> 28) & 0xF
            part = (idcode >> 12) & 0xFFFF
            mfg = (idcode >> 1) & 0x7FF
            print("  version=0x%X part=0x%04X mfg=0x%03X" % (ver, part, mfg))
            if (idcode & 0x0FFFFFFF) == 0x03727093:
                print("VERDICT: xc7z020 (PYNQ-Z1/Z2 Zynq) PRESENT AND POWERED")
            else:
                print("VERDICT: a device is alive on the chain, but not the xc7z020 IDCODE 0x03727093")
    else:
        print("VERDICT: no TDO data returned")
finally:
    f.set_bitmode(0x00, Ftdi.BitMode.RESET)
    f.close()
    print("(channel A returned to RESET)")
