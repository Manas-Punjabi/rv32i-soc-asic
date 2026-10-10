`timescale 1ns/1ps
// tb_apb_accel.sv — verifies the APB fabric and the accelerator wrapper.
//
//  A0  reset state          busy=0, done=0 after reset
//  A1  PARAMS register      reads back N and DW
//  A2  load / start / poll  full transaction sequence, result matches golden
//  A3  done sticky          stays set until written-1-to-clear
//  A4  back-to-back         second run without reloading A/B
//  A5  write while busy     matrix writes during a run are ignored
//  A6  unmapped slave       PSLVERR, no hang
//  A7  misaligned access    PSLVERR on an unaligned matrix address
//  A8  out-of-range index   PSLVERR past N*N words
module tb_apb_accel;
  localparam int N  = 4;
  localparam int DW = 32;
  localparam int ADDR_W = 20, SLAVE_AW = 12, N_SLAVES = 4;

  localparam logic [ADDR_W-1:0] ACCEL_BASE = 20'h01000;   // slave 1
  localparam logic [ADDR_W-1:0] NOMAP_BASE = 20'h05000;   // beyond N_SLAVES: unmapped
  localparam logic [11:0] R_CTRL = 12'h000, R_STATUS = 12'h004, R_PARAMS = 12'h008;
  localparam logic [11:0] B_A = 12'h400, B_B = 12'h800, B_C = 12'hC00;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // master side
  logic              psel = 0, penable = 0, pwrite = 0;
  logic [ADDR_W-1:0] paddr = '0;
  logic [31:0]       pwdata = '0, prdata;
  logic              pready, pslverr;

  // slave side
  logic [N_SLAVES-1:0] s_psel;
  logic                s_penable, s_pwrite;
  logic [SLAVE_AW-1:0] s_paddr;
  logic [31:0]         s_pwdata;
  // per-slave response wires, concatenated into the fabric's flat inputs
  logic [31:0] accel_prdata;
  logic        accel_pready, accel_pslverr;
  wire [N_SLAVES*32-1:0] s_prdata  = {32'h0, 32'h0, accel_prdata, 32'h0};
  wire [N_SLAVES-1:0]    s_pready  = {1'b1,  1'b1,  accel_pready, 1'b1};
  wire [N_SLAVES-1:0]    s_pslverr = {1'b0,  1'b0,  accel_pslverr, 1'b0};

  apb_fabric #(.N_SLAVES(N_SLAVES), .ADDR_W(ADDR_W), .SLAVE_AW(SLAVE_AW)) u_fab (
    .clk(clk), .rst_n(rst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .s_psel(s_psel), .s_penable(s_penable), .s_pwrite(s_pwrite),
    .s_paddr(s_paddr), .s_pwdata(s_pwdata),
    .s_prdata(s_prdata), .s_pready(s_pready), .s_pslverr(s_pslverr)
  );

  // slave 1: the accelerator. Slaves 0, 2, 3 are tied off here.
  apb_mm_accel #(.N(N), .DW(DW), .SLAVE_AW(SLAVE_AW)) u_accel (
    .clk(clk), .rst_n(rst_n),
    .psel(s_psel[1]), .penable(s_penable), .pwrite(s_pwrite),
    .paddr(s_paddr), .pwdata(s_pwdata),
    .prdata(accel_prdata), .pready(accel_pready), .pslverr(accel_pslverr)
  );

  int errors = 0, checks = 0;
  logic [31:0] A [0:N*N-1], B [0:N*N-1], C [0:N*N-1];

  // This TB drives the fabric rather than a slave, so the address it issues is
  // the full master width; the tasks themselves are the shared ones.
  localparam int APB_AW = ADDR_W;
  `include "apb_tasks.svh"

  task automatic golden();
    logic [DW-1:0] acc;
    for (int i = 0; i < N; i++)
      for (int j = 0; j < N; j++) begin
        acc = '0;
        for (int k = 0; k < N; k++) acc = acc + A[i*N+k] * B[k*N+j];
        C[i*N+j] = acc;
      end
  endtask

  task automatic load_matrices();
    logic e;
    for (int x = 0; x < N*N; x++) begin
      apb_write(ACCEL_BASE + B_A + ADDR_W'(x*4), A[x], e);
      chk(!e, "PSLVERR writing A");
      apb_write(ACCEL_BASE + B_B + ADDR_W'(x*4), B[x], e);
      chk(!e, "PSLVERR writing B");
    end
  endtask

  // start, poll STATUS until done, then compare C against the golden model
  task automatic run_and_check(input string name);
    logic [31:0] st, rd;
    logic e;
    int spins;
    golden();
    apb_write(ACCEL_BASE + R_CTRL, 32'h1, e);
    chk(!e, "PSLVERR writing CTRL");
    spins = 0;
    do begin
      apb_read(ACCEL_BASE + R_STATUS, st, e);
      spins++;
      if (spins > 200) begin
        $display("  FAIL: %s: done never set", name);
        $display("FAIL: hang"); $finish;
      end
    end while (!st[1]);
    chk(st[0] == 1'b0, $sformatf("%s: busy still set when done", name));
    for (int x = 0; x < N*N; x++) begin
      apb_read(ACCEL_BASE + B_C + ADDR_W'(x*4), rd, e);
      chk(!e, "PSLVERR reading C");
      chk(rd == C[x], $sformatf("%s: C[%0d] got %h exp %h", name, x, rd, C[x]));
    end
    apb_write(ACCEL_BASE + R_STATUS, 32'h2, e);      // clear sticky done
    $display("[%s] ok (%0d status polls)", name, spins);
  endtask

  initial begin
    logic [31:0] d;
    logic e;
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/tb_apb_accel.vcd");
      $dumpvars(0, tb_apb_accel);
    end
    repeat (3) @(negedge clk); rst_n = 1;

    // A0 reset state
    apb_read(ACCEL_BASE + R_STATUS, d, e);
    chk(d[1:0] == 2'b00, "A0: busy/done set after reset");
    chk(!e, "A0: PSLVERR on STATUS read");

    // A1 PARAMS
    apb_read(ACCEL_BASE + R_PARAMS, d, e);
    chk(d[7:0] == 8'(N) && d[15:8] == 8'(DW), $sformatf("A1: PARAMS = %h", d));

    // A2 full sequence
    for (int x = 0; x < N*N; x++) begin A[x] = $urandom; B[x] = $urandom; end
    load_matrices();
    run_and_check("A2.random");

    // A3 sticky done survives until cleared
    for (int x = 0; x < N*N; x++) begin A[x] = $urandom; B[x] = $urandom; end
    load_matrices();
    golden();
    apb_write(ACCEL_BASE + R_CTRL, 32'h1, e);
    repeat (20) @(negedge clk);
    apb_read(ACCEL_BASE + R_STATUS, d, e);
    chk(d[1] == 1'b1, "A3: done not sticky");
    apb_read(ACCEL_BASE + R_STATUS, d, e);
    chk(d[1] == 1'b1, "A3: done cleared by a read");
    apb_write(ACCEL_BASE + R_STATUS, 32'h2, e);
    apb_read(ACCEL_BASE + R_STATUS, d, e);
    chk(d[1] == 1'b0, "A3: done not cleared by write-1");

    // A4 back-to-back without reloading
    run_and_check("A4.rerun_no_reload");

    // A5 matrix writes while busy are ignored
    apb_write(ACCEL_BASE + R_CTRL, 32'h1, e);
    apb_write(ACCEL_BASE + B_A + 12'h0, 32'hDEAD_BEEF, e);
    apb_write(ACCEL_BASE + B_B + 12'h4, 32'hDEAD_BEEF, e);
    do apb_read(ACCEL_BASE + R_STATUS, d, e); while (!d[1]);
    apb_write(ACCEL_BASE + R_STATUS, 32'h2, e);
    run_and_check("A5.after_write_while_busy");

    // A6 unmapped slave: error, no hang
    apb_read(NOMAP_BASE + 12'h0, d, e);
    chk(e == 1'b1, "A6: no PSLVERR from unmapped slave");

    // A7 misaligned matrix access
    apb_read(ACCEL_BASE + B_C + 12'h002, d, e);
    chk(e == 1'b1, "A7: no PSLVERR on misaligned access");

    // A8 index past N*N
    apb_read(ACCEL_BASE + B_C + ADDR_W'(N*N*4), d, e);
    chk(e == 1'b1, "A8: no PSLVERR past end of C");

    if (errors == 0) $display("PASS: %0d checks, N=%0d DW=%0d", checks, N, DW);
    else             $display("FAIL: %0d errors / %0d checks", errors, checks);
    $finish;
  end

  initial begin #2_000_000; $display("FAIL: timeout"); $finish; end
endmodule
