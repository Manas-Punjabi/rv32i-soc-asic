// scan_swap.v — Yosys techmap rules: replace each sky130 flop with its scan
// equivalent, scan inputs tied off.
//
// OpenROAD's DFT stitches scan chains; it does not replace flops ("Cell is not
// a scan cell. Can't use it for scan architect"). Yosys `dfflibmap` picks the
// plain df* cells, so this map runs after it and swaps in the sdf* family with
// SCE = 0 and SCD = 0, which is functionally identical to the plain flop.
// execute_dft_plan then rewires SCE to the scan-enable port and threads
// SCD/Q into chains.
//
// Only the flop types this design actually maps to are listed; a type that
// appears later will simply not be swapped, and OpenROAD will report it as a
// non-scan cell rather than silently leaving it out of the chain.

module sky130_fd_sc_hd__dfxtp_1 (input CLK, input D, output Q);
  sky130_fd_sc_hd__sdfxtp_1 _TECHMAP_REPLACE_ (
    .CLK(CLK), .D(D), .SCD(1'b0), .SCE(1'b0), .Q(Q));
endmodule

module sky130_fd_sc_hd__dfrtp_1 (input CLK, input D, input RESET_B, output Q);
  sky130_fd_sc_hd__sdfrtp_1 _TECHMAP_REPLACE_ (
    .CLK(CLK), .D(D), .RESET_B(RESET_B), .SCD(1'b0), .SCE(1'b0), .Q(Q));
endmodule

module sky130_fd_sc_hd__dfstp_2 (input CLK, input D, input SET_B, output Q);
  sky130_fd_sc_hd__sdfstp_2 _TECHMAP_REPLACE_ (
    .CLK(CLK), .D(D), .SET_B(SET_B), .SCD(1'b0), .SCE(1'b0), .Q(Q));
endmodule
