#!/usr/bin/env bash
# run_drc.sh — sign-off DRC on the routed GDS with Magic.
#
#   bash scripts/run_drc.sh [FLOW_VARIANT] [--full]     default: base, abstracted
#
# Runs natively in WSL, not in the container: Magic and Netgen are source builds
# in ~/opt (Ubuntu's magic 8.3.105 segfaults on the PDK techfile).
#
# HOW THE MACROS ARE ABSTRACTED
#
# Magic's drc(full) deck is not valid inside a sky130 SRAM bitcell array. The
# macro's own GDS, straight from the PDK with nothing of this project in it,
# reports 5,579,161 errors under this deck -- the largest single rule being
# "poly overhang of SRAM core transistor", a construct that carries foundry
# waivers the open deck does not model (scripts/drc_probe_macro.sh measures it).
# Checking the macro interior therefore measures the vendor's IP, not ours.
#
# The PDK already ships an abstract of the macro: libs.ref/sky130_sram_macros/
# maglef/<macro>.mag is 17 KB with no subcells and 131 port labels, against
# 2.8 MB and 7,357 subcell instances for the full mag view. This script loads
# that abstract first and then reads the chip GDS with `gds noduplicates true`,
# which makes Magic skip any cell already in memory. The macro instance stays an
# outline plus its top-level pins, so the check covers exactly this project's
# paint -- routing, cell placement, cell-to-cell interactions, and our metal
# against the macro's own pin shapes.
#
# Earlier attempts to strip the macro after loading the full view (`select top
# cell; delete`, `property LEFview true`) do not empty the cell and left a
# meaningless count. Holding a genuine abstract from the start is what works.
#
# Two things this mode does NOT cover, stated rather than buried: geometry
# inside the macro (vendor IP, measured separately), and our metal against
# macro geometry that the abstract omits -- during routing that was covered by
# the macro's LEF obstructions, and route DRC was 0.
#
# --full checks everything hierarchically. Expect ~30 minutes and a result
# dominated by the macros.
set -u
cd "$(dirname "$0")/.."
VARIANT=base
FULL=0
for a in "$@"; do
  case $a in --full) FULL=1;; *) VARIANT=$a;; esac
done
export PDK_ROOT=${PDK_ROOT:-$HOME/.volare}
WORK=${ORFS_WORK:-$HOME/ASIC/rv32i-soc-asic-work}
GDS=$WORK/results/sky130hd/soc_top/$VARIANT/6_final.gds
MAGIC=${MAGIC:-$HOME/opt/magic/bin/magic}
RC=$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc
MACRO=sky130_sram_2kbyte_1rw1r_32x512_8
MAGLEF=$PDK_ROOT/sky130A/libs.ref/sky130_sram_macros/maglef/$MACRO

[[ -f $GDS ]] || { echo "no GDS at $GDS"; exit 1; }
mkdir -p build docs/reports

if [[ $FULL -eq 1 ]]; then
  OUT=docs/reports/magic_drc_${VARIANT}_full.txt
  MODE="hierarchical, including macro internals (vendor IP dominates)"
else
  OUT=docs/reports/magic_drc_${VARIANT}.txt
  MODE="macros abstracted from the PDK's maglef view"
fi

echo "Magic DRC on $GDS"
echo "  mode: $MODE"

# ---------------------------------------------------------------- baseline
# The abstract's own DRC count, so the chip number can be attributed. Runs in
# its own Magic process: a single process would let the continuous checker queue
# cells from the GDS read and mix them into the total.
ABS_ERRORS=n/a
if [[ $FULL -eq 0 ]]; then
  echo "  baseline: the macro abstract on its own ..."
  "$MAGIC" -dnull -noconsole -rcfile "$RC" <<EOF > build/magic_drc_abstract.log 2>&1
load $MAGLEF
select top cell
drc euclidean on
drc style drc(full)
drc check
drc catchup
puts "ABSTRACT_ERRORS: [drc list count total]"
quit -noprompt
EOF
  ABS_ERRORS=$(sed -n 's/^ABSTRACT_ERRORS: //p' build/magic_drc_abstract.log | tail -1)
  ABS_ERRORS=${ABS_ERRORS:-unknown}
  echo "            $ABS_ERRORS errors in the abstract itself"
fi

# ---------------------------------------------------------------- the chip
if [[ $FULL -eq 1 ]]; then
  PRELUDE="gds read $GDS"
else
  # Load the abstract, then read the GDS with noduplicates so the macro cell is
  # not replaced by the full hierarchy the merged GDS carries. `drc off` keeps
  # the continuous checker from queueing the orphaned macro-internal cells that
  # the read leaves in memory; it is re-enabled for the explicit check below.
  PRELUDE="load $MAGLEF
drc off
gds noduplicates true
gds read $GDS
drc on"
fi

echo "  checking soc_top ..."
"$MAGIC" -dnull -noconsole -rcfile "$RC" <<EOF > build/magic_drc_$VARIANT.log 2>&1
$PRELUDE
load soc_top
select top cell
puts "MACRO_CHILDREN: [llength [cellname list children $MACRO]]"
drc euclidean on
drc style drc(full)
drc check
drc catchup
puts "TOP_CELL_ERRORS: [drc list count]"
puts "HIERARCHICAL_ERRORS: [drc list count total]"
# Backticks are escaped because this heredoc is unquoted: bash would otherwise
# run the contents as a command substitution and blank the comment.
# \`drc listall count\` silently returns nothing on this Magic build, which left
# an empty report. \`drc listall why\` is the form that works; it materializes
# every error box, so only the counts are kept here -- writing the boxes
# produced a 348 MB file on the first full-chip run.
set rules {}
set boxtotal 0
foreach {why boxes} [drc listall why] {
  lappend rules [list [llength \$boxes] \$why]
  incr boxtotal [llength \$boxes]
}
puts "ERROR_BOXES: \$boxtotal"
set fh [open $OUT w]
puts \$fh "# Magic sign-off DRC, variant=$VARIANT"
puts \$fh "# drc style drc(full), drc euclidean on"
puts \$fh "# mode: $MODE"
puts \$fh "# macro abstract's own error count: $ABS_ERRORS"
puts \$fh "# subcells under $MACRO: [llength [cellname list children $MACRO]] (0 = abstract held)"
puts \$fh "#"
# The error-box total is the figure the docs quote (the sum of the census below,
# the same unit as the macro-alone measurement). Magic's own counters are kept
# for reference but count something else: on the full-hierarchy run they read
# 4.47 M against 11.15 M boxes, and an earlier version of this header labelled
# them "soc_top's own paint", which they are not in --full mode.
puts \$fh "# error boxes, all rules (sum of the census): \$boxtotal"
puts \$fh "# Magic drc list count, top cell / total:     [drc list count] / [drc list count total]"
puts \$fh ""
puts \$fh "counts by rule (descending):"
if {[llength \$rules] == 0} { puts \$fh "  (none)" }
foreach r [lsort -integer -index 0 -decreasing \$rules] {
  puts \$fh [format "  %10d  %s" [lindex \$r 0] [lindex \$r 1]]
}
close \$fh
quit -noprompt
EOF

echo
grep -E "^MACRO_CHILDREN:|^TOP_CELL_ERRORS:|^HIERARCHICAL_ERRORS:|^ERROR_BOXES:" build/magic_drc_$VARIANT.log
# The GDS carries a layer the sky130A cif input does not map; the shapes are
# skipped. Reported rather than hidden -- it means the read is not 100% clean.
grep -c "Unknown layer/datatype" build/magic_drc_$VARIANT.log \
  | sed 's/^/unmapped-layer messages during the GDS read: /'
# If the macro's interior leaked in, its signature rule appears in the census.
if [[ $FULL -eq 0 ]] && grep -qi "SRAM core" "$OUT" 2>/dev/null; then
  echo "WARNING: an SRAM-core rule appears in the census -- the abstract did not hold."
fi
echo "report: $OUT"
