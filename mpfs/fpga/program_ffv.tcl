source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set pd "$SAR_FPGA/libero_ffv"
open_project -file "$pd/sar_accel.prjx"
set_root -module {SAR_TOP::work}
puts "@@@ PROGRAMMING SAR_TOP_ffv (fabric+sNVM)"
if {[catch {run_tool -name {PROGRAMDEVICE}} e]} { puts "@@@ PROG_ERR: $e" } else { puts "@@@ PROG_OK" }
puts "@@@ DONE"
