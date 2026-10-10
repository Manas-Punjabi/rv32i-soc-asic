// rvfi_checks.svh — RVFI trace checks shared by tb_core and tb_soc.
//
// The including testbench defines, before the include:
//   `define RVFI_IF   <path to the rvfi_* outputs>   e.g. dut          or dut
//   `define RVFI_CORE <path to the core>             e.g. dut          or dut.u_core
// and has clk / rst_n in scope. Checked every cycle:
//   order is contiguous from 0; x0 never carries a value; the next record's pc_rdata
//   is this record's pc_wdata unless an interrupt intervened (one discontinuity per
//   taken interrupt); a trapped record reports no rd write and no memory access.
logic [63:0] rvfi_expect_order = 0;
logic [31:0] rvfi_prev_pc_next;
bit          rvfi_have_prev = 0;
int          rvfi_errors = 0, rvfi_records = 0, rvfi_irq_pending = 0;

always @(posedge clk) if (rst_n) begin
  if (`RVFI_CORE.trap && `RVFI_CORE.irq_pending) rvfi_irq_pending = rvfi_irq_pending + 1;
  if (`RVFI_IF.rvfi_valid) begin
    rvfi_records++;
    if (`RVFI_IF.rvfi_order != rvfi_expect_order) begin
      rvfi_errors++; $display("  RVFI: order %0d, expected %0d", `RVFI_IF.rvfi_order, rvfi_expect_order);
    end
    if (`RVFI_IF.rvfi_rd_addr == 0 && `RVFI_IF.rvfi_rd_wdata != 0) begin
      rvfi_errors++; $display("  RVFI: rd_wdata=%h with rd_addr=0 at pc %h", `RVFI_IF.rvfi_rd_wdata, `RVFI_IF.rvfi_pc_rdata);
    end
    if (rvfi_have_prev && `RVFI_IF.rvfi_pc_rdata != rvfi_prev_pc_next) begin
      if (rvfi_irq_pending > 0) rvfi_irq_pending = rvfi_irq_pending - 1;
      else begin
        rvfi_errors++; $display("  RVFI: pc %h follows a record whose pc_wdata was %h", `RVFI_IF.rvfi_pc_rdata, rvfi_prev_pc_next);
      end
    end
    if (`RVFI_IF.rvfi_trap && (`RVFI_IF.rvfi_rd_addr != 0 || `RVFI_IF.rvfi_mem_rmask != 0 || `RVFI_IF.rvfi_mem_wmask != 0)) begin
      rvfi_errors++; $display("  RVFI: trapped instruction at %h reports side effects", `RVFI_IF.rvfi_pc_rdata);
    end
    rvfi_expect_order <= `RVFI_IF.rvfi_order + 1;
    rvfi_prev_pc_next <= `RVFI_IF.rvfi_pc_wdata;
    rvfi_have_prev    <= 1;
  end
end
