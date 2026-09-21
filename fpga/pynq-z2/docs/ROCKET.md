# Rocket + TACIT + PS-backed DDR on PYNQ-Z2

The full SoC bitstream. Unlike `pynqz2_dramtest.bit`, this one **is** Chipyard.

## Result

`build_rocket/pynqz2_rocket_tacit.bit` — 4,045,677 B, built headless end to end.

| | | of device |
|---|---|---|
| Slice LUTs | **28,009** | **52.65 %** |
| Slice Registers | 17,477 | 16.43 % |
| Block RAM | **58** | **41.43 %** |
| DSPs | 13 | 5.91 % |
| WNS / WHS @ 40 MHz | **+0.159 ns / +0.032 ns** | closes |
| DRC | 37 warnings, 0 errors | see below |

That 52.65 % is close to the 61 % predicted from the Arty-200T deltas before any of this
was built, which is a reasonable check on the earlier budget.

## The config

`chipyard/PynqZ2Configs.scala`, class `PynqZ2RocketTacitConfig`:

- **`WithNBigCores(1)` + `WithoutFPU`** — the FPU is 13,878 LUTs on its own; dropping it is
  what makes this fit.
- **`WithInclusiveCache(nWays = 4, capacityKB = 64)`** — see below, this one is load-bearing.
- **`WithExtMemSize(256 MB)`, `WithExtMemIdBits(4)`** — ID width must stay ≤ 6 because
  `S_AXI_HP0`'s AWID/ARID/WID are 6 bits; wider IDs get truncated at the port and responses
  return to the wrong master.
- **`WithTacitEncoder` + `WithTraceSinkDMA(1)`** — encoder per tile at
  `0x3000000 + tileId*0x1000`, DMA sink writing the trace into DDR, which on this board
  means into PS DRAM over the same HP0 port the core uses.

### The L2 is the thing that nearly killed it

With Chipyard's default L2 the design synthesised at **140/140 BRAM36 — 100 %** and 86.4 %
LUT. `WithInclusiveCache` defaults to `capacityKB = 512`; on a device with 630 KB of block
RAM total that is unroutable before the L1s are even counted. At 64 KB / 4 ways it drops to
58 BRAM and 52.65 % LUT.

Deleting the L2 outright with `WithNBanks(0)` does **not** work: it removes the memory bus
with it and elaboration dies with `key not found: Location(mbus)`, because both the AXI4 mem
punchthrough and TACIT's DMA sink attach there. That route needs
`WithIncoherentBusTopology` too.

## The memory path

```
ChipTop.axi4_mem_0  (AXI4, 4-bit ID, 64-bit, 8-bit LEN, base 0x8000_0000)
        │
        ▼  src/axi4_to_axi3.v   — LEN narrowed to 4 bits, WID reconstructed, LOCK widened
        │
        ▼  {4'd1, addr[27:0]}   — folds 256 MB of ExtMem into 0x1000_0000-0x1FFF_FFFF
        │
        ▼  S_AXI_HP0 ──▶ PS DDR controller ──▶ DDR3
```

`S_AXI_HP0` is **AXI3**: 4-bit LEN (16-beat max), a `WID` channel AXI4 deleted, 2-bit LOCK.
The bridge passes bursts through and **checks** rather than fragmenting — Rocket moves one
64 B cache line per burst, 8 beats of 64 bits, comfortably inside the limit, so a fragmenter
would be dead logic carrying live bug risk. Anything longer sets a sticky error bit readable
at `STATUS[3]` and asserts in simulation. WID is reconstructed from an AWID order FIFO,
sound because AXI4 forbids write-data interleaving.

## Clock: 40 MHz, and why not 50

At 50 MHz this misses by **WNS −2.063 ns**, on a path inside the L2 MSHR scheduler
(`mshrs_1/s_grantack` → `mshrs_4/s_writeback`): 30 logic levels, 21.65 ns, 72 % of it
routing. That is the inclusive cache's scheduler, not anything in the PS interface. 25 ns
leaves ~3 ns and closes at +0.159 ns. Going faster means trimming the L2 further rather
than tweaking constraints.

`host/run_rocket.py` sets FCLK0 to 40 MHz explicitly, because the FSBL programs it from the
boot image and stock PYNQ leaves it at 100.

## DRC: 37 warnings, 0 errors

Mostly `REQP-1840` (RAMB18 async control) and `DPOP-1` (DSP output not pipelined). For
calibration, the **known-good Arty-200T bitstreams that run on real hardware today** report
**155** and **1,788** violations of the same classes. 37 is clean by that standard.

## Running it

```bash
sudo python3 host/run_rocket.py --elf hello.bin   # load image, release reset
screen /dev/ttyPS1 115200                         # Rocket's console
```

Rocket's ExtMem base (0x8000_0000) is physical **0x1000_0000** on the PS side — that is
where a program image goes. Reserve it from Linux (`mem=256M`) first.

The SoC comes out of configuration **held in reset** so the PS can place a program before
the core fetches. `SOC_CTRL` bit 0 releases it.

## Simulation of the memory path

`sim/tb_bridge.sv` runs the **same bridge RTL that is in the bitstream**, with
Rocket-shaped traffic (8-beat 64-bit INCR bursts = one 64 B cache line), into a strict
AXI3 slave whose LEN port is only 4 bits wide — so a burst the bridge failed to constrain
would be silently truncated and land in the wrong place, which is exactly the corruption
being checked for. A separate monitor asserts `WID` matches the AWID of the burst in
flight, because the slave ignores WID and a broken order-FIFO would otherwise only fail on
silicon.

```
[TB] AXI4->AXI3 bridge: 64 bursts of 8 beats @ 0x10000000
[TB] beats=1024 (expect 1024)  data_errors=0  wid_errors=0  burst_too_long=0
BRIDGE_TEST: PASS
```

Run it with `vivado -mode batch -source tcl/run_sim_bridge.tcl`.

## Still unproven without hardware

- DDR3 PHY training, as ever.
- Rocket actually fetching and running from PS DRAM. The AXI3 conversion is checked in
  simulation and the geometry is asserted, but the first real instruction fetch over HP0
  happens on the board.
- The UART crossover carrying real characters end to end.
