// apb_fabric.sv — single-master APB interconnect with address decode.
//
// Slave n owns addresses where PADDR[ADDR_W-1:SLAVE_AW] == n.
// With the default ADDR_W=20, SLAVE_AW=12 that is a 4 KB window per slave:
//   slave 0 @ 0x00000, slave 1 @ 0x01000, slave 2 @ 0x02000, ...
// An access to an unmapped slave completes in one cycle and returns
// PSLVERR with zero data, so a stray access can never hang the bus.
module apb_fabric #(
  parameter int N_SLAVES = 4,
  parameter int ADDR_W   = 20,
  parameter int SLAVE_AW = 12
)(
  // master side
  input  logic                clk,
  input  logic                rst_n,
  input  logic                psel,
  input  logic                penable,
  input  logic                pwrite,
  input  logic [ADDR_W-1:0]   paddr,
  input  logic [31:0]         pwdata,
  output logic [31:0]         prdata,
  output logic                pready,
  output logic                pslverr,
  // slave side (flattened: slave n occupies bit n / [n*32 +: 32])
  output logic [N_SLAVES-1:0]      s_psel,
  output logic                     s_penable,
  output logic                     s_pwrite,
  output logic [SLAVE_AW-1:0]      s_paddr,
  output logic [31:0]              s_pwdata,
  input  logic [N_SLAVES*32-1:0]   s_prdata,
  input  logic [N_SLAVES-1:0]      s_pready,
  input  logic [N_SLAVES-1:0]      s_pslverr
);
  localparam int SEL_W = ADDR_W - SLAVE_AW;

  logic [SEL_W-1:0] sel;
  logic             hit;

  assign sel       = paddr[ADDR_W-1:SLAVE_AW];
  assign s_penable = penable;
  assign s_pwrite  = pwrite;
  assign s_paddr   = paddr[SLAVE_AW-1:0];
  assign s_pwdata  = pwdata;

  always_comb begin
    s_psel = '0;
    hit    = 1'b0;
    for (int n = 0; n < N_SLAVES; n++) begin
      if (psel && (sel == SEL_W'(n))) begin
        s_psel[n] = 1'b1;
        hit       = 1'b1;
      end
    end
  end

  // response mux; unmapped access terminates immediately with an error
  always_comb begin
    prdata  = '0;
    pready  = 1'b1;
    pslverr = 1'b0;
    if (!hit) begin
      pslverr = psel;
    end else begin
      for (int n = 0; n < N_SLAVES; n++) begin
        if (s_psel[n]) begin
          prdata  = s_prdata[n*32 +: 32];
          pready  = s_pready[n];
          pslverr = s_pslverr[n];
        end
      end
    end
  end

  // The fabric is purely combinational today. clk/rst_n are in the port list so
  // it can gain pipelining or a default-slave timeout without a port change.
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, clk, rst_n};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
