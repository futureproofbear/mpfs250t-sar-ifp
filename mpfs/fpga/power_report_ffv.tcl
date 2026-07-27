# power_report_ffv.tcl -- vectorless SmartPower estimate for the CURRENT placed-and-routed
# libero_ffv design. Read-only with respect to the design: it opens the project, runs the power
# tool and exports a report. It does NOT synthesise, place, route or re-export a bitstream, so it
# cannot change what is programmed.
#
# DELIBERATELY NOT part of run_build_safe.sh -- power analysis is opt-in per build, by request.
#
# Vectorless means SmartPower assumes default toggle rates rather than reading real switching
# activity. Treat the absolute number as a BALLPARK and the build-to-build DELTA as the useful
# signal. For a number worth quoting, drive it from a VCD of an actual pipeline run: the phases
# differ enormously (both CoreFFT chains streaming during the FFT passes, fabric near-idle and MSS
# busy during the renormalize epilogue), so a single average hides the peak that matters.
#
# Also note this is FABRIC ONLY. It excludes the four U54s, the DDR controller and the PHY -- and
# the renormalize epilogue is pure CPU. For a whole-board figure use the Icicle's on-board current
# sense over I2C instead.
set here [file normalize [file dirname [info script]]]
set proj "$here/libero_ffv"

if {[catch { open_project -project "$proj/sar_accel.prjx" } e]} {
    puts "POWER_ERR: cannot open project: $e"
    puts "@@@ DONE"
    return
}

# The design must already be placed and routed -- power needs real placement to mean anything.
if {[catch { run_tool -name {VERIFYPOWER} } e]} {
    puts "POWER_RC: $e"
} else {
    puts "POWER_OK"
}

# Export whatever report the tool produced, under a stable name the wrapper can find.
catch {
    export_report \
        -export_dir "$proj/designer/SAR_TOP" \
        -name {SAR_TOP_power.rpt} \
        -type {POWER}
}
## Deliberately NO save_project: closing without saving keeps this genuinely non-mutating, so a
## power run can never alter the project that produced a verified bitstream. The exported report
## is the only output.
catch { close_project }
puts "@@@ POWER_DONE"
puts "@@@ DONE"
