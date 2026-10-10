// mm_pe.sv — pipelined dot-product processing element
// Latency: 3 cycles, or 4 with SPLIT_MUL=1
//   SPLIT_MUL=0: operand reg -> product reg -> sum reg
//   SPLIT_MUL=1: operand reg -> half-product regs -> product reg -> sum reg
// Arithmetic wraps modulo 2**DW. Buses are flattened: element k at [k*DW +: DW].
module mm_pe #(
  parameter int N  = 4,
  parameter int DW = 32,
  parameter int SPLIT_MUL = 0,
  parameter int LAT = 3 + SPLIT_MUL    // derived; do not override
)(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            in_valid,
  input  logic [N*DW-1:0] a_row,
  input  logic [N*DW-1:0] b_col,
  output logic            out_valid,
  output logic [DW-1:0]   dot
);
  localparam int H = DW / 2;

  logic [N*DW-1:0] a_q, b_q, prod_q;
  logic [DW-1:0]   sum_c;
  logic [LAT-1:0]  v_sr;

  // valid pipeline is reset; datapath registers are reset-free to save area
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) v_sr <= '0;
    else        v_sr <= {v_sr[LAT-2:0], in_valid};
  end
  assign out_valid = v_sr[LAT-1];

  // S1: register operands
  always_ff @(posedge clk) begin
    a_q <= a_row;
    b_q <= b_col;
  end

  // S2: N parallel multipliers
  if (SPLIT_MUL != 0) begin : g_split
    // a*b = a*b_lo + (a*b_hi << H), each half registered (shorter critical path)
    logic [N*DW-1:0] pl_q, ph_q;
    for (genvar k = 0; k < N; k++) begin : g_mul
      always_ff @(posedge clk) begin
        pl_q[k*DW +: DW]   <= a_q[k*DW +: DW] * b_q[k*DW +: H];
        ph_q[k*DW +: DW]   <= a_q[k*DW +: DW] * b_q[k*DW + H +: DW - H];
        prod_q[k*DW +: DW] <= pl_q[k*DW +: DW] + (ph_q[k*DW +: DW] << H);
      end
    end
  end else begin : g_full
    for (genvar k = 0; k < N; k++) begin : g_mul
      always_ff @(posedge clk)
        prod_q[k*DW +: DW] <= a_q[k*DW +: DW] * b_q[k*DW +: DW];
    end
  end

  // S3: adder
  always_comb begin
    sum_c = '0;
    for (int k = 0; k < N; k++) sum_c = sum_c + prod_q[k*DW +: DW];
  end

  always_ff @(posedge clk) dot <= sum_c;
endmodule
