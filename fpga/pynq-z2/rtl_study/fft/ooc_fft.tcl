# ---------------------------------------------------------------------------
# Out-of-context area AND timing for the FFT / front-end assist candidates.
#
#   vivado -mode batch -source ooc_fft.tcl
#
# Same part and the same synth -> opt -> place -> phys_opt -> route flow as
# rtl_study/pext/ooc_pext.tcl, so the numbers are directly comparable with
# PEXT_FEASIBILITY.md's tables.  The default period is 28.999 ns -- the clock the
# shipped P-ext bitstream actually runs at (34.4828 MHz), not the 25 or 28.571 ns
# the P-ext study used before the clock arithmetic was settled.
#
# Env:
#   FFT_ONLY    space-separated subset of labels to run (default: all)
#   FFT_OUT     output directory (default: ./ooc_out)
#   FFT_PERIOD  clock period in ns (default: 28.999)
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set outdir [expr {[info exists ::env(FFT_OUT)] ? $::env(FFT_OUT) : "$here/ooc_out"}]
set period [expr {[info exists ::env(FFT_PERIOD)] ? $::env(FFT_PERIOD) : 28.999}]
set only   [expr {[info exists ::env(FFT_ONLY)] ? $::env(FFT_ONLY) : ""}]
file mkdir $outdir

set part xc7z020clg400-1

set rtl [list $here/fft_units.v]

# label                 FFT_DUT
set duts {
  {null       fft_v_null}
  {qmul1      fft_v_qmul1}
  {qmul2      fft_v_qmul2}
  {cmul       fft_v_cmul}
  {bf2        fft_v_bf2}
  {melmac     fft_v_melmac}
}

proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}

# an undriven net synthesises to constant 0 with only a warning -- same promotion
# the pext flow uses, and the same reason: a silently tied-off port would make a
# block measure small for the wrong reason.
set_msg_config -id {Synth 8-3848} -new_severity ERROR

set summary {}
foreach dd $duts {
  lassign $dd label dut
  if {$only ne "" && [lsearch -exact $only $label] < 0} { continue }
  puts "=============== FFT_RUN $label (dut=$dut) ==============="

  create_project -in_memory -force -part $part
  read_verilog $rtl

  if {[catch {synth_design -top fft_harness -part $part -mode out_of_context \
                -verilog_define "FFT_DUT=$dut"} err]} {
    puts "FFT_RESULT $label SYNTH_FAILED: $err"
    close_project
    continue
  }

  create_clock -name clk -period $period [get_ports clk]

  opt_design
  place_design -quiet
  phys_opt_design -quiet
  route_design -quiet

  report_utilization -file $outdir/${label}_util.rpt
  report_timing -delay_type max -max_paths 5 -nworst 5 -path_type full_clock_expanded \
                -from [all_registers] -to [all_registers] -file $outdir/${label}_timing.rpt

  set luts [util_row $outdir/${label}_util.rpt "Slice LUTs"]
  set ffs  [util_row $outdir/${label}_util.rpt "Slice Registers"]
  set dsps [util_row $outdir/${label}_util.rpt "DSPs"]
  set lram [util_row $outdir/${label}_util.rpt "LUT as Memory"]
  set llog [util_row $outdir/${label}_util.rpt "LUT as Logic"]
  set bram [util_row $outdir/${label}_util.rpt "Block RAM Tile"]

  set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1 \
               -from [all_registers] -to [all_registers]]
  if {[llength $paths] == 0} {
    puts "FFT_RESULT $label lut=$luts ff=$ffs dsp=$dsps NO_TIMING_PATH"
  } else {
    set pth   [lindex $paths 0]
    set slack [get_property SLACK $pth]
    set dd2   [get_property DATAPATH_DELAY $pth]
    set lvl   [get_property LOGIC_LEVELS $pth]
    set src   [get_property STARTPOINT_PIN $pth]
    set dst   [get_property ENDPOINT_PIN $pth]
    set fh [open $outdir/${label}_timing.rpt r]; set t [read $fh]; close $fh
    set lg "?"; set rt "?"
    if {[regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns} $t -> _dd _lg _rt]} {
      set lg $_lg; set rt $_rt
    }
    puts [format "FFT_RESULT %s lut=%s lutlogic=%s lutmem=%s ff=%s dsp=%s bram=%s slack=%.3f dpd=%.3f logic=%s route=%s levels=%s" \
          $label $luts $llog $lram $ffs $dsps $bram $slack $dd2 $lg $rt $lvl]
    lappend summary [list $label $luts $llog $lram $ffs $dsps $bram $slack $dd2 $lg $rt $lvl $src $dst]
  }
  close_project
}

set fh [open $outdir/summary.tsv w]
puts $fh "label\tlut\tlut_logic\tlut_mem\tff\tdsp\tbram\tslack_ns\tdatapath_ns\tlogic_ns\troute_ns\tlevels\tstart\tend"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "FFT_ALL_DONE period=$period n=[llength $summary] -> $outdir/summary.tsv"
exit
