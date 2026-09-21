# The dual-core Rocket + TACIT + MBP P-ext + PDM microphone bitstream WITH the board's two
# RGB LEDs (LD4, LD5) on a sifive GPIO controller at 0x1001_0000.
# All the work is in build_rocket.tcl; this only selects the variant.
set ::env(ROCKET_VARIANT) micrgb
source [file dirname [info script]]/build_rocket.tcl
