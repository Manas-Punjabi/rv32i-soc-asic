`timescale 1ns/1ps
// tb_apb_gpio.sv — verifies apb_gpio (W = 8).
//
//  G0  reset state       OUT = 0, pins low
//  G1  OUT               write drives the pins and reads back; upper bits ignored / read 0
//  G2  SET / CLR         bitwise, other bits untouched
//  G3  IN                pins read back after the 2-flop synchronizer, not before
//  G4  IN is asynchronous a change between clock edges is still captured cleanly
//  G5  unmapped offset   PSLVERR; SET/CLR are write-only (read returns 0, no error)
module tb_apb_gpio;
  localparam int SLAVE_AW = 12, W = 8;
  localparam logic [11:0] R_OUT = 12'h000, R_IN = 12'h004, R_SET = 12'h008, R_CLR = 12'h00C;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic                psel = 0, penable = 0, pwrite = 0;
  logic [SLAVE_AW-1:0] paddr = '0;
  logic [31:0]         pwdata = '0, prdata;
  logic                pready, pslverr;
  logic [W-1:0]        gpio_out, gpio_in = '0;

  apb_gpio #(.SLAVE_AW(SLAVE_AW), .W(W)) dut (
    .clk(clk), .rst_n(rst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .gpio_out(gpio_out), .gpio_in(gpio_in)
  );

  localparam int APB_AW = SLAVE_AW;   // this TB drives the slave directly
  int errors = 0, checks = 0;
  `include "apb_tasks.svh"

  initial begin
    logic [31:0] d;
    logic e;
    if ($test$plusargs("vcd")) begin $dumpfile("build/tb_apb_gpio.vcd"); $dumpvars(0, tb_apb_gpio); end
    repeat (3) @(negedge clk); rst_n = 1;

    // G0
    rd(R_OUT, d, "OUT"); chk(d == 0, "G0: OUT not 0 after reset");
    chk(gpio_out == '0, "G0: pins not low after reset");

    // G1
    wr(R_OUT, 32'hFFFF_FFA5, "OUT");
    chk(gpio_out == 8'hA5, $sformatf("G1: pins = %h", gpio_out));
    rd(R_OUT, d, "OUT"); chk(d == 32'h0000_00A5, $sformatf("G1: OUT reads %h", d));

    // G2
    wr(R_SET, 32'h0000_0018, "SET");
    chk(gpio_out == 8'hBD, $sformatf("G2: after SET pins = %h", gpio_out));
    wr(R_CLR, 32'h0000_00C1, "CLR");            // bit 6 is already 0: must stay 0
    chk(gpio_out == 8'h3C, $sformatf("G2: after CLR pins = %h", gpio_out));
    wr(R_SET, 32'h0, "SET"); wr(R_CLR, 32'h0, "CLR");
    chk(gpio_out == 8'h3C, "G2: SET/CLR of 0 changed the pins");

    // G3: drive inputs on a clock edge boundary and read after 0, 1, 2+ cycles
    @(negedge clk); gpio_in = 8'h5A;
    chk(dut.in_sync1 == 8'h00, "G3: IN visible with no synchronizer latency");
    @(negedge clk);
    chk(dut.in_sync1 == 8'h00, "G3: IN visible after one flop");
    @(negedge clk);
    chk(dut.in_sync1 == 8'h5A, "G3: IN not visible after two flops");
    rd(R_IN, d, "IN"); chk(d == 32'h0000_005A, $sformatf("G3: IN reads %h", d));

    // G4: change mid-cycle, an arbitrary offset from the edge
    #3.7; gpio_in = 8'hC3;
    repeat (3) @(negedge clk);
    rd(R_IN, d, "IN"); chk(d == 32'h0000_00C3, $sformatf("G4: IN reads %h", d));

    // G5
    apb_read(12'h010, d, e);      chk(e, "G5: no PSLVERR on unmapped read");
    apb_write(12'h010, 32'h0, e); chk(e, "G5: no PSLVERR on unmapped write");
    apb_read(R_SET, d, e); chk(!e && d == 0, "G5: SET read should be 0 without error");
    apb_read(R_CLR, d, e); chk(!e && d == 0, "G5: CLR read should be 0 without error");
    chk(gpio_out == 8'h3C, "G5: reads changed the pins");

    if (errors == 0) $display("PASS: %0d checks, apb_gpio W=%0d", checks, W);
    else             $display("FAIL: %0d errors / %0d checks", errors, checks);
    $finish;
  end

  initial begin #1_000_000; $display("FAIL: timeout"); $finish; end
endmodule
