// ---------------------------------------------------------------------------
// Out-of-context harnesses for the TACIT trace encoder and its branch predictor.
//
// The DUTs are the GENERATED Verilog from out/gensrc/<config>/gen-collateral,
// not a hand-written model, so an OOC number here is the same RTL the bitstream
// carries.  Everything crossing the harness boundary is registered, so the OOC
// result is the block's own logic and not a pile of IBUF/OBUF paths.
//
// Two tops:
//   bp_ooc_harness   DSCBranchPredictor on its own
//   enc_ooc_harness  the whole TacitEncoder (predictor, queues, packetizer)
// ---------------------------------------------------------------------------

module bp_ooc_harness (
  input         clk,
  input         rst,
  input  [63:0] pc_in,
  input         uv_in,
  input         ut_in,
  output        resp_out
);
  reg [63:0] pc_q;
  reg        uv_q, ut_q, resp_q;
  wire       resp_w;

  always @(posedge clk) begin
    pc_q   <= pc_in;
    uv_q   <= uv_in;
    ut_q   <= ut_in;
    resp_q <= resp_w;
  end
  assign resp_out = resp_q;

  DSCBranchPredictor dut (
    .clock          (clk),
    .reset          (rst),
    .io_req_pc      (pc_q),
    .io_resp        (resp_w),
    .io_update_valid(uv_q),
    .io_update_taken(ut_q)
  );
endmodule

module enc_ooc_harness (
  input         clk,
  input         rst,
  input         enable_in,
  input  [31:0] bp_mode_in,
  input         iretire_in,
  input  [63:0] iaddr_in,
  input  [3:0]  itype_in,
  input  [63:0] time_in,
  input         out_ready_in,
  output        stall_out,
  output        out_valid_out,
  output [7:0]  out_bits_out
);
  reg        enable_q, iretire_q, out_ready_q;
  reg [31:0] bp_mode_q;
  reg [63:0] iaddr_q, time_q;
  reg [3:0]  itype_q;
  reg        stall_q, out_valid_q;
  reg [7:0]  out_bits_q;

  wire       stall_w, out_valid_w;
  wire [7:0] out_bits_w;

  always @(posedge clk) begin
    enable_q    <= enable_in;
    bp_mode_q   <= bp_mode_in;
    iretire_q   <= iretire_in;
    iaddr_q     <= iaddr_in;
    itype_q     <= itype_in;
    time_q      <= time_in;
    out_ready_q <= out_ready_in;
    stall_q     <= stall_w;
    out_valid_q <= out_valid_w;
    out_bits_q  <= out_bits_w;
  end
  assign stall_out     = stall_q;
  assign out_valid_out = out_valid_q;
  assign out_bits_out  = out_bits_q;

  // With the DSC branch predictor gated off at elaboration, firtool drops the
  // io_control_bp_mode port from TacitEncoder entirely -- nothing consumes it any
  // more. Define TACIT_NO_BP to measure that flavour.
  TacitEncoder dut (
    .clock                 (clk),
    .reset                 (rst),
    .io_control_enable     (enable_q),
`ifndef TACIT_NO_BP
    .io_control_bp_mode    (bp_mode_q),
`endif
    .io_in_group_0_iretire (iretire_q),
    .io_in_group_0_iaddr   (iaddr_q),
    .io_in_group_0_itype   (itype_q),
    .io_in_time            (time_q),
    .io_stall              (stall_w),
    .io_out_ready          (out_ready_q),
    .io_out_valid          (out_valid_w),
    .io_out_bits           (out_bits_w)
  );
endmodule
