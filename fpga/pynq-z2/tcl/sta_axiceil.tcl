# Static timing of a ROUTED axiceil checkpoint at other FCLK0 periods, and of the PS7 boundary.
#   vivado -mode batch -source tcl/sta_axiceil.tcl -tclargs <build dir> <period ns> [<period ns> ...]
#
# The lab runs a bitstream at a clock below the one it was timed at (FCLK0 = 1000/N MHz, set at
# run time).  Closure at that clock is read here, from the placed-and-routed netlist with the
# clock redefined, rather than inferred from WNS arithmetic.
set build [lindex $argv 0]
open_checkpoint $build/post_route.dcp
set pin [get_pins u_ps7/inst/PS7_i/FCLKCLK[0]]
foreach period [lrange $argv 1 end] {
  create_clock -name clk_fpga_0 -period $period $pin
  set wns [get_property SLACK [get_timing_paths -delay_type max]]
  set whs [get_property SLACK [get_timing_paths -delay_type min]]
  puts "STA_PERIOD $period WNS $wns WHS $whs"
  report_timing_summary -max_paths 5 -file $build/reports/sta_period_${period}.rpt
}
create_clock -name clk_fpga_0 -period 7.000 $pin
set ps [get_cells u_ps7/inst/PS7_i]
set to  [get_timing_paths -to   $ps -max_paths 1 -delay_type max]
set frm [get_timing_paths -from $ps -max_paths 1 -delay_type max]
puts "STA_PS7_BOUNDARY into_PS7 slack [get_property SLACK $to] datapath [get_property DATAPATH_DELAY $to] levels [get_property LOGIC_LEVELS $to] endpoint [get_property ENDPOINT_PIN $to]"
puts "STA_PS7_BOUNDARY from_PS7 slack [get_property SLACK $frm] datapath [get_property DATAPATH_DELAY $frm] levels [get_property LOGIC_LEVELS $frm] startpoint [get_property STARTPOINT_PIN $frm]"
report_timing -to $ps -max_paths 5 -file $build/reports/sta_into_ps7.rpt
report_timing -from $ps -max_paths 5 -file $build/reports/sta_from_ps7.rpt
exit
