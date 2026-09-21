// SPDX-License-Identifier: Apache-2.0
//
// Parameter-fixing wrappers for the out-of-context sweep, one per measured row.
// mbx_harness can only instantiate a module with no required parameters, and every
// output must reach `z` or the synthesiser deletes the logic behind it.
//
// The harness contributes 64 LUT and 337 FF (the `null` row of ooc_out/summary.tsv);
// subtract them from every row below to get the datapath.

// ---------------------------------------------------------------------- fill engine
module mbxd_v_dma #(parameter DEPTH = 8) (
  input wire clk, input wire rst,
  input wire [63:0] a, b, c, d, input wire [15:0] ctl,
  output wire [63:0] z
);
  wire rv, rr, we;
  wire [39:0] ra;
  wire [3:0]  rs;
  wire [15:0] w;
  wire [63:0] wd;
  wire busy;
  wire [7:0] inf;

  assign rr = ctl[1];

  mbxd_dma #(.DEPTH(DEPTH), .LGBEATS(3)) u (
    .clk(clk), .rst(rst), .start(ctl[0]),
    .src_base(a[39:0]), .row_blocks(b[15:0]), .nrows(b[31:16]),
    .row_stride(b[63:32]), .dst_word(c[15:0]),
    .req_valid(rv), .req_ready(rr), .req_addr(ra), .req_source(rs),
    .rsp_valid(ctl[2]), .rsp_ready(), .rsp_source(ctl[6:3]), .rsp_data(d),
    .sp_we(we), .sp_word(w), .sp_data(wd), .busy(busy), .inflight(inf));

  assign z = {24'd0, ra} ^ {60'd0, rs} ^ {48'd0, w} ^ wd
           ^ {60'd0, rv, we, busy, 1'b0} ^ {56'd0, inf};
endmodule

module mbxd_v_dma2 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_dma #(.DEPTH(2)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d),
                             .ctl(ctl), .z(z));
endmodule
module mbxd_v_dma4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_dma #(.DEPTH(4)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d),
                             .ctl(ctl), .z(z));
endmodule
module mbxd_v_dma8 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_dma #(.DEPTH(8)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d),
                             .ctl(ctl), .z(z));
endmodule

// ---------------------------------------------------------------------- result drain
module mbxd_v_st #(parameter DEPTH = 2) (
  input wire clk, input wire rst,
  input wire [63:0] a, b, c, d, input wire [15:0] ctl,
  output wire [63:0] z
);
  wire rv, ir, first, last, busy;
  wire [39:0] ra;
  wire [3:0]  rs;
  wire [63:0] rd_;

  mbxd_st #(.DEPTH(DEPTH), .LGBEATS(3), .LGFIFO(5)) u (
    .clk(clk), .rst(rst), .start(ctl[0]),
    .dst_base(a[39:0]), .nblocks(b[15:0]),
    .in_valid(ctl[1]), .in_ready(ir), .in_data(d),
    .req_valid(rv), .req_ready(ctl[2]), .req_addr(ra), .req_source(rs),
    .req_data(rd_), .req_first(first), .req_last(last),
    .rsp_valid(ctl[3]), .busy(busy));

  assign z = {24'd0, ra} ^ {60'd0, rs} ^ rd_ ^ {59'd0, rv, ir, first, last, busy};
endmodule

module mbxd_v_st2 (input wire clk, rst, input wire [63:0] a, b, c, d,
                   input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_st #(.DEPTH(2)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d),
                            .ctl(ctl), .z(z));
endmodule

// ---------------------------------------------------------------------- scratchpad
module mbxd_v_spad #(parameter NRD = 5, parameter GRP = 4) (
  input wire clk, input wire rst,
  input wire [63:0] a, b, c, d, input wire [15:0] ctl,
  output wire [63:0] z
);
  wire [NRD*16-1:0] ra;
  wire [NRD*64-1:0] rdat;
  genvar i;
  generate
    // distinct addresses per port, or the optimiser shares the muxes
    for (i = 0; i < NRD; i = i + 1) begin : ga
      assign ra[i*16 +: 16] = a[15:0] + i*7 + {12'd0, ctl[3:0]};
    end
  endgenerate

  mbxd_spad #(.NRD(NRD), .GRP(GRP), .DEPTH(512)) u (
    .clk(clk), .rd_addr(ra), .rd_data(rdat),
    .wr_en(ctl[4]), .wr_word(b[15:0]), .wr_data(d));

  reg [63:0] f;
  integer k;
  always @* begin
    f = 64'd0;
    for (k = 0; k < NRD; k = k + 1) begin
      f = f ^ rdat[k*64 +: 64];
    end
  end
  assign z = f ^ c;
endmodule

module mbxd_v_spad5x4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                       input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_spad #(.NRD(5), .GRP(4)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c),
                                     .d(d), .ctl(ctl), .z(z));
endmodule
module mbxd_v_spad5x8 (input wire clk, rst, input wire [63:0] a, b, c, d,
                       input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_spad #(.NRD(5), .GRP(8)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c),
                                     .d(d), .ctl(ctl), .z(z));
endmodule
module mbxd_v_spad9x4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                       input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_spad #(.NRD(9), .GRP(4)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c),
                                     .d(d), .ctl(ctl), .z(z));
endmodule

// ---------------------------------------------------------------------- whole engine
module mbxd_v_eng #(parameter NCH = 4, parameter GRP = 4,
                    parameter LDEPTH = 8, parameter STORE = 1) (
  input wire clk, input wire rst,
  input wire [63:0] a, b, c, d, input wire [15:0] ctl,
  output wire [63:0] z
);
  wire cr, rvd, rv, rw, first, last, busy;
  wire [4:0]  rrd;
  wire [63:0] rdata, qa, ob;
  wire [39:0] qaddr;
  wire [3:0]  qsrc;
  wire        ov;

  mbxd_engine #(.NCH(NCH), .GRP(GRP), .LDEPTH(LDEPTH), .SDEPTH(2), .STORE(STORE)) u (
    .clk(clk), .rst(rst),
    .cmd_valid(ctl[0]), .cmd_funct(ctl[7:1]), .cmd_rs1(a), .cmd_rs2(b),
    .cmd_rd(ctl[12:8]), .cmd_xd(ctl[13]), .cmd_ready(cr),
    .resp_valid(rvd), .resp_rd(rrd), .resp_data(rdata), .busy(busy),
    .req_valid(rv), .req_ready(ctl[14]), .req_write(rw), .req_addr(qaddr),
    .req_source(qsrc), .req_data(qa), .req_first(first), .req_last(last),
    .rsp_valid(ctl[15]), .rsp_write(c[0]), .rsp_source(c[4:1]), .rsp_data(d),
    .out_bytes(ob), .out_valid(ov));

  assign z = rdata ^ qa ^ ob ^ {24'd0, qaddr} ^ {60'd0, qsrc}
           ^ {55'd0, cr, rvd, rv, rw, first, last, busy, ov, 1'b0} ^ {59'd0, rrd};
endmodule

module mbxd_v_eng4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_eng #(.NCH(4), .GRP(4), .LDEPTH(8), .STORE(1)) u
    (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z));
endmodule
module mbxd_v_eng4_nost (input wire clk, rst, input wire [63:0] a, b, c, d,
                         input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_eng #(.NCH(4), .GRP(4), .LDEPTH(8), .STORE(0)) u
    (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z));
endmodule
module mbxd_v_eng4_d4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                       input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_eng #(.NCH(4), .GRP(4), .LDEPTH(4), .STORE(1)) u
    (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z));
endmodule
module mbxd_v_eng8 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  mbxd_v_eng #(.NCH(8), .GRP(4), .LDEPTH(8), .STORE(1)) u
    (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z));
endmodule

// ------------------------------------------------ the in-tile sequencer, re-measured
// A copy of mbx_v_tseq4 so this sweep needs only the files it actually uses, and so
// tseq's 127 LUT is re-measured in the same run rather than quoted from another one.
module mbxd_v_tseq4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                     input wire [15:0] ctl, output wire [63:0] z);
  wire [79:0] ra; wire me, mc, qe, bsy; wire [15:0] oi;
  mbx_tseq #(.NCH(4)) u (
    .clk(clk), .rst(rst), .start(ctl[0]),
    .ngroups(a[15:0]), .nquads(a[31:16]), .npix(a[47:32]),
    .act_base(b[15:0]), .wgt_base(b[31:16]), .out_base(b[47:32]),
    .rd_addr(ra), .mac_en(me), .mac_clr(mc), .quant_en(qe),
    .out_index(oi), .busy(bsy));
  assign z = {16'd0, ra[79:64], ra[47:32], ra[15:0]} ^ {48'd0, oi} ^
             {60'd0, me, mc, qe, bsy};
endmodule

// ------------------------------------------------ the MAC array on its own, NCH = 4
// 32 int8 MAC/cycle.  Re-measured here so the sizing argument in mbxd_top.v can be
// checked against the array it is sizing.
module mbxd_v_mac4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  wire [255:0] acc;
  mbx_mac8xn_dsp #(.N(4), .PACK(0), .PIPE(0), .ACCW(32)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a),
    .w({b, c, d, {b[31:0], c[31:0]}}), .seed(64'd0), .acc(acc));
  assign z = acc[63:0] ^ acc[127:64] ^ acc[191:128] ^ acc[255:192];
endmodule
