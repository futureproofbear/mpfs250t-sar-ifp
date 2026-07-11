# sar_id_restore integration + build/program/verify

Goal: replace the lossy SmartDesign ID slice+pad on AXIIC_C0(DIC) SLAVE0 -> FIC_0_AXI4_S
with `sar_id_restore.v` (store identity / restore on response). Handbook basis: CoreAXI4-
Interconnect *widens* the target ID (prepends Log2(NUM_INITIATORS)); it does NOT FIFO-compress,
so truncating at the 4-bit FIC0_S boundary loses the source-routing bits -> broken read/write
response routing. This module re-attaches them.

## Boundary nets (SAR_TOP.v)
WIDE (AXIIC_C0 DIC SLAVE0 side, 9-bit):  DIC_AXI4mslave0_{ARID,RID,AWID,BID}
                                          + handshakes DIC_AXI4mslave0_{ARVALID,ARREADY,
                                            RVALID,RREADY,AWVALID,AWREADY,BVALID,BREADY}
NARROW (FIC0_S side, 4-bit):              FIC_0_AXI4_S_{ARID,RID,AWID,BID}

## SmartDesign edit (headless Tcl sketch -- adjust pin names to your canvas)
    import_files -hdl_source {C:/.../mpfs/fpga/sar_id_restore.v}
    build_design_hierarchy
    open_smartdesign -sd_name {SAR_TOP}
    sd_instantiate_hdl_module -sd_name {SAR_TOP} -hdl_module_name {sar_id_restore} \
        -instance_name {ID_FIX}
    # 1) remove the auto slice+pad: disconnect the 4 ID buses where DIC SLAVE0 meets FIC0_S
    #    (in this netlist they appear as the DIC_AXI4mslave0_*_0 slice/concat assigns).
    # 2) rewire the IDs THROUGH ID_FIX:
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:aclk    <fabric clk net CCC_OUT0_FABCLK_0>}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:aresetn <RST_FABRIC_RESET_N>}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:s_arid  AXIIC_C0:SLAVE0_ARID}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:m_arid  <MSS>:FIC_0_AXI4_S_ARID}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:m_rid   <MSS>:FIC_0_AXI4_S_RID}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:s_rid   AXIIC_C0:SLAVE0_RID}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:s_awid  AXIIC_C0:SLAVE0_AWID}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:m_awid  <MSS>:FIC_0_AXI4_S_AWID}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:m_bid   <MSS>:FIC_0_AXI4_S_BID}
    sd_connect_pins -sd_name {SAR_TOP} -pin_names {ID_FIX:s_bid   AXIIC_C0:SLAVE0_BID}
    # snoop handshakes (drive nothing): tie the 4 *valid/*ready monitor inputs to the live nets
    sd_connect_pins ... {ID_FIX:s_arvalid AXIIC_C0:SLAVE0_ARVALID}
    sd_connect_pins ... {ID_FIX:s_arready AXIIC_C0:SLAVE0_ARREADY}
    sd_connect_pins ... {ID_FIX:m_rvalid  <MSS>:FIC_0_AXI4_S_RVALID}
    sd_connect_pins ... {ID_FIX:m_rready  <MSS>:FIC_0_AXI4_S_RREADY}
    sd_connect_pins ... {ID_FIX:s_awvalid AXIIC_C0:SLAVE0_AWVALID}
    sd_connect_pins ... {ID_FIX:s_awready AXIIC_C0:SLAVE0_AWREADY}
    sd_connect_pins ... {ID_FIX:m_bvalid  <MSS>:FIC_0_AXI4_S_BVALID}
    sd_connect_pins ... {ID_FIX:m_bready  <MSS>:FIC_0_AXI4_S_BREADY}
    # leave every NON-ID signal (addr/len/size/burst/data/strb/last/valid/ready) wired
    # AXIIC_C0 SLAVE0 <-> FIC0_S DIRECTLY as today.
    generate_component -component_name {SAR_TOP}
    build_design_hierarchy

NOTE: the slice removal + exact MSS instance/pin path are the intricate part -- easiest to
confirm in the SmartDesign canvas. Once the IDs route through ID_FIX, the rest is the same
headless flow.

## Build / program / verify (reuse the existing scripts)
1. After the SD edit above, run the implementation flow (synth->P&R->bitstream->export):
   the run_tool block from build_dataplane_fix.tcl (skip the create_and_configure_core part --
   no ID_WIDTH change needed here).
2. `bash mpfs/host/run_fix_all.sh`-style: gate, then FlashPro Express program (program_fabric.tcl).
3. Power-cycle, `bash mpfs/host/run_m2.sh`. SUCCESS = M2 rec tag=0x30 flips st=3(HANG)->st=0(PASS):
   the resample kernel's DDR read completes through FIC0_S, IDs restored.

## Reminder
We still haven't independently confirmed the ID path is the hang cause (vs MSS ARREADY-stuck).
run_m2 after this build is the end-to-end confirmation: PASS => ID was it; still HANG + (if the
sar_fic0s_mon monitor is also in) T6 shows ar_accepted=0 => MSS-side, pivot.
