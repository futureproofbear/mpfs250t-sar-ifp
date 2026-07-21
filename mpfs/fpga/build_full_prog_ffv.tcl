## build_full_prog_ffv.tcl -- P&R the reconstructed libero_ffv (SAR_TOP with the Verilog
## feeder fft_feeder_v). Import constraints + derive the 62.5 MHz clocks, SYNTH -> P&R ->
## VERIFYTIMING -> gate on setup+hold -> export bitstream. NO PROGRAMDEVICE (board off).
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set here "$SAR_FPGA"
set pd "$here/libero_ffv"
open_project -file "$pd/sar_accel.prjx"
build_design_hierarchy
set_root -module {SAR_TOP::work}

## constraints: import the CDC + IO PDC (tracked in mpfs/fpga/constraints) and derive the CCC clocks (62.5/7.8125)
catch { import_files -io_pdc "$here/constraints/sar_io.pdc" }
catch { import_files -sdc    "$here/constraints/sar_fft_cdc.sdc" }
if {[catch { derive_constraints_sdc } e]} { puts "DERIVE_RC: $e" } else { puts "DERIVE_OK" }
build_design_hierarchy

set dsdc  "$pd/constraint/SAR_TOP_derived_constraints.sdc"
set cdc   "$pd/constraint/sar_fft_cdc.sdc"
set iopdc "$pd/constraint/io/sar_io.pdc"
catch { organize_tool_files -tool {PLACEROUTE}   -file $iopdc -file $dsdc -file $cdc -module {SAR_TOP::work} -input_type {constraint} }
catch { organize_tool_files -tool {VERIFYTIMING} -file $dsdc -file $cdc -module {SAR_TOP::work} -input_type {constraint} }

if {[catch { run_tool -name {SYNTHESIZE} } e]} { puts "SYN_RC: $e" } else { puts "SYN_OK" }
catch { configure_tool -name {PLACEROUTE} -params {REPAIR_MIN_DELAY:true} }
if {[catch { run_tool -name {PLACEROUTE} } e]} { puts "PNR_RC: $e" } else { puts "PNR_OK" }
if {[catch { run_tool -name {VERIFYTIMING} } e]} { puts "VT_RC: $e" } else { puts "VT_OK" }
save_project

## timing gate: setup (pinslacks) + hold (multi-corner violation reports)
##
## FIXED 2026-07-22 -- SECOND GATE HOLE. GENERATEPROGRAMMINGDATA silently RE-RUNS place-and-route
## and DELETES the multi-corner timing XMLs. The old flow gated, printed TIMING_MET, and only then
## generated programming data -- so the exported bitstream's layout was covered by NO timing report
## at all. Caught on the 2026-07-22 migration build, where prog-data restarted the placer and
## produced a different (better, as it happened) placement than the one that passed the gate.
## The gate is now a proc, run BEFORE prog-data and AGAIN afterwards if the layout moved. The
## bitstream is exported ONLY if the SECOND evaluation passes, so what ships is what was verified.
proc sar_layout_sig {pd} {
  ## Layout fingerprint. SAR_TOP.loc IS the placement, so if it is untouched across prog-data the
  ## timing analysis still describes the design being exported. Size+mtime is enough to detect a
  ## re-place (the placer rewrites the file); it does not need to be cryptographic.
  set f "$pd/designer/SAR_TOP/SAR_TOP.loc"
  if {![file exists $f]} { return "NOLOC" }
  return "[file size $f]:[file mtime $f]"
}

## Gates must require POSITIVE EVIDENCE, never the absence of a match -- a missing or empty
## artifact otherwise reads as "zero violations" and passes a design that was never checked.
set ok 1
set tr "$pd/designer/SAR_TOP/pinslacks.txt"; set sv 0; set sw 1.0e9; set srows 0
if {[file exists $tr]} { set fp [open $tr r]; set first 1
  while {[gets $fp line]>=0} { if {$first} {set first 0; continue}; set c [split $line ","]; if {[llength $c]<2} continue; set s [string trim [lindex $c 1]]; if {![string is double -strict $s]} continue; incr srows; if {$s<0} { incr sv; if {$s<$sw} {set sw $s} } }
  close $fp } else { puts "NO_PINSLACKS"; set ok 0 }
puts "SETUP nviol=$sv worst=$sw rows=$srows"
if {$srows < 1000} { puts "GATE_FAIL: pinslacks.txt has only $srows parsed slack rows (expected >1000)"; set ok 0 }

## FIXED 2026-07-20: the mindelay REPAIR report only lists paths that were REPAIRED. When a design
## has "Total paths eligible for improvement: 0" the regexp below matches nothing and this reported
## HOLD nviol=0 UNCONDITIONALLY -- it never actually verified hold. Every build before this date
## claimed hold met without checking it. Kept as a secondary signal only; the authoritative hold
## check is the multi-corner violation report immediately after.
set mr "$pd/designer/SAR_TOP/SAR_TOP_mindelay_repair_report.rpt"; set hv 0
if {[file exists $mr]} { set fp [open $mr r]; while {[gets $fp line]>=0} { if {[regexp {min-delay slack:\s*(-?[0-9]+) ps} $line m val]} { if {$val<0} { incr hv } } }; close $fp } else { puts "NO_MINDELAY_RPT"; set ok 0 }
puts "HOLD nviol=$hv (repair-report only -- VIOLRPT below is the real check)"

## Authoritative: SmartTime multi-corner violation reports must EXIST and say "No Path" for BOTH.
foreach {tag vf} [list SETUP "$pd/designer/SAR_TOP/SAR_TOP_max_timing_violations_multi_corner.xml" \
                       HOLD  "$pd/designer/SAR_TOP/SAR_TOP_min_timing_violations_multi_corner.xml"] {
  if {![file exists $vf]} { puts "GATE_FAIL: missing $tag multi-corner violation report"; set ok 0; continue }
  set fp [open $vf r]; set txt [read $fp]; close $fp
  if {[string first "No Path" $txt] >= 0} { puts "VIOLRPT $tag: No Path (clean)" \
  } else { puts "GATE_FAIL: $tag multi-corner violation report LISTS PATHS -> real violations"; set ok 0 }
}

if {!($sv==0 && $hv==0 && $ok)} {
  puts "TIMING_NOT_MET setup=$sv hold=$hv evidence_ok=$ok worst=${sw}ps"
  puts "FFV_BUILD_DONE"
  return
}
puts "TIMING_MET (pre-progdata)"

## Programming data can re-place the design. Fingerprint the layout, generate, compare.
set sig_before [sar_layout_sig $pd]
catch { run_tool -name {GENERATEPROGRAMMINGDATA} }
set sig_after [sar_layout_sig $pd]

if {$sig_before ne $sig_after} {
  puts "LAYOUT_CHANGED_BY_PROGDATA -- re-verifying timing against the layout that will ship"
  if {[catch { run_tool -name {VERIFYTIMING} } e]} { puts "REVT_RC: $e" } else { puts "REVT_OK" }
  ## Re-evaluate ONLY the authoritative multi-corner reports; pinslacks is regenerated by P&R.
  set ok2 1
  foreach {tag vf} [list SETUP "$pd/designer/SAR_TOP/SAR_TOP_max_timing_violations_multi_corner.xml"                          HOLD  "$pd/designer/SAR_TOP/SAR_TOP_min_timing_violations_multi_corner.xml"] {
    if {![file exists $vf]} { puts "GATE_FAIL(recheck): missing $tag multi-corner report"; set ok2 0; continue }
    set fp [open $vf r]; set txt [read $fp]; close $fp
    if {[string first "No Path" $txt] >= 0} { puts "RECHECK $tag: No Path (clean)"     } else { puts "GATE_FAIL(recheck): $tag report LISTS PATHS"; set ok2 0 }
  }
  if {!$ok2} {
    puts "TIMING_NOT_MET_AFTER_PROGDATA -- refusing to export a bitstream whose layout failed"
    puts "FFV_BUILD_DONE"
    return
  }
  puts "TIMING_MET (post-progdata, re-verified)"
} else {
  puts "LAYOUT_UNCHANGED_BY_PROGDATA -- pre-progdata timing still describes the exported design"
}

catch { run_tool -name {GENERATEPROGRAMMINGFILE} }
file mkdir "$pd/export"
catch { export_prog_job -job_file_name {SAR_TOP_ffv} -export_dir "$pd/export" -bitstream_file_type {TRUSTED_FACILITY} }
puts "BITSTREAM_DONE"
puts "FFV_BUILD_DONE"
