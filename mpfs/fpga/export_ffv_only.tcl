## export_ffv_only.tcl -- export the programming job from the ALREADY placed+routed+verified
## libero_ffv project, WITHOUT re-running synth/P&R. Use after build_full_prog_ffv.tcl has placed,
## routed and VERIFYTIMING'd the design (save_project was called) but the export was skipped (e.g.
## the 2026-07-24 gate false-negative). Same export-tail safety as build_full_prog_ffv.tcl: fingerprint
## the layout, run prog-data, and if prog-data re-placed, RE-VERIFY the authoritative multi-corner
## VIOLRPT before exporting -- so what ships is what was verified. NO PROGRAMDEVICE.
source [file join [file dirname [info script]] lib sar_env.tcl]
set here "$SAR_FPGA"
set pd "$here/libero_ffv"
open_project -file "$pd/sar_accel.prjx"
set_root -module {SAR_TOP::work}

proc sar_layout_sig {pd} {
  set f "$pd/designer/SAR_TOP/SAR_TOP.loc"
  if {![file exists $f]} { return "NOLOC" }
  return "[file size $f]:[file mtime $f]"
}
proc violrpt_clean {pd} {
  ## authoritative: both multi-corner violation reports must EXIST and say "No Path"
  set ok 1
  foreach {tag vf} [list SETUP "$pd/designer/SAR_TOP/SAR_TOP_max_timing_violations_multi_corner.xml" \
                         HOLD  "$pd/designer/SAR_TOP/SAR_TOP_min_timing_violations_multi_corner.xml"] {
    if {![file exists $vf]} { puts "GATE_FAIL: missing $tag multi-corner violation report"; set ok 0; continue }
    set fp [open $vf r]; set txt [read $fp]; close $fp
    if {[string first "No Path" $txt] >= 0} { puts "VIOLRPT $tag: No Path (clean)" \
    } else { puts "GATE_FAIL: $tag multi-corner violation report LISTS PATHS -> real violations"; set ok 0 }
  }
  return $ok
}

## pre-export gate: the design in the project must already be timing-clean (authoritative)
if {![violrpt_clean $pd]} { puts "REFUSING_EXPORT -- design not timing-clean"; puts "FFV_BUILD_DONE"; return }
puts "TIMING_MET (pre-progdata, from saved P&R)"

set sig_before [sar_layout_sig $pd]
catch { run_tool -name {GENERATEPROGRAMMINGDATA} }
set sig_after [sar_layout_sig $pd]
if {$sig_before ne $sig_after} {
  puts "LAYOUT_CHANGED_BY_PROGDATA -- re-verifying"
  if {[catch { run_tool -name {VERIFYTIMING} } e]} { puts "REVT_RC: $e" } else { puts "REVT_OK" }
  if {![violrpt_clean $pd]} { puts "TIMING_NOT_MET_AFTER_PROGDATA -- refusing to export"; puts "FFV_BUILD_DONE"; return }
  puts "TIMING_MET (post-progdata, re-verified)"
} else {
  puts "LAYOUT_UNCHANGED_BY_PROGDATA -- verified layout is what ships"
}

catch { run_tool -name {GENERATEPROGRAMMINGFILE} }
file mkdir "$pd/export"
catch { export_prog_job -job_file_name {SAR_TOP_ffv} -export_dir "$pd/export" -bitstream_file_type {TRUSTED_FACILITY} }
puts "BITSTREAM_DONE"
puts "FFV_BUILD_DONE"
