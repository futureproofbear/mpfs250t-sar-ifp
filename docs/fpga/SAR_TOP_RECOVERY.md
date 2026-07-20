# SAR_TOP recovery status (2026-06-30 → 2026-07-01)

## ✅ RESOLUTION (2026-07-01): the 62.5 MHz fix is PROVEN headless

**The timing-closure fix is validated.** Place-and-route of the 62.5 MHz design (with the CoreFFT
CLK↔SLOWCLK false-path) closes timing **completely**:

| Build | Setup violations | Hold violations | Verdict |
|---|---|---|---|
| 125 MHz (as-built) | **25,847** (worst −3.7 ns) | — | FAILS |
| **62.5 MHz + `sar_fft_cdc.sdc`** | **0** (of 315,349 pins) | **0** | **MET** |

This confirms the M3 FFT stall was a **timing-closure failure**, fixed by halving the fabric clock.
Done entirely headless (board off) via the Libero **VM-netlist custom flow** — see the verified recipe
below. The live script that replays this recipe is `mpfs/fpga/build_corefft_vm.tcl`.

### Verified headless recipe (timing closure — reproduces the 0/0 result)
1. Regenerate `PF_CCC_C0` → 62.5 / 7.8125 MHz (`PF_CCC_C0_62p5.tcl` + `reconfig_ccc_62p5.tcl`).
2. Byte-splice the new PLL defparams into the surviving as-built netlist `libero_sar/synthesis/SAR_TOP.vm`
   (6 values: `VCOFREQUENCY 5000→3000`, `FB_INT_VAL 0x64→0x3C`, `DIV0 0x0A→0x0C`, `DIV1 0x50→0x60`,
   `DIV2 0x0A→0x06`, `DIV3 0x19→0x0F`; OUT = VCO/(DIV×4), VCO = 50×FB_INT). Rename top module
   `SAR_TOP`→`SAR_TOP_NL`; save as `SAR_TOP_NL.vm`.
3. **Fresh** Libero project, same device: `project_settings -vm_netlist_flow TRUE` then
   `import_files -verilog_netlist {SAR_TOP_NL.vm}` (extension must be `.vm`). Root auto-sets to
   `SAR_TOP_NL`; **no synthesis runs**. (The existing SmartDesign project refuses a netlist root.)
4. Import/associate constraints: `sar_io.pdc`, the 62.5 derived SDC (`OUT0 ÷2→÷4`, `OUT1 ÷16→÷32`),
   and `sar_fft_cdc.sdc`. `run_tool COMPILE → PLACEROUTE → VERIFYTIMING` → 0 setup + 0 hold.

### ✅ BOOTABLE BITSTREAM — DONE, fully headless (2026-07-01)
The earlier "needs GUI" caveat was **wrong**. `SAR_TOP` was reconstructed entirely headless
(`mpfs/fpga/build_sartop_330.tcl`) with the 62.5 MHz CCC, the `sar_axi_idconv` (ID_FIX) created
*with* its S_AXI/M_AXI bus interfaces headless, and the CIC reconfigured to 6 targets (AXI4-Lite
slave 5 = `AXI4Lmtarget5`; at the time this drove the CoreAXI4DMAController — that IP has since been
removed and slave 5 @ `0x6000_5000` is now `fft_unloader`). It then synthesized → P&R → **TIMING MET (0 setup + 0 hold)** → exported
a bootable programming job (Fabric + sNVM + eNVM, MSS design-init included):
**`mpfs/fpga/libero_sar/export/SAR_TOP_62p5.job`** (12.12 MB — same size as the working
`SAR_TOP_idfix.job`). See the full headless recipe in memory `sartop-smartdesign-deleted-recovery`.

**To program + test:** flash `SAR_TOP_62p5.job` to the FPGA (Libero `PROGRAMDEVICE` / FlashPro6 on J33),
then re-run the firmware `PIPE` mailbox test — expect the range-FFT stage to terminate and produce
correct data (the 125 MHz timing failure that caused the stall is now closed).

---

## Incident narrative — archived

This document originally opened with the 2026-06-30 incident log: how `reconfig_ccc_62p5.tcl` ran
`delete_component SAR_TOP` and destroyed the as-built SmartDesign, a snapshot of what survived on
disk that day, and the three recovery options considered. That recovery completed on 2026-07-01 and
was later superseded by `create_fresh_project_ffv.tcl`, so the narrative is now archived verbatim in
`history/corefft-gearbox-saga.md` (Part 2). What remains here is the part that is still used: the
verified 62.5 MHz recipe above (cited by `mpfs/fpga/build_corefft_vm.tcl`) and the lesson below.

## Lesson
To change ONLY a CCC frequency, **never `delete_component SAR_TOP`** — regenerate the CCC component and
`sd_update_instance` it in place. The deletion in `reconfig_ccc.tcl`/`reconfig_ccc_62p5.tcl` is unsafe
unless a known-good faithful re-assembly script exists (it does not). Commit `libero_sar/` (at least the
SmartDesign `.cxf`/`.sdb` + `.prjx`) to git so the top is recoverable.
