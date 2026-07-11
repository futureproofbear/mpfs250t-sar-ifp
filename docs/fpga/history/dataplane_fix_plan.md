# Data-plane fix plan — AXIIC_C0 ID width vs FIC0_S 4-bit (and the gating caveat)

## Current AXIIC_C0 config (from AXIIC_C0.cxf)
`ID_WIDTH=8`, `NUM_MASTERS=6`, `NUM_SLAVES=1`, `NUM_THREADS=1`, `CROSSBAR_MODE=0`.
Result: slave-side `DIC_AXI4mslave0_ARID = [8:0]` (9-bit) → SmartDesign truncates to the
4-bit `FIC_0_AXI4_S_ARID`, and hard-zeros the upper response-ID bits (`SAR_TOP.v:1121,1125`).

## Evaluating the three patterns against THIS design
- **`NUM_THREADS` is already 1**, so the "single-thread/sequential" half of Pattern 1 is done.
  The remaining lever is **`ID_WIDTH`**. Our sequencer (`sar_sequencer.c`) fires kernels
  **one at a time** (resample loop → window → FFT → corner-turn → FFT → detect), so there is
  essentially no cross-master read concurrency to preserve — shrinking the ID namespace costs
  us nothing functionally. (Only FFT-pass overlaps feeder-read with DMA-write, which are
  separate AXI read/write ID spaces, so a small read-ID is fine.)
- **Pattern 1 ≈ Pattern 3 here:** in this IP version the slave-side width is *derived from
  `ID_WIDTH`* (there is no separate "Slave ID = 4" knob exposed in the .cxf). So both patterns
  reduce to: **lower `ID_WIDTH` until the slave-side ID fits 4 bits**, letting the core size its
  own routing/tracking instead of the wrapper bit-chopping.
- **Pattern 2 (multi-FIC)** is the right *bandwidth* answer later (enable FIC1 Target +
  AXIIC_C1), but it's a structural change (MSS regen + 2nd crossbar) — not the bring-up fix.

## THE CHANGE (bring-up)
In Libero, open the **AXIIC_C0** CoreAXI4Interconnect config and set **`ID_WIDTH = 3`**
(observed expansion was +1: 8→9, so 3→4 exactly matches `FIC_0_AXI4_S` 4-bit). Regenerate.

**Verify (no guessing):** after regenerate, confirm in `SAR_TOP.v` that
`wire [3:0] DIC_AXI4mslave0_ARID;` and that lines ~1103/1119/1123 are now a **straight
equal-width assign with NO `…_8to4 = 5'h0` truncation/pad**. If the slave ID still comes out
>4 bits, drop `ID_WIDTH` to `1` and re-check. (If the kernels drove IDs wider than the new
`ID_WIDTH`, their master-side IDs would be truncated instead — SmartHLS kernels normally use
ID 0/sequential, so ID_WIDTH 3 is safe; verify no `MASTERx_*ID*_…to…=…` truncation appears.)

## CAVEAT — confirm the cause is the ID path before rebuilding around it
The ID truncation is a **real latent bug** worth fixing regardless, but we have **not yet
proven it is the cause of the hang** (the alternative is the MSS FIC0_S subordinate simply not
asserting ARREADY). Order of operations:

1. **First (no rebuild): run `fic0s_probe.tcl` in SmartDebug** on the current bitstream.
   - `ARVALID=1, ARREADY=0` (stuck) → **MSS won't accept** → this ID fix will NOT help; pivot
     to the FIC0_S subordinate config (region/QoS/ES behaviour).
   - `AR accepted, RVALID never` → **response/ID routing** → the `ID_WIDTH=3` fix is exactly right.
2. **Then rebuild** with the matching fix. If SmartDebug isn't available, do the **combined
   rebuild**: apply `ID_WIDTH=3` **and** add `sar_fic0s_mon.v` (AXIIC_CTRL slave6 @0x60006000)
   in one pass, set firmware `M2_PROBE_MON=1`, and let M2's T6 report the verdict over JTAG:
   - data plane now works → ID truncation was it.
   - still hangs + T6 shows `ar_valid=1, ar_accepted=0` → MSS-side; ID was a red herring.

## After the fix
Re-flash, power-cycle, run `run_m2.sh`. Success = T3 status `PASS` (resample completed) and
`g_sar_status` from a full `sar_form_image` run returns `SAR_SEQ_OK` (0). Then re-enable the
real geometry/SIG staging path for an actual image.
