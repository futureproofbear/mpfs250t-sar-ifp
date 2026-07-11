## stage_constraints_tdest.tcl -- import the hand-written constraints into the FRESH libero_tdest
## project and (re)generate the top-level derived SDC for the new design (with the fft_unloader).
## Run AFTER create_fresh_project.tcl, BEFORE build_full_prog_fresh.tcl.
##   sar_io.pdc         : fabric I/O pin map (REF_CLK, MMUART)               -> constraint/io/
##   sar_fft_cdc.sdc    : CoreFFT CLK<->SLOWCLK false-path exceptions        -> constraint/
##   SAR_TOP_derived... : CCC/MSS/AXIIC generated clocks (auto-derived)      -> constraint/
set here [file normalize [file dirname [info script]]]
set pd "$here/libero_tdest"
open_project "$pd/sar_accel.prjx"
project_settings -abort_flow_on_sdc_errors 0
catch {project_settings -abort_flow_on_pdc_errors 0}
build_design_hierarchy
set_root -module {SAR_TOP::work}

## hand-written constraints (unchanged by the unloader: same CCC clocks, same fabric I/O)
catch { import_files -io_pdc "$here/constraints/sar_io.pdc" } e1;                    puts "io_pdc: $e1"
catch { import_files -sdc   "$here/libero_sar/constraint/sar_fft_cdc.sdc" } e2;      puts "cdc_sdc: $e2"

## derived timing constraints for the CURRENT design hierarchy (CCC/MSS/AXIIC generated clocks)
if {[catch {derive_constraints_sdc} e]} { puts "derive: $e" } else { puts "derive: OK" }

save_project
set dsdc "$pd/constraint/SAR_TOP_derived_constraints.sdc"
puts "derived exists = [file exists $dsdc]"
if {[file exists $dsdc]} { puts "clocks in derived = [exec grep -c -i create_clock $dsdc]" }
puts "STAGE_CONSTRAINTS_DONE"
