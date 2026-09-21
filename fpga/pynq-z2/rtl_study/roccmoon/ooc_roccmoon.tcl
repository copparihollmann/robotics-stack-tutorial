# ---------------------------------------------------------------------------
# Out-of-context area and timing of the engine as built (mbxr_engine), on the same part,
# period (28.999 ns = 34.4828 MHz) and synth -> opt -> place -> phys_opt -> route flow as
# rtl_study/rocc/ooc_rocc_d.tcl, so the rows compare directly with ooc_out_d/summary.tsv's
# d_eng4.  The in-context number that matters is the routed SoC's; this is the block.
#
#   scripts/lib/with_lock.sh vivado vivado -mode batch -source ooc_roccmoon.tcl
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set outdir "$here/ooc_out"
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
# rtl_study/ holds engine revision 2a since 2026-09-17; ooc_out/summary.tsv's r_eng* rows are
# revision 1 (the scratchpad was ../rocc/mbxd_spad.v).
set rtl [list $here/mbxr_engine.v $here/mbxr_tseq.v $here/mbxr_datapath.v $here/mbxr_st.v \
              $here/mbxr_ooc_wrap.v $here/../rocc/mbxd_dma.v $here/mbxd_spad2.v \
              $here/../rocc/mbx_mac.v]
set rows {{r_eng4 4} {r_eng2 2} {r_eng8 8}}
if {[info exists ::env(MBXR_ONLY)]} {
  set keep {}
  foreach r $rows { if {[lsearch -exact $::env(MBXR_ONLY) [lindex $r 0]] >= 0} { lappend keep $r } }
  set rows $keep
}
set_msg_config -id {Synth 8-3848} -new_severity ERROR
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
  report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/${label}_hier.rpt
  report_timing -delay_type max -max_paths 5 -nworst 1 -from [all_registers] -to [all_registers] \
    -file $outdir/${label}_timing.rpt
  set pth [lindex [get_timing_paths -delay_type max -max_paths 1 -from [all_registers] -to [all_registers]] 0]
  set row [list $label [util_row $outdir/${label}_util.rpt "Slice LUTs"] \
             [util_row $outdir/${label}_util.rpt "Slice Registers"] \
             [util_row $outdir/${label}_util.rpt "DSPs"] \
             [util_row $outdir/${label}_util.rpt "Block RAM Tile"] \
             [format %.3f [get_property SLACK $pth]] [format %.3f [get_property DATAPATH_DELAY $pth]] \
             [get_property LOGIC_LEVELS $pth] [get_property STARTPOINT_PIN $pth] [get_property ENDPOINT_PIN $pth]]
  puts "MBXR_RESULT $row"
  lappend summary $row
  close_project
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram\tslack_ns\tdatapath_ns\tlevels\tstart\tend"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "MBXR_ALL_DONE"
exit
