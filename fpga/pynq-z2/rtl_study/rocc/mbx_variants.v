// -----------------------------------------------------------------------------
// Parameter-fixing wrappers, one per measured row, all with the same port list
// so mbx_harness can instantiate any of them.  Inputs are spread across
// a/b/c/d/ctl and every output is folded into z, so nothing is optimised away
// and the LUT column is the datapath.
// -----------------------------------------------------------------------------

// ---- MAC array: the shape question ------------------------------------------
module mbx_v_mac8_dsp (input wire clk, rst, input wire [63:0] a, b, c, d,
                       input wire [15:0] ctl, output wire [63:0] z);
  wire [63:0] acc;
  mbx_mac8xn_dsp #(.N(1), .PACK(0), .PIPE(0)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w(b), .seed(c), .acc(acc));
  assign z = acc;
endmodule

module mbx_v_mac8_dsp_p2 (input wire clk, rst, input wire [63:0] a, b, c, d,
                          input wire [15:0] ctl, output wire [63:0] z);
  wire [63:0] acc;
  mbx_mac8xn_dsp #(.N(1), .PACK(0), .PIPE(1)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w(b), .seed(c), .acc(acc));
  assign z = acc;
endmodule

module mbx_v_mac8x4_nopack (input wire clk, rst, input wire [63:0] a, b, c, d,
                            input wire [15:0] ctl, output wire [63:0] z);
  wire [255:0] acc;
  mbx_mac8xn_dsp #(.N(4), .PACK(0), .PIPE(0)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w({d, c, b, a}),
    .seed({48'd0, ctl}), .acc(acc));
  assign z = acc[63:0] ^ acc[127:64] ^ acc[191:128] ^ acc[255:192];
endmodule

module mbx_v_mac8x4_pack (input wire clk, rst, input wire [63:0] a, b, c, d,
                          input wire [15:0] ctl, output wire [63:0] z);
  wire [255:0] acc;
  mbx_mac8xn_dsp #(.N(4), .PACK(1), .PIPE(0)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w({d, c, b, a}),
    .seed({48'd0, ctl}), .acc(acc));
  assign z = acc[63:0] ^ acc[127:64] ^ acc[191:128] ^ acc[255:192];
endmodule

module mbx_v_mac8x4_pack_p2 (input wire clk, rst, input wire [63:0] a, b, c, d,
                             input wire [15:0] ctl, output wire [63:0] z);
  wire [255:0] acc;
  mbx_mac8xn_dsp #(.N(4), .PACK(1), .PIPE(1)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w({d, c, b, a}),
    .seed({48'd0, ctl}), .acc(acc));
  assign z = acc[63:0] ^ acc[127:64] ^ acc[191:128] ^ acc[255:192];
endmodule

module mbx_v_mac8x4_pack_a32 (input wire clk, rst, input wire [63:0] a, b, c, d,
                              input wire [15:0] ctl, output wire [63:0] z);
  wire [255:0] acc;
  mbx_mac8xn_dsp #(.N(4), .PACK(1), .PIPE(0), .ACCW(32)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w({d, c, b, a}),
    .seed({48'd0, ctl}), .acc(acc));
  assign z = acc[63:0] ^ acc[127:64] ^ acc[191:128] ^ acc[255:192];
endmodule

module mbx_v_mac8x4_lut (input wire clk, rst, input wire [63:0] a, b, c, d,
                         input wire [15:0] ctl, output wire [63:0] z);
  wire [255:0] acc;
  mbx_mac8xn_lut #(.N(4)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w({d, c, b, a}),
    .seed({48'd0, ctl}), .acc(acc));
  assign z = acc[63:0] ^ acc[127:64] ^ acc[191:128] ^ acc[255:192];
endmodule

// N = 8.  The four extra weight words are byte rotations of the first four:
// distinct values, zero LUT cost to produce.
module mbx_v_mac8x8_pack (input wire clk, rst, input wire [63:0] a, b, c, d,
                          input wire [15:0] ctl, output wire [63:0] z);
  wire [511:0] acc;
  wire [63:0] ar = {a[55:0], a[63:56]};
  wire [63:0] br = {b[55:0], b[63:56]};
  wire [63:0] cr = {c[55:0], c[63:56]};
  wire [63:0] dr = {d[55:0], d[63:56]};
  mbx_mac8xn_dsp #(.N(8), .PACK(1), .PIPE(0)) u (
    .clk(clk), .en(ctl[0]), .clr(ctl[1]), .a(a), .w({dr, cr, br, ar, d, c, b, a}),
    .seed({48'd0, ctl}), .acc(acc));
  assign z = acc[63:0] ^ acc[127:64] ^ acc[191:128] ^ acc[255:192] ^
             acc[319:256] ^ acc[383:320] ^ acc[447:384] ^ acc[511:448];
endmodule

// ---- the quantised output stage ---------------------------------------------
module mbx_v_quant4_comb (input wire clk, rst, input wire [63:0] a, b, c, d,
                          input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] y;
  mbx_quant #(.LANES(4), .STAGES(1)) u (
    .clk(clk), .en(ctl[0]), .acc({d, c, b, a}),
    .mult(a[31:0] ^ b[31:0]), .shift(ctl[5:0]), .relu(ctl[6]), .y(y));
  assign z = {32'd0, y};
endmodule

module mbx_v_quant4_p3 (input wire clk, rst, input wire [63:0] a, b, c, d,
                        input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] y;
  mbx_quant #(.LANES(4), .STAGES(3)) u (
    .clk(clk), .en(ctl[0]), .acc({d, c, b, a}),
    .mult(a[31:0] ^ b[31:0]), .shift(ctl[5:0]), .relu(ctl[6]), .y(y));
  assign z = {32'd0, y};
endmodule

module mbx_v_qmul32 (input wire clk, rst, input wire [63:0] a, b, c, d,
                     input wire [15:0] ctl, output wire [63:0] z);
  wire [33:0] p;
  mbx_qmul32 u (.clk(clk), .acc(a[31:0]), .mult(b[31:0]), .p(p));
  assign z = {30'd0, p};
endmodule

// ---- the gather engine -------------------------------------------------------
module mbx_v_align (input wire clk, rst, input wire [63:0] a, b, c, d,
                    input wire [15:0] ctl, output wire [63:0] z);
  wire [63:0] m; wire [7:0] be;
  mbx_align u (.lo(a), .hi(b), .sh(ctl[2:0]), .pos(ctl[5:3]), .len(ctl[9:6]),
               .resid(c), .merged(m), .be(be));
  assign z = m ^ {56'd0, be};
endmodule

module mbx_v_gather (input wire clk, rst, input wire [63:0] a, b, c, d,
                     input wire [15:0] ctl, output wire [63:0] z);
  wire [31:0] ma; wire mr, we, bsy; wire [63:0] wd; wire [15:0] wa;
  mbx_gather #(.ROWS(64)) u (
    .clk(clk), .rst(rst), .start(ctl[0]), .iw0(a[31:0]), .kw(ctl[4:1]),
    .nrows(a[47:32]), .iwid(b[31:0]),
    .rp_we(ctl[5]), .rp_wa(b[47:32]), .rp_wd(c[32:0]),
    .mem_addr(ma), .mem_req(mr), .mem_gnt(ctl[6]),
    .mem_lo(c), .mem_hi(d),
    .patch_wd(wd), .patch_wa(wa), .patch_we(we), .busy(bsy));
  assign z = wd ^ {16'd0, ma, wa} ^ {61'd0, mr, we, bsy};
endmodule

// ---- state and control -------------------------------------------------------
module mbx_v_accbank16 (input wire clk, rst, input wire [63:0] a, b, c, d,
                        input wire [15:0] ctl, output wire [63:0] z);
  wire [255:0] rd;
  mbx_accbank #(.NACC(16), .NCH(4)) u (
    .clk(clk), .we(ctl[0]), .wa(ctl[4:1]), .wd({d, c, b, a}),
    .ra(ctl[8:5]), .rd(rd));
  assign z = rd[63:0] ^ rd[127:64] ^ rd[191:128] ^ rd[255:192];
endmodule

module mbx_v_ctrl_d1 (input wire clk, rst, input wire [63:0] a, b, c, d,
                      input wire [15:0] ctl, output wire [63:0] z);
  wire [63:0] act, rdat; wire [255:0] wgt; wire [39:0] ra; wire [2:0] rt;
  wire me, mc, qe, cr, rv, bsy, sv; wire [39:0] sa; wire [3:0] bk;
  mbx_ctrl #(.DEPTH(1), .NCH(4)) u (
    .clk(clk), .rst(rst), .cmd_valid(ctl[0]), .cmd_ready(cr),
    .cmd_funct(ctl[7:1]), .cmd_rs1(a), .cmd_rs2(b), .cmd_rd(ctl[12:8]),
    .cmd_xd(ctl[13]), .resp_valid(rv), .resp_ready(ctl[14]), .resp_rd(),
    .resp_data(rdat), .busy(bsy), .req_addr(ra), .req_valid(), .req_ready(ctl[15]),
    .req_tag(rt), .rsp_valid(ctl[14]), .rsp_tag(c[2:0]), .rsp_data(d), .st_addr(sa), .st_valid(sv),
    .act_word(act), .wgt_word(wgt), .mac_en(me), .mac_clr(mc), .quant_en(qe),
    .blk(bk), .acc_probe(c));
  assign z = act ^ wgt[63:0] ^ wgt[255:192] ^ rdat ^ {24'd0, ra} ^ {24'd0, sa} ^
             {51'd0, bk, rt, me, mc, qe, cr, rv, sv};
endmodule

module mbx_v_ctrl_d4 (input wire clk, rst, input wire [63:0] a, b, c, d,
                      input wire [15:0] ctl, output wire [63:0] z);
  wire [63:0] act, rdat; wire [255:0] wgt; wire [39:0] ra; wire [2:0] rt;
  wire me, mc, qe, cr, rv, bsy, sv; wire [39:0] sa; wire [3:0] bk;
  mbx_ctrl #(.DEPTH(4), .NCH(4)) u (
    .clk(clk), .rst(rst), .cmd_valid(ctl[0]), .cmd_ready(cr),
    .cmd_funct(ctl[7:1]), .cmd_rs1(a), .cmd_rs2(b), .cmd_rd(ctl[12:8]),
    .cmd_xd(ctl[13]), .resp_valid(rv), .resp_ready(ctl[14]), .resp_rd(),
    .resp_data(rdat), .busy(bsy), .req_addr(ra), .req_valid(), .req_ready(ctl[15]),
    .req_tag(rt), .rsp_valid(ctl[14]), .rsp_tag(c[2:0]), .rsp_data(d), .st_addr(sa), .st_valid(sv),
    .act_word(act), .wgt_word(wgt), .mac_en(me), .mac_clr(mc), .quant_en(qe),
    .blk(bk), .acc_probe(c));
  assign z = act ^ wgt[63:0] ^ wgt[255:192] ^ rdat ^ {24'd0, ra} ^ {24'd0, sa} ^
             {51'd0, bk, rt, me, mc, qe, cr, rv, sv};
endmodule

module mbx_v_ctrl_d8 (input wire clk, rst, input wire [63:0] a, b, c, d,
                      input wire [15:0] ctl, output wire [63:0] z);
  wire [63:0] act, rdat; wire [255:0] wgt; wire [39:0] ra; wire [2:0] rt;
  wire me, mc, qe, cr, rv, bsy, sv; wire [39:0] sa; wire [3:0] bk;
  mbx_ctrl #(.DEPTH(8), .NCH(4)) u (
    .clk(clk), .rst(rst), .cmd_valid(ctl[0]), .cmd_ready(cr),
    .cmd_funct(ctl[7:1]), .cmd_rs1(a), .cmd_rs2(b), .cmd_rd(ctl[12:8]),
    .cmd_xd(ctl[13]), .resp_valid(rv), .resp_ready(ctl[14]), .resp_rd(),
    .resp_data(rdat), .busy(bsy), .req_addr(ra), .req_valid(), .req_ready(ctl[15]),
    .req_tag(rt), .rsp_valid(ctl[14]), .rsp_tag(c[2:0]), .rsp_data(d), .st_addr(sa), .st_valid(sv),
    .act_word(act), .wgt_word(wgt), .mac_en(me), .mac_clr(mc), .quant_en(qe),
    .blk(bk), .acc_probe(c));
  assign z = act ^ wgt[63:0] ^ wgt[255:192] ^ rdat ^ {24'd0, ra} ^ {24'd0, sa} ^
             {51'd0, bk, rt, me, mc, qe, cr, rv, sv};
endmodule

// ---- the three whole units ---------------------------------------------------
module mbx_v_min (input wire clk, rst, input wire [63:0] a, b, c, d,
                  input wire [15:0] ctl, output wire [63:0] z);
  wire cr, rv, bsy; wire [4:0] rrd; wire [63:0] rdat;
  mbx_min u (.clk(clk), .rst(rst), .cmd_valid(ctl[0]), .cmd_funct(ctl[7:1]),
             .cmd_rs1(a), .cmd_rs2(b), .cmd_rd(ctl[12:8]), .cmd_xd(ctl[13]),
             .cmd_ready(cr), .resp_valid(rv), .resp_rd(rrd), .resp_data(rdat),
             .busy(bsy));
  assign z = rdat ^ {55'd0, rrd, cr, rv, bsy};
endmodule

module mbx_v_lean (input wire clk, rst, input wire [63:0] a, b, c, d,
                   input wire [15:0] ctl, output wire [63:0] z);
  wire cr, rv, bsy, ov, sv; wire [4:0] rrd; wire [63:0] rdat;
  wire [39:0] ra, sa; wire rvld; wire [2:0] rt; wire [31:0] ob;
  mbx_lean #(.DEPTH(4), .NCH(4), .PACK(1)) u (
    .clk(clk), .rst(rst), .cmd_valid(ctl[0]), .cmd_funct(ctl[7:1]),
    .cmd_rs1(a), .cmd_rs2(b), .cmd_rd(ctl[12:8]), .cmd_xd(ctl[13]),
    .cmd_ready(cr), .resp_valid(rv), .resp_ready(ctl[14]), .resp_rd(rrd),
    .resp_data(rdat), .busy(bsy), .req_addr(ra), .req_valid(rvld),
    .req_ready(ctl[15]), .req_tag(rt), .rsp_valid(ctl[14]), .rsp_tag(c[2:0]),
    .rsp_data(d), .st_addr(sa), .st_valid(sv),
    .out_bytes(ob), .out_valid(ov));
  assign z = rdat ^ {24'd0, ra} ^ {24'd0, sa} ^ {32'd0, ob} ^
             {50'd0, rt, rrd, cr, rv, bsy, rvld, ov, sv};
endmodule

module mbx_v_full (input wire clk, rst, input wire [63:0] a, b, c, d,
                   input wire [15:0] ctl, output wire [63:0] z);
  wire cr, rv, bsy, ov, pwe, sv; wire [4:0] rrd; wire [63:0] rdat, pwd;
  wire [39:0] ra, sa; wire rvld; wire [2:0] rt; wire [31:0] ob;
  mbx_full #(.DEPTH(4), .NCH(4), .ROWS(64)) u (
    .clk(clk), .rst(rst), .cmd_valid(ctl[0]), .cmd_funct(ctl[7:1]),
    .cmd_rs1(a), .cmd_rs2(b), .cmd_rd(ctl[12:8]), .cmd_xd(ctl[13]),
    .cmd_ready(cr), .resp_valid(rv), .resp_ready(ctl[14]), .resp_rd(rrd),
    .resp_data(rdat), .busy(bsy), .req_addr(ra), .req_valid(rvld),
    .req_ready(ctl[15]), .req_tag(rt), .rsp_valid(ctl[14]), .rsp_tag(c[2:0]),
    .rsp_data(d), .g_lo(c), .g_hi(d), .st_addr(sa), .st_valid(sv),
    .out_bytes(ob), .out_valid(ov), .patch_wd(pwd), .patch_we(pwe));
  assign z = rdat ^ pwd ^ {24'd0, ra} ^ {24'd0, sa} ^ {32'd0, ob} ^
             {49'd0, rt, rrd, cr, rv, bsy, rvld, ov, pwe, sv};
endmodule

// =============================================================================
// Revision 2 -- the scratchpad-fed tiled unit.  See ROCC_STUDY.md section 7.
// =============================================================================

// ---- the scratchpad: capacity against port-mux cost --------------------------
module mbx_v_spad #(parameter NRD = 5, parameter GRP = 3)
  (input wire clk, rst, input wire [63:0] a, b, c, d,
   input wire [15:0] ctl, output wire [63:0] z);
  wire [NRD*16-1:0] ra;
  wire [NRD*64-1:0] rdat;
  genvar i;
  generate
    for (i = 0; i < NRD; i = i + 1) begin : g_p
      // each port gets a different address, so no port can be merged with another
      assign ra[i*16 +: 16] = a[15:0] + (i * 7) + {12'd0, ctl[3:0]};
    end
  endgenerate
  mbx_spad #(.NRD(NRD), .GRP(GRP), .DEPTH(512)) u (
    .clk(clk), .rd_addr(ra), .rd_data(rdat),
    .wr_en(ctl[4]), .wr_bank(b[15:0]), .wr_addr(c[15:0]), .wr_data(d));
  // fold every read port into z so none of them is optimised away
  reg [63:0] f;
  integer k;
  always @* begin
    f = 64'd0;
    for (k = 0; k < NRD; k = k + 1) f = f ^ rdat[k*64 +: 64];
  end
  assign z = f;
endmodule

module mbx_v_spad_5x1  (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_spad #(.NRD(5), .GRP(1))  u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
module mbx_v_spad_5x3  (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_spad #(.NRD(5), .GRP(3))  u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
module mbx_v_spad_5x6  (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_spad #(.NRD(5), .GRP(6))  u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
module mbx_v_spad_5x15 (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_spad #(.NRD(5), .GRP(15)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
module mbx_v_spad_9x2  (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_spad #(.NRD(9), .GRP(2))  u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule

// ---- the tile fill engine ----------------------------------------------------
module mbx_v_dma #(parameter DEPTH = 4)
  (input wire clk, rst, input wire [63:0] a, b, c, d,
   input wire [15:0] ctl, output wire [63:0] z);
  wire [39:0] ra; wire rv; wire [2:0] rt;
  wire we, bsy; wire [15:0] bk, ad; wire [63:0] wd;
  mbx_dma #(.DEPTH(DEPTH)) u (
    .clk(clk), .rst(rst), .start(ctl[0]),
    .src_base(a[39:0]), .row_bytes(b[15:0]), .src_stride(b[31:16]), .nrows(b[47:32]),
    .dst_bank(c[15:0]), .dst_addr(c[31:16]),
    .req_addr(ra), .req_valid(rv), .req_ready(ctl[1]), .req_tag(rt),
    .rsp_valid(ctl[2]), .rsp_tag(a[42:40]), .rsp_data(d),
    .sp_we(we), .sp_bank(bk), .sp_addr(ad), .sp_data(wd), .busy(bsy));
  assign z = wd ^ {24'd0, ra} ^ {32'd0, bk, ad} ^ {59'd0, rt, rv, we} ^ {63'd0, bsy};
endmodule
module mbx_v_dma_d4 (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_dma #(.DEPTH(4)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
module mbx_v_dma_d8 (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_dma #(.DEPTH(8)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule

// ---- the tile sequencer -------------------------------------------------------
module mbx_v_tseq4 (input wire clk, rst, input wire [63:0] a, b, c, d,
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

// ---- the whole tiled unit -----------------------------------------------------
module mbx_v_tiled #(parameter NCH = 4, parameter GRP = 3, parameter GATHER = 1)
  (input wire clk, rst, input wire [63:0] a, b, c, d,
   input wire [15:0] ctl, output wire [63:0] z);
  wire cr, rv, bsy, ov; wire [4:0] rrd; wire [63:0] rdat;
  wire [39:0] ra; wire rq; wire [2:0] rt; wire [63:0] ob;
  mbx_tiled #(.NCH(NCH), .GRP(GRP), .DEPTH(4), .GATHER(GATHER), .ROWS(64)) u (
    .clk(clk), .rst(rst), .cmd_valid(ctl[0]), .cmd_funct(ctl[7:1]),
    .cmd_rs1(a), .cmd_rs2(b), .cmd_rd(ctl[12:8]), .cmd_xd(ctl[13]),
    .cmd_ready(cr), .resp_valid(rv), .resp_rd(rrd), .resp_data(rdat), .busy(bsy),
    .req_addr(ra), .req_valid(rq), .req_ready(ctl[14]), .req_tag(rt),
    .rsp_valid(ctl[15]), .rsp_tag(c[2:0]), .rsp_data(d),
    .g_lo(c), .g_hi(d), .out_bytes(ob), .out_valid(ov));
  assign z = rdat ^ {24'd0, ra} ^ ob ^ {51'd0, rt, rrd, cr, rv, bsy, rq, ov};
endmodule
module mbx_v_tiled4    (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_tiled #(.NCH(4), .GRP(3), .GATHER(1)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
module mbx_v_tiled4_nog(input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_tiled #(.NCH(4), .GRP(3), .GATHER(0)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
module mbx_v_tiled8    (input wire clk, rst, input wire [63:0] a, b, c, d, input wire [15:0] ctl, output wire [63:0] z);
  mbx_v_tiled #(.NCH(8), .GRP(2), .GATHER(1)) u (.clk(clk), .rst(rst), .a(a), .b(b), .c(c), .d(d), .ctl(ctl), .z(z)); endmodule
