# Board selection, sourced by both build scripts.
#   set env(PYNQ_BOARD) to "z1" (default) or "z2".
#
# Both boards are xc7z020clg400-1 with the same MT41J256M16RE-125 DDR, so the design,
# constraints and every area/timing result are shared. What differs is the PS7 preset --
# the Z1's T_RCD/T_RP are 7 where the Z2's are 13.125 -- and the board_part name, since
# Digilent ships the PYNQ-Z1 as "arty-z7-20" (same PCB) and has no "pynq-z1" board part.
set ::BOARD [expr {[info exists ::env(PYNQ_BOARD)] ? $::env(PYNQ_BOARD) : "z1"}]

switch -- $::BOARD {
  z1 {
    set ::BOARD_PART  "digilentinc.com:arty-z7-20:part0:1.1"
    set ::PRESET_FILE "ps7_preset_pynqz1.tcl"
    set ::PRESET_PROC "apply_ps7_preset_pynqz1"
    set ::DDR_T_RCD   "7"
  }
  z2 {
    set ::BOARD_PART  "tul.com.tw:pynq-z2:part0:1.0"
    set ::PRESET_FILE "ps7_preset_pynqz2.tcl"
    set ::PRESET_PROC "apply_ps7_preset_pynqz2"
    set ::DDR_T_RCD   "13.125"
  }
  default { error "PYNQ_BOARD must be z1 or z2, got '$::BOARD'" }
}
puts "BOARD: $::BOARD  part=$::BOARD_PART  preset=$::PRESET_FILE"
