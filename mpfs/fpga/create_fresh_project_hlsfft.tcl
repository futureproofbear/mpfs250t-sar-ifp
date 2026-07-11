## create_fresh_project_hlsfft.tcl -- fresh Libero project with the HLS fft_kernel REPLACING the
## CoreFFT streaming chain (FEED+GBX+COREFFT+UNLD). Same IP/MSS/interconnect as the CoreFFT build;
## only the FFT datapath differs. Output project: libero_hlsfft (the CoreFFT libero_tdest is left
## untouched as the fallback). Then: stage constraints + run build_full_prog_hlsfft.tcl.
##
## Run:  libero.exe SCRIPT:create_fresh_project_hlsfft.tcl LOGFILE:create_fresh_project_hlsfft.log

set here {C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga}
set proj "$here/libero_hlsfft"
file delete -force $proj

new_project \
    -location $proj -name {sar_accel} -project_description {SAR accelerator (HLS FFT)} \
    -hdl {VERILOG} -family {PolarFireSoC} -die {MPFS250T_ES} -package {FCVG484} \
    -speed {STD} -die_voltage {1.05} -part_range {EXT} -ondemand_build_dh {1}

## ---------------- IP components (DirectCore / SgCore) ----------------
## COREFFT_C0 kept ONLY as the temp set_root for create_hdl_plus's SYNTHESIZE config (and as an
## in-project CoreFFT fallback). It is NOT instantiated in SAR_TOP -> not synthesized into the design.
create_and_configure_core -core_vlnv {Actel:DirectCore:COREFFT:8.1.100} -component_name {COREFFT_C0} \
    -params [list {CFG_ARCH:1} {POINTS:8192} {WIDTH:16} {SCALE:0} {SCALE_EXP_ON:true} {INVERSE:0}]
generate_component -component_name {COREFFT_C0}

## Data-plane interconnect AXIIC_C0 (DIC): 6 initiators -> 1 DDR target (config reused UNCHANGED;
## FFTK uses initiator4, initiator5 left unused -> crossbar identical to the known-good build).
source "$here/axiic_c0_params_330.tcl"    ;# -> $AXIIC_C0_PARAMS
create_and_configure_core -core_vlnv {Actel:DirectCore:COREAXI4INTERCONNECT:3.0.130} -component_name {AXIIC_C0} -params $AXIIC_C0_PARAMS
generate_component -component_name {AXIIC_C0}

## Control-plane interconnect AXIIC_CTRL (CIC): 1 initiator -> 6 targets (FFTK on target4 @ 0x60004000,
## target5 unused). Config reused unchanged.
source "$here/axiic_ctrl_params.tcl"      ;# -> $AXIIC_CTRL_PARAMS
create_and_configure_core -core_vlnv {Actel:DirectCore:COREAXI4INTERCONNECT:3.0.130} -component_name {AXIIC_CTRL} -params $AXIIC_CTRL_PARAMS
generate_component -component_name {AXIIC_CTRL}

## Clock: PF_CCC @ 62.5 MHz (OUT0). OUT1 (was CoreFFT SLOWCLK) now unused but the CCC config is reused as-is.
source "$here/PF_CCC_C0_62p5.tcl"         ;# create_and_configure_core PF_CCC_C0
generate_component -component_name {PF_CCC_C0}

## Reset controller (CORERESET_PF).
create_and_configure_core -download_core -core_vlnv {Actel:DirectCore:CORERESET_PF:*} -component_name {CORERESET_C0} -params {}
generate_component -component_name {CORERESET_C0}

build_design_hierarchy

## ---------------- MSS (DLL-BYPASSED build = matches on-board bitstream) + design init ----------------
import_mss_component -file "$here/mss_nodll/out/ICICLE_MSS.cxz"
build_design_hierarchy
catch { generate_design_initialization_data }

## ---------------- HDL+ cores (FRESH) ----------------
## FFT chain kernels: drop hls_fft_feeder + hls_fft_unloader; add hls_fft (the fft_kernel).
set_root -module {COREFFT_C0::work}       ;# temp root so create_hdl_plus's SYNTHESIZE config applies
foreach hls {hls_corner_turn hls_window hls_detect hls_resample hls_fft} {
    source "$here/$hls/hls_output/scripts/libero/create_hdl_plus.tcl"
}
## sar_axi_idconv (S_AXI/M_AXI bifs) still required between DIC and MSS FIC0. gearbox_idconv_cores.tcl
## also (harmlessly) creates the now-unused corefft_stream64_adapter core.
source "$here/gearbox_idconv_cores.tcl"
build_design_hierarchy

## ---------------- assemble SAR_TOP (HLS FFT variant) ----------------
source "$here/sartop_assembly_hlsfft.tcl"  ;# -> "SARTOP_HLSFFT_DONE"
puts "FRESH_HLSFFT_PROJECT_DONE"
