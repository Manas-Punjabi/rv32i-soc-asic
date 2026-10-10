// rv32i_regfile.sv — 32 x 32-bit register file, two read ports, one write port.
// x0 reads as zero. A read of the register being written in the same cycle
// returns the new value, which is the WB -> ID forwarding path.
module rv32i_regfile (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata,
  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2
);
  logic [31:0] regs [1:31];      // x1..x31; x0 is not stored

  always_ff @(posedge clk)
    if (we && waddr != 5'd0) regs[waddr] <= wdata;

  always_comb begin
    if (raddr1 == 5'd0)               rdata1 = 32'h0;
    else if (we && waddr == raddr1)   rdata1 = wdata;
    else                              rdata1 = regs[raddr1];
    if (raddr2 == 5'd0)               rdata2 = 32'h0;
    else if (we && waddr == raddr2)   rdata2 = wdata;
    else                              rdata2 = regs[raddr2];
  end
endmodule
