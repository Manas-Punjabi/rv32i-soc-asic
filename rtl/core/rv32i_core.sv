// rv32i_core.sv — 5-stage in-order RV32I core with machine-mode Zicsr/Zicntr.
//
// Pipeline: IF | ID | EX | MEM | WB
//
//   IF   The instruction memory is a synchronous read port addressed by the
//        *next* PC, so its output register is the IF/ID register. `pc_q` is the
//        PC of the instruction currently in ID.
//   ID   Decode, register read (with WB->ID bypass inside the register file),
//        load-use detection.
//   EX   Forwarding (MEM->EX, WB->EX), ALU, branch/jump resolution, CSR access,
//        exception detection. Everything that redirects the PC happens here, so
//        a taken branch costs one bubble (only ID is flushed) and no instruction
//        older than EX can ever be cancelled.
//   MEM  Data memory request; the pipeline freezes while dmem_ready is low.
//   WB   Load data extraction, register write, instret.
//
// Hazards: EX->EX and MEM->EX forwarding cover every ALU-to-ALU dependency; a
// load followed immediately by a consumer stalls one cycle.
//
// Memory ports (both synchronous, SRAM-style):
//   imem: address out, data back the next cycle, always ready.
//   dmem: request held until dmem_ready; read data valid the cycle after the
//         handshake and must stay stable until the next handshake.
//
// Misaligned loads/stores/jumps trap (the spec permits this). Traps and
// interrupts are machine-mode only; mtvec is direct-mode only.
module rv32i_core #(
  parameter logic [31:0] RESET_PC = 32'h8000_0000,
  parameter logic [31:0] HART_ID  = 32'h0
)(
  input  logic        clk,
  input  logic        rst_n,
  // instruction port
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  // data port
  output logic        dmem_valid,
  input  logic        dmem_ready,
  output logic [31:0] dmem_addr,
  output logic        dmem_we,
  output logic [3:0]  dmem_be,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,
`ifdef RVFI
  // RISC-V Formal Interface retirement trace (simulation only; never synthesized).
  // One record per retired instruction in program order, from WB. An instruction
  // that raises an exception is reported with rvfi_trap = 1, rd_addr = 0, no memory
  // access and pc_wdata = mtvec. An instruction pre-empted by an interrupt is not
  // reported: it did not execute and will be re-fetched after mret.
  // rvfi_mem_addr is the word-aligned address; rmask/wmask give the byte lanes.
  // rvfi_mem_rdata is the raw word from memory, before extraction/sign extension.
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
  // Interrupt side band (RVFI rvfi_intr + rvfi_ext_*, as in Ibex's co-simulation):
  // rvfi_intr marks the first instruction of a handler entered by an interrupt (the
  // pre-empted instruction is not reported, so its pc_wdata does not lead here);
  // rvfi_ext_mcause is that interrupt's mcause and rvfi_ext_mip the pending lines
  // when it was taken. Valid with rvfi_valid && rvfi_intr.
  output logic        rvfi_intr,
  output logic [31:0] rvfi_ext_mcause,
  output logic [31:0] rvfi_ext_mip,
`endif
  // interrupts, level-sensitive
  input  logic        irq_soft,
  input  logic        irq_timer,
  input  logic        irq_ext
);
  // exception causes
  localparam logic [31:0] C_FETCH_MISALIGNED = 32'd0;
  localparam logic [31:0] C_ILLEGAL          = 32'd2;
  localparam logic [31:0] C_BREAKPOINT       = 32'd3;
  localparam logic [31:0] C_LOAD_MISALIGNED  = 32'd4;
  localparam logic [31:0] C_STORE_MISALIGNED = 32'd6;
  localparam logic [31:0] C_ECALL_M          = 32'd11;

  // ================================================================ IF
  // The instruction memory is a synchronous-read SRAM: data for an address
  // issued in cycle N is usable in N+2, and each beat must be captured in the
  // cycle it is valid. rv32i_fetch owns that pipeline and hands ID one
  // instruction at a time with a ready handshake. See rv32i_fetch.sv.
  logic [31:0] pc_q;                // PC of the instruction in ID
  logic        stall_mem, stall_id, ex_redirect;
  logic        fencei_replay, fencei_go;
  logic [31:0] redirect_pc;
  logic [31:0] id_instr;
  logic        id_valid, id_ready;

  assign id_ready = !stall_id && !stall_mem;

  rv32i_fetch #(.RESET_PC(RESET_PC)) u_fetch (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .redirect(ex_redirect), .redirect_pc(redirect_pc),
    .instr_valid(id_valid), .instr(id_instr), .instr_pc(pc_q),
    .id_ready(id_ready)
  );

  // ================================================================ ID

  logic [4:0]  id_rs1, id_rs2, id_rd;
  logic        id_rs1_used, id_rs2_used;
  logic [31:0] id_imm;
  logic [3:0]  id_alu_op;
  logic [1:0]  id_alu_a_sel, id_wb_sel;
  logic        id_alu_b_sel, id_rd_we;
  logic        id_is_branch, id_is_jal, id_is_jalr, id_is_load, id_is_store;
  logic [2:0]  id_funct3;
  logic        id_is_csr, id_csr_use_imm, id_is_ecall, id_is_ebreak, id_is_mret, id_illegal;

  rv32i_decode u_dec (
    .instr(id_instr), .rs1(id_rs1), .rs2(id_rs2), .rd(id_rd),
    .rs1_used(id_rs1_used), .rs2_used(id_rs2_used), .imm(id_imm),
    .alu_op(id_alu_op), .alu_a_sel(id_alu_a_sel), .alu_b_sel(id_alu_b_sel),
    .wb_sel(id_wb_sel), .rd_we(id_rd_we),
    .is_branch(id_is_branch), .is_jal(id_is_jal), .is_jalr(id_is_jalr),
    .is_load(id_is_load), .is_store(id_is_store), .funct3(id_funct3),
    .is_csr(id_is_csr), .csr_use_imm(id_csr_use_imm),
    .is_ecall(id_is_ecall), .is_ebreak(id_is_ebreak), .is_mret(id_is_mret),
    .illegal(id_illegal)
  );

  // register file; written from WB
  logic [31:0] id_rs1_val, id_rs2_val;
  logic        wb_valid_q, wb_rd_we_q, wb_rd_we_q_raw;
  logic [4:0]  wb_rd_q;
  logic [31:0] wb_value;

  rv32i_regfile u_rf (
    .clk(clk), .we(wb_rd_we_q), .waddr(wb_rd_q), .wdata(wb_value),
    .raddr1(id_rs1), .raddr2(id_rs2), .rdata1(id_rs1_val), .rdata2(id_rs2_val)
  );

  // ---- ID/EX register
  logic        ex_valid_q;
  logic [31:0] ex_pc_q, ex_instr_q, ex_rs1_val_q, ex_rs2_val_q, ex_imm_q;
  logic [4:0]  ex_rs1_q, ex_rs2_q, ex_rd_q;
  logic [3:0]  ex_alu_op_q;
  logic [1:0]  ex_alu_a_sel_q, ex_wb_sel_q;
  logic        ex_alu_b_sel_q, ex_rd_we_q;
  logic        ex_is_branch_q, ex_is_jal_q, ex_is_jalr_q, ex_is_load_q, ex_is_store_q;
  logic [2:0]  ex_funct3_q;
  logic        ex_is_csr_q, ex_csr_use_imm_q, ex_is_ecall_q, ex_is_ebreak_q, ex_is_mret_q, ex_illegal_q;

  // load-use: the instruction in EX is a load whose rd is a source of the one in
  // ID. Gated by id_valid: with a decoupled front-end, ID can be empty, and the
  // decoder's outputs are meaningless then.
  assign stall_id = id_valid && ex_valid_q && ex_is_load_q && (ex_rd_q != 5'd0) &&
                    ((id_rs1_used && id_rs1 == ex_rd_q) || (id_rs2_used && id_rs2 == ex_rd_q));

  logic id_bubble;
  assign id_bubble = !id_valid || stall_id || ex_redirect;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ex_valid_q     <= 1'b0;
      ex_rd_we_q     <= 1'b0;
      ex_is_branch_q <= 1'b0; ex_is_jal_q  <= 1'b0; ex_is_jalr_q  <= 1'b0;
      ex_is_load_q   <= 1'b0; ex_is_store_q <= 1'b0; ex_is_csr_q  <= 1'b0;
      ex_is_ecall_q  <= 1'b0; ex_is_ebreak_q <= 1'b0; ex_is_mret_q <= 1'b0;
      ex_illegal_q   <= 1'b0;
    end else if (!stall_mem) begin
      ex_valid_q     <= !id_bubble;
      ex_rd_we_q     <= !id_bubble && id_rd_we;
      ex_is_branch_q <= !id_bubble && id_is_branch;
      ex_is_jal_q    <= !id_bubble && id_is_jal;
      ex_is_jalr_q   <= !id_bubble && id_is_jalr;
      ex_is_load_q   <= !id_bubble && id_is_load;
      ex_is_store_q  <= !id_bubble && id_is_store;
      ex_is_csr_q    <= !id_bubble && id_is_csr;
      ex_is_ecall_q  <= !id_bubble && id_is_ecall;
      ex_is_ebreak_q <= !id_bubble && id_is_ebreak;
      ex_is_mret_q   <= !id_bubble && id_is_mret;
      ex_illegal_q   <= !id_bubble && id_illegal;
    end
  end

  // datapath fields need no reset: a bubble ignores them
  always_ff @(posedge clk) begin
    if (!stall_mem) begin
      ex_pc_q          <= pc_q;
      ex_instr_q       <= id_instr;
      ex_rs1_val_q     <= id_rs1_val;
      ex_rs2_val_q     <= id_rs2_val;
      ex_imm_q         <= id_imm;
      ex_rs1_q         <= id_rs1;
      ex_rs2_q         <= id_rs2;
      ex_rd_q          <= id_rd;
      ex_alu_op_q      <= id_alu_op;
      ex_alu_a_sel_q   <= id_alu_a_sel;
      ex_alu_b_sel_q   <= id_alu_b_sel;
      ex_wb_sel_q      <= id_wb_sel;
      ex_funct3_q      <= id_funct3;
      ex_csr_use_imm_q <= id_csr_use_imm;
    end
  end

  // ================================================================ EX
  // ---- forwarding
  logic        mem_valid_q, mem_rd_we_q;
  logic [4:0]  mem_rd_q;
  logic [31:0] mem_result_q;
  logic [31:0] fwd_rs1, fwd_rs2;

  always_comb begin
    if (mem_rd_we_q && mem_rd_q == ex_rs1_q)          fwd_rs1 = mem_result_q;
    else if (wb_rd_we_q_raw && wb_rd_q == ex_rs1_q)   fwd_rs1 = wb_value;
    else                                              fwd_rs1 = ex_rs1_val_q;
    if (mem_rd_we_q && mem_rd_q == ex_rs2_q)          fwd_rs2 = mem_result_q;
    else if (wb_rd_we_q_raw && wb_rd_q == ex_rs2_q)   fwd_rs2 = wb_value;
    else                                              fwd_rs2 = ex_rs2_val_q;
  end

  // ---- ALU
  logic [31:0] alu_a, alu_b, alu_y;
  always_comb begin
    case (ex_alu_a_sel_q)
      2'd1:    alu_a = ex_pc_q;
      2'd2:    alu_a = 32'h0;
      default: alu_a = fwd_rs1;
    endcase
    alu_b = ex_alu_b_sel_q ? ex_imm_q : fwd_rs2;
  end
  rv32i_alu u_alu (.a(alu_a), .b(alu_b), .op(ex_alu_op_q), .y(alu_y));

  // ---- branches and jumps
  logic br_eq, br_lt, br_ltu, br_cond, jump_taken;
  logic [31:0] jump_target;
  assign br_eq  = (fwd_rs1 == fwd_rs2);
  assign br_lt  = ($signed(fwd_rs1) < $signed(fwd_rs2));
  assign br_ltu = (fwd_rs1 < fwd_rs2);
  always_comb begin
    case (ex_funct3_q)
      3'b000:  br_cond = br_eq;
      3'b001:  br_cond = !br_eq;
      3'b100:  br_cond = br_lt;
      3'b101:  br_cond = !br_lt;
      3'b110:  br_cond = br_ltu;
      default: br_cond = !br_ltu;     // 3'b111 bgeu
    endcase
  end
  // jal/branch: pc + imm from the ALU; jalr: (rs1 + imm) with bit 0 cleared
  assign jump_target = ex_is_jalr_q ? {alu_y[31:1], 1'b0} : alu_y;
  assign jump_taken  = ex_valid_q && (ex_is_jal_q || ex_is_jalr_q || (ex_is_branch_q && br_cond));

  // ---- CSR
  logic [31:0] csr_rdata, csr_operand, mtvec_q, mepc_q, irq_cause;
  logic        csr_illegal, irq_pending, csr_no_write;
  logic        trap, mret_en, retire;
  logic [31:0] trap_cause, trap_val;

  assign csr_operand  = ex_csr_use_imm_q ? {27'h0, ex_rs1_q} : fwd_rs1;   // zimm is the rs1 field
  assign csr_no_write = ex_funct3_q[1] && (ex_rs1_q == 5'd0);   // csrrs/csrrc with x0 or zimm=0

  rv32i_csr #(.HART_ID(HART_ID)) u_csr (
    .clk(clk), .rst_n(rst_n),
    .csr_en(ex_valid_q && ex_is_csr_q && !stall_mem),
    .csr_addr(ex_imm_q[11:0]), .csr_op(ex_funct3_q[1:0]),
    .csr_wdata(csr_operand), .csr_no_write(csr_no_write),
    .csr_rdata(csr_rdata), .csr_illegal(csr_illegal),
    .trap_en(trap), .trap_cause(trap_cause), .trap_pc(ex_pc_q), .trap_val(trap_val),
    .mret_en(mret_en), .mtvec_q(mtvec_q), .mepc_q(mepc_q),
    .irq_soft(irq_soft), .irq_timer(irq_timer), .irq_ext(irq_ext),
    .irq_pending(irq_pending), .irq_cause(irq_cause),
    .retire(retire)
  );

  // ---- exceptions, highest priority first
  logic mem_misaligned;
  assign mem_misaligned = (ex_is_load_q || ex_is_store_q) &&
                          ((ex_funct3_q[1:0] == 2'b01 && alu_y[0]) ||
                           (ex_funct3_q[1:0] == 2'b10 && alu_y[1:0] != 2'b00));
  always_comb begin
    trap       = 1'b0;
    trap_cause = 32'h0;
    trap_val   = 32'h0;
    if (ex_valid_q && !stall_mem) begin
      if (irq_pending)                          begin trap = 1'b1; trap_cause = irq_cause;          end
      else if (ex_illegal_q || csr_illegal)     begin trap = 1'b1; trap_cause = C_ILLEGAL;          trap_val = ex_instr_q;  end
      else if (ex_is_ecall_q)                   begin trap = 1'b1; trap_cause = C_ECALL_M;          end
      else if (ex_is_ebreak_q)                  begin trap = 1'b1; trap_cause = C_BREAKPOINT;       trap_val = ex_pc_q;     end
      else if (jump_taken && jump_target[1:0] != 2'b00)
                                                begin trap = 1'b1; trap_cause = C_FETCH_MISALIGNED; trap_val = jump_target; end
      else if (mem_misaligned)                  begin trap = 1'b1;
                                                      trap_cause = ex_is_load_q ? C_LOAD_MISALIGNED : C_STORE_MISALIGNED;
                                                      trap_val = alu_y; end
    end
  end
  assign mret_en = ex_valid_q && ex_is_mret_q && !stall_mem && !trap;

  // ---- PC redirect (evaluated only when the pipeline is not frozen)
  always_comb begin
    ex_redirect = 1'b0;
    redirect_pc = mtvec_q;
    if (stall_mem)          ex_redirect = 1'b0;
    else if (trap)          begin ex_redirect = 1'b1; redirect_pc = mtvec_q;     end
    else if (mret_en)       begin ex_redirect = 1'b1; redirect_pc = mepc_q;      end
    else if (jump_taken)    begin ex_redirect = 1'b1; redirect_pc = jump_target; end
    // fence.i targets are written word-aligned: a pc in EX always is (no C extension,
    // misaligned jumps trap), but synthesis cannot prove that through the fetch-loop
    // registers, and the plain ex_pc_q kept the pc's constant-zero low bits as 7 flops
    // plus ~9,000 um2 of logic (logic-only synthesis, measured 2026-10-06)
    else if (fencei_replay) begin ex_redirect = 1'b1; redirect_pc = {ex_pc_q[31:2], 2'b00}; end
    else if (fencei_go)     begin ex_redirect = 1'b1;
                                  redirect_pc = {ex_pc_q[31:2] + 30'd1, 2'b00};            end
  end

  // ---- result for non-load instructions, also what MEM forwards
  logic [31:0] ex_result;
  always_comb begin
    case (ex_wb_sel_q)
      2'd2:    ex_result = ex_pc_q + 32'd4;
      2'd3:    ex_result = csr_rdata;
      default: ex_result = alu_y;
    endcase
  end

  // ---- store data lanes and byte enables
  logic [31:0] st_data;
  logic [3:0]  st_be;
  always_comb begin
    case (ex_funct3_q[1:0])
      2'b00: begin st_data = {4{fwd_rs2[7:0]}};  st_be = 4'b0001 << alu_y[1:0];           end
      2'b01: begin st_data = {2{fwd_rs2[15:0]}}; st_be = alu_y[1] ? 4'b1100 : 4'b0011;   end
      default: begin st_data = fwd_rs2;          st_be = 4'b1111;                        end
    endcase
  end

  // ---- EX/MEM register
  logic        mem_is_load_q, mem_is_store_q;

  // fence.i (Zifencei): the front-end may hold instructions fetched before an earlier
  // store reached memory, so fence.i flushes it with a redirect to pc+4. If that store
  // is still in MEM, its write lands on the same edge the refetch would read, so the
  // fence.i is replayed instead: killed like an interrupted instruction, refetched.
  logic ex_is_fencei;
  assign ex_is_fencei  = ex_valid_q && !trap && ex_instr_q[6:0] == 7'b0001111 &&
                         ex_instr_q[14:12] == 3'b001;
  assign fencei_replay = ex_is_fencei && mem_is_store_q;
  assign fencei_go     = ex_is_fencei && !mem_is_store_q;
  logic [31:0] mem_addr_q, mem_wdata_q;
  logic [3:0]  mem_be_q;
  logic [2:0]  mem_funct3_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_valid_q    <= 1'b0;
      mem_rd_we_q    <= 1'b0;
      mem_is_load_q  <= 1'b0;
      mem_is_store_q <= 1'b0;
    end else if (!stall_mem) begin
      mem_valid_q    <= ex_valid_q && !trap && !fencei_replay;
      mem_rd_we_q    <= ex_valid_q && !trap && ex_rd_we_q;
      mem_is_load_q  <= ex_valid_q && !trap && ex_is_load_q;
      mem_is_store_q <= ex_valid_q && !trap && ex_is_store_q;
    end
  end
  always_ff @(posedge clk) begin
    if (!stall_mem) begin
      mem_rd_q     <= ex_rd_q;
      mem_result_q <= ex_result;
      mem_addr_q   <= alu_y;
      mem_wdata_q  <= st_data;
      mem_be_q     <= st_be;
      mem_funct3_q <= ex_funct3_q;
    end
  end

  // ================================================================ MEM
  assign dmem_valid = mem_is_load_q || mem_is_store_q;
  assign dmem_we    = mem_is_store_q;
  assign dmem_addr  = {mem_addr_q[31:2], 2'b00};
  assign dmem_be    = mem_be_q;
  assign dmem_wdata = mem_wdata_q;
  assign stall_mem  = dmem_valid && !dmem_ready;

  // ---- MEM/WB register. Frozen with the rest of the pipeline on a stall: the
  // instruction in EX read its operands before WB's value reached the register
  // file, so WB must keep forwarding until EX can move on. The register write
  // and instret happen once, in the cycle the stall ends.
  logic        wb_is_load_q, wb_en;
  logic [31:0] wb_result_q;
  logic [2:0]  wb_funct3_q;
  logic [1:0]  wb_addr_lo_q;
  assign wb_en = !stall_mem;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_valid_q     <= 1'b0;
      wb_rd_we_q_raw <= 1'b0;
    end else if (wb_en) begin
      wb_valid_q     <= mem_valid_q;
      wb_rd_we_q_raw <= mem_rd_we_q;
    end
  end
  always_ff @(posedge clk) begin
    if (wb_en) begin
      wb_rd_q      <= mem_rd_q;
      wb_result_q  <= mem_result_q;
      wb_is_load_q <= mem_is_load_q;
      wb_funct3_q  <= mem_funct3_q;
      wb_addr_lo_q <= mem_addr_q[1:0];
    end
  end

  // ================================================================ WB
  logic [7:0]  ld_byte;
  logic [15:0] ld_half;
  logic [31:0] ld_data;
  assign ld_byte = dmem_rdata[wb_addr_lo_q*8 +: 8];
  assign ld_half = wb_addr_lo_q[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
  always_comb begin
    case (wb_funct3_q)
      3'b000:  ld_data = {{24{ld_byte[7]}}, ld_byte};    // lb
      3'b001:  ld_data = {{16{ld_half[15]}}, ld_half};   // lh
      3'b100:  ld_data = {24'h0, ld_byte};               // lbu
      3'b101:  ld_data = {16'h0, ld_half};               // lhu
      default: ld_data = dmem_rdata;                     // lw
    endcase
  end
  assign wb_value   = wb_is_load_q ? ld_data : wb_result_q;
  assign wb_rd_we_q = wb_rd_we_q_raw && !stall_mem;     // register file write, once
  assign retire     = wb_valid_q && !stall_mem;

`ifdef RVFI
  // ================================================================ RVFI
  // A shadow of the EX/MEM and MEM/WB registers that also carries instructions
  // which trapped (the real pipeline turns those into bubbles).
  logic        rv_mem_valid_q, rv_mem_trap_q, rv_mem_ld_q, rv_mem_st_q;
  logic [31:0] rv_mem_pc_q, rv_mem_insn_q, rv_mem_pc_next_q;
  logic [4:0]  rv_mem_rd_q;
  logic        rv_wb_valid_q, rv_wb_trap_q, rv_wb_ld_q;
  logic [31:0] rv_wb_pc_q, rv_wb_insn_q, rv_wb_pc_next_q, rv_wb_addr_q, rv_wb_wdata_q;
  logic [4:0]  rv_wb_rd_q;
  logic [3:0]  rv_wb_wmask_q;
  logic        irq_taken;
  assign irq_taken = trap && irq_pending;      // interrupts have top priority in `trap`

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rv_mem_valid_q <= 1'b0;
      rv_wb_valid_q  <= 1'b0;
      rvfi_order     <= '0;
    end else begin
      if (!stall_mem) begin
        rv_mem_valid_q   <= ex_valid_q && !irq_taken && !fencei_replay;
        rv_mem_trap_q    <= trap && !irq_taken;
        rv_mem_pc_q      <= ex_pc_q;
        rv_mem_insn_q    <= ex_instr_q;
        rv_mem_pc_next_q <= ex_redirect ? redirect_pc : ex_pc_q + 32'd4;
        rv_mem_rd_q      <= (ex_rd_we_q && !trap) ? ex_rd_q : 5'd0;
        rv_mem_ld_q      <= ex_is_load_q  && !trap;
        rv_mem_st_q      <= ex_is_store_q && !trap;
      end
      if (wb_en) begin
        rv_wb_valid_q   <= rv_mem_valid_q;
        rv_wb_trap_q    <= rv_mem_trap_q;
        rv_wb_pc_q      <= rv_mem_pc_q;
        rv_wb_insn_q    <= rv_mem_insn_q;
        rv_wb_pc_next_q <= rv_mem_pc_next_q;
        rv_wb_rd_q      <= rv_mem_rd_q;
        rv_wb_ld_q      <= rv_mem_ld_q;
        rv_wb_addr_q    <= (rv_mem_ld_q || rv_mem_st_q) ? {mem_addr_q[31:2], 2'b00} : 32'h0;
        rv_wb_wmask_q   <= rv_mem_st_q ? mem_be_q : 4'h0;
        rv_wb_wdata_q   <= rv_mem_st_q ? mem_wdata_q : 32'h0;
      end
      if (rvfi_valid) rvfi_order <= rvfi_order + 64'd1;
    end
  end

  logic [3:0] rv_rmask;
  always_comb begin
    case (wb_funct3_q[1:0])
      2'b00:   rv_rmask = 4'b0001 << wb_addr_lo_q;
      2'b01:   rv_rmask = wb_addr_lo_q[1] ? 4'b1100 : 4'b0011;
      default: rv_rmask = 4'b1111;
    endcase
  end

  assign rvfi_valid     = rv_wb_valid_q && wb_en;
  assign rvfi_insn      = rv_wb_insn_q;
  assign rvfi_trap      = rv_wb_trap_q;
  assign rvfi_pc_rdata  = rv_wb_pc_q;
  assign rvfi_pc_wdata  = rv_wb_pc_next_q;
  assign rvfi_rd_addr   = rv_wb_rd_q;
  assign rvfi_rd_wdata  = (rv_wb_rd_q != 5'd0) ? wb_value : 32'h0;
  assign rvfi_mem_addr  = rv_wb_addr_q;
  assign rvfi_mem_rmask = rv_wb_ld_q ? rv_rmask : 4'h0;
  assign rvfi_mem_wmask = rv_wb_wmask_q;
  assign rvfi_mem_rdata = rv_wb_ld_q ? dmem_rdata : 32'h0;
  assign rvfi_mem_wdata = rv_wb_wdata_q;

  // ---- interrupt side band
  // Taking an interrupt kills the instruction in EX and flushes ID; the handler's first
  // instruction is the next one to enter EX. Older instructions in MEM/WB still retire
  // first, so the flag rides down the pipeline with that instruction, cause and mip
  // with it (a second interrupt may be taken before the first handler instruction
  // retires).
  logic        rv_intr_next, rv_ex_intr_q, rv_mem_intr_q, rv_wb_intr_q;
  logic [31:0] rv_intr_cause_q, rv_intr_mip_q;
  logic [31:0] rv_ex_cause_q, rv_mem_cause_q, rv_wb_cause_q;
  logic [31:0] rv_ex_mip_q, rv_mem_mip_q, rv_wb_mip_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rv_intr_next  <= 1'b0;
      rv_ex_intr_q  <= 1'b0;
      rv_mem_intr_q <= 1'b0;
      rv_wb_intr_q  <= 1'b0;
    end else begin
      if (!stall_mem) begin
        if (irq_taken) begin
          rv_intr_next    <= 1'b1;
          rv_intr_cause_q <= trap_cause;
          rv_intr_mip_q   <= {20'h0, irq_ext, 3'h0, irq_timer, 3'h0, irq_soft, 3'h0};
        end else if (rv_ex_intr_q && fencei_replay) begin
          rv_intr_next <= 1'b1;          // the flagged instruction is a replayed fence.i:
        end else if (!id_bubble) begin   // it is refetched, so the flag must follow it
          rv_intr_next <= 1'b0;
        end
        rv_ex_intr_q  <= !id_bubble && rv_intr_next;
        rv_ex_cause_q <= rv_intr_cause_q;
        rv_ex_mip_q   <= rv_intr_mip_q;
        rv_mem_intr_q  <= ex_valid_q && !irq_taken && !fencei_replay && rv_ex_intr_q;
        rv_mem_cause_q <= rv_ex_cause_q;
        rv_mem_mip_q   <= rv_ex_mip_q;
      end
      if (wb_en) begin
        rv_wb_intr_q  <= rv_mem_intr_q;
        rv_wb_cause_q <= rv_mem_cause_q;
        rv_wb_mip_q   <= rv_mem_mip_q;
      end
    end
  end
  assign rvfi_intr       = rv_wb_intr_q;
  assign rvfi_ext_mcause = rv_wb_intr_q ? rv_wb_cause_q : 32'h0;
  assign rvfi_ext_mip    = rv_wb_intr_q ? rv_wb_mip_q   : 32'h0;
`endif
endmodule
