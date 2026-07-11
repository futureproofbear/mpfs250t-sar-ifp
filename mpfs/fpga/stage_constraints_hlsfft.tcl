## stage_constraints_hlsfft.tcl -- import constraints into the libero_hlsfft project and derive the
## top-level SDC. Run AFTER create_fresh_project_hlsfft.tcl, BEFORE build_full_prog_hlsfft.tcl.
##   sar_io.pdc      : fabric I/O pin map (REF_CLK, MMUART)  -> constraint/io/  (unchanged)
##   sar_fft_cdc.sdc : DROPPED -- it constrains CoreFFT's CLK<->SLOWCLK crossing, which does not
##                     exist in the HLS-FFT design (no CoreFFT, no SLOWCLK). The HLS kernels carry
##                     their own component SDCs automatically.
##   SAR_TOP_derived : CCC/MSS/AXIIC generated clocks (auto-derived for the current hierarchy)
set here [file normalize [file dirname [info script]]]
set pd "$here/libero_hlsfft"
open_project "$pd/sar_accel.prjx"
project_settings -abort_flow_on_sdc_errors 0
catch {project_settings -abort_flow_on_pdc_errors 0}
build_design_hierarchy
set_root -module {SAR_TOP::work}

## hand-written fabric I/O constraints (same CCC clocks + fabric I/O as the CoreFFT build)
catch { import_files -io_pdc "$here/constraints/sar_io.pdc" } e1;  puts "io_pdc: $e1"

## derived timing constraints for the CURRENT hierarchy (CCC/MSS/AXIIC generated clocks)
if {[catch {derive_constraints_sdc} e]} { puts "derive: $e" } else { puts "derive: OK" }

save_project
set dsdc "$pd/constraint/SAR_TOP_derived_constraints.sdc"
puts "derived exists = [file exists $dsdc]"
if {[file exists $dsdc]} { puts "clocks in derived = [exec grep -c -i create_clock $dsdc]" }
puts "STAGE_CONSTRAINTS_HLSFFT_DONE"
