# Running Zephyr on Rocket, on the PYNQ-Z1

Verified on hardware. `scripts/20_rocket_run.sh` does all of this; this document explains
what it does and, more usefully, the two things that are not obvious.

```
*** Booting Zephyr OS build 4329bf61c4fe ***
Hello World! chipyard_pynqz1/rocketchip_virt_riscv64
```

## The flow

```
west build -b chipyard_pynqz1     ->  zephyr.bin (raw image, entry 0x8000_0000)
scp to the board                  ->  PS writes it into DDR at phys 0x1000_0000
SOC_CTRL bit 0                    ->  release Rocket from reset
SOC_CTRL bit 1                    ->  pulse custom_boot  <-- the part people miss
Rocket's UART -> PS UART1 (EMIO)  ->  /dev/ttyPS1 at 115200
```

```bash
scripts/20_rocket_run.sh                                    # hello_world
scripts/20_rocket_run.sh --sample <path> --name <x>         # any Zephyr app
scripts/20_rocket_run.sh --no-bitstream                     # reuse the loaded PL
```

## Releasing reset is not enough — the bootrom parks in `wfi`

This is the one that costs an afternoon. Chipyard's bootrom reset vector is `_hang`, not
`_start`:

```asm
_hang:                    // reset vector
  la a0, _start
  csrw mtvec, a0          // on MSIP interrupt, go to _start
  li a0, 8
  csrw mie, a0            // enable MSIP only
  csrs mstatus, a0
wfi_loop:
  wfi
  j wfi_loop              // wait for someone to poke MSIP
```

So a freshly-reset hart does **nothing** until an MSIP interrupt arrives. In simulation TSI
sends it; there is no TSI in `PynqZ2RocketTacitConfig`. What sends it here is the **custom
boot pin**, `SOC_CTRL` bit 1. Asserting it runs a small hardware FSM
(`testchipip/src/main/scala/boot/CustomBootPin.scala`) that:

1. writes `BootAddrReg` (`0x1000`) = `0x8000_0000`, then
2. writes hart 0's `msip` in the CLINT.

The bootrom takes the interrupt, reads `BootAddrReg`, and `mret`s to `0x8000_0000`.

The FSM latches on the pin's rising edge and then parks in a `dead` state until the pin
drops, so `run_rocket.py` pulses it — assert, wait, deassert — which leaves it armed for the
next run. That is why re-running an app needs no bitstream reload.

`STATUS` bit 2 (`saw_mem`) is the tell: it goes 0 → 1 the instant the core fetches from
DDR. If it stays 0 after `custom_boot`, the hart is still in `wfi_loop`.

```
  before release         STATUS = 0x00000001  resetn=0 saw_mem=0
  reset released         STATUS = 0x00000003  resetn=1 saw_mem=0
  custom_boot asserted   STATUS = 0x00000007  resetn=1 saw_mem=1   <- it fetched
```

## The board definition: `boards/chipyard/pynqz1`

It lives in **this repo**, not in `zephyr_ws/zephyr/boards/` — that checkout is west-managed
and `west update` would discard it. `scripts/20_rocket_run.sh` passes
`-DBOARD_ROOT=$IISWC_ROOT`.

It is `chipyard_arty` with only the changes this hardware forces. The address map needed no
changes at all: `chipyard-riscv.dtsi` already matches the generated SoC (UART `0x10020000`,
CLINT `0x2000000`, PLIC `0xc000000`, DRAM `0x8000_0000` + 256 MB). Verify against the DTS
Chipyard emits next to the Verilog, which is the ground truth:

```
generated-src/chipyard.harness.TestHarness.PynqZ2RocketTacitConfig/*.dts
```

| Change | Why |
|---|---|
| `CONFIG_FPU=n` | `riscv,isa = "rv64imaczicsr_zifencei_zihpm_xrocket"` — the config uses `WithoutFPU`. Building with `CONFIG_FPU=y` emits FP instructions that trap as illegal. The ELF must report `soft-float ABI` and a `Tag_RISCV_arch` with no `f`/`d`. |
| `CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=40000` | The PL runs at 40 MHz and mtime ticks at clock / `CONFIG_RTC_CLOCK_DIVIDER_VALUE` (1000). |
| `uart0 interrupts = <1 1>` | The shared dtsi assumes PLIC source 3; the generated DTS says `interrupts = <1>` with `riscv,ndev = <1>`. |
| `CONFIG_BUILD_OUTPUT_BIN=y` | Nothing here parses an ELF — the PS writes a flat image into DDR. |

### That clock value also sets the baud rate

`SIFIVE_PERIPHERAL_CLOCK_FREQUENCY` is **not** taken from the devicetree. From
`soc/rocketchip/virt_riscv/common/soc.h`:

```c
#define SIFIVE_PERIPHERAL_CLOCK_FREQUENCY \
        (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC * CONFIG_RTC_CLOCK_DIVIDER_VALUE)
```

and `uart_sifive.c` computes `div = sys_clk_freq / baud_rate - 1`. So
`40000 * 1000 / 115200 - 1 = 346`, giving 115,273 baud — 0.06 % off, fine. Get
`SYS_CLOCK_HW_CYCLES_PER_SEC` wrong and the symptom is a *garbled* console rather than a
silent one. Silence means the core never started; garbage means this number is wrong.

## Measured on hardware

`samples/timer` cross-checks Zephyr's mtime-based timing API against the raw `rdcycle` CSR,
which is what turns the clock configuration from an assumption into a measurement:

```
dummy_work()              60 cycles (timing API), 1500000 ns, 60067 cycles (rdcycle)
k_busy_wait(1000 us)      40 cycles (timing API), 1000000 ns, 39244 cycles (rdcycle)
k_msleep(1)               47 cycles (timing API), 1175000 ns, 47339 cycles (rdcycle)
```

- `k_busy_wait(1000 us)` = **40 mtime cycles**, which at 40 kHz is exactly 1.000 ms.
- The same wait = **39,244 core cycles**, i.e. 39.2 MHz — the 40 MHz FCLK.
- `dummy_work`: 60 mtime cycles → 1.5 ms, and 60,067 rdcycles at 40 MHz → 1.5 ms. Two
  independent counters, same answer.
- `k_msleep(1)` costs **47,339 core cycles over 47 mtime ticks** — 1.175 ms of wall time,
  which at 40 MHz is 47,000 cycles. The sleep costs what it takes.

> **This last line used to read 3,002 cycles, and that was also correct at the time.**
> Stock Rocket gates `mcycle` on `!io.csr_stall`, and `csr_stall` is `reg_wfi || cease`, so
> the counter *stops* for as long as the hart sits in `wfi`: `rdcycle` reported how much
> work the hart did, not how much time passed. Both bitstreams in this repo now carry
> `patches/0004-rocketchip-mcycle-free-run.patch`, which takes `reg_wfi` out of that enable
> and leaves `mcountinhibit.CY` and `cease` alone. The two compute-bound rows above are
> unchanged by it — `dummy_work()` to the cycle, `k_busy_wait()` by 0.14% — because they
> never sleep. See [`TACIT_MULTICORE.md`](TACIT_MULTICORE.md) §6.

## "Failed to reboot: spinning endlessly..."

Harmless, and it means `main()` ran to completion. `samples/hello_world` ends with
`sys_reboot(SYS_REBOOT_COLD)` to terminate a *simulation* through HTIF. On real hardware
there is no reboot path, so Zephyr says so and spins.

## When there is no output

| Symptom | Cause |
|---|---|
| Nothing, `saw_mem = 0` | Hart still in `wfi_loop` — `custom_boot` was never pulsed. |
| Nothing, `saw_mem = 1` | It fetched but died early. Check the image landed: `run_rocket.py` reads DDR back after writing and fails loudly if it did not. |
| Garbled characters | `CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC` does not match the real FCLK. |
| Banner missing, later lines present | The console reader started late; the UART TX FIFO is 8 bytes. Start `console.py` before releasing reset — the script sleeps 1.5 s to guarantee this. |
| `MAGIC != 0x5A5A0002` | The DRAM-test bitstream is loaded, not the Rocket one. |
