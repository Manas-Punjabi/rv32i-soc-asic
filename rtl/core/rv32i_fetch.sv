// rv32i_fetch.sv — decoupled instruction front-end for a synchronous-read memory.
//
// WHY THIS MODULE EXISTS
//
// A synchronous-read SRAM latches the address on a rising edge and drives the
// data out from the *falling* edge of the following cycle, holding it only until
// the next rising edge. Two consequences fix the design:
//
//  1. The data for an address issued in cycle N is usable in cycle N+2, not N+1.
//     The read is its own pipeline stage.
//  2. The output cannot be held by deasserting chip-select: the OpenRAM model
//     drives dout to X on every rising edge regardless of csb, and the liberty
//     has no cross-cycle hold arc. Each beat must be captured in the cycle it is
//     valid, or it is gone.
//
// So the front-end cannot simply freeze when the back-end stalls: a read already
// in flight will land and must be stored. This module issues reads, tracks the
// two in flight, and buffers landed instructions in a small queue so that
//
//   - straight-line code sustains one instruction per cycle,
//   - a back-end stall never loses an instruction,
//   - a redirect costs two bubbles: the refill latency of the memory.
//
// instr/instr_pc are held until ID consumes them (id_ready), so ID needs no
// register of its own: an unconsumed landing beat is pushed into the queue and
// re-presented from its head.
//
// Queue depth 3 is the smallest that covers a stall of any length: at most two
// beats can land after a stall begins (the two reads in flight), and the credit
// rule below never issues a read whose beat could not be stored.
module rv32i_fetch #(
  parameter logic [31:0] RESET_PC = 32'h8000_0000
)(
  input  logic        clk,
  input  logic        rst_n,
  // instruction memory: address out, data valid two cycles later
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  // redirect from EX (branch, jump, trap, mret); takes effect immediately
  input  logic        redirect,
  input  logic [31:0] redirect_pc,
  // to ID
  output logic        instr_valid,
  output logic [31:0] instr,
  output logic [31:0] instr_pc,
  input  logic        id_ready        // ID consumes instr this cycle
);
  localparam int DEPTH = 3;

  logic [31:0] pc_issue;
  logic        issue;

  // in-flight tracking: a read issued in cycle N lands in cycle N+2, so s2 is
  // the beat whose data is on imem_rdata right now
  logic        s1_v, s2_v;
  logic [31:0] s1_pc, s2_pc;

  // queue of landed instructions
  logic [31:0] q_instr [0:DEPTH-1];
  logic [31:0] q_pc    [0:DEPTH-1];
  logic [1:0]  q_count, q_head, q_tail;
  logic [2:0]  occupancy;

  logic land, take_from_q, push, pop;

  assign land        = s2_v;
  assign take_from_q = (q_count != 2'd0);

  // ID sees the queue head if there is one, otherwise the landing beat
  assign instr_valid = take_from_q | land;
  assign instr       = take_from_q ? q_instr[q_head] : imem_rdata;
  assign instr_pc    = take_from_q ? q_pc[q_head]    : s2_pc;

  assign pop  = take_from_q && id_ready;
  assign push = land && !(id_ready && !take_from_q);

  // never issue a read whose beat could not be stored
  assign occupancy = {1'b0, q_count} + {2'b0, s1_v} + {2'b0, s2_v};
  assign issue     = redirect || (occupancy < 3'd3);

  // on a redirect the new target must go out this cycle, not the stale pc_issue
  assign imem_addr = redirect ? redirect_pc : pc_issue;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc_issue <= RESET_PC;
      s1_v     <= 1'b0;
      s2_v     <= 1'b0;
    end else if (redirect) begin
      // both reads in flight are on the wrong path; drop them. The read issued
      // this cycle is the redirect target, so it becomes the new s1.
      pc_issue <= redirect_pc + 32'd4;
      s1_v     <= 1'b1;
      s2_v     <= 1'b0;
    end else begin
      if (issue) pc_issue <= pc_issue + 32'd4;
      s1_v <= issue;
      s2_v <= s1_v;
    end
  end

  always_ff @(posedge clk) begin
    if (redirect)    s1_pc <= redirect_pc;
    else if (issue)  s1_pc <= pc_issue;
    s2_pc <= s1_pc;
  end

  // the asynchronous reset and the synchronous flush are kept in separate
  // branches: `if (!rst_n || redirect)` mixes a non-reset signal into the reset
  // condition, which Yosys rejects with "Multiple edge sensitive events found
  // for this signal" even though both simulators accept it
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_count <= 2'd0;
      q_head  <= 2'd0;
      q_tail  <= 2'd0;
    end else if (redirect) begin
      q_count <= 2'd0;
      q_head  <= 2'd0;
      q_tail  <= 2'd0;
    end else begin
      if (push && !pop)      q_count <= q_count + 2'd1;
      else if (pop && !push) q_count <= q_count - 2'd1;
      if (push) q_tail <= (q_tail == 2'(DEPTH-1)) ? 2'd0 : q_tail + 2'd1;
      if (pop)  q_head <= (q_head == 2'(DEPTH-1)) ? 2'd0 : q_head + 2'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (push) begin
      q_instr[q_tail] <= imem_rdata;
      q_pc[q_tail]    <= s2_pc;
    end
  end
endmodule
