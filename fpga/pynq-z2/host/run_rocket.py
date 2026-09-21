#!/usr/bin/env python3
"""Bring up Rocket + TACIT on PYNQ-Z2: load bitstream, load a program, release reset.

    sudo python3 run_rocket.py --elf hello.bin           # raw binary image
    sudo python3 run_rocket.py --no-load --release       # just release reset

The SoC's ExtMem sits at 0x8000_0000 in Rocket's view. The FPGA top folds that into the
PS DDR window with {4'd1, addr[27:0]}, so Rocket's 0x8000_0000 IS physical 0x1000_0000
here -- that is where a program image must be written.

Rocket comes out of configuration HELD IN RESET on purpose, so the PS can place a program
in DDR before the core fetches anything. Release is SOC_CTRL bit 0.

RELEASING RESET IS NOT ENOUGH. The Chipyard bootrom's reset vector is `_hang`, which arms
MSIP and then parks the hart in `wfi_loop`. In simulation TSI pokes it awake; there is no
TSI in this config. What wakes it is the CUSTOM BOOT PIN (SOC_CTRL bit 1): asserting it
runs a small hardware FSM that writes BootAddrReg (0x1000) = 0x8000_0000 and then writes
hart 0's MSIP in the CLINT. The bootrom takes the interrupt, reads BootAddrReg and `mret`s
to 0x8000_0000. See testchipip/src/main/scala/boot/CustomBootPin.scala.

So the order is: hold reset -> write the image -> release reset -> pulse custom_boot.

Console: Rocket's UART is cross-connected in the PL to PS UART1 on EMIO, so its output is
/dev/ttyPS1 on this board. Read it with:  screen /dev/ttyPS1 115200
"""
import argparse, mmap, os, struct, sys, time

from zynq_preflight import preflight

# Unbuffered: a GP0 access that hangs takes the CPU with it, and anything still in a stdio
# buffer is lost -- leaving no record of which access wedged.
sys.stdout.reconfigure(line_buffering=True)

GP0_BASE   = 0x4000_0000          # M_AXI_GP0 window
CTRL, STATUS, MAGIC = 0x00, 0x04, 0x08
EXPECT_MAGIC = 0x5A5A_0002
# The FCLK0 this design is TIMED at, and therefore the one --fclk defaults to. A wrapper
# for a bitstream built at another clock overrides this alongside EXPECT_MAGIC, so that
# running the wrapper with no arguments cannot overclock or underclock the design --
# see run_rocket_pext.py.
DEFAULT_FCLK = 40.0
# Rocket's ExtMem base (0x8000_0000) folded into PS DDR by the top-level address fold.
SOC_MEM_PHYS = 0x1000_0000

# Bitstreams no run may load, by content.  The same list as bitstream_refused() in
# scripts/lib/bitstream_id.sh, repeated here for any loader path that never sources that file.
# Each has a row in fpga/pynq-z2/bwlab/errata.csv.
REFUSED_MD5 = {
    "0a3026ade7857ae3c6def89340e18c99":
        "0x5A5A001C bwwin f91, under diagnosis: 0 console bytes at 08:50 on 2026-09-17 (MEMORY_BANDWIDTH.md s9.7)",
    "f271cf9fb2d3df559707c2ee726591db":
        "0x5A5A0018 first build: build defective: 128-bit ExtMem into 64-bit HP0; 0 console bytes; no rows",
    "0d449ffd1b6b3d7696d43010cfb9574e":
        "0x5A5A0019 first build: build defective: 128-bit ExtMem into 64-bit HP0; never loaded; no rows",
    "275c728234a980f69689e22058b3470b":
        "0x5A5A0033 roccmoonnch8f40: COMPUTES ONE OUTPUT CHANNEL IN EIGHT AS ZERO. "
        "mbxr_engine.v:512 `wire [2:0] pport = pr[2:0] + 3'd1` truncates weight plane 7's port "
        "index (8) to 0, so that plane is never written and pbad cannot fire. Measured in "
        "Verilator on this bitstream's own sources: MBXR_TB_FAIL 109 of 119, every wrong output "
        "n %% 8 == 7. With the shipping MBXR_NCH=4 guest it only hangs; with a matched "
        "-DMBXR_NCH=8 guest it returns wrong bytes with every gate green (TODO.md, B98).",
    "52080a127204fc9ebe4fb89fd341510c":
        "B96 NCH=8: COMPUTES ATTENTION WRONG and reports MAGIC 0x5A5A0032 like the shipping build. "
        "mbxa_core is instantiated without NCH and acc is fixed at [127:0], so lanes 4-7 never reach "
        "the attention unit. Vivado logged Synth 8-689 at ERROR and still wrote it with BUILD_EXIT=0.",
}


def refuse_if_listed(path):
    import hashlib
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    why = REFUSED_MD5.get(h.hexdigest())
    if why:
        sys.exit(f"REFUSED: {path} md5 {h.hexdigest()} -- {why}")


class Regs:
    def __init__(self, phys=GP0_BASE, span=0x1000):
        self.f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.m = mmap.mmap(self.f, span, offset=phys)

    def rd(self, off):  return struct.unpack("<I", self.m[off:off+4])[0]
    def wr(self, off, v): self.m[off:off+4] = struct.pack("<I", v & 0xFFFFFFFF)
    def close(self): self.m.close(); os.close(self.f)


#: How much of the image is held in this process's memory at a time. See load_image().
LOAD_CHUNK = 4 << 20


def load_image(path, phys, span_hint=None, chunk=LOAD_CHUNK):
    """Write a raw image into PS DDR and read it back to prove it landed.

    No msync: the mapping is O_SYNC, so it is uncached device memory and the stores go
    straight to DDR. Calling mmap.flush() on it actually fails with EINVAL, because msync
    is not supported on a /dev/mem mapping.

    IN CHUNKS, AND THAT IS NOT A MICRO-OPTIMISATION.  This used to read the whole file into
    `data` and the whole readback into `got`, so peak RSS was 2x the image.  The board's
    Linux is capped at `mem=256M` (/proc/cmdline) with ~238 MB usable, so any image past
    ~100 MB killed the loader rather than the guest -- and Rocket's own DDR window is the
    OTHER 256 MB, which is not the memory that ran out.  Lab B57's decoder images carry a
    37.75 MB embedding table plus 577,152 B per baked utterance and reach ~206 MB, so the old
    loader could not have loaded one at all.  Peak RSS here is 2 x `chunk`, whatever the image.

    THE ORDER IS STILL WRITE-EVERYTHING-THEN-VERIFY-EVERYTHING, deliberately: interleaving
    the verify would not notice a later write that disturbed an earlier byte, and this check
    exists precisely because the DDR path has been wrong before.  The failure message is
    unchanged, including the absolute byte offset.
    """
    n = os.path.getsize(path)
    span = span_hint or ((n + 0xFFFF) & ~0xFFFF)
    f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(f, span, offset=phys)
    try:
        with open(path, "rb") as fh:
            off = 0
            while True:
                buf = fh.read(chunk)
                if not buf:
                    break
                m[off:off + len(buf)] = buf
                off += len(buf)
        if off != n:
            raise SystemExit(f"read {off} bytes of {path} but it is {n} bytes")
        with open(path, "rb") as fh:
            off = 0
            while True:
                buf = fh.read(chunk)
                if not buf:
                    break
                got = m[off:off + len(buf)]
                if got != buf:
                    bad = next(i for i in range(len(buf)) if got[i] != buf[i])
                    raise SystemExit(f"image did not land in DDR: first mismatch at byte "
                                     f"{off + bad} (wrote 0x{buf[bad]:02x}, "
                                     f"read 0x{got[bad]:02x})")
                off += len(buf)
    finally:
        m.close(); os.close(f)
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bitstream", default="pynqz2_rocket_tacit.bit")
    ap.add_argument("--elf", help="raw binary image to place at Rocket's ExtMem base")
    ap.add_argument("--fclk", type=float, default=DEFAULT_FCLK,
                    help=f"FCLK0 MHz; this design is TIMED at {DEFAULT_FCLK}")
    ap.add_argument("--no-load", action="store_true")
    ap.add_argument("--release", action="store_true", help="release reset and exit")
    ap.add_argument("--hold", action="store_true", help="put the SoC back into reset")
    a = ap.parse_args()

    if not a.no_load:
        refuse_if_listed(os.path.abspath(a.bitstream))
        from pynq import Bitstream
        Bitstream(os.path.abspath(a.bitstream)).download()
        print(f"loaded {a.bitstream}")
        try:
            from pynq.ps import Clocks
            before = Clocks.fclk0_mhz
            Clocks.fclk0_mhz = a.fclk
            print(f"FCLK0: {before:.4f} -> {Clocks.fclk0_mhz:.4f} MHz "
                  f"(asked for {a.fclk})")
        except Exception as e:
            print(f"warning: could not set FCLK0 ({e}); design is timed for {a.fclk} MHz")

    preflight()

    r = Regs()
    print("reading MAGIC over M_AXI_GP0 ...")
    magic = r.rd(MAGIC)
    print(f"MAGIC = 0x{magic:08X}", "OK" if magic == EXPECT_MAGIC else "*** MISMATCH ***")
    if magic != EXPECT_MAGIC:
        r.close(); sys.exit("PL not reachable, or this is not the Rocket bitstream")

    if a.hold:
        r.wr(CTRL, 0); print("SoC held in reset"); r.close(); return

    # Always start from a known state: back into reset before touching DDR, so a running
    # core cannot be fetching from the region about to be overwritten.
    r.wr(CTRL, 0)
    time.sleep(0.01)

    if a.elf:
        n = load_image(a.elf, SOC_MEM_PHYS)
        print(f"wrote {n} bytes to phys 0x{SOC_MEM_PHYS:08X} "
              f"(Rocket sees this as 0x8000_0000)")

    if a.elf or a.release:
        def show(tag):
            st = r.rd(STATUS)
            print(f"  {tag:22s} STATUS = 0x{st:08X}  "
                  f"resetn={int(bool(st & 2))} saw_mem={int(bool(st & 4))} "
                  f"burst_err={int(bool(st & 8))}")
            return st

        show("before release")
        r.wr(CTRL, 0b01)                  # bit 0 = soc_resetn: out of reset
        time.sleep(0.02)
        show("reset released")

        # Pulse the custom boot pin. The FSM latches on the rising edge, does its two
        # writes, then parks in a `dead` state until the pin drops -- so dropping it again
        # leaves it armed for the next run rather than requiring a bitstream reload.
        r.wr(CTRL, 0b11)
        time.sleep(0.05)
        st = show("custom_boot asserted")
        r.wr(CTRL, 0b01)
        time.sleep(0.02)
        st = show("custom_boot released")

        if st & 8:
            print("*** AXI3 burst-length error: the SoC issued a burst longer than 16 "
                  "beats. Memory may be corrupt. See src/axi4_to_axi3.v ***")
        if not (st & 4):
            print("*** saw_mem is still 0: the SoC has not fetched anything from DDR. "
                  "The hart is probably still parked in the bootrom's wfi_loop. ***")
        print("console: screen /dev/ttyPS1 115200   (or host/console.py)")
    r.close()


if __name__ == "__main__":
    main()
