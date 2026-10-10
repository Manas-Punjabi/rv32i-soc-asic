// apb_gpio.sv — W output pins and W input pins, APB slave.
//
// Register map (byte offsets):
//   0x000  OUT  RW  output pins; bits above W read 0
//   0x004  IN   R   input pins, through a 2-flop synchronizer (2 clocks of latency)
//   0x008  SET  W   OUT |= data
//   0x00C  CLR  W   OUT &= ~data
//
// Any other offset returns PSLVERR. All accesses complete in one cycle.
module apb_gpio #(
  parameter int SLAVE_AW = 12,
  parameter int W        = 8
)(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                psel,
  input  logic                penable,
  input  logic                pwrite,
  input  logic [SLAVE_AW-1:0] paddr,
  input  logic [31:0]         pwdata,
  output logic [31:0]         prdata,
  output logic                pready,
  output logic                pslverr,
  output logic [W-1:0]        gpio_out,
  input  logic [W-1:0]        gpio_in
);
  localparam logic [11:0] R_OUT = 12'h000;
  localparam logic [11:0] R_IN  = 12'h004;
  localparam logic [11:0] R_SET = 12'h008;
  localparam logic [11:0] R_CLR = 12'h00C;

  logic acc, wr, rd;
  assign acc = psel && penable;
  assign wr  = acc &&  pwrite;
  assign rd  = acc && !pwrite;

  logic [11:0] off;
  assign off = paddr[11:0];

  logic known;
  assign known = (off == R_OUT) || (off == R_IN) || (off == R_SET) || (off == R_CLR);

  logic [W-1:0] out_q, in_sync0, in_sync1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_q    <= '0;
      in_sync0 <= '0;
      in_sync1 <= '0;
    end else begin
      in_sync0 <= gpio_in;
      in_sync1 <= in_sync0;
      if (wr) begin
        case (off)
          R_OUT: out_q <= pwdata[W-1:0];
          R_SET: out_q <= out_q |  pwdata[W-1:0];
          R_CLR: out_q <= out_q & ~pwdata[W-1:0];
          default: ;
        endcase
      end
    end
  end
  assign gpio_out = out_q;

  always_comb begin
    prdata = 32'h0;
    if (rd) begin
      case (off)
        R_OUT:   prdata = {{(32-W){1'b0}}, out_q};
        R_IN:    prdata = {{(32-W){1'b0}}, in_sync1};
        default: prdata = 32'h0;
      endcase
    end
  end
  assign pready  = 1'b1;
  assign pslverr = acc && !known;

  // bits of pwdata above W are ignored (W may be 32, so no [31:W] slice here)
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, pwdata >> W};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
