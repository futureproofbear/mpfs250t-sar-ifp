## program_hlsfft.tcl -- PROGRAMDEVICE the already-built libero_hlsfft bitstream, no rebuild.
## Use when the board is back on (FlashPro6/J33) after build_full_prog_hlsfft.tcl reported
## BITSTREAM_READY. Does NOT rebuild; just programs the HLS-FFT bitstream.
open_project -file {C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/libero_hlsfft/sar_accel.prjx}
if {[catch { build_design_hierarchy } e]} { puts ">>> build_design_hierarchy: $e" }
if {[catch { set_root -module {SAR_TOP::work} } e]} { puts ">>> set_root SAR_TOP::work FAILED: $e" } else { puts ">>> set_root SAR_TOP::work OK" }
catch { refresh_programmer_list }
if {[catch { run_tool -name {PROGRAMDEVICE} } e]} {
    puts ">>> PROGRAMDEVICE FAILED: $e"
} else {
    puts ">>> PROGRAMDEVICE OK"
}
puts ">>> PROGRAM_HLSFFT_DONE"
