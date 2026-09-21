// SPDX-License-Identifier: Apache-2.0
//
// mbxr_tseq -- the in-tile sequencer, rewritten for the engine that is actually built.
//
// WHAT CHANGED FROM rtl_study/rocc/mbx_tseq.v, AND WHY EACH ONE IS A CORRECTNESS ITEM.
//
//   1. PLANAR WEIGHTS.  mbx_tseq read weight lane c at `w_ptr + c` from port c+1, which
//      assumes every weight port holds the same interleaved image.  mbxd_spad gives each
//      read port its OWN banks and mbxd_dma fills one bank group per descriptor, so that
//      layout needs the weights written NCH times (ROCC_DECOUPLED.md 7.5).  Here every
//      lane reads the SAME word address from its own plane, and each plane holds only
//      that lane's rows.
//
//   2. A BIAS STEP.  Each plane row is G+1 words: word 0 carries the int32 bias in its low
//      32 bits, words 1..G the weights.  Step 0 loads the accumulator from word 0 (the
//      activation is not read), steps 1..G accumulate.  One extra cycle per output pixel
//      quad -- 1/37 at K = 288 -- buys bit-exactness with kernel_linear_s8's
//      `acc = bias[n]` without a second read path.
//
//   3. A PIXEL STRIDE.  The activation pointer advances by `astride` words per pixel, not
//      by G.  For a linear layer astride = G (rows abut); for a 1-D convolution over an
//      NHWC-contiguous window it is stride x IC / 8, so overlapping windows need no im2col
//      engine at all -- which is what section 4.2 said NHWC buys.
//
//   4. ALIGNMENT WITH THE BLOCK RAM.  mbxd_spad's read is registered, so a word addressed
//      in cycle t is on the MAC's inputs in cycle t+1.  mbx_tseq raised mac_en in cycle t;
//      this module emits `s0_*` in the addressing cycle and the engine registers them once
//      before they reach the array.
//
//   5. HOLD.  When the drain's FIFO is nearly full the sequencer stops issuing steps.  The
//      steps already addressed complete normally; nothing is repeated and nothing dropped.
//
//   6. A SUB-BYTE WEIGHT GRID (`wpack`, 2026-09-18).  The activation word and the weight word
//      were ONE counter.  At six bits a code they diverge: a K = 288 row is 36 activation
//      words and 27 weight words, and a K = 1152 row is 144 against 108.  Both are exact, and
//      both are the same pattern -- FOUR MAC BEATS CONSUME THREE WEIGHT WORDS (4 x 8 codes x
//      6 bits = 192 bits = 3 words), so the weight pointer stalls once every four beats and
//      nothing else moves.
//
//      `ngroups` stays the ACTIVATION count, which is what the driver already sends: the
//      whole of the weight schedule is `ph`, two bits, and one stall term on w_ptr.  The row
//      advance needs no arithmetic either -- after beat 4m+3 the pointer has walked 3(m+1)
//      words, so `w_row <= w_ptr + 1` lands on the next PACKED row (G + 1 = 28 words at
//      K = 288) exactly as it lands on the next byte row at eight bits.
//
//      `s0_ph` is the phase of the beat being ADDRESSED this cycle; the engine registers it
//      with s0_valid and the read port's 48-bit select uses it one cycle later.  At wpack = 0
//      every register below behaves exactly as it did before this was written, which is what
//      compat/run_compat_tb.sh's exact cycle count checks.
//
// Loop order, which fixes the output byte order the drain writes (row-major in the tile):
//
//     for p in 0..P-1                 pixels / input rows of this activation tile
//       for q in 0..Q-1               output-channel quads of this weight tile
//         step 0                      acc[c] = bias(q, c)
//         for g in 1..G               acc[c] += dot8(act[p][g-1], wgt[q][c][g])
//         -> NCH quantised bytes, lane 0 first
//
// Every address is a running counter plus a constant.  No multiplier.

module mbxr_tseq #(
  parameter NCH = 4,
  parameter AW  = 10          // word address width within one buffer (1024 words)
) (
  input  wire          clk,
  input  wire          rst,
  input  wire          start,
  input  wire [15:0]   ngroups,     // G  words per activation row / weights per plane row
  input  wire [15:0]   nquads,      // Q
  input  wire [15:0]   npix,        // P
  input  wire [15:0]   astride,     // words between successive pixels' first words
  input  wire [AW-1:0] act_base,    // word of pixel 0's first activation word
  input  wire [AW-1:0] wgt_base,    // word of quad 0's bias word, in every plane
  input  wire          hold,
  input  wire          wpack,       // 1: weight rows hold 6-bit codes, 4 beats per 3 words

  output wire [AW-1:0] a_addr,
  output wire [AW-1:0] w_addr,
  output wire          s0_valid,    // a step is being addressed this cycle
  output wire          s0_clr,      // ... and it is the bias step
  output wire          s0_last,     // ... and it is the last weight step of its quad
  output wire [1:0]    s0_ph,       // ... and this is its phase in the 4-beat/3-word group
  output wire          busy
);
  reg          run;
  reg [15:0]   g, q, p;
  reg [15:0]   G_q, Q_q, P_q, S_q;
  reg [AW-1:0] wb_q;
  reg [AW-1:0] a_pix;       // first activation word of the current pixel
  reg [AW-1:0] a_ptr;       // activation word read by this step (don't-care on step 0)
  reg [AW-1:0] w_row;       // bias word of the current quad
  reg [AW-1:0] w_ptr;       // word read by this step
  reg [1:0]    ph;          // beat phase within the 4-beat / 3-word group (wpack only)
  reg          wp_q;

  // The one stall: beat 4m+2 and beat 4m+3 read the SAME word (bits 96..143 and 144..191 of
  // the group both live in words 3m+1 and 3m+2), so the pointer does not advance out of
  // phase 2.  g == 0 is the bias step and always advances -- it reads word 0 of the row.
  wire w_stall = wp_q && (g != 16'd0) && (ph == 2'd2);
  wire last_g = (g == G_q);
  wire last_q = (q + 16'd1 == Q_q);
  wire last_p = (p + 16'd1 == P_q);
  wire go     = run && !hold;

  assign a_addr   = a_ptr;
  assign w_addr   = w_ptr;
  assign s0_valid = go;
  assign s0_clr   = (g == 16'd0);
  assign s0_last  = last_g;
  assign s0_ph    = ph;
  assign busy     = run;

  always @(posedge clk) begin
    if (rst) begin
      run <= 1'b0;
      g <= 16'd0; q <= 16'd0; p <= 16'd0;
      G_q <= 16'd0; Q_q <= 16'd0; P_q <= 16'd0; S_q <= 16'd0;
      wb_q <= {AW{1'b0}}; a_pix <= {AW{1'b0}}; a_ptr <= {AW{1'b0}};
      w_row <= {AW{1'b0}}; w_ptr <= {AW{1'b0}};
      ph <= 2'd0; wp_q <= 1'b0;
    end else if (start && !run) begin
      // G = 0, Q = 0 or P = 0 is an empty tile: refuse to run rather than wrap a counter.
      run   <= (ngroups != 16'd0) && (nquads != 16'd0) && (npix != 16'd0);
      g <= 16'd0; q <= 16'd0; p <= 16'd0;
      G_q <= ngroups; Q_q <= nquads; P_q <= npix; S_q <= astride;
      wb_q  <= wgt_base;
      a_pix <= act_base; a_ptr <= act_base;
      w_row <= wgt_base; w_ptr <= wgt_base;
      ph <= 2'd0; wp_q <= wpack;
    end else if (go) begin
      if (!last_g) begin
        g     <= g + 16'd1;
        if (!w_stall) w_ptr <= w_ptr + 1'b1;
        // the bias step hands beat 0 phase 0; every later step walks the group
        ph    <= (g == 16'd0) ? 2'd0 : (ph + 2'd1);
        // step 0 -> 1 keeps a_ptr on the pixel's first word; later steps advance it
        if (g != 16'd0) a_ptr <= a_ptr + 1'b1;
      end else begin
        g <= 16'd0;
        ph <= 2'd0;
        if (!last_q) begin
          q     <= q + 16'd1;
          w_row <= w_ptr + 1'b1;            // the row after this one's last weight word
          w_ptr <= w_ptr + 1'b1;
          a_ptr <= a_pix;
        end else if (!last_p) begin
          q     <= 16'd0;
          p     <= p + 16'd1;
          a_pix <= a_pix + S_q[AW-1:0];
          a_ptr <= a_pix + S_q[AW-1:0];
          w_row <= wb_q;
          w_ptr <= wb_q;
        end else begin
          run <= 1'b0;
        end
      end
    end
  end
endmodule
