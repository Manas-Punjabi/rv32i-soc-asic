#!/usr/bin/env bash
# dft_physical.sh — build a routed variant WITH scan chains, and its matched
# control without them, to measure what routing the chains actually costs.
#
#   bash scripts/dft_physical.sh scan    [--flow]
#   bash scripts/dft_physical.sh noscan  [--flow]
#
# Without --flow it stops after writing the netlist, which is the cheap way to
# check the synthesis and stitching steps before spending ~40 minutes on place
# and route.
#
# WHY THIS IS NOT COMPARED AGAINST THE base VARIANT
#
# scripts/dft_scan.sh already measures insertion and coverage (25 chains, 100 %
# of 4,899 flops, +7.3 % cell area) but stops at the netlist, so no published
# PPA number here includes scan. Closing that needs a routed variant.
#
# ORFS has no DFT variables, so the scan netlist has to be produced outside the
# flow and injected. The injection point is results/<...>/1_2_yosys.v: ORFS's
# own chain is 1_2_yosys.v -> 1_synth.odb -> floorplan -> ... -> final, so
# substituting that file substitutes exactly the artifact Yosys would have
# written.
#
# That means synthesis here is NOT ORFS's synthesis: no DONT_USE_CELLS, and
# Yosys's generic abc recipe rather than the platform's. Absolute numbers from
# these variants therefore must not be quoted beside base or the sweep -- that
# would mix two flow setups, which this project's rule 8 forbids. What is valid
# is the *delta* between the two variants this script builds, because both come
# through this identical path with scan as the only difference. Report them as
# their own pair.
#
# Memory is the real configuration (MEM_WORDS=1024, USE_SRAM=1, two OpenRAM
# macros), unlike dft_scan.sh's logic-only MEM_WORDS=2. The macro is black-boxed
# from its liberty, exactly as ORFS does it via ADDITIONAL_LIBS; a macro's
# contents are not scannable either way.
set -u
cd "$(dirname "$0")/.."
MODE=${1:-scan}
RUN_FLOW=0
for a in "$@"; do [[ $a == --flow ]] && RUN_FLOW=1; done
case $MODE in scan|noscan) ;; *) echo "mode must be scan or noscan"; exit 1;; esac

MAX_LEN=${MAX_LEN:-200}
MEM_WORDS=1024
CLOCK_PERIOD=${CLOCK_PERIOD:-15.0}
VARIANT=dft_$MODE

# The floorplan is looser than base's (CORE_UTILIZATION 35, PLACE_DENSITY 0.60).
# Measured reason: this script's plain `synth -flatten` + generic abc produces
# 90,234 placed cells against base's ~70k, so at base's settings global routing
# fails on congestion (GRT-0116, total congestion 90, met4 62) -- and on the
# scan variant OpenROAD then hits a secondary bug writing the congestion
# markers (ODB-0269, corrupted filename). Both variants use the same relaxed
# numbers, so the scan-vs-noscan delta stays valid; neither is comparable to
# base, which this script's header already states.
CORE_UTIL=${CORE_UTIL:-28}
PLACE_DENS=${PLACE_DENS:-0.50}
mkdir -p build/fe

P=/OpenROAD-flow-scripts/flow/platforms/sky130hd
LIB=$P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
SRAM_REF=/pdk/sky130A/libs.ref/sky130_sram_macros
MACRO=sky130_sram_2kbyte_1rw1r_32x512_8
SRAM_LIB=$SRAM_REF/lib/${MACRO}_TT_1p8V_25C.lib
SRAM_LEF=$SRAM_REF/lef/$MACRO.lef

RTL="rtl/core/rv32i_decode.sv rtl/core/rv32i_alu.sv rtl/core/rv32i_regfile.sv \
rtl/core/rv32i_csr.sv rtl/core/rv32i_core.sv rtl/core/rv32i_fetch.sv \
rtl/accel/mm_pe.sv rtl/accel/mm_accel.sv \
rtl/bus/apb_fabric.sv rtl/bus/apb_master.sv rtl/periph/apb_mm_accel.sv \
rtl/periph/apb_uart.sv rtl/periph/apb_timer.sv rtl/periph/apb_gpio.sv \
rtl/mem/soc_mem.sv rtl/soc_top.sv"

PRE_V=build/fe/dftphys_${MODE}_pre.v
OUT_V=build/fe/dftphys_${MODE}.v
PRE_STAT=build/fe/dftphys_${MODE}_pre.stat
POST_STAT=build/fe/dftphys_${MODE}_post.stat
SYNTH_LOG=build/fe/dftphys_${MODE}_synth.log
INS_LOG=build/fe/dftphys_${MODE}_insert.log
TCL=build/fe/dftphys_${MODE}.tcl

# Clock gating runs in both modes so it is not a variable between them. It is
# also required for scan coverage: sky130_fd_sc_hd has no scan+enable flop, so
# without gating the enable flops drop out of the chains (38 % coverage).
SWAP=""
[[ $MODE == scan ]] && SWAP="techmap -map /work/scripts/scan_swap.v; tee -o /work/$POST_STAT stat -liberty $LIB;"

echo "dft_physical: mode=$MODE MEM_WORDS=$MEM_WORDS USE_SRAM=1 period=$CLOCK_PERIOD"
echo "  1/3 synthesis (macro black-boxed from its liberty)"
bash scripts/orfs.sh "yosys -p '
    read_liberty -lib $SRAM_LIB;
    read_verilog -sv -DSYNTHESIS $RTL;
    chparam -set MEM_WORDS $MEM_WORDS -set USE_SRAM 1 soc_top;
    synth -top soc_top -flatten;
    clockgate -liberty $LIB;
    dfflibmap -liberty $LIB;
    abc -liberty $LIB;
    opt_clean;
    hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO;
    tee -o /work/$PRE_STAT stat -liberty $LIB;
    $SWAP
    write_verilog -noattr /work/$PRE_V' " > "$SYNTH_LOG" 2>&1 \
  || { tail -20 "$SYNTH_LOG"; exit 1; }
printf "      macro instances kept: %s\n" "$(grep -c "$MACRO " "$PRE_V")"

if [[ $MODE == scan ]]; then
  echo "  2/3 stitching scan chains with OpenROAD DFT"
  cat > "$TCL" <<TCLEOF
read_lef $P/lef/sky130_fd_sc_hd.tlef
read_lef $P/lef/sky130_fd_sc_hd_merged.lef
read_lef $SRAM_LEF
read_liberty $LIB
read_liberty $SRAM_LIB
read_verilog /work/$PRE_V
link_design soc_top
create_clock -name core_clock -period $CLOCK_PERIOD [get_ports clk]
set_dft_config -max_length $MAX_LEN -clock_mixing clock_mix
report_dft_config
report_dft_plan
execute_dft_plan
write_verilog /work/$OUT_V
TCLEOF
  bash scripts/orfs.sh "openroad -no_init -exit /work/$TCL" > "$INS_LOG" 2>&1 \
    || { tail -25 "$INS_LOG"; exit 1; }
  chains=$(grep -c "^Scan chain" "$INS_LOG")
  scanned=$(grep -oE "sky130_fd_sc_hd__sdf[a-z]+_[0-9]+" "$OUT_V" | wc -l)
  plain=$(grep -oE "sky130_fd_sc_hd__e?df[a-z]+_[0-9]+" "$OUT_V" | wc -l)
  total=$(( scanned + plain ))
  printf "      chains: %s   scan flops: %s / %s" "$chains" "$scanned" "$total"
  [[ $total -gt 0 ]] && printf "  (%d%%)" $(( 100 * scanned / total ))
  echo
  printf "      scan ports: %s\n" "$(grep -cE '^ *(input|output) +scan_' "$OUT_V")"
else
  echo "  2/3 no stitching (control variant)"
  cp "$PRE_V" "$OUT_V"
fi

echo "  3/3 inject as the Yosys handoff for variant $VARIANT"
WORK=${ORFS_WORK:-$HOME/ASIC/rv32i-soc-asic-work}
DEST=$WORK/results/sky130hd/soc_top/$VARIANT
RTLIL=$DEST/1_1_yosys_canonicalize.rtlil
mkdir -p "$DEST"

# ORFS's real chain has a canonicalize step ahead of the netlist:
#
#   VERILOG_FILES -> 1_1_yosys_canonicalize.rtlil -> 1_2_yosys.v
#                 -> 1_synth.odb -> floorplan -> ... -> final
#
# Dropping a netlist at 1_2_yosys.v is only honoured when that .rtlil already
# exists and is OLDER than it. On a fresh variant it does not exist, so make
# builds it; our file is then older than its own dependency and Yosys
# regenerates it, silently discarding the scan netlist. Measured the hard way:
# a 1,408 s run that produced 0 scan flops. So the scaffolding is built once
# first, then the netlist is injected over it and only 1_synth.odb onward
# rebuilds.
inject() {
  cp "$OUT_V" "$DEST/1_2_yosys.v"
  cp flow/constraint.sdc "$DEST/1_2_yosys.sdc"
  touch "$DEST/1_2_yosys.v" "$DEST/1_2_yosys.sdc"
  echo "      injected $DEST/1_2_yosys.v  ($(grep -c . "$OUT_V") lines)"
}

if [[ $RUN_FLOW -eq 0 ]]; then
  inject
  echo
  echo "netlist only. Re-run with --flow to place and route:"
  echo "  bash scripts/dft_physical.sh $MODE --flow"
  exit 0
fi

if [[ ! -f $RTLIL ]]; then
  echo "      no Yosys scaffolding for this variant yet: building it once"
  make asic FLOW_VARIANT=$VARIANT MEM_SRAM=1 MEM_WORDS=$MEM_WORDS \
            CLOCK_PERIOD=$CLOCK_PERIOD CORE_UTILIZATION=$CORE_UTIL \
            PLACE_DENSITY=$PLACE_DENS ORFS_ARGS=synth \
    > build/fe/dftphys_${MODE}_scaffold.log 2>&1 \
    || { tail -15 build/fe/dftphys_${MODE}_scaffold.log; exit 1; }
fi
inject

echo
echo "running the ORFS flow for $VARIANT (floorplan -> final)"
FINAL=$DEST/6_final.v
# Delete any 6_final.v from an earlier attempt first. Without this the checks
# below can read a stale file: the first version of this script reported a
# scan-cell count for a run that had actually failed at global route.
rm -f "$FINAL"
echo "  floorplan: CORE_UTILIZATION=$CORE_UTIL PLACE_DENSITY=$PLACE_DENS (looser than base)"
if ! make asic FLOW_VARIANT=$VARIANT MEM_SRAM=1 MEM_WORDS=$MEM_WORDS \
               CLOCK_PERIOD=$CLOCK_PERIOD CORE_UTILIZATION=$CORE_UTIL \
               PLACE_DENSITY=$PLACE_DENS ORFS_ARGS=final; then
  echo
  echo "the ORFS flow FAILED for $VARIANT. No numbers from this run."
  exit 1
fi

# Flow succeeded -- now confirm the injected netlist carried through to it.
echo
[[ -f $FINAL ]] || { echo "flow reported success but wrote no 6_final.v"; exit 1; }
sdf=$(grep -oE "sky130_fd_sc_hd__sdf[a-z]+_[0-9]+" "$FINAL" | wc -l)
ports=$(grep -cE "^ *(input|output) +scan_" "$FINAL")
printf "routed netlist: %s scan flops, %s scan ports\n" "$sdf" "$ports"
if [[ $MODE == scan && $sdf -eq 0 ]]; then
  echo "WARNING: no scan cells in the routed netlist -- Yosys re-ran over the"
  echo "         injected netlist. This is NOT a scan variant."
  exit 1
fi
