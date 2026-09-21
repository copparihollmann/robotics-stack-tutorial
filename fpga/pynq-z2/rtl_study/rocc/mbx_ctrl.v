// -----------------------------------------------------------------------------
// MBX control front end -- what a decoupled unit costs before any arithmetic.
//
// This is the part with no equivalent in the packed-SIMD extension.  An
// ALU-integrated op has NO control: operands arrive in the operand muxes, the
// result goes to mem_reg_wdata, and the core's existing scoreboard does the rest
// (PEXT_FEASIBILITY.md section 3: "alu.io.out goes to one register, not to a
// live bypass").  A RoCC op decodes its own command, keeps its own descriptors,
// generates its own addresses, tracks its own outstanding loads, reorders the
// data that comes back and produces its own response.  All of that is here.
//
// The plumbing OUTSIDE this module -- RoccCommandRouter, the response RRArbiter,
// the extra D-cache arbiter port (LazyRoCC.scala:94) and the core-side rocc
// signals -- is a separate +984 LUT OOC, measured in PEXT_FEASIBILITY.md
// section 3(c) by elaborating WithAccumulatorRoCC.  This module sits behind it.
//
// DEPTH is the point of the whole exercise.  MEMORY_HIERARCHY.md section 5
// measures both harts at concurrency 1.01, because nMSHRs = 0 selects the
// blocking DCache and each hart can have exactly one cached miss in flight.  A
// unit with its own TileLink port can have DEPTH.  DEPTH = 1 is what the core
// already has; the delta from 1 to 4 to 8 is what that capability costs in LUTs.
// -----------------------------------------------------------------------------
module mbx_ctrl #(
  parameter DEPTH = 4,          // outstanding loads in flight
  parameter NCH   = 4           // channels per MAC pass (= weight words per group)
) (
  input  wire        clk,
  input  wire        rst,

  // ---- RoCC command interface (the shape of RoCCCommand) --------------------
  input  wire        cmd_valid,
  output wire        cmd_ready,
  input  wire [6:0]  cmd_funct,
  input  wire [63:0] cmd_rs1,
  input  wire [63:0] cmd_rs2,
  input  wire [4:0]  cmd_rd,
  input  wire        cmd_xd,

  // ---- RoCC response --------------------------------------------------------
  output wire        resp_valid,
  input  wire        resp_ready,
  output wire [4:0]  resp_rd,
  output wire [63:0] resp_data,
  output wire        busy,

  // ---- memory: request / out-of-order response / result store ---------------
  output wire [39:0] req_addr,
  output wire        req_valid,
  input  wire        req_ready,
  output wire [2:0]  req_tag,
  input  wire        rsp_valid,
  input  wire [2:0]  rsp_tag,
  input  wire [63:0] rsp_data,
  output wire [39:0] st_addr,
  output wire        st_valid,

  // ---- to the datapath ------------------------------------------------------
  output wire [63:0]        act_word,
  output wire [64*NCH-1:0]  wgt_word,
  output wire               mac_en,
  output wire               mac_clr,
  output wire               quant_en,
  output wire [3:0]         blk,        // output-channel block index: the accumulator
                                        // file address, so the file is real state and
                                        // not four flops the optimiser can fold away
  input  wire [63:0]        acc_probe
);
  localparam TW   = 3;
  localparam SLOT = NCH + 1;    // one activation word + NCH weight words

  // ---- descriptors ----------------------------------------------------------
  reg [39:0] abase, wbase, obase;
  reg [15:0] ngroups, nblocks;
  reg [15:0] astride, wstride, ostride;

  // ---- sequencer ------------------------------------------------------------
  reg [15:0] g, b;
  reg        run;
  wire       last_g = (g + 16'd1) == ngroups;
  wire       last_b = (b + 16'd1) == nblocks;

  // ---- outstanding-load table ----------------------------------------------
  // Allocated on issue, freed on response.  ent_slot is the reorder function:
  // responses may come back in any order, and each carries the tag that says
  // which operand slot of the current group it belongs in.
  reg [DEPTH-1:0] ent_v;
  reg [2:0]       ent_slot [0:DEPTH-1];
  reg [63:0]      robuf    [0:SLOT-1];
  reg [SLOT-1:0]  have;

  wire [DEPTH-1:0] freev = ~ent_v;
  wire             havefree = |freev;
  integer          k;
  reg  [TW-1:0]    alloc;
  always @* begin
    alloc = {TW{1'b0}};
    for (k = DEPTH-1; k >= 0; k = k - 1) if (freev[k]) alloc = k[TW-1:0];
  end

  // slot 0 is the shared activation word, slots 1..NCH the NCH weight words
  reg  [2:0] phase;
  wire       want_w = (phase != 3'd0);
  wire [39:0] aaddr = abase + {24'd0, g} * {24'd0, astride};
  wire [39:0] waddr = wbase + ({24'd0, b} * {24'd0, wstride}) +
                              ({24'd0, g} * 40'd8 * NCH) +
                              ({37'd0, phase - 3'd1} <<< 3);

  assign req_addr  = want_w ? waddr : aaddr;
  assign req_valid = run && havefree && !have[phase];
  assign req_tag   = alloc;

  wire group_ready = &have;

  assign act_word = robuf[0];
  genvar c;
  generate
    for (c = 0; c < NCH; c = c + 1) begin : g_w
      assign wgt_word[c*64 +: 64] = robuf[c + 1];
    end
  endgenerate

  assign mac_en   = run && group_ready;
  assign mac_clr  = mac_en && (g == 16'd0);
  assign quant_en = run && group_ready && last_g;
  assign busy     = run;
  assign st_addr  = obase + {24'd0, b} * {24'd0, ostride};
  assign st_valid = quant_en;
  assign blk      = b[3:0];

  // NEVER deassert.  RocketCore.scala:792-796 turns a stalled RoCC command into
  // replay_wb_rocc -> take_pc_wb, which is a full pipeline flush and refetch,
  // not a stall.  PEXT_FEASIBILITY.md section 3(c) calls this "one sharp edge".
  assign cmd_ready = 1'b1;

  reg        rv;
  reg [4:0]  rrd;
  assign resp_valid = rv;
  assign resp_rd    = rrd;
  assign resp_data  = acc_probe;

  always @(posedge clk) begin
    if (rst) begin
      run <= 1'b0; g <= 16'd0; b <= 16'd0; phase <= 3'd0;
      ent_v <= {DEPTH{1'b0}}; have <= {SLOT{1'b0}}; rv <= 1'b0;
    end else begin
      if (rv && resp_ready) rv <= 1'b0;

      if (cmd_valid) begin
        case (cmd_funct)
          7'd0: begin abase   <= cmd_rs1[39:0]; astride <= cmd_rs2[15:0]; end
          7'd1: begin wbase   <= cmd_rs1[39:0]; wstride <= cmd_rs2[15:0]; end
          7'd2: begin obase   <= cmd_rs1[39:0]; ostride <= cmd_rs2[47:32];
                      ngroups <= cmd_rs2[15:0]; nblocks <= cmd_rs2[31:16]; end
          7'd3: begin run <= 1'b1; g <= 16'd0; b <= 16'd0; phase <= 3'd0;
                      have <= {SLOT{1'b0}}; ent_v <= {DEPTH{1'b0}}; end
          default: if (cmd_xd) begin rv <= 1'b1; rrd <= cmd_rd; end
        endcase
      end

      if (req_valid && req_ready) begin
        ent_v[alloc]    <= 1'b1;
        ent_slot[alloc] <= phase;
        phase <= (phase == (SLOT-1)) ? 3'd0 : phase + 3'd1;
      end

      if (rsp_valid) begin
        ent_v[rsp_tag]            <= 1'b0;
        robuf[ent_slot[rsp_tag]]  <= rsp_data;
        have[ent_slot[rsp_tag]]   <= 1'b1;
      end

      if (mac_en) begin
        have  <= {SLOT{1'b0}};
        phase <= 3'd0;
        if (last_g) begin
          g <= 16'd0;
          b <= b + 16'd1;
          if (last_b) run <= 1'b0;
        end else begin
          g <= g + 16'd1;
        end
      end
    end
  end
endmodule
