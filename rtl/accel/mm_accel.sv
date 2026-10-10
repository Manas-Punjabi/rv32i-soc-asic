// mm_accel.sv — parameterized NxN matrix-multiply accelerator
// N parallel PEs; PE j computes C[i][j] = sum_k A[i][k]*B[k][j].
// Full multiply takes N + LAT + 1 cycles (LAT = 3, or 4 with SPLIT_MUL).
// Rows stream through the PEs one per cycle, so all N rows are
// in flight together once the pipeline fills.
module mm_accel #(
  parameter int N  = 4,                 // N >= 2
  parameter int DW = 32,
  parameter int SPLIT_MUL = 0,       // 1: extra pipeline stage in multipliers
  parameter int AW = $clog2(N*N)        // derived; do not override
)(
  input  logic          clk,
  input  logic          rst_n,
  // matrix load (accepted only while idle), row-major address i*N+j
  input  logic          we_a,
  input  logic          we_b,
  input  logic [AW-1:0] waddr,
  input  logic [DW-1:0] wdata,
  // control
  input  logic          start,
  output logic          busy,
  output logic          done,           // 1-cycle pulse
  // result readback
  input  logic [AW-1:0] raddr,
  output logic [DW-1:0] rdata
);
  localparam int RW  = $clog2(N+1);
  localparam int LAT = 3 + SPLIT_MUL;   // PE latency
  localparam logic [RW-1:0] N_LAST = RW'(N - 1);

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
  state_t state;

  logic [N*N*DW-1:0]           mem_a, mem_b, mem_c;
  logic [RW-1:0]               feed_cnt, out_cnt;
  logic                        feed_v;
  logic [LAT*RW-1:0]           tag_sr;        // row index aligned to PE latency
  logic [RW-1:0]               out_row;
  logic [N*DW-1:0]             a_row;
  logic [N*N*DW-1:0]           b_cols;        // column j at [j*N*DW +: N*DW]
  /* verilator lint_off UNUSEDSIGNAL */
  logic [N-1:0]                pe_v;          // all PEs share timing; pe_v[0] is used
  /* verilator lint_on UNUSEDSIGNAL */
  logic [N*DW-1:0]             dots;

  assign feed_v = (state == S_RUN) && (feed_cnt <= N_LAST);
  assign busy   = (state == S_RUN);
  assign done   = (state == S_DONE);
  assign rdata  = mem_c[raddr*DW +: DW];

  // row select for A
  always_comb begin
    for (int k = 0; k < N; k++)
      a_row[k*DW +: DW] = mem_a[(feed_cnt*N + k)*DW +: DW];
  end

  // processing elements
  for (genvar j = 0; j < N; j++) begin : g_pe
    for (genvar k = 0; k < N; k++) begin : g_col
      assign b_cols[(j*N + k)*DW +: DW] = mem_b[(k*N + j)*DW +: DW];
    end
    mm_pe #(.N(N), .DW(DW), .SPLIT_MUL(SPLIT_MUL)) u_pe (
      .clk      (clk),
      .rst_n    (rst_n),
      .in_valid (feed_v),
      .a_row    (a_row),
      .b_col    (b_cols[j*N*DW +: N*DW]),
      .out_valid(pe_v[j]),
      .dot      (dots[j*DW +: DW])
    );
  end

  // tag pipeline
  always_ff @(posedge clk) tag_sr <= {tag_sr[(LAT-1)*RW-1:0], feed_cnt};
  assign out_row = tag_sr[(LAT-1)*RW +: RW];

  // storage
  always_ff @(posedge clk) begin
    if (state == S_IDLE && we_a) mem_a[waddr*DW +: DW] <= wdata;
    if (state == S_IDLE && we_b) mem_b[waddr*DW +: DW] <= wdata;
    if (pe_v[0]) begin
      for (int j = 0; j < N; j++)
        mem_c[(out_row*N + j)*DW +: DW] <= dots[j*DW +: DW];
    end
  end

  // control FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      feed_cnt <= '0;
      out_cnt  <= '0;
    end else begin
      case (state)
        S_IDLE: if (start) begin
          state    <= S_RUN;
          feed_cnt <= '0;
          out_cnt  <= '0;
        end
        S_RUN: begin
          if (feed_v) feed_cnt <= feed_cnt + 1'b1;
          if (pe_v[0]) begin
            out_cnt <= out_cnt + 1'b1;
            if (out_cnt == N_LAST) state <= S_DONE;
          end
        end
        default: state <= S_IDLE;   // S_DONE -> idle
      endcase
    end
  end
endmodule
