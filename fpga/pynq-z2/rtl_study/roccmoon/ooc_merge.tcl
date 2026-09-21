# Out-of-context area/timing of the ENGINE AS SHIPPED in 0x5A5A002E (merge/, four lanes),
# at NCH = 4 (as built) and NCH = 8 (the widening), on the same part, period and
# synth -> opt -> place -> phys_opt -> route flow as ooc_roccmoon.tcl, so the rows compare
# directly with that file's r_eng4/r_eng8 (which are revision 2a WITHOUT the lanes).
set here [file dirname [file normalize [info script]]]
set root  "$here/.."
set outdir "$here/ooc_out_merge"
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
set rtl [list \
  $root/roccmoon/merge/mbxr_engine.v $root/roccmoon/merge/mbxr_lanes.v \
  $root/roccmoon/attn_unit/mbxa_unit.v $root/roccmoon/attn_unit/mbxa_rq.v \
  $root/roccmoon/smx_lane/mbxr_smx.v $root/roccmoon/ln_lane/mbxr_ln.v \
  $root/roccmoon/lut_lane/mbxl_lut.v \
  $root/roccmoon/mbxr_tseq.v $root/roccmoon/mbxr_datapath.v $root/roccmoon/mbxr_st.v \
  $root/roccmoon/mbxd_spad2.v $root/roccmoon/mbxr_ooc_wrap.v \
  $root/rocc/mbxd_dma.v $root/rocc/mbx_mac.v]
set rows {{m_eng4 4} {m_eng8 8}}
set_msg_config -id {Synth 8-3848} -new_severity ERROR
# B96: PORT WIDTH MISMATCH IS AN ERROR HERE, AND THIS LINE IS WHY THE FILE EXISTS.
# Synth 8-689 is a WARNING by default.  At NCH = 8 `mbxr_lanes` drove a 256-bit `acc` into
# `mbxa_core`'s hard-coded 128-bit port -- mbxa_core was never given the NCH parameter -- and
# every m_eng8 row this script ever produced was measured on a design with the attention lane's
# accumulator silently truncated to its low 128 bits.  One warning in a 2,000-line log.
# A width mismatch on a parameterised bus is never benign in a widening experiment.
set_msg_config -id {Synth 8-689} -new_severity ERROR
proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9.\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}
set summary {}
foreach r $rows {
  lassign $r label nch
  create_project -in_memory -force -part $part
  read_verilog $rtl
  synth_design -top mbxr_ooc_wrap -part $part -mode out_of_context -generic NCH=$nch
  create_clock -name clk -period $period [get_ports clk]
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
  report_utilization -hierarchical -hierarchical_depth 4 -file $outdir/${label}_hier.rpt
  set pth [lindex [get_timing_paths -delay_type max -max_paths 1 -from [all_registers] -to [all_registers]] 0]
  set row [list $label [util_row $outdir/${label}_util.rpt "Slice LUTs"] \
             [util_row $outdir/${label}_util.rpt "Slice Registers"] \
             [util_row $outdir/${label}_util.rpt "DSPs"] \
             [util_row $outdir/${label}_util.rpt "Block RAM Tile"] \
             [format %.3f [get_property SLACK $pth]] [get_property LOGIC_LEVELS $pth]]
  puts "MBXR_RESULT $row"
  lappend summary $row
  close_project
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram\tslack_ns\tlevels"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh

# B96: A SLACK DELTA BETWEEN TWO ARMS THAT BIND ON DIFFERENT CONES IS NOT A COST.
#
# Every timing figure this tree has ever quoted for NCH 4 -> 8 -- -1.903, -0.731, -0.055,
# -1.407, -0.257 -- was `slack(NCH8) - slack(NCH4)`, and NOT ONE of them is the cost of the
# widening.  The NCH = 4 arm binds on a 73-LOGIC-LEVEL path the widening never touches, so the
# subtraction returns the difference between two unrelated critical paths.  Three runs of
# near-identical RTL spanned 1.35 ns purely by moving which cone bound.
#
# The `levels` column was in this file's own output the whole time.  So: say it out loud.
if {[llength $summary] >= 2} {
  set l0 [lindex [lindex $summary 0] 6]
  set l1 [lindex [lindex $summary 1] 6]
  set s0 [lindex [lindex $summary 0] 5]
  set s1 [lindex [lindex $summary 1] 5]
  puts "MBXR_SLACK [lindex [lindex $summary 0] 0] $s0 ($l0 levels)  [lindex [lindex $summary 1] 0] $s1 ($l1 levels)"
  if {$l0 ne $l1} {
    puts "MBXR_CONE_MISMATCH: the two arms bind on DIFFERENT paths ($l0 vs $l1 logic levels)."
    puts "MBXR_CONE_MISMATCH: [format %.3f [expr {$s1 - $s0}]] ns is a DIFFERENCE OF TWO CRITICAL"
    puts "MBXR_CONE_MISMATCH: PATHS, NOT A COST. Do not quote it as the price of the change."
    puts "MBXR_CONE_MISMATCH: To price timing, constrain both arms to the SAME cone or compare"
    puts "MBXR_CONE_MISMATCH: post-route WNS of two full SoC builds."
  } else {
    puts "MBXR_SLACK_OK: both arms bind at $l0 logic levels; the delta is comparable."
  }
}
puts "MBXR_ALL_DONE"
