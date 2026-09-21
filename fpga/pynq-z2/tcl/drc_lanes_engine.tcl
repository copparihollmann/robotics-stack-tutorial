# A DRC-ONLY run on the merged engine, out of context: synth_design + opt_design on
# rtl_study/roccmoon/merge/ and the two lane directories, with opt_design NOT quiet.
#
# Why this exists.  The first 0x5A5A0029 build stopped an hour in on
#   ERROR: [DRC MDRV-1] Multiple Driver Nets: ... u_ln/UNCONN_OUT has multiple drivers
# -- mbxr_ln.v drove one error register from two always blocks.  Verilator merges same-clock
# multiple drivers and simulates them, so 151 M elements and 15 of 15 mutants passed on RTL
# that cannot be synthesised; and the lane's own out-of-context run called `opt_design -quiet`,
# which turned the DRC error into silence and went on to place, route and report numbers.
# See docs/LAYERNORM_LANE.md s15.  This finds the whole class in about four minutes.
set R [file normalize [file dirname [info script]]/../rtl_study]
create_project -in_memory -force -part xc7z020clg400-1
read_verilog [list $R/roccmoon/merge/mbxr_engine.v $R/roccmoon/merge/mbxr_lanes.v \
  $R/roccmoon/attn_unit/mbxa_unit.v $R/roccmoon/attn_unit/mbxa_rq.v \
  $R/roccmoon/smx_lane/mbxr_smx.v $R/roccmoon/ln_lane/mbxr_ln.v \
  $R/roccmoon/lut_lane/mbxl_lut.v \
  $R/roccmoon/mbxr_tseq.v $R/roccmoon/mbxr_datapath.v $R/roccmoon/mbxr_st.v \
  $R/roccmoon/mbxd_spad2.v $R/rocc/mbxd_dma.v $R/rocc/mbx_mac.v]
synth_design -top mbxr_engine -part xc7z020clg400-1 -mode out_of_context
create_clock -name clk -period 28.999 [get_ports clk]
if {[catch {opt_design} msg]} {
  puts "ENGINE_DRC_FAILED: $msg"
  exit 1
}
puts "ENGINE_DRC_CLEAN"
exit
