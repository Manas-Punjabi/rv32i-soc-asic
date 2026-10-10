# sta_violation_census.tcl — what exactly is failing, and how much of it.
#
# report_checks with a small -group_path_count shows only the worst few paths,
# which is enough to see a number but not enough to say what the failure *is*.
# This lists every violating endpoint in end-point format so setup checks and
# recovery/removal checks can be counted separately.
#
# Same environment as sta_post_route.tcl.
set top [expr {[info exists ::env(TOP)] ? $::env(TOP) : "soc_top"}]
foreach lib $::env(LIB_FILES) { read_liberty $lib }
read_verilog $::env(NETLIST)
link_design  $top
read_sdc     $::env(SDC)
if {[info exists ::env(SPEF)] && [file exists $::env(SPEF)]} { read_spef $::env(SPEF) }

puts "==== violating endpoints, max (setup + recovery) ===="
report_checks -path_delay max -slack_max 0 -group_path_count 20000 -format end -digits 3
puts "==== violating endpoints, min (hold + removal) ===="
report_checks -path_delay min -slack_max 0 -group_path_count 20000 -format end -digits 3
exit
