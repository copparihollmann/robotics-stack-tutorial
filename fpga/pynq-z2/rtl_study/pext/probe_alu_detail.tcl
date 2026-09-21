# Detailed anatomy of the EX-stage ALU path in the shipped routed checkpoint:
# how much of it is the ALU itself, and how much is everything else.
set dcp "$::env(IISWC_ROOT)/fpga/pynq-z2/build_rocket_smp_z1/post_route.dcp"
set outdir [expr {[info exists ::env(PEXT_OUT)] ? $::env(PEXT_OUT) : "/tmp/pext_probe2"}]
file mkdir $outdir
open_checkpoint $dcp
set core u_soc/system/tile_prci_domain/element_reset_domain_rockettile/core

# the full path into the ALU's output register, with every cell listed
report_timing -delay_type max -max_paths 3 -nworst 3 \
  -to [get_cells -hier -filter "NAME =~ ${core}/mem_reg_wdata_reg*"] \
  -file $outdir/alu_path.rpt
# the D$ address path, the ALU's one same-cycle combinational consumer
report_timing -delay_type max -max_paths 2 \
  -to [get_cells -quiet -hier -filter "NAME =~ *rockettile/dcache/*s1_*reg*"] \
  -file $outdir/dcache_addr.rpt

# how big is the ALU, in context?
foreach pat {*core/alu* *core/*alu*} {
  set c [get_cells -quiet -hier -filter "NAME =~ ${core}/*alu*"]
  puts "PROBE2 alu_cells n=[llength $c]"
  break
}
# LUT/FF inside the big core, for scale
set lut [llength [get_cells -quiet -hier -filter "NAME =~ ${core}/* && PRIMITIVE_GROUP == LUT"]]
set ff  [llength [get_cells -quiet -hier -filter "NAME =~ ${core}/* && PRIMITIVE_GROUP == FLOP_LATCH"]]
puts "PROBE2 core_lut=$lut core_ff=$ff"

# the integer register file: find the Mem that has 2 read ports
set rfmem [get_cells -quiet -hier -filter "NAME =~ ${core}/*Memory*" ]
puts "PROBE2 rf_mem_cells=[llength $rfmem]"
array unset k
foreach c [get_cells -quiet -hier -filter "NAME =~ ${core}/* && PRIMITIVE_SUBGROUP == dram"] {
  set n [get_property NAME $c]
  regexp {([^/]+)/[^/]+$} $n -> parent
  incr k($parent)
}
foreach p [lsort [array names k]] { puts "PROBE2 dram_parent $p = $k($p)" }
puts "PROBE2_DONE"
exit
