# Inserting sar_axi_idconv (full AXI4 ID converter) -- GUI steps, then headless build

`sar_axi_idconv.v` is a full AXI4 pass-through with two bus interfaces, validated to
match the real ports:
  S_AXI  = AXIIC_C0 DIC:SLAVE0   (9-bit ID, 32-bit addr, 2-bit LOCK, has REGION/USER)
  M_AXI  = MSS FIC_0_AXI4_S      (4-bit ID, 38-bit addr, 1-bit LOCK, no REGION/USER)
It downsizes ID 9->4 on AR/AW (stashing the upper 5 bits keyed by the low-4 tag),
restores 4->9 on R/B, zero-extends addr 32->38. So both bus connections are matched-width.

The headless `create_hdl_core`/`sd_instantiate_hdl_*` Tcl wouldn't cooperate in Libero
2025.2, so the bus-interface creation + the 2 connects are done in the GUI (Libero SoC).
Everything after (synth/P&R/bitstream/program/verify) stays headless.

## GUI steps (Libero SoC, project open)
1. **File > Import > HDL Source Files** -> `mpfs/fpga/sar_axi_idconv.v`. Then **Build Hierarchy**.
   (Right-click the file > **Check HDL File** first to confirm it parses -- if it errors, send me the message.)
2. **Create the HDL+ core with bus interfaces:** right-click the `sar_axi_idconv` *module*
   (Design Hierarchy, Show: Modules) -> **Create Core from HDL** (or **HDL+ Core**). In the dialog:
   - Map **ACLK** -> clock, **ARESETN** -> reset (active-low).
   - **Add Bus Interface -> AXI4**, mode **Slave/Target (Mirrored)**, and map the `S_AXI_*`
     signals (the dialog auto-matches by the `S_AXI_` prefix; accept).
   - **Add Bus Interface -> AXI4**, mode **Master/Initiator**, map the `M_AXI_*` signals.
   - Save the core. It now shows S_AXI + M_AXI bus pins.
3. **Open SAR_TOP** SmartDesign. **Drag the core** onto the canvas; rename it **`ID_FIX`**.
4. **Delete the existing connection** between **DIC:SLAVE0** and **MSS:FIC_0_AXI4_S**
   (click the bus wire/connection between them, Delete). This removes the lossy auto-slice.
5. **Make the 2 bus connections:**
   - drag **DIC:SLAVE0  ->  ID_FIX:S_AXI**
   - drag **ID_FIX:M_AXI  ->  MSS:FIC_0_AXI4_S**
   - connect **ID_FIX:ACLK** -> the fabric clock net (`CCC_OUT0_FABCLK_0` / CCC `OUT0_FABCLK_0`)
   - connect **ID_FIX:ARESETN** -> `RST_FABRIC_RESET_N` (CORERESET `FABRIC_RESET_N`)
6. **Ctrl+S** (save SmartDesign), then **Generate Component** (or it'll generate on build).
   DRC should pass (warnings only). **File > Close Project**, then tell me **"closed"**.

## Then I do headless:
`build_dataplane_fix.tcl`'s run_tool block (synth -> P&R -> bitstream -> export) but WITHOUT
the AXIIC_C0 reconfigure (no ID_WIDTH change) -> `program_fabric.tcl` (FPExpress) ->
power-cycle -> `run_m2.sh`. SUCCESS = M2 rec tag=0x30 flips st=3 (HANG) -> st=0 (PASS):
the resample read completes through FIC0_S with its ID restored.
