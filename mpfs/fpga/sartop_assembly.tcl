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
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {resample_top}             -instance_name {RES}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {fft_feeder_top}           -instance_name {FEED}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {corefft_stream64_adapter} -instance_name {GBX}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {sar_axi_idconv}           -instance_name {ID_FIX}
## =====================================================================================
## SECOND CoreFFT CHAIN (2026-07-25) -- FFT_B + GBX_B + FEED_B + UNLD_B + COEFG_B.
##
## WHY: a pass's rows are INDEPENDENT (each row is its own 8192-pt transform with its own BFP
## exponent), and one chain leaves the shared FIC_0 read slot 92.5% idle -- measured on silicon
## with the fabric coefficient generator on: READ_BUSY 2,862 + R_DATAWAIT 3,762 of ELAPSED 88,231
## cycles for one FFT-1 row = 7.5% read-channel occupancy, 45 AR bursts averaging 182 beats. Two
## chains therefore need ~15% of the slot. The two PASSES cannot overlap (FFT-2 consumes the
## corner-turn of FFT-1's output), so splitting ROWS WITHIN a pass is the only available form.
##
## THE TWO INSTANCES WIN AND RES2 ARE RECLAIMED, NOT ADDED TO. That keeps the DIC at
## NUM_INITIATORS=6 / NUM_INITIATORS_WIDTH=3, so sar_axi_idconv.v:145,153 still forwards a 3-bit
## master_number into FIC_0's 4-bit ARID/AWID with nothing truncated, and the AXIIC_C0 arbiter/mux
## does not widen at all (see axiic_c0_params_330.tcl -- UNCHANGED by this design).
##   WIN  (initiator1 / CIC target1) : the 2-D Hamming window has been fused into fft_feeder_v.v
##                                     since 2026-07-21; window_top has had no firmware user since.
##   RES2 (initiator2 / CIC target2) : the 2-lane range gather. Silicon 2026-07-25: 4.85 s vs 5.78 s
##                                     but 99.64% of a 1024x1024 ROI wrong (openspec
##                                     add-res2-dual-lane-gather/tasks.md -- verdict DO NOT COMMIT).
##                                     The firmware lane is removed with it in this change.
## FEED_B takes initiator1/target1 (read-only master, exactly like FEED on initiator4) and UNLD_B
## takes initiator2/target2 (write-only, exactly like UNLD on initiator5). Every OTHER kernel keeps
## its address, so no firmware or host script address moves.
##
## FFT_B is a SECOND INSTANCE of the SAME COREFFT_C0 component, not a second component: identical
## configuration is then structural, not a copied parameter list that can drift.
sd_instantiate_component -sd_name $sd -component_name {COREFFT_C0}   -instance_name {FFT_B}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {corefft_stream64_adapter} -instance_name {GBX_B}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {fft_feeder_top}           -instance_name {FEED_B}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {fft_unloader_top}         -instance_name {UNLD_B}
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
## COEFG: on-fabric azimuth resample coefficient generator (NEW 8th CIC target @ 0x6000_7000, see
## sar_coeffgen.v / sar_coeffgen_core.tcl / axiic_ctrl_params.tcl TARGET7). Hand-written Verilog,
## NOT SmartHLS. It has NO AXI4 initiator at all -- it consumes ZERO DIC initiator ports; its only
## data-plane connection is the {m_idx,m_wq,m_valid,m_ready} stream straight into FEED (below).
## It replaces 1499 us/row of CPU coefficient generation with ~147 us/row in fabric AND deletes
## FEED's idx+wq DDR load passes (6144 of 8961 read beats/row). Runtime-gated at FEED reg 0x20
## bit1, DEFAULT OFF -- this build is behaviour-neutral until the firmware sets it.
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {sar_coeffgen}             -instance_name {COEFG}
## COEFG_B: the SECOND chain's coefficient generator, a full 2nd instance (NEW 9th CIC target
## @0x6000_8000, axiic_ctrl_params.tcl TARGET8). The two chains process DIFFERENT rows at the same
## time and a row's coefficients depend on the scalar KR[j], so they need two INDEPENDENT streams.
##
## WHY A FULL SECOND INSTANCE AND NOT A SHARED TABLE STORE (tan_s/inv_tan/KC are row-invariant, so
## sharing is arithmetically legal): sharing would need ONE WRITE + TWO READ ports on each 8192x32
## table. PolarFire LSRAM gives 1W+1R (two-port) or 2 x R/W (dual-port); a 1W2R array is mapped by
## REPLICATION unless the tool chooses to fold the write onto one dual-port port, and THIS DESIGN
## ALREADY HAS THE COUNTEREXAMPLE: fft_feeder_v.v:642 adds a second reader to `wtab` and the
## comment records that synthesis replicates it. A shared store would therefore very likely cost
## the SAME 96 blocks while adding a long cross-module RAM read path onto COEFG/u_mul_fr -- which
## is the design's critical path at +0.266 ns. Betting the LSRAM budget on an inference nobody can
## verify without a synthesis run is exactly how the last coeffgen estimate came in 50 blocks
## optimistic. Two instances cost a deterministic +48 LSRAM and replicate the critical path rather
## than lengthening it.
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {sar_coeffgen}             -instance_name {COEFG_B}

## ---------------- clocks ----------------
sd_create_scalar_port -sd_name $sd -port_name {REF_CLK_50MHz} -port_direction {IN}
sd_instantiate_macro -sd_name $sd -macro_name {CLKINT} -instance_name {CLKREF}
catch { sd_connect_pins -sd_name $sd -pin_names {"REF_CLK_50MHz" "CLKREF:A"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CLKREF:Y" "CCC:REF_CLK_0"} }
sd_connect_pins -sd_name $sd -pin_names {"CCC:OUT0_FABCLK_0" \
    "MSS:FIC_0_ACLK" "DIC:ACLK" "CIC:ACLK" "UNLD:clk" "FFT:CLK" "GBX:clk" \
    "CT:clk" "RES:clk" "FEED:clk" "RST:CLK" "ID_FIX:ACLK" \
    "RSLICE_DIC:ACLK" "RSLICE_CIC:ACLK" "FIC0MON:aclk" "COEFG:clk" \
    "UNLD_B:clk" "FFT_B:CLK" "GBX_B:clk" "FEED_B:clk" "COEFG_B:clk"}
## BOTH CoreFFT instances take the SAME OUT1 SLOWCLK. constraints/sar_fft_cdc.sdc declares the
## OUT0<->OUT1 false paths clock-to-clock (not per instance), so it already covers FFT_B.
catch { sd_connect_pins -sd_name $sd -pin_names {"CCC:OUT1_FABCLK_0" "FFT:SLOWCLK" "FFT_B:SLOWCLK"} }

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
    "RSLICE_DIC:ARESETN" "RSLICE_CIC:ARESETN" "FIC0MON:aresetn" "COEFG:resetn" \
    "FFT_B:NGRST" "GBX_B:resetn" "COEFG_B:resetn"}
## UNLD (HLS kernel) uses an active-high synchronous reset -> invert FABRIC_RESET_N like the other kernels.
foreach k {CT RES FEED UNLD FEED_B UNLD_B} {
    sd_invert_pins -sd_name $sd -pin_names "${k}:reset"
    sd_connect_pins -sd_name $sd -pin_names "RST:FABRIC_RESET_N ${k}:reset"
}

## ---------------- data plane (AXIIC 3.0.130): 6 initiators -> DIC -> ID_FIX -> MSS FIC0 ----------------
## STILL SIX. Slots 1 and 2 are RECLAIMED from the dead WIN/RES2 kernels for the second chain, so
## NUM_INITIATORS stays 6 and NUM_INITIATORS_WIDTH stays 3 -- the 8-master ceiling that
## sar_axi_idconv.v:145,153 imposes (master_number[2:0] -> FIC_0's 4-bit ARID/AWID) is not
## approached, and axiic_c0_params_330.tcl needs NO change at all.
##   0 CT      read+write   corner turn
##   1 FEED_B  read-only    2nd chain feeder   (was WIN,  dead: window fused into the feeder)
##   2 UNLD_B  write-only   2nd chain unloader (was RES2, dead: reverted dual-lane resample)
##   3 RES     read+write   resample
##   4 FEED    read-only    1st chain feeder
##   5 UNLD    write-only   1st chain unloader
## SASD IS UNTOUCHED (CROSSBAR_MODE:0, OPEN_TRANS_MAX:1, NUM_THREADS:1, READ_INTERLEAVE:false).
## Both feeders tie m_arid to 0 (fft_feeder_top.v:120 leaves .m_arid() open, fft_feeder_v.v:382
## drives zero) and are safe ONLY because SASD permits one outstanding read interconnect-wide.
## Do NOT add read parallelism to SASD in the same change as a second ID-less read master.
catch { sd_connect_pins -sd_name $sd -pin_names {"CT:axi4initiator"        "DIC:AXI4minitiator0"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FEED_B:axi4initiator"    "DIC:AXI4minitiator1"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"UNLD_B:axi4initiator"    "DIC:AXI4minitiator2"} }
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

## ---------------- control plane (AXIIC 3.0.130): FIC0 initiator -> CIC -> 8 targets ----------------
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
## Targets 1 and 2 are REUSED IN PLACE (see the instantiate block): FEED_B @0x60001000 and
## UNLD_B @0x60002000. Reported, not bare-catch -- these two are the connections a silent failure
## would leave dangling, and a dangling target bif promotes the whole interface to top-level I/O
## (the 144-pin synthesis failure documented at RSLICE_CIC below).
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget0" "CT:axi4target"} }
if {[catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget1" "FEED_B:axi4target"} } err]} { puts "FEEDB_CTRL_CONNECT_FAIL : $err" } else { puts "FEEDB_CTRL_CONNECT_OK" }
if {[catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget2" "UNLD_B:axi4target"} } err]} { puts "UNLDB_CTRL_CONNECT_FAIL : $err" } else { puts "UNLDB_CTRL_CONNECT_OK" }
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
## v2 (2026-07-24): WRITE-channel taps -- same ID_FIX:M_AXI boundary, observe-only. Lets the monitor
## separate write time from intra-burst read throttle in the gather stall (see sar_fic0s_mon.v v2 map).
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWVALID" "FIC0MON:mon_awvalid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWREADY" "FIC0MON:mon_awready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WVALID"  "FIC0MON:mon_wvalid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WREADY"  "FIC0MON:mon_wready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_WLAST"   "FIC0MON:mon_wlast"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_BVALID"  "FIC0MON:mon_bvalid"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_BREADY"  "FIC0MON:mon_bready"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_BRESP"   "FIC0MON:mon_bresp"} }

## target7 (NEW): sar_coeffgen, TYPE:1/AXI4-Lite (axiic_ctrl_params.tcl TARGET7, NUM_TARGETS:8)
## -> control + table-load regs @ 0x60007000. Same "AXI4Lmtarget<n>" (with an L) pin naming as
## target6 -- a Lite-typed target is a narrower CoreAXI4Interconnect bus interface (no ID/LEN/
## BURST/WSTRB/xLAST), which matches sar_coeffgen.v's s_* port set with no dangling signals.
## REPORTED, not bare-catch: a silently failed connect leaves a dangling interface and a netlist
## that differs from the one this script claims to build (the lesson behind the RSLICE puts below).
if {[catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4Lmtarget7" "COEFG:s_axi"} } err]} { puts "COEFG_CTRL_CONNECT_FAIL : $err" } else { puts "COEFG_CTRL_CONNECT_OK" }
## target8 (NEW): COEFG_B, the 2nd chain's coefficient generator @0x6000_8000. Same AXI4-Lite
## ("AXI4Lmtarget<n>", with an L) typing as targets 6/7 -- it is the same sar_coeffgen core.
if {[catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4Lmtarget8" "COEFG_B:s_axi"} } err]} { puts "COEFGB_CTRL_CONNECT_FAIL : $err" } else { puts "COEFGB_CTRL_CONNECT_OK" }

## =====================================================================================
## PER-CHAIN WIRING -- CoreFFT streaming path, SCALE_EXP capture, coefficient stream.
##
## Written as ONE loop over the two chains so chain B's wiring is LITERALLY the same code as
## chain A's with a different instance quadruple. That is deliberate and is the whole point:
##
##   H-2 / SCALE_EXP.  fft_feeder_v.v:149-155 latches SCALE_EXP on the FALLING edge of
##   OUTP_READY and holds it only until the next frame. `FFT_x:SCALE_EXP -> FEED_x:scale_exp_in`
##   and `FFT_x:OUTP_READY -> FEED_x:outp_ready_in` MUST come from the SAME chain. A cross-wire
##   (FFT_B's exponent latched into FEED, say) is invisible to synthesis, invisible to timing,
##   and invisible to a correlation check -- it produces a smooth, wrong-brightness image,
##   because the firmware renormalizes each row by >>(emax - exp_row) with the WRONG exp_row.
##   A hand-copied second block of 15 connect lines is exactly how that typo gets made; a loop
##   over {FFT GBX FEED UNLD COEFG} / {FFT_B GBX_B FEED_B UNLD_B COEFG_B} cannot make it.
##
##   Reported, not bare-catch, for the same reason: a silently failed connect leaves a dangling
##   pin and a netlist that differs from the one this script claims to have built.
##
## The two chains share NOTHING on the data plane except DDR itself (disjoint rows -- chain A
## writes dst + 2k*32768, chain B dst + (2k+1)*32768) and the FIC_0 read slot.
## =====================================================================================
foreach {F G FD U CG} {
    FFT   GBX   FEED   UNLD   COEFG
    FFT_B GBX_B FEED_B UNLD_B COEFG_B
} {
    foreach {a b} [list \
        "$FD:out_var"       "$G:s_axis_tdata" \
        "$FD:out_var_valid" "$G:s_axis_tvalid" \
        "$FD:out_var_ready" "$G:s_axis_tready" \
        "$G:datai_re"       "$F:DATAI_RE" \
        "$G:datai_im"       "$F:DATAI_IM" \
        "$G:datai_valid"    "$F:DATAI_VALID" \
        "$F:BUF_READY"      "$G:buf_ready" \
        "$F:DATAO_RE"       "$G:datao_re" \
        "$F:DATAO_IM"       "$G:datao_im" \
        "$F:DATAO_VALID"    "$G:datao_valid" \
        "$F:OUTP_READY"     "$G:outp_ready" \
        "$G:read_outp"      "$F:READ_OUTP" \
    ] { if {[catch { sd_connect_pins -sd_name $sd -pin_names "$a $b" } err]} { puts "CHAIN_CONNECT_FAIL $a $b : $err" } else { puts "CHAIN_CONNECT_OK $a $b" } }

    ## CoreFFT block-floating-point exponent -> THIS chain's feeder capture register (0x14), and
    ## OUTP_READY fanned out to it as the frame-boundary strobe (falling edge = latch).
    ## The firmware reads each row's exponent to reconstruct the CPU FFT's GLOBAL block exponent
    ## (emax = max over sar_row_exp[], then Output[i] >>= emax-exp_i). emax is a MAX, so it is
    ## order- and partition-independent -- which is precisely why splitting rows across two chains
    ## is bit-exact, PROVIDED each chain latches its OWN row's exponent from its OWN CoreFFT.
    foreach {a b} [list \
        "$F:SCALE_EXP"  "$FD:scale_exp_in" \
        "$F:OUTP_READY" "$FD:outp_ready_in" \
    ] { if {[catch { sd_connect_pins -sd_name $sd -pin_names "$a $b" } err]} { puts "SCALEEXP_CONNECT_FAIL $a $b : $err" } else { puts "SCALEEXP_CONNECT_OK $a $b" } }

    ## CoreFFT output stream (gearbox 64-bit master) -> fft_unloader AXI4-Stream SLAVE. The unloader
    ## drains the WHOLE frame in one continuous run (no descriptors, no per-transform re-arm, no
    ## TLAST), so there is never a "2nd back-to-back transaction" for a stream target FSM to
    ## deadlock on. TLAST/TDEST were DMA-framing only; the unloader ignores them.
    foreach {a b} [list \
        "$G:m_axis_tdata"  "$U:in_var" \
        "$G:m_axis_tvalid" "$U:in_var_valid" \
        "$U:in_var_ready"  "$G:m_axis_tready" \
    ] { if {[catch { sd_connect_pins -sd_name $sd -pin_names "$a $b" } err]} { puts "CHAIN_CONNECT_FAIL $a $b : $err" } else { puts "CHAIN_CONNECT_OK $a $b" } }
    catch { sd_mark_pins_unused -sd_name $sd -pin_names "$G:m_axis_tlast" }
    catch { sd_mark_pins_unused -sd_name $sd -pin_names "$G:m_axis_tdest" }

    ## COEFG -> FEED coefficient stream, plain pins (no bus interface on either side, exactly like
    ## SCALE_EXP above). This is the ONLY data-plane connection a generator has: no FIC, no AXI4
    ## initiator, no DIC port, nothing added to the FIC_0 read path. The feeder consumes it only
    ## when its GATHER_CTRL (0x20) bit1 is set; bit1 is 0 out of reset, so an unconsumed stream
    ## simply back-pressures and the feeder behaves exactly as it does today.
    foreach {a b} [list \
        "$CG:m_idx"   "$FD:c_idx" \
        "$CG:m_wq"    "$FD:c_wq" \
        "$CG:m_valid" "$FD:c_valid" \
        "$CG:m_ready" "$FD:c_ready" \
    ] { if {[catch { sd_connect_pins -sd_name $sd -pin_names "$a $b" } err]} { puts "COEFG_STREAM_CONNECT_FAIL $a $b : $err" } else { puts "COEFG_STREAM_CONNECT_OK $a $b" } }
}

## ---------------- misc + MSS ----------------
## (FFT:SCALE_EXP -> FEED:scale_exp_in now lives in the per-chain loop above, together with
## FFT_B:SCALE_EXP -> FEED_B:scale_exp_in, so the two chains cannot be cross-wired.)
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
