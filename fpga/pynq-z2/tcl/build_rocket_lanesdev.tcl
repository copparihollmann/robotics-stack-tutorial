# The lane development config: 0x5A5A002A's SoC minus TACIT, the mic, the RGB LEDs, the MBP
# P-extension and hart 0's pipelined multiplier.  MAGIC 0x5A5A002B.  A DIFFERENT MACHINE --
# for lane function, not for fit or timing.  See fpga/pynq-z2/docs/LAYERNORM_LANE.md section 20.
set ::env(ROCKET_VARIANT) lanesdev
source [file dirname [info script]]/build_rocket.tcl
