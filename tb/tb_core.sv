`timescale 1ns/1ps
// tb_core.sv — runs one program on rv32i_core and reports PASS/FAIL.
//
// The core sees a single unified memory (instruction and data ports on the same
// array), MEM_WORDS words starting at MEM_BASE, loaded from +hex=<file> (one
// 32-bit word per line, $readmemh format, address 0 = MEM_BASE).
//
// A program ends by storing to TOHOST (+tohost=<addr>, default MEM_BASE+0x1000,
// which is where riscv-tests' link.ld puts it): value 1 means pass, any other
// value is (failing test number << 1) | 1. This is the riscv-tests convention
// and the directed tests in tb/asm use it too.
//
// +stall     data port randomly deasserts ready (exercises the pipeline freeze)
// +vcd       dump build/tb_core.vcd
// +timeout=N give up after N cycles (default 200000)
module tb_core;
  localparam logic [31:0] MEM_BASE  = 32'h8000_0000;
  localparam int          MEM_WORDS = 16384;                 // 64 KB
  localparam int          MEM_AW    = $clog2(MEM_WORDS);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_valid, dmem_ready, dmem_we;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;
  logic        irq_soft = 0, irq_timer = 0, irq_ext = 0;

  rv32i_core #(.RESET_PC(MEM_BASE)) dut (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_valid(dmem_valid), .dmem_ready(dmem_ready), .dmem_addr(dmem_addr),
    .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
    .irq_soft(irq_soft), .irq_timer(irq_timer), .irq_ext(irq_ext)
  );

  // ---- memory ------------------------------------------------------------
  // The same soc_mem the SoC uses, so the core is never verified against a
  // memory model that is kinder than the real one (2-cycle read, one wait state
  // on the data port).
  //
  // +stall adds random extra latency by withholding the request before the
  // access starts. Gating rw_ready externally would break soc_mem's protocol:
  // it pulses ready exactly once per access.
  bit stall_mode = 0, ready_rand = 1;
  always_ff @(posedge clk) ready_rand <= ($urandom_range(0, 3) != 0);

  logic mem_req;
  assign mem_req = dmem_valid && (!stall_mode || ready_rand);

  soc_mem #(.WORDS(MEM_WORDS)) u_mem (
    .clk(clk), .rst_n(rst_n),
    .r_addr(imem_addr[MEM_AW+1:2]), .r_data(imem_rdata),
    .rw_en(mem_req), .rw_we(dmem_we), .rw_be(dmem_be),
    .rw_addr(dmem_addr[MEM_AW+1:2]), .rw_wdata(dmem_wdata),
    .rw_ready(dmem_ready), .rw_rdata(dmem_rdata)
  );

  logic handshake;
  assign handshake = dmem_valid && dmem_ready;

  // ---- interrupt pokes from the program (directed tests only) --------------
  // A store to MEM_BASE+0x1010 sets {ext, timer, soft} from bits [2:0].
  logic [31:0] irq_reg_addr;
  assign irq_reg_addr = MEM_BASE + 32'h1010;
  always_ff @(posedge clk) begin
    if (handshake && dmem_we && dmem_addr == irq_reg_addr)
      {irq_ext, irq_timer, irq_soft} <= dmem_wdata[2:0];
  end

  // ---- run ---------------------------------------------------------------
  string       hexfile;
  logic [31:0] tohost;
  int          timeout, cycles;

  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("FAIL: no +hex=<file>"); $finish;
    end
    if (!$value$plusargs("tohost=%h", tohost)) tohost = MEM_BASE + 32'h1000;
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 200000;
    stall_mode = $test$plusargs("stall");
    // the array lives in soc_mem's flop-implementation generate block
    for (int i = 0; i < MEM_WORDS; i++) u_mem.g_flops.mem[i] = 32'h0;
    $readmemh(hexfile, u_mem.g_flops.mem);
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/tb_core.vcd");
      $dumpvars(0, tb_core);
    end
    repeat (3) @(negedge clk);
    rst_n = 1;
  end

`ifdef RVFI
  // ---- RVFI trace checks, every cycle (tb/rvfi_checks.svh) ------------------
  `define RVFI_IF   dut
  `define RVFI_CORE dut
  `include "rvfi_checks.svh"
`endif

  // +trace: print every trap (cause, pc, mtval) as it is taken
  bit trace = 0;
  initial trace = $test$plusargs("trace");
  always @(posedge clk)
    if (trace && rst_n && dut.trap)
      $display("  trap cause=%h pc=%h val=%h -> %h", dut.trap_cause, dut.ex_pc_q, dut.trap_val, dut.mtvec_q);

  always @(posedge clk) begin
    cycles++;
    if (rst_n && handshake && dmem_we && dmem_addr == tohost && dmem_wdata != 0) begin
`ifdef RVFI
      if (rvfi_errors != 0)
        $display("FAIL  %0d RVFI trace errors in %0d records", rvfi_errors, rvfi_records);
      else
`endif
      if (dmem_wdata == 32'h1)
        $display("PASS  cycles=%0d instret=%0d", cycles, dut.u_csr.minstret);
      else
        $display("FAIL  test %0d  (tohost=%h) cycles=%0d", dmem_wdata >> 1, dmem_wdata, cycles);
      $finish;
    end
    if (cycles > timeout) begin
      $display("FAIL  timeout after %0d cycles, pc=%h", cycles, dut.pc_q);
      $finish;
    end
  end
endmodule
