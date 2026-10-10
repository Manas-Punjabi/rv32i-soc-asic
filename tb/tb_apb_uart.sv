`timescale 1ns/1ps
// tb_apb_uart.sv — verifies apb_uart against a bit-level reference on both sides.
//
//  U0  reset state          tx_ready, tx_idle, no rx, DIV = reset value, tx line high
//  U1  registers            DIV and CTRL read back
//  U2  TX framing           start, 8 data bits LSB first, stop; several bytes
//  U3  TX back-to-back      second byte written while the first shifts; no gap on the line
//  U4  TX overrun           a write while not ready is dropped, later bytes still go out
//  U5  TX at a new DIV      framing holds after changing the divider
//  U6  RX                   asynchronous transmitter, 2% baud error and random phase
//  U7  RX overrun           second byte dropped, first kept, flag set, W1C clears it
//  U8  RX framing error     stop bit low: flag set, no byte delivered, W1C clears it
//  U9  RX glitch            a low pulse shorter than half a bit is ignored
//  U10 interrupts           rx_ie / tx_ie gate irq
//  U11 unmapped offset      PSLVERR
//  U12 loopback             tx wired to rx: bytes round-trip through both halves
module tb_apb_uart;
  localparam int SLAVE_AW = 12;
  localparam int DIV = 16;                       // clocks per bit in simulation
  localparam logic [11:0] R_TXDATA = 12'h000, R_RXDATA = 12'h004, R_STATUS = 12'h008,
                          R_CTRL = 12'h00C, R_DIV = 12'h010;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic                psel = 0, penable = 0, pwrite = 0;
  logic [SLAVE_AW-1:0] paddr = '0;
  logic [31:0]         pwdata = '0, prdata;
  logic                pready, pslverr;
  logic                tx_o, rx_i, irq;
  bit                  loopback = 0;
  logic                rx_drive = 1;
  assign rx_i = loopback ? tx_o : rx_drive;

  apb_uart #(.SLAVE_AW(SLAVE_AW), .DIV_RESET(DIV)) dut (
    .clk(clk), .rst_n(rst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .tx_o(tx_o), .rx_i(rx_i), .irq(irq)
  );

  localparam int APB_AW = SLAVE_AW;   // this TB drives the slave directly
  int errors = 0, checks = 0;
  `include "apb_tasks.svh"

  // ---- reference receiver on tx_o: samples at mid-bit, negedge clk ------------
  task automatic ref_rx(output logic [7:0] b, output bit ok, input int div = DIV);
    ok = 1;
    @(negedge tx_o);
    repeat (div / 2) @(negedge clk);
    if (tx_o !== 1'b0) ok = 0;                 // start bit
    for (int i = 0; i < 8; i++) begin
      repeat (div) @(negedge clk);
      b[i] = tx_o;
    end
    repeat (div) @(negedge clk);
    if (tx_o !== 1'b1) ok = 0;                 // stop bit
  endtask

  // ---- reference transmitter on rx_i: asynchronous to clk --------------------
  // bit period in ns; DIV*10 is nominal, the caller adds error and phase
  task automatic ref_tx(input logic [7:0] b, input real bit_ns, input bit stop = 1);
    rx_drive = 0;                              // start
    #(bit_ns);
    for (int i = 0; i < 8; i++) begin rx_drive = b[i]; #(bit_ns); end
    rx_drive = stop;                           // stop
    #(bit_ns);
    rx_drive = 1;
  endtask

  task automatic expect_tx(input logic [7:0] want, input string what, input int div = DIV);
    logic [7:0] got; bit ok;
    ref_rx(got, ok, div);
    chk(ok, $sformatf("%s: bad framing", what));
    chk(got == want, $sformatf("%s: got %h exp %h", what, got, want));
  endtask

  // byte lists, element i at [i*8 +: 8] (Icarus cannot initialize unpacked arrays)
  localparam logic [39:0] U2_BYTES  = {8'h41, 8'hFF, 8'h00, 8'hAA, 8'h55};
  localparam logic [31:0] U6_BYTES  = {8'h80, 8'h01, 8'hC3, 8'h5A};
  localparam logic [23:0] U12_BYTES = {8'h21, 8'h69, 8'h48};

  initial begin
    logic [31:0] d;
    logic e;
    logic [7:0] b;
    real per;
    int t_stop, t_start;
    if ($test$plusargs("vcd")) begin $dumpfile("build/tb_apb_uart.vcd"); $dumpvars(0, tb_apb_uart); end
    repeat (3) @(negedge clk); rst_n = 1;

    // U0
    rd(R_STATUS, d, "STATUS");
    chk(d[4:0] == 5'b00011, $sformatf("U0: STATUS after reset = %b", d[4:0]));
    rd(R_DIV, d, "DIV");
    chk(d == DIV, "U0: DIV reset value");
    chk(tx_o === 1'b1, "U0: tx line not idle-high");

    // U1
    wr(R_CTRL, 32'h3, "CTRL"); rd(R_CTRL, d, "CTRL");
    chk(d == 32'h3, "U1: CTRL readback");
    wr(R_CTRL, 32'h0, "CTRL");
    wr(R_DIV, 32'd8, "DIV"); rd(R_DIV, d, "DIV");
    chk(d == 32'd8, "U1: DIV readback");
    wr(R_DIV, DIV, "DIV");

    // U2: framing, one byte at a time
    for (int i = 0; i < 5; i++) begin
      b = U2_BYTES[i*8 +: 8];
      fork
        wr(R_TXDATA, {24'h0, b}, "TXDATA");
        expect_tx(b, $sformatf("U2 byte %h", b));
      join
      rd(R_STATUS, d, "STATUS");
      while (!d[1]) rd(R_STATUS, d, "STATUS");           // wait tx_idle
    end

    // U3: back-to-back with no gap: the second start bit must follow the first
    // stop bit directly, so a reference receiver run twice in a row sees both
    fork
      begin
        wr(R_TXDATA, 32'h12, "TXDATA");
        rd(R_STATUS, d, "STATUS");
        chk(d[0] == 1'b1, "U3: tx_ready should be 1 once the holding register was loaded into the shifter");
        wr(R_TXDATA, 32'h34, "TXDATA");
        rd(R_STATUS, d, "STATUS");
        chk(d[0] == 1'b0 && d[1] == 1'b0, "U3: not ready/not idle with two bytes queued");
      end
      begin
        expect_tx(8'h12, "U3 first");
        t_stop = $time;
        @(negedge tx_o); t_start = $time;
        chk(t_start - t_stop < DIV * 10, $sformatf("U3: gap of %0d ns between bytes", t_start - t_stop));
        repeat (DIV / 2) @(negedge clk);
        for (int i = 0; i < 8; i++) begin repeat (DIV) @(negedge clk); d[i] = tx_o; end
        chk(d[7:0] == 8'h34, $sformatf("U3 second: got %h", d[7:0]));
        repeat (DIV) @(negedge clk);
      end
    join
    rd(R_STATUS, d, "STATUS"); while (!d[1]) rd(R_STATUS, d, "STATUS");

    // U4: three quick writes, the third finds tx_ready = 0 and is dropped
    fork
      begin
        wr(R_TXDATA, 32'hA1, "TXDATA");
        wr(R_TXDATA, 32'hB2, "TXDATA");
        wr(R_TXDATA, 32'hC3, "TXDATA");             // dropped
      end
      begin
        expect_tx(8'hA1, "U4 first");
        expect_tx(8'hB2, "U4 second");
      end
    join
    rd(R_STATUS, d, "STATUS"); while (!d[1]) rd(R_STATUS, d, "STATUS");
    fork
      begin repeat (DIV * 12) @(negedge clk); end
      begin @(negedge tx_o); fail("U4: a third byte was sent"); end
    join_any
    disable fork;
    checks++;

    // U5: change DIV and transmit at the new rate
    wr(R_DIV, 32'd8, "DIV");
    fork
      wr(R_TXDATA, 32'h96, "TXDATA");
      expect_tx(8'h96, "U5 at DIV=8", 8);
    join
    rd(R_STATUS, d, "STATUS"); while (!d[1]) rd(R_STATUS, d, "STATUS");
    wr(R_DIV, DIV, "DIV");

    // U6: RX from an asynchronous transmitter, +2% and -2% baud error, random phase
    for (int i = 0; i < 4; i++) begin
      b   = U6_BYTES[i*8 +: 8];
      per = (i % 2) ? DIV * 10.0 * 1.02 : DIV * 10.0 * 0.98;
      #($urandom_range(0, 9) * 1.0 + 0.3);
      ref_tx(b, per);
      rd(R_STATUS, d, "STATUS");
      chk(d[2] == 1'b1, $sformatf("U6: rx_valid not set for %h", b));
      rd(R_RXDATA, d, "RXDATA");
      chk(d[7:0] == b, $sformatf("U6: got %h exp %h", d[7:0], b));
      rd(R_STATUS, d, "STATUS");
      chk(d[2] == 1'b0, "U6: rx_valid not cleared by the read");
    end

    // U7: two bytes without reading: overrun, first byte kept
    ref_tx(8'h11, DIV * 10.0);
    ref_tx(8'h22, DIV * 10.0);
    rd(R_STATUS, d, "STATUS");
    chk(d[3] == 1'b1 && d[2] == 1'b1, $sformatf("U7: STATUS = %b", d[4:0]));
    rd(R_RXDATA, d, "RXDATA");
    chk(d[7:0] == 8'h11, $sformatf("U7: kept %h, expected the first byte", d[7:0]));
    wr(R_STATUS, 32'h8, "STATUS W1C");
    rd(R_STATUS, d, "STATUS");
    chk(d[3] == 1'b0 && d[2] == 1'b0, "U7: overrun not cleared / byte not popped");

    // U8: framing error
    ref_tx(8'h33, DIV * 10.0, 0);
    #(DIV * 10);
    rd(R_STATUS, d, "STATUS");
    chk(d[4] == 1'b1 && d[2] == 1'b0, $sformatf("U8: STATUS = %b", d[4:0]));
    wr(R_STATUS, 32'h10, "STATUS W1C");
    rd(R_STATUS, d, "STATUS");
    chk(d[4] == 1'b0, "U8: rx_frame not cleared");

    // U9: glitch shorter than half a bit
    rx_drive = 0; #(DIV * 10 / 4); rx_drive = 1;
    #(DIV * 10 * 12);
    rd(R_STATUS, d, "STATUS");
    chk(d[4:2] == 3'b000, $sformatf("U9: glitch produced STATUS = %b", d[4:0]));
    chk(dut.rx_state == dut.RX_IDLE, "U9: receiver not idle after glitch");

    // U10: interrupts
    chk(irq == 1'b0, "U10: irq with nothing enabled");
    wr(R_CTRL, 32'h2, "CTRL tx_ie");
    chk(irq == 1'b1, "U10: tx_ie with tx_ready should raise irq");
    wr(R_CTRL, 32'h1, "CTRL rx_ie");
    chk(irq == 1'b0, "U10: rx_ie with no byte should not raise irq");
    ref_tx(8'h7E, DIV * 10.0);
    chk(irq == 1'b1, "U10: rx_ie with a byte waiting should raise irq");
    rd(R_RXDATA, d, "RXDATA");
    chk(irq == 1'b0, "U10: irq should drop after the pop");
    wr(R_CTRL, 32'h0, "CTRL");

    // U11
    apb_read(12'h014, d, e);  chk(e, "U11: no PSLVERR on unmapped read");
    apb_write(12'h100, 32'h0, e); chk(e, "U11: no PSLVERR on unmapped write");

    // U12: loopback through both halves
    loopback = 1;
    for (int i = 0; i < 3; i++) begin
      b = U12_BYTES[i*8 +: 8];
      wr(R_TXDATA, {24'h0, b}, "TXDATA");
      rd(R_STATUS, d, "STATUS"); while (!d[2]) rd(R_STATUS, d, "STATUS");
      rd(R_RXDATA, d, "RXDATA");
      chk(d[7:0] == b, $sformatf("U12: loopback got %h exp %h", d[7:0], b));
    end
    loopback = 0;

    if (errors == 0) $display("PASS: %0d checks, apb_uart DIV=%0d", checks, DIV);
    else             $display("FAIL: %0d errors / %0d checks", errors, checks);
    $finish;
  end

  initial begin #5_000_000; $display("FAIL: timeout"); $finish; end
endmodule
