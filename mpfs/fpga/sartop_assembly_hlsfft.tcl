## sartop_assembly_hlsfft.tcl -- SAR_TOP wiring with the HLS fft_kernel REPLACING the entire
## CoreFFT streaming chain (FEED + GBX + COREFFT + UNLD). The HLS FFT is a plain AXI kernel with
## the SAME interface shape as CT/WIN/DET/RES: one axi4initiator (merged read+write master) + one
## axi4target (control). It joins the well-behaved plain-kernel datapath, sidestepping BOTH the
## CoreFFT native-handshake fragility AND the pipeline-context stall that wedged the streaming path.
##
## FFTK sits on DIC:AXI4minitiator4 (data) + CIC:AXI4mtarget4 (control @ 0x60004000). The freed
## port5 on each interconnect is left unused (interconnect config reused unchanged = zero crossbar risk).
## Firmware fft_pass(): src@+0xc, dst@+0x10, nrows@+0x14, start/idle@+8.
##
## Preserves the CoreFFT assembly (sartop_assembly.tcl) untouched as the fallback.
set sd SAR_TOP
catch {delete_component -component_name $sd}
create_smartdesign -sd_name $sd

## ---------------- instantiate ----------------
sd_instantiate_component -sd_name $sd -component_name {ICICLE_MSS}   -instance_name {MSS}
sd_instantiate_component -sd_name $sd -component_name {PF_CCC_C0}    -instance_name {CCC}
sd_instantiate_component -sd_name $sd -component_name {CORERESET_C0} -instance_name {RST}
sd_instantiate_component -sd_name $sd -component_name {AXIIC_C0}     -instance_name {DIC}
sd_instantiate_component -sd_name $sd -component_name {AXIIC_CTRL}   -instance_name {CIC}
## FFTK = HLS fft_kernel: forward 8192-pt FFT, unconditional 1/8192 scaling, plain AXI4 read+write master.
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {fft_kernel_top}  -instance_name {FFTK}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {corner_turn_top} -instance_name {CT}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {window_top}      -instance_name {WIN}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {detect_top}      -instance_name {DET}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {resample_top}    -instance_name {RES}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {sar_axi_idconv}  -instance_name {ID_FIX}

## ---------------- clocks ----------------
sd_create_scalar_port -sd_name $sd -port_name {REF_CLK_50MHz} -port_direction {IN}
sd_instantiate_macro -sd_name $sd -macro_name {CLKINT} -instance_name {CLKREF}
catch { sd_connect_pins -sd_name $sd -pin_names {"REF_CLK_50MHz" "CLKREF:A"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CLKREF:Y" "CCC:REF_CLK_0"} }
sd_connect_pins -sd_name $sd -pin_names {"CCC:OUT0_FABCLK_0" \
    "MSS:FIC_0_ACLK" "DIC:ACLK" "CIC:ACLK" "FFTK:clk" \
    "CT:clk" "WIN:clk" "DET:clk" "RES:clk" "RST:CLK" "ID_FIX:ACLK"}
## CCC:OUT1 (was CoreFFT SLOWCLK) is now unused -- leave the CCC output unconnected.

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
    "DIC:ARESETN" "CIC:ARESETN" "ID_FIX:ARESETN"}
## HLS kernels use an active-high synchronous reset -> invert FABRIC_RESET_N like the other kernels.
foreach k {CT WIN DET RES FFTK} {
    sd_invert_pins -sd_name $sd -pin_names "${k}:reset"
    sd_connect_pins -sd_name $sd -pin_names "RST:FABRIC_RESET_N ${k}:reset"
}

## ---------------- data plane (AXIIC 3.0.130): 5 initiators used -> DIC -> ID_FIX -> MSS FIC0 ----------------
catch { sd_connect_pins -sd_name $sd -pin_names {"CT:axi4initiator"        "DIC:AXI4minitiator0"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"WIN:axi4initiator"       "DIC:AXI4minitiator1"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"DET:axi4initiator"       "DIC:AXI4minitiator2"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"RES:axi4initiator"       "DIC:AXI4minitiator3"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"FFTK:axi4initiator"      "DIC:AXI4minitiator4"} }
## DIC:AXI4minitiator5 unused (was UNLD). Interconnect config kept at 6 ports (crossbar unchanged).
catch { sd_mark_pins_unused -sd_name $sd -pin_names {DIC:AXI4minitiator5} }
catch { sd_connect_pins -sd_name $sd -pin_names {"DIC:AXI4mtarget0" "ID_FIX:S_AXI"} }
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

## ---------------- control plane (AXIIC 3.0.130): FIC0 initiator -> CIC -> 5 targets used ----------------
catch { sd_connect_pins -sd_name $sd -pin_names {"MSS:FIC_0_AXI4_INITIATOR" "CIC:AXI4minitiator0"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget0" "CT:axi4target"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget1" "WIN:axi4target"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget2" "DET:axi4target"} }
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget3" "RES:axi4target"} }
## target4 @ 0x60004000 = fft_kernel control regs (start/idle@+8, src@+0xc, dst@+0x10, nrows@+0x14)
catch { sd_connect_pins -sd_name $sd -pin_names {"CIC:AXI4mtarget4" "FFTK:axi4target"} }
## CIC:AXI4mtarget5 unused (was UNLD control).
catch { sd_mark_pins_unused -sd_name $sd -pin_names {CIC:AXI4mtarget5} }

## ---------------- misc + MSS ----------------
catch { sd_connect_pins_to_constant -sd_name $sd -pin_names {MSS:MSS_INT_F2M} -value {GND} }
sd_mark_pins_unused -sd_name $sd -pin_names {MSS:MSS_INT_M2F}
sd_connect_instance_pins_to_ports -sd_name $sd -instance_name {MSS}

## ---------------- generate ----------------
save_smartdesign -sd_name $sd
generate_component -component_name $sd
save_project
puts "SARTOP_HLSFFT_DONE"
