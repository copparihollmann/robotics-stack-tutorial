# The I2C bus on its own, without the camera shield: the two balls PYNQZ2_HAS_I2C drives.
#
# A SEPARATE constraint file, added to constrs_1 by tcl/build_rocket.tcl only for the variants
# that have the ports -- exactly as src/pynqz2_mic.xdc, src/pynqz2_rgb.xdc and src/pynqz2_cam.xdc
# are, and for exactly the same reason.  DO NOT MERGE THIS INTO pynqz2_rocket.xdc BEHIND AN `if`:
# Vivado 2023.1 parses every file in constrs_1 as XDC, which has no control flow --
#     CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in the xdc
#                       constraint file
# -- and then runs NEITHER branch, leaving the pins unconstrained and AUTO-PLACED.  See the header
# of src/pynqz2_mic.xdc and docs/MICROPHONE.md section 8.3 for the time that nearly shipped.
#
# ---------------------------------------------------------------------------------------
# WHICH BALLS, AND WHERE THEY COME FROM
#
# P16 = SCL, P15 = SDA: the PYNQ-Z1's dedicated I2C pins on the chipKIT/Arduino header.  Two
# independent statements in this repo agree:
#
#   1. boards/arty-z7-20/A.0/part0_pins.xml -- the Vivado board file this build actually uses
#      (tcl/board.tcl sets board_part digilentinc.com:arty-z7-20:part0:1.1 for PYNQ_BOARD=z1):
#         <pin index="27" name ="i2c_scl_i" ... loc="P16"/>
#         <pin index="28" name ="i2c_sda_i" ... loc="P15"/>
#      boards/pynq-z2/A.0/part0_pins.xml agrees, so the two boards share these balls.
#
#   2. src/pynqz2_cam.xdc, which puts cam_sda on P15 and cam_scl on P16 from the shield's own
#      netlist (archive/drafts/PINMAP_riskybirdv3_pynq_camera_rev0.6.md), re-checked there
#      against report_io of the routed 0x5A5A0010 design.
#
# THE PULL-UPS ARE ON THE BOARD.  The Z1 fits 2.2 k to 3V3 on both lines (R49/R50) --
# docs/OLED_SSD1306.md section 1 prices the rise time against them and against a module's own
# 4.7 k/10 k in parallel; every combination is inside the 300 ns fast-mode limit.  These are the
# only two PL balls on this board with pull-ups fitted, which is why an SSD1306 wired directly to
# the PL goes here and not on two spare header pins.
#
# PULLUP TRUE is set anyway, as the Arty-200T binder (WithArty200TI2C) sets it and as
# src/pynqz2_cam.xdc does: the board's 2.2 k dominates, and the weak internal one only keeps the
# lines defined when nothing is plugged in.  Bank 34, VCCO 3.3 V; all PL I/O on this board is
# LVCMOS33 (no VADJ jumper).
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports i2c_scl]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports i2c_sda]

# TIMING: there is none to state.  Both lines are open-drain, bidirectional and asynchronous --
# the TLI2C samples them through its own filter and only ever reacts to a falling SCL edge, and
# the 100 kHz bit period is 400 clock cycles at 40 MHz.  There is no off-chip launch or capture
# edge the timing engine could budget against, so say so rather than leaving four unconstrained
# I/O paths for the tool to invent an endpoint for.  src/pynqz2_cam.xdc says the same two lines
# for the same two balls.
set_false_path -from [get_ports {i2c_scl i2c_sda}]
set_false_path -to   [get_ports {i2c_scl i2c_sda}]
