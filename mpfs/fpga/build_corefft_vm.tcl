# build_corefft_vm.tcl -- reconstruct the deleted VM-netlist recovery build for the
# CoreFFT SAR_TOP @ 62.5 MHz (per docs/fpga/SAR_TOP_RECOVERY.md, verified 0/0 timing).
# Fresh project, import the surviving byte-spliced netlist SAR_TOP_NL.vm (no synthesis),
# associate the 62.5 MHz SDC + CDC + I/O PDC, P&R, gate on timing, export a job.
#
# Flip STOP_AFTER_SETUP to 0 for the full ~1hr gated build. =1 validates the fragile
# project-setup API fast (seconds-minutes) BEFORE committing to P&R.
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set STOP_AFTER_SETUP 0

set ROOT    "$SAR_FPGA"
set PROJDIR "$ROOT/libero_corefft_vm"
set NL      "$ROOT/libero_sar/synthesis/SAR_TOP_NL.vm"
set IOPDC   "$ROOT/libero_sar/constraint/io/sar_io.pdc"
set SDC     "$ROOT/libero_sar/constraint/SAR_TOP_derived_constraints.sdc"
set CDC     "$ROOT/libero_sar/constraint/sar_fft_cdc.sdc"

file delete -force $PROJDIR                      ;# idempotent re-run
puts "@@@ NEW_PROJECT"
new_project \
    -location $PROJDIR -name {corefft_vm} -project_description {CoreFFT VM-netlist 62.5MHz recovery build} \
    -hdl {VERILOG} -family {PolarFireSoC} -die {MPFS250T_ES} -package {FCVG484} \
    -speed {STD} -die_voltage {1.05} -part_range {EXT} -ondemand_build_dh {1}
puts "@@@ VM_FLOW"
project_settings -vm_netlist_flow TRUE
puts "@@@ IMPORT_NETLIST"
import_files -verilog_netlist $NL
build_design_hierarchy
catch { set_root -module {SAR_TOP_NL::work} }
puts "@@@ ROOT=[get_root]"
puts "@@@ IMPORT_CONSTRAINTS"
import_files -io_pdc $IOPDC
import_files -sdc    $SDC
import_files -sdc    $CDC
puts "@@@ ORGANIZE"
catch { organize_tool_files -tool {PLACEROUTE} \
    -file "$PROJDIR/constraint/io/sar_io.pdc" \
    -file "$PROJDIR/constraint/SAR_TOP_derived_constraints.sdc" \
    -file "$PROJDIR/constraint/sar_fft_cdc.sdc" \
    -module {SAR_TOP_NL::work} -input_type {constraint} } e1
puts "@@@ ORG_PR: $e1"
catch { organize_tool_files -tool {VERIFYTIMING} \
    -file "$PROJDIR/constraint/SAR_TOP_derived_constraints.sdc" \
    -file "$PROJDIR/constraint/sar_fft_cdc.sdc" \
    -module {SAR_TOP_NL::work} -input_type {constraint} } e2
puts "@@@ ORG_VT: $e2"
save_project
puts "@@@ SETUP_DONE"

if {$STOP_AFTER_SETUP} { puts "@@@ STOPPING (setup-only)"; return }

# ---------------- full gated build ----------------
configure_tool -name {PLACEROUTE} -params {REPAIR_MIN_DELAY:true}
run_tool -name {COMPILE}
puts "@@@ COMPILE_DONE"
run_tool -name {PLACEROUTE}
puts "@@@ PLACEROUTE_DONE"
run_tool -name {VERIFYTIMING}
puts "@@@ VERIFYTIMING_DONE"

# timing-closure gate (from build_timed.tcl)
set timing_report ""
foreach cand [glob -nocomplain "$PROJDIR/designer/*/pinslacks.txt"] { set timing_report $cand }
if {$timing_report eq "" || ![file exists $timing_report]} {
    return -code error "TIMING GATE: pinslacks.txt not found -- refusing to export."
}
set fp [open $timing_report r]; set nviol 0; set worst 1.0e9; set first 1
while {[gets $fp line] >= 0} {
    if {$first} { set first 0; continue }
    set cols [split $line ","]
    if {[llength $cols] < 2} { continue }
    set slack [string trim [lindex $cols 1]]
    if {![string is double -strict $slack]} { continue }
    if {$slack < 0} { incr nviol; if {$slack < $worst} { set worst $slack } }
}
close $fp
if {$nviol > 0} {
    puts "@@@ TIMING_FAIL: $nviol neg-slack pins, worst ${worst} ps"
    return -code error "Timing closure failed ($nviol violations, worst ${worst} ps)."
}
puts "@@@ TIMING_GATE_PASSED (0 neg-slack pins)"
run_tool -name {GENERATEPROGRAMMINGDATA}
puts "@@@ GENDATA_DONE"
run_tool -name {GENERATEPROGRAMMINGFILE}
puts "@@@ GENFILE_DONE"
file mkdir "$PROJDIR/export"
export_prog_job -job_file_name {SAR_TOP_corefft} -export_dir "$PROJDIR/export" -bitstream_file_type {TRUSTED_FACILITY}
puts "@@@ EXPORT_DONE -> $PROJDIR/export/SAR_TOP_corefft.job"
