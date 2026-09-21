// Multiplier cells with the USE_DSP attribute pinned to a literal.  Vivado will
// not take a parameter as an attribute value, and "auto" is not a legal value
// for use_dsp, so the choice has to be made structurally.
(* use_dsp = "yes" *) module pext_mul32x16_dsp (input wire signed [31:0] a, input wire signed [15:0] b, output wire signed [47:0] p);
  assign p = a * b;
endmodule
(* use_dsp = "no"  *) module pext_mul32x16_lut (input wire signed [31:0] a, input wire signed [15:0] b, output wire signed [47:0] p);
  assign p = a * b;
endmodule
module pext_mul32x16_auto (input wire signed [31:0] a, input wire signed [15:0] b, output wire signed [47:0] p);
  assign p = a * b;
endmodule

(* use_dsp = "yes" *) module pext_mul17x17_dsp (input wire signed [16:0] a, input wire signed [16:0] b, output wire signed [33:0] p);
  assign p = a * b;
endmodule
(* use_dsp = "no"  *) module pext_mul17x17_lut (input wire signed [16:0] a, input wire signed [16:0] b, output wire signed [33:0] p);
  assign p = a * b;
endmodule
module pext_mul17x17_auto (input wire signed [16:0] a, input wire signed [16:0] b, output wire signed [33:0] p);
  assign p = a * b;
endmodule

(* use_dsp = "yes" *) module pext_mul9x9_dsp (input wire signed [8:0] a, input wire signed [8:0] b, output wire signed [17:0] p);
  assign p = a * b;
endmodule
module pext_mul9x9_lut (input wire signed [8:0] a, input wire signed [8:0] b, output wire signed [17:0] p);
  assign p = a * b;
endmodule
