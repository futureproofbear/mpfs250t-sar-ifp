# prep_add_sinc32.tcl -- link sar_sinc32_gather.v into the EXISTING libero_ffv project.
#
# sar_sinc32_gather is a submodule of sar_resample_v (the LCFG[17] 32-tap gather path). The project
# already has sar_resample_v.v and sar_resample_v_top.v linked from when that core was added, but
# not its new child, so synthesis would stop on a missing module.
#
# Deliberately INCREMENTAL, not a fresh project: create_fresh_project_ffv.tcl deletes libero_ffv
# wholesale, export/ included, so the current known-good SAR_TOP_ffv.job would be destroyed before
# the replacement exists. Adding a file does not need that.
#
# Used as the prep stage of run_build_safe.sh:
#   bash mpfs/host/run_build_safe.sh mpfs/fpga/prep_add_sinc32.tcl

source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA
set pd "$SAR_FPGA/libero_ffv"

open_project -file "$pd/sar_accel.prjx"

if {[catch { create_links -hdl_source "$SAR_FPGA/sar_sinc32_gather.v" } e]} {
    puts "@@@ LINK_NOTE: $e"
}
build_design_hierarchy
set_root -module {SAR_TOP::work}
save_project

puts "@@@ PREP_OK sar_sinc32_gather linked"
puts "@@@ DONE"
