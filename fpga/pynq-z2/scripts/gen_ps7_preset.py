#!/usr/bin/env python3
"""Generate tcl/ps7_preset_pynqz2.tcl from the TUL board preset.

The preset file describes a whole block-design preset, so it carries user_parameters for
several IPs (axi_gpio's C_GPIO_WIDTH, etc). Only the processing_system7 block's CONFIG.PCW_*
parameters belong on the PS7 IP; everything else makes Vivado error out.
"""
import re, sys, xml.etree.ElementTree as ET
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "boards/pynq-z2/A.0/preset.xml"
OUT = Path(__file__).resolve().parent.parent / "tcl/ps7_preset_pynqz2.tcl"

root = ET.parse(SRC).getroot()
ps7 = [ip for ip in root.iter("ip") if ip.get("name") == "processing_system7"]
if len(ps7) != 1:
    sys.exit(f"expected exactly one processing_system7 block in {SRC}, found {len(ps7)}")

# Derived/read-only params Vivado recomputes; setting them is noise or an error.
SKIP = re.compile(r"CONFIG\.PCW_(.*_BASEADDR|.*_HIGHADDR|.*_PERIPHERAL_DIVISOR\d)$")
params = [(u.get("name"), u.get("value")) for u in ps7[0].iter("user_parameter")]
kept = [(n, v) for n, v in params
        if n.startswith("CONFIG.PCW_") and not SKIP.match(n)]

with OUT.open("w") as f:
    f.write("""# PYNQ-Z2 PS7 preset, generated from boards/pynq-z2/A.0/preset.xml (TUL, board rev A.0).
#
# WHY THIS FILE EXISTS. Setting CONFIG.PCW_IMPORT_BOARD_PRESET on the processing_system7 IP
# is silently ignored in Vivado 2023.1 batch mode -- the IP keeps Vivado's defaults
# (MT41J128M8 / 32-bit bus) instead of this board's (MT41J256M16RE-125 / 16-bit bus).
# A bitstream built that way fails DDR training on real hardware with no build-time error,
# so we apply every parameter explicitly and then ASSERT the critical ones in
# tcl/verify_ps7.tcl. Do not swap this for a preset import without re-running that check.
#
# Generated -- do not hand-edit. Regenerate with scripts/gen_ps7_preset.py.

proc apply_ps7_preset_pynqz2 {ip} {
  set_property -dict [list \\\n""")
    for n, v in kept:
        f.write(f"    {n} {{{v}}} \\\n")
    f.write("  ] $ip\n}\n")

print(f"processing_system7 params: {len(params)}  applied: {len(kept)}  skipped: {len(params)-len(kept)}")
