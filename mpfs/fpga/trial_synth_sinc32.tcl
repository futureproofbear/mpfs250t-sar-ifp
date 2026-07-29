# trial_synth_sinc32.tcl -- STANDALONE synthesis of sar_sinc32_gather, to answer one question
# cheaply: does a 32-tap gather fit, and can its adder tree close at 100 MHz on this device?
#
# WHY STANDALONE. The full SAR_TOP build is ~50 minutes and the 100 MHz domain already has only
# 0.255 ns of setup slack, so timing is the likely failure mode for this core. Finding that out in
# minutes -- before writing the integration, the coefficient load path, the 32-bank source fill and
# the re-timed drain logic -- is worth far more than finding it at the end of a P&R.
#
# WHAT THE NUMBERS MEAN, and what they do NOT. A standalone synthesis gives honest RESOURCE counts
# and a synthesis-level timing estimate for this block in isolation. It does NOT include placement,
# routing congestion, or competition with the rest of SAR_TOP for the same region -- all of which
# make real timing WORSE. So treat a comfortable standalone result as necessary, not sufficient;
# treat a failing one as decisive.
#
# Device parameters copied from create_fresh_project_ffv.tcl so this is the same silicon.
#
# Usage:  libero SCRIPT:trial_synth_sinc32.tcl

set here  [file normalize [file dirname [info script]]]
set proj  [file join $here trial_sinc32]

if {[file exists $proj]} { file delete -force $proj }

new_project \
    -location $proj -name {sinc32_trial} -project_description {32-tap sinc gather, trial synth} \
    -hdl {VERILOG} -family {PolarFireSoC} -die {MPFS250T_ES} -package {FCVG484} \
    -speed {STD} -die_voltage {1.05} -part_range {EXT} -ondemand_build_dh {1}

create_links -hdl_source [file join $here sar_sinc32_gather.v]
build_design_hierarchy
set_root -module {sar_sinc32_gather::work}

# 100 MHz, the fabric domain this core would live in.
set sdc [file join $proj trial.sdc]
set fh [open $sdc w]
puts $fh "create_clock -name {clk} -period 10.000 \[get_ports {clk}\]"
close $fh
create_links -sdc $sdc
organize_tool_files -tool {SYNTHESIZE} -file $sdc -module {sar_sinc32_gather::work} -input_type {constraint}

puts "@@@ SYNTHESIZING sar_sinc32_gather (32 taps, 256 phases) at 100 MHz"
if {[catch {run_tool -name {SYNTHESIZE}} e]} {
    puts "@@@ SYNTH_ERR: $e"
} else {
    puts "@@@ SYNTH_OK"
}
puts "@@@ DONE"
