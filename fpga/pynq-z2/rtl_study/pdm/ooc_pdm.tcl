# Out-of-context area and timing for the PDM microphone blocks, in the style of
# rtl_study/pext/ooc_pext.tcl: synthesise AND place AND route each block alone on
# xc7z020clg400-1 at the real target period, and report the worst register-to-register
# path.  Synthesis-estimated delay is not good enough -- the critical path in the real
# design is 74% routing (PEXT_FEASIBILITY.md).
#
#   vivado -mode batch -source ooc_pdm.tcl
#   PDM_PERIOD=28.999 PDM_OUT=$PWD/ooc_out vivado -mode batch -source ooc_pdm.tcl
#
# Read `logic ns` and `levels`, not `routed ns`: an OOC block alone on an empty part
# is placed with no pressure, so its absolute route delay is an artefact.  The
# feasibility doc's one measured OOC->in-context transfer factor was 0.88x.
#
# The DSP column is load-bearing here.  pdm_fir_mac is written as an inferrable MACC
# and is MEANT to become exactly one DSP48E1; if inference silently fell back to LUT
# multipliers the block would still work and would cost a few hundred LUTs more, so
# the number is checked rather than assumed.

set here [file normalize [file dirname [info script]]]
cd $here
set outdir [expr {[info exists ::env(PDM_OUT)] ? $::env(PDM_OUT) : "$here/ooc_out"}]
set period [expr {[info exists ::env(PDM_PERIOD)] ? $::env(PDM_PERIOD) : 28.999}]
set only   [expr {[info exists ::env(PDM_ONLY)] ? $::env(PDM_ONLY) : ""}]
file mkdir $outdir
set part xc7z020clg400-1

set src [file normalize $here/../../src]
set rtl [list $src/pdm_cic4.v $src/pdm_fir_mac.v $src/pdm_dcblock.v \
              $src/pdm_mic_fifo.v $src/pdm_mic_capture.v $src/pdm_mic_core.v \
              $here/pdm_harness.v]

# label                top module
set duts {
  cic                  pdm_h_cic
  fir                  pdm_h_fir
  dcblock              pdm_h_dcblock
  fifo                 pdm_h_fifo
  capture              pdm_h_capture
  core                 pdm_h_core
}

proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}

# an undriven net synthesises to constant 0 with only a warning -- same promotion as
# the real build.  Set once: re-setting it after the promotion is itself an error.
set_msg_config -id {Synth 8-3848} -new_severity ERROR

set fsum [open $outdir/summary.tsv w]
puts $fsum "label\tperiod_ns\tlut\tlut_logic\tlut_mem\tff\tdsp\tbram36\tbram18\tslack_ns\tdatapath_ns\tlogic_ns\troute_ns\tlevels\tstart\tend"
set n 0

foreach {label top} $duts {
  if {$only ne "" && [lsearch $only $label] < 0} { continue }
  puts "=== PDM_OOC $label ($top) period=$period ==="
  create_project -in_memory -force -part $part
  read_verilog $rtl

  if {[catch {synth_design -top $top -part $part -mode out_of_context -include_dirs $src} err]} {
    puts "PDM_RESULT $label SYNTH_FAILED: $err"
    close_project
    continue
  }
  create_clock -name clk -period $period [get_ports clk]

  opt_design
  place_design -quiet
  phys_opt_design -quiet
  route_design -quiet

  set tag ${label}_p${period}
  report_utilization -file $outdir/${tag}_util.rpt
  report_timing -delay_type max -max_paths 5 -nworst 5 -path_type full_clock_expanded \
                -from [all_registers] -to [all_registers] -file $outdir/${tag}_timing.rpt

  set luts [util_row $outdir/${tag}_util.rpt "Slice LUTs"]
  set llog [util_row $outdir/${tag}_util.rpt "LUT as Logic"]
  set lram [util_row $outdir/${tag}_util.rpt "LUT as Memory"]
  set ffs  [util_row $outdir/${tag}_util.rpt "Slice Registers"]
  set dsps [util_row $outdir/${tag}_util.rpt "DSPs"]
  set br36 [util_row $outdir/${tag}_util.rpt "RAMB36/FIFO"]
  set br18 [util_row $outdir/${tag}_util.rpt "RAMB18"]

  set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1 \
                              -from [all_registers] -to [all_registers]]
  if {[llength $paths] == 0} {
    puts "PDM_RESULT $label lut=$luts ff=$ffs dsp=$dsps NO_INTERNAL_PATH"
    close_project
    continue
  }
  set pth   [lindex $paths 0]
  set slack [get_property SLACK $pth]
  set dd    [get_property DATAPATH_DELAY $pth]
  set lvl   [get_property LOGIC_LEVELS $pth]
  set spin  [get_property STARTPOINT_PIN $pth]
  set epin  [get_property ENDPOINT_PIN $pth]
  set fh [open $outdir/${tag}_timing.rpt r]; set t [read $fh]; close $fh
  set lg "?"; set rt "?"
  if {[regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns} $t -> _dd _lg _rt]} {
    set lg $_lg; set rt $_rt
  }
  puts [format "PDM_RESULT %s period=%s lut=%s lutlogic=%s lutmem=%s ff=%s dsp=%s bram36=%s bram18=%s slack=%.3f dpd=%.3f logic=%s route=%s levels=%s" \
        $label $period $luts $llog $lram $ffs $dsps $br36 $br18 $slack $dd $lg $rt $lvl]
  puts $fsum [format "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%.3f\t%s\t%s\t%s\t%s\t%s" \
        $label $period $luts $llog $lram $ffs $dsps $br36 $br18 $slack $dd $lg $rt $lvl $spin $epin]
  flush $fsum
  incr n
  close_project
}
close $fsum
puts "PDM_ALL_DONE period=$period n=$n -> $outdir/summary.tsv"
exit
