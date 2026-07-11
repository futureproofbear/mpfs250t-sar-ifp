# build_timed.tcl -- SAR_TOP build flow with a HARD timing-closure GATE.
#
# Synth -> P&R -> Verify Timing -> PARSE pinslacks.txt -> ABORT if any negative
# slack BEFORE generating/exporting a bitstream. Prevents shipping a
# timing-failing bitstream to silicon (root cause of the M3 FFT saga: 25,847
# neg-slack pins, worst -3.7 ns at 125 MHz, were programmed unnoticed).
#
# PREREQ: reconfigure PF_CCC_C0 to OUT0=62.5 MHz / OUT1=7.8125 MHz first (GUI),
# and add constraint/sar_fft_cdc.sdc to the timing set, so timing can actually close.
#
# Run:  <libero>/libero SCRIPT:build_timed.tcl   (or `script build_timed.tcl` in the Tcl console)

set ROOT {C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga}
set PROJ "$ROOT/libero_sar/sar_accel.prjx"
open_project -file $PROJ
build_design_hierarchy

configure_tool -name {PLACEROUTE} -params {REPAIR_MIN_DELAY:true}
run_tool -name {SYNTHESIZE}
run_tool -name {PLACEROUTE}
run_tool -name {VERIFYTIMING}

# ---------------- TIMING-CLOSURE GATE ----------------
# Parse the per-pin slack table (slack is the 2nd CSV column, in ps). Count any
# negative-slack pins and report the worst; abort the flow if timing did not close.
set timing_report ""
foreach cand [glob -nocomplain "$ROOT/libero_sar/designer/*/pinslacks.txt"] {
    set timing_report $cand
}
if {$timing_report eq "" || ![file exists $timing_report]} {
    return -code error "TIMING GATE: pinslacks.txt not found -- cannot verify timing; refusing to build a bitstream."
}
set fp [open $timing_report r]
set nviol 0
set worst 1.0e9
set first 1
while {[gets $fp line] >= 0} {
    if {$first} { set first 0; continue }      ;# skip "pin,slack" header
    set cols [split $line ","]
    if {[llength $cols] < 2} { continue }
    set slack [string trim [lindex $cols 1]]
    if {![string is double -strict $slack]} { continue }
    if {$slack < 0} {
        incr nviol
        if {$slack < $worst} { set worst $slack }
    }
}
close $fp

if {$nviol > 0} {
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    puts "CRITICAL: TIMING NOT MET -- $nviol negative-slack pins (worst ${worst} ps)."
    puts "Refusing to generate/export a bitstream. Lower the fabric clock (CCC OUT0,"
    puts "keep SLOWCLK = OUT0/8) and/or add CDC false-paths, then rebuild."
    puts "Report: $timing_report"
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    return -code error "Timing closure failed ($nviol violations, worst ${worst} ps)."
}
puts ">>> TIMING GATE PASSED: 0 negative-slack pins. Proceeding to bitstream."
# -----------------------------------------------------

run_tool -name {GENERATEPROGRAMMINGDATA}
run_tool -name {GENERATEPROGRAMMINGFILE}
export_prog_job -job_file_name {SAR_TOP_timed} -export_dir "$ROOT/libero_sar/export" -bitstream_file_type {TRUSTED_FACILITY}
puts ">>> TIMED BUILD DONE (timing met). Program with PROGRAMDEVICE / FlashPro when ready."
