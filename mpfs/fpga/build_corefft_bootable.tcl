# build_corefft_bootable.tcl -- add the HSS eNVM boot client to the (already P&R'd,
# timing-MET) corefft_vm project and export a COMPLETE bootable job (FABRIC + SNVM + ENVM).
#
# ⚠️ FOR DEPLOYMENT ONLY (standalone boot-from-eNVM), NOT the debug iso-test. HSS in eNVM
# does NOT cooperate with JTAG halt -> openocd "Target not halted" / gdb rejected (proven
# 2026-07-08, needed a power-cycle). For the iso-test, program SAR_TOP_corefft.job FABRIC-ONLY
# and re-flash the APP via mpfs/host/run_program.sh (boot mode 1). See runbook §8.
set PROJDIR {C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/libero_corefft_vm}
set ENVMCFG {C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/hss/ENVM.cfg}
open_project -file "$PROJDIR/corefft_vm.prjx"
project_settings -abort_flow_on_sdc_errors 0
catch { project_settings -abort_flow_on_pdc_errors 0 }
set_root -module {SAR_TOP_NL::work}
puts "@@@ ROOT_SET"

catch { run_tool -name {GENERATEPROGRAMMINGDATA} } e0; puts "@@@ PGD0: $e0"
if {[catch {configure_envm -cfg_file $ENVMCFG} e]} { puts "@@@ ENVM_ERR: $e" } else { puts "@@@ ENVM_OK" }
if {[catch {generate_design_initialization_data} e]} { puts "@@@ DI_ERR: $e" } else { puts "@@@ DI_OK" }
if {[catch {run_tool -name {GENERATEPROGRAMMINGDATA}} e]} { puts "@@@ PGD_ERR: $e" } else { puts "@@@ PGD_OK" }

file mkdir "$PROJDIR/export"
if {[catch {export_prog_job \
    -job_file_name {SAR_TOP_corefft_boot} \
    -export_dir "$PROJDIR/export" \
    -bitstream_file_type {TRUSTED_FACILITY} \
    -bitstream_file_components {FABRIC_SNVM ENVM}} e]} { puts "@@@ JOB_ERR: $e" } else { puts "@@@ JOB_OK" }
save_project
puts "@@@ ALLDONE"
