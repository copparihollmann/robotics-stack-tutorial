// -----------------------------------------------------------------------------
// Three RoCC units, from the smallest thing worth calling one to the largest
// thing still worth calling lean.
//
//   mbx_min   the tutorial demo.  Command decode, one 64-bit accumulator, one
//             8-lane int8 MAC fed straight from rs1/rs2.  NO memory port: it is
//             AccumulatorExample (LazyRoCC.scala:118-145) with MBP.DOT8 inside.
//             xd = 0 on the MAC op, so it issues 1/cycle and never touches the
//             writeback port or the scoreboard; one xd = 1 read at the end pays
//             the ~5-6 cycle round trip once.
//
//   mbx_lean  the real candidate.  Its own memory port with DEPTH outstanding
//             loads, a descriptor sequencer, a 4-channel broadcast MAC with the
//             shared-operand DSP packing, an accumulator file and the fused
//             quantised output stage that could not go in the ALU.
//
//   mbx_full  mbx_lean plus the im2col gather engine, i.e. everything the
//             convolution kernel does except the driver loops.
// -----------------------------------------------------------------------------

module mbx_min (
  input  wire        clk,
  input  wire        rst,
  input  wire        cmd_valid,
  input  wire [6:0]  cmd_funct,
  input  wire [63:0] cmd_rs1,
  input  wire [63:0] cmd_rs2,
  input  wire [4:0]  cmd_rd,
  input  wire        cmd_xd,
  output wire        cmd_ready,
  output wire        resp_valid,
  output wire [4:0]  resp_rd,
  output wire [63:0] resp_data,
  output wire        busy
);
  wire [63:0] acc;
  wire        do_mac = cmd_valid && (cmd_funct == 7'd0);
  wire        do_clr = cmd_valid && (cmd_funct == 7'd1);
  mbx_mac8xn_dsp #(.N(1), .PACK(0), .PIPE(0)) u_mac (
    .clk(clk), .en(do_mac), .clr(do_clr),
    .a(cmd_rs1), .w(cmd_rs2), .seed(64'd0), .acc(acc));

  reg rv; reg [4:0] rrd;
  always @(posedge clk) begin
    if (rst) rv <= 1'b0;
    else     rv <= cmd_valid && cmd_xd;
    if (cmd_valid && cmd_xd) rrd <= cmd_rd;
  end
  assign cmd_ready  = 1'b1;
  assign resp_valid = rv;
  assign resp_rd    = rrd;
  assign resp_data  = acc;
  assign busy       = 1'b0;
endmodule

module mbx_lean #(
  parameter DEPTH = 4,
  parameter NCH   = 4,
  parameter PACK  = 1
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cmd_valid,
  input  wire [6:0]  cmd_funct,
  input  wire [63:0] cmd_rs1,
  input  wire [63:0] cmd_rs2,
  input  wire [4:0]  cmd_rd,
  input  wire        cmd_xd,
  output wire        cmd_ready,
  output wire        resp_valid,
  input  wire        resp_ready,
  output wire [4:0]  resp_rd,
  output wire [63:0] resp_data,
  output wire        busy,
  output wire [39:0] req_addr,
  output wire        req_valid,
  input  wire        req_ready,
  output wire [2:0]  req_tag,
  input  wire        rsp_valid,
  input  wire [2:0]  rsp_tag,
  input  wire [63:0] rsp_data,
  output wire [39:0] st_addr,
  output wire        st_valid,
  output wire [31:0] out_bytes,
  output wire        out_valid
);
  wire [63:0]      act;
  wire [64*NCH-1:0] wgt, acc, bank_rd;
  wire             mac_en, mac_clr, quant_en;
  wire [3:0]       blk;
  reg              quant_en_q;
  always @(posedge clk) quant_en_q <= quant_en;

  mbx_ctrl #(.DEPTH(DEPTH), .NCH(NCH)) u_ctrl (
    .clk(clk), .rst(rst),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_funct(cmd_funct),
    .cmd_rs1(cmd_rs1), .cmd_rs2(cmd_rs2), .cmd_rd(cmd_rd), .cmd_xd(cmd_xd),
    .resp_valid(resp_valid), .resp_ready(resp_ready), .resp_rd(resp_rd),
    .resp_data(resp_data), .busy(busy),
    .req_addr(req_addr), .req_valid(req_valid), .req_ready(req_ready),
    .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_tag(rsp_tag),
    .rsp_data(rsp_data), .st_addr(st_addr), .st_valid(st_valid),
    .act_word(act), .wgt_word(wgt), .mac_en(mac_en), .mac_clr(mac_clr),
    .quant_en(quant_en), .blk(blk), .acc_probe(acc[63:0]));

  mbx_mac8xn_dsp #(.N(NCH), .PACK(PACK), .PIPE(0)) u_mac (
    .clk(clk), .en(mac_en), .clr(mac_clr), .a(act), .w(wgt),
    .seed(64'd0), .acc(acc));

  // The accumulator file is the pipeline boundary between the MAC's adder tree
  // and the requantiser's multiplier.  Both fit the period on their own; putting
  // them in one cycle does not (see ROCC_STUDY.md section 3).
  mbx_accbank #(.NACC(16), .NCH(NCH)) u_bank (
    .clk(clk), .we(quant_en), .wa(blk), .wd(acc), .ra(blk), .rd(bank_rd));

  mbx_quant #(.LANES(NCH), .STAGES(3)) u_q (
    .clk(clk), .en(quant_en_q), .acc(bank_rd),
    .mult(cmd_rs2[31:0]), .shift(cmd_rs2[37:32]), .relu(cmd_rs2[38]),
    .y(out_bytes[8*NCH-1:0]));

  generate
    if (8*NCH < 32) begin : g_pad
      assign out_bytes[31:8*NCH] = {(32-8*NCH){1'b0}};
    end
  endgenerate
  assign out_valid = quant_en;
endmodule

module mbx_full #(
  parameter DEPTH = 4,
  parameter NCH   = 4,
  parameter ROWS  = 64
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cmd_valid,
  input  wire [6:0]  cmd_funct,
  input  wire [63:0] cmd_rs1,
  input  wire [63:0] cmd_rs2,
  input  wire [4:0]  cmd_rd,
  input  wire        cmd_xd,
  output wire        cmd_ready,
  output wire        resp_valid,
  input  wire        resp_ready,
  output wire [4:0]  resp_rd,
  output wire [63:0] resp_data,
  output wire        busy,
  output wire [39:0] req_addr,
  output wire        req_valid,
  input  wire        req_ready,
  output wire [2:0]  req_tag,
  input  wire        rsp_valid,
  input  wire [2:0]  rsp_tag,
  input  wire [63:0] rsp_data,
  input  wire [63:0] g_lo,
  input  wire [63:0] g_hi,
  output wire [39:0] st_addr,
  output wire        st_valid,
  output wire [31:0] out_bytes,
  output wire        out_valid,
  output wire [63:0] patch_wd,
  output wire        patch_we
);
  wire gbusy;
  mbx_lean #(.DEPTH(DEPTH), .NCH(NCH), .PACK(1)) u_lean (
    .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd_funct(cmd_funct),
    .cmd_rs1(cmd_rs1), .cmd_rs2(cmd_rs2), .cmd_rd(cmd_rd), .cmd_xd(cmd_xd),
    .cmd_ready(cmd_ready), .resp_valid(resp_valid), .resp_ready(resp_ready),
    .resp_rd(resp_rd), .resp_data(resp_data), .busy(busy),
    .req_addr(req_addr), .req_valid(req_valid), .req_ready(req_ready),
    .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_tag(rsp_tag),
    .rsp_data(rsp_data), .st_addr(st_addr), .st_valid(st_valid),
    .out_bytes(out_bytes), .out_valid(out_valid));

  wire [31:0] gaddr; wire greq; wire [15:0] pwa;
  mbx_gather #(.ROWS(ROWS)) u_g (
    .clk(clk), .rst(rst), .start(cmd_valid && (cmd_funct == 7'd4)),
    .iw0(cmd_rs1[31:0]), .kw(cmd_rs2[3:0]), .nrows(cmd_rs2[19:4]),
    .iwid(cmd_rs1[63:32]),
    .rp_we(cmd_valid && (cmd_funct == 7'd5)), .rp_wa(cmd_rs1[15:0]),
    .rp_wd(cmd_rs2[32:0]),
    .mem_addr(gaddr), .mem_req(greq), .mem_gnt(req_ready),
    .mem_lo(g_lo), .mem_hi(g_hi),
    .patch_wd(patch_wd), .patch_wa(pwa), .patch_we(patch_we), .busy(gbusy));
endmodule
