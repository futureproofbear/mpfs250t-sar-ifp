# axi4_regslice_core.tcl -- register the hand-written Verilog axi4_regslice.v as an HDL+ core
# with S_AXI/M_AXI AXI4 BIFs (same naming convention as sar_axi_idconv.v), modeled exactly on
# feeder_v_core.tcl / unloader_v_core.tcl (the two Verilog-core registration scripts already
# sourced from create_fresh_project_ffv.tcl) and on gearbox_idconv_cores.tcl's S_AXI/M_AXI BIF
# assignment loop for sar_axi_idconv (the field-name-for-field-name precedent this module's
# ports were copied from).
#
# WHY: post-layout multi-corner timing shows the worst setup path moving between the two vendor
# CoreAXI4Interconnect instances (DIC = AXIIC_C0 data interconnect, CIC = AXIIC_CTRL control
# interconnect) build to build. axi4_regslice.v is a topology-preserving inline register slice
# (rewire A->B into A->[slice]->B on an EXISTING point-to-point AXI4 link) meant to be dropped
# onto the links feeding into/out of DIC/CIC to break up the long combinational paths reported
# inside them. It does NOT add or remove a target/initiator from either CoreAXI4Interconnect
# instance -- see sar_axi_idconv.v's header for why that distinction matters on this project.
#
# This script ONLY makes the core buildable (create_hdl_core + BIF registration), matching how
# feeder_v_core.tcl/unloader_v_core.tcl/gearbox_idconv_cores.tcl are sourced from
# create_fresh_project_ffv.tcl. It does NOT instantiate or wire the core into sartop_assembly.tcl
# -- that inline-insertion wiring (breaking an existing SmartDesign connection and rerouting it
# through this slice) is a separate step done during the actual build, because it needs the live
# generated netlist to get the exact existing net names right. See the NET-LEVEL REWIRING note at
# the bottom of this file for what that step will need to do.
#
# ID_WIDTH/ADDR_WIDTH/DATA_WIDTH/DEPTH are Verilog module parameters (see axi4_regslice.v) and
# are exposed by Libero's "Configure Core" per SmartDesign instance -- the SAME registered core
# can be dropped onto BOTH the 11-bit-ID/32-bit-addr DIC link and the 4-bit-ID/38-bit-addr CIC
# link (see bottom note) by overriding the instance's generics, matching how fft_feeder_top's IDW
# parameter is already overridden per-instance elsewhere in this design.
source [file join [file dirname [info script]] lib sar_env.tcl]   ;# SAR_ROOT/SAR_FPGA + tool paths (config.yaml)
set here "$SAR_FPGA"

catch { create_links -hdl_source "$here/axi4_regslice.v" }
build_design_hierarchy
catch { create_hdl_core -file "$here/axi4_regslice.v" -module {axi4_regslice} -library {work} }

# ---- S_AXI: AXI4 slave (upstream / existing initiator side) ----
catch { hdl_core_add_bif -hdl_core_name {axi4_regslice} -bif_definition {AXI4:AMBA:AMBA4:slave} -bif_name {S_AXI} -signal_map {} }
foreach {b c} {
    ARADDR  S_AXI_ARADDR   ARBURST S_AXI_ARBURST  ARCACHE S_AXI_ARCACHE
    ARID    S_AXI_ARID     ARLEN   S_AXI_ARLEN    ARLOCK  S_AXI_ARLOCK
    ARPROT  S_AXI_ARPROT   ARQOS   S_AXI_ARQOS    ARREADY S_AXI_ARREADY
    ARREGION S_AXI_ARREGION ARSIZE S_AXI_ARSIZE   ARUSER  S_AXI_ARUSER
    ARVALID S_AXI_ARVALID
    AWADDR  S_AXI_AWADDR   AWBURST S_AXI_AWBURST  AWCACHE S_AXI_AWCACHE
    AWID    S_AXI_AWID     AWLEN   S_AXI_AWLEN    AWLOCK  S_AXI_AWLOCK
    AWPROT  S_AXI_AWPROT   AWQOS   S_AXI_AWQOS    AWREADY S_AXI_AWREADY
    AWREGION S_AXI_AWREGION AWSIZE S_AXI_AWSIZE   AWUSER  S_AXI_AWUSER
    AWVALID S_AXI_AWVALID
    BID     S_AXI_BID      BREADY  S_AXI_BREADY   BRESP   S_AXI_BRESP
    BVALID  S_AXI_BVALID
    RDATA   S_AXI_RDATA    RID     S_AXI_RID      RLAST   S_AXI_RLAST
    RREADY  S_AXI_RREADY   RRESP   S_AXI_RRESP    RVALID  S_AXI_RVALID
    WDATA   S_AXI_WDATA    WLAST   S_AXI_WLAST    WREADY  S_AXI_WREADY
    WSTRB   S_AXI_WSTRB    WUSER   S_AXI_WUSER    WVALID  S_AXI_WVALID
} { catch { hdl_core_assign_bif_signal -hdl_core_name {axi4_regslice} -bif_name {S_AXI} -bif_signal_name $b -core_signal_name $c } }

# ---- M_AXI: AXI4 master (downstream / existing target side) ----
catch { hdl_core_add_bif -hdl_core_name {axi4_regslice} -bif_definition {AXI4:AMBA:AMBA4:master} -bif_name {M_AXI} -signal_map {} }
foreach {b c} {
    ARADDR  M_AXI_ARADDR   ARBURST M_AXI_ARBURST  ARCACHE M_AXI_ARCACHE
    ARID    M_AXI_ARID     ARLEN   M_AXI_ARLEN    ARLOCK  M_AXI_ARLOCK
    ARPROT  M_AXI_ARPROT   ARQOS   M_AXI_ARQOS    ARREADY M_AXI_ARREADY
    ARREGION M_AXI_ARREGION ARSIZE M_AXI_ARSIZE   ARUSER  M_AXI_ARUSER
    ARVALID M_AXI_ARVALID
    AWADDR  M_AXI_AWADDR   AWBURST M_AXI_AWBURST  AWCACHE M_AXI_AWCACHE
    AWID    M_AXI_AWID     AWLEN   M_AXI_AWLEN    AWLOCK  M_AXI_AWLOCK
    AWPROT  M_AXI_AWPROT   AWQOS   M_AXI_AWQOS    AWREADY M_AXI_AWREADY
    AWREGION M_AXI_AWREGION AWSIZE M_AXI_AWSIZE   AWUSER  M_AXI_AWUSER
    AWVALID M_AXI_AWVALID
    BID     M_AXI_BID      BREADY  M_AXI_BREADY   BRESP   M_AXI_BRESP
    BVALID  M_AXI_BVALID
    RDATA   M_AXI_RDATA    RID     M_AXI_RID      RLAST   M_AXI_RLAST
    RREADY  M_AXI_RREADY   RRESP   M_AXI_RRESP    RVALID  M_AXI_RVALID
    WDATA   M_AXI_WDATA    WLAST   M_AXI_WLAST    WREADY  M_AXI_WREADY
    WSTRB   M_AXI_WSTRB    WUSER   M_AXI_WUSER    WVALID  M_AXI_WVALID
} { catch { hdl_core_assign_bif_signal -hdl_core_name {axi4_regslice} -bif_name {M_AXI} -bif_signal_name $b -core_signal_name $c } }

build_design_hierarchy
puts "AXI4_REGSLICE_CORE_DONE"

# ---------------------------------------------------------------------------------------------
# NET-LEVEL REWIRING NEEDED AT BUILD TIME (read sartop_assembly.tcl before doing this -- current
# topology reproduced here for reference):
#
#   DIC-side (data plane, kernel masters -> FIC0), the single highest-leverage point:
#     TODAY:  DIC:AXI4mtarget0 <-------------------------------------> ID_FIX:S_AXI
#     AFTER:  DIC:AXI4mtarget0 <-> RS_DIC:S_AXI   RS_DIC:M_AXI <-> ID_FIX:S_AXI
#     Params for this instance: ID_WIDTH=11, ADDR_WIDTH=32, DATA_WIDTH=64 (matches
#     sar_axi_idconv.v's S_AXI exactly -- this link carries the arbitrated output of all 6 DIC
#     initiators (CT/WIN/DET/RES/FEED/UNLD), which is where the "rdata_interleave_fifo" critical
#     path was measured, so it is the single point that covers all 6 masters at once).
#     In SmartDesign: delete the DIC:AXI4mtarget0<->ID_FIX:S_AXI connection, instantiate
#     axi4_regslice as RS_DIC, drag DIC:AXI4mtarget0 -> RS_DIC:S_AXI and RS_DIC:M_AXI ->
#     ID_FIX:S_AXI, connect RS_DIC:ACLK/ARESETN like every other block in sartop_assembly.tcl's
#     clock/reset fanout.
#
#   CIC-side (control plane, FIC0 -> kernel registers), the single highest-leverage point:
#     TODAY:  MSS:FIC_0_AXI4_INITIATOR <---------------------------> CIC:AXI4minitiator0
#     AFTER:  MSS:FIC_0_AXI4_INITIATOR <-> RS_CIC:S_AXI   RS_CIC:M_AXI <-> CIC:AXI4minitiator0
#     Params for this instance: ID_WIDTH=4, ADDR_WIDTH=38 (matches MSS FIC_0_AXI4_INITIATOR,
#     same widths as ID_FIX:M_AXI in sar_axi_idconv.v), DATA_WIDTH=64. This is the single point
#     upstream of the "IntrConvertor_loop[0]" per-target logic inside CIC, so one slice here
#     covers all 6 CIC targets (CT/WIN/DET/RES/FEED/UNLD) instead of needing 6 instances.
#
#   FALLBACK if a single slice per boundary does not buy enough margin: the same core can be
#   dropped onto the 6 individual DIC-initiator links (kernel:axi4initiator <-> DIC:AXI4minitiatorN,
#   reduced field set -- match whatever ARID/ARLOCK/etc. fields that particular kernel wrapper
#   actually drives, e.g. fft_feeder_top.v's axi4initiator omits ARID/ARLOCK/ARCACHE/ARPROT/
#   ARQOS/ARREGION/ARUSER) and/or the 6 individual CIC-target links (CIC:AXI4mtargetN <->
#   kernel:axi4target) instead of/in addition to the two single-point instances above -- same
#   core, same registration script, different per-instance widths and DEPTH.
#
#   In all cases: do NOT change DIC's or CIC's own configuration, and do NOT change how many
#   targets/initiators either interconnect exposes -- the slice only sits on an EXISTING
#   point-to-point link.
