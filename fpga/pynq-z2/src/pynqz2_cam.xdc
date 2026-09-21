# The HM01B0 camera shield on the PYNQ-Z1: pins and timing for PYNQZ2_CAM (0x5A5A001E).
#
# A SEPARATE constraint file, added by tcl/build_rocket.tcl only when has_cam is set, for the
# reason in src/pynqz2_mic.xdc's header: XDC has no `if`, and a guarded block in a shared file is
# silently not run.  docs/CAMERA_Z1.md sections 2 and 4 carry the reasoning; this file is the
# statement.
#
# PINS.  From archive/drafts/PINMAP_riskybirdv3_pynq_camera_rev0.6.md (the shield's netlist,
# riskybirdv3_pynq_camera rev 0.6), and every ball, bank and pin function below was re-checked
# against Vivado's own report_io of the routed 0x5A5A0010 design, where all 16 are unused User IO.
# NOT fpga/pynq-z2/docs/CAMERA_PCB_SPEC.md, which is an older PYNQ-Z2 RPi-header design.
#
#   U13 (shield IO2) is PUDC_B, tied to 3V3 on the shield through R27.  It must never carry a port;
#   build_rocket.tcl checks that after route.  The shield's PL UART (A0/A1: Y11, Y12) and JTAG
#   (IO11-13 and IO42: R17, P18, N17, Y13) are out of scope for this build and stay unassigned.
#
# Every shield pin is LVCMOS33 on the Z1 (banks 13 and 34, VCCO 3.3 V).  IO0-IO13 reach the ball
# through 200 ohm on the Z1; A0-A5 go straight to the ball; SDA/SCL have 2.2 k pull-ups on the Z1.

# ---- data bus, shield IO0,1,3..8, bank 34 -------------------------------------------------------
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {cam_d[0]}]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports {cam_d[1]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {cam_d[2]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {cam_d[3]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {cam_d[4]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports {cam_d[5]}]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports {cam_d[6]}]
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {cam_d[7]}]

# ---- sync, clock and interrupt, shield A2-A5, bank 13 --------------------------------------------
set_property -dict {PACKAGE_PIN U10 IOSTANDARD LVCMOS33} [get_ports cam_pclk]
set_property -dict {PACKAGE_PIN W11 IOSTANDARD LVCMOS33} [get_ports cam_fvld]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33} [get_ports cam_lvld]
set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVCMOS33} [get_ports cam_int]

# ---- outputs to the sensor, shield IO9/IO10, bank 34 ---------------------------------------------
set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33} [get_ports cam_mclk]
set_property -dict {PACKAGE_PIN T16 IOSTANDARD LVCMOS33} [get_ports cam_trig]

# ---- I2C, shield SDA/SCL, bank 34 ----------------------------------------------------------------
# PULLUP as the Arty-200T binder (WithArty200TI2C) sets it.  The Z1's own 2.2 k pull-ups dominate;
# the weak internal one only keeps the lines defined if the shield is absent.
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports cam_sda]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports cam_scl]

# ==================================================================================================
# TIMING
# ==================================================================================================

# ---- PCLK ----------------------------------------------------------------------------------------
# 36 MHz, the HM01B0's "Pixel Clock (PCLK) (MAX.)" in the datasheet's key-parameter table
# (HM01B0-MNA preliminary V01, section 1.3), and the value the Arty-200T integration constrained
# ospi_pclk to (WithArty200TOspi: addClock("ospi_pclk", pclkIO, 36), set_input_jitter 0.5).  It is
# the absolute maximum: the same table gives 6 MHz for QVGA at 60 fps on the 8-bit interface this
# RTL uses, and the RTL's fastest MCLK at 34.4828 MHz is 17.24 MHz (mclkDiv = 0).  So every
# PCLK-domain path is timed against at least 2x the clock it can see.
create_clock -name cam_pclk -period 27.778 [get_ports cam_pclk]
set_input_jitter cam_pclk 0.5

# U10 is IO_L12N_T1_MRCC_13: the N side of its clock-capable pair (the P side, T9, is not on the
# shield).  A single-ended clock has a dedicated route to a BUFG only from the P side, so without
# this the placer stops with an IO-to-BUFG placement error.  The fabric hop costs a few ns of
# insertion delay on a clock whose half-period is at least 13.9 ns; the input delays below are
# analysed with it.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins u_cam_pclk_bufg/I]]

# The sensor's clock and the PS clocks are unrelated.  Every crossing inside HM01B0Capture is a
# Gray-coded pointer or counter behind a 3-flop synchroniser (AsyncFifo, crossCount, syncPclk), so
# timing between them is not meaningful; report_cdc is where they are checked.  Same form as
# src/pynqz2_memclk.xdc, which selects the PS clocks by their pins.
set_clock_groups -asynchronous \
  -group [get_clocks cam_pclk] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ *PS7_i/FCLKCLK*}]]

# ---- D, FVLD, LVLD against PCLK: source-synchronous through two translators and the Z1 -------------
# Model (docs/CAMERA_Z1.md section 4.2 has the arithmetic):
#   * launch on PCLK's FALLING edge, capture on the rising edge (CaptureFrontend samples on the
#     rising edge, so data must change on the falling one).  The HM01B0 datasheet has no AC
#     output-timing table; the sensor's clock-to-out is ASSUMED 0 .. +8 ns after its falling edge.
#   * D crosses U1 (SN74AXC8T245), PCLK crosses U2 (SN74AXC4T245) and R1 (22 ohm): different
#     packages, so a translator skew of -3 .. +3 ns between them is assumed.
#   * D then crosses the Z1's 200 ohm series resistor into the pin: +0.5 .. +4 ns for 200 ohm into
#     ~5-20 pF.  PCLK (A5) has no series resistor on the Z1.
#   max = 8 + 3 + 4 = 15.0 ns     min = 0 - 3 + 0.5 = -2.5 ns     (both after the falling edge)
# FVLD and LVLD are on A2/A3 (no 200 ohm) but cross the same U2 as PCLK; they get the same budget,
# which is pessimistic for them.
set_input_delay -clock cam_pclk -clock_fall -max 15.0 [get_ports {cam_d[*] cam_fvld cam_lvld}]
set_input_delay -clock cam_pclk -clock_fall -min -2.5 [get_ports {cam_d[*] cam_fvld cam_lvld}]

# ---- MCLK: forwarded from an ODDR on FCLK0 ---------------------------------------------------------
# The RTL divides FCLK0 by 2*(mclkDiv+1) in a toggle flop; pynqz2_rocket_top.v re-launches that
# flop's output from an ODDR (D1 = D2) so the edge the sensor sees comes from the IOB, not from a
# fabric route.  mclkDiv is a run-time register, so no one divide ratio is always true: this
# clock describes the reset value, mclkDiv = 0, the fastest (17.24 MHz).  Nothing in the PL is
# clocked by it and the sensor returns PCLK rather than sampling anything against MCLK, so it
# carries no output delay; it exists so the port is a named clock in the reports.
create_generated_clock -name cam_mclk -source [get_pins u_cam_mclk_oddr/C] -divide_by 2 [get_ports cam_mclk]

# ---- no timing relationship --------------------------------------------------------------------
# TRIG is a software pulse; INT is a level the RTL synchronises (syncSys); I2C at <= 400 kHz is
# oversampled by the TLI2C's own input registers, and its outputs change once per SCL quarter.
set_false_path -to   [get_ports cam_trig]
set_false_path -from [get_ports cam_int]
set_false_path -from [get_ports {cam_scl cam_sda}]
set_false_path -to   [get_ports {cam_scl cam_sda}]
