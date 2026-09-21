# extract_floorplan_zynq.tcl -- Vivado batch extractor for the PYNQ-Z1/Z2 floorplan plot.
#
# Zynq-7000 variant of the Arty-200T tool in the riskybird tree. The partition is
# different because this SoC is different: there is no MIG (the DDR controller is hard
# silicon in the PS, so it places nothing in fabric), there is no Gemmini or Saturn, and
# the interesting split is the big/LITTLE tile pair plus the TACIT trace logic that lives
# INSIDE each tile and is worth pulling out on its own -- it is a larger LUT block than
# the L2.
#
# Opens a POST-ROUTE checkpoint and emits, into an output directory, everything the
# plotter needs: the block partition as placed-site lists, plus per-block utilisation
# re-derived from the checkpoint. Nothing is hardcoded; the numbers in the plot legend
# come back out of the DCP.
#
# Usage:
#   vivado -mode batch -source extract_floorplan_zynq.tcl -tclargs <post_route.dcp> <outdir>

if {[llength $argv] < 2} {
    puts "ERROR: usage: vivado -mode batch -source extract_floorplan_zynq.tcl -tclargs <post_route.dcp> <outdir>"
    exit 1
}
set dcp    [lindex $argv 0]
set outdir [lindex $argv 1]
if {![file exists $dcp]} { puts "ERROR: DCP not found: $dcp"; exit 1 }
file mkdir $outdir

# ---- block partition: id -> get_cells filter (over IS_PRIMITIVE && LOC != "") ----
#
# MUTUALLY EXCLUSIVE and EXHAUSTIVE -- every placed primitive lands in exactly one block,
# and `uncore` is defined as the negation of all the others so nothing is silently lost.
#
# TACIT and the RoCC accelerator are carved out BY MODULE TYPE (the hierarchical cell's
# REF_NAME), not by instance name. Instance names are Scala-generated (`applyOrElse`,
# `applyOrElse_1`, ...) and shift whenever another tile-attached module is added: on the
# roccmoon build hart 1's `applyOrElse` is the RoccMoonShim and its TACIT encoder and sink
# are `applyOrElse_1` / `applyOrElse_2`, so the old name patterns put the shim in `tacit`
# and hart 1's TraceSinkDMA in `hart1`. Module names do not move.
#
#   tacit : TacitEncoder*, TraceSinkDMA*, TraceEncoderController*   (inside each tile)
#   accel : RoccMoonEngine* (injected in the sbus scope, so it would otherwise read as
#           "buses"), its two sbus couplers, and the tile-side RoCC shim, command router
#           and response queue. Empty on builds without the engine -- the plotter then
#           leaves it out of the legend.
proc hier_insts {refpats} {
    set out {}
    foreach rp $refpats {
        foreach c [get_cells -hierarchical -quiet -filter "IS_PRIMITIVE == 0 && REF_NAME =~ \"$rp\""] {
            lappend out [get_property NAME $c]
        }
    }
    return [lsort -unique $out]
}
# (pattern, negation) over the primitives under a set of hierarchical instances. An empty
# set gives a pattern that matches nothing and a negation that excludes nothing.
proc under_filters {insts} {
    if {[llength $insts] == 0} { return [list {NAME == "__none__"} {NAME != "__none__"}] }
    set pos {}; set neg {}
    foreach i $insts { lappend pos "NAME =~ \"$i/*\""; lappend neg "NAME !~ \"$i/*\"" }
    return [list "([join $pos { || }])" "([join $neg { && }])"]
}

# tile_prci_domain is hart 0 (big, +P-ext); tile_prci_domain_1 is hart 1 (LITTLE).
# The trailing slash keeps `tile_prci_domain/` from matching `tile_prci_domain_1/`.
proc define_blocks {} {
    global B
    set tacit_insts [hier_insts {TacitEncoder* TraceSinkDMA* TraceEncoderController*}]
    set accel_insts [hier_insts {RoccMoonEngine* RoccMoonShim* RoccCommandRouter* TLInterconnectCoupler_sbus_from_roccmoon* Queue2_RoCCResponse*}]
    lassign [under_filters $tacit_insts] tacitpat tacitneg
    lassign [under_filters $accel_insts] accelpat accelneg
    puts "---- tacit instances: [llength $tacit_insts]   accel instances: [llength $accel_insts]"
    foreach i [concat $tacit_insts $accel_insts] { puts "----   carve: $i ([get_property REF_NAME [get_cells $i]])" }

    set B(tacit)  $tacitpat
    set B(accel)  $accelpat
    set B(hart0)  "(NAME =~ \"*/tile_prci_domain/*\"   && $tacitneg && $accelneg)"
    set B(hart1)  "(NAME =~ \"*/tile_prci_domain_1/*\" && $tacitneg && $accelneg)"
    set B(l2)     {NAME =~ "*/coh_wrapper/*"}
    set B(mic)    {NAME =~ "*/micLM/*"}
    set B(buses)  "((NAME =~ \"*/sbus/*\" || NAME =~ \"*/cbus/*\" || NAME =~ \"*/pbus/*\" || NAME =~ \"*/mbus/*\" || NAME =~ \"*/fbus/*\") && $accelneg)"
    set B(uncore) "(NAME !~ \"*/tile_prci_domain/*\" && NAME !~ \"*/tile_prci_domain_1/*\" && NAME !~ \"*/coh_wrapper/*\" && NAME !~ \"*/micLM/*\" && NAME !~ \"*/sbus/*\" && NAME !~ \"*/cbus/*\" && NAME !~ \"*/pbus/*\" && NAME !~ \"*/mbus/*\" && NAME !~ \"*/fbus/*\" && $accelneg)"
}

set order {uncore buses l2 hart1 hart0 tacit accel mic}

puts "==== opening checkpoint: $dcp ===="
open_checkpoint $dcp
set part [get_property PART [current_design]]
define_blocks

# Derive a config name from the build directory (…/build_rocket_mic_z1/post_route.dcp).
set cfg [file tail [file dirname $dcp]]

set fh [open "$outdir/meta.txt" w]
puts $fh "PART $part"
puts $fh "CONFIG $cfg"
puts $fh "DCP $dcp"
puts $fh "DATE [clock format [clock seconds]]"
close $fh
puts "part=$part config=$cfg"

proc grep1 {file re {dflt 0}} {
    if {![file exists $file]} { return $dflt }
    set f [open $file r]; set data [read $f]; close $f
    foreach line [split $data "\n"] {
        if {[regexp $re $line -> v]} { return $v }
    }
    return $dflt
}

set csv [open "$outdir/blocks_util.csv" w]
puts $csv "block,luts,ff,bram_tiles,dsp,cells"

set total_placed 0
foreach b $order {
    set cells [get_cells -hierarchical -filter "IS_PRIMITIVE && LOC != \"\" && $B($b)"]
    set n [llength $cells]
    incr total_placed $n
    puts "---- block $b : $n placed primitives ----"

    set ph [open "$outdir/cells_$b.txt" w]
    if {$n > 0} { puts $ph [join [get_property LOC $cells] "\n"] }
    close $ph

    set luts 0; set ff 0; set bram 0; set dsp 0
    if {$n > 0} {
        set rpt "$outdir/util_$b.rpt"
        report_utilization -cells $cells -file $rpt
        set luts [grep1 $rpt {\|\s*Slice LUTs\s*\|\s*(\d+)\s*\|}]
        set ff   [grep1 $rpt {\|\s*Register as Flip Flop\s*\|\s*(\d+)\s*\|}]
        set bram [grep1 $rpt {\|\s*Block RAM Tile\s*\|\s*([\d.]+)\s*\|}]
        set dsp  [grep1 $rpt {\|\s*DSPs\s*\|\s*(\d+)\s*\|}]
    }
    puts $csv "$b,$luts,$ff,$bram,$dsp,$n"
}

# Partition check: the blocks must account for every placed primitive in the design.
set all [llength [get_cells -hierarchical -filter {IS_PRIMITIVE && LOC != ""}]]
puts "==== partition: $total_placed of $all placed primitives covered ===="
if {$total_placed != $all} {
    puts "ERROR: partition is not exhaustive -- $all placed, $total_placed covered."
    puts "       A cell matched no block, or matched two. Fix the filters above."
    exit 1
}

set full "$outdir/util_full.rpt"
report_utilization -file $full
set dl [grep1 $full {\|\s*Slice LUTs\s*\|\s*(\d+)\s*\|}]
set df [grep1 $full {\|\s*Register as Flip Flop\s*\|\s*(\d+)\s*\|}]
set db [grep1 $full {\|\s*Block RAM Tile\s*\|\s*([\d.]+)\s*\|}]
set dd [grep1 $full {\|\s*DSPs\s*\|\s*(\d+)\s*\|}]
set al [grep1 $full {\|\s*Slice LUTs\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|}]
set af [grep1 $full {\|\s*Register as Flip Flop\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|}]
set ab [grep1 $full {\|\s*Block RAM Tile\s*\|\s*[\d.]+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|}]
set ad [grep1 $full {\|\s*DSPs\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|}]
puts $csv "DEVICE,$dl,$df,$db,$dd,0"
puts $csv "DEVICE_AVAIL,$al,$af,$ab,$ad,0"
close $csv

puts "==== EXTRACT DONE -> $outdir ===="
