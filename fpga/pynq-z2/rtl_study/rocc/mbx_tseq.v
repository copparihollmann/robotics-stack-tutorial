// -----------------------------------------------------------------------------
// MBX tile compute sequencer -- where the loop nest is cut.
//
// The user's constraint on this design point was explicit: "we don't need the full
// expensive conv FSMs, but a simple tiled op with some load/instruction sequencing
// could be useful."  So: SOFTWARE keeps the layer loop and the tiling decision, and
// issues one `mbx.mm` per tile.  THE ACCELERATOR sequences WITHIN a tile, which is
// three nested counters and nothing else -- no padding logic, no stride/dilation, no
// im2col loop, no output-channel blocking, none of the shapes that make Gemmini's
// LoopConv 5,810 LUT and 114 DSP (ACCELERATOR_FIT.md section 2).
//
//   for p in 0..P-1          output pixels in this tile
//     for q in 0..Q-1        output-channel quads
//       for g in 0..G-1      groups of 8 along the reduction axis   <- innermost
//         acc[0..NCH-1] += dot8( act[p][g], wgt[q][c][g] )
//
// g innermost makes it output-stationary over (p, q): NCH accumulators live, one
// activation word and NCH weight words read per cycle, one requantise per (p, q).
// Every address is a running counter plus a constant stride -- no multipliers.
// -----------------------------------------------------------------------------
module mbx_tseq #(
  parameter NCH = 4
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  // tile descriptor
  input  wire [15:0] ngroups,     // G  = ceil(K/8)
  input  wire [15:0] nquads,      // Q  = ceil(OC/NCH)
  input  wire [15:0] npix,        // P  pixels in this tile
  input  wire [15:0] act_base,    // scratchpad word address of the im2col tile
  input  wire [15:0] wgt_base,
  input  wire [15:0] out_base,
  // scratchpad read addresses: port 0 = activation, ports 1..NCH = weights
  output wire [(NCH+1)*16-1:0] rd_addr,
  // datapath control
  output wire        mac_en,
  output wire        mac_clr,
  output wire        quant_en,
  output wire [15:0] out_index,
  output wire        busy
);
  reg [15:0] g, q, p;
  reg        run;
  reg [15:0] a_ptr, w_ptr, o_ptr;
  reg [15:0] G_q, Q_q, P_q, ab_q, wb_q;

  wire last_g = (g + 16'd1) == G_q;
  wire last_q = (q + 16'd1) == Q_q;
  wire last_p = (p + 16'd1) == P_q;

  // port 0: the activation word for (p, g).  ports 1..NCH: the NCH weight words for
  // (q, c, g), which are adjacent because mb_pext_conv_wpack already interleaves four
  // channels -- PEXT_KERNELS.md section 2.2, and the reason its inner loop is 16
  // instructions rather than 23.
  assign rd_addr[0 +: 16] = a_ptr;
  genvar c;
  generate
    for (c = 0; c < NCH; c = c + 1) begin : g_w
      assign rd_addr[(c+1)*16 +: 16] = w_ptr + (c);
    end
  endgenerate

  assign mac_en    = run;
  assign mac_clr   = run && (g == 16'd0);
  assign quant_en  = run && last_g;
  assign out_index = o_ptr;
  assign busy      = run;

  always @(posedge clk) begin
    if (rst) begin
      run <= 1'b0; g <= 0; q <= 0; p <= 0;
    end else if (start) begin
      run <= 1'b1; g <= 0; q <= 0; p <= 0;
      G_q <= ngroups; Q_q <= nquads; P_q <= npix;
      ab_q <= act_base; wb_q <= wgt_base;
      a_ptr <= act_base; w_ptr <= wgt_base; o_ptr <= out_base;
    end else if (run) begin
      if (!last_g) begin
        g     <= g + 16'd1;
        a_ptr <= a_ptr + 16'd1;
        w_ptr <= w_ptr + NCH[15:0];
      end else begin
        g     <= 16'd0;
        o_ptr <= o_ptr + 16'd1;
        if (!last_q) begin
          // same pixel, next output-channel quad: rewind the activation pointer to
          // this pixel's group 0; the weight sweep was contiguous and is already there
          q     <= q + 16'd1;
          a_ptr <= a_ptr - (G_q - 16'd1);
          w_ptr <= w_ptr + NCH[15:0];
        end else if (!last_p) begin
          // next pixel: activation advances by one group, weights rewind to quad 0
          q     <= 16'd0;
          p     <= p + 16'd1;
          a_ptr <= a_ptr + 16'd1;
          w_ptr <= wb_q;
        end else begin
          run <= 1'b0;
        end
      end
    end
  end
endmodule
