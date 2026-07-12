set pd {C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/libero_ffv}
open_project -file "$pd/sar_accel.prjx"
set_root -module {SAR_TOP::work}
puts "@@@ PROGRAMMING SAR_TOP_ffv (fabric+sNVM)"
if {[catch {run_tool -name {PROGRAMDEVICE}} e]} { puts "@@@ PROG_ERR: $e" } else { puts "@@@ PROG_OK" }
puts "@@@ DONE"
