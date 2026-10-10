// apb_master.sv — turns the core's data-port request into one APB transfer.
//
// The core holds valid/addr/wdata/we stable until ready, so they drive the APB
// signals directly. Cycle 1 of a request is the setup phase (psel, !penable),
// cycle 2+ the access phase (penable) until the slave's pready. ready to the
// core is asserted in the completing cycle; read data is registered so it stays
// valid afterwards, as the core's port contract requires.
//
// APB3: no PSTRB, so a byte or half-word store reaches the slave as the full
// lane-replicated word. Peripherals are word registers; firmware uses 32-bit
// accesses.
//
// PSLVERR is dropped: the core has no bus-error exception in v1, so an access to
// an unmapped address completes and returns zero. An earlier version registered
// it on an `err` output that nothing read -- a flip-flop with no consumer -- so
// the port is gone rather than left as a hook for a feature that does not exist.
// Adding it back means adding a trap cause in rv32i_core at the same time.
module apb_master #(
  parameter int ADDR_W = 20
)(
  input  logic              clk,
  input  logic              rst_n,
  // core side
  input  logic              req,          // valid && this address is a peripheral
  input  logic              we,
  input  logic [31:0]       addr,
  input  logic [31:0]       wdata,
  output logic              ready,
  output logic [31:0]       rdata,        // registered, valid from the cycle after ready
  // APB side
  output logic              psel,
  output logic              penable,
  output logic              pwrite,
  output logic [ADDR_W-1:0] paddr,
  output logic [31:0]       pwdata,
  input  logic [31:0]       prdata,
  input  logic              pready,
  input  logic              pslverr
);
  logic access;     // 0: setup phase (or idle), 1: access phase

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)           access <= 1'b0;
    else if (!access)     access <= req;
    else if (pready)      access <= 1'b0;
  end

  assign psel    = req;
  assign penable = access;
  assign pwrite  = we;
  assign paddr   = addr[ADDR_W-1:0];
  assign pwdata  = wdata;
  assign ready   = access && pready;

  always_ff @(posedge clk)
    if (ready) rdata <= prdata;

  // addr[31:ADDR_W] is decoded by soc_top; pslverr is dropped (see the header)
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, addr[31:ADDR_W], pslverr};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
