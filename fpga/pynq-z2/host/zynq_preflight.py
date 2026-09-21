"""PS-side sanity checks before the first M_AXI_GP0 access.

Shared by run_dramtest.py and run_rocket.py. Everything checked here lives inside the PS,
so none of it can hang -- which is the whole point, because the Zynq GP ports have NO bus
timeout. A read to 0x4000_0000 when the PL is unprogrammed, unclocked or held in reset
never returns a response and the CPU locks hard: no console, no SSH, no panic. Recovery is
the watchdog (if armed) or pulling power.
"""
import mmap, os, struct, sys

SLCR                = 0xF800_0000
SLCR_FPGA0_CLK_CTRL = 0x0170     # [25:20] divisor1, [13:8] divisor0, [5:4] srcsel
SLCR_FPGA_RST_CTRL  = 0x0240     # [0] FCLK_RESET0_N asserted when 1
SLCR_PLL_ARM        = 0x0100
SLCR_PLL_IO         = 0x0108
SLCR_PLL_DDR        = 0x0104
# PS_CLK crystal frequency, board-specific (PCW_CRYSTAL_PERIPHERAL_FREQMHZ).
# 50 MHz on PYNQ-Z1/Z2; many other Zynq boards use 33.333 MHz.
PS_CLK_MHZ          = 50.0


def preflight():
    """Check, using PS-internal registers only, that a GP0 access can complete.

    This matters because the Zynq GP ports have no bus timeout. If the PL is unprogrammed,
    unclocked, or held in reset, the very first read to 0x4000_0000 never returns a
    response and the CPU locks hard -- no console, no SSH, only a power cycle or the
    watchdog. Everything checked here lives in the PS, so none of it can hang.
    """
    state = "unknown"
    try:
        state = open("/sys/class/fpga_manager/fpga0/state").read().strip()
    except OSError:
        pass
    print(f"fpga_manager state: {state}")
    if state != "operating":
        sys.exit(f"PL is not programmed (state={state!r}); refusing to touch GP0")

    f = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    m = mmap.mmap(f, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=SLCR)
    rd = lambda off: struct.unpack("<I", m[off:off + 4])[0]

    rst = rd(SLCR_FPGA_RST_CTRL)
    clk = rd(SLCR_FPGA0_CLK_CTRL)
    # FPGA0_CLK_CTRL[5:4] SRCSEL: 0x0/0x1 = IO PLL, 0x2 = ARM PLL, 0x3 = DDR PLL.
    src = (clk >> 4) & 0b11
    d0, d1 = (clk >> 8) & 0x3F, (clk >> 20) & 0x3F
    pll = rd({0: SLCR_PLL_IO, 1: SLCR_PLL_IO,
              2: SLCR_PLL_ARM, 3: SLCR_PLL_DDR}[src])
    fclk = (PS_CLK_MHZ * ((pll >> 12) & 0x7F) / (d0 * d1)) if d0 and d1 else 0.0
    m.close(); os.close(f)

    print(f"FPGA_RST_CTRL = 0x{rst:08X} (FCLK_RESET0_N {'ASSERTED' if rst & 1 else 'released'})")
    # Four decimals, not one: the P-ext build runs at 1000/29 = 34.4828 MHz, and
    # "34.5" is not a number anyone can check a timing constraint against.
    print(f"FCLK0 = {fclk:.4f} MHz  (divisors {d0}/{d1}, src {src}, "
          f"PLL fdiv {(pll >> 12) & 0x7F} x {PS_CLK_MHZ} MHz)")
    print(f"FCLK0_HZ = {int(round(fclk * 1e6))}")
    if rst & 1:
        sys.exit("PL is held in reset; a GP0 access would hang. Clear SLCR FPGA_RST_CTRL[0].")
    if not d0 or not d1 or fclk < 1.0:
        sys.exit("FCLK0 is stopped; a GP0 access would hang.")

    if not os.path.exists("/dev/watchdog"):
        print("note: no /dev/watchdog -- a PL fault will need a physical power cycle")


