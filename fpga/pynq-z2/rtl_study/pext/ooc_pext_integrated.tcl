# ---------------------------------------------------------------------------
# Out-of-context area and timing for the INTEGRATED P-ext ALU.
#
#   vivado -mode batch -source ooc_pext_integrated.tcl
#
# This is the follow-up to ooc_pext.tcl, and it asks a different question. That
# script measured candidate datapaths bolted onto RocketALU with an extra result
# mux, because nothing was integrated yet. This one measures the module Chisel
# actually emitted with coreParams.usePExt = true -- the four ops live inside
# RocketALU's own MuxLookup, so there is no bolt-on mux to pay for.
#
# Four rows, each routed at BOTH candidate periods:
#
#   alu_base   RocketALU       from PynqZ2RocketBigLittleTacitConfig
#   alu_pext   RocketALU_pext  from PynqZ2RocketBigLittlePextTacitConfig, hart 0
#   ex_base    the whole EX stage around RocketALU
#   ex_pext    the whole EX stage around RocketALU_pext
#
# plus ex_none, the pext_ex_stage.v model the feasibility study used, as a
# cross-check that pext_integrated.v's transcription of the EX stage did not drift
# from it (ex_base and ex_none must land on the same numbers).
#
# Both ALUs are vendored firtool output, so this runs without a Chipyard install.
# Set CHIPYARD_GENSRC_PEXT / CHIPYARD_GENSRC to read a live elaboration instead.
#
# Env:
#   PEXT_OUT      output directory (default: ./ooc_int_out)
#   PEXT_PERIODS  space-separated clock periods in ns (default: "25.0 28.571")
#   PEXT_ONLY     space-separated subset of labels to run (default: all)
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set outdir  [expr {[info exists ::env(PEXT_OUT)]     ? $::env(PEXT_OUT)     : "$here/ooc_int_out"}]
set periods [expr {[info exists ::env(PEXT_PERIODS)] ? $::env(PEXT_PERIODS) : "25.0 28.571"}]
set only    [expr {[info exists ::env(PEXT_ONLY)]    ? $::env(PEXT_ONLY)    : ""}]
# -1 = let Vivado decide (the default). 0 = forbid DSP48E1 inference, which is the
# experiment that prices the DSPs: a combinational DSP48E1 has a large clock-to-out,
# and the four ops infer 18 of them, so "does a LUT array close faster" is a real
# question and not a style preference.
set maxdsp  [expr {[info exists ::env(PEXT_MAX_DSP)]  ? $::env(PEXT_MAX_DSP)  : -1}]
file mkdir $outdir

set part xc7z020clg400-1

# --- the two ALUs ----------------------------------------------------------
# A live generated-src tree wins; otherwise the vendored copies, which are what
# make this reproducible from this repo alone.
proc pick_alu {envvar cfg fallback} {
  global here
  if {[info exists ::env($envvar)]} {
    set p "$::env($envvar)/gen-collateral/RocketALU.sv"
    if {[file exists $p]} { return $p }
  }
  set gsroot [expr {[info exists ::env(CHIPYARD_GENSRC_ROOT)] ? $::env(CHIPYARD_GENSRC_ROOT)
                                                              : [file normalize $here/../../../../out/gensrc]}]
  set p "$gsroot/chipyard.harness.TestHarness.$cfg/gen-collateral/RocketALU.sv"
  if {[file exists $p]} { return $p }
  puts "NOTE: using vendored [file tail $fallback]"
  return $fallback
}

set alu_base [pick_alu CHIPYARD_GENSRC      PynqZ2RocketBigLittleTacitConfig \
                       $here/RocketALU_vendored.sv]
# The P-ext ALU is renamed RocketALU -> RocketALU_pext so both can live in one
# project. A live tree's copy is still called RocketALU, so rename it on the way in.
set alu_pext_src [pick_alu CHIPYARD_GENSRC_PEXT PynqZ2RocketBigLittlePextTacitConfig \
                           $here/RocketALU_pext_vendored.sv]
set alu_pext $alu_pext_src
if {[string first "_pext_vendored" $alu_pext_src] < 0} {
  set alu_pext $outdir/RocketALU_pext.sv
  set fi [open $alu_pext_src r]; set txt [read $fi]; close $fi
  regsub -all {\mRocketALU\M} $txt {RocketALU_pext} txt
  set fo [open $alu_pext w]; puts $fo $txt; close $fo
  puts "NOTE: renamed $alu_pext_src -> RocketALU_pext"
}
foreach f [list $alu_base $alu_pext] { if {![file exists $f]} { error "no ALU source: $f" } }
puts "ALU base: $alu_base"
puts "ALU pext: $alu_pext"

set rtl [list \
  $here/pext_harness.v $here/pext_integrated.v $here/pext_alu_ref.v \
  $here/pext_ex_stage.v \
  $here/pext_pdot8_lut.v $here/pext_pdot8_dsp.v $here/pext_pdot8_lut_p2.v \
  $here/pext_pmaxmin8.v $here/pext_paddsub8_sat.v $here/pext_prequant.v \
  $here/pext_pdot4_16.v $here/pext_reduce_ladder.v $here/pext_decomposed.v \
  $here/pext_simd_alu.v $here/pext_variants.v $here/pext_null.v \
  $here/pext_pdot8_dsp48.v $here/pext_mulcell.v \
  $alu_base $alu_pext]

# label   top-module          PEXT_DUT define ("-" when the top is the DUT)
set duts {
  {alu_base  pext_harness       pext_alu_only}
  {alu_pext  pext_harness       pext_alu_pext}
  {ex_base   pext_ex_int_base   -}
  {ex_pext   pext_ex_int_pext   -}
  {ex_none   pext_ex_none       -}
  {op_dot8   pext_harness       pext_alu_op_dot8}
  {op_max8   pext_harness       pext_alu_op_max8}
  {op_qmul   pext_harness       pext_alu_op_qmul}
  {op_clip8  pext_harness       pext_alu_op_clip8}
}

proc util_row {rpt name} {
  set fh [open $rpt r]; set txt [read $fh]; close $fh
  foreach line [split $txt "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\[0-9\]+)\\s+\\|" $line -> v]} { return $v }
  }
  return 0
}

# an undriven net synthesises to constant 0 with only a warning -- same promotion
# as the real build.
set_msg_config -id {Synth 8-3848} -new_severity ERROR

set summary {}
foreach period $periods {
  foreach d $duts {
    lassign $d label top define
    if {$only ne "" && [lsearch -exact $only $label] < 0} { continue }
    puts "=============== PEXT_RUN $label period=$period (top=$top) ==============="

    create_project -in_memory -force -part $part
    read_verilog -sv $rtl

    set args [list -top $top -part $part -mode out_of_context]
    if {$maxdsp >= 0} { lappend args -max_dsp $maxdsp }
    if {$define ne "-"} { lappend args -verilog_define "PEXT_DUT=$define" }
    if {[catch {synth_design {*}$args} err]} {
      puts "PEXT_RESULT $label period=$period SYNTH_FAILED: $err"
      close_project
      continue
    }

    create_clock -name clk -period $period [get_ports clk]
    # every I/O port is registered inside the DUT, so only reg -> reg matters.

    opt_design
    place_design -quiet
    phys_opt_design -quiet
    route_design -quiet

    set tag ${label}_p${period}[expr {$maxdsp >= 0 ? "_dsp$maxdsp" : ""}]
    report_utilization -file $outdir/${tag}_util.rpt
    report_timing -delay_type max -max_paths 5 -nworst 5 -path_type full_clock_expanded \
                  -from [all_registers] -to [all_registers] -file $outdir/${tag}_timing.rpt

    set luts [util_row $outdir/${tag}_util.rpt "Slice LUTs"]
    set ffs  [util_row $outdir/${tag}_util.rpt "Slice Registers"]
    set dsps [util_row $outdir/${tag}_util.rpt "DSPs"]

    set paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1 \
                 -from [all_registers] -to [all_registers]]
    if {[llength $paths] == 0} {
      puts "PEXT_RESULT $label period=$period lut=$luts ff=$ffs dsp=$dsps NO_TIMING_PATH"
      close_project
      continue
    }
    set pth   [lindex $paths 0]
    set slack [get_property SLACK $pth]
    set dd    [get_property DATAPATH_DELAY $pth]
    set lvl   [get_property LOGIC_LEVELS $pth]
    set fh [open $outdir/${tag}_timing.rpt r]; set t [read $fh]; close $fh
    set lg "?"; set rt "?"
    if {[regexp {Data Path Delay:\s+([0-9.]+)ns\s+\(logic ([0-9.]+)ns.*route ([0-9.]+)ns} $t -> _dd _lg _rt]} {
      set lg $_lg; set rt $_rt
    }
    puts [format "PEXT_RESULT %s period=%s maxdsp=%s lut=%s ff=%s dsp=%s slack=%.3f dpd=%.3f logic=%s route=%s levels=%s" \
          $label $period $maxdsp $luts $ffs $dsps $slack $dd $lg $rt $lvl]
    lappend summary [list $label $period $maxdsp $luts $ffs $dsps $slack $dd $lg $rt $lvl]
    close_project
  }
}

set sfx [expr {$maxdsp >= 0 ? "_dsp$maxdsp" : ""}]
set fh [open $outdir/summary$sfx.tsv w]
puts $fh "label\tperiod_ns\tmax_dsp\tlut\tff\tdsp\tslack_ns\tdatapath_ns\tlogic_ns\troute_ns\tlevels"
foreach s $summary { puts $fh [join $s "\t"] }
close $fh
puts "PEXT_ALL_DONE n=[llength $summary] -> $outdir/summary$sfx.tsv"
exit
