#!/usr/bin/env bash
# Apply the tutorial's boot-time devicetree changes to a stock PYNQ image.ub.
#
#   ./patch_boot_dtb.sh /path/to/stock/image.ub /path/to/output/image.ub
#
# Two changes, both needed, neither possible with a runtime overlay:
#
#   1. PS UART1 on -- status=okay AND /aliases/serial1. xuartps takes its line number from
#      of_alias_get_id(np,"serial"); with only serial0 present UART1 falls back to line 0,
#      collides with the console and fails with uart_add_one_port() err=-22. An overlay
#      cannot supply the alias: of_alias_scan() runs once, early in boot.
#
#   2. Watchdog in reset mode -- the stock node has no reset-on-timeout, so cdns_wdt arms
#      the SWDT to raise an interrupt. A PL design that stalls an AXI transaction locks the
#      CPU, which can then never service that interrupt. With the property set, expiry
#      drives a real SoC reset and the board recovers on its own in ~30 s.
#
# Needs fdtput (device-tree-compiler) on the build host. Deliberately does NOT need
# mkimage/dumpimage -- see fit_dtb.py.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src=${1:?usage: patch_boot_dtb.sh <stock image.ub> <output image.ub>}
dst=${2:?usage: patch_boot_dtb.sh <stock image.ub> <output image.ub>}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

"$here/fit_dtb.py" extract "$src" "$tmp/base.dtb"

fdtput -ts "$tmp/base.dtb" /axi/serial@e0001000 status okay
fdtput -ts "$tmp/base.dtb" /aliases serial1 /axi/serial@e0001000
fdtput     "$tmp/base.dtb" /axi/watchdog@f8005000 reset-on-timeout   # zero-length boolean

echo "--- applied ---"
echo "  serial@e0001000 status : $(fdtget -ts "$tmp/base.dtb" /axi/serial@e0001000 status)"
echo "  aliases/serial1        : $(fdtget -ts "$tmp/base.dtb" /aliases serial1)"
echo "  watchdog reset-on-timeout present"

"$here/fit_dtb.py" replace "$src" "$tmp/base.dtb" "$dst"
echo
echo "Install with:  scp $dst board:/tmp/ && ssh board 'sudo cp /tmp/$(basename "$dst") /boot/image.ub && sudo reboot'"
echo "Keep the stock image as /boot/image.ub.orig -- it is the recovery path from the"
echo "U-Boot prompt over serial if a boot change goes wrong."
