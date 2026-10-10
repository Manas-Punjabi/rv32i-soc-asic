// soc_top.sv — RV32I core + unified memory + APB peripherals.
//
//   0x8000_0000 ..  unified RAM (soc_mem), MEM_WORDS words; reset PC = 0x8000_0000.
//                   Aliased across the 0x8xxx_xxxx window (address bits above the
//                   memory size are ignored). Fetch and data share it (1R + 1RW).
//   0x4000_0000 ..  APB, 4 KB per slave: 0 UART, 1 matrix accelerator, 2 timer, 3 GPIO.
//                   One APB transfer per data access; the core stalls meanwhile.
//   elsewhere       reads return 0, writes are dropped, no trap.
//
// Fetching from the APB window is not supported (a fetch there reads RAM aliases).
// PSLVERR from a slave is not an exception in v1: the access completes and the
// error is dropped. Byte/half-word stores to peripherals arrive as full words.
//
// Reset: rst_n is asynchronous in, released synchronously through two flops.
// Interrupts: timer -> irq_timer, MSIP -> irq_soft, UART -> irq_ext.
module soc_top #(
  parameter int    MEM_WORDS = 16384,          // 64 KB
  parameter int    USE_SRAM  = 0,              // 1: sky130 OpenRAM macros instead of flops
  parameter        MEM_INIT  = "",             // $readmemh image, simulation only (untyped: Icarus)
  parameter int    N         = 4,              // accelerator matrix size
  parameter int    DW        = 32,             // accelerator data width
  parameter int    SPLIT_MUL = 0,
  parameter int    UART_DIV  = 868,            // 100 MHz / 115200
  parameter int    GPIO_W    = 8
)(
  input  logic              clk,
  input  logic              rst_n,
  output logic              uart_tx,
  input  logic              uart_rx,
  output logic [GPIO_W-1:0] gpio_out,
  input  logic [GPIO_W-1:0] gpio_in
`ifdef RVFI
  ,
  output logic        rvfi_valid,
  output logic [63:0] rvfi_order,
  output logic [31:0] rvfi_insn,
  output logic        rvfi_trap,
  output logic [31:0] rvfi_pc_rdata,
  output logic [31:0] rvfi_pc_wdata,
  output logic [4:0]  rvfi_rd_addr,
  output logic [31:0] rvfi_rd_wdata,
  output logic [31:0] rvfi_mem_addr,
  output logic [3:0]  rvfi_mem_rmask,
  output logic [3:0]  rvfi_mem_wmask,
  output logic [31:0] rvfi_mem_rdata,
  output logic [31:0] rvfi_mem_wdata,
  output logic        rvfi_intr,
  output logic [31:0] rvfi_ext_mcause,
  output logic [31:0] rvfi_ext_mip
`endif
);
  localparam int MEM_AW   = $clog2(MEM_WORDS);
  localparam int N_SLAVES = 4, ADDR_W = 20, SLAVE_AW = 12;

  // ---------------------------------------------------------------- reset
  logic [1:0] rst_sync;
  logic       rst_n_s;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_sync <= 2'b00;
    else        rst_sync <= {rst_sync[0], 1'b1};
  end
  assign rst_n_s = rst_sync[1];

  // ---------------------------------------------------------------- core
  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_valid, dmem_ready, dmem_we;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;
  logic        irq_soft, irq_timer, irq_ext;

  rv32i_core #(.RESET_PC(32'h8000_0000)) u_core (
    .clk(clk), .rst_n(rst_n_s),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_valid(dmem_valid), .dmem_ready(dmem_ready), .dmem_addr(dmem_addr),
    .dmem_we(dmem_we), .dmem_be(dmem_be), .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
`ifdef RVFI
    .rvfi_valid(rvfi_valid), .rvfi_order(rvfi_order), .rvfi_insn(rvfi_insn),
    .rvfi_trap(rvfi_trap), .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata),
    .rvfi_rd_addr(rvfi_rd_addr), .rvfi_rd_wdata(rvfi_rd_wdata),
    .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask),
    .rvfi_mem_wmask(rvfi_mem_wmask), .rvfi_mem_rdata(rvfi_mem_rdata),
    .rvfi_mem_wdata(rvfi_mem_wdata),
    .rvfi_intr(rvfi_intr), .rvfi_ext_mcause(rvfi_ext_mcause), .rvfi_ext_mip(rvfi_ext_mip),
`endif
    .irq_soft(irq_soft), .irq_timer(irq_timer), .irq_ext(irq_ext)
  );

  // ---------------------------------------------------------------- data-port decode
  logic sel_mem, sel_apb, sel_none;
  assign sel_mem  = (dmem_addr[31:28] == 4'h8);
  assign sel_apb  = (dmem_addr[31:28] == 4'h4);
  assign sel_none = !sel_mem && !sel_apb;

  logic        mem_req, mem_ready, apb_req, apb_ready;
  logic [31:0] mem_rdata, apb_rdata;
  assign mem_req = dmem_valid && sel_mem;
  assign apb_req = dmem_valid && sel_apb;

  // which source answered the last completed access; rdata must hold until the next one
  logic last_apb, last_none;
  always_ff @(posedge clk or negedge rst_n_s) begin
    if (!rst_n_s) begin
      last_apb  <= 1'b0;
      last_none <= 1'b0;
    end else if (dmem_valid && dmem_ready) begin
      last_apb  <= sel_apb;
      last_none <= sel_none;
    end
  end

  // the RAM takes one wait state (synchronous-read SRAM timing, see soc_mem.sv);
  // an unmapped access completes immediately
  assign dmem_ready = sel_apb ? apb_ready : (sel_mem ? mem_ready : 1'b1);
  assign dmem_rdata = last_none ? 32'h0 : (last_apb ? apb_rdata : mem_rdata);

  // ---------------------------------------------------------------- memory
  soc_mem #(.WORDS(MEM_WORDS), .USE_SRAM(USE_SRAM), .MEM_INIT(MEM_INIT)) u_mem (
    .clk(clk), .rst_n(rst_n_s),
    .r_addr(imem_addr[MEM_AW+1:2]), .r_data(imem_rdata),
    .rw_en(mem_req), .rw_we(dmem_we), .rw_be(dmem_be),
    .rw_addr(dmem_addr[MEM_AW+1:2]), .rw_wdata(dmem_wdata),
    .rw_ready(mem_ready), .rw_rdata(mem_rdata)
  );

  // ---------------------------------------------------------------- APB
  logic                  psel, penable, pwrite, pready, pslverr;
  logic [ADDR_W-1:0]     paddr;
  logic [31:0]           pwdata, prdata;
  logic [N_SLAVES-1:0]   s_psel, s_pready, s_pslverr;
  logic                  s_penable, s_pwrite;
  logic [SLAVE_AW-1:0]   s_paddr;
  logic [31:0]           s_pwdata;
  logic [N_SLAVES*32-1:0] s_prdata;

  apb_master #(.ADDR_W(ADDR_W)) u_apb_m (
    .clk(clk), .rst_n(rst_n_s),
    .req(apb_req), .we(dmem_we), .addr(dmem_addr), .wdata(dmem_wdata),
    .ready(apb_ready), .rdata(apb_rdata),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr)
  );

  apb_fabric #(.N_SLAVES(N_SLAVES), .ADDR_W(ADDR_W), .SLAVE_AW(SLAVE_AW)) u_fab (
    .clk(clk), .rst_n(rst_n_s),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .s_psel(s_psel), .s_penable(s_penable), .s_pwrite(s_pwrite),
    .s_paddr(s_paddr), .s_pwdata(s_pwdata),
    .s_prdata(s_prdata), .s_pready(s_pready), .s_pslverr(s_pslverr)
  );

  logic uart_irq;
  apb_uart #(.SLAVE_AW(SLAVE_AW), .DIV_RESET(UART_DIV)) u_uart (
    .clk(clk), .rst_n(rst_n_s),
    .psel(s_psel[0]), .penable(s_penable), .pwrite(s_pwrite), .paddr(s_paddr),
    .pwdata(s_pwdata), .prdata(s_prdata[0*32 +: 32]), .pready(s_pready[0]),
    .pslverr(s_pslverr[0]),
    .tx_o(uart_tx), .rx_i(uart_rx), .irq(uart_irq)
  );

  apb_mm_accel #(.N(N), .DW(DW), .SPLIT_MUL(SPLIT_MUL), .SLAVE_AW(SLAVE_AW)) u_accel (
    .clk(clk), .rst_n(rst_n_s),
    .psel(s_psel[1]), .penable(s_penable), .pwrite(s_pwrite), .paddr(s_paddr),
    .pwdata(s_pwdata), .prdata(s_prdata[1*32 +: 32]), .pready(s_pready[1]),
    .pslverr(s_pslverr[1])
  );

  apb_timer #(.SLAVE_AW(SLAVE_AW)) u_timer (
    .clk(clk), .rst_n(rst_n_s),
    .psel(s_psel[2]), .penable(s_penable), .pwrite(s_pwrite), .paddr(s_paddr),
    .pwdata(s_pwdata), .prdata(s_prdata[2*32 +: 32]), .pready(s_pready[2]),
    .pslverr(s_pslverr[2]),
    .irq_timer(irq_timer), .irq_soft(irq_soft)
  );

  apb_gpio #(.SLAVE_AW(SLAVE_AW), .W(GPIO_W)) u_gpio (
    .clk(clk), .rst_n(rst_n_s),
    .psel(s_psel[3]), .penable(s_penable), .pwrite(s_pwrite), .paddr(s_paddr),
    .pwdata(s_pwdata), .prdata(s_prdata[3*32 +: 32]), .pready(s_pready[3]),
    .pslverr(s_pslverr[3]),
    .gpio_out(gpio_out), .gpio_in(gpio_in)
  );

  assign irq_ext = uart_irq;

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, imem_addr[31:MEM_AW+2], imem_addr[1:0],
                   dmem_addr[27:MEM_AW+2], dmem_addr[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
