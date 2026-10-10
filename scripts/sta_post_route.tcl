# sta_post_route.tcl — standalone OpenSTA sign-off on the routed design
#
# Usage: sta scripts/sta_post_route.tcl
# Env:   LIB_FILES  space-separated liberty files (standard cells, then macros)
#        NETLIST    routed netlist (ORFS 6_final.v)
#        SPEF       parasitics (ORFS 6_final.spef), optional
#        SDC        constraints (ORFS 6_final.sdc)
#        TOP        top module, default soc_top
#        CORNER     label printed in the header, optional
#
# LIB_FILE (singular) is still accepted for one-liberty designs.
#
# Note for this SoC: the SRAM macro is characterized at TT only, so an ss or ff
# run mixes a TT macro with off-corner standard cells. run_sta.sh says so in the
# header of every report rather than leaving the reader to assume otherwise.
set top [expr {[info exists ::env(TOP)] ? $::env(TOP) : "soc_top"}]

if {[info exists ::env(LIB_FILES)]} {
  foreach lib $::env(LIB_FILES) { read_liberty $lib }
} else {
  read_liberty $::env(LIB_FILE)
}

read_verilog $::env(NETLIST)
link_design  $top
read_sdc     $::env(SDC)
if {[info exists ::env(SPEF)] && [file exists $::env(SPEF)]} {
  read_spef $::env(SPEF)
}

if {[info exists ::env(CORNER)]} { puts "==== corner: $::env(CORNER) ====" }

puts "==== setup ===="
report_checks -path_delay max -group_path_count 5 -format full_clock_expanded \
  -fields {slew cap input_pins} -digits 3
puts "==== hold ===="
report_checks -path_delay min -group_path_count 5 -digits 3
puts "==== summary ===="
report_wns
report_tns
report_worst_slack -max
report_worst_slack -min
report_check_types -max_slew -max_capacitance -max_fanout -violators
exit
