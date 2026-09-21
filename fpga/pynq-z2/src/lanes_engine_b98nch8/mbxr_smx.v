// SPDX-License-Identifier: Apache-2.0
//
// mbxr_smx -- a row-streaming int8 softmax lane for the Moonshine encoder's attention.
// An OUT-OF-CONTEXT STUDY (ROCC_DECOUPLED.md s8.14's "softmax lane"): no SoC, no MAGIC, no
// bitstream.  Bit-exact with kernel_softmax_s8 of
// modelblaster/kernels/pext_nl/pext_nl_softmax_s8_pext_int_memo2.c (and so with pext_int_memo
// and pext_int_row), checked in Verilator by smx_lane/tb_smx.cpp against that C.
//
// ---- the split between software and this block -------------------------------------------
// Software computes, once per dispatch and exactly as the kernel does (smx_golden.c,
// smx_lane_cfg): the 256-entry table ex[d] = int_exp2_q31(nl_scale(-d << 16, im, is)), the
// output multiplier om and the shift s = os + 32 - 8.  It writes them here while the lane is
// idle.  The lane does every per-row and per-element step:
//     mx  = max_k x[k];   sum = SUM_k ex[mx - x[k]]           (uint64 in C; < 2^42 here)
//     inv = floor((2^64 - 1) / sum);  q_hi = inv >> 32;  q_lo = inv & 0xffffffff
//     ev  = ex[mx - x[k]];  p32 = ev*q_hi + ((ev*q_lo) >> 32)
//     p   = (p32*om + 2^30) >> 31;  if (s > 0) p = (p + 2^(s-1)) >> s
//     y   = nl_q8_to_s8(p, -128, 127) = min((p + 128) >> 8, 127)       (p >= 0)
// memo2's per-row cutoff and cache are software speed tricks; every element is computed here.
//
// ---- what is supported, and what is ruled out (and why) -----------------------------------
//  * s in [0, 33]: the kernel's fast path, exactly, for any uint32 om (the 64-bit wrap of
//    p32*om + 2^30 is reproduced; om from nl_f2ms_recip is in [2^30, 2^31) anyway).
//  * s in [34, 127]: every output is 0 in the kernel (p < 2^33 <= 2^(s-1), both in the fast path
//    and in nl_scale's s >= 62 branch), and here (s is clamped to 34).  s >= 128 is undefined
//    behaviour in nl_scale (an __int128 shift by >= 128) and needs scale_out >= 2^104.
//  * s < 0 is RULED OUT: err[0], in_ready held low.  It needs scale_out < 2^-24, an int8
//    probability encoding whose 1.0 is 2^24 LSBs (every nonzero output saturates), and the
//    kernel's nl_scale branch for it shifts p32 left by -s in int64 (overflow for -s >= 32)
//    and truncates to int32 in nl_q8_to_s8 -- a 64 x 31-bit multiply to reproduce nothing
//    useful.  Moonshine's six softmaxes all have s = 17 (scale_out = 1/127).
//  * PRECONDITION sum >= 2^31 for every row, so inv < 2^33 (q_hi in {0, 1}) and 33 quotient
//    bits suffice.  It holds for every table the kernel builds: ex[0] = int_exp2_q31(0) = 2^31
//    at every scale, and the row maximum contributes ex[0] to its own sum.  A row that breaks
//    it sets err[2]; sum == 0 (the kernel's "every output is 0") is honoured, but cannot occur
//    under the precondition.  Table entries may be any uint32 (no monotonicity is assumed).
//
// ---- architecture: three row stages that overlap ------------------------------------------
//   I  ingest   one score per handshake into ring S (2^RAW bytes), running max; at the row's
//               K-th byte its max goes to a 4-deep row queue.
//   S  sum      reads the row back from ring S (1 byte/cycle), d = mx - x, ex[d] from table
//               copy S, 42-bit sum; writes d into ring O.  The row's sum then goes through a
//               non-restoring divider (DIV_BPC quotient bits per cycle) while the reader is
//               already on the next row.  {zero, q_hi, q_lo} go to a 4-deep row queue.
//   O  output   reads d back from ring O (1 byte/cycle), ex[d] from table copy O, two
//               32 x 32 products, the round/shift/saturate, into an output FIFO.
// A stage starts a row only when every resource the row will need downstream is reserved
// (ring bytes, a row-queue slot, output-FIFO credit per element), so no stage ever stalls a
// pipeline in flight and every ready/valid is a function of registers only.  With the input
// always valid and the output always ready the three stages run back to back: K cycles per row
// in steady state (1 cycle per element) for K >= DCYC + 4; first score in to last output out
// 3K + DCYC + 8 cycles (simulated: 509 at K = 165, DIV_BPC = 6).
//
// Configuration map (cfg_we, while idle; a write while busy sets err[1]):
//   0x000..0x0ff  ex[d]           0x100  om (int32)        0x101  s (int32)
//   0x102         K (1..1024)     0x103  clear err[3:1]
// err[0] config unusable (s < 0 or K outside 1..1024)  err[1] config written while busy
// err[2] a row's sum was below 2^31 (that row is not the kernel's)
// err[3] in_last disagreed with the configured K

`default_nettype none

module mbxr_smx #(
  parameter RAW     = 11,   // log2 bytes per row ring: 2048 >= 2 * 1024
  parameter DIV_BPC = 6,    // reciprocal quotient bits per cycle
  parameter OFW     = 3     // log2 output FIFO depth; must exceed the 5-cycle O pipeline
) (
  input  wire        clk,
  input  wire        rst,
  // configuration
  input  wire        cfg_we,
  input  wire [8:0]  cfg_addr,
  input  wire [31:0] cfg_wdata,
  // scores in: K per row, row-major
  input  wire        in_valid,
  output wire        in_ready,
  input  wire [7:0]  in_data,
  input  wire        in_last,
  // softmax out: K per row, in order
  output wire        out_valid,
  input  wire        out_ready,
  output wire [7:0]  out_data,
  output wire        out_last,
  // status
  output wire        idle,
  output wire [3:0]  err
);
  localparam [RAW+1:0] DEPTH = {2'b01, {RAW{1'b0}}};
  localparam [OFW:0]   OCAP  = {1'b1, {OFW{1'b0}}};

  // ======================================================================================
  // configuration
  // ======================================================================================
  reg  [31:0] c_om;
  reg  [5:0]  c_s;          // min(s, 34)
  reg         c_sneg;
  reg  [9:0]  c_km1;        // K - 1
  reg  [10:0] c_k;          // K
  reg         c_kok;
  reg         e_busy, e_sum, e_last;
  wire        cfg_ok = c_kok & ~c_sneg;
  wire        tab_we = cfg_we & ~cfg_addr[8];

  always @(posedge clk) begin
    if (rst) begin
      c_om <= 32'd0; c_s <= 6'd0; c_sneg <= 1'b0; c_km1 <= 10'd0; c_k <= 11'd0; c_kok <= 1'b0;
      e_busy <= 1'b0;
    end else if (cfg_we) begin
      if (!idle) e_busy <= 1'b1;
      case (cfg_addr)
        9'h100: c_om <= cfg_wdata;
        9'h101: begin
          c_sneg <= cfg_wdata[31];
          c_s    <= (|cfg_wdata[31:6] || cfg_wdata[5:0] > 6'd34) ? 6'd34 : cfg_wdata[5:0];
        end
        9'h102: begin
          c_kok <= (cfg_wdata != 32'd0) && (cfg_wdata <= 32'd1024);
          c_km1 <= cfg_wdata[9:0] - 10'd1;
          c_k   <= cfg_wdata[10:0];
        end
        9'h103: e_busy <= 1'b0;
        default: ;
      endcase
    end
  end
  assign err = {e_last, e_sum, e_busy, ~cfg_ok};
  wire err_clr = cfg_we & (cfg_addr == 9'h103);

  // ======================================================================================
  // stage I: ingest
  // ======================================================================================
  reg  [9:0]   i_pos;
  reg  [7:0]   i_max;
  reg  [RAW:0] i_wp;
  reg  [2:0]   is_res, is_wp, is_rp;          // S row queue: reserved / written / taken
  reg  [7:0]   is_mem [0:3];
  reg  [RAW:0] s_rp;                          // stage S's read pointer into ring S

  wire [RAW+1:0] i_need  = {1'b0, i_wp - s_rp} + {{(RAW-9){1'b0}}, c_k};
  wire           i_admit = (i_need <= DEPTH) && ((is_res - is_rp) != 3'd4);
  assign in_ready = cfg_ok & ((i_pos != 10'd0) | i_admit);

  wire       i_fire  = in_valid & in_ready;
  wire       i_first = (i_pos == 10'd0);
  wire       i_lastp = (i_pos == c_km1);
  wire [7:0] i_mx_n  = (i_first || $signed(in_data) > $signed(i_max)) ? in_data : i_max;

  always @(posedge clk) begin
    if (rst) begin
      i_pos <= 10'd0; i_wp <= {(RAW+1){1'b0}}; is_res <= 3'd0; is_wp <= 3'd0; e_last <= 1'b0;
    end else begin
      if (err_clr) e_last <= 1'b0;
      if (i_fire) begin
        i_wp  <= i_wp + 1'b1;
        i_max <= i_mx_n;
        if (i_first) is_res <= is_res + 3'd1;
        if (i_lastp) begin
          i_pos <= 10'd0;
          is_wp <= is_wp + 3'd1;
        end else begin
          i_pos <= i_pos + 10'd1;
        end
        if (in_last != i_lastp) e_last <= 1'b1;
      end
    end
  end
  always @(posedge clk) if (i_fire & i_lastp) is_mem[is_wp[1:0]] <= i_mx_n;

  // ring S: written by I, read by S
  wire [7:0] ring_s_q;
  wire       s_rd;
  mbxr_smx_ram #(.AW(RAW), .DW(8)) u_ring_s (
    .clk(clk), .we(i_fire), .wa(i_wp[RAW-1:0]), .wd(in_data),
    .re(s_rd), .ra(s_rp[RAW-1:0]), .rd(ring_s_q));

  // ======================================================================================
  // stage S: sum, then reciprocal
  // ======================================================================================
  reg          s_act;
  reg  [9:0]   s_pos;
  reg  [7:0]   s_mx;
  reg  [RAW:0] s_wres;                         // ring O bytes reserved by S
  reg  [RAW:0] s_wp;                           // ring O write pointer
  reg  [2:0]   so_res, so_wp, so_rp;           // O row queue
  reg  [33:0]  so_mem [0:3];                   // {zero, q_hi, q_lo}
  reg  [1:0]   s_rows;                         // rows started by S, not yet queued for O
  reg  [RAW:0] o_rp;                           // stage O's read pointer into ring O
  wire         dv_push;

  wire [RAW+1:0] s_need = {1'b0, s_wres - o_rp} + {{(RAW-9){1'b0}}, c_k};
  wire s_can   = (is_wp != is_rp) && (s_need <= DEPTH) && ((so_res - so_rp) != 3'd4) &&
                 (s_rows != 2'd2);
  wire s_start = ~s_act & s_can;
  assign s_rd  = s_act | s_start;
  wire [9:0] s_posx   = s_act ? s_pos : 10'd0;
  wire       s_rdlast = s_rd & (s_posx == c_km1);
  wire [7:0] s_mxx    = s_act ? s_mx : is_mem[is_rp[1:0]];

  always @(posedge clk) begin
    if (rst) begin
      s_act <= 1'b0; s_pos <= 10'd0; s_rp <= {(RAW+1){1'b0}}; s_wres <= {(RAW+1){1'b0}};
      is_rp <= 3'd0; so_res <= 3'd0; s_rows <= 2'd0;
    end else begin
      if (s_start) begin
        is_rp  <= is_rp + 3'd1;
        so_res <= so_res + 3'd1;
        s_wres <= s_wres + {{(RAW-10){1'b0}}, c_k};
        s_mx   <= s_mxx;
      end
      if (s_rd) begin
        s_rp  <= s_rp + 1'b1;
        s_pos <= s_posx + 10'd1;
        s_act <= ~s_rdlast;
      end
      s_rows <= s_rows + {1'b0, s_start} - {1'b0, dv_push};
    end
  end

  // S1: x is on ring_s_q; d = mx - x (0..255 because mx >= x); table and ring O addressed
  reg        s1_v, s1_first, s1_last;
  reg  [7:0] s1_mx;
  wire [7:0] s1_d = s1_mx - ring_s_q;
  always @(posedge clk) begin
    if (rst) s1_v <= 1'b0; else s1_v <= s_rd;
    s1_first <= (s_posx == 10'd0);
    s1_last  <= s_rdlast;
    s1_mx    <= s_mxx;
  end

  wire [31:0] tab_s_q;
  mbxr_smx_ram #(.AW(8), .DW(32)) u_tab_s (
    .clk(clk), .we(tab_we), .wa(cfg_addr[7:0]), .wd(cfg_wdata),
    .re(1'b1), .ra(s1_d), .rd(tab_s_q));

  // ring O: d, written by S, read by O
  wire [7:0] ring_o_q;
  wire       o_rd;
  mbxr_smx_ram #(.AW(RAW), .DW(8)) u_ring_o (
    .clk(clk), .we(s1_v), .wa(s_wp[RAW-1:0]), .wd(s1_d),
    .re(o_rd), .ra(o_rp[RAW-1:0]), .rd(ring_o_q));
  always @(posedge clk) begin
    if (rst) s_wp <= {(RAW+1){1'b0}};
    else if (s1_v) s_wp <= s_wp + 1'b1;
  end

  // S2: ev on tab_s_q; accumulate
  reg         s2_v, s2_first, s2_last;
  reg  [41:0] s_acc;
  wire [41:0] s_acc_n = (s2_first ? 42'd0 : s_acc) + {10'd0, tab_s_q};
  always @(posedge clk) begin
    if (rst) s2_v <= 1'b0; else s2_v <= s1_v;
    s2_first <= s1_first;
    s2_last  <= s1_last;
    if (s2_v) s_acc <= s_acc_n;
  end

  // the row's sum waits here while the divider finishes the previous row (s_rows <= 2 means
  // it never waits behind more than one)
  reg         h_v;
  reg  [41:0] h_sum;
  wire        dv_busy, dv_zero;
  wire [32:0] dv_inv;
  wire        h_new   = s2_v & s2_last;
  wire        dv_load = h_v & ~dv_busy;
  always @(posedge clk) begin
    if (rst) begin
      h_v <= 1'b0; so_wp <= 3'd0; e_sum <= 1'b0;
    end else begin
      if (err_clr) e_sum <= 1'b0;
      if (h_new) begin
        h_v   <= 1'b1;
        h_sum <= s_acc_n;
      end else if (dv_load) begin
        h_v <= 1'b0;
      end
      if (dv_load && h_sum[41:31] == 11'd0) e_sum <= 1'b1;
      if (dv_push) so_wp <= so_wp + 3'd1;
    end
  end
  mbxr_smx_div #(.DIV_BPC(DIV_BPC)) u_div (
    .clk(clk), .rst(rst), .load(dv_load), .sum(h_sum),
    .busy(dv_busy), .done(dv_push), .inv(dv_inv), .zero(dv_zero));
  always @(posedge clk) if (dv_push) so_mem[so_wp[1:0]] <= {dv_zero, dv_inv};

  // ======================================================================================
  // stage O: per-element arithmetic
  // ======================================================================================
  reg          o_act;
  reg  [9:0]   o_pos;
  reg  [33:0]  o_desc;
  reg  [OFW:0] o_commit;                       // elements read by O and not yet taken
  wire         o_take;

  wire        o_credit = (o_commit != OCAP);
  wire        o_start  = ~o_act & (so_wp != so_rp) & o_credit;
  assign      o_rd     = (o_act & o_credit) | o_start;
  wire [9:0]  o_posx   = o_act ? o_pos : 10'd0;
  wire        o_rdlast = o_rd & (o_posx == c_km1);
  wire [33:0] o_descx  = o_act ? o_desc : so_mem[so_rp[1:0]];

  always @(posedge clk) begin
    if (rst) begin
      o_act <= 1'b0; o_pos <= 10'd0; o_rp <= {(RAW+1){1'b0}}; so_rp <= 3'd0;
      o_commit <= {(OFW+1){1'b0}};
    end else begin
      if (o_start) begin
        so_rp  <= so_rp + 3'd1;
        o_desc <= o_descx;
      end
      if (o_rd) begin
        o_rp  <= o_rp + 1'b1;
        o_pos <= o_posx + 10'd1;
        o_act <= ~o_rdlast;
      end
      o_commit <= o_commit + {{OFW{1'b0}}, o_rd} - {{OFW{1'b0}}, o_take};
    end
  end

  // O1: d on ring_o_q -> table
  reg        o1_v, o1_last;
  reg [33:0] o1_desc;
  always @(posedge clk) begin
    if (rst) o1_v <= 1'b0; else o1_v <= o_rd;
    o1_last <= o_rdlast;
    o1_desc <= o_descx;
  end
  wire [31:0] tab_o_q;
  mbxr_smx_ram #(.AW(8), .DW(32)) u_tab_o (
    .clk(clk), .we(tab_we), .wa(cfg_addr[7:0]), .wd(cfg_wdata),
    .re(1'b1), .ra(ring_o_q), .rd(tab_o_q));

  // O2: ev on tab_o_q, the row's {zero, q_hi, q_lo} beside it -> O3, O4 in mbxr_smx_elem
  reg        o2_v, o2_last;
  reg [33:0] o2_desc;
  always @(posedge clk) begin
    if (rst) o2_v <= 1'b0; else o2_v <= o1_v;
    o2_last <= o1_last;
    o2_desc <= o1_desc;
  end
  wire       o4_v, o4_last;
  wire [7:0] r_y;
  mbxr_smx_elem u_elem (
    .clk(clk), .rst(rst), .in_v(o2_v), .in_last(o2_last), .ev(tab_o_q), .desc(o2_desc),
    .om(c_om), .s(c_s), .out_v(o4_v), .out_last(o4_last), .y(r_y));

  // output FIFO (credit-checked at O's read, so it never overflows)
  reg [8:0]   of_mem [0:(1<<OFW)-1];
  reg [OFW:0] of_wp, of_rp;
  always @(posedge clk) if (o4_v) of_mem[of_wp[OFW-1:0]] <= {o4_last, r_y};
  always @(posedge clk) begin
    if (rst) begin
      of_wp <= {(OFW+1){1'b0}}; of_rp <= {(OFW+1){1'b0}};
    end else begin
      if (o4_v)   of_wp <= of_wp + 1'b1;
      if (o_take) of_rp <= of_rp + 1'b1;
    end
  end
  assign out_valid = (of_wp != of_rp);
  assign {out_last, out_data} = of_mem[of_rp[OFW-1:0]];
  assign o_take = out_valid & out_ready;

  assign idle = (i_pos == 10'd0) && (is_res == is_rp) && ~s_act && (s_rows == 2'd0) &&
                (so_res == so_rp) && ~o_act && (o_commit == {(OFW+1){1'b0}});
endmodule

/* verilator lint_off DECLFILENAME */

// ---- simple dual-port block RAM, registered read ------------------------------------------
module mbxr_smx_ram #(
  parameter AW = 8,
  parameter DW = 32
) (
  input  wire          clk,
  input  wire          we,
  input  wire [AW-1:0] wa,
  input  wire [DW-1:0] wd,
  input  wire          re,
  input  wire [AW-1:0] ra,
  output reg  [DW-1:0] rd
);
  (* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];
  always @(posedge clk) begin
    if (we) mem[wa] <= wd;
    if (re) rd <= mem[ra];
  end
endmodule

// ---- inv = floor((2^64 - 1) / sum) for sum >= 2^31, DIV_BPC quotient bits per cycle --------
// Non-restoring division from the partial remainder 2^(64-DIT) - 1 (< 2^31 <= sum, so the
// skipped quotient bits are 0), DIT iterations.  The quotient bit is NOT the sign of the new
// partial remainder, which makes it the restoring quotient exactly; the remainder is never
// used, so it is never corrected.  |P| <= sum < 2^42 fits 44 bits signed.  One iteration,
// P' = 2P + 1 -/+ sum, is ONE 45-bit carry chain: ({2P + 1, 1} + {sum ^ S, S}) >> 1 with S = 1
// to subtract (the low pair 1 + S carries S in).  `done` is high in the last busy cycle, with
// the quotient on `inv` combinationally.
module mbxr_smx_div #(
  parameter DIV_BPC = 6
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        load,
  input  wire [41:0] sum,
  output reg         busy,
  output wire        done,
  output wire [32:0] inv,
  output reg         zero
);
  localparam integer DCYC = (33 + DIV_BPC - 1) / DIV_BPC;   // cycles per row
  localparam integer DIT  = DCYC * DIV_BPC;                  // quotient bits computed, >= 33
  reg  [5:0]         cnt;
  reg  signed [43:0] p;
  reg  [41:0]        d;
  reg  [DIT-1:0]     q;
  reg  signed [43:0] nr_p;
  /* verilator lint_off UNUSEDSIGNAL */      // nr_t[0]: the carry-in pair; nr_q above bit 32: 0
  reg  [44:0]        nr_t;
  reg  [DIT-1:0]     nr_q;
  /* verilator lint_on UNUSEDSIGNAL */
  reg                nr_sub;
  integer j;
  always @* begin
    nr_p = p;
    nr_q = q;
    for (j = 0; j < DIV_BPC; j = j + 1) begin
      nr_sub = ~nr_p[43];
      nr_t   = {nr_p[42:0], 1'b1, 1'b1} + {{2'b00, d} ^ {44{nr_sub}}, nr_sub};
      nr_p   = nr_t[44:1];
      nr_q   = {nr_q[DIT-2:0], ~nr_p[43]};
    end
  end
  assign done = busy & (cnt == 6'd1);
  assign inv  = nr_q[32:0];
  always @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
    end else if (load) begin
      busy <= 1'b1;
      cnt  <= DCYC[5:0];
      p    <= {{(DIT-20){1'b0}}, {(64-DIT){1'b1}}};          // 2^(64-DIT) - 1
      d    <= sum;
      q    <= {DIT{1'b0}};
      zero <= (sum == 42'd0);
    end else if (busy) begin
      p   <= nr_p;
      q   <= nr_q;
      cnt <= cnt - 6'd1;
      if (cnt == 6'd1) busy <= 1'b0;
    end
  end
endmodule

// ---- one element: ev and its row's {zero, q_hi, q_lo} in, the int8 out 2 cycles later -------
//   m1  = ev * q_lo                                                      (registered)
//   p32 = ev*q_hi + (m1 >> 32)  (< 2^32 because ev <= sum);  m2 = p32 * om (registered)
//   p   = (m2 + 2^30) >> 31 (mod 2^33);  (p + 2^(s-1)) >> s as ((2p >> s) + 1) >> 1;
//   y   = (p + 128) >> 8 saturated at 127, or 0 for a row whose sum was 0
module mbxr_smx_elem (
  input  wire        clk,
  input  wire        rst,
  input  wire        in_v,
  input  wire        in_last,
  input  wire [31:0] ev,
  input  wire [33:0] desc,
  input  wire [31:0] om,
  input  wire [5:0]  s,
  output reg         out_v,
  output reg         out_last,
  output wire [7:0]  y
);
  /* verilator lint_off UNUSEDSIGNAL */   // m1[31:0], m2[29:0], r_ps1[0], r_v: bits the C drops
  reg  [63:0] m1;
  reg         v3, last3, zero3, qhi3, zero4;
  reg  [31:0] ev3;
  reg  [63:0] m2;
  wire [31:0] p32 = m1[63:32] + (qhi3 ? ev3 : 32'd0);
  always @(posedge clk) begin
    m1    <= ev * desc[31:0];
    if (rst) v3 <= 1'b0; else v3 <= in_v;
    last3 <= in_last;
    zero3 <= desc[33];
    qhi3  <= desc[32];
    ev3   <= ev;
    m2    <= p32 * om;
    if (rst) out_v <= 1'b0; else out_v <= v3;
    out_last <= last3;
    zero4    <= zero3;
  end
  wire [32:0] r_p   = m2[63:31] + {32'd0, m2[30]};
  wire [33:0] r_p2  = {r_p, 1'b0} >> s;
  wire [33:0] r_ps1 = r_p2 + 34'd1;
  wire [32:0] r_ps  = r_ps1[33:1];
  wire [32:0] r_v   = r_ps + 33'd128;
  /* verilator lint_on UNUSEDSIGNAL */
  assign y = zero4 ? 8'd0 : ((r_ps >= 33'd32640) ? 8'd127 : {1'b0, r_v[14:8]});
endmodule

// Registers every port, so the out-of-context numbers are register to register.  (The
// registered ready/valid is not a protocol-correct wrapper; it exists only for timing.)
module mbxr_smx_ooc #(
  parameter RAW     = 11,
  parameter DIV_BPC = 6,
  parameter OFW     = 3
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [8:0]  cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        in_valid,
  output reg         in_ready,
  input  wire [7:0]  in_data,
  input  wire        in_last,
  output reg         out_valid,
  input  wire        out_ready,
  output reg  [7:0]  out_data,
  output reg         out_last,
  output reg         idle,
  output reg  [3:0]  err
);
  reg        rst_q, cfg_we_q, in_valid_q, in_last_q, out_ready_q;
  reg [8:0]  cfg_addr_q;
  reg [31:0] cfg_wdata_q;
  reg [7:0]  in_data_q;
  wire       w_in_ready, w_out_valid, w_out_last, w_idle;
  wire [7:0] w_out_data;
  wire [3:0] w_err;
  always @(posedge clk) begin
    rst_q <= rst; cfg_we_q <= cfg_we; cfg_addr_q <= cfg_addr; cfg_wdata_q <= cfg_wdata;
    in_valid_q <= in_valid; in_data_q <= in_data; in_last_q <= in_last; out_ready_q <= out_ready;
    in_ready <= w_in_ready; out_valid <= w_out_valid; out_data <= w_out_data;
    out_last <= w_out_last; idle <= w_idle; err <= w_err;
  end
  mbxr_smx #(.RAW(RAW), .DIV_BPC(DIV_BPC), .OFW(OFW)) u (
    .clk(clk), .rst(rst_q), .cfg_we(cfg_we_q), .cfg_addr(cfg_addr_q), .cfg_wdata(cfg_wdata_q),
    .in_valid(in_valid_q), .in_ready(w_in_ready), .in_data(in_data_q), .in_last(in_last_q),
    .out_valid(w_out_valid), .out_ready(out_ready_q), .out_data(w_out_data),
    .out_last(w_out_last), .idle(w_idle), .err(w_err));
endmodule

`default_nettype wire
