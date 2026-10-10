#!/usr/bin/env bash
# dft_scan.sh — scan-chain insertion with OpenROAD's DFT, and what it cost.
#
#   bash scripts/dft_scan.sh [--no-clockgate] [MEM_WORDS] [MAX_LENGTH]
#                                              default 2, 200
#
# Yosys maps the design to sky130 cells and swaps each flop for its scan
# equivalent (scripts/scan_swap.v); OpenROAD then stitches them into chains
# (set_dft_config / report_dft_plan / execute_dft_plan) and creates the
# scan_in/scan_out/scan_enable ports.
#
# The swap step is needed because OpenROAD's DFT stitches, it does not replace:
# handed plain df* cells it reports "Cell is not a scan cell. Can't use it for
# scan architect" and produces zero chains.
#
# Clock gating is applied first, and that is not incidental: sky130_fd_sc_hd has
# no scan+enable flop (the sdf* family has no "sedf" member), so every enable
# flop the synthesizer infers would be left out of the chains. `clockgate`
# rewrites those into plain flops behind an ICG, which are scannable. Pass
# --no-clockgate to measure the coverage loss without it.
#
# MEM_WORDS defaults to 2 for the same reason as clock_gate.sh: flop-based RAM
# would dominate the chain count and does not exist in the SRAM-macro build.
# A macro's contents are not scannable either way.
set -u
cd "$(dirname "$0")/.."
CLOCKGATE=1
[[ ${1:-} == "--no-clockgate" ]] && { CLOCKGATE=0; shift; }
MEM_WORDS=${1:-2}
MAX_LEN=${2:-200}
mkdir -p build/fe

P=/OpenROAD-flow-scripts/flow/platforms/sky130hd
LIB=$P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
# Glob, not a hand-written list: a hand-written list silently goes stale when a
# file is added, and this script then stops running.
RTL=$(ls rtl/*/*.sv rtl/*.sv | tr '\n' ' ')

# every artefact carries the mode, so a run of one variant can never overwrite
# the other's numbers and then be compared against them by accident
CG=""
TAG=nocg
if [[ $CLOCKGATE -eq 1 ]]; then CG="clockgate -liberty $LIB;"; TAG=cg; fi

PRE_STAT=build/fe/dft_pre_$TAG.stat
SWAP_STAT=build/fe/dft_swapped_$TAG.stat
PRE_V=build/fe/dft_pre_$TAG.v
POST_V=build/fe/dft_post_$TAG.v
TCL=build/fe/dft_$TAG.tcl
SYNTH_LOG=build/fe/dft_synth_$TAG.log
INS_LOG=build/fe/dft_insert_$TAG.log

echo "DFT scan insertion: MEM_WORDS=$MEM_WORDS, max chain length=$MAX_LEN, clock gating=$CLOCKGATE"

echo "  synthesizing to sky130 cells and swapping in scan flops ..."
bash scripts/orfs.sh "yosys -p '
    read_verilog -sv -DSYNTHESIS $RTL;
    chparam -set MEM_WORDS $MEM_WORDS soc_top;
    synth -top soc_top -flatten;
    $CG
    dfflibmap -liberty $LIB;
    abc -liberty $LIB;
    opt_clean;
    tee -o /work/$PRE_STAT stat -liberty $LIB;
    techmap -map /work/scripts/scan_swap.v;
    tee -o /work/$SWAP_STAT stat -liberty $LIB;
    write_verilog -noattr /work/$PRE_V' " > "$SYNTH_LOG" 2>&1 \
  || { tail -10 "$SYNTH_LOG"; exit 1; }

cat > "$TCL" <<TCLEOF
read_lef $P/lef/sky130_fd_sc_hd.tlef
read_lef $P/lef/sky130_fd_sc_hd_merged.lef
read_liberty $LIB
read_verilog /work/$PRE_V
link_design soc_top
create_clock -name core_clock -period 15.0 [get_ports clk]
set_dft_config -max_length $MAX_LEN -clock_mixing clock_mix
report_dft_config
report_dft_plan
execute_dft_plan
write_verilog /work/$POST_V
TCLEOF

echo "  stitching scan chains ..."
bash scripts/orfs.sh "openroad -no_init -exit /work/$TCL" > "$INS_LOG" 2>&1 \
  || { tail -25 "$INS_LOG"; exit 1; }

chains=$(grep -c "^Scan chain" "$INS_LOG")
echo
echo "  chains: $chains"
grep -E "^Scan chain" "$INS_LOG" | head -3 | sed 's/^/    /'
[[ $chains -gt 3 ]] && echo "    ... ($chains chains total)"
echo "  scan flops in the output netlist:"
grep -oE "sky130_fd_sc_hd__sdf[a-z]+_[0-9]+" "$POST_V" | sort | uniq -c | sed 's/^/    /'
echo "  non-scan flops remaining:"
nsf=$(grep -oE "sky130_fd_sc_hd__e?df[a-z]+_[0-9]+" "$POST_V" | sort | uniq -c)
[[ -n $nsf ]] && echo "$nsf" | sed 's/^/    /' || echo "    none"

# grep -c would count matching lines; these are per-instance counts
scanned=$(grep -oE "sky130_fd_sc_hd__sdf[a-z]+_[0-9]+" "$POST_V" | wc -l)
plain=$(grep -oE "sky130_fd_sc_hd__e?df[a-z]+_[0-9]+" "$POST_V" | wc -l)
total=$(( scanned + plain ))
[[ $total -gt 0 ]] && printf "  scan coverage: %d of %d flops (%d%%)\n" \
  "$scanned" "$total" $(( 100 * scanned / total ))

a0=$(grep "Chip area for module" "$PRE_STAT"  | tail -1 | awk '{print $NF}')
a1=$(grep "Chip area for module" "$SWAP_STAT" | tail -1 | awk '{print $NF}')
printf "  cell area: %s um2 before the scan swap, %s um2 after\n" "$a0" "$a1"
echo "  ports created: $(grep -cE '^ *(input|output) +scan_' "$POST_V") scan_* ports"
