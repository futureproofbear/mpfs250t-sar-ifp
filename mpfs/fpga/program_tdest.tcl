## program_fresh.tcl -- (re)program the already-built libero_tdest bitstream, no rebuild.
## Use when the board is back on (FlashPro6/J33) after build_full_prog_fresh.tcl generated the
## programming data. Does NOT rebuild; just runs PROGRAMDEVICE on the fresh project.
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
open_project -file "$SAR_FPGA/libero_tdest/sar_accel.prjx"
catch { refresh_programmer_list }
if {[catch { run_tool -name {PROGRAMDEVICE} } e]} {
    puts ">>> PROGRAMDEVICE FAILED: $e"
} else {
    puts ">>> PROGRAMDEVICE OK"
}
puts ">>> PROGRAM_FRESH_DONE"
