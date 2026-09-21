# Worst setup paths of a routed roccmoon-family build, by the block they run through:
#   the big core's pipelined multiplier (core/mul), its ALU (core/alu: MBP's DOT8/QMUL cascade), and
#   the L2's MSHR scheduler (0x5A5A0010's worst path).
#
#   vivado -mode batch -source postroute_paths.tcl -tclargs <build dir>
set build [lindex $argv 0]
open_checkpoint $build/post_route.dcp
set out $build/reports/paths_by_block.rpt
set fh [open $out w]
proc worst {fh label cells} {
  if {[llength $cells] == 0} { puts $fh "$label\tNO_CELLS"; puts "PATHS $label NO_CELLS"; return }
  set p [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1 -through $cells] 0]
  if {$p eq ""} { puts $fh "$label\tNO_PATH"; puts "PATHS $label NO_PATH"; return }
  set row [format "%s\tslack %.3f\tdatapath %.3f\tlevels %s\tfrom %s\tto %s" $label [get_property SLACK $p] \
             [get_property DATAPATH_DELAY $p] [get_property LOGIC_LEVELS $p] \
             [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
  puts $fh $row
  puts "PATHS $row"
}
# hart 0's tile is the one whose core has a `mul` instance; hart 1's core has none
set mulcells [get_cells -hier -regexp {.*/core/mul/.*} -filter {IS_PRIMITIVE}]
set tile0 ""
if {[llength $mulcells] > 0} {
  regexp {^(.*)/core/mul/} [lindex $mulcells 0] -> tile0
}
# no pipelined multiplier (0x5A5A0010): hart 0 is the core whose ALU holds DSPs (MBP's products)
if {$tile0 eq ""} {
  foreach d [get_cells -hier -regexp {.*/core/alu/.*} -filter {REF_NAME =~ DSP48E1}] {
    regexp {^(.*)/core/alu/} $d -> tile0
    break
  }
}
foreach c [get_cells -hier -regexp {.*/core/alu/.*} -filter {IS_PRIMITIVE}] {
  regexp {^(.*)/core/alu/} $c -> t
  dict incr alus $t
}
if {[info exists alus]} { dict for {t n} $alus { puts $fh "alu_instance\t$t\t$n primitives" } }
puts $fh "hart0_tile\t$tile0"
worst $fh overall [get_cells -hier -filter {IS_SEQUENTIAL}]
worst $fh pipelined_mul $mulcells
if {$tile0 ne ""} {
  worst $fh big_core_alu [get_cells -hier -regexp "${tile0}/core/alu/.*" -filter {IS_PRIMITIVE}]
  worst $fh big_core_div [get_cells -hier -regexp "${tile0}/core/div/.*" -filter {IS_PRIMITIVE}]
  # through the DSP48s only: MBP's products in the ALU (the QMUL cascade), the multiplier's in core/mul
  worst $fh big_core_alu_dsp [get_cells -hier -regexp "${tile0}/core/alu/.*" -filter {REF_NAME =~ DSP48E1}]
  worst $fh pipelined_mul_dsp [get_cells -hier -regexp "${tile0}/core/mul/.*" -filter {REF_NAME =~ DSP48E1}]
}
worst $fh l2_mshrs [get_cells -hier -regexp {.*inclusive_cache_bank_sched/mshrs_.*} -filter {IS_PRIMITIVE}]
if {[llength $mulcells] > 0} {
  report_timing -delay_type max -max_paths 3 -nworst 1 -through $mulcells -file $build/reports/path_pipelined_mul.rpt
}
close $fh
puts "PATHS_DONE $out"
exit
