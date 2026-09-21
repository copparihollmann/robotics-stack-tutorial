# Simulate the PL -> S_AXI_HP0 -> PS memory path with Xilinx's Zynq-7000 VIP.
#   vivado -mode batch -source tcl/run_sim.tcl
# Expects the build project to exist (tcl/build_bitstream.tcl); reuses its ps7_0 IP.
set root [file normalize [file dirname [info script]]/..]
set build $root/build
set_param board.repoPaths [list $root/boards]
open_project $build/proj/pynqz2.xpr

add_files -fileset sim_1 -norecurse $root/sim/tb_hp0_dram.sv
set_property top tb_hp0_dram [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {false} -objects [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
puts "SIM_LAUNCHED"
exit
