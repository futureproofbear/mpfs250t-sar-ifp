# feeder_v_core.tcl -- register the hand-written Verilog fft_feeder (fft_feeder_top wrapping
# fft_feeder_v) as an HDL+ core with the SAME bus interfaces the SmartHLS core had, so it drops
# into sartop_assembly.tcl UNCHANGED (FEED = fft_feeder_top; axi4initiator/axi4target/out_var).
# Replaces the dead SmartHLS mem->stream feeder (runbook §8). Mirrors gearbox_idconv_cores.tcl.
set here {C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga}

catch { create_links -hdl_source "$here/fft_feeder_v.v" }
catch { create_links -hdl_source "$here/fft_feeder_top.v" }
build_design_hierarchy
catch { create_hdl_core -file "$here/fft_feeder_top.v" -module {fft_feeder_top} -library {work} }

# ---- axi4initiator: AXI4 read master (read-only; only AR/R assigned, like the HLS core) ----
catch { hdl_core_add_bif -hdl_core_name {fft_feeder_top} -bif_definition {AXI4:AMBA:AMBA4:master} -bif_name {axi4initiator} -signal_map {} }
foreach {b c} {
    ARADDR  axi4initiator_ar_addr   ARBURST axi4initiator_ar_burst  ARLEN  axi4initiator_ar_len
    ARSIZE  axi4initiator_ar_size   ARVALID axi4initiator_ar_valid  ARREADY axi4initiator_ar_ready
    RDATA   axi4initiator_r_data    RLAST   axi4initiator_r_last    RRESP  axi4initiator_r_resp
    RVALID  axi4initiator_r_valid   RREADY  axi4initiator_r_ready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {fft_feeder_top} -bif_name {axi4initiator} -bif_signal_name $b -core_signal_name $c } }

# ---- axi4target: AXI4 slave (control regs) ----
catch { hdl_core_add_bif -hdl_core_name {fft_feeder_top} -bif_definition {AXI4:AMBA:AMBA4:slave} -bif_name {axi4target} -signal_map {} }
foreach {b c} {
    ARADDR axi4target_araddr  ARID axi4target_arid  ARLEN axi4target_arlen  ARSIZE axi4target_arsize
    ARBURST axi4target_arburst  ARVALID axi4target_arvalid  ARREADY axi4target_arready
    RDATA axi4target_rdata  RID axi4target_rid  RLAST axi4target_rlast  RRESP axi4target_rresp
    RVALID axi4target_rvalid  RREADY axi4target_rready
    AWADDR axi4target_awaddr  AWID axi4target_awid  AWLEN axi4target_awlen  AWSIZE axi4target_awsize
    AWBURST axi4target_awburst  AWVALID axi4target_awvalid  AWREADY axi4target_awready
    WDATA axi4target_wdata  WSTRB axi4target_wstrb  WLAST axi4target_wlast  WVALID axi4target_wvalid  WREADY axi4target_wready
    BID axi4target_bid  BRESP axi4target_bresp  BVALID axi4target_bvalid  BREADY axi4target_bready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {fft_feeder_top} -bif_name {axi4target} -bif_signal_name $b -core_signal_name $c } }

build_design_hierarchy
puts "FEEDER_V_CORE_DONE"
