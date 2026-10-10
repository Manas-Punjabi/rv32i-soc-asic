`timescale 1ns/1ps
// tb_soc_mem.sv — proves the SRAM-macro build of soc_mem behaves identically to
// the flop build, cycle for cycle, on both ports.
//
// Two instances get the same stimulus: one USE_SRAM=0, one USE_SRAM=1 wired to
// the PDK's OpenRAM behavioural models. Every write goes to both, so their
// contents stay equal, and every read is compared against the other instance and
// against a golden array. This is what validates the bank decode, the delayed
// bank select and the output capture before the macro goes near the SoC.
//
//  M0  handshake        rw_ready is low for one cycle, then high for exactly one
//  M1  write then read  every word, through the rw port
//  M2  fetch port       every word, through the read-only port
//  M3  byte enables     partial writes land on the right lanes
//  M4  bank crossing    back-to-back accesses that alternate banks
module tb_soc_mem;
  localparam int WORDS = 1024;              // 2 banks of 512
  localparam int AW    = $clog2(WORDS);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [AW-1:0] r_addr = '0, rw_addr = '0;
  logic          rw_en = 0, rw_we = 0;
  logic [3:0]    rw_be = 4'hF;
  logic [31:0]   rw_wdata = '0;

  logic [31:0] f_r_data, f_rw_rdata, s_r_data, s_rw_rdata;
  logic        f_ready, s_ready;

  soc_mem #(.WORDS(WORDS), .USE_SRAM(0)) u_flop (
    .clk(clk), .rst_n(rst_n),
    .r_addr(r_addr), .r_data(f_r_data),
    .rw_en(rw_en), .rw_we(rw_we), .rw_be(rw_be), .rw_addr(rw_addr),
    .rw_wdata(rw_wdata), .rw_ready(f_ready), .rw_rdata(f_rw_rdata)
  );

  soc_mem #(.WORDS(WORDS), .USE_SRAM(1)) u_sram (
    .clk(clk), .rst_n(rst_n),
    .r_addr(r_addr), .r_data(s_r_data),
    .rw_en(rw_en), .rw_we(rw_we), .rw_be(rw_be), .rw_addr(rw_addr),
    .rw_wdata(rw_wdata), .rw_ready(s_ready), .rw_rdata(s_rw_rdata)
  );

  int errors = 0, checks = 0;
  logic [31:0] golden [0:WORDS-1];

  task automatic chk(input bit cond, input string msg);
    checks++;
    if (!cond) begin errors++; $display("  FAIL: %s", msg); end
  endtask

  // one write: hold the request until ready
  task automatic wr_word(input logic [AW-1:0] a, input logic [31:0] d,
                         input logic [3:0] be = 4'hF);
    @(negedge clk);
    rw_en = 1; rw_we = 1; rw_addr = a; rw_wdata = d; rw_be = be;
    @(posedge clk);
    while (!f_ready) @(posedge clk);
    chk(f_ready === s_ready, $sformatf("ready mismatch on write %0d", a));
    @(negedge clk);
    rw_en = 0; rw_we = 0;
    for (int i = 0; i < 4; i++) if (be[i]) golden[a][i*8 +: 8] = d[i*8 +: 8];
  endtask

  // one read through the rw port; data is valid the cycle after the handshake
  task automatic rd_word(input logic [AW-1:0] a, output logic [31:0] f,
                         output logic [31:0] s);
    @(negedge clk);
    rw_en = 1; rw_we = 0; rw_addr = a;
    @(posedge clk);
    while (!f_ready) @(posedge clk);
    chk(f_ready === s_ready, $sformatf("ready mismatch on read %0d", a));
    @(negedge clk);
    rw_en = 0;
    @(negedge clk);              // the cycle after the handshake
    f = f_rw_rdata; s = s_rw_rdata;
  endtask

  initial begin
    logic [31:0] f, s;
    int nready;
    repeat (3) @(negedge clk); rst_n = 1;

    // M0: the handshake shape. The request is asserted at a negedge, so it is
    // captured at the following posedge; ready is low until then and high for
    // exactly the one cycle after it.
    @(negedge clk); rw_en = 1; rw_we = 1; rw_addr = 0; rw_wdata = 32'hA5A5_0000;
    #1;
    chk(f_ready === 1'b0 && s_ready === 1'b0, "M0: ready high before the request was captured");
    @(posedge clk); #1;
    chk(f_ready === 1'b1 && s_ready === 1'b1, "M0: ready not high in the access cycle");
    @(negedge clk); rw_en = 0; rw_we = 0;
    @(posedge clk); #1;
    chk(f_ready === 1'b0 && s_ready === 1'b0, "M0: ready high for more than one cycle");
    golden[0] = 32'hA5A5_0000;

    // M1: fill every word, then read it all back through the rw port
    for (int a = 0; a < WORDS; a++)
      wr_word(AW'(a), 32'h1000_0000 + 32'(a) * 32'h0001_0001);
    for (int a = 0; a < WORDS; a++) begin
      rd_word(AW'(a), f, s);
      chk(f === golden[a], $sformatf("M1: flop rw read %0d got %h exp %h", a, f, golden[a]));
      chk(s === golden[a], $sformatf("M1: sram rw read %0d got %h exp %h", a, s, golden[a]));
    end

    // M2: the same through the fetch port, which is read every cycle
    for (int a = 0; a < WORDS; a++) begin
      @(negedge clk); r_addr = AW'(a);
      @(negedge clk);              // address latched
      @(negedge clk);              // data valid this cycle (N+2)
      chk(f_r_data === golden[a], $sformatf("M2: flop fetch %0d got %h exp %h", a, f_r_data, golden[a]));
      chk(s_r_data === golden[a], $sformatf("M2: sram fetch %0d got %h exp %h", a, s_r_data, golden[a]));
    end

    // M3: byte enables
    wr_word(AW'(7), 32'hDEAD_BEEF, 4'b0010);
    rd_word(AW'(7), f, s);
    chk(f === golden[7], $sformatf("M3: flop byte-enable got %h exp %h", f, golden[7]));
    chk(s === golden[7], $sformatf("M3: sram byte-enable got %h exp %h", s, golden[7]));
    wr_word(AW'(7), 32'h1122_3344, 4'b1001);
    rd_word(AW'(7), f, s);
    chk(f === golden[7], $sformatf("M3: flop byte-enable 2 got %h exp %h", f, golden[7]));
    chk(s === golden[7], $sformatf("M3: sram byte-enable 2 got %h exp %h", s, golden[7]));

    // M4: alternate banks back to back (bank = top address bit)
    for (int i = 0; i < 8; i++) begin
      logic [AW-1:0] a = AW'((i % 2) ? (512 + i) : i);
      rd_word(a, f, s);
      chk(f === golden[a], $sformatf("M4: flop bank-cross %0d got %h exp %h", a, f, golden[a]));
      chk(s === golden[a], $sformatf("M4: sram bank-cross %0d got %h exp %h", a, s, golden[a]));
    end
    // and on the fetch port, where the bank select has to be delayed to match
    for (int i = 0; i < 8; i++) begin
      logic [AW-1:0] a = AW'((i % 2) ? (512 + i) : i);
      @(negedge clk); r_addr = a;
      @(negedge clk); @(negedge clk);
      chk(f_r_data === golden[a], $sformatf("M4: flop fetch bank-cross %0d got %h exp %h",
                                            a, f_r_data, golden[a]));
      chk(s_r_data === golden[a], $sformatf("M4: sram fetch bank-cross %0d got %h exp %h",
                                            a, s_r_data, golden[a]));
    end

    if (errors == 0) $display("PASS: %0d checks, soc_mem flop vs sram, WORDS=%0d", checks, WORDS);
    else             $display("FAIL: %0d errors / %0d checks", errors, checks);
    $finish;
  end

  initial begin #5_000_000; $display("FAIL: timeout"); $finish; end
endmodule
