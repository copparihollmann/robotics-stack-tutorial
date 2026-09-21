# axiceil (interface ceiling) constraints: the four LEDs only; copied from src/pynqz2.xdc.
# (boards/pynq-z2/A.0/part0_pins.xml), not from a datasheet reading.
#
# There is nothing here for DDR or MIO: on Zynq-7000 those are hard silicon on dedicated
# balls owned by the PS, so the PL design constrains only what it actually drives.
# All PL I/O on this board is LVCMOS33 -- the board has no VADJ jumper (only J9 power and
# JP1 boot mode), so a 1.8 V bank is not an option.

set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {leds[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {leds[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {leds[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {leds[3]}]

# FCLK_CLK0 is generated inside the PS and arrives via a BUFG; Vivado derives it from the
# PS7 IP, so no create_clock is needed. Leaving it implicit avoids double-constraining it.
