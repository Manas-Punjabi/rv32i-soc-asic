// apb_timer.sv — CLINT-style machine timer and software interrupt, APB slave.
//
// Register map (byte offsets):
//   0x000  MTIME_LO     RW  free-running 64-bit counter, +1 every clock
//   0x004  MTIME_HI     RW
//   0x008  MTIMECMP_LO  RW  irq_timer = (mtime >= mtimecmp). Resets to all ones,
//   0x00C  MTIMECMP_HI  RW  so no interrupt is pending after reset.
//   0x010  MSIP         RW  bit0 = irq_soft
//
// Any other offset returns PSLVERR. All accesses complete in one cycle.
//
// Firmware convention for a race-free mtimecmp update on a 32-bit bus: write
// MTIMECMP_HI = 0xFFFFFFFF, then LO, then the real HI.
module apb_timer #(
  parameter int SLAVE_AW = 12
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
  output logic                irq_timer,
  output logic                irq_soft
);
  localparam logic [11:0] R_MTIME_LO    = 12'h000;
  localparam logic [11:0] R_MTIME_HI    = 12'h004;
  localparam logic [11:0] R_MTIMECMP_LO = 12'h008;
  localparam logic [11:0] R_MTIMECMP_HI = 12'h00C;
  localparam logic [11:0] R_MSIP        = 12'h010;

  logic acc, wr, rd;
  assign acc = psel && penable;
  assign wr  = acc &&  pwrite;
  assign rd  = acc && !pwrite;

  logic [11:0] off;
  assign off = paddr[11:0];

  logic known;
  assign known = (off == R_MTIME_LO) || (off == R_MTIME_HI) ||
                 (off == R_MTIMECMP_LO) || (off == R_MTIMECMP_HI) || (off == R_MSIP);

  logic [63:0] mtime, mtimecmp;
  logic        msip;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mtime    <= '0;
      mtimecmp <= '1;
      msip     <= 1'b0;
    end else begin
      mtime <= mtime + 64'd1;
      if (wr) begin
        case (off)
          R_MTIME_LO:    mtime[31:0]     <= pwdata;
          R_MTIME_HI:    mtime[63:32]    <= pwdata;
          R_MTIMECMP_LO: mtimecmp[31:0]  <= pwdata;
          R_MTIMECMP_HI: mtimecmp[63:32] <= pwdata;
          R_MSIP:        msip            <= pwdata[0];
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    prdata = 32'h0;
    if (rd) begin
      case (off)
        R_MTIME_LO:    prdata = mtime[31:0];
        R_MTIME_HI:    prdata = mtime[63:32];
        R_MTIMECMP_LO: prdata = mtimecmp[31:0];
        R_MTIMECMP_HI: prdata = mtimecmp[63:32];
        R_MSIP:        prdata = {31'h0, msip};
        default:       prdata = 32'h0;
      endcase
    end
  end
  assign pready    = 1'b1;
  assign pslverr   = acc && !known;
  assign irq_timer = (mtime >= mtimecmp);
  assign irq_soft  = msip;
endmodule
