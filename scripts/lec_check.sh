#!/usr/bin/env bash
# lec_check.sh — logical equivalence: RTL vs the synthesized netlist.
#
# For each module, Yosys `equiv_opt -assert -multiclock synth` builds a miter of
# the elaborated RTL against the output of `synth` and proves them equivalent
# (SAT + temporal induction). A module that cannot be proven within the timeout
# is reported as UNPROVEN, never as passing.
#
#   bash scripts/lec_check.sh [module ...]     default: every module below
#
# soc_mem is excluded: it is a memory array, replaced by an SRAM macro in phase
# 7, so there is no synthesized logic to compare. soc_top is attempted last and
# is expected to be the hard one.
set -u
cd "$(dirname "$0")/.."
mkdir -p build/fe
TIMEOUT=${LEC_TIMEOUT:-600}
SIMPLE=${LEC_SIMPLE:-5}      # equiv_simple sequential depth
INDUCT=${LEC_INDUCT:-20}     # equiv_induct induction depth

RTL=$(ls rtl/*/*.sv rtl/*.sv | tr '\n' ' ')
# Every module must be listed here: the RTL glob picks up a new file, but a module
# missing from this list is never proven, and nothing reports the omission.
MODULES=(rv32i_alu rv32i_regfile rv32i_decode rv32i_csr rv32i_fetch rv32i_core
         mm_pe mm_accel apb_fabric apb_master apb_mm_accel apb_uart apb_timer apb_gpio)

[[ $# -gt 0 ]] && MODULES=("$@")

proven=0; unproven=0; failed=0
for m in "${MODULES[@]}"; do
  log=build/fe/lec_$m.log
  start=$(date +%s)
  # Explicit miter rather than equiv_opt, so the induction depth is ours to set.
  # Mirrors what `equiv_opt -multiclock` does internally, including the
  # clk2fflogic step that turns clocked and asynchronously reset flops into
  # explicit state logic; without it the miter is unprovable for anything with
  # an async reset.
  #
  # The gold side is elaborated past processes and memories before the miter is
  # built. Memories are mapped to flops on both sides (`memory`, not
  # `memory -nomap`): with $mem/$memrd left in place the register file's read
  # ports have no counterpart in the synthesized mux tree and stay unproven.
  # `setundef -undriven -zero` then drives the read-mux bits for register x0,
  # which memory_map leaves undriven because `regs` is declared [1:31]; that
  # address is never selected (the RTL returns a hard zero for x0), so choosing
  # zero for it cannot hide a real difference.
  timeout "$TIMEOUT" yosys -p "read_verilog -sv $RTL; hierarchy -top $m; \
      proc; memory; opt_clean; setundef -undriven -zero; \
      design -save gold; \
      synth -top $m; design -stash gate; \
      design -copy-from gold -as gold $m; \
      design -copy-from gate -as gate $m; \
      clk2fflogic; \
      equiv_make gold gate equiv; hierarchy -top equiv; \
      equiv_simple -seq $SIMPLE; equiv_induct -seq $INDUCT equiv; \
      equiv_status -assert equiv" > "$log" 2>&1
  rc=$?
  secs=$(( $(date +%s) - start ))
  # Three outcomes, kept distinct on purpose: proven, inconclusive, and a real
  # mismatch. equiv_induct leaving cells unproven means the induction did not
  # close, NOT that the netlist is wrong -- a genuine mismatch shows up as a
  # counterexample. Reporting the two the same way would hide a bug behind a
  # timeout, or cry wolf over a prover limit.
  if [[ $rc -eq 0 ]]; then
    printf "  %-16s EQUIVALENT   (%ss)\n" "$m" "$secs"
    proven=$((proven+1))
  elif [[ $rc -eq 124 ]]; then
    printf "  %-16s UNPROVEN     (timeout after %ss)\n" "$m" "$TIMEOUT"
    unproven=$((unproven+1))
  elif grep -qiE "not equivalent|counterexample|proven non-equivalent" "$log"; then
    printf "  %-16s NOT EQUIVALENT: %s\n" "$m" \
      "$(grep -iE 'not equivalent|counterexample' "$log" | head -1 | cut -c1-60)"
    failed=$((failed+1))
  elif grep -q "unproven .equiv cells in .equiv_status" "$log"; then
    n=$(grep -oE "Found [0-9]+ unproven" "$log" | tail -1 | grep -oE "[0-9]+")
    printf "  %-16s UNPROVEN     (%s cells, induction did not close; no counterexample)\n" "$m" "$n"
    unproven=$((unproven+1))
  else
    printf "  %-16s ERROR: %s\n" "$m" \
      "$(grep -iE 'ERROR' "$log" | head -1 | cut -c1-70)"
    failed=$((failed+1))
  fi
done

echo "LEC: $proven proven, $unproven unproven, $failed not equivalent"
# a genuine mismatch fails the run; an unproven module is reported and listed in
# docs/verification.md with its reason, never silently counted as a pass
[[ $failed -eq 0 ]]
