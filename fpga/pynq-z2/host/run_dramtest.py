#!/usr/bin/env python3
"""Day-one PYNQ-Z2 bring-up: load the bitstream and prove the PL can reach PS DDR.

Run on the board, under PYNQ Linux:

    sudo python3 run_dramtest.py                    # 64 KB at 0x1000_0000
    sudo python3 run_dramtest.py --mb 16            # 16 MB
    sudo python3 run_dramtest.py --base 0x18000000  # a different region

What it checks, in order, so a failure localises itself:
  1. MAGIC reads back 0x5A5A0001   -> the bitstream is loaded and M_AXI_GP0 reaches the PL
  2. the test completes            -> the PL master got responses from S_AXI_HP0 at all
  3. ERRCNT == 0                   -> every byte written through HP0 to DDR read back

Step 1 failing means the PL is not loaded or GP0 is not routed. Step 2 hanging means HP0
never responded -- the classic symptom of the PS not having brought DDR up. Step 3 failing
means the path works but the data is wrong, which points at address mapping.

IMPORTANT: the region must not be memory Linux is using. 0x1000_0000 is the start of the
upper 256 MB; reserve it by booting with `mem=256M` on the kernel command line, or point
--base at a buffer you allocated with pynq.allocate() and pass its physical address.
"""
import argparse, mmap, os, struct, sys, time

from zynq_preflight import preflight

# Unbuffered: if a GP0 access hangs, the CPU locks and anything still sitting in a stdio
# buffer is lost. MEASURED: the first hang on this board produced an entirely empty log,
# which said nothing about which access wedged.
sys.stdout.reconfigure(line_buffering=True)

CTRL, BASE, NBURST, STATUS, ERRCNT, BEATS, MAGIC, RUNS = (
    0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C)
GP0_BASE = 0x4000_0000          # M_AXI_GP0 window on Zynq-7000
BYTES_PER_BURST = 64            # 8 beats x 64-bit
EXPECT_MAGIC = 0x5A5A_0001


class Regs:
    def __init__(self, phys=GP0_BASE, span=0x1000):
        self.f = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.m = mmap.mmap(self.f, span, offset=phys)

    def rd(self, off):
        return struct.unpack("<I", self.m[off:off + 4])[0]

    def wr(self, off, val):
        self.m[off:off + 4] = struct.pack("<I", val & 0xFFFFFFFF)

    def close(self):
        self.m.close(); os.close(self.f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bitstream", default="pynqz2_dramtest.bit")
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0x1000_0000)
    ap.add_argument("--mb", type=float, default=0.0625, help="region size in MiB")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--fclk", type=float, default=50.0, help="FCLK0 MHz; the design is timed at 50")
    ap.add_argument("--no-load", action="store_true", help="assume the bitstream is already loaded")
    a = ap.parse_args()

    if not a.no_load:
        try:
            # Bitstream, NOT Overlay. Overlay() needs a .hwh metadata file alongside the
            # .bit, and this design is built without an IPI block design so Vivado cannot
            # export one (write_hw_platform refuses: "No Hardware definition found as
            # there is no IPI block design"). Bitstream().download() just programs the PL,
            # which is all we need -- the registers are reached through /dev/mem below.
            from pynq import Bitstream
            Bitstream(os.path.abspath(a.bitstream)).download()
            print(f"loaded {a.bitstream}")
        except ImportError:
            sys.exit("pynq not available; load the .bit yourself and rerun with --no-load")

        # The FSBL programs FCLK0 from whatever the boot image was built for -- the stock
        # PYNQ image leaves it at 100 MHz. This design is TIMED at 50 MHz (clk_fpga_0,
        # 20.000 ns), so set it explicitly rather than inheriting the boot value.
        # It does also close timing at 100 MHz (worst path ~7.95 ns), but relying on that
        # is luck, not design.
        try:
            from pynq.ps import Clocks
            before = Clocks.fclk0_mhz
            Clocks.fclk0_mhz = a.fclk
            print(f"FCLK0: {before:.1f} MHz -> {Clocks.fclk0_mhz:.1f} MHz")
        except Exception as e:
            print(f"warning: could not set FCLK0 ({e}); design is timed for {a.fclk} MHz")

    preflight()

    r = Regs()
    print("reading MAGIC over M_AXI_GP0 ...")
    magic = r.rd(MAGIC)
    print(f"MAGIC = 0x{magic:08X}", "OK" if magic == EXPECT_MAGIC else "*** MISMATCH ***")
    if magic != EXPECT_MAGIC:
        r.close()
        sys.exit("PL not reachable over M_AXI_GP0 -- is the bitstream actually loaded?")

    nbursts = max(1, int(a.mb * 1024 * 1024 // BYTES_PER_BURST))
    total = nbursts * BYTES_PER_BURST
    print(f"region 0x{a.base:08X} .. 0x{a.base + total - 1:08X}  ({total/1024:.0f} KiB, {nbursts} bursts)")

    r.wr(BASE, a.base)
    r.wr(NBURST, nbursts)
    # Read back before starting: this confirms the writes landed in the registers they
    # were addressed to, and orders them ahead of the start pulse.
    got_base, got_n = r.rd(BASE), r.rd(NBURST)
    if (got_base, got_n) != (a.base, nbursts):
        r.close()
        sys.exit(f"register writes did not take: BASE=0x{got_base:08X} (want 0x{a.base:08X}), "
                 f"NBURST={got_n} (want {nbursts})")

    # STATUS.done stays set after a run, so polling it straight after start reads the
    # PREVIOUS run's result. RUNS increments once per completed run; wait for it to move.
    runs_before = r.rd(RUNS)
    r.wr(CTRL, 1)

    t0 = time.time()
    next_report = 1.0
    while True:
        st = r.rd(STATUS)
        if r.rd(RUNS) != runs_before:
            break
        if time.time() - t0 > next_report:
            print(f"  ... {time.time()-t0:5.1f}s  status=0x{st:X}  beats={r.rd(BEATS)}")
            next_report += 1.0
        if time.time() - t0 > a.timeout:
            beats, errs = r.rd(BEATS), r.rd(ERRCNT)   # read before closing the mapping
            r.close()
            sys.exit(f"TIMEOUT after {a.timeout}s (status=0x{st:X}, beats={beats}, "
                     f"errcnt={errs}, runs={runs_before}). "
                     "HP0 never completed -- check that the PS has DDR up.")
        time.sleep(0.0005)

    el = time.time() - t0
    errs, beats = r.rd(ERRCNT), r.rd(BEATS)
    expect_beats = nbursts * 16          # write pass + read pass, 8 beats per 64 B burst
    if beats != expect_beats:
        print(f"*** beats={beats}, expected {expect_beats} ***")
    # write pass + read pass, 8 bytes per beat
    mibps = (beats * 8) / el / (1024 * 1024) if el > 0 else 0
    print(f"done in {el*1000:.1f} ms   beats={beats}   throughput={mibps:.1f} MiB/s")
    print(f"ERRCNT = {errs}", "-> PASS" if errs == 0 else "-> FAIL")
    r.close()
    sys.exit(0 if errs == 0 else 1)


if __name__ == "__main__":
    main()
