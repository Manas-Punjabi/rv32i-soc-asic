#!/usr/bin/env bash
# lec_mmpe_widths.sh — why mm_pe does not prove at DW=32.
#
# mm_pe contains N parallel DW x DW multipliers. Equivalence checking of a
# multiplier by SAT is exponential in the operand width, so a timeout at DW=32
# says nothing about whether the netlist is correct. Sweeping the width shows
# where the method gives out: if the same RTL proves at small DW, the structure
# is right and only the SAT problem size defeats the prover.
set -u
cd "$(dirname "$0")/.."
mkdir -p build/fe
TIMEOUT=${LEC_TIMEOUT:-300}

for dw in 2 4 8 16 32; do
  log=build/fe/lec_mm_pe_dw$dw.log
  start=$(date +%s)
  timeout "$TIMEOUT" yosys -p "read_verilog -sv rtl/accel/mm_pe.sv; \
      chparam -set DW $dw mm_pe; hierarchy -top mm_pe; \
      proc; memory; opt_clean; setundef -undriven -zero; design -save gold; \
      synth -top mm_pe; design -stash gate; \
      design -copy-from gold -as gold mm_pe; design -copy-from gate -as gate mm_pe; \
      clk2fflogic; equiv_make gold gate equiv; hierarchy -top equiv; \
      equiv_simple -seq 5; equiv_induct -seq 20 equiv; equiv_status -assert equiv" \
      > "$log" 2>&1
  rc=$?
  secs=$(( $(date +%s) - start ))
  if [[ $rc -eq 0 ]]; then printf "  mm_pe DW=%-3s EQUIVALENT  (%ss)\n" "$dw" "$secs"
  elif [[ $rc -eq 124 ]]; then printf "  mm_pe DW=%-3s UNPROVEN    (timeout %ss)\n" "$dw" "$TIMEOUT"
  else printf "  mm_pe DW=%-3s UNPROVEN    (%s)\n" "$dw" \
       "$(grep -oE 'Found [0-9]+ unproven' "$log" | tail -1)"; fi
done
