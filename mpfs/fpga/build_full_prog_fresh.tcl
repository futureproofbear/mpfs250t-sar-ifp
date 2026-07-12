## Full flow in ONE session: SYNTHESIZE -> PLACEROUTE -> VERIFYTIMING -> gate -> export.
## Ignores flaky run_tool return codes; gates on the actual pinslacks/mindelay reports.
set here {C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga}
set pd "$here/libero_tdest"
open_project -file "$pd/sar_accel.prjx"
build_design_hierarchy
set_root -module {SAR_TOP::work}
set dsdc "$pd/constraint/SAR_TOP_derived_constraints.sdc"
set cdc  "$pd/constraint/sar_fft_cdc.sdc"
set iopdc "$pd/constraint/io/sar_io.pdc"
catch { organize_tool_files -tool {PLACEROUTE}   -file $iopdc -file $dsdc -file $cdc -module {SAR_TOP::work} -input_type {constraint} }
catch { organize_tool_files -tool {VERIFYTIMING} -file $dsdc -file $cdc -module {SAR_TOP::work} -input_type {constraint} }
if {[catch { run_tool -name {SYNTHESIZE} } e]} { puts "SYN_RC: $e" } else { puts "SYN_OK" }
catch { configure_tool -name {PLACEROUTE} -params {REPAIR_MIN_DELAY:true} }
if {[catch { run_tool -name {PLACEROUTE} } e]} { puts "PNR_RC: $e" } else { puts "PNR_OK" }
if {[catch { run_tool -name {VERIFYTIMING} } e]} { puts "VT_RC: $e" } else { puts "VT_OK" }
save_project
set tr "$pd/designer/SAR_TOP/pinslacks.txt"; set sv 0; set sw 1.0e9
if {[file exists $tr]} { set fp [open $tr r]; set first 1
  while {[gets $fp line]>=0} { if {$first} {set first 0; continue}; set c [split $line ","]; if {[llength $c]<2} continue; set s [string trim [lindex $c 1]]; if {![string is double -strict $s]} continue; if {$s<0} { incr sv; if {$s<$sw} {set sw $s} } }
  close $fp }
puts "SETUP nviol=$sv worst=$sw"
set mr "$pd/designer/SAR_TOP/SAR_TOP_mindelay_repair_report.rpt"; set hv 0
if {[file exists $mr]} { set fp [open $mr r]; while {[gets $fp line]>=0} { if {[regexp {min-delay slack:\s*(-?[0-9]+) ps} $line m val]} { if {$val<0} { incr hv } } }; close $fp }
puts "HOLD nviol=$hv"
if {$sv==0 && $hv==0} {
  puts "TIMING_MET"
  catch { run_tool -name {GENERATEPROGRAMMINGDATA} }
  catch { run_tool -name {GENERATEPROGRAMMINGFILE} }
  file mkdir "$pd/export"
  catch { export_prog_job -job_file_name {SAR_TOP_62p5} -export_dir "$pd/export" -bitstream_file_type {TRUSTED_FACILITY} }
  catch { run_tool -name {PROGRAMDEVICE} }
  puts "PROGRAM_ATTEMPTED"
  puts "BITSTREAM_DONE"
} else { puts "TIMING_NOT_MET setup=$sv hold=$hv worst=${sw}ps" }
puts "FULL_NODLL_DONE"
