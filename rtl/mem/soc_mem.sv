// soc_mem.sv — unified instruction/data memory: one read port and one
// read/write port. Either flops (USE_SRAM=0) or sky130 OpenRAM macros
// (USE_SRAM=1), behind one interface with identical timing.
//
// WHY THE TIMING LOOKS LIKE THIS
//
// A synchronous-read SRAM macro consumes a pipeline stage: it latches the
// address on a rising edge, reads during the following cycle, and drives the
// data out from the *falling* edge of that cycle, holding it only until the next
// rising edge (sky130 OpenRAM: dout has `timing_type : falling_edge`, 0.38-0.53
// ns). The consumer must capture it in a flop, and the value is usable only in
// the cycle after that. An array read in flops can be folded into the same cycle
// as the address; a macro cannot. The flop implementation below therefore models
// the macro's timing, so the core is verified against the timing it gets in
// silicon and one core works with either memory.
//
//   read port (fetch):  address in cycle N  ->  data valid in cycle N+2
//   read/write port:    request in cycle N, rw_ready low; ready in N+1 (one wait
//                       state); read data valid in N+2, i.e. the cycle after the
//                       handshake. Hold the request until rw_ready, which is what
//                       the core's dmem port already does.
//
// With USE_SRAM=1, WORDS must be a multiple of 512 and a power-of-two number of
// banks; bank select is the top address bit(s), delayed one cycle to line up
// with the data it selects.
module soc_mem #(
  parameter int    WORDS    = 4096,
  parameter int    USE_SRAM = 0,
  parameter int    AW       = $clog2(WORDS),   // derived; do not override
  parameter        MEM_INIT = ""               // flop build only; untyped for Icarus
)(
  input  logic          clk,
  input  logic          rst_n,
  // read port (fetch): always accepts an address
  input  logic [AW-1:0] r_addr,
  output logic [31:0]   r_data,
  // read/write port (data): hold the request until rw_ready
  input  logic          rw_en,
  input  logic          rw_we,
  input  logic [3:0]    rw_be,
  input  logic [AW-1:0] rw_addr,
  input  logic [31:0]   rw_wdata,
  output logic          rw_ready,
  output logic [31:0]   rw_rdata
);
  // ---- shared handshake: one wait state, ready pulses once per access -------
  logic acc_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) acc_q <= 1'b0;
    else        acc_q <= rw_en && !acc_q;
  end
  assign rw_ready = acc_q;

  // explicit generate/endgenerate: Icarus 12 and Yosys 0.33 are both happier with
  // it than with a bare module-scope conditional
  generate
  if (USE_SRAM == 0) begin : g_flops
    // ---- flop array, timed to match the macro --------------------------------
    logic [31:0] mem [0:WORDS-1];

`ifndef SYNTHESIS
    initial if (MEM_INIT != "") $readmemh(MEM_INIT, mem);
`endif

    logic [31:0] r_data_s1;
    always_ff @(posedge clk) begin
      r_data_s1 <= mem[r_addr];
      r_data    <= r_data_s1;
    end

    always_ff @(posedge clk) begin
      if (acc_q) begin
        if (rw_we) begin
          if (rw_be[0]) mem[rw_addr][7:0]   <= rw_wdata[7:0];
          if (rw_be[1]) mem[rw_addr][15:8]  <= rw_wdata[15:8];
          if (rw_be[2]) mem[rw_addr][23:16] <= rw_wdata[23:16];
          if (rw_be[3]) mem[rw_addr][31:24] <= rw_wdata[31:24];
        end else begin
          rw_rdata <= mem[rw_addr];
        end
      end
    end
  end else begin : g_sram
    // ---- sky130 OpenRAM macros ----------------------------------------------
    localparam int BANK_AW = 9;                       // 512 words per macro
    localparam int NBANKS  = WORDS / 512;
    localparam int SELW    = (NBANKS > 1) ? $clog2(NBANKS) : 1;

    logic            start;                        // first cycle of an access
    assign start = rw_en && !acc_q;

    logic [SELW-1:0] r_bank, rw_bank, r_bank_q, rw_bank_q;
    // flattened: bank b at [b*32 +: 32]. As unpacked arrays Yosys reports
    // "Replacing memory with list of registers", which is noise on what are
    // just the macros' output nets.
    logic [NBANKS*32-1:0] r_dout, rw_dout;

    if (NBANKS > 1) begin : g_sel
      assign r_bank  = r_addr[AW-1 -: SELW];
      assign rw_bank = rw_addr[AW-1 -: SELW];
    end else begin : g_nosel
      assign r_bank  = '0;
      assign rw_bank = '0;
    end

    // the bank select must be delayed to line up with the data it chooses:
    // address latched at the end of cycle N, data captured at the end of N+1
    always_ff @(posedge clk) begin
      r_bank_q <= r_bank;
      if (start) rw_bank_q <= rw_bank;
    end

    for (genvar b = 0; b < NBANKS; b++) begin : g_bank
      sky130_sram_2kbyte_1rw1r_32x512_8 u_sram (
        // port 0: read/write, driven only in the first cycle of an access
        .clk0   (clk),
        .csb0   (!(start && (rw_bank == SELW'(b)))),
        .web0   (!rw_we),
        .wmask0 (rw_be),
        .addr0  (rw_addr[BANK_AW-1:0]),
        .din0   (rw_wdata),
        .dout0  (rw_dout[b*32 +: 32]),
        // port 1: read, issued every cycle for the selected bank
        .clk1   (clk),
        .csb1   (!(r_bank == SELW'(b))),
        .addr1  (r_addr[BANK_AW-1:0]),
        .dout1  (r_dout[b*32 +: 32])
      );
    end

    // capture each beat in the cycle it is valid: the macro drives dout only
    // from the falling edge until the next rising edge
    always_ff @(posedge clk) begin
      r_data <= r_dout[r_bank_q*32 +: 32];
      if (acc_q && !rw_we) rw_rdata <= rw_dout[rw_bank_q*32 +: 32];
    end
  end
  endgenerate
endmodule
