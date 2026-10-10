// rv32i_csr.sv — machine-mode CSR file for a single-hart, M-only RV32I core.
//
// Implemented: mstatus (MIE/MPIE; MPP reads 11), misa, mie, mip, mtvec (direct
// mode only), mscratch, mepc, mcause, mtval, mcycle/h, minstret/h,
// mcountinhibit, the read-only cycle/instret aliases and the id registers.
// Every other address raises an illegal-instruction trap, as does a write to a
// read-only CSR. No S/U mode, so medeleg/mideleg/satp/pmp* do not exist.
//
// CSR instructions execute in EX: the read value goes to rd, the write lands at
// the end of the same cycle. Traps are raised from EX as well, and nothing older
// than EX can trap, so a CSR write never has to be undone.
module rv32i_csr #(
  parameter logic [31:0] HART_ID = 32'h0
)(
  input  logic        clk,
  input  logic        rst_n,
  // CSR instruction in EX
  input  logic        csr_en,          // valid CSR instruction, no older trap pending
  input  logic [11:0] csr_addr,
  input  logic [1:0]  csr_op,          // funct3[1:0]: 01 rw, 10 rs, 11 rc
  input  logic [31:0] csr_wdata,       // rs1 value or zimm
  input  logic        csr_no_write,    // rs/rc with a zero source: read only
  output logic [31:0] csr_rdata,
  output logic        csr_illegal,     // combinational: unknown address or RO write
  // traps
  input  logic        trap_en,         // take an exception or interrupt this cycle
  input  logic [31:0] trap_cause,      // mcause value (bit 31 = interrupt)
  input  logic [31:0] trap_pc,         // -> mepc
  input  logic [31:0] trap_val,        // -> mtval
  input  logic        mret_en,
  output logic [31:0] mtvec_q,
  output logic [31:0] mepc_q,
  // interrupts
  input  logic        irq_soft,
  input  logic        irq_timer,
  input  logic        irq_ext,
  output logic        irq_pending,     // mstatus.MIE && (mie & mip) != 0
  output logic [31:0] irq_cause,       // highest-priority pending interrupt
  // counters
  input  logic        retire           // one instruction retired this cycle
);
  // addresses
  localparam logic [11:0] A_MSTATUS       = 12'h300;
  localparam logic [11:0] A_MISA          = 12'h301;
  localparam logic [11:0] A_MIE           = 12'h304;
  localparam logic [11:0] A_MTVEC         = 12'h305;
  localparam logic [11:0] A_MSTATUSH      = 12'h310;
  localparam logic [11:0] A_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] A_MSCRATCH      = 12'h340;
  localparam logic [11:0] A_MEPC          = 12'h341;
  localparam logic [11:0] A_MCAUSE        = 12'h342;
  localparam logic [11:0] A_MTVAL         = 12'h343;
  localparam logic [11:0] A_MIP           = 12'h344;
  localparam logic [11:0] A_MCYCLE        = 12'hB00;
  localparam logic [11:0] A_MINSTRET      = 12'hB02;
  localparam logic [11:0] A_MCYCLEH       = 12'hB80;
  localparam logic [11:0] A_MINSTRETH     = 12'hB82;
  localparam logic [11:0] A_CYCLE         = 12'hC00;
  localparam logic [11:0] A_INSTRET       = 12'hC02;
  localparam logic [11:0] A_CYCLEH        = 12'hC80;
  localparam logic [11:0] A_INSTRETH      = 12'hC82;
  localparam logic [11:0] A_MVENDORID     = 12'hF11;
  localparam logic [11:0] A_MARCHID       = 12'hF12;
  localparam logic [11:0] A_MIMPID        = 12'hF13;
  localparam logic [11:0] A_MHARTID       = 12'hF14;

  // misa: RV32 (MXL=1), I only
  localparam logic [31:0] MISA = 32'h4000_0100;

  // state
  logic        mstatus_mie, mstatus_mpie;
  logic        mie_msie, mie_mtie, mie_meie;
  logic [31:2] mtvec_base;
  logic [31:0] mscratch;
  logic [31:2] mepc;
  logic [31:0] mcause, mtval;
  logic [63:0] mcycle, minstret;
  logic        inhibit_cy, inhibit_ir;

  assign mtvec_q = {mtvec_base, 2'b00};
  assign mepc_q  = {mepc, 2'b00};

  // IALIGN=32: mepc[1:0] are always zero, so the low bits of trap_pc are dropped
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, trap_pc[1:0]};
  /* verilator lint_on UNUSEDSIGNAL */

  // ---------------------------------------------------------------- read
  logic [31:0] mip_val, mie_val, mstatus_val;
  assign mip_val     = {20'h0, irq_ext, 3'h0, irq_timer, 3'h0, irq_soft, 3'h0};
  assign mie_val     = {20'h0, mie_meie, 3'h0, mie_mtie, 3'h0, mie_msie, 3'h0};
  assign mstatus_val = {19'h0, 2'b11, 3'h0, mstatus_mpie, 3'h0, mstatus_mie, 3'h0};

  logic known, read_only;
  always_comb begin
    known     = 1'b1;
    csr_rdata = 32'h0;
    case (csr_addr)
      A_MSTATUS:       csr_rdata = mstatus_val;
      A_MISA:          csr_rdata = MISA;
      A_MIE:           csr_rdata = mie_val;
      A_MTVEC:         csr_rdata = mtvec_q;
      A_MSTATUSH:      csr_rdata = 32'h0;
      A_MCOUNTINHIBIT: csr_rdata = {29'h0, inhibit_ir, 1'b0, inhibit_cy};
      A_MSCRATCH:      csr_rdata = mscratch;
      A_MEPC:          csr_rdata = mepc_q;
      A_MCAUSE:        csr_rdata = mcause;
      A_MTVAL:         csr_rdata = mtval;
      A_MIP:           csr_rdata = mip_val;
      A_MCYCLE,   A_CYCLE:    csr_rdata = mcycle[31:0];
      A_MCYCLEH,  A_CYCLEH:   csr_rdata = mcycle[63:32];
      A_MINSTRET, A_INSTRET:  csr_rdata = minstret[31:0];
      A_MINSTRETH, A_INSTRETH: csr_rdata = minstret[63:32];
      A_MVENDORID, A_MARCHID, A_MIMPID: csr_rdata = 32'h0;
      A_MHARTID:       csr_rdata = HART_ID;
      default:         known = 1'b0;
    endcase
  end

  // csr[11:10] == 2'b11 marks a read-only CSR in the address space
  assign read_only   = (csr_addr[11:10] == 2'b11);
  assign csr_illegal = csr_en && (!known || (read_only && !csr_no_write));

  // ---------------------------------------------------------------- write
  logic [31:0] wval;
  logic        we;
  always_comb begin
    case (csr_op)
      2'b10:   wval = csr_rdata |  csr_wdata;   // set
      2'b11:   wval = csr_rdata & ~csr_wdata;   // clear
      default: wval = csr_wdata;                // write
    endcase
  end
  // a trap (including an interrupt arriving on this instruction) cancels the write
  assign we = csr_en && !csr_no_write && !csr_illegal && !trap_en;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      mie_msie     <= 1'b0;
      mie_mtie     <= 1'b0;
      mie_meie     <= 1'b0;
      mtvec_base   <= '0;
      mscratch     <= '0;
      mepc         <= '0;
      mcause       <= '0;
      mtval        <= '0;
      inhibit_cy   <= 1'b0;
      inhibit_ir   <= 1'b0;
    end else begin
      if (trap_en) begin
        // trap wins over a CSR write from the same instruction: the trapping
        // instruction does not execute
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
        mepc         <= trap_pc[31:2];
        mcause       <= trap_cause;
        mtval        <= trap_val;
      end else if (mret_en) begin
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
      end else if (we) begin
        case (csr_addr)
          A_MSTATUS: begin
            mstatus_mie  <= wval[3];
            mstatus_mpie <= wval[7];
          end
          A_MIE: begin
            mie_msie <= wval[3];
            mie_mtie <= wval[7];
            mie_meie <= wval[11];
          end
          A_MTVEC:         mtvec_base <= wval[31:2];
          A_MCOUNTINHIBIT: begin inhibit_cy <= wval[0]; inhibit_ir <= wval[2]; end
          A_MSCRATCH:      mscratch   <= wval;
          A_MEPC:          mepc       <= wval[31:2];
          A_MCAUSE:        mcause     <= wval;
          A_MTVAL:         mtval      <= wval;
          default: ;   // misa, mip, mstatush, id registers: writes ignored (WARL)
        endcase
      end
    end
  end

  // counters: 64-bit, software-writable, halted by mcountinhibit
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mcycle   <= '0;
      minstret <= '0;
    end else begin
      if (we && csr_addr == A_MCYCLE)         mcycle[31:0]    <= wval;
      else if (we && csr_addr == A_MCYCLEH)   mcycle[63:32]   <= wval;
      else if (!inhibit_cy)                   mcycle          <= mcycle + 64'd1;
      if (we && csr_addr == A_MINSTRET)       minstret[31:0]  <= wval;
      else if (we && csr_addr == A_MINSTRETH) minstret[63:32] <= wval;
      else if (retire && !inhibit_ir)         minstret        <= minstret + 64'd1;
    end
  end

  // ---------------------------------------------------------------- interrupts
  // priority per the privileged spec: external > software > timer
  logic p_ext, p_soft, p_timer;
  assign p_ext   = irq_ext   && mie_meie;
  assign p_soft  = irq_soft  && mie_msie;
  assign p_timer = irq_timer && mie_mtie;
  assign irq_pending = mstatus_mie && (p_ext || p_soft || p_timer);
  assign irq_cause   = p_ext  ? 32'h8000_000B :
                       p_soft ? 32'h8000_0003 : 32'h8000_0007;
endmodule
