set here [file normalize [file dirname [info script]]]
set pd "$here/libero_sar"
open_project "$pd/sar_accel.prjx"
project_settings -abort_flow_on_sdc_errors 0
catch {project_settings -abort_flow_on_pdc_errors 0}
set_root -module {SAR_TOP::work}
# generate the top-level derived SDC (CCC/MSS generated clocks at full hierarchy)
if {[catch {derive_constraints_sdc} e]} { puts "derive: $e" } else { puts "derive: OK" }
set dsdc [lindex [glob -nocomplain "$pd/constraint/*derived*.sdc" "$pd/constraint/*.sdc"] 0]
puts "derived SDC = $dsdc"
puts "clocks in derived SDC = [exec grep -c -i create_clock $dsdc]"
# associate derived constraints (+ io pin map) with the flow
catch {organize_tool_files -tool {PLACEROUTE} -file $dsdc \
       -file "$pd/constraint/io/sar_io.pdc" -module {SAR_TOP::work} -input_type {constraint}}
catch {organize_tool_files -tool {VERIFYTIMING} -file $dsdc -module {SAR_TOP::work} -input_type {constraint}}
# re-run timing-driven P&R + a real timing check
if {[catch {run_tool -name {PLACEROUTE}} e]} { puts "PNR_ERR: $e" } else { puts "PNR_OK" }
if {[catch {run_tool -name {VERIFYTIMING}} e]} { puts "VT_ERR: $e" } else { puts "VT_OK" }
save_project
puts "RECONSTRAIN_DONE"
