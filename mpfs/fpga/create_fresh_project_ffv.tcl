## create_fresh_project.tcl -- build a BRAND-NEW, uncorrupted Libero project for the SAR
## accelerator with the TLAST fix. The old libero_sar HDL+ core DB is corrupted (a prior
## module-rename + core-dir-delete broke every HDL+ core's link, unrecoverable headless).
## This creates all IP components + MSS + the HDL+ cores FRESH (no core ever corrupted),
## then assembles SAR_TOP with the CoreFFT output stream drained by the fft_unloader HLS kernel
## (plain AXI4 write master) instead of the deadlocking CoreAXI4DMAController.
##
## Run:  libero.exe SCRIPT:create_fresh_project.tcl LOGFILE:create_fresh_project.log
## Output project: mpfs/fpga/libero_fresh  (the corrupt libero_sar is left untouched as fallback).
## Then: copy constraints in + run build_full_prog.tcl (pointed at libero_fresh).

source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set here "$SAR_FPGA"
set proj "$here/libero_ffv"
file delete -force $proj

new_project \
    -location $proj -name {sar_accel} -project_description {SAR accelerator (fresh, TLAST fix)} \
    -hdl {VERILOG} -family {PolarFireSoC} -die {MPFS250T_ES} -package {FCVG484} \
    -speed {STD} -die_voltage {1.05} -part_range {EXT} -ondemand_build_dh {1}

## ---------------- IP components (DirectCore / SgCore) ----------------
## CoreFFT 8.1.100: in-place, 8192-pt, 16-bit, conditional-BFP SCALE_EXP.
create_and_configure_core -core_vlnv {Actel:DirectCore:COREFFT:8.1.100} -component_name {COREFFT_C0} \
    -params [list {CFG_ARCH:1} {POINTS:8192} {WIDTH:16} {SCALE:0} {SCALE_EXP_ON:true} {INVERSE:0}]
generate_component -component_name {COREFFT_C0}

## NOTE: the CoreAXI4DMAController (AXIDMA_C0) that used to drain CoreFFT->DDR is GONE.
## Its AXI4-Stream S2MM target deadlocks on the 2nd back-to-back transaction (SmartDebug-confirmed).
## Replaced by the fft_unloader HLS kernel (plain AXI4 write master, added to the HDL+ core list below).

## Data-plane interconnect AXIIC_C0 (DIC): COREAXI4INTERCONNECT 3.0.130, 6 initiators -> 1 DDR target.
## Full 3.0.130 param set extracted from the as-built AXIIC_C0.cxf (NUM_INITIATORS=6/NUM_TARGETS=1).
source "$here/axiic_c0_params_330.tcl"    ;# -> $AXIIC_C0_PARAMS
create_and_configure_core -core_vlnv {Actel:DirectCore:COREAXI4INTERCONNECT:3.0.130} -component_name {AXIIC_C0} -params $AXIIC_C0_PARAMS
generate_component -component_name {AXIIC_C0}

## Control-plane interconnect AXIIC_CTRL (CIC): 3.0.130, 1 initiator -> 6 targets (target5 now = standard AXI4 for fft_unloader ctrl; was AXI4-Lite for DMA).
source "$here/axiic_ctrl_params.tcl"      ;# -> $AXIIC_CTRL_PARAMS
create_and_configure_core -core_vlnv {Actel:DirectCore:COREAXI4INTERCONNECT:3.0.130} -component_name {AXIIC_CTRL} -params $AXIIC_CTRL_PARAMS
generate_component -component_name {AXIIC_CTRL}

## Clock: PF_CCC @ 62.5 MHz (OUT0) + 7.8125 MHz (OUT1 = CoreFFT SLOWCLK). Full param TCL from the as-built.
source "$here/PF_CCC_C0_62p5.tcl"         ;# create_and_configure_core PF_CCC_C0
generate_component -component_name {PF_CCC_C0}

## Reset controller (CORERESET_PF).
create_and_configure_core -download_core -core_vlnv {Actel:DirectCore:CORERESET_PF:*} -component_name {CORERESET_C0} -params {}
generate_component -component_name {CORERESET_C0}

build_design_hierarchy

## ---------------- MSS (DLL-BYPASSED build = matches on-board bitstream) + design init ----------------
## FIC0/1/2/3 embedded DLLs BYPASSED (the 62.5 MHz data-plane fix). mss_es/mss_component have DLLs
## ENABLED (=the broken data-plane hang) -- do NOT use those.
import_mss_component -file "$here/mss_nodll/out/ICICLE_MSS.cxz"
build_design_hierarchy
catch { generate_design_initialization_data }

## ---------------- HDL+ cores (created FRESH -- the whole point of the new project) ----------------
set_root -module {COREFFT_C0::work}       ;# temp root so create_hdl_plus's SYNTHESIZE config applies
foreach hls {hls_corner_turn hls_window hls_detect hls_resample hls_fft_unloader} {
    source "$here/$hls/hls_output/scripts/libero/create_hdl_plus.tcl"
}
## gearbox (corefft_stream64_adapter, now WITH m_axis_tlast) + sar_axi_idconv (S_AXI/M_AXI bifs)
source "$here/gearbox_idconv_cores.tcl"
source "$here/feeder_v_core.tcl"
build_design_hierarchy

## ---------------- assemble SAR_TOP (instantiate + wire, incl GBX:m_axis -> UNLD:in_var stream) ----------------
source "$here/sartop_assembly.tcl"        ;# set sd SAR_TOP ... generate_component SAR_TOP ... "SARTOP330_DONE"
puts "FRESH_PROJECT_DONE"
