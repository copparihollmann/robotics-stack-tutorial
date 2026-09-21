# ---------------------------------------------------------------------------
# Out-of-context area and timing of engine revision 2a (rtl_study/roccmoon/rev2), with
# revision 1 rebuilt in the same session as the control.  Same part, period and flow as
# ../ooc_roccmoon.tcl, and the same register-everything wrapper (mbxr_ooc_wrap.v), so the
# rows compare directly.  Also records the scratchpad banks' inferred primitives.
#
#   scripts/lib/with_lock.sh vivado vivado -mode batch -source ooc_rev2.tcl
# Reports go to $MBXR_OOC_OUT (default: ./ooc_out, uncommitted; copy them to archive/).
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set up   [file dirname $here]
set outdir [expr {[info exists ::env(MBXR_OOC_OUT)] ? $::env(MBXR_OOC_OUT) : "$here/ooc_out"}]
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
set common [list $up/mbxr_tseq.v $up/mbxr_datapath.v $up/mbxr_ooc_wrap.v $up/../rocc/mbxd_dma.v $up/../rocc/mbx_mac.v]
set rows [list \
  [list r1_eng4 [concat [list $up/mbxr_engine.v $up/mbxr_st.v $up/../rocc/mbxd_spad.v] $common]] \
  [list r2a_eng4 [concat [list $here/mbxr_engine.v $here/mbxr_st.v $here/mbxd_spad2.v] $common]] ]
proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9.\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}
set summary {}
foreach r $rows {
  lassign $r label rtl
  create_project -in_memory -force -part $part
  read_verilog $rtl
  synth_design -top mbxr_ooc_wrap -part $part -mode out_of_context -generic NCH=4
  create_clock -name clk -period $period [get_ports clk]
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
  report_utilization -hierarchical -hierarchical_depth 4 -file $outdir/${label}_hier.rpt
  report_ram_utilization -file $outdir/${label}_ram.rpt
  report_timing -delay_type max -max_paths 5 -nworst 1 -from [all_registers] -to [all_registers] \
    -file $outdir/${label}_timing.rpt
  set pth [lindex [get_timing_paths -delay_type max -max_paths 1 -from [all_registers] -to [all_registers]] 0]
  set ramb [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
  set lutram [util_row $outdir/${label}_util.rpt "LUT as Memory"]
  set row [list $label [util_row $outdir/${label}_util.rpt "Slice LUTs"] \
             [util_row $outdir/${label}_util.rpt "Slice Registers"] \
             [util_row $outdir/${label}_util.rpt "DSPs"] \
             [util_row $outdir/${label}_util.rpt "Block RAM Tile"] $ramb $lutram \
             [format %.3f [get_property SLACK $pth]] [format %.3f [get_property DATAPATH_DELAY $pth]] \
             [get_property LOGIC_LEVELS $pth] [get_property STARTPOINT_PIN $pth] [get_property ENDPOINT_PIN $pth]]
  puts "MBXR_RESULT $row"
  lappend summary $row
  close_project
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram_tiles\tramb36_cells\tlut_as_memory\tslack_ns\tdatapath_ns\tlevels\tstart\tend"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "MBXR_ALL_DONE"
exit
