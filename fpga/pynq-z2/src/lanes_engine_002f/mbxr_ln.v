// SPDX-License-Identifier: Apache-2.0
//
// mbxr_ln -- a row-streaming normalisation lane for the Moonshine encoder: LayerNorm and
// GroupNorm on one datapath.  An OUT-OF-CONTEXT STUDY (fpga/pynq-z2/docs/LAYERNORM_LANE.md;
// ROCC_DECOUPLED.md s8.14's "LayerNorm lane"): no SoC, no MAGIC, no bitstream.
//
// Bit-exact with the q16 normalisation core -- kernel_layernorm_pc_s8, kernel_layernorm_s16_s8
// and kernel_groupnorm_s16 of zephyr-chipyard-sw/modelblaster/pipeline/reference_kernels.py
// (and so with the curated pext_nl/pext_nl_groupnorm_s16_pext_int_memo.c, which the q16 gates
// show is bit-exact with that reference).  Checked in Verilator by ln_lane/tb_ln.cpp against
// that C.  NOT the as-extracted kernel_layernorm_s8 (pext_int_rsqrt): that one is
// accuracy_class numeric_drift and belongs to the extraction s8.13 measures at 120.5 % WER.
//
// ---- the specification -------------------------------------------------------------------
//   u_k = x_k * umul[c]        S = SUM u_k        Q = SUM u_k^2        c = floor(k / HW)
//   V   = K*Q - S^2 + eps_q
//   R   = isqrt(floor(2^120 / V))
//   t_k = floor((K*u_k - S) * R / 2^44)                    (arithmetic shift: floor)
//   y_k = clamp(floor((t_k*gmul[c] + badd[c]*2^16 + 2^31) / 2^32))
// HW = 1 gives LayerNorm (affine per position); HW = 999 gives the stem's GroupNorm (affine
// per channel, 999 positions each).  umul = 1, kumul = K give the per-tensor forms
// (layernorm_s16_s8, groupnorm_s16); layernorm_pc_s8 uses the Q24 per-position scales.
// Software writes umul[c], kumul[c] = K*umul[c], gmul[c] and badd[c] once per dispatch while
// the lane is idle, exactly as s8.15.8's softmax lane is given ex[256], om and s.
//
// ---- the reciprocal square root ----------------------------------------------------------
// floor(sqrt(floor(n/d))) == floor(sqrt(n/d)) for integers, so R is the unique integer with
//     R^2 * V <= 2^120 < (R+1)^2 * V,  i.e.  R = floor(2^60 / sqrt(V)).
// It is an exact 61-bit floor, so a Newton iteration (what int_rsqrt_q31 does in software, to
// 31 bits) cannot produce it without a final exact correction that costs more than computing
// it outright.  Two restoring digit recurrences do it with no multiplier at all, one bit per
// cycle, sharing a single 97-bit add/subtract with the K*Q and S^2 multiplies before them:
//     1 + K*Q 20 + S^2 44 + V 1 + 2^120/V 121 + isqrt 61 + 1 = 249 cycles per row,
// and they run while the next row is ingested, so for K >= 249 they cost nothing.
//
// ---- architecture: three row stages that overlap (one-pass), or two phases (two-pass) -----
//   I  ingest   one element per handshake; u = x*umul[c]; S += u; Q += u*u; x into the ring.
//   R  row      the 249-cycle serial unit above; hands {S, R} to a 2-deep queue.
//   A  apply    one element per handshake out; w = x*kumul[c] (= K*u); d = w - S;
//               t = (d*R) >>> 44; y = clamp((t*gmul[c] + bb[c]) >>> 32).
// One-pass (two_pass = 0, K <= 2**KL2): A reads x back from a 4-row ring, so the source sends
// each row once and three rows are in flight -- K cycles per row, 1.000 cycles per element.
// Two-pass (two_pass = 1): no ring is big enough -- the stem's GroupNorm reduces over 287,712
// int16 values in ONE row -- so the source sends the row twice, I takes the first copy and A
// the second.  2K + 249 cycles per row, 2.000 input cycles per output element.
//
// ---- what is supported, and what is refused ----------------------------------------------
//  * PRECONDITION eps_q in (2^18, 2^63), hence V > 2^18, hence R < 2^51: the d*R multiplier
//    then needs three 17-bit chunks of R rather than four.  Moonshine's smallest eps_q is
//    398,648 (layers.0.input_layernorm); the other thirteen are >= 1.3e13.  A configuration
//    that breaks it is refused by err[0], the discipline of s8.15.8's err[0].
//  * err[2]: R >= 2^51 despite that (cannot happen; checked, not assumed).
//  * err[3]: a range -- |u| >= 2^32, |S| >= 2^42, Q >= 2^73, K*Q >= 2^84, V >= 2^84, V < 0,
//    |w| = |K*u| >= 2^40, or the affine index c >= 2**TL2.
//  * err[4]: |t| >= 2^26.  |t| <= sqrt(K)*2^16 follows from SUM d_k^2 = K*(V - eps_q), which
//    is 2^25.07 at GroupNorm's K, so this is unreachable too and is likewise checked.
//    Inside these ranges no intermediate of the reference overflows int64 or __int128 either,
//    so "bit-exact" is unconditional there.
//  * gmul and badd are int64 in the reference and int32 in this lane's table, which is the
//    supported range for them (Moonshine's widest is the stem's gmul, 250,595,132).
//  * err[1] configuration written while busy      err[5] in_last disagreed with K
//  A row that raises err[2..4] still produces K outputs, so the stream length never depends on
//  the data; software reads err after the dispatch and recomputes it if any bit is set.
//
// Configuration map (cfg_we, while idle; a write while busy sets err[1]):
//   cfg_addr[12] = 0 : affine table, {index[TL2-1:0], word[2:0]}
//       word 0 umul[24:0]   1 kumul[31:0]   2 kumul[39:32]   3 gmul[31:0]   4 badd[31:0]
//       Words 1..3 stage into a register and word 4 commits the entry, so the apply-side
//       table has a single full-width write port: write the five words of an index in order.
//   cfg_addr[12] = 1 (cfg_addr[2:0] selects):
//       0 K[19:0]   1 HW[19:0]   2 eps_q[31:0]   3 eps_q[63:32]
//       4 flags {2: two_pass, 1: out16, 0: in16}          5 clear err[5:1]

`default_nettype none

module mbxr_ln #(
  parameter KL2 = 9,      // one-pass rows: K <= 2**KL2
  parameter TL2 = 9,      // affine table depth (number of distinct c)
  parameter OFW = 4       // log2 output FIFO depth; must exceed the 9-stage apply pipeline
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [12:0] cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        in_valid,
  output wire        in_ready,
  input  wire [15:0] in_data,
  input  wire        in_last,
  output wire        out_valid,
  input  wire        out_ready,
  output wire [15:0] out_data,
  output wire        out_last,
  output wire        idle,
  output wire [5:0]  err
);
  localparam [OFW:0] OCAP = {1'b1, {OFW{1'b0}}};

  // ======================================================================================
  // configuration
  // ======================================================================================
  reg  [19:0] c_k, c_hw;
  reg  [63:0] c_eps;
  reg         c_in16, c_out16, c_tp;
  reg         c_kok;
  reg         e_busy, e_eps, e_rng, e_t, e_last;
  reg         rng_w;      // |K*u| out of range, seen in the apply stage; latched into e_rng
                          // by the row-unit block below, so e_rng has ONE driver.  Driving a
                          // reg from two always blocks is legal to Verilator (it merges them)
                          // and illegal to Vivado (DRC MDRV-1): see LAYERNORM_LANE.md s15.

  wire           tab_we = cfg_we & ~cfg_addr[12];
  wire [TL2-1:0] tab_wa = cfg_addr[TL2+2:3];

  always @(posedge clk) begin
    if (rst) begin
      c_k <= 20'd0; c_hw <= 20'd1; c_eps <= 64'd0;
      c_in16 <= 1'b0; c_out16 <= 1'b0; c_tp <= 1'b0; c_kok <= 1'b0; e_busy <= 1'b0;
    end else if (cfg_we) begin
      if (!idle) e_busy <= 1'b1;
      if (cfg_addr[12]) begin
        case (cfg_addr[2:0])
          3'd0: begin
            c_k   <= cfg_wdata[19:0];
            c_kok <= (cfg_wdata[31:20] == 12'd0) && (cfg_wdata[19:0] != 20'd0);
          end
          3'd1: c_hw <= cfg_wdata[19:0];
          3'd2: c_eps[31:0]  <= cfg_wdata;
          3'd3: c_eps[63:32] <= cfg_wdata;
          3'd4: begin c_in16 <= cfg_wdata[0]; c_out16 <= cfg_wdata[1]; c_tp <= cfg_wdata[2]; end
          3'd5: e_busy <= 1'b0;
          default: ;
        endcase
      end
    end
  end
  wire err_clr = cfg_we & cfg_addr[12] & (cfg_addr[2:0] == 3'd5);

  wire [20:0] kmax   = 21'd1 << KL2;
  wire        k_fits = c_tp | ({1'b0, c_k} <= kmax);
  wire        cfg_ok = c_kok & k_fits & (c_hw != 20'd0)
                     & (c_eps > 64'd262144) & ~c_eps[63];
  assign err = {e_last, e_t, e_rng, e_eps, e_busy, ~cfg_ok};

  // ======================================================================================
  // memories: affine tables (TAB_U for ingest, TAB_A for apply) and the one-pass row ring
  // ======================================================================================
  wire [24:0]  tu_q;
  wire [103:0] ta_q;
  wire [15:0]  ring_q;

  // ======================================================================================
  // forward declarations used by the admission logic
  // ======================================================================================
  reg  [2:0]   a_rid;
  reg          a_armed, tp_busy;
  reg  [19:0]  a_pos, a_hwc;
  reg  [TL2:0] a_c;
  reg  [1:0]   q_ir_cnt, q_ra_cnt, q_ir_res;

  // ======================================================================================
  // stage I: ingest and reduce -- one pass, S and Q together
  // ======================================================================================
  reg  [19:0]  i_pos, i_hwc;
  reg  [TL2:0] i_c;
  reg  [2:0]   i_rid;
  reg          i_run;

  wire i_room  = c_tp | ((i_rid - a_rid) != 3'd4);
  wire i_owns  = ~c_tp | ~tp_busy;      // two-pass: no new row until the apply pass is done
  wire i_admit = i_room & (q_ir_res != 2'd2) & i_owns;
  wire i_rdy   = cfg_ok & i_owns & (i_run | i_admit);
  wire i_fire  = in_valid & i_rdy;
  wire i_lastp = (i_pos == c_k - 20'd1);
  wire i_hwlst = (i_hwc == c_hw - 20'd1);

  wire signed [15:0] i_x = c_in16 ? $signed(in_data) : $signed({{8{in_data[7]}}, in_data[7:0]});

  reg                v1, v2, v3;
  reg                f1, f2, f3;         // first element of its row
  reg                z1, z2, z3;         // last element of its row
  reg                r1, r2, r3;         // row parity: which accumulator bank
  reg  signed [15:0] x1;
  reg  signed [32:0] u2, u3;
  reg         [65:0] uu3;
  reg                ov2, ov3;
  reg  signed [43:0] acc_s [0:1];
  reg         [73:0] acc_q [0:1];
  reg                acc_e [0:1];

  wire signed [41:0] u_raw = x1 * $signed({1'b0, tu_q});
  wire               u_ovf = (u_raw[41:32] != {10{u_raw[32]}}) | i_c[TL2];
  wire        [32:0] u2abs = u2[32] ? (~u2 + 33'd1) : u2;
  wire signed [43:0] s_add = (f3 ? 44'sd0 : acc_s[r3]) + {{11{u3[32]}}, u3};
  wire        [73:0] q_add = (f3 ? 74'd0  : acc_q[r3]) + {8'd0, uu3};
  wire               e_add = (f3 ? 1'b0   : acc_e[r3]) | ov3
                           | (s_add[43] ^ s_add[42]) | q_add[73];

  // stage 1 x and umul, stage 2 u = x*umul, stage 3 u*u and both accumulators
  always @(posedge clk) begin
    if (rst) begin
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
    end else begin
      v1 <= i_fire; v2 <= v1; v3 <= v2;
    end
    f1 <= i_fire & (i_pos == 20'd0); f2 <= f1; f3 <= f2;
    z1 <= i_fire & i_lastp;          z2 <= z1; z3 <= z2;
    r1 <= i_rid[0];                  r2 <= r1; r3 <= r2;
    if (i_fire) x1 <= i_x;
    if (v1) begin u2 <= u_raw[32:0]; ov2 <= u_ovf; end
    if (v2) begin u3 <= u2; uu3 <= u2abs * u2abs; ov3 <= ov2; end
    if (v3) begin acc_s[r3] <= s_add; acc_q[r3] <= q_add; acc_e[r3] <= e_add; end
  end

  always @(posedge clk) begin
    if (rst) begin
      i_pos <= 20'd0; i_hwc <= 20'd0; i_c <= {(TL2+1){1'b0}}; i_rid <= 3'd0; i_run <= 1'b0;
      e_last <= 1'b0;
    end else begin
      if (err_clr) e_last <= 1'b0;
      if (i_fire) begin
        if (in_last != i_lastp) e_last <= 1'b1;
        if (i_lastp) begin
          i_pos <= 20'd0; i_hwc <= 20'd0; i_c <= {(TL2+1){1'b0}};
          i_rid <= i_rid + 3'd1; i_run <= 1'b0;
        end else begin
          i_pos <= i_pos + 20'd1;
          i_run <= 1'b1;
          if (i_hwlst) begin i_hwc <= 20'd0; i_c <= i_c + 1'b1; end
          else i_hwc <= i_hwc + 20'd1;
        end
      end
    end
  end

  // ======================================================================================
  // stage R: K*Q, S^2, V, 2^120/V, isqrt -- one shared 97-bit add/subtract, no multiplier
  // ======================================================================================
  localparam [2:0] RS_IDLE=3'd0, RS_KQ=3'd1, RS_S2=3'd2, RS_V1=3'd3,
                   RS_V2=3'd7, RS_DIV=3'd4, RS_SQR=3'd5, RS_DONE=3'd6;
  reg  [2:0]   rs;
  /* verilator lint_off UNUSEDSIGNAL */
  reg  [96:0]  acc;            // [96] is the guard bit of the shared add/subtract
  reg  [95:0]  kq;
  reg  [83:0]  vq;
  reg  [121:0] dq;
  reg  [60:0]  root;
  reg  [6:0]   rcnt;
  /* verilator lint_on UNUSEDSIGNAL */
  reg  signed [43:0] rs_s;
  reg         [73:0] rs_q;
  reg         [43:0] rs_sa;
  reg          rs_bad;

  reg  signed [43:0] q_ir_s [0:1];
  reg         [73:0] q_ir_q [0:1];
  reg                q_ir_e [0:1];
  reg                q_ir_wp, q_ir_rp;
  wire               ir_push = v3 & z3;
  wire               ir_pop  = (rs == RS_IDLE) & (q_ir_cnt != 2'd0);

  wire [96:0] acc2 = {acc[95:0], 1'b0};
  wire [96:0] acc4 = {acc[94:0], dq[121:120]};
  wire [96:0] trl  = {34'd0, root[60:0], 2'b01};
  // one 98-bit add/subtract serves K*Q, S^2, V, the division and the square root
  wire [96:0] wa   = (rs == RS_SQR) ? acc4 :
                     (rs == RS_V1)  ? {1'b0, kq} :
                     (rs == RS_V2)  ? acc : acc2;
  wire [96:0] wb   = (rs == RS_KQ)  ? {23'd0, rs_q} :
                     (rs == RS_S2)  ? {53'd0, rs_sa} :
                     (rs == RS_V1)  ? acc :
                     (rs == RS_V2)  ? {33'd0, c_eps} :
                     (rs == RS_DIV) ? {13'd0, vq} : trl;
  wire        wsub = (rs == RS_DIV) | (rs == RS_SQR) | (rs == RS_V1);
  wire [97:0] wsum = {1'b0, wa} + (wsub ? (~{1'b0, wb} + 98'd1) : {1'b0, wb});
  wire        wge  = ~wsum[97];
  wire        kbit = c_k[rcnt[4:0]];
  wire        sbit = rs_sa[rcnt[5:0]];


  reg  signed [43:0] q_ra_s [0:1];
  reg         [50:0] q_ra_r [0:1];
  reg                q_ra_wp, q_ra_rp;
  wire               ra_push = (rs == RS_DONE) & (q_ra_cnt != 2'd2);
  // the next row's descriptor is taken in the SAME cycle as the current row's last element,
  // so the apply stage never idles between rows.  Its bank is the one the next row's elements
  // will carry; for K < 8 an element of the row before last could still be reading that bank,
  // so the early take is disabled there (those rows are bound by the 249-cycle unit anyway).
  wire               a_lastf = a_fire & a_lastp;
  wire               ra_pop  = (q_ra_cnt != 2'd0) & (~a_armed | (a_lastf & (|c_k[19:3])));
  wire               ra_bank = a_lastf ? ~a_rid[0] : a_rid[0];

  always @(posedge clk) begin
    if (rst) begin
      rs <= RS_IDLE; e_eps <= 1'b0; e_rng <= 1'b0;
    end else begin
      if (err_clr) begin e_eps <= 1'b0; e_rng <= 1'b0; end
      if (rng_w) e_rng <= 1'b1;
      case (rs)
        RS_IDLE: if (q_ir_cnt != 2'd0) begin
          rs_s   <= q_ir_s[q_ir_rp];
          rs_q   <= q_ir_q[q_ir_rp];
          rs_sa  <= q_ir_s[q_ir_rp][43] ? (~q_ir_s[q_ir_rp] + 44'd1) : q_ir_s[q_ir_rp];
          rs_bad <= q_ir_e[q_ir_rp];
          acc    <= 97'd0;
          rcnt   <= 7'd19;
          rs     <= RS_KQ;
        end
        RS_KQ: begin
          if (rcnt == 7'd0) begin
            kq <= kbit ? wsum[95:0] : acc2[95:0];
            acc <= 97'd0; rcnt <= 7'd43; rs <= RS_S2;
          end else begin
            acc <= kbit ? wsum[96:0] : acc2;
            rcnt <= rcnt - 7'd1;
          end
        end
        RS_S2: begin
          acc <= sbit ? wsum[96:0] : acc2;
          if (rcnt == 7'd0) rs <= RS_V1;
          else rcnt <= rcnt - 7'd1;
        end
        RS_V1: begin                       // K*Q - S^2, on the shared adder
          acc    <= wsum[96:0];
          rs_bad <= rs_bad | (|kq[95:84]) | wsum[97];
          if ((|kq[95:84]) | wsum[97]) e_rng <= 1'b1;
          rs     <= RS_V2;
        end
        RS_V2: begin                       // + eps_q, and V must fit 84 bits
          vq     <= wsum[83:0];
          rs_bad <= rs_bad | (|wsum[97:84]);
          if (|wsum[97:84]) e_rng <= 1'b1;
          acc    <= 97'd0;
          dq     <= 122'd0;
          rcnt   <= 7'd120;
          rs     <= RS_DIV;
        end
        RS_DIV: begin
          // the dividend 2^120 has one set bit, at j = 120
          if (rcnt == 7'd120) begin
            acc <= 97'd1; dq <= 122'd0; rcnt <= rcnt - 7'd1;
          end else begin
            acc <= wge ? wsum[96:0] : acc2;
            dq  <= {dq[120:0], wge};
            if (rcnt == 7'd0) begin
              rs <= RS_SQR; rcnt <= 7'd60; root <= 61'd0; acc <= 97'd0;
            end else rcnt <= rcnt - 7'd1;
          end
        end
        RS_SQR: begin
          acc  <= wge ? wsum[96:0] : acc4;
          root <= {root[59:0], wge};
          dq   <= {dq[119:0], 2'b00};
          if (rcnt == 7'd0) rs <= RS_DONE;
          else rcnt <= rcnt - 7'd1;
        end
        RS_DONE: if (q_ra_cnt != 2'd2) begin
          rs <= RS_IDLE;
          if (rs_bad | (|root[60:51])) e_rng <= 1'b1;
          if (|root[60:51]) e_eps <= 1'b1;
        end
        default: rs <= RS_IDLE;
      endcase
    end
  end

  // ======================================================================================
  // stage A: apply
  // ======================================================================================
  reg  signed [43:0] a_sb [0:1];
  reg         [50:0] a_rb [0:1];
  reg  [OFW:0]       o_res;


  wire a_credit = (o_res != OCAP);
  wire a_go     = cfg_ok & a_credit & a_armed;
  wire a_fire   = a_go & (c_tp ? in_valid : 1'b1);
  wire a_lastp  = (a_pos == c_k - 20'd1);
  wire a_hwlst  = (a_hwc == c_hw - 20'd1);

  reg                b1, b2, b3, b4, b5, b6, b7, b8;
  reg                y1, y2, y3, y4, y5, y6, y7, y8;
  reg                k1, k2, k3, k4;        // row parity carried with the element
  reg  signed [15:0] xa0, xa1;
  reg         [39:0] ku1;
  /* verilator lint_off UNUSEDSIGNAL */
  reg  signed [56:0] w2;       // [56:45] checked by w_ovf, then dropped
  reg  signed [97:0] pr5;      // [43:0] are the bits the >>> 44 discards
  reg  signed [59:0] qq6;      // [31:0] are the bits the >>> 32 discards
  /* verilator lint_on UNUSEDSIGNAL */
  reg  signed [44:0] d3;
  reg  signed [62:0] m4a, m4b, m4c;
  reg         [15:0] yy7;
  reg  signed [31:0] g1, g2, g3, g4, g5;
  reg  signed [48:0] bb1, bb2, bb3, bb4, bb5;

  wire signed [15:0] a_x  = c_in16 ? $signed(in_data) : $signed({{8{in_data[7]}}, in_data[7:0]});
  wire signed [15:0] xsrc = c_tp ? xa0 : $signed(ring_q);
  wire        [39:0] kum  = ta_q[39:0];
  wire signed [31:0] gml  = $signed(ta_q[71:40]);
  wire signed [31:0] bdd  = $signed(ta_q[103:72]);
  wire signed [56:0] w_raw = xa1 * $signed({1'b0, ku1});
  wire               w_ovf = (w_raw[56:40] != {17{w_raw[40]}}) | a_c[TL2];
  wire signed [97:0] pr_sum = {{35{m4a[62]}}, m4a}
                            + {{18{m4b[62]}}, m4b, 17'd0}
                            + {{ 1{m4c[62]}}, m4c, 34'd0};
  wire signed [53:0] t5    = pr5[97:44];
  wire               t_ovf = (t5[53:26] != {28{t5[26]}});
  wire signed [26:0] t5c   = t5[26:0];
  wire signed [27:0] yfull = qq6[59:32];
  wire signed [27:0] ymax  = c_out16 ? 28'sd32767  : 28'sd127;
  wire signed [27:0] ymin  = c_out16 ? -28'sd32768 : -28'sd128;

  always @(posedge clk) begin
    if (rst) begin
      b1<=1'b0; b2<=1'b0; b3<=1'b0; b4<=1'b0; b5<=1'b0; b6<=1'b0; b7<=1'b0; b8<=1'b0;
      e_t<=1'b0; rng_w<=1'b0;
    end else begin
      if (err_clr) e_t <= 1'b0;
      b1<=a_fire; b2<=b1; b3<=b2; b4<=b3; b5<=b4; b6<=b5; b7<=b6; b8<=b7;
      y1<=a_fire & a_lastp; y2<=y1; y3<=y2; y4<=y3; y5<=y4; y6<=y5; y7<=y6; y8<=y7;
      k1<=a_rid[0]; k2<=k1; k3<=k2; k4<=k3;
      if (a_fire) xa0 <= a_x;
      if (b1) begin
        xa1 <= xsrc; ku1 <= kum; g1 <= gml;
        bb1 <= {{1{bdd[31]}}, bdd, 16'd0} + 49'sh0_8000_0000;
      end
      rng_w <= b2 & w_ovf;
      if (b2) begin
        w2 <= w_raw; g2 <= g1; bb2 <= bb1;
      end
      if (b3) begin d3 <= w2[44:0] - {a_sb[k3][43], a_sb[k3]}; g3 <= g2; bb3 <= bb2; end
      if (b4) begin
        m4a <= d3 * $signed({1'b0, a_rb[k4][16:0]});
        m4b <= d3 * $signed({1'b0, a_rb[k4][33:17]});
        m4c <= d3 * $signed({1'b0, a_rb[k4][50:34]});
        g4 <= g3; bb4 <= bb3;
      end
      if (b5) begin pr5 <= pr_sum; g5 <= g4; bb5 <= bb4; end
      if (b6) begin
        qq6 <= t5c * g5 + $signed({{11{bb5[48]}}, bb5});
        if (t_ovf) e_t <= 1'b1;
      end
      if (b7) yy7 <= (yfull > ymax) ? ymax[15:0] : ((yfull < ymin) ? ymin[15:0] : yfull[15:0]);
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      a_pos <= 20'd0; a_hwc <= 20'd0; a_c <= {(TL2+1){1'b0}}; a_rid <= 3'd0;
      a_armed <= 1'b0; tp_busy <= 1'b0;
    end else begin
      if (c_tp & i_fire & i_lastp) tp_busy <= 1'b1;
      if (a_fire) begin
        if (a_lastp) begin
          a_pos <= 20'd0; a_hwc <= 20'd0; a_c <= {(TL2+1){1'b0}};
          a_rid <= a_rid + 3'd1; a_armed <= 1'b0; tp_busy <= 1'b0;
        end else begin
          a_pos <= a_pos + 20'd1;
          if (a_hwlst) begin a_hwc <= 20'd0; a_c <= a_c + 1'b1; end
          else a_hwc <= a_hwc + 20'd1;
        end
      end
      if (ra_pop) begin
        a_sb[ra_bank] <= q_ra_s[q_ra_rp]; a_rb[ra_bank] <= q_ra_r[q_ra_rp];
        a_armed <= 1'b1;
      end
    end
  end

  // ======================================================================================
  // memory ports
  // ======================================================================================
  wire [TL2-1:0] i_ca = i_c[TL2-1:0];
  wire [TL2-1:0] a_ca = a_c[TL2-1:0];
  // The apply-side entry is staged in a register and committed by its last word, so the array
  // has one full-width write port and infers block RAM; sub-range writes do not.
  reg  [71:0] tstage;
  wire        tu_we = tab_we & (cfg_addr[2:0] == 3'd0);
  wire        ta_we = tab_we & (cfg_addr[2:0] == 3'd4);
  always @(posedge clk) begin
    if (tab_we) begin
      case (cfg_addr[2:0])
        3'd1: tstage[31:0]  <= cfg_wdata;
        3'd2: tstage[39:32] <= cfg_wdata[7:0];
        3'd3: tstage[71:40] <= cfg_wdata;
        default: ;
      endcase
    end
  end
  mbxr_ln_ram #(.W(25),  .AW(TL2))   u_tab_u (.clk(clk), .we(tu_we), .wa(tab_wa),
      .wd(cfg_wdata[24:0]), .ra(i_ca), .rq(tu_q));
  mbxr_ln_ram #(.W(104), .AW(TL2))   u_tab_a (.clk(clk), .we(ta_we), .wa(tab_wa),
      .wd({cfg_wdata, tstage}), .ra(a_ca), .rq(ta_q));
  mbxr_ln_ram #(.W(16),  .AW(KL2+2)) u_ring  (.clk(clk), .we(i_fire & ~c_tp),
      .wa({i_rid[1:0], i_pos[KL2-1:0]}), .wd($unsigned(i_x)),
      .ra({a_rid[1:0], a_pos[KL2-1:0]}), .rq(ring_q));

  // ======================================================================================
  // the two row queues
  // ======================================================================================
  always @(posedge clk) begin
    if (rst) begin
      q_ir_cnt <= 2'd0; q_ir_wp <= 1'b0; q_ir_rp <= 1'b0; q_ir_res <= 2'd0;
      q_ra_cnt <= 2'd0; q_ra_wp <= 1'b0; q_ra_rp <= 1'b0;
    end else begin
      if (ir_push) begin
        q_ir_s[q_ir_wp] <= s_add; q_ir_q[q_ir_wp] <= q_add; q_ir_e[q_ir_wp] <= e_add;
        q_ir_wp <= ~q_ir_wp;
      end
      if (ir_pop) q_ir_rp <= ~q_ir_rp;
      q_ir_cnt <= q_ir_cnt + (ir_push ? 2'd1 : 2'd0) - (ir_pop ? 2'd1 : 2'd0);
      q_ir_res <= q_ir_res + ((i_fire & (i_pos == 20'd0)) ? 2'd1 : 2'd0)
                           - (ir_pop ? 2'd1 : 2'd0);
      if (ra_push) begin
        q_ra_s[q_ra_wp] <= rs_s; q_ra_r[q_ra_wp] <= root[50:0];
        q_ra_wp <= ~q_ra_wp;
      end
      if (ra_pop) q_ra_rp <= ~q_ra_rp;
      q_ra_cnt <= q_ra_cnt + (ra_push ? 2'd1 : 2'd0) - (ra_pop ? 2'd1 : 2'd0);
    end
  end

  // ======================================================================================
  // output FIFO
  // ======================================================================================
  reg  [16:0]  ofifo [0:(1<<OFW)-1];
  reg  [OFW:0] o_wp, o_rp;
  wire         o_pop = out_valid & out_ready;
  always @(posedge clk) begin
    if (rst) begin
      o_wp <= {(OFW+1){1'b0}}; o_rp <= {(OFW+1){1'b0}}; o_res <= {(OFW+1){1'b0}};
    end else begin
      if (b8) begin ofifo[o_wp[OFW-1:0]] <= {y8, yy7}; o_wp <= o_wp + 1'b1; end
      if (o_pop) o_rp <= o_rp + 1'b1;
      o_res <= o_res + {{OFW{1'b0}}, a_fire} - {{OFW{1'b0}}, o_pop};
    end
  end
  assign out_valid = (o_wp != o_rp);
  assign out_data  = ofifo[o_rp[OFW-1:0]][15:0];
  assign out_last  = ofifo[o_rp[OFW-1:0]][16];

  assign in_ready = c_tp ? (a_armed ? a_go : i_rdy) : i_rdy;
  assign idle = ~i_run & ~a_armed & ~tp_busy & (rs == RS_IDLE)
              & (q_ir_cnt == 2'd0) & (q_ra_cnt == 2'd0) & (q_ir_res == 2'd0) & ~out_valid
              & ~v1 & ~v2 & ~v3
              & ~b1 & ~b2 & ~b3 & ~b4 & ~b5 & ~b6 & ~b7 & ~b8;
endmodule

// Registers every port, so the out-of-context numbers are register to register.  (The
// registered ready/valid is not a protocol-correct wrapper; it exists only for timing.)
/* verilator lint_off DECLFILENAME */
// One write port, one registered read port: the simple-dual-port shape Vivado maps to block
// RAM.  Written as its own module because the same code inline in mbxr_ln is refused
// ("Infeasible attribute ram_style") and falls back to 2,281 LUTs of distributed RAM.
module mbxr_ln_ram #(parameter W = 16, parameter AW = 9) (
  input  wire          clk,
  input  wire          we,
  input  wire [AW-1:0] wa,
  input  wire [W-1:0]  wd,
  input  wire [AW-1:0] ra,
  output reg  [W-1:0]  rq
);
  (* ram_style = "block" *) reg [W-1:0] mem [0:(1<<AW)-1];
  always @(posedge clk) begin
    if (we) mem[wa] <= wd;
    rq <= mem[ra];
  end
endmodule

module mbxr_ln_ooc #(
  parameter KL2 = 9,
  parameter TL2 = 9,
  parameter OFW = 4
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        cfg_we,
  input  wire [12:0] cfg_addr,
  input  wire [31:0] cfg_wdata,
  input  wire        in_valid,
  output reg         in_ready,
  input  wire [15:0] in_data,
  input  wire        in_last,
  output reg         out_valid,
  input  wire        out_ready,
  output reg  [15:0] out_data,
  output reg         out_last,
  output reg         idle,
  output reg  [5:0]  err
);
  reg        rst_q, cfg_we_q, in_valid_q, in_last_q, out_ready_q;
  reg [12:0] cfg_addr_q;
  reg [31:0] cfg_wdata_q;
  reg [15:0] in_data_q;
  wire       w_in_ready, w_out_valid, w_out_last, w_idle;
  wire [15:0] w_out_data;
  wire [5:0] w_err;
  always @(posedge clk) begin
    rst_q <= rst; cfg_we_q <= cfg_we; cfg_addr_q <= cfg_addr; cfg_wdata_q <= cfg_wdata;
    in_valid_q <= in_valid; in_data_q <= in_data; in_last_q <= in_last;
    out_ready_q <= out_ready;
    in_ready <= w_in_ready; out_valid <= w_out_valid; out_data <= w_out_data;
    out_last <= w_out_last; idle <= w_idle; err <= w_err;
  end
  mbxr_ln #(.KL2(KL2), .TL2(TL2), .OFW(OFW)) u (
    .clk(clk), .rst(rst_q), .cfg_we(cfg_we_q), .cfg_addr(cfg_addr_q), .cfg_wdata(cfg_wdata_q),
    .in_valid(in_valid_q), .in_ready(w_in_ready), .in_data(in_data_q), .in_last(in_last_q),
    .out_valid(w_out_valid), .out_ready(out_ready_q), .out_data(w_out_data),
    .out_last(w_out_last), .idle(w_idle), .err(w_err));
endmodule

/* verilator lint_on DECLFILENAME */
`default_nettype wire
