#!/usr/bin/env bash
# run_sta.sh — standalone post-route STA at three corners.
#
#   bash scripts/run_sta.sh [FLOW_VARIANT]      default: base
#
# Runs OpenSTA in the ORFS container on the routed netlist + SPEF and writes
# docs/reports/sta_<variant>_<corner>.txt for each corner.
#
# CORNER COVERAGE, STATED HONESTLY
#
# The standard cells have ss/ff liberties in the PDK, but
# sky130_sram_2kbyte_1rw1r_32x512_8 ships **only** TT_1p8V_25C. So the ss and ff
# runs pair off-corner standard cells with a TT macro: every path that starts or
# ends inside a macro carries a nominal macro delay while the logic around it is
# at the slow or fast corner. Those two runs are therefore *approximate* and are
# labelled as such in the report header and in docs/implementation.md. Only the tt run
# is a true single-corner analysis. Characterizing the macro at ss/ff would need
# Liberate or an equivalent, which this toolchain does not have.
set -u
cd "$(dirname "$0")/.."
VARIANT=${1:-base}
R=/orfs_work/results/sky130hd/soc_top/$VARIANT
SC=/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib
SRAM=/pdk/sky130A/libs.ref/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
mkdir -p docs/reports

# A by-endpoint census of everything that violates. report_checks with a small
# -group_path_count shows only the worst few paths per group, which is enough to
# read a number off but not to say what is failing: on the ss run the top-5 view
# made it look like reset recovery when in fact 790 of the 791 violating
# endpoints are ordinary setup. Only run where there is something to census.
run_census() { # name  sc-liberty
  local name=$1 sclib=$2
  bash scripts/orfs.sh "TOP=soc_top \
      LIB_FILES='$sclib $SRAM' \
      NETLIST=$R/6_final.v SPEF=$R/6_final.spef SDC=$R/6_final.sdc \
      sta -no_splash -exit /work/scripts/sta_violation_census.tcl" \
    > docs/reports/sta_${VARIANT}_${name}_census.txt 2>&1
  printf "    census: %s violating endpoints\n" \
    "$(grep -c VIOLATED docs/reports/sta_${VARIANT}_${name}_census.txt)"
}

run_corner() { # name  sc-liberty  note
  local name=$1 sclib=$2 note=$3
  local out=docs/reports/sta_${VARIANT}_${name}.txt
  echo "  $name ..."
  {
    echo "# post-route STA, variant=$VARIANT, corner=$name"
    echo "# standard cells: $(basename "$sclib")"
    echo "# SRAM macro:     $(basename "$SRAM")"
    echo "# $note"
    echo
  } > "$out"
  bash scripts/orfs.sh "TOP=soc_top CORNER=$name \
      LIB_FILES='$sclib $SRAM' \
      NETLIST=$R/6_final.v SPEF=$R/6_final.spef SDC=$R/6_final.sdc \
      sta -no_splash -exit /work/scripts/sta_post_route.tcl" >> "$out" 2>&1
  printf "    %s\n" "$(grep -E '^(wns|tns|worst slack)' "$out" | tr '\n' ' ')"
}

echo "post-route STA, variant=$VARIANT"
run_corner tt "$SC/sky130_fd_sc_hd__tt_025C_1v80.lib" \
  "true single-corner analysis: cells and macro both at TT."
run_corner ss "$SC/sky130_fd_sc_hd__ss_100C_1v60.lib" \
  "APPROXIMATE: cells at ss_100C_1v60, macro still TT (no ss liberty exists)."
run_census ss "$SC/sky130_fd_sc_hd__ss_100C_1v60.lib"
run_corner ff "$SC/sky130_fd_sc_hd__ff_n40C_1v95.lib" \
  "APPROXIMATE: cells at ff_n40C_1v95, macro still TT (no ff liberty exists)."
run_census ff "$SC/sky130_fd_sc_hd__ff_n40C_1v95.lib"

echo
echo "reports  docs/reports/sta_${VARIANT}_{tt,ss,ff}.txt"
echo "censuses docs/reports/sta_${VARIANT}_{ss,ff}_census.txt"
