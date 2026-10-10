// apb_tasks.svh — APB master tasks and check helpers shared by the peripheral
// testbenches. The including module must declare:
//   clk, psel, penable, pwrite, paddr (APB_AW bits), pwdata, prdata, pready, pslverr,
//   int errors, checks
//
// APB_AW is the width of the address this testbench drives: SLAVE_AW when the
// testbench talks to a slave directly, or the full master width when it goes
// through apb_fabric (tb_apb_accel does).
// Every access completes when pready is seen high; the #1 after the edge lets the
// combinational response settle before it is sampled.
task automatic apb_write(input logic [APB_AW-1:0] a, input logic [31:0] d, output logic err);
  @(negedge clk); psel = 1; pwrite = 1; paddr = a; pwdata = d; penable = 0;
  @(negedge clk); penable = 1;
  #1;
  while (!pready) begin @(negedge clk); #1; end
  err = pslverr;
  @(negedge clk); psel = 0; penable = 0; pwrite = 0;
endtask

task automatic apb_read(input logic [APB_AW-1:0] a, output logic [31:0] d, output logic err);
  @(negedge clk); psel = 1; pwrite = 0; paddr = a; penable = 0;
  @(negedge clk); penable = 1;
  #1;
  while (!pready) begin @(negedge clk); #1; end
  d = prdata; err = pslverr;
  @(negedge clk); psel = 0; penable = 0;
endtask

task automatic fail(input string msg);
  errors++;
  $display("  FAIL: %s", msg);
endtask

task automatic chk(input bit cond, input string msg);
  checks++;
  if (!cond) fail(msg);
endtask

// write and require no error; read and require no error
task automatic wr(input logic [APB_AW-1:0] a, input logic [31:0] d, input string what);
  logic e;
  apb_write(a, d, e);
  chk(!e, $sformatf("PSLVERR writing %s", what));
endtask

task automatic rd(input logic [APB_AW-1:0] a, output logic [31:0] d, input string what);
  logic e;
  apb_read(a, d, e);
  chk(!e, $sformatf("PSLVERR reading %s", what));
endtask
