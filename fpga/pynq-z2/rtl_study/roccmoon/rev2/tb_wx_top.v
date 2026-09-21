// SPDX-License-Identifier: Apache-2.0
// Test top for mbxr_wx: both sides of the crossing and a stand-in for the lane's DMA whose load
// length, beats and errors the C++ testbench chooses.  tb_wx.cpp drives two unrelated clocks.
module tb_wx_top #(parameter ASYNC = 1) (
  input  wire        clk, rst, wclk, wrst,
  input  wire        accept, clr_count,
  output wire        busy, err_pulse,
  output wire [47:0] beats,
  output wire        start,
  input  wire        dma_busy, dma_beat, dma_err
);
  wire x_req, x_done, x_err_tog, x_rdy, rdy_core; wire [31:0] x_g; wire [7:0] x_inf, inf_core;
  mbxr_wx_core #(.ASYNC(ASYNC)) u_c (.clk(clk), .rst(rst), .accept(accept), .busy(busy),
    .clr_count(clr_count), .beats(beats), .err_pulse(err_pulse), .inflight(inf_core),
    .x_req(x_req), .x_done(x_done), .x_beats_gray(x_g), .x_err_tog(x_err_tog), .x_inflight(x_inf), .x_ready(x_rdy), .lane_ready(rdy_core));
  mbxr_wx_half #(.ASYNC(ASYNC)) u_h (.wclk(wclk), .wrst(wrst), .x_req(x_req), .quiet(1'b1), .x_done(x_done),
    .x_beats_gray(x_g), .x_err_tog(x_err_tog), .x_inflight(x_inf), .x_ready(x_rdy), .start(start),
    .busy(dma_busy), .beat(dma_beat), .err(dma_err), .inflight(8'd0));
endmodule
