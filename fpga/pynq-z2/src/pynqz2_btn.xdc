# The four pushbuttons BTN0..BTN3: the four balls PYNQZ2_HAS_BTN reads.
#
# A SEPARATE constraint file, added to constrs_1 by tcl/build_rocket.tcl only for the variants
# that have the ports.  The reason is the one in the header of src/pynqz2_rgb.xdc and
# src/pynqz2_mic.xdc: XDC has no `if`, and a guarded block in a shared file is silently not run,
# which leaves the pins auto-placed and nobody here can see the board to notice.
#
# ---------------------------------------------------------------------------------------
# WHICH BALLS, AND WHERE THEY COME FROM
#
# Two files in this repo state it, and they agree exactly.  Both are VENDOR board files, not
# recollection, and the first is the one this build actually loads:
#
#   1. boards/arty-z7-20/A.0/part0_pins.xml -- the Vivado board file for
#      digilentinc.com:arty-z7-20:part0:1.1, which tcl/board.tcl selects for PYNQ_BOARD=z1
#      (Digilent ships the PYNQ-Z1 as the Arty Z7-20; there is no "pynq-z1" board part, which is
#      also why src/pynqz2_rgb.xdc takes the RGB LEDs' balls from the same family of files):
#         <pin index="0" name ="btns_4bits_tri_i_0" iostandard="LVCMOS33" loc="D19"/>
#         <pin index="1" name ="btns_4bits_tri_i_1" iostandard="LVCMOS33" loc="D20"/>
#         <pin index="2" name ="btns_4bits_tri_i_2" iostandard="LVCMOS33" loc="L20"/>
#         <pin index="3" name ="btns_4bits_tri_i_3" iostandard="LVCMOS33" loc="L19"/>
#
#   2. boards/pynq-z2/A.0/part0_pins.xml -- the TUL PYNQ-Z2 board file, same four names, same
#      four balls, in the same order.  The two boards are the same Zynq part on two closely
#      related PCBs and share this block.
#
# docs/RGB_LEDS.md section 8 already priced exactly this addition and names the same four balls
# from the same two board files.  Unlike the RGB LEDs there is no colour question to settle:
# `btns_4bits_tri_i_0..3` is self-describing.
#
# BIT ORDER is the board files': btn[0] is BTN0 (D19) and btn[3] is BTN3 (L19).  It reaches
# software as bits 6..9 of the GPIO controller at 0x1001_0000 -- pins 0..5 are the two RGB LEDs
# and are unchanged from 0x5A5A0035.  tcl/build_rocket.tcl's btn_pins table states the same four
# facts a second time and checks them against the IMPLEMENTED design, after synthesis against the
# constraint and after ROUTE against where the port actually landed.
#
# POLARITY: ACTIVE HIGH, and that is the vendor's statement rather than a convention.  PYNQ-Z1
# Reference Manual section 12, quoted in docs/RGB_LEDS.md section 8: the buttons "normally
# generate a low output when they are at rest, and a high output only when they are pressed".
# So a pressed button reads 1 in the GPIO's input_val register, with no inversion anywhere in
# this design.  There is no debounce hardware on the board and none is added here (see the
# PYNQZ2_HAS_BTN block in src/pynqz2_rocket_top.v for why debounce is software's problem).
#
# NO PULL-UP OR PULL-DOWN IS SET.  The board's own resistors define the idle level; adding a weak
# internal one would either fight them or mask a disconnected button.  All PL I/O on this board is
# LVCMOS33 (no VADJ jumper).  The bank each ball sits in is not asserted here -- report_io of the
# routed design prints it, and tcl/build_rocket.tcl checks the BALL, which is the thing that can
# be wrong.
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} [get_ports {btn[2]}]
set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} [get_ports {btn[3]}]

# TIMING: none to state.  A mechanical button has no launch edge, and the first thing the signal
# meets on-chip is the GPIO controller's own 3-deep SynchronizerShiftReg
# (rocket-chip-blocks devices/gpio/GPIO.scala:86).  Leaving these as ordinary input paths would
# have the timing engine invent a source clock and budget against it; say instead that there
# isn't one.  src/pynqz2_cam.xdc does the same for cam_int, which is the same kind of signal.
set_false_path -from [get_ports {btn[*]}]
