## build_gbxfix_ffv.tcl -- rebuild libero_ffv SAR_TOP with the FIXED gearbox
## (corefft_stream64_adapter.v: capture on datao_valid + almost-full read_outp, so CoreFFT's
## ~4-cycle-late in-flight DATAO beats are no longer dropped under backpressure -- proven in
## QuestaSim by corefft_stream64_lossck_tb.v). The gearbox is a LINKED HDL source (component
## caches only the bif .xml, and the fix did NOT change ports/bifs), so re-synthesis re-reads
## the edited .v. Gated on setup+hold TIMING MET. NO PROGRAMDEVICE (board off / separate step).
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set here "$SAR_FPGA"
set pd "$here/libero_ffv"
open_project -file "$pd/sar_accel.prjx"

## refresh the linked gearbox source so the edited RTL is the one synthesized
catch { create_links -hdl_source "$here/corefft_stream64_adapter.v" }
build_design_hierarchy
set_root -module {SAR_TOP::work}

## constraints: reuse the derived + CDC + IO PDC already organized in the ffv project
set dsdc  "$pd/constraint/SAR_TOP_derived_constraints.sdc"
set cdc   "$pd/constraint/sar_fft_cdc.sdc"
set iopdc "$pd/constraint/io/sar_io.pdc"
if {![file exists $dsdc]} {
  ## first-time constraint derivation (if the ffv project was cleaned)
  catch { import_files -io_pdc "$here/libero_sar/constraint/io/sar_io.pdc" }
  catch { import_files -sdc    "$here/libero_sar/constraint/sar_fft_cdc.sdc" }
  if {[catch { derive_constraints_sdc } e]} { puts "DERIVE_RC: $e" } else { puts "DERIVE_OK" }
  build_design_hierarchy
}
catch { organize_tool_files -tool {PLACEROUTE}   -file $iopdc -file $dsdc -file $cdc -module {SAR_TOP::work} -input_type {constraint} }
catch { organize_tool_files -tool {VERIFYTIMING} -file $dsdc -file $cdc -module {SAR_TOP::work} -input_type {constraint} }

## re-run synthesis so the edited gearbox is picked up (source mtime changed -> re-synthesizes),
## then P&R + timing
if {[catch { run_tool -name {SYNTHESIZE} } e]} { puts "SYN_RC: $e" } else { puts "SYN_OK" }
catch { configure_tool -name {PLACEROUTE} -params {REPAIR_MIN_DELAY:true} }
if {[catch { run_tool -name {PLACEROUTE} } e]} { puts "PNR_RC: $e" } else { puts "PNR_OK" }
if {[catch { run_tool -name {VERIFYTIMING} } e]} { puts "VT_RC: $e" } else { puts "VT_OK" }
save_project

## ---- timing gate: setup (pinslacks) + hold (mindelay repair report) ----
set tr "$pd/designer/SAR_TOP/pinslacks.txt"; set sv 0; set sw 1.0e9
if {[file exists $tr]} { set fp [open $tr r]; set first 1
  while {[gets $fp line]>=0} { if {$first} {set first 0; continue}; set c [split $line ","]; if {[llength $c]<2} continue; set s [string trim [lindex $c 1]]; if {![string is double -strict $s]} continue; if {$s<0} { incr sv; if {$s<$sw} {set sw $s} } }
  close $fp } else { puts "NO_PINSLACKS" }
puts "SETUP nviol=$sv worst=$sw"
set mr "$pd/designer/SAR_TOP/SAR_TOP_mindelay_repair_report.rpt"; set hv 0
if {[file exists $mr]} { set fp [open $mr r]; while {[gets $fp line]>=0} { if {[regexp {min-delay slack:\s*(-?[0-9]+) ps} $line m val]} { if {$val<0} { incr hv } } }; close $fp }
puts "HOLD nviol=$hv"

if {$sv==0 && $hv==0} {
  puts "TIMING_MET"
  catch { run_tool -name {GENERATEPROGRAMMINGDATA} }
  catch { run_tool -name {GENERATEPROGRAMMINGFILE} }
  file mkdir "$pd/export"
  catch { export_prog_job -job_file_name {SAR_TOP_gbxfix} -export_dir "$pd/export" -bitstream_file_type {TRUSTED_FACILITY} }
  puts "BITSTREAM_DONE SAR_TOP_gbxfix"
} else { puts "TIMING_NOT_MET setup=$sv hold=$hv worst=${sw}ps" }
puts "GBXFIX_BUILD_DONE"
