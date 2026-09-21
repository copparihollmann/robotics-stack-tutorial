# Datapath simulation: self-test master vs behavioural AXI3 memory. No IP, no VIP.
set root [file normalize [file dirname [info script]]/..]
set out $root/build/sim_mem
file delete -force $out; file mkdir $out
cd $out
exec >@stdout 2>@stderr xvlog -sv $root/src/axi_dram_selftest.v $root/sim/axi3_slave_mem.v $root/sim/tb_axi3_mem.sv
exec >@stdout 2>@stderr xelab -debug off --timescale 1ns/1ps -top tb_axi3_mem -snapshot tb_snap
exec >@stdout 2>@stderr xsim tb_snap -runall
exit
