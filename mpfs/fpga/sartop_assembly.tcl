set sd SAR_TOP
catch {delete_component -component_name $sd}
create_smartdesign -sd_name $sd

## ---------------- instantiate ----------------
sd_instantiate_component -sd_name $sd -component_name {ICICLE_MSS}   -instance_name {MSS}
sd_instantiate_component -sd_name $sd -component_name {PF_CCC_C0}    -instance_name {CCC}
sd_instantiate_component -sd_name $sd -component_name {CORERESET_C0} -instance_name {RST}
sd_instantiate_component -sd_name $sd -component_name {AXIIC_C0}     -instance_name {DIC}
sd_instantiate_component -sd_name $sd -component_name {AXIIC_CTRL}   -instance_name {CIC}
sd_instantiate_component -sd_name $sd -component_name {COREFFT_C0}   -instance_name {FFT}
## UNLD = fft_unloader HLS kernel: drains the CoreFFT->gearbox output stream to DDR via a plain
## AXI4 write master. Replaces the deadlocking CoreAXI4DMAController (AXIDMA_C0) S2MM stream target.
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {fft_unloader_top}          -instance_name {UNLD}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {corner_turn_top}          -instance_name {CT}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {window_top}               -instance_name {WIN}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {detect_top}               -instance_name {DET}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {resample_top}             -instance_name {RES}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {fft_feeder_top}           -instance_name {FEED}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {corefft_stream64_adapter} -instance_name {GBX}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {sar_axi_idconv}           -instance_name {ID_FIX}
## RSLICE_DIC/RSLICE_CIC: ONE axi4_regslice HDL+ core, TWO instances (timing fix -- see
## axi4_regslice_core.tcl / axi4_regslice.v headers). RSLICE_DIC sits on the existing
## DIC:AXI4mtarget0<->ID_FIX:S_AXI link (11-bit ID/32-bit addr, matches ID_FIX:S_AXI exactly).
## RSLICE_CIC sits on the existing MSS:FIC_0_AXI4_INITIATOR<->CIC:AXI4minitiator0 link:
## ID_WIDTH=8 (NOT 4 -- verified against ICICLE_MSS.v's own port decl, FIC_0_AXI4_M_ARID/AWID
## are [7:0]; the task brief's "ID_WIDTH=4" conflated this control-plane FIC_0_AXI4_M/INITIATOR
## port with the DATA-plane FIC_0_AXI4_S port that sar_axi_idconv.v converts down to 4 bits --
## those are two different MSS FIC0 ports/widths. CIC's own INITIATOR0_ARID/AWID are also
## [7:0], so ID_WIDTH=8 here reproduces the interconnect's existing zero-ID-loss behavior;
## ID_WIDTH=4 would have silently truncated 4 real ID bits that the interconnect itself does
## NOT truncate today), ADDR_WIDTH=38 (matches MSS; CIC's own INITIATOR0_ARADDR is only
## 32-bit, so the existing 38->32 address truncation at the interconnect boundary is
## unchanged/pre-existing, not something this slice introduces), DATA_WIDTH=64.
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {axi4_regslice}            -instance_name {RSLICE_DIC}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {axi4_regslice}            -instance_name {RSLICE_CIC}
catch { sd_configure_core_instance -sd_name $sd -instance_name {RSLICE_DIC} -params {"ID_WIDTH:11" "ADDR_WIDTH:32" "DATA_WIDTH:64"} }
catch { sd_update_instance -sd_name $sd -instance_name {RSLICE_DIC} }
catch { sd_configure_core_instance -sd_name $sd -instance_name {RSLICE_CIC} -params {"ID_WIDTH:8" "ADDR_WIDTH:38" "DATA_WIDTH:64" "LOCK_WIDTH:1"} }
catch { sd_update_instance -sd_name $sd -instance_name {RSLICE_CIC} }
## FIC0MON: FIC_0_AXI4_S transaction monitor (new 7th CIC target @ 0x6000_6000, see
## sar_fic0s_mon.v / sar_fic0s_mon_core.tcl / axiic_ctrl_params.tcl TARGET6).
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {sar_fic0s_mon}            -instance_name {FIC0MON}

## ---------------- clocks ----------------
sd_create_scalar_port -sd_name $sd -port_name {REF_CLK_50MHz} -port_direction {IN}
sd_instantiate_macro -sd_name $sd -macro_name {CLKINT} -instance_name {CLKREF}
catch { sd_connect_pins -sd_name $sd -pin_names {"REF_CLK_50MHz" "CLKREF:A"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CLKREF:Y" "CCC:REF_CLK_0"} }
sd_connect_pins -sd_name $sd -pin_names {"CCC:OUT0_FABCLK_0" \
    "MSS:FIC_0_ACLK" "DIC:ACLK" "CIC:ACLK" "UNLD:clk" "FFT:CLK" "GBX:clk" \
    "CT:clk" "WIN:clk" "DET:clk" "RES:clk" "FEED:clk" "RST:CLK" "ID_FIX:ACLK" \
    "RSLICE_DIC:ACLK" "RSLICE_CIC:ACLK" "FIC0MON:aclk"}
catch { sd_connect_pins -sd_name $sd -pin_names {"CCC:OUT1_FABCLK_0" "FFT:SLOWCLK"} }

## ---------------- reset (CORERESET_PF) ----------------
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {RST:BANK_x_VDDI_STATUS} -value {VCC} }
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {RST:BANK_y_VDDI_STATUS} -value {VCC} }
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {RST:SS_BUSY}            -value {GND} }
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {RST:FF_US_RESTORE}      -value {GND} }
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {RST:INIT_DONE}          -value {VCC} }
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {RST:FPGA_POR_N}         -value {VCC} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CCC:PLL_LOCK_0"        "RST:PLL_LOCK"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"RST:PLL_POWERDOWN_B"   "CCC:PLL_POWERDOWN_N_0"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"MSS:MSS_RESET_N_M2F"   "RST:EXT_RST_N"} }
sd_connect_pins -sd_name $sd -pin_names {"RST:FABRIC_RESET_N" \
    "FFT:NGRST" "DIC:ARESETN" "CIC:ARESETN" "GBX:resetn" "ID_FIX:ARESETN" \
    "RSLICE_DIC:ARESETN" "RSLICE_CIC:ARESETN" "FIC0MON:aresetn"}
## UNLD (HLS kernel) uses an active-high synchronous reset -> invert FABRIC_RESET_N like the other kernels.
foreach k {CT WIN DET RES FEED UNLD} {
    sd_invert_pins -sd_name $sd -pin_names "${k}:reset"
    sd_connect_pins -sd_name $sd -pin_names "RST:FABRIC_RESET_N ${k}:reset"
}

## ---------------- data plane (AXIIC 3.0.130): 6 initiators -> DIC -> ID_FIX -> MSS FIC0 ----------------
catch { sd_connect_pins -sd_name $sd -pin_names {"CT:axi4initiator"        "DIC:AXI4minitiator0"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"WIN:axi4initiator"       "DIC:AXI4minitiator1"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"DET:axi4initiator"       "DIC:AXI4minitiator2"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"RES:axi4initiator"       "DIC:AXI4minitiator3"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FEED:axi4initiator"      "DIC:AXI4minitiator4"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"UNLD:axi4initiator"      "DIC:AXI4minitiator5"} }
## RSLICE_DIC inline register slice (timing fix, see axi4_regslice.v header): rewire the
## former direct DIC:AXI4mtarget0<->ID_FIX:S_AXI connection through RSLICE_DIC.
## DIC:AXI4mtarget0 -> RSLICE_DIC:S_AXI works at INTERFACE level (DirectCore target -> HDL+
## core slave bif, same as the original DIC:AXI4mtarget0<->ID_FIX:S_AXI connect it replaces).
if {[catch { sd_connect_pins -sd_name $sd -pin_names {"DIC:AXI4mtarget0" "RSLICE_DIC:S_AXI"} } err]} { puts "DIC_RSLICE_CONNECT_FAIL : $err" } else { puts "DIC_RSLICE_CONNECT_OK" }
## RSLICE_DIC:M_AXI -> ID_FIX:S_AXI is HDL+-core-to-HDL+-core: Libero's interface-level bif
## connect rejects this pair ("not compatible") even though every field/width matches
## byte-for-byte (confirmed on a real build attempt) -- same "bus-interface metadata differs"
## trap already documented for ID_FIX:M_AXI<->MSS:FIC_0_AXI4_S below. Fall back to signal level.
foreach {b} {
    AWID AWADDR AWLEN AWSIZE AWBURST AWLOCK AWCACHE AWPROT AWQOS AWREGION AWUSER AWVALID AWREADY
    WDATA WSTRB WLAST WUSER WVALID WREADY
    BID BRESP BVALID BREADY
    ARID ARADDR ARLEN ARSIZE ARBURST ARLOCK ARCACHE ARPROT ARQOS ARREGION ARUSER ARVALID ARREADY
    RID RDATA RRESP RLAST RVALID RREADY
} { if {[catch { sd_connect_pins -sd_name $sd -pin_names "RSLICE_DIC:M_AXI_$b ID_FIX:S_AXI_$b" } err]} { puts "RSLICE_DIC_CONNECT_FAIL $b : $err" } else { puts "RSLICE_DIC_CONNECT_OK $b" } }
## ID_FIX:M_AXI -> MSS FIC_0_AXI4_S at SIGNAL level (interface-metadata incompatible; signals match exactly)
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARADDR" "MSS:FIC_0_AXI4_S_ARADDR"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARBURST" "MSS:FIC_0_AXI4_S_ARBURST"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARCACHE" "MSS:FIC_0_AXI4_S_ARCACHE"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARID" "MSS:FIC_0_AXI4_S_ARID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARLEN" "MSS:FIC_0_AXI4_S_ARLEN"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARLOCK" "MSS:FIC_0_AXI4_S_ARLOCK"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARPROT" "MSS:FIC_0_AXI4_S_ARPROT"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARQOS" "MSS:FIC_0_AXI4_S_ARQOS"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARREADY" "MSS:FIC_0_AXI4_S_ARREADY"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARSIZE" "MSS:FIC_0_AXI4_S_ARSIZE"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARVALID" "MSS:FIC_0_AXI4_S_ARVALID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWADDR" "MSS:FIC_0_AXI4_S_AWADDR"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWBURST" "MSS:FIC_0_AXI4_S_AWBURST"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWCACHE" "MSS:FIC_0_AXI4_S_AWCACHE"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWID" "MSS:FIC_0_AXI4_S_AWID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWLEN" "MSS:FIC_0_AXI4_S_AWLEN"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWLOCK" "MSS:FIC_0_AXI4_S_AWLOCK"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWPROT" "MSS:FIC_0_AXI4_S_AWPROT"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWQOS" "MSS:FIC_0_AXI4_S_AWQOS"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWREADY" "MSS:FIC_0_AXI4_S_AWREADY"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWSIZE" "MSS:FIC_0_AXI4_S_AWSIZE"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWVALID" "MSS:FIC_0_AXI4_S_AWVALID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_BID" "MSS:FIC_0_AXI4_S_BID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_BREADY" "MSS:FIC_0_AXI4_S_BREADY"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_BRESP" "MSS:FIC_0_AXI4_S_BRESP"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_BVALID" "MSS:FIC_0_AXI4_S_BVALID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RDATA" "MSS:FIC_0_AXI4_S_RDATA"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RID" "MSS:FIC_0_AXI4_S_RID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RLAST" "MSS:FIC_0_AXI4_S_RLAST"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RREADY" "MSS:FIC_0_AXI4_S_RREADY"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RRESP" "MSS:FIC_0_AXI4_S_RRESP"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RVALID" "MSS:FIC_0_AXI4_S_RVALID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WDATA" "MSS:FIC_0_AXI4_S_WDATA"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WLAST" "MSS:FIC_0_AXI4_S_WLAST"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WREADY" "MSS:FIC_0_AXI4_S_WREADY"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WSTRB" "MSS:FIC_0_AXI4_S_WSTRB"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WVALID" "MSS:FIC_0_AXI4_S_WVALID"} }

## ---------------- control plane (AXIIC 3.0.130): FIC0 initiator -> CIC -> 7 targets ----------------
## RSLICE_CIC inline register slice (timing fix, see axi4_regslice.v header): rewire the
## former direct MSS:FIC_0_AXI4_INITIATOR<->CIC:AXI4minitiator0 connection through RSLICE_CIC.
## MSS:FIC_0_AXI4_INITIATOR -> RSLICE_CIC:S_AXI: interface-level bif connect is "not
## compatible" here (confirmed on a real build attempt), same trap as ID_FIX:M_AXI<->
## MSS:FIC_0_AXI4_S below -- fall back to signal level. MSS's real Verilog port names for
## this (initiator/master) side are FIC_0_AXI4_M_* (verified in ICICLE_MSS.v; the OTHER FIC0
## port used by the data plane is FIC_0_AXI4_S_*). MSS has no REGION/USER fields on this port
## (same as its FIC_0_AXI4_S side below). AxLOCK is DELIBERATELY OMITTED: MSS's
## FIC_0_AXI4_M_ARLOCK/AWLOCK are true 1-bit SCALARS (no bit range) vs RSLICE_CIC's fixed
## 2-bit S_AXI_ARLOCK/AWLOCK -- unlike the ID/DATA width mismatches elsewhere (which Libero
## pads with a warning), a scalar<->bus connect is a hard "dimension incompatibility" error
## (confirmed on a real build attempt). AXI4 LOCK/exclusive access is unused anywhere in this
## design. FIXED 2026-07-22: LOCK is now INCLUDED. RSLICE_CIC is instantiated with LOCK_WIDTH:1
## (param override above) so its S_AXI_ARLOCK/AWLOCK are 1-bit and connect to MSS's 1-bit
## FIC_0_AXI4_M_ARLOCK/AWLOCK. Leaving them OUT (the earlier attempt) left two dangling signals
## on the MSS:FIC_0_AXI4_INITIATOR bus interface, which made SmartDesign promote the ENTIRE
## interface (37 signals, ~200 bits) to top-level I/O -> 321 I/O modules vs the 144-pin limit ->
## synthesis "Number of I/O modules exceeds the limit" failure. Measured: the data-plane
## FIC_0_AXI4_S loop below INCLUDES LOCK and is NOT promoted; this one omitted it and WAS. A
## single dangling bif signal exposes the whole interface.
foreach {b} {
    ARADDR ARBURST ARCACHE ARID ARLEN ARLOCK ARPROT ARQOS ARREADY ARSIZE ARVALID
    AWADDR AWBURST AWCACHE AWID AWLEN AWLOCK AWPROT AWQOS AWREADY AWSIZE AWVALID
    BID BREADY BRESP BVALID
    RDATA RID RLAST RREADY RRESP RVALID
    WDATA WLAST WREADY WSTRB WVALID
} { if {[catch { sd_connect_pins -sd_name $sd -pin_names "MSS:FIC_0_AXI4_M_$b RSLICE_CIC:S_AXI_$b" } err]} { puts "RSLICE_CIC_CONNECT_FAIL $b : $err" } else { puts "RSLICE_CIC_CONNECT_OK $b" } }
if {[catch { sd_connect_pins -sd_name $sd -pin_names {"RSLICE_CIC:M_AXI" "CIC:AXI4minitiator0"} } err]} { puts "RSLICE_CIC_MAXI_CONNECT_FAIL : $err" } else { puts "RSLICE_CIC_MAXI_CONNECT_OK" }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget0" "CT:axi4target"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget1" "WIN:axi4target"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget2" "DET:axi4target"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget3" "RES:axi4target"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget4" "FEED:axi4target"} }
## target5 now a standard AXI4 target (was AXI4Lmtarget5 for the DMA) -> fft_unloader control regs @ 0x60005000
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget5" "UNLD:axi4target"} }
## target6 (NEW): sar_fic0s_mon monitor, TYPE:1/AXI4-Lite (axiic_ctrl_params.tcl) -> control
## regs @ 0x60006000. NOTE the pin is "AXI4Lmtarget6" (with an L), not "AXI4mtarget6" -- a
## Lite-typed target is a genuinely different, narrower CoreAXI4Interconnect bus interface
## (no ID/LEN/BURST/WSTRB/xLAST), verified against a scratch-generated netlist to match
## sar_fic0s_mon.v's s_axi_* port set with zero dangling signals on either side.
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4Lmtarget6" "FIC0MON:s_axi"} }
## FIC0MON observe-only taps: AFTER ID_FIX (== MSS:FIC_0_AXI4_S, same net, signal-level-
## connected above) rather than the module header's guessed pre-idconv "DIC_AXI4mslave0_*"
## names. mon_araddr[37:0]/mon_arid[3:0] match ID_FIX:M_AXI_ARADDR/ARID (== MSS FIC_0_AXI4_S,
## 38-bit addr/4-bit ID) exactly with zero adaptation; the pre-idconv DIC:AXI4mtarget0 side is
## 11-bit ID/32-bit addr, a real width mismatch against sar_fic0s_mon.v's ports. Verified from
## sar_axi_idconv.v's own port declarations, not the header's guessed names.
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARVALID" "FIC0MON:mon_arvalid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARREADY" "FIC0MON:mon_arready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARADDR"  "FIC0MON:mon_araddr"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARID"    "FIC0MON:mon_arid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_ARLEN"   "FIC0MON:mon_arlen"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RVALID"  "FIC0MON:mon_rvalid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RREADY"  "FIC0MON:mon_rready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RRESP"   "FIC0MON:mon_rresp"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RID"     "FIC0MON:mon_rid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_RLAST"   "FIC0MON:mon_rlast"} }

## ---------------- CoreFFT streaming path ----------------
catch { sd_connect_pins -sd_name $sd -pin_names {"FEED:out_var"       "GBX:s_axis_tdata"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FEED:out_var_valid" "GBX:s_axis_tvalid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FEED:out_var_ready" "GBX:s_axis_tready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"GBX:datai_re"    "FFT:DATAI_RE"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"GBX:datai_im"    "FFT:DATAI_IM"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"GBX:datai_valid" "FFT:DATAI_VALID"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FFT:BUF_READY"   "GBX:buf_ready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FFT:DATAO_RE"    "GBX:datao_re"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FFT:DATAO_IM"    "GBX:datao_im"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FFT:DATAO_VALID" "GBX:datao_valid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FFT:OUTP_READY"  "GBX:outp_ready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"GBX:read_outp"   "FFT:READ_OUTP"} }
## fan OUTP_READY out to the feeder too: it latches SCALE_EXP on OUTP_READY's falling edge
## (frame boundary) so the CPU can read each row's block exponent for the global renormalize.
catch { sd_connect_pins -sd_name $sd -pin_names {"FFT:OUTP_READY"  "FEED:outp_ready_in"} }
## CoreFFT output stream (gearbox 64-bit master) -> fft_unloader AXI4-Stream SLAVE. The unloader
## drains the WHOLE frame in one continuous run (no descriptors, no per-transform re-arm, no TLAST),
## so there is never a "2nd back-to-back transaction" for a stream target FSM to deadlock on.
catch { sd_connect_pins -sd_name $sd -pin_names {"GBX:m_axis_tdata"  "UNLD:in_var"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"GBX:m_axis_tvalid" "UNLD:in_var_valid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"UNLD:in_var_ready" "GBX:m_axis_tready"} }
## TLAST/TDEST were DMA-framing only; the unloader ignores them. Leave the gearbox outputs unused.
catch { sd_mark_pins_unused -sd_name $sd -pin_names {GBX:m_axis_tlast} }
catch { sd_mark_pins_unused -sd_name $sd -pin_names {GBX:m_axis_tdest} }

## ---------------- misc + MSS ----------------
## CoreFFT block-floating-point exponent -> feeder capture register (0x14). Was unused; now the
## firmware reads it per row to reconstruct the CPU FFT's global block exponent (fix the per-row
## BFP that corrupts the 2-D image -- corr~0 -> expect ~0.99 after the global renormalize).
catch { sd_connect_pins -sd_name $sd -pin_names {"FFT:SCALE_EXP" "FEED:scale_exp_in"} }
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {MSS:MSS_INT_F2M} -value {GND} }
sd_mark_pins_unused -sd_name $sd -pin_names {MSS:MSS_INT_M2F}
sd_connect_instance_pins_to_ports -sd_name $sd -instance_name {MSS}

## ---------------- Icicle eMMC/SD demux select (U44/U29 = TS3A27518E) ----------------
## The shared SDMMC controller reaches the on-board eMMC only when the demux is set to
## COM-NC: EN#=L (enabled), IN1=IN2=L. Board pins: SDIO_SW_SEL0=D7, SDIO_SW_SEL1=C7,
## SDIO_SW_EN_N=B7 (100K pulldowns default them low, but our unused-I/O state was not
## letting the pulldowns win -> eMMC silent). We only ever use eMMC, so tie all three
## LOW from the fabric. (SD would need these = 1,1,0.) See ICICLE_SDIO.pdc for pins.
sd_create_scalar_port -sd_name $sd -port_name {SDIO_SW_SEL0} -port_direction {OUT}
sd_create_scalar_port -sd_name $sd -port_name {SDIO_SW_SEL1} -port_direction {OUT}
sd_create_scalar_port -sd_name $sd -port_name {SDIO_SW_EN_N} -port_direction {OUT}
sd_connect_pins_to_constant -sd_name $sd -pin_names {SDIO_SW_SEL0} -value {GND}
sd_connect_pins_to_constant -sd_name $sd -pin_names {SDIO_SW_SEL1} -value {GND}
sd_connect_pins_to_constant -sd_name $sd -pin_names {SDIO_SW_EN_N} -value {GND}

## ---------------- generate ----------------
save_smartdesign -sd_name $sd
generate_component -component_name $sd
save_project
puts "SARTOP330_DONE"
