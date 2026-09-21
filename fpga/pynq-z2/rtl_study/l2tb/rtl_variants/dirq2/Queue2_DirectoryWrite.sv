// SIMULATION WHAT-IF (l2tb, NOT generated RTL): 2-entry version of the generated Queue1_DirectoryWrite
// (same ports; chisel Queue(2) semantics: no flow, no pipe; enq.ready = !full, deq.valid = !empty).
module Queue2_DirectoryWrite(
  input         clock,
  input         reset,
  output        io_enq_ready,
  input         io_enq_valid,
  input  [7:0]  io_enq_bits_set,
  input  [1:0]  io_enq_bits_way,
  input         io_enq_bits_data_dirty,
  input  [1:0]  io_enq_bits_data_state,
  input  [1:0]  io_enq_bits_data_clients,
  input  [14:0] io_enq_bits_data_tag,
  input         io_deq_ready,
  output        io_deq_valid,
  output [7:0]  io_deq_bits_set,
  output [1:0]  io_deq_bits_way,
  output        io_deq_bits_data_dirty,
  output [1:0]  io_deq_bits_data_state,
  output [1:0]  io_deq_bits_data_clients,
  output [14:0] io_deq_bits_data_tag
);
  reg  [29:0] ram0, ram1;   // ram0 is the head
  reg  [1:0]  count;
  wire        do_enq = (count != 2'd2) & io_enq_valid;
  wire        do_deq = io_deq_ready & (count != 2'd0);
  wire [29:0] in = {io_enq_bits_data_tag, io_enq_bits_data_clients, io_enq_bits_data_state, io_enq_bits_data_dirty, io_enq_bits_way, io_enq_bits_set};
  always @(posedge clock) begin
    if (reset) count <= 2'd0;
    else begin
      case ({do_enq, do_deq})
        2'b10: begin if (count == 2'd0) ram0 <= in; else ram1 <= in; count <= count + 2'd1; end
        2'b01: begin ram0 <= ram1; count <= count - 2'd1; end
        2'b11: begin if (count == 2'd1) ram0 <= in; else begin ram0 <= ram1; ram1 <= in; end end
        default: ;
      endcase
    end
  end
  assign io_enq_ready = count != 2'd2;
  assign io_deq_valid = count != 2'd0;
  assign io_deq_bits_set = ram0[7:0];
  assign io_deq_bits_way = ram0[9:8];
  assign io_deq_bits_data_dirty = ram0[10];
  assign io_deq_bits_data_state = ram0[12:11];
  assign io_deq_bits_data_clients = ram0[14:13];
  assign io_deq_bits_data_tag = ram0[29:15];
endmodule
