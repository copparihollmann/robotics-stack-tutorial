# The two RGB LEDs, LD4 and LD5.  A SEPARATE constraint file, added to constrs_1 by
# tcl/build_rocket.tcl only for the variants that have the ports -- exactly as
# src/pynqz2_mic.xdc is, and for exactly the same reason.
#
# DO NOT MERGE THIS INTO pynqz2_rocket.xdc BEHIND AN `if`.  Vivado 2023.1 parses every
# file in constrs_1 as XDC, which is a restricted subset of Tcl with no control flow:
#     CRITICAL WARNING: [Designutils 20-1307] Command 'if' is not supported in the xdc
#                       constraint file
# and it then runs NEITHER branch.  The design still places, because unconstrained I/O is
# auto-placed wherever the placer likes, so the failure mode is a bitstream with six LED
# signals on six arbitrary balls and no error anywhere.  That bug nearly shipped with the
# microphone; see the header of src/pynqz2_mic.xdc and docs/MICROPHONE.md section 8.3.
# Conditional FILE INCLUSION from real Tcl is the thing that works.
#
# ---------------------------------------------------------------------------------------
# THE COLOUR MAPPING, AND WHERE IT COMES FROM
#
# The board files in this repo (boards/pynq-z2/A.0/part0_pins.xml and
# boards/arty-z7-20/A.0/part0_pins.xml, which agree) give six balls under the name
# rgb_led_tri_o_0..5 and say NOTHING about which is red, green or blue, or which of the
# two LEDs it belongs to.  Guessing is a silent failure: every bit lights something.
#
# Two INDEPENDENT vendor sources settle it, and they agree exactly:
#
#   1. Digilent, digilent-xdc/Arty-Z7-20-Master.xdc -- the schematic net name is in the
#      trailing comment of each line, which is as close to the schematic as a text file
#      gets:
#         L15 led4_b  #IO_L22N_T3_AD7P_35        Sch=LED4_B
#         G17 led4_g  #IO_L16P_T2_35             Sch=LED4_G
#         N15 led4_r  #IO_L21P_T3_DQS_AD14P_35   Sch=LED4_R
#         G14 led5_b  #IO_0_35                   Sch=LED5_B
#         L14 led5_g  #IO_L22P_T3_AD7P_35        Sch=LED5_G
#         M15 led5_r  #IO_L23N_T3_35             Sch=LED5_R
#      (The Arty Z7-20 and the PYNQ-Z1 are the same Zynq part on two closely related PCBs.
#      Digilent's own feature comparison says the ONE difference is the microphone --
#      docs/MICROPHONE.md section 1.1 quotes it -- and Digilent publishes no PYNQ-Z1 master
#      XDC, which is why our builds use the Arty board file in the first place.)
#
#   2. Xilinx, PYNQ's own RGBLED class for this board, pynq/lib/rgbled.py:
#         RGB_BLUE = 1   RGB_GREEN = 2   RGB_RED = 4   RGB_WHITE = 7
#      three bits per LED, LD4 at the bottom (the base overlay notebook uses
#      rgbled_position = [4,5]).  Combined with the bit order in
#      PYNQ boards/Pynq-Z1/base/vivado/constraints/base.xdc --
#         rgbleds_6bits_tri_o[0]=L15 [1]=G17 [2]=N15 [3]=G14 [4]=L14 [5]=M15
#      -- that is bit 0 = LD4 blue, bit 1 = LD4 green, bit 2 = LD4 red, and the same
#      again three bits up for LD5.  Identical to (1).
#
# That base.xdc is the same file docs/MICROPHONE.md section 1.3 took F17/G18 from, and the
# microphone it named was then recorded from on this board -- so this source has already
# been right about this board once, measurably.
#
# POLARITY: ACTIVE HIGH.  PYNQ-Z1 Reference Manual section 12.1, verbatim: "Each
# tri-color LED has three input signals that drive the cathodes of three smaller internal
# LEDs: one red, one blue, and one green.  Driving the signal corresponding to one of
# these colors high will illuminate the internal LED.  The input signals are driven by the
# Zynq PL through a transistor, which inverts the signals.  Therefore, to light up the
# tri-color LED, the corresponding signals need to be driven high."
#
# DRIVE STRENGTH: nothing special, and that is a consequence of the transistor.  The FPGA
# pin drives a transistor base, not the LED, so there is no series-resistor sizing to get
# right here -- unlike the four plain LEDs, which section 12 says are "anode-connected to
# the Zynq PL via 330-ohm resistors".  Default LVCMOS33 drive is left alone, as it is for
# leds[3:0] in pynqz2_rocket.xdc.
#
# BRIGHTNESS: the same section says "Digilent strongly recommends the use of pulse-width
# modulation (PWM) when driving the tri-color LEDs.  Driving any of the inputs to a steady
# logic '1' will result in the LED being illuminated at an uncomfortably bright level.  You
# can avoid this by ensuring that none of the tri-color signals are driven with more than a
# 50% duty cycle."  That is honoured in HARDWARE, not in software: src/pynqz2_rocket_top.v
# gates all six signals with a fixed RGB_DUTY/256 chopper, so no guest can leave one of
# these on at 100% however it drives the GPIO.  See docs/RGB_LEDS.md section 2.
#
# All PL I/O on this board is LVCMOS33 -- no VADJ jumper.
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports {rgb_led[0]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {rgb_led[1]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {rgb_led[2]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {rgb_led[3]}]
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports {rgb_led[4]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {rgb_led[5]}]

# These are outputs into a transistor base with a ~135 kHz chopper on them; there is no
# receiver whose setup/hold the timing engine could budget, and no launch/capture pair that
# means anything off-chip.  Say so, rather than leaving six unconstrained output paths for
# the tool to invent an endpoint for.
set_false_path -to [get_ports {rgb_led[*]}]
