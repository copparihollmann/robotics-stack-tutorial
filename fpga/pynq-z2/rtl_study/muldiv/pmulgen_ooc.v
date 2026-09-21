// SPDX-License-Identifier: Apache-2.0
//
// Registers the ports of the GENERATED PipelinedMultiplier (PipelinedMultiplier_roccmoonmul.sv,
// from 0x5A5A0011's elaboration), so its OOC paths are register-to-register, as muldiv_ooc
// (pmul64.v) does for MulDiv.
module pmulgen_ooc (
  input  wire        clock, reset,
  input  wire        io_req_valid, io_req_bits_dw,
  input  wire [4:0]  io_req_bits_fn,
  input  wire [63:0] io_req_bits_in1, io_req_bits_in2,
  output reg  [63:0] io_resp_bits_data
);
  reg v, dw; reg [4:0] fn; reg [63:0] a, b;
  wire [63:0] d;
  always @(posedge clock) begin
    v <= io_req_valid; dw <= io_req_bits_dw; fn <= io_req_bits_fn; a <= io_req_bits_in1; b <= io_req_bits_in2;
    io_resp_bits_data <= d;
  end
  PipelinedMultiplier u (.clock(clock), .reset(reset), .io_req_valid(v), .io_req_bits_fn(fn),
                         .io_req_bits_dw(dw), .io_req_bits_in1(a), .io_req_bits_in2(b),
                         .io_resp_bits_data(d));
endmodule
