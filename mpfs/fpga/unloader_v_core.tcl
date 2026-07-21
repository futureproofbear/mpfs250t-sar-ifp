# unloader_v_core.tcl -- register the hand-written Verilog fft_unloader (fft_unloader_top wrapping
# fft_unloader_v) as an HDL+ core with the SAME bus interfaces the SmartHLS core had, so it drops
# into sartop_assembly.tcl UNCHANGED (UNLD = fft_unloader_top; axi4initiator/axi4target/in_var).
# Direct mirror of feeder_v_core.tcl, which is silicon-proven.
#
# WHY replace the HLS unloader: it now computes |z| = sqrt(I^2+Q^2) inline (runtime-enabled), which
# deletes the separate 20.6 s detect stage -- a 512 MB read + 128 MB write. Detect could NOT be done
# in SmartHLS: it mis-synthesizes the signed narrowing (int16_t)(x>>16) as UNSIGNED, saturating ~50%
# of the image, and that passed both cosim and a correlation check. tb/tb_fft_unloader_det.v
# mutation-tests exactly this (strip `signed` -> 2035/2048 mismatches).
#
# NOTE the initiator here is a WRITE master (AW/W/B), where the feeder's is a READ master (AR/R).
# The pin names are taken from a real SmartHLS-generated core in this repo
# (hls_coeffgen/hls_output/reports), not invented.
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set here "$SAR_FPGA"

catch { create_links -hdl_source "$here/fft_unloader_v.v" }
catch { create_links -hdl_source "$here/fft_unloader_top.v" }
build_design_hierarchy
catch { create_hdl_core -file "$here/fft_unloader_top.v" -module {fft_unloader_top} -library {work} }

# ---- axi4initiator: AXI4 WRITE master (only AW/W/B assigned, like the HLS core) ----
catch { hdl_core_add_bif -hdl_core_name {fft_unloader_top} -bif_definition {AXI4:AMBA:AMBA4:master} -bif_name {axi4initiator} -signal_map {} }
foreach {b c} {
    AWADDR  axi4initiator_aw_addr   AWBURST axi4initiator_aw_burst  AWLEN  axi4initiator_aw_len
    AWSIZE  axi4initiator_aw_size   AWVALID axi4initiator_aw_valid  AWREADY axi4initiator_aw_ready
    WDATA   axi4initiator_w_data    WLAST   axi4initiator_w_last    WSTRB  axi4initiator_w_strb
    WVALID  axi4initiator_w_valid   WREADY  axi4initiator_w_ready
    BRESP   axi4initiator_b_resp    BVALID  axi4initiator_b_valid   BREADY axi4initiator_b_ready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {fft_unloader_top} -bif_name {axi4initiator} -bif_signal_name $b -core_signal_name $c } }

# ---- axi4target: AXI4 slave (control regs) ----
catch { hdl_core_add_bif -hdl_core_name {fft_unloader_top} -bif_definition {AXI4:AMBA:AMBA4:slave} -bif_name {axi4target} -signal_map {} }
foreach {b c} {
    ARADDR axi4target_araddr  ARID axi4target_arid  ARLEN axi4target_arlen  ARSIZE axi4target_arsize
    ARBURST axi4target_arburst  ARVALID axi4target_arvalid  ARREADY axi4target_arready
    RDATA axi4target_rdata  RID axi4target_rid  RLAST axi4target_rlast  RRESP axi4target_rresp
    RVALID axi4target_rvalid  RREADY axi4target_rready
    AWADDR axi4target_awaddr  AWID axi4target_awid  AWLEN axi4target_awlen  AWSIZE axi4target_awsize
    AWBURST axi4target_awburst  AWVALID axi4target_awvalid  AWREADY axi4target_awready
    WDATA axi4target_wdata  WSTRB axi4target_wstrb  WLAST axi4target_wlast  WVALID axi4target_wvalid  WREADY axi4target_wready
    BID axi4target_bid  BRESP axi4target_bresp  BVALID axi4target_bvalid  BREADY axi4target_bready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {fft_unloader_top} -bif_name {axi4target} -bif_signal_name $b -core_signal_name $c } }

build_design_hierarchy
puts "UNLOADER_V_CORE_DONE"
