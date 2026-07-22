# sar_fic0s_mon_core.tcl -- register the hand-written Verilog sar_fic0s_mon.v (FIC_0_AXI4_S
# transaction monitor) as an HDL+ core, modeled exactly on axi4_regslice_core.tcl /
# feeder_v_core.tcl / unloader_v_core.tcl's create_links/create_hdl_core/hdl_core_add_bif/
# hdl_core_assign_bif_signal pattern.
#
# sar_fic0s_mon.v's s_axi_* port set (see its own header) is a genuine AXI4-LITE slave --
# no ID/LEN/BURST/LOCK/CACHE/QOS/REGION/USER, no WSTRB/WLAST, no BID/RID/RLAST, 32-bit
# WDATA/RDATA -- so only the AXI4-Lite-relevant fields are assigned below (same convention
# as feeder_v_core.tcl/unloader_v_core.tcl assigning only the subset of AXI4 fields their
# modules actually implement). The clk/aresetn/mon_* observe-only ports need no BIF wrapper;
# they are wired directly as plain pins in sartop_assembly.tcl, same as FEED's
# scale_exp_in/outp_ready_in.
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set here "$SAR_FPGA"

catch { create_links -hdl_source "$here/sar_fic0s_mon.v" }
build_design_hierarchy
catch { create_hdl_core -file "$here/sar_fic0s_mon.v" -module {sar_fic0s_mon} -library {work} }

# ---- s_axi: AXI4-Lite slave (control/status regs @ 0x6000_6000) ----
catch { hdl_core_add_bif -hdl_core_name {sar_fic0s_mon} -bif_definition {AXI4:AMBA:AMBA4:slave} -bif_name {s_axi} -signal_map {} }
foreach {b c} {
    ARADDR  s_axi_araddr   ARVALID s_axi_arvalid  ARREADY s_axi_arready
    RDATA   s_axi_rdata    RRESP   s_axi_rresp    RVALID  s_axi_rvalid   RREADY s_axi_rready
    AWADDR  s_axi_awaddr   AWVALID s_axi_awvalid  AWREADY s_axi_awready
    WDATA   s_axi_wdata    WVALID  s_axi_wvalid   WREADY  s_axi_wready
    BRESP   s_axi_bresp    BVALID  s_axi_bvalid   BREADY  s_axi_bready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {sar_fic0s_mon} -bif_name {s_axi} -bif_signal_name $b -core_signal_name $c } }

build_design_hierarchy
puts "SAR_FIC0S_MON_CORE_DONE"
