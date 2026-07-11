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
below. Project: `mpfs/fpga/libero_vm`; scripts `mpfs/fpga/build_freshvm*.tcl`.

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
*with* its S_AXI/M_AXI bus interfaces headless, and the CIC reconfigured to 6 targets (the AXI4-Lite
DMA-control `AXI4Lmtarget5`). It then synthesized → P&R → **TIMING MET (0 setup + 0 hold)** → exported
a bootable programming job (Fabric + sNVM + eNVM, MSS design-init included):
**`mpfs/fpga/libero_sar/export/SAR_TOP_62p5.job`** (12.12 MB — same size as the working
`SAR_TOP_idfix.job`). See the full headless recipe in memory `sartop-smartdesign-deleted-recovery`.

**To program + test:** flash `SAR_TOP_62p5.job` to the FPGA (Libero `PROGRAMDEVICE` / FlashPro6 on J33),
then re-run the firmware `PIPE` mailbox test — expect the range-FFT stage to terminate and produce
correct data (the 125 MHz timing failure that caused the stall is now closed).

---

## What happened
While lowering the fabric clock to close timing (125 → 62.5 MHz), the CCC was reconfigured with
`reconfig_ccc_62p5.tcl`, which — modeled on the existing `reconfig_ccc.tcl` — runs
`delete_component SAR_TOP` before regenerating `PF_CCC_C0`. **This deleted the as-built SAR_TOP
SmartDesign.** The CCC regenerated correctly to 62.5/7.8125 MHz, but SAR_TOP could not then be
faithfully rebuilt headless.

**Root issue:** the as-built SAR_TOP was an *iterative* product — `build_sartop.tcl` (a stale
scaffold) plus a chain of rewire/fix steps (`reconnect_dic_330.tcl`, `reconnect_cic_330.tcl`,
`sd_insert_idfix.tcl` = the `sar_id_restore`/idconv ID-width fix) **and manual GUI steps**
(`docs/fpga/history/idconv_gui_steps.md`, `id_restore_integration.md`). The scripts do not cleanly
replay (interconnect port names/counts differ across core versions: `AXI4mmaster*` vs `MASTER*`;
masters actually route through `sar_axi_idconv`). `build_sartop.tcl` alone reconstructs a *different*,
unvalidated topology — attempts failed at the data-plane connections (line 64 → fixed via
`build_design_hierarchy`; then line 68, interconnect master mismatch).

`libero_sar/` was **never committed to git** and there is **no project/SmartDesign backup** on disk
(only a broken 23:28 `SAR_TOP.cxf/.sdb` from the failed re-assembly).

## What SURVIVES (intact)
- `synthesis/SAR_TOP.vm` (mtime 07:12) — the **complete as-built synthesized netlist** (125 MHz).
  CCC is a hierarchical module `PF_CCC_C0_PF_CCC_C0_0_PF_CCC` wrapping `PLL pll_inst_0`.
  PLL: `VCOFREQUENCY=5000`, `DIV0_VAL=0x0A→OUT0 125 MHz`, `DIV1_VAL=0x50→OUT1 15.625 MHz`,
  `DIV3_VAL=0x19→50 MHz`. (OUT = 5000/(DIV_VAL×4).)
- All sub-components: **`PF_CCC_C0` now regenerated to 62.5/7.8125 MHz** (verified SDC ×5÷4, ×5÷32),
  plus AXIDMA_C0, AXIIC_C0, AXIIC_CTRL, ICICLE_MSS, CORERESET_C0, COREFFT_C0, and all 8 HDL+ cores
  (corner_turn/window/detect/resample/fft_feeder + corefft_stream64_adapter + sar_axi_idconv).
- Firmware: untouched. All markdown docs: updated for the timing-closure finding.

## Recovery options (board is OFF — no urgency)
1. **Restore from a backup (BEST, if one exists).** If a copy of the Libero project / SAR_TOP from
   before 2026-06-30 ~23:25 exists anywhere, restore it, then change the clock the *safe* way:
   regenerate `PF_CCC_C0` (already done) and **`sd_update_instance`** the CCC in SAR_TOP (do NOT
   delete SAR_TOP), regenerate SAR_TOP, then `build_timed.tcl`.
2. **GUI reconstruction (faithful, manual).** Rebuild the SAR_TOP SmartDesign in Libero GUI using the
   surviving components (CCC already 62.5 MHz) + the documented steps: `build_sartop.tcl` instantiate/
   clock/reset scaffold → data-plane through `sar_axi_idconv` → `idconv_gui_steps.md` /
   `id_restore_integration.md` → interconnect reconnect. Then `build_timed.tcl` (gated).
3. **Netlist defparam splice (headless, fragile — not recommended unsupervised).** Synthesize the new
   62.5 MHz `PF_CCC_C0` alone, extract its PLL defparams, splice the CCC module body into the surviving
   `synthesis/SAR_TOP.vm`, then run **P&R-only** on the patched netlist → `build_timed.tcl` gate →
   bitstream. Note `DIV1_VAL=160` for 7.8125 MHz overflows the 7-bit divider, so the new CCC uses a
   different VCO/divider arrangement — the splice must take the *full* new defparam set, not a 2-value
   edit. Risk: hand-editing a 19 MB netlist + forcing P&R without source.

## Lesson
To change ONLY a CCC frequency, **never `delete_component SAR_TOP`** — regenerate the CCC component and
`sd_update_instance` it in place. The deletion in `reconfig_ccc.tcl`/`reconfig_ccc_62p5.tcl` is unsafe
unless a known-good faithful re-assembly script exists (it does not). Commit `libero_sar/` (at least the
SmartDesign `.cxf`/`.sdb` + `.prjx`) to git so the top is recoverable.
