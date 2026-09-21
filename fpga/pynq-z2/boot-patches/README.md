# Boot-partition patches for the PYNQ-Z1

## `uEnv.txt` — reserve the upper 256 MB  ✅ APPLIED AND VERIFIED

Copy to `/boot/uEnv.txt`. Verified on hardware:

```
Kernel command line: ... clk_ignore_unused mem=256M
Memory: 111736K/262144K available      (was 524288K)
free -m: 238 MB total                  (was 491 MB)
```

**It must set `bootargs` outright, not `extrabootargs`.** `boot.scr` does import `uEnv.txt`
("Importing environment(uEnv.txt) from mmc0..."), and it does reference `$extrabootargs` —
but only inside a conditional that never fires on this boot path:

```
setenv update_bootargs 'if test -n ${launch_ramdisk_init} && test ${bootargs} = ""; then ...'
```

An `extrabootargs=mem=256M` line is read and then silently ignored. Setting the full
`bootargs` string works because U-Boot writes its `bootargs` env var into `/chosen` before
handing off.

> Memory is tight afterwards: 238 MB total with 128 MB CMA-reserved leaves ~85 MB available
> and PYNQ's stack is not small. Consider adding `cma=64M` if userspace starts struggling.

## `patch_boot_dtb.sh` — enable PS UART1 and arm the watchdog  ✅ APPLIED AND VERIFIED

Two devicetree changes, applied to the DTB **inside `image.ub`**:

```
./patch_boot_dtb.sh /path/to/stock/image.ub image_new.ub
scp image_new.ub board:/tmp/
ssh board 'sudo cp /boot/image.ub /boot/image.ub.orig; sudo cp /tmp/image_new.ub /boot/image.ub; sudo reboot'
```

### 1. PS UART1 → `/dev/ttyPS1`

Needs **both** `serial@e0001000` → `status = "okay"` *and* `/aliases/serial1`. `xuartps`
takes its line number from `of_alias_get_id(np, "serial")`; with only `serial0` present
UART1 falls back to line 0, collides with the already-registered console, and fails with
`uart_add_one_port() failed; err=-22` — while `status` still reads `okay`, which makes it
look like the change worked.

**A runtime overlay cannot do this.** `uart1_enable.dts` (kept here as a documented dead
end) does flip `status` through configfs, but `of_alias_scan()` runs once at boot, so an
overlay-added alias is never registered and the probe fails exactly as above. The alias has
to be in the base DTB.

`/boot/system.dtb` is also ignored — this board takes the FIT path
(`## Loading fdt from FIT Image`), so the DTB that matters is the one inside `image.ub`.

Verified after reboot:

```
e0001000.serial: ttyPS1 at MMIO 0xe0001000 (irq = 27, base_baud = 6250000) is a xuartps
```

The clock gating resolved itself, as predicted. `serial@e0001000` lists
`clocks = <&clkc 24>, <&clkc 29>`, so the Zynq clock driver owns `UART_CLK_CTRL` CLKACT1 —
no SLCR poke needed. `0xF8000154` reads `CLKACT1 = 0` at idle (runtime PM, not a fault) and
`0x00000A03` the moment the port is opened.

### 2. Watchdog in reset mode

The stock node has **no `reset-on-timeout`**, so `cdns_wdt` arms the SWDT to raise an
interrupt — useless against a CPU locked on a stalled AXI transaction, which can never
service it. Adding the property makes expiry drive a real SoC reset.

Pair it with `systemd` arming and pinging the device:

```
/etc/systemd/system.conf.d/watchdog.conf
[Manager]
RuntimeWatchdogSec=30
RebootWatchdogSec=120
```

Verified: `SWDT ZMR (0xF8005000) = 0x00000033` → `WDEN=1 RSTEN=1 IRQEN=0`, `systemd` (PID 1)
holds `/dev/watchdog`, and arming it without pinging reset the board — `boot_id` changed,
SSH back in ~45 s. Without this, a bad bitstream means walking over and pulling a cable.

## `fit_dtb.py` — editing a FIT image without `mkimage`

The DTB lives inside `image.ub`, and neither the board nor the build host has
`mkimage`/`dumpimage`. A FIT image *is* a flat devicetree, so `fit_dtb.py` does the surgery
with stock Python: `extract` pulls the `flat_dt` payload out, `replace` puts one back and
recomputes the sha1 that U-Boot verifies at boot (it refuses to boot on a mismatch, with
`Bad hash value`). Every other payload is carried through and re-checked byte-for-byte.

Cross-checked against `fdtput` doing the same edit: the two outputs differ only in trailing
padding and are property-for-property identical.

> **Keep `/boot/image.ub.orig`.** It is the recovery path: interrupt autoboot on the serial
> console and `fatload mmc 0 0x2080000 image.ub.orig; bootm 0x2080000`.
