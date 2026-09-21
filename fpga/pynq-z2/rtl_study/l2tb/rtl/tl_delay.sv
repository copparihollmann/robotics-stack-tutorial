// SIMULATION ONLY. TL channel delay slices for l2tb (S parameter).

module tl_slice #(parameter W = 8) (
  input  logic         clock,
  input  logic         reset,
  input  logic         in_valid,
  output logic         in_ready,
  input  logic [W-1:0] in_bits,
  output logic         out_valid,
  input  logic         out_ready,
  output logic [W-1:0] out_bits
);
  // Two-entry FIFO == chisel Queue(2): registered ready, one cycle latency, full throughput.
  logic [W-1:0] mem0, mem1;
  logic [1:0]   cnt;
  logic         enq, deq;
  assign in_ready  = cnt != 2'd2;
  assign out_valid = cnt != 2'd0;
  assign out_bits  = mem0;
  assign enq = in_valid && in_ready;
  assign deq = out_valid && out_ready;
  always_ff @(posedge clock) begin
    if (reset) begin
      cnt <= 2'd0;
    end else begin
      case ({enq, deq})
        2'b10: begin
          if (cnt == 2'd0) mem0 <= in_bits; else mem1 <= in_bits;
          cnt <= cnt + 2'd1;
        end
        2'b01: begin
          mem0 <= mem1;
          cnt  <= cnt - 2'd1;
        end
        2'b11: begin
          if (cnt == 2'd1) mem0 <= in_bits;
          else begin mem0 <= mem1; mem1 <= in_bits; end
        end
        default: ;
      endcase
    end
  end
endmodule

// A chain of MAXS slices with a runtime tap: s = 0 is a wire, s = k is k slices.
module tl_delay #(parameter W = 8, parameter MAXS = 6) (
  input  logic         clock,
  input  logic         reset,
  input  logic [3:0]   s,
  input  logic         in_valid,
  output logic         in_ready,
  input  logic [W-1:0] in_bits,
  output logic         out_valid,
  input  logic         out_ready,
  output logic [W-1:0] out_bits
);
  logic         tv [0:MAXS];
  logic         tr [0:MAXS];
  logic [W-1:0] tb [0:MAXS];
  assign tv[0] = in_valid;
  assign tb[0] = in_bits;
  assign in_ready = tr[0];
  genvar k;
  generate
    for (k = 1; k <= MAXS; k++) begin : g
      logic sv, sr;
      logic [W-1:0] sb;
      tl_slice #(.W(W)) sl (.clock(clock), .reset(reset),
        .in_valid(tv[k-1] && (k <= s)), .in_ready(sr), .in_bits(tb[k-1]),
        .out_valid(tv[k]), .out_ready(tr[k]), .out_bits(tb[k]));
      assign tr[k-1] = (k - 1 == s) ? out_ready : sr;
    end
  endgenerate
  assign tr[MAXS] = (s == MAXS) ? out_ready : 1'b0;
  assign out_valid = tv[s];
  assign out_bits  = tb[s];
endmodule

