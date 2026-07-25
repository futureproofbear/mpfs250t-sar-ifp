# sar_coeffgen_core.tcl -- register the hand-written Verilog sar_coeffgen.v (on-fabric azimuth
# resample coefficient generator) as an HDL+ core, modeled exactly on sar_fic0s_mon_core.tcl /
# feeder_v_core.tcl's create_links/create_hdl_core/hdl_core_add_bif/hdl_core_assign_bif_signal
# pattern.
#
# NO SmartHLS ANYWHERE IN THIS PATH. sar_coeffgen.v is hand-written by mandate (docs/SAR_GUIDE.md
# Part 2, docs/fpga/DEV_GUIDE.md 1): SmartHLS has silently produced dead RTL (the mem->stream
# feeder) and dropped sign extension (the detect (int16_t)(x>>16) miscompile) on this toolchain,
# and this module is float32-exact arithmetic feeding a value gate -- exactly the class of code
# that failure mode destroys.
#
# sar_coeffgen.v's s_* port set is a genuine AXI4-LITE slave -- no ID/LEN/BURST/LOCK/CACHE/QOS/
# REGION/USER, no WSTRB/WLAST, no BID/RID/RLAST, 32-bit WDATA/RDATA -- so only the AXI4-Lite
# fields are assigned below, the same convention sar_fic0s_mon_core.tcl uses for the CIC's
# AXI4Lmtarget6. s_bresp/s_rresp exist purely so no bif signal is left unassigned (a single
# dangling bif signal makes SmartDesign promote the whole interface to top-level I/O -- see the
# RSLICE_CIC LOCK note in sartop_assembly.tcl).
#
# clk/resetn and the {m_idx,m_wq,m_valid,m_ready} coefficient stream need no BIF wrapper; they are
# wired as plain pins in sartop_assembly.tcl, same as FEED's scale_exp_in/outp_ready_in.
#
# The file also carries sar_fp32_mul / sar_fp32_add (leaf arithmetic modules); -module picks the
# top explicitly so the leaves are pulled in as hierarchy, not registered as cores.
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set here "$SAR_FPGA"

catch { create_links -hdl_source "$here/sar_coeffgen.v" }
build_design_hierarchy
catch { create_hdl_core -file "$here/sar_coeffgen.v" -module {sar_coeffgen} -library {work} }

# ---- s_axi: AXI4-Lite slave (control/table-load regs @ 0x6000_7000) ----
catch { hdl_core_add_bif -hdl_core_name {sar_coeffgen} -bif_definition {AXI4:AMBA:AMBA4:slave} -bif_name {s_axi} -signal_map {} }
foreach {b c} {
    ARADDR  s_araddr   ARVALID s_arvalid  ARREADY s_arready
    RDATA   s_rdata    RRESP   s_rresp    RVALID  s_rvalid   RREADY s_rready
    AWADDR  s_awaddr   AWVALID s_awvalid  AWREADY s_awready
    WDATA   s_wdata    WVALID  s_wvalid   WREADY  s_wready
    BRESP   s_bresp    BVALID  s_bvalid   BREADY  s_bready
} { catch { hdl_core_assign_bif_signal -hdl_core_name {sar_coeffgen} -bif_name {s_axi} -bif_signal_name $b -core_signal_name $c } }

build_design_hierarchy
puts "SAR_COEFFGEN_CORE_DONE"
