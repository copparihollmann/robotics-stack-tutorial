# Out-of-context area and timing of the big core's multiplier options, same part, period and flow
# as rtl_study/roccmoon/ooc_roccmoon.tcl.
#   muldiv_today  rocket-chip's generated MulDiv of 0x5A5A0010's big core (mulUnroll 8, early out)
#   pmul64        PipelinedMultiplier(64, 2), transcribed (mulUnroll = 64 selects it; div stays in MulDiv)
#   pmul_gen      PipelinedMultiplier as GENERATED for 0x5A5A0011's big core (replaces pmul64's estimate)
#   div_gen       MulDiv as GENERATED for 0x5A5A0011's big core: mulUnroll = 0, the divider only
set here [file dirname [file normalize [info script]]]
set outdir "$here/ooc_out"
set period 28.999
set part xc7z020clg400-1
file mkdir $outdir
proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9.\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}
set summary {}
set rows [list \
  [list muldiv_today muldiv_ooc  [list MulDiv_big_roccmoon.sv pmul64.v]] \
  [list pmul64       pmul64      [list MulDiv_big_roccmoon.sv pmul64.v]] \
  [list pmul_gen     pmulgen_ooc [list PipelinedMultiplier_roccmoonmul.sv pmulgen_ooc.v]] \
  [list div_gen      muldiv_ooc  [list MulDiv_divonly_roccmoonmul.sv pmul64.v]]]
if {[info exists ::env(MULDIV_ROWS)]} {
  set rows [lsearch -all -inline -regexp $rows "^($::env(MULDIV_ROWS)) "]
}
foreach r $rows {
  lassign $r label top files
  create_project -in_memory -force -part $part
  set paths {}
  foreach f $files { lappend paths $here/$f }
  read_verilog -sv $paths
  synth_design -top $top -part $part -mode out_of_context -verilog_define SYNTHESIS
  create_clock -name clk -period $period [get_ports clock]
  opt_design; place_design -quiet; phys_opt_design -quiet; route_design -quiet
  report_utilization -file $outdir/${label}_util.rpt
  report_timing -delay_type max -max_paths 3 -nworst 1 -from [all_registers] -to [all_registers] -file $outdir/${label}_timing.rpt
  set pth [lindex [get_timing_paths -delay_type max -max_paths 1 -from [all_registers] -to [all_registers]] 0]
  set row [list $label [util_row $outdir/${label}_util.rpt "Slice LUTs"] [util_row $outdir/${label}_util.rpt "Slice Registers"] \
             [util_row $outdir/${label}_util.rpt "DSPs"] [format %.3f [get_property SLACK $pth]] \
             [format %.3f [get_property DATAPATH_DELAY $pth]] [get_property LOGIC_LEVELS $pth]]
  puts "MULDIV_RESULT $row"
  lappend summary $row
  close_project
}
# summary.tsv keeps every row ever run: a partial run (MULDIV_ROWS) replaces only its own rows
set keep {}
if {[file exists $outdir/summary.tsv]} {
  set fh [open $outdir/summary.tsv r]
  foreach line [lrange [split [string trim [read $fh]] "\n"] 1 end] {
    set lbl [lindex [split $line "\t"] 0]
    set redone 0
    foreach s $summary { if {[lindex $s 0] eq $lbl} { set redone 1 } }
    if {!$redone} { lappend keep [split $line "\t"] }
  }
  close $fh
}
set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tff\tdsp\tslack_ns\tdatapath_ns\tlevels"
foreach s [concat $keep $summary] { puts $fh [join $s "\t"] }
close $fh
puts "MULDIV_ALL_DONE"
exit
