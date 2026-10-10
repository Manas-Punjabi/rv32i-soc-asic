#!/usr/bin/env bash
# clock_gate.sh — insert integrated clock gating and report what it changed.
#
#   bash scripts/clock_gate.sh [MEM_WORDS]      default 2
#
# Yosys `clockgate -liberty` finds sets of flops sharing a clock and an enable
# and replaces the enable with an ICG (sky130_fd_sc_hd__dlclkp_*, a latch-based
# positive-edge gate) driving enable-less flops. Runs inside the ORFS container
# because the pass needs Yosys >= 0.40; the local Yosys is 0.33.
#
# MEM_WORDS matters: with flop-based RAM the memory dominates the flop count and
# the gating gain is mostly the memory's, which will not exist once the SRAM
# macro replaces it in the physical build. The default of 2 words therefore reports the
# gain on the SoC *logic*, which is the number that carries forward.
#
# This reports cells and flops only. A power delta cannot be measured here:
# switching power needs post-route parasitics and activity, so that number comes
# from two full flow runs under one flow setup (docs/implementation.md).
#
#   --reuse   re-report from the existing build/fe/cg_*.stat without resynthesizing
set -u
cd "$(dirname "$0")/.."
REUSE=0
[[ ${1:-} == "--reuse" ]] && { REUSE=1; shift; }
MEM_WORDS=${1:-2}
mkdir -p build/fe

LIB=/OpenROAD-flow-scripts/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
# Glob, not a hand-written list: a hand-written list silently goes stale when a
# file is added, and this script then stops running.
RTL=$(ls rtl/*/*.sv rtl/*.sv | tr '\n' ' ')

run_yosys() { # $1 = "gate" or "nogate", writes build/fe/cg_$1.log
  local mode=$1 cg=""
  [[ $mode == gate ]] && cg="clockgate -liberty $LIB;"
  bash scripts/orfs.sh "yosys -p '
      read_verilog -sv -DSYNTHESIS $RTL;
      chparam -set MEM_WORDS $MEM_WORDS soc_top;
      synth -top soc_top -flatten;
      $cg
      dfflibmap -liberty $LIB;
      abc -liberty $LIB;
      opt_clean;
      tee -o /work/build/fe/cg_$mode.stat stat -liberty $LIB;
      write_verilog /work/build/fe/cg_$mode.v' " > "build/fe/cg_$mode.log" 2>&1
}

echo "clock gating, MEM_WORDS=$MEM_WORDS"
if [[ $REUSE -eq 0 ]]; then
  for m in nogate gate; do
    printf "  %-7s ... " "$m"
    if run_yosys "$m"; then echo "done"; else echo "FAILED"; tail -5 "build/fe/cg_$m.log"; exit 1; fi
  done
else
  echo "  (--reuse: reporting from the existing stat files)"
fi

summary() { # $1 = stat file.
  # Yosys 0.68 `stat -liberty` prints a table:  <count> <area> <name>
  # with a "cells" total line and per-cell-type lines under it.
  local cells icg dff area
  cells=$(awk '$3=="cells" {print $1; exit}' "$1")
  area=$(grep "Chip area for module" "$1" | tail -1 | awk '{print $NF}')
  icg=$(awk '$3 ~ /dlclkp/ {s+=$1} END {print s+0}' "$1")
  # every sequential cell in this library: df*, edf*, sdf* (scan), dl* latches
  dff=$(awk '$3 ~ /sky130_fd_sc_hd__(e?d|s?d)f[a-z]*_[0-9]+$/ {s+=$1} END {print s+0}' "$1")
  echo "$cells $dff $icg $area"
}

enflops() { awk '$3 ~ /edf/ {s+=$1} END {print s+0}' "$1"; }

read -r c0 d0 g0 a0 <<< "$(summary build/fe/cg_nogate.stat)"
read -r c1 d1 g1 a1 <<< "$(summary build/fe/cg_gate.stat)"
e0=$(enflops build/fe/cg_nogate.stat); e1=$(enflops build/fe/cg_gate.stat)
printf "\n  %-24s %14s %14s\n" "" "no gating" "gated"
printf "  %-24s %14s %14s\n" "total cells"        "$c0" "$c1"
printf "  %-24s %14s %14s\n" "sequential cells"   "$d0" "$d1"
printf "  %-24s %14s %14s\n" "enable flops (edf*)" "$e0" "$e1"
printf "  %-24s %14s %14s\n" "ICGs (dlclkp)"      "$g0" "$g1"
printf "  %-24s %14s %14s\n" "cell area (um2)"    "$a0" "$a1"
echo
echo "  Power delta is NOT measured here: switching power needs post-route"
echo "  parasitics and activity. It is measured post-route (docs/implementation.md)."
