`timescale 1ns/1ps
// tb_apb_timer.sv — verifies apb_timer.
//
//  T0  reset state        mtime small, mtimecmp all ones, no irq, msip 0
//  T1  mtime runs         +1 per clock, measured across a known gap; HI/LO consistent
//  T2  mtime writable     LO and HI take a value and keep counting from it
//  T3  compare            irq_timer exactly when mtime reaches mtimecmp, stays until moved
//  T4  64-bit compare     HI decides when LO would say otherwise
//  T5  race-free update   HI=all ones, LO, HI sequence never glitches irq
//  T6  msip               write 1 / 0 drives irq_soft
//  T7  unmapped offset    PSLVERR
module tb_apb_timer;
  localparam int SLAVE_AW = 12;
  localparam logic [11:0] R_MTIME_LO = 12'h000, R_MTIME_HI = 12'h004,
                          R_CMP_LO = 12'h008, R_CMP_HI = 12'h00C, R_MSIP = 12'h010;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic                psel = 0, penable = 0, pwrite = 0;
  logic [SLAVE_AW-1:0] paddr = '0;
  logic [31:0]         pwdata = '0, prdata;
  logic                pready, pslverr, irq_timer, irq_soft;

  apb_timer #(.SLAVE_AW(SLAVE_AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .irq_timer(irq_timer), .irq_soft(irq_soft)
  );

  localparam int APB_AW = SLAVE_AW;   // this TB drives the slave directly
  int errors = 0, checks = 0;
  `include "apb_tasks.svh"

  // count cycles in which irq_timer was high during a window
  int irq_high;
  bit count_irq = 0;
  always @(posedge clk) if (count_irq && irq_timer) irq_high++;

  initial begin
    logic [31:0] d, lo, hi, lo2;
    logic e;
    int t0, t1;
    if ($test$plusargs("vcd")) begin $dumpfile("build/tb_apb_timer.vcd"); $dumpvars(0, tb_apb_timer); end
    repeat (3) @(negedge clk); rst_n = 1;

    // T0
    rd(R_MTIME_HI, d, "MTIME_HI"); chk(d == 0, "T0: MTIME_HI not 0");
    rd(R_MTIME_LO, d, "MTIME_LO"); chk(d < 32'd100, $sformatf("T0: MTIME_LO = %0d", d));
    rd(R_CMP_LO, d, "CMP_LO");     chk(d == 32'hFFFF_FFFF, "T0: MTIMECMP_LO not all ones");
    rd(R_CMP_HI, d, "CMP_HI");     chk(d == 32'hFFFF_FFFF, "T0: MTIMECMP_HI not all ones");
    rd(R_MSIP, d, "MSIP");         chk(d == 0, "T0: MSIP not 0");
    chk(!irq_timer && !irq_soft, "T0: irq after reset");

    // T1: two reads a known number of cycles apart. Each apb_read samples
    // prdata at the same point of its access phase, so the difference is exact.
    rd(R_MTIME_LO, lo, "MTIME_LO");  t0 = $time;
    repeat (37) @(negedge clk);
    rd(R_MTIME_LO, lo2, "MTIME_LO"); t1 = $time;
    chk(lo2 - lo == (t1 - t0) / 10, $sformatf("T1: mtime advanced %0d in %0d cycles", lo2 - lo, (t1 - t0) / 10));

    // T2: write both halves, then read back a consistent 64-bit value
    wr(R_MTIME_HI, 32'h0000_0005, "MTIME_HI");
    wr(R_MTIME_LO, 32'hFFFF_FFF0, "MTIME_LO");
    repeat (20) @(negedge clk);                  // let it carry into HI
    rd(R_MTIME_LO, lo, "MTIME_LO");
    rd(R_MTIME_HI, hi, "MTIME_HI");
    chk(hi == 32'h6 && lo < 32'd100, $sformatf("T2: after write and carry: %h_%h", hi, lo));

    // T3: compare in the near future; irq exactly when mtime reaches it
    wr(R_MTIME_HI, 32'h0, "MTIME_HI");
    wr(R_MTIME_LO, 32'h0, "MTIME_LO");
    wr(R_CMP_HI, 32'h0, "CMP_HI");
    wr(R_CMP_LO, 32'd200, "CMP_LO");
    chk(!irq_timer, "T3: irq before compare reached");
    @(posedge irq_timer);
    chk(dut.mtime == 64'd200, $sformatf("T3: irq rose at mtime=%0d, expected 200", dut.mtime));
    repeat (50) @(negedge clk);
    chk(irq_timer, "T3: irq did not stay asserted");
    wr(R_CMP_LO, 32'hFFFF_FFFF, "CMP_LO");
    wr(R_CMP_HI, 32'hFFFF_FFFF, "CMP_HI");
    chk(!irq_timer, "T3: irq not cleared by moving mtimecmp away");

    // T4: HI decides. mtime = 0x1_0000_0100, cmp = 0x0_FFFF_FFFF -> irq (mtime > cmp)
    wr(R_MTIME_HI, 32'h1, "MTIME_HI");
    wr(R_MTIME_LO, 32'h100, "MTIME_LO");
    wr(R_CMP_HI, 32'h0, "CMP_HI");
    wr(R_CMP_LO, 32'hFFFF_FFFF, "CMP_LO");
    chk(irq_timer, "T4: HI greater but no irq");
    // cmp = 0x2_0000_0000 -> no irq although LO(cmp)=0 < LO(mtime)
    wr(R_CMP_HI, 32'h2, "CMP_HI");
    wr(R_CMP_LO, 32'h0, "CMP_LO");
    chk(!irq_timer, "T4: HI smaller on mtime side but irq asserted");

    // T5: race-free sequence from a far-future compare to a near-future one.
    // Naive LO-first would pass through cmp = {2, small} < mtime and glitch.
    wr(R_MTIME_HI, 32'h2, "MTIME_HI");
    wr(R_MTIME_LO, 32'h5000, "MTIME_LO");
    wr(R_CMP_HI, 32'hFFFF_FFFF, "CMP_HI");
    wr(R_CMP_LO, 32'hFFFF_FFFF, "CMP_LO");
    irq_high = 0; count_irq = 1;
    wr(R_CMP_HI, 32'hFFFF_FFFF, "CMP_HI");      // step 1: HI = all ones (already)
    wr(R_CMP_LO, 32'h0000_9000, "CMP_LO");      // step 2: LO
    wr(R_CMP_HI, 32'h2, "CMP_HI");              // step 3: real HI
    count_irq = 0;
    chk(irq_high == 0, $sformatf("T5: irq glitched for %0d cycles during update", irq_high));
    chk(!irq_timer, "T5: irq after update (target still in the future)");

    // T6: msip
    wr(R_MSIP, 32'h1, "MSIP");
    chk(irq_soft, "T6: msip=1 but no irq_soft");
    rd(R_MSIP, d, "MSIP"); chk(d == 1, "T6: MSIP readback");
    wr(R_MSIP, 32'hFFFF_FFFE, "MSIP");          // only bit 0 counts
    chk(!irq_soft, "T6: irq_soft after msip=0");

    // T7
    apb_read(12'h014, d, e);      chk(e, "T7: no PSLVERR on unmapped read");
    apb_write(12'h800, 32'h0, e); chk(e, "T7: no PSLVERR on unmapped write");

    if (errors == 0) $display("PASS: %0d checks, apb_timer", checks);
    else             $display("FAIL: %0d errors / %0d checks", errors, checks);
    $finish;
  end

  initial begin #1_000_000; $display("FAIL: timeout"); $finish; end
endmodule
