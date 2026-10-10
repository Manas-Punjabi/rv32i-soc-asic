#!/usr/bin/env bash
# mutate_core.sh — inject known bugs into copies of the core RTL and confirm the
# ISA suites + directed tests catch each one. Runs with +stall so the freeze path
# is covered too, and with -DRVFI so the trace checks are armed. Expected: every
# mutant killed.
#
#   bash scripts/mutate_core.sh            # all mutants
#   bash scripts/mutate_core.sh M3 M7      # a subset
set -u
cd "$(dirname "$0")/.."
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
only="$*"

mut() { # name file sed-expr
  local name=$1 file=$2 expr=$3
  [[ -n $only && " $only " != *" ${name%%_*} "* ]] && return
  rm -rf "$W/rtl"; mkdir -p "$W/rtl"; cp rtl/core/*.sv "$W/rtl/"
  sed -i "$expr" "$W/rtl/$file"
  if cmp -s "rtl/core/$file" "$W/rtl/$file"; then echo "  $name: MUTATION NOT APPLIED"; fail=$((fail+1)); return; fi
  # run the suites against the mutant by pointing the runner at a shadow tree
  rm -rf "$W/tree"; mkdir -p "$W/tree"
  cp -r scripts tb Makefile "$W/tree/"; mkdir -p "$W/tree/rtl"
  cp -r "$W/rtl" "$W/tree/rtl/core"
  cp -r rtl/mem "$W/tree/rtl/mem"      # tb_core instantiates soc_mem
  local r; r=$(cd "$W/tree" && bash scripts/run_isa_tests.sh --stall 2>/dev/null | tail -1)
  if [[ $r == *" 0 failed"* ]]; then echo "  SURVIVED $name  ($r)"; fail=$((fail+1));
  else echo "  killed   $name  ($r)"; pass=$((pass+1)); fi
}

mut M1_no_mem_fwd_rs1    rv32i_core.sv    's/if (mem_rd_we_q \&\& mem_rd_q == ex_rs1_q)/if (1'"'"'b0)/'
mut M2_no_wb_fwd_rs2     rv32i_core.sv    's/else if (wb_rd_we_q_raw \&\& wb_rd_q == ex_rs2_q)/else if (1'"'"'b0)/'
mut M3_no_load_use_stall rv32i_core.sv    's/assign stall_id = id_valid \&\& ex_valid_q \&\&/assign stall_id = 1'"'"'b0 \&\&/'
mut M4_bge_is_blt        rv32i_core.sv    's/3'"'"'b101:  br_cond = !br_lt;/3'"'"'b101:  br_cond = br_lt;/'
mut M5_jalr_keeps_bit0   rv32i_core.sv    's/ex_is_jalr_q ? {alu_y\[31:1\], 1'"'"'b0} : alu_y/alu_y/'
mut M6_no_half_misalign  rv32i_core.sv    's/(ex_funct3_q\[1:0\] == 2'"'"'b01 \&\& alu_y\[0\])/1'"'"'b0/'
mut M7_mret_no_mie       rv32i_csr.sv     's/mstatus_mie  <= mstatus_mpie;/mstatus_mie  <= 1'"'"'b0;/'
mut M8_irq_prio_swap     rv32i_csr.sv     's/p_ext  ? 32'"'"'h8000_000B :/p_soft ? 32'"'"'h8000_0003 : p_ext ? 32'"'"'h8000_000B :/'
mut M9_trap_writes_rd    rv32i_core.sv    's/mem_rd_we_q    <= ex_valid_q \&\& !trap \&\& ex_rd_we_q;/mem_rd_we_q    <= ex_valid_q \&\& ex_rd_we_q;/'
mut M10_no_rf_bypass     rv32i_regfile.sv 's/else if (we \&\& waddr == raddr1)   rdata1 = wdata;/else if (1'"'"'b0) rdata1 = wdata;/'
mut M11_sra_is_srl       rv32i_alu.sv     's/op\[3\] ? \$unsigned(\$signed(a) >>> sh) : a >> sh/a >> sh/'
mut M12_sb_lane0_only    rv32i_core.sv    's/st_be = 4'"'"'b0001 << alu_y\[1:0\];/st_be = 4'"'"'b0001;/'
mut M13_lb_zero_ext      rv32i_core.sv    's/3'"'"'b000:  ld_data = {{24{ld_byte\[7\]}}, ld_byte};/3'"'"'b000:  ld_data = {24'"'"'h0, ld_byte};/'
mut M14_ignore_ready     rv32i_core.sv    's/assign stall_mem  = dmem_valid \&\& !dmem_ready;/assign stall_mem  = 1'"'"'b0;/'
mut M15_wb_advances_in_stall rv32i_core.sv 's/assign wb_en = !stall_mem;/assign wb_en = 1'"'"'b1;/'
mut M16_csr_rc_is_rs     rv32i_csr.sv     's/2'"'"'b11:   wval = csr_rdata \& ~csr_wdata;/2'"'"'b11:   wval = csr_rdata | csr_wdata;/'
mut M17_no_illegal_trap  rv32i_core.sv    's/else if (ex_illegal_q || csr_illegal)/else if (1'"'"'b0)/'
# RVFI trace (the runner compiles with -DRVFI, so the trace checks run on every program)
mut M18_rvfi_pc_next_always_plus4 rv32i_core.sv 's/rv_mem_pc_next_q <= ex_redirect ? redirect_pc : ex_pc_q + 32'"'"'d4;/rv_mem_pc_next_q <= ex_pc_q + 32'"'"'d4;/'
mut M19_rvfi_x0_carries_value    rv32i_core.sv 's/assign rvfi_rd_wdata  = (rv_wb_rd_q != 5'"'"'d0) ? wb_value : 32'"'"'h0;/assign rvfi_rd_wdata  = wb_value;/'
mut M20_rvfi_counts_bubbles      rv32i_core.sv 's/assign rvfi_valid     = rv_wb_valid_q \&\& wb_en;/assign rvfi_valid     = wb_en;/'
# decoupled front-end (rv32i_fetch.sv): the queue, the credit rule and the
# redirect flush are all new state, so each gets a control
mut F1_no_issue_credit   rv32i_fetch.sv  "s/assign issue     = redirect || (occupancy < 3'd3);/assign issue     = 1'b1;/"
# F2: the queue's own redirect branch (reset and flush are separate branches)
mut F2_redirect_keeps_q  rv32i_fetch.sv  "/q_tail  <= 2'd0;/,/end else begin/ s/end else if (redirect) begin/end else if (1'b0) begin/"
mut F3_redirect_keeps_s2 rv32i_fetch.sv  "/redirect_pc + 32/,+2 s/s2_v     <= 1'b0;/s2_v <= s1_v;/"
mut F4_stale_beat_pc     rv32i_fetch.sv  's/assign instr_pc    = take_from_q ? q_pc\[q_head\]    : s2_pc;/assign instr_pc    = take_from_q ? q_pc[q_head]    : s1_pc;/'
mut F5_drop_beat_on_stall rv32i_fetch.sv 's/assign push = land \&\& !(id_ready \&\& !take_from_q);/assign push = 1'"'"'b0;/'
mut F6_redirect_stale_addr rv32i_fetch.sv 's/assign imem_addr = redirect ? redirect_pc : pc_issue;/assign imem_addr = pc_issue;/'
# fence.i (Zifencei) flush: F7 removes the
# flush (the original bug); F8 keeps the flush but drops the replay, so a store still in
# MEM is written on the same edge the refetch reads -- why a plain flush is not enough
mut F7_fencei_no_flush   rv32i_core.sv   "s/assign ex_is_fencei  = ex_valid_q \&\& !trap \&\&/assign ex_is_fencei  = 1'b0 \&\& !trap \&\&/"
mut F8_fencei_no_replay  rv32i_core.sv   "s/assign fencei_replay = ex_is_fencei \&\& mem_is_store_q;/assign fencei_replay = 1'b0;/;s/assign fencei_go     = ex_is_fencei \&\& !mem_is_store_q;/assign fencei_go     = ex_is_fencei;/"

echo "killed $pass / $((pass+fail))"
[[ $fail -eq 0 ]]
