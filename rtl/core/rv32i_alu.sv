// rv32i_alu.sv — RV32I integer ALU.
// op = {alt, funct3}: alt selects SUB for funct3=000 and SRA for funct3=101.
module rv32i_alu (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [3:0]  op,
  output logic [31:0] y
);
  logic [4:0] sh;
  assign sh = b[4:0];

  always_comb begin
    case (op[2:0])
      3'b000:  y = op[3] ? a - b : a + b;
      3'b001:  y = a << sh;
      3'b010:  y = {31'h0, $signed(a) < $signed(b)};
      3'b011:  y = {31'h0, a < b};
      3'b100:  y = a ^ b;
      3'b101:  y = op[3] ? $unsigned($signed(a) >>> sh) : a >> sh;
      3'b110:  y = a | b;
      default: y = a & b;
    endcase
  end
endmodule
