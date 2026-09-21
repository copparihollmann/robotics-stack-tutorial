set root [file normalize [file dirname [info script]]/..]
set out $root/build/sim_bridge
file delete -force $out; file mkdir $out
cd $out
exec >@stdout 2>@stderr xvlog -sv $root/src/axi_dram_selftest.v $root/src/axi4_to_axi3.v \
     $root/sim/axi3_slave_mem.v $root/sim/tb_bridge.sv
exec >@stdout 2>@stderr xelab -debug off --timescale 1ns/1ps -top tb_bridge -snapshot br
exec >@stdout 2>@stderr xsim br -runall
exit
