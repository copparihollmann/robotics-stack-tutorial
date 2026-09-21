// -----------------------------------------------------------------------------
// MBX-T: the tiled unit.  Scratchpad, tile fill, im2col, broadcast MAC, requantise.
//
// Eight instructions on custom-1.  Only `mbx.fence` returns a value, so only it pays
// the round trip -- and on this SoC an xd = 1 RoCC op stalls the whole ID stage until
// its response is granted the register-file write port (ROCC_STUDY.md section 4.4).
//
//   funct7 mnemonic   xd  rs1                rs2
//   0      mbx.sd     0   src base           {nrows[47:32], stride[31:16], row_bytes[15:0]}
//   1      mbx.ld     0   {dst_addr, bank}   -                 fill a tile: one instruction
//   2      mbx.lp     0   {iw0, IW}          {nrows, KW}       im2col gather into the spad
//   3      mbx.cfg    0   {P, Q, G}          {out_base, wgt_base, act_base}
//   4      mbx.mm     0   -                  -                 run the tile
//   5      mbx.sq     0   -                  {relu, shift, mult}
//   6      mbx.st     0   dst base           {rows, row_bytes}  drain results
//   7      mbx.fence  1   -                  -                 rd = busy
//
// Software keeps the layer loop and the tiling decision.  The unit sequences within a
// tile.  That is the whole design, and the distinction from a convolution accelerator
// is exactly one of scope: there is no padding logic, no stride or dilation, no
// im2col loop nest and no output-channel blocking in here.
// -----------------------------------------------------------------------------
module mbx_tiled #(
  parameter NCH   = 4,
  parameter GRP   = 3,      // scratchpad banks per read port
  parameter DEPTH = 4,      // outstanding loads
  parameter GATHER = 1,     // include the im2col engine
  parameter ROWS  = 64
) (
  input  wire        clk,
  input  wire        rst,
  // RoCC command
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
  output wire        busy,
  // memory
  output wire [39:0] req_addr,
  output wire        req_valid,
  input  wire        req_ready,
  output wire [2:0]  req_tag,
  input  wire        rsp_valid,
  input  wire [2:0]  rsp_tag,
  input  wire [63:0] rsp_data,
  input  wire [63:0] g_lo,
  input  wire [63:0] g_hi,
  // result drain
  output wire [63:0] out_bytes,
  output wire        out_valid
);
  localparam NRD = NCH + 1;

  // ---- descriptors ---------------------------------------------------------
  reg [39:0] sd_base;
  reg [15:0] sd_rb, sd_str, sd_nr;
  reg [15:0] t_g, t_q, t_p, t_ab, t_wb, t_ob;
  reg [31:0] q_mult; reg [5:0] q_shift; reg q_relu;

  wire ld  = cmd_valid && (cmd_funct == 7'd1);
  wire lp  = cmd_valid && (cmd_funct == 7'd2);
  wire mm  = cmd_valid && (cmd_funct == 7'd4);

  // ---- tile fill -----------------------------------------------------------
  wire        dma_we, dma_busy;
  wire [15:0] dma_bank, dma_addr;
  wire [63:0] dma_data;
  mbx_dma #(.DEPTH(DEPTH)) u_dma (
    .clk(clk), .rst(rst), .start(ld),
    .src_base(sd_base), .row_bytes(sd_rb), .src_stride(sd_str), .nrows(sd_nr),
    .dst_bank(cmd_rs1[31:16]), .dst_addr(cmd_rs1[15:0]),
    .req_addr(req_addr), .req_valid(req_valid), .req_ready(req_ready),
    .req_tag(req_tag), .rsp_valid(rsp_valid), .rsp_tag(rsp_tag), .rsp_data(rsp_data),
    .sp_we(dma_we), .sp_bank(dma_bank), .sp_addr(dma_addr), .sp_data(dma_data),
    .busy(dma_busy));

  // ---- im2col --------------------------------------------------------------
  wire        g_we, g_busy;
  wire [63:0] g_wd;
  wire [15:0] g_wa;
  wire [31:0] g_ma;
  wire        g_mr;
  generate
    if (GATHER) begin : g_gather
      mbx_gather #(.ROWS(ROWS)) u_g (
        .clk(clk), .rst(rst), .start(lp),
        .iw0(cmd_rs1[31:0]), .kw(cmd_rs2[3:0]), .nrows(cmd_rs2[19:4]),
        .iwid(cmd_rs1[63:32]),
        .rp_we(cmd_valid && (cmd_funct == 7'd6)), .rp_wa(cmd_rs1[15:0]),
        .rp_wd(cmd_rs2[32:0]),
        .mem_addr(g_ma), .mem_req(g_mr), .mem_gnt(req_ready),
        .mem_lo(g_lo), .mem_hi(g_hi),
        .patch_wd(g_wd), .patch_wa(g_wa), .patch_we(g_we), .busy(g_busy));
    end else begin : g_nogather
      assign g_we = 1'b0; assign g_wd = 64'd0; assign g_wa = 16'd0;
      assign g_ma = 32'd0; assign g_mr = 1'b0; assign g_busy = 1'b0;
    end
  endgenerate

  // ---- scratchpad ----------------------------------------------------------
  wire [NRD*16-1:0] rd_addr;
  wire [NRD*64-1:0] rd_data;
  mbx_spad #(.NRD(NRD), .GRP(GRP), .DEPTH(512)) u_sp (
    .clk(clk), .rd_addr(rd_addr), .rd_data(rd_data),
    .wr_en(dma_we | g_we),
    .wr_bank(g_we ? 16'd0 : dma_bank),
    .wr_addr(g_we ? g_wa : dma_addr),
    .wr_data(g_we ? g_wd : dma_data));

  // ---- tile sequencer ------------------------------------------------------
  wire        mac_en, mac_clr, quant_en, t_busy;
  wire [15:0] out_index;
  mbx_tseq #(.NCH(NCH)) u_ts (
    .clk(clk), .rst(rst), .start(mm),
    .ngroups(t_g), .nquads(t_q), .npix(t_p),
    .act_base(t_ab), .wgt_base(t_wb), .out_base(t_ob),
    .rd_addr(rd_addr), .mac_en(mac_en), .mac_clr(mac_clr),
    .quant_en(quant_en), .out_index(out_index), .busy(t_busy));

  // ---- MAC array + accumulators + requantise -------------------------------
  wire [64*NCH-1:0] acc, bank_rd;
  mbx_mac8xn_dsp #(.N(NCH), .PACK(0), .PIPE(0), .ACCW(32)) u_mac (
    .clk(clk), .en(mac_en), .clr(mac_clr),
    .a(rd_data[63:0]), .w(rd_data[64*NRD-1:64]),
    .seed(64'd0), .acc(acc));

  reg quant_en_q;
  always @(posedge clk) quant_en_q <= quant_en;
  mbx_accbank #(.NACC(16), .NCH(NCH)) u_bank (
    .clk(clk), .we(quant_en), .wa(out_index[3:0]), .wd(acc),
    .ra(out_index[3:0]), .rd(bank_rd));
  mbx_quant #(.LANES(NCH), .STAGES(3)) u_q (
    .clk(clk), .en(quant_en_q), .acc(bank_rd),
    .mult(q_mult), .shift(q_shift), .relu(q_relu),
    .y(out_bytes[8*NCH-1:0]));
  generate
    if (8*NCH < 64) begin : g_pad
      assign out_bytes[63:8*NCH] = {(64-8*NCH){1'b0}};
    end
  endgenerate
  assign out_valid = quant_en_q;

  // ---- command / response --------------------------------------------------
  reg rv; reg [4:0] rrd;
  assign cmd_ready  = 1'b1;     // never deassert: RocketCore.scala:792 replays, not stalls
  assign resp_valid = rv;
  assign resp_rd    = rrd;
  assign resp_data  = {61'd0, dma_busy, g_busy, t_busy};
  assign busy       = dma_busy | g_busy | t_busy;

  always @(posedge clk) begin
    if (rst) rv <= 1'b0;
    else begin
      if (rv) rv <= 1'b0;
      if (cmd_valid) begin
        case (cmd_funct)
          7'd0: begin sd_base <= cmd_rs1[39:0]; sd_rb <= cmd_rs2[15:0];
                      sd_str  <= cmd_rs2[31:16]; sd_nr <= cmd_rs2[47:32]; end
          7'd3: begin t_g  <= cmd_rs1[15:0];  t_q  <= cmd_rs1[31:16]; t_p <= cmd_rs1[47:32];
                      t_ab <= cmd_rs2[15:0];  t_wb <= cmd_rs2[31:16]; t_ob <= cmd_rs2[47:32]; end
          7'd5: begin q_mult <= cmd_rs2[31:0]; q_shift <= cmd_rs2[37:32];
                      q_relu <= cmd_rs2[38]; end
          7'd7: if (cmd_xd) begin rv <= 1'b1; rrd <= cmd_rd; end
          default: ;
        endcase
      end
    end
  end
endmodule
