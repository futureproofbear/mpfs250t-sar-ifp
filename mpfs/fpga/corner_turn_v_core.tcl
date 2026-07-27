# corner_turn_v_core.tcl -- register the hand-written corner-turn (corner_turn_v_top wrapping
# corner_turn_v) as an HDL+ core with the SAME bus interfaces the SmartHLS `corner_turn_top` had,
# so sartop_assembly.tcl needs only the hdl_core_name swapped and every existing connect still
# lands: CT:axi4initiator -> DIC:AXI4minitiator0, CIC:AXI4mtarget0 -> CT:axi4target.
#
# Unlike the feeder (read-only) and the unloader (write-only), the corner-turn is BOTH, so its
# axi4initiator carries AR/R *and* AW/W/B. Mirrors feeder_v_core.tcl otherwise.
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths
set here "$SAR_FPGA"

catch { create_links -hdl_source "$here/corner_turn_v.v" }
catch { create_links -hdl_source "$here/corner_turn_v_top.v" }
build_design_hierarchy
catch { create_hdl_core -file "$here/corner_turn_v_top.v" -module {corner_turn_v_top} -library {work} }

# ---- axi4initiator: AXI4 master, READ + WRITE ----
catch { hdl_core_add_bif -hdl_core_name {corner_turn_v_top} -bif_definition {AXI4:AMBA:AMBA4:master} -bif_name {axi4initiator} -signal_map {} }
foreach {b c} {
    ARADDR  axi4initiator_ar_addr   ARBURST axi4initiator_ar_burst  ARLEN   axi4initiator_ar_len
    ARSIZE  axi4initiator_ar_size   ARVALID axi4initiator_ar_valid  ARREADY axi4initiator_ar_ready
    RDATA   axi4initiator_r_data    RLAST   axi4initiator_r_last    RRESP   axi4initiator_r_resp
    RVALID  axi4initiator_r_valid   RREADY  axi4initiator_r_ready
    AWADDR  axi4initiator_aw_addr   AWBURST axi4initiator_aw_burst  AWLEN   axi4initiator_aw_len
    AWSIZE  axi4initiator_aw_size   AWVALID axi4initiator_aw_valid  AWREADY axi4initiator_aw_ready
    WDATA   axi4initiator_w_data    WLAST   axi4initiator_w_last    WSTRB   axi4initiator_w_strb
    WVALID  axi4initiator_w_valid   WREADY  axi4initiator_w_ready
    BRESP   axi4initiator_b_resp    BVALID  axi4initiator_b_valid   BREADY  axi4initiator_b_ready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {corner_turn_v_top} -bif_name {axi4initiator} -bif_signal_name $b -core_signal_name $c } }

# ---- axi4target: AXI4 slave (control regs) ----
catch { hdl_core_add_bif -hdl_core_name {corner_turn_v_top} -bif_definition {AXI4:AMBA:AMBA4:slave} -bif_name {axi4target} -signal_map {} }
foreach {b c} {
    ARADDR axi4target_araddr  ARID axi4target_arid  ARLEN axi4target_arlen  ARSIZE axi4target_arsize
    ARBURST axi4target_arburst  ARVALID axi4target_arvalid  ARREADY axi4target_arready
    RDATA axi4target_rdata  RID axi4target_rid  RLAST axi4target_rlast  RRESP axi4target_rresp
    RVALID axi4target_rvalid  RREADY axi4target_rready
    AWADDR axi4target_awaddr  AWID axi4target_awid  AWLEN axi4target_awlen  AWSIZE axi4target_awsize
    AWBURST axi4target_awburst  AWVALID axi4target_awvalid  AWREADY axi4target_awready
    WDATA axi4target_wdata  WSTRB axi4target_wstrb  WLAST axi4target_wlast
    WVALID axi4target_wvalid  WREADY axi4target_wready
    BID axi4target_bid  BRESP axi4target_bresp  BVALID axi4target_bvalid  BREADY axi4target_bready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {corner_turn_v_top} -bif_name {axi4target} -bif_signal_name $b -core_signal_name $c } }

puts "CORNER_TURN_V_CORE_DONE"
