// SPDX-License-Identifier: Apache-2.0
//
// rocket-chip's PipelinedMultiplier(width = 64, latency = 2), what RocketCore instantiates when
// MulDivParams.mulUnroll == xLen (RocketCore.scala:226, :567), transcribed from
// Multiplier.scala:186-213 for an out-of-context area and timing estimate.  NOT Chisel-generated:
// a faithful behavioural transcription, labelled as such in ROCC_DECOUPLED.md.
//
//   in   = Pipe(io.req)                          one register stage
//   prod = SInt(65) lhs * SInt(65) rhs          combinational
//   data = Mux(cmdHi, prod[127:64], Mux(cmdHalf, sext(prod[31:0]), prod[63:0]))
//   resp = Pipe(in, latency - 1)                 one register stage after the product
module pmul64 (
  input  wire        clock,
  input  wire        reset,
  input  wire        io_req_valid,
  input  wire [4:0]  io_req_bits_fn,
  input  wire        io_req_bits_dw,
  input  wire [63:0] io_req_bits_in1,
  input  wire [63:0] io_req_bits_in2,
  output reg         io_resp_valid,
  output reg  [63:0] io_resp_bits_data
);
  localparam FN_MUL = 5'd0, FN_MULH = 5'd1, FN_MULHSU = 5'd2, FN_MULHU = 5'd3;
  reg        in_valid;
  reg [4:0]  in_fn;
  reg        in_dw;
  reg [63:0] in1, in2;
  always @(posedge clock) begin
    in_valid <= io_req_valid;
    in_fn <= io_req_bits_fn; in_dw <= io_req_bits_dw;
    in1 <= io_req_bits_in1; in2 <= io_req_bits_in2;
  end
  wire cmdHi     = (in_fn == FN_MULH) || (in_fn == FN_MULHU) || (in_fn == FN_MULHSU);
  wire lhsSigned = (in_fn == FN_MULH) || (in_fn == FN_MULHSU);
  wire rhsSigned = (in_fn == FN_MULH);
  wire cmdHalf   = (in_dw == 1'b0);      // DW_32
  wire signed [64:0] lhs = {lhsSigned & in1[63], in1};
  wire signed [64:0] rhs = {rhsSigned & in2[63], in2};
  wire signed [129:0] prod = lhs * rhs;
  wire [63:0] muxed = cmdHi ? prod[127:64] : (cmdHalf ? {{32{prod[31]}}, prod[31:0]} : prod[63:0]);
  always @(posedge clock) begin
    io_resp_valid <= in_valid;
    io_resp_bits_data <= muxed;
  end
endmodule

// registers the ports of rocket-chip's generated MulDiv so its OOC paths are register-to-register
module muldiv_ooc (
  input  wire        clock, reset,
  input  wire        io_req_valid, io_req_bits_dw, io_kill, io_resp_ready,
  input  wire [4:0]  io_req_bits_fn, io_req_bits_tag,
  input  wire [63:0] io_req_bits_in1, io_req_bits_in2,
  output reg         io_req_ready, io_resp_valid,
  output reg  [63:0] io_resp_bits_data,
  output reg  [4:0]  io_resp_bits_tag
);
  reg v, dw, kill, rr; reg [4:0] fn, tag; reg [63:0] a, b;
  wire rq, rv; wire [63:0] d; wire [4:0] t;
  always @(posedge clock) begin
    v <= io_req_valid; dw <= io_req_bits_dw; kill <= io_kill; rr <= io_resp_ready;
    fn <= io_req_bits_fn; tag <= io_req_bits_tag; a <= io_req_bits_in1; b <= io_req_bits_in2;
    io_req_ready <= rq; io_resp_valid <= rv; io_resp_bits_data <= d; io_resp_bits_tag <= t;
  end
  MulDiv u (.clock(clock), .reset(reset), .io_req_ready(rq), .io_req_valid(v), .io_req_bits_fn(fn),
            .io_req_bits_dw(dw), .io_req_bits_in1(a), .io_req_bits_in2(b), .io_req_bits_tag(tag),
            .io_kill(kill), .io_resp_ready(rr), .io_resp_valid(rv), .io_resp_bits_data(d),
            .io_resp_bits_tag(t));
endmodule
