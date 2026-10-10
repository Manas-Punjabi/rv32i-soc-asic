#!/usr/bin/env bash
# drc_probe_macro.sh — is the DRC count coming from the SRAM macro or from us?
#
# The first full-chip run reported 11.1 M errors, which is far too many to be
# routing or placement. This runs the identical sign-off deck on the macro's own
# GDS, straight from the PDK, with nothing of ours in it. Whatever it reports is
# the macro as delivered.
#
# Written as a script rather than a heredoc on the command line because the
# -rcfile path must expand; getting that wrong silently loads technology
# "minimum", where drc(full) does not exist and the answer is a meaningless 0.
set -u
cd "$(dirname "$0")/.."
export PDK_ROOT=${PDK_ROOT:-$HOME/.volare}
MAGIC=${MAGIC:-$HOME/opt/magic/bin/magic}
MACRO=${1:-sky130_sram_2kbyte_1rw1r_32x512_8}
GDS=$PDK_ROOT/sky130A/libs.ref/sky130_sram_macros/gds/$MACRO.gds
mkdir -p build docs/reports

echo "Magic DRC on the macro alone: $MACRO"
"$MAGIC" -dnull -noconsole -rcfile "$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc" <<EOF > build/drc_macro_$MACRO.log 2>&1
gds read $GDS
load $MACRO
select top cell
drc euclidean on
drc style drc(full)
drc check
drc catchup
set fh [open docs/reports/magic_drc_macro_$MACRO.txt w]
puts \$fh "# Magic sign-off DRC on $MACRO as delivered in the PDK"
puts \$fh "# drc style drc(full), drc euclidean on -- nothing of this project is in this layout"
puts \$fh ""
set total 0
set rules {}
foreach {why boxes} [drc listall why] {
  set n [llength \$boxes]
  incr total \$n
  lappend rules [list \$n \$why]
}
puts \$fh "TOTAL: \$total"
puts \$fh ""
foreach r [lsort -integer -index 0 -decreasing \$rules] {
  puts \$fh [format "  %10d  %s" [lindex \$r 0] [lindex \$r 1]]
}
close \$fh
puts "TECH: [tech name]"
puts "MACRO_TOTAL: \$total"
quit -noprompt
EOF

grep -E "^TECH:|^MACRO_TOTAL:" build/drc_macro_$MACRO.log
echo "report: docs/reports/magic_drc_macro_$MACRO.txt"
