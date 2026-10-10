`timescale 1ns/1ps
// tb_soc.sv — runs one program on soc_top and reports PASS/FAIL.
//
// The memory image comes from +hex=<file> (same format as tb_core, loaded at
// 0x8000_0000). The program ends by storing (code << 1) | 1 to +tohost=<addr>
// (default 0x8000_1000); code 0 is PASS. UART TX is decoded and echoed to the
// console; +uart_expect=<string> additionally requires that exact text to have
// been received by the end. uart_rx is looped back from uart_tx, gpio_in from
// gpio_out, so firmware can test both directions.
//
// Compile with -DRVFI to also run the trace checks (tb/rvfi_checks.svh).
//
// +vcd       dump build/tb_soc.vcd
// +timeout=N give up after N cycles (default 400000)
module tb_soc;
  localparam logic [31:0] MEM_BASE  = 32'h8000_0000;
  localparam int          MEM_WORDS = 16384;                 // 64 KB
  localparam int          UART_DIV  = 16;
  localparam int          GPIO_W    = 8;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic              uart_tx, uart_rx;
  logic [GPIO_W-1:0] gpio_out, gpio_in;
  assign uart_rx = uart_tx;
  assign gpio_in = gpio_out;

  soc_top #(.MEM_WORDS(MEM_WORDS), .UART_DIV(UART_DIV), .GPIO_W(GPIO_W)) dut (
    .clk(clk), .rst_n(rst_n),
    .uart_tx(uart_tx), .uart_rx(uart_rx), .gpio_out(gpio_out), .gpio_in(gpio_in)
`ifdef RVFI
    , .rvfi_valid(), .rvfi_order(), .rvfi_insn(), .rvfi_trap(), .rvfi_pc_rdata(),
    .rvfi_pc_wdata(), .rvfi_rd_addr(), .rvfi_rd_wdata(), .rvfi_mem_addr(),
    .rvfi_mem_rmask(), .rvfi_mem_wmask(), .rvfi_mem_rdata(), .rvfi_mem_wdata()
`endif
  );

`ifdef RVFI
  `define RVFI_IF   dut
  `define RVFI_CORE dut.u_core
  `include "rvfi_checks.svh"
`endif

  // ---- UART monitor: decode uart_tx at UART_DIV clocks per bit -------------
  string uart_text = "";
  initial forever begin
    logic [7:0] b;
    @(negedge uart_tx);
    repeat (UART_DIV / 2) @(negedge clk);
    if (uart_tx === 1'b0) begin
      for (int i = 0; i < 8; i++) begin repeat (UART_DIV) @(negedge clk); b[i] = uart_tx; end
      repeat (UART_DIV) @(negedge clk);
      if (uart_tx === 1'b1) begin
        uart_text = {uart_text, string'(b)};
        $write("%c", b);
      end else $display("  UART monitor: framing error");
    end
  end

  // ---- run ---------------------------------------------------------------
  string       hexfile, uart_expect;
  logic [31:0] tohost;
  int          timeout, cycles;
  bit          have_expect;

  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("FAIL: no +hex=<file>"); $finish;
    end
    if (!$value$plusargs("tohost=%h", tohost)) tohost = MEM_BASE + 32'h1000;
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 400000;
    have_expect = $value$plusargs("uart_expect=%s", uart_expect);
    for (int i = 0; i < MEM_WORDS; i++) dut.u_mem.g_flops.mem[i] = 32'h0;
    $readmemh(hexfile, dut.u_mem.g_flops.mem);
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/tb_soc.vcd");
      $dumpvars(0, tb_soc);
    end
    repeat (3) @(negedge clk);
    rst_n = 1;
  end

  // the tohost store, seen at the core's data port
  logic tohost_store;
  assign tohost_store = dut.u_core.dmem_valid && dut.u_core.dmem_ready && dut.u_core.dmem_we &&
                        dut.u_core.dmem_addr == tohost && dut.u_core.dmem_wdata != 0;

  always @(posedge clk) begin
    cycles++;
    if (rst_n && tohost_store) begin
      if (uart_text.len() != 0 && uart_text[uart_text.len()-1] != "\n") $display("");
      // trailing newlines are not part of the comparison (plusargs cannot carry them)
      while (uart_text.len() != 0 && uart_text[uart_text.len()-1] == "\n")
        uart_text = uart_text.substr(0, uart_text.len()-2);
      if (have_expect && uart_text != uart_expect)
        $display("FAIL  uart text \"%s\", expected \"%s\"", uart_text, uart_expect);
`ifdef RVFI
      else if (rvfi_errors != 0)
        $display("FAIL  %0d RVFI trace errors in %0d records", rvfi_errors, rvfi_records);
`endif
      else if (dut.u_core.dmem_wdata == 32'h1)
        $display("PASS  cycles=%0d instret=%0d", cycles, dut.u_core.u_csr.minstret);
      else
        $display("FAIL  test %0d  (tohost=%h) cycles=%0d", dut.u_core.dmem_wdata >> 1, dut.u_core.dmem_wdata, cycles);
      $finish;
    end
    if (cycles > timeout) begin
      $display("FAIL  timeout after %0d cycles, pc=%h", cycles, dut.u_core.pc_q);
      $finish;
    end
  end
endmodule
