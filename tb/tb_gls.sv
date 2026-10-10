`timescale 1ns/1ps
// tb_gls.sv — post-layout simulation: run a program on the routed netlist.
//
// The DUT is ORFS's 6_final.v with escaped instance names de-dotted
// (scripts/sdf_dedot.py), the sky130 cell models, and the PDK's behavioural
// model for the SRAM macros.
//
// HOW THE PROGRAM GETS INTO MEMORY
//
// A gate-level netlist has no array to $readmemh into -- the flop build's memory
// is thousands of individual flops. The macro build is what makes this practical:
// the macro's behavioural model owns a `mem` array, so the image is loaded
// straight into bank 0. gls_smoke.S and sw/link_gls.ld keep everything inside
// the first 2 KB so only that bank matters; bank 1 is never read.
//
// Termination is by polling mem[TOHOST_WORD] rather than watching bus signals:
// after flattening there is no named dmem_valid to look at.
//
// +hex=<file>     image, one 32-bit word per line ($readmemh)
// +timeout=N      give up after N clock cycles (default 200000)
// +vcd            dump build/tb_gls.vcd
module tb_gls;
  // tohost is at 0x8000_0700 -> word 0x1C0 within bank 0
  localparam int TOHOST_WORD = 'h1C0;

  // The functional run has unit delays so any period works. The SDF run must be
  // driven at a real period: run_gls.sh passes -DHALF_PERIOD, and also runs a
  // control at a period that must fail -- a delay-annotated simulation that
  // passes at every period is not applying the delays.
`ifndef HALF_PERIOD
  `define HALF_PERIOD 5.0
`endif
  logic clk = 0, rst_n = 0;
  always #(`HALF_PERIOD) clk = ~clk;

`ifdef SDF_FILE
  initial $sdf_annotate(`SDF_FILE, dut);
`endif

  logic        uart_tx, uart_rx;
  logic [7:0]  gpio_out, gpio_in;
  assign uart_rx = uart_tx;             // loopback, as in tb_soc
  assign gpio_in = gpio_out;

  soc_top dut (
    .clk(clk), .rst_n(rst_n),
    .uart_tx(uart_tx), .uart_rx(uart_rx),
    .gpio_out(gpio_out), .gpio_in(gpio_in)
  );

  // the de-dotted name of macro bank 0; see scripts/sdf_dedot.py
  `define BANK0 dut.\u_mem_g_sram_g_bank[0]_u_sram

  string hexfile;
  int    timeout, cycles;

  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("FAIL: no +hex=<file>"); $finish;
    end
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 200000;
    // clear then load bank 0; leaving it X makes every fetch X
    for (int i = 0; i < 512; i++) `BANK0 .mem[i] = 32'h0;
    $readmemh(hexfile, `BANK0 .mem);
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/tb_gls.vcd");
      $dumpvars(0, tb_gls);
    end
    repeat (5) @(negedge clk);
    rst_n = 1;
  end

  always @(posedge clk) begin
    cycles++;
    if (rst_n && `BANK0 .mem[TOHOST_WORD] !== 32'h0 &&
                 `BANK0 .mem[TOHOST_WORD] !== 32'hxxxxxxxx) begin
      if (`BANK0 .mem[TOHOST_WORD] == 32'h1)
        $display("PASS  gate-level, cycles=%0d", cycles);
      else
        $display("FAIL  check %0d (tohost=%h) cycles=%0d",
                 `BANK0 .mem[TOHOST_WORD] >> 1, `BANK0 .mem[TOHOST_WORD], cycles);
      $finish;
    end
    if (cycles > timeout) begin
      $display("FAIL  timeout after %0d cycles", cycles);
      $finish;
    end
  end
endmodule
