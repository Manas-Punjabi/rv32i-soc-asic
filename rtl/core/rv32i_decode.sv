// rv32i_decode.sv — combinational instruction decoder for RV32I + Zicsr.
//
// Produces register indices, the immediate, ALU operand selects and the
// per-class control bits. Anything not in the base ISA (or the machine-mode
// subset this core supports) sets `illegal`; the pipeline turns that into
// an illegal-instruction trap in EX rather than executing garbage.
module rv32i_decode (
  input  logic [31:0] instr,
  output logic [4:0]  rs1,
  output logic [4:0]  rs2,
  output logic [4:0]  rd,
  output logic        rs1_used,      // hazard detection only looks at used sources
  output logic        rs2_used,
  output logic [31:0] imm,
  output logic [3:0]  alu_op,        // {sub_or_sra, funct3}; 0000 = ADD
  output logic [1:0]  alu_a_sel,     // 0 rs1, 1 pc, 2 zero
  output logic        alu_b_sel,     // 0 rs2, 1 imm
  output logic [1:0]  wb_sel,        // 0 alu, 1 load, 2 pc+4, 3 csr
  output logic        rd_we,
  output logic        is_branch,
  output logic        is_jal,
  output logic        is_jalr,
  output logic        is_load,
  output logic        is_store,
  output logic [2:0]  funct3,        // branch condition / load-store width / csr op
  output logic        is_csr,
  output logic        csr_use_imm,   // csrrwi/csrrsi/csrrci: operand is the zimm in rs1
  output logic        is_ecall,
  output logic        is_ebreak,
  output logic        is_mret,
  output logic        illegal
);
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_IMM    = 7'b0010011;
  localparam logic [6:0] OP_REG    = 7'b0110011;
  localparam logic [6:0] OP_FENCE  = 7'b0001111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;

  logic [6:0] opcode, funct7;
  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];
  assign rs1    = instr[19:15];
  assign rs2    = instr[24:20];
  assign rd     = instr[11:7];

  // immediates, sign-extended
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  assign imm_i = {{20{instr[31]}}, instr[31:20]};
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
  assign imm_u = {instr[31:12], 12'h0};
  assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

  logic f7_zero, f7_alt;
  assign f7_zero = (funct7 == 7'b0000000);
  assign f7_alt  = (funct7 == 7'b0100000);

  always_comb begin
    rs1_used    = 1'b0;
    rs2_used    = 1'b0;
    imm         = imm_i;
    alu_op      = 4'b0000;
    alu_a_sel   = 2'd0;
    alu_b_sel   = 1'b1;
    wb_sel      = 2'd0;
    rd_we       = 1'b0;
    is_branch   = 1'b0;
    is_jal      = 1'b0;
    is_jalr     = 1'b0;
    is_load     = 1'b0;
    is_store    = 1'b0;
    is_csr      = 1'b0;
    csr_use_imm = 1'b0;
    is_ecall    = 1'b0;
    is_ebreak   = 1'b0;
    is_mret     = 1'b0;
    illegal     = (instr[1:0] != 2'b11);       // no compressed instructions

    case (opcode)
      OP_LUI: begin
        imm = imm_u; alu_a_sel = 2'd2; rd_we = 1'b1;
      end
      OP_AUIPC: begin
        imm = imm_u; alu_a_sel = 2'd1; rd_we = 1'b1;
      end
      OP_JAL: begin
        imm = imm_j; alu_a_sel = 2'd1; is_jal = 1'b1; wb_sel = 2'd2; rd_we = 1'b1;
      end
      OP_JALR: begin
        rs1_used = 1'b1; is_jalr = 1'b1; wb_sel = 2'd2; rd_we = 1'b1;
        illegal  = illegal || (funct3 != 3'b000);
      end
      OP_BRANCH: begin
        imm = imm_b; alu_a_sel = 2'd1; rs1_used = 1'b1; rs2_used = 1'b1; is_branch = 1'b1;
        illegal = illegal || (funct3 == 3'b010) || (funct3 == 3'b011);
      end
      OP_LOAD: begin
        rs1_used = 1'b1; is_load = 1'b1; wb_sel = 2'd1; rd_we = 1'b1;
        illegal  = illegal || (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
      end
      OP_STORE: begin
        imm = imm_s; rs1_used = 1'b1; rs2_used = 1'b1; is_store = 1'b1;
        illegal = illegal || (funct3[2] == 1'b1) || (funct3 == 3'b011);
      end
      OP_IMM: begin
        rs1_used = 1'b1; rd_we = 1'b1;
        alu_op   = {f7_alt && (funct3 == 3'b101), funct3};
        case (funct3)
          3'b001:  illegal = illegal || !f7_zero;                 // slli
          3'b101:  illegal = illegal || !(f7_zero || f7_alt);     // srli / srai
          default: ;
        endcase
      end
      OP_REG: begin
        rs1_used = 1'b1; rs2_used = 1'b1; alu_b_sel = 1'b0; rd_we = 1'b1;
        alu_op   = {f7_alt, funct3};
        illegal  = illegal || !(f7_zero || (f7_alt && (funct3 == 3'b000 || funct3 == 3'b101)));
      end
      OP_FENCE: begin
        // fence and fence.i are no-ops: one hart, in-order, no caches
        illegal = illegal || (funct3[2:1] != 2'b00);
      end
      OP_SYSTEM: begin
        case (funct3)
          3'b000: begin
            // ecall / ebreak / mret / wfi (wfi is a nop here)
            if (instr[31:7] == 25'h0)                 is_ecall  = 1'b1;
            else if (instr[31:7] == 25'h2000)         is_ebreak = 1'b1;   // imm = 1
            else if (instr[31:20] == 12'h302 && instr[19:7] == 13'h0) is_mret = 1'b1;
            else if (instr[31:20] == 12'h105 && instr[19:7] == 13'h0) ;    // wfi
            else illegal = 1'b1;
          end
          3'b100: illegal = 1'b1;
          default: begin
            // csr address = imm_i[11:0]; the zimm of the *i forms is the rs1 field
            is_csr = 1'b1; wb_sel = 2'd3; rd_we = 1'b1;
            csr_use_imm = funct3[2];
            rs1_used    = !funct3[2];
          end
        endcase
      end
      default: illegal = 1'b1;
    endcase

    // x0 is never a destination
    if (rd == 5'd0) rd_we = 1'b0;
  end
endmodule
