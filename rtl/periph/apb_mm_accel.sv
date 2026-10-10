// apb_mm_accel.sv — APB slave wrapper around mm_accel.
//
// Register map (byte offsets within the slave's 4 KB window):
//   0x000  CTRL    W  bit0 = start (self-clearing, ignored while busy)
//   0x004  STATUS  R  bit0 = busy, bit1 = done (sticky)
//                   W  bit1 = 1 clears the sticky done flag
//   0x008  PARAMS  R  [7:0] = N, [15:8] = DW
//   0x400  A[0]    W  matrix A, row-major, N*N words
//   0x800  B[0]    W  matrix B, row-major, N*N words
//   0xC00  C[0]    R  result, row-major, N*N words
//
// Writes to A/B are ignored while busy (mm_accel enforces this too).
// All accesses complete in the APB access phase: PREADY is always 1.
module apb_mm_accel #(
  parameter int N         = 4,
  parameter int DW        = 32,
  parameter int SPLIT_MUL = 0,          // passed through to mm_accel
  parameter int SLAVE_AW  = 12
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
  output logic                pslverr
);
  localparam int AW = $clog2(N*N);
  localparam logic [7:0] N_BYTE  = 8'(N);
  localparam logic [7:0] DW_BYTE = 8'(DW);

  localparam logic [11:0] REG_CTRL   = 12'h000;
  localparam logic [11:0] REG_STATUS = 12'h004;
  localparam logic [11:0] REG_PARAMS = 12'h008;
  localparam logic [11:0] BASE_A     = 12'h400;
  localparam logic [11:0] BASE_B     = 12'h800;
  localparam logic [11:0] BASE_C     = 12'hC00;

  // region decode by the top nibble of the offset
  logic in_a, in_b, in_c, in_reg;
  assign in_a   = (paddr[11:10] == BASE_A[11:10]);
  assign in_b   = (paddr[11:10] == BASE_B[11:10]);
  assign in_c   = (paddr[11:10] == BASE_C[11:10]);
  assign in_reg = (paddr[11:10] == 2'b00);

  logic [AW-1:0] word_idx;
  logic          idx_valid;
  assign word_idx  = paddr[2 +: AW];
  assign idx_valid = ({24'h0, paddr[9:2]} < N*N) && (paddr[1:0] == 2'b00);

  // APB access phase strobes
  logic acc, wr, rd;
  assign acc = psel && penable;
  assign wr  = acc &&  pwrite;
  assign rd  = acc && !pwrite;

  // accelerator connections
  logic          we_a, we_b, start, busy, done;
  logic [AW-1:0] waddr, raddr;
  logic [DW-1:0] wdata, rdata_acc;

  assign we_a  = wr && in_a && idx_valid;
  assign we_b  = wr && in_b && idx_valid;
  assign waddr = word_idx;
  assign wdata = pwdata[DW-1:0];
  assign raddr = word_idx;

  assign start = wr && in_reg && (paddr[11:0] == REG_CTRL) && pwdata[0];

  mm_accel #(.N(N), .DW(DW), .SPLIT_MUL(SPLIT_MUL)) u_accel (
    .clk(clk), .rst_n(rst_n),
    .we_a(we_a), .we_b(we_b), .waddr(waddr), .wdata(wdata),
    .start(start), .busy(busy), .done(done),
    .raddr(raddr), .rdata(rdata_acc)
  );

  // sticky done: set by the accelerator's one-cycle pulse, cleared by
  // writing STATUS bit1 (write-1-to-clear). Clear loses to set.
  logic done_sticky;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)      done_sticky <= 1'b0;
    else if (done)   done_sticky <= 1'b1;
    else if (wr && in_reg && (paddr[11:0] == REG_STATUS) && pwdata[1])
                     done_sticky <= 1'b0;
  end

  always_comb begin
    prdata = 32'h0;
    if (rd) begin
      if (in_c && idx_valid)       prdata = {{(32-DW){1'b0}}, rdata_acc};
      else if (in_reg) begin
        case (paddr[11:0])
          REG_STATUS: prdata = {30'h0, done_sticky, busy};
          REG_PARAMS: prdata = {16'h0, DW_BYTE, N_BYTE};
          default:    prdata = 32'h0;
        endcase
      end
    end
  end

  assign pready  = 1'b1;
  // error on a misaligned or out-of-range access to a matrix window
  assign pslverr = acc && (in_a || in_b || in_c) && !idx_valid;
endmodule
