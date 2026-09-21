# ---------------------------------------------------------------------------
# Width-select datapath parameter study (mbxr_dpw.v), out of context, same part, period and
# flow as ooc_roccmoon.tcl:
#   dpw_m0  today's int8 contract rebuilt as the control (the datapath part of r_eng4)
#   dpw_m1  (b1) int16 x int8 on the same 32 MAC DSPs, 40-bit accumulator, per-channel requant
#   dpw_m2  (b2) as m1 with 16 products per lane (int16 at 32 MAC/cycle)
# No MAGIC, no bitstream.
#   scripts/lib/with_lock.sh vivado vivado -mode batch -source ooc_dpw.tcl
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set outdir "$here/ooc_out"
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
set rtl [list $here/mbxr_dpw.v $here/../rocc/mbx_mac.v]
set rows {{dpw_m0 0} {dpw_m1 1} {dpw_m2 2}}
proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9.\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}
set summary {}
foreach r $rows {
  lassign $r label mode
  create_project -in_memory -force -part $part
  read_verilog $rtl
  synth_design -top mbxr_dpw_ooc -part $part -mode out_of_context -generic NCH=4 -generic MODE=$mode
  create_clock -name clk -period $period [get_ports clk]
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
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
set fh [open $outdir/dpw_summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tbram\tslack_ns\tdatapath_ns\tlevels\tstart\tend"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "MBXR_ALL_DONE"
exit
