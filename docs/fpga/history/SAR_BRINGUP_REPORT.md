# SAR-on-PolarFire-SoC — On-Silicon Bring-Up Report

> **▶ 2026-07-14:** repo now **standalone `mpfs250t-sar-ifp`**; the on-board **eMMC pipeline (M1–M3) is
> proven on silicon** (scene stored on eMMC, loaded + focused on-board, output persisted — retiring the
> ~3 h JTAG scene load). Current status:
> [`../PROJECT_SOURCE_OF_TRUTH.md`](../../PROJECT_SOURCE_OF_TRUTH.md) + [`SILICON_ISO_TEST_RUNBOOK.md`](../SILICON_ISO_TEST_RUNBOOK.md) § eMMC. Below is retained as bring-up history.

Target: Microchip PolarFire SoC Icicle Kit, **MPFS250T_ES** (engineering sample, FCVG484).
Goal: GUI-free Synthetic Aperture Radar image formation (Polar Format Algorithm) with the
**FPGA fabric doing the heavy compute**, bare-metal RISC-V orchestrating, host PC doing
off-board prep/post — **JTAG is the only I/O path** (no Ethernet/SD/UART-bulk).

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`../PROJECT_SOURCE_OF_TRUTH.md`](../../PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". The `CoreAXI4DMAController` (S2MM) / `DMA` instance described throughout this report
> — including the "full DMA *transfer* test" open item and the `DMA` block in the §2 netlist / §1 data
> plane — was **removed** (it deadlocked on the 2nd back-to-back S2MM transaction; 3 firmware/TDEST
> workarounds failed) and **replaced by the `fft_unloader` HLS kernel** (AXI4-Stream slave → AXI4 write
> master, control base `K_FFT_UNLOADER @0x6000_5000`). A gearbox output skid FIFO was added to keep
> CoreFFT from wedging under unloader backpressure. Both fixes are fabric-level (firmware unchanged);
> `fft_unloader` is validated standalone on silicon, the FIFO fix is sim-validated, fabric rebuilding.

> ## ✅ STATUS (2026-06-30): DATA PLANE **AND** DMA CONTROL FIXED ON SILICON
> The fabric data-plane hang is resolved (root cause = **AXI ID-width truncation at `FIC_0_AXI4_S`**;
> fix = `sar_axi_idconv.v`; M2 `tag=0x30` `st=3` (HANG) → `st=0` (PASS), SCRATCH written
> `0xDEADBEEF`→`0`). The DMA control slave (`tag=0x50`) is **now also fixed** — root cause = CIC
> slave-5 was Full-AXI4 (`TARGET_TYPE=0`) feeding the DMA's AXI4-Lite control through a 64→32 DWC
> and black-holing reads; fix = CIC `TARGET5_TYPE=1` (AXI4-Lite) + 11-bit address slice, with both
> interconnects upgraded to CoreAXI4Interconnect 3.0.130. Verified: tags `0x50–0x53` read distinct
> DMA registers (VER=`0x00020064`), no hang.
> **Remaining open:** full DMA *transfer* test (descriptor + START data-move not yet exercised) and
> bulk-data transport (JTAG-slow — measured **~84 kbit/s**, viable run-to-completion). Details in §4–§6, §10.
>
> ## ⚠ UPDATE (2026-06-30): M3 FULL-PIPELINE `PIPE` RUN — REAL ROOT CAUSE = **BITSTREAM FAILS TIMING @125 MHz**
> The M3 full PFA pipeline (resample→corner-turn→window→2D-FFT→detect) is wired into firmware (`PIPE`
> mailbox → `sar_form_image`). Stages 1–4 ran on silicon; the range-FFT stage appeared to hang. After a
> long on-silicon debug (SmartDebug active-probes, DMA-sentinel), the cause is **P&R timing failure, not
> logic/firmware:** `pinslacks.txt` = **25,847 / 315,348 pins negative slack, worst −3.7 ns, ALL on the
> single CCC OUT0 125 MHz fabric clock** — real same-clock setup failures (by block: CT 14341, CIC 3957,
> DMA 3349, FEED 1973, DIC 1826, RES 249, DET 102, WIN 50; **CoreFFT = 0**). Silicon ran
> **non-deterministically**; stages 1–4 "completed" but almost certainly with **corrupt data** (only
> completion was checked, not correctness). **Fix:** lower fabric clock CCC OUT0 **125→62.5 MHz**, OUT1
> (CoreFFT SLOWCLK) **15.625→7.8125 MHz** (SLOWCLK ≤ CLK/8); worst path ~11.7 ns < 16 ns @62.5 MHz; done
> **headless** (`PF_CCC_C0_62p5.tcl`/`reconfig_ccc_62p5.tcl`) + re-assemble (`build_sartop.tcl`). **New
> build gate:** `build_timed.tcl` aborts before bitstream on any negative slack. **Lesson:** always verify
> P&R timing closure before blaming logic/firmware — Libero programs timing-failing bitstreams silently.
> **Status:** 62.5 MHz timing closure **PROVEN (2026-07-01)** — headless P&R of the 62.5 MHz design
> (with the CoreFFT `CLK`↔`SLOWCLK` false-path `sar_fft_cdc.sdc`) **closes timing completely (0 setup
> violations of 315,349 pins, 0 hold)** vs 25,847 setup violations at 125 MHz, via the Libero VM-netlist
> custom flow (`mpfs/fpga/libero_vm`); the fix is confirmed. **Caveat:** a fully *bootable* bitstream
> still needs SAR_TOP rebuilt with the (already regenerated) 62.5 MHz CCC — recipe in `SAR_TOP_RECOVERY.md`.
> See §6.9 / §8.

---

## 1. System architecture (the partition)

```
 HOST PC (Python, off-board)                 PolarFire SoC
 ─────────────────────────────               ───────────────────────────────────────────
 parse CPHD + geometry                        E51 (hart0): monitor; wakes U54_1
 build KR/KC/tanphi/window, coeffs            U54_1 (hart1, has FPU): ORCHESTRATION
 quantize SIG -> 16-bit BFP I/Q                 - load job, compute resample coeffs
 serialize -> .bin     ── JTAG load (DDR) ─►    - program fabric kernels, poll DONE
 golden oracle (numpy)                         FPGA fabric (SAR_TOP): HEAVY COMPUTE
 post: rescale, PNG    ◄─ JTAG dump (DDR) ──    resample->window->FFT->corner-turn->FFT->detect
```

### DDR memory map (1 GB LPDDR4)
| Region | Addr | Cache | Used by |
|---|---|---|---|
| SIG (input I/Q) | `0x88000000` | cached | fabric resample in |
| SCRATCH | `0x98000000` | cached | inter-stage |
| OUT (image) | `0xA8000000` | cached | detect out / host dump |
| TABLES base | `0xB0000000` | **non-cached** | job/geometry/coeffs |
| ↳ job descriptor | `0xB0040000` | | `sar_job_t` (magic 'SAR1', M,N,…) |
| ↳ geometry (f0/df/pr/tans/invord/KR/KC/ham) | `0xB0100000`+ | | coeff gen inputs |
| ↳ coeff banks (idx/wq) | `0xB0148000` | | resample kernel reads |
| (cached 32-bit window) | `0x80000000–0xAFFFFFFF` (768 MB) | | |
| (non-cached 32-bit window) | `0xB0000000–0xBFFFFFFF` (256 MB) | | |

---

## 2. Fabric design (SAR_TOP SmartDesign) — parts and connections

### Instances (names as in the netlist)
| Instance | Component | Role |
|---|---|---|
| `MSS` | ICICLE_MSS | the hard MSS (RISC-V + DDR ctrl + FICs) |
| `CIC` | AXIIC_CTRL (CoreAXI4Interconnect) | **control** crossbar (1 master, 6 slaves) |
| `DIC` | AXIIC_C0 (CoreAXI4Interconnect) | **data** crossbar (6 masters, 1 slave) |
| `DMA` | AXIDMA_C0 (CoreAXI4DMAController) | S2MM datamover for the FFT stream — **REMOVED 2026-07-04, replaced by `fft_unloader` HLS kernel** (see update note at top) |
| `FFT` | COREFFT_C0 | the FFT engine |
| (5 HLS) | CORNER_TURN/WINDOW/DETECT/RESAMPLE/FFT_FEEDER | SmartHLS kernels |
| `CCC` | PF_CCC_C0 | fabric PLL/clock conditioner |
| `RST` | CORERESET_C0 | fabric reset sequencer |
| `CLK_DIV2/4`, `OSCILLATOR_160MHz` | PF_CLK_DIV / PF_OSC | clocking support |

### Clock tree
`OSCILLATOR_160MHz → PF_CCC_C0 (CCC) → OUT0_FABCLK_0 (= net CCC_OUT0_FABCLK_0)` clocks
**everything in fabric**: `CIC`, `DIC`, `DMA`, all 5 kernels, and the MSS FIC0 interface.
CCC also exposes `CCC_PLL_LOCK_0`. `CLK_DIV2/4` provide divided clocks.

### Reset tree
`CORERESET_C0 (RST)`: inputs `CLK=CCC_OUT0_FABCLK_0`, `EXT_RST_N=MSS_MSS_RESET_N_M2F`,
`PLL_LOCK=CCC_PLL_LOCK_0`; output `FABRIC_RESET_N (= net RST_FABRIC_RESET_N)` resets
**all fabric** (CIC, DIC, DMA, kernels via `~RST_FABRIC_RESET_N`).

### CONTROL plane (works ✓)
```
MSS FIC_0_AXI4_M (initiator)  →  CIC (AXIIC_CTRL)  →  6 AXI4-Lite slaves @ 0x6000_n000:
   SLAVE0 CORNER_TURN 0x60000000   SLAVE1 WINDOW 0x60001000   SLAVE2 DETECT 0x60002000
   SLAVE3 RESAMPLE   0x60003000    SLAVE4 FFT_FEEDER 0x60004000   SLAVE5 DMA 0x60005000
```
SmartHLS control reg layout per kernel: `+0x08` START/STATUS (write 1=start, reads 0=done),
`+0x0c` arg0, `+0x10` arg1, `+0x14` arg2, `+0x18` arg3.

### DATA plane (FIXED ✓ — see §4/§5)
```
5 kernel AXI masters + DMA master (6 masters)  →  DIC (AXIIC_C0, window 0x80000000-0xBFFFFFFF)
   →  DIC:AXI4mslave0  →  ID_FIX (sar_axi_idconv, 9-bit⇄4-bit ID convert)  →  MSS FIC_0_AXI4_S  →  DDR
```
The sequencer runs kernels **one at a time** (resample loop → window → FFT → corner-turn →
FFT → detect), so only one data master is active at a time (NUM_THREADS=1, sequential) — which
is what makes the single-outstanding ID stash/restore in `ID_FIX` lossless.

---

## 3. What has been done / validated

### Off-board (prior milestones)
- PFA algorithm verified (host numpy golden, correlation **0.9999998**).
- ES bitstream built, **timing met**. Firmware + host tooling complete. Milestone "M0" done.

### On-silicon (this campaign)
- **Boot:** board boots **boot mode 1** (app from eNVM at 0x20220000, copied to L2 scratchpad
  0x0a000000). Programmed via `mpfsBootmodeProgrammer.jar` + `fpgenprog` (reliable, not OpenOCD).
- **RISC-V firmware works end-to-end:** U54_1 wakes (E51 soft-int), runs an **autonomous
  self-test** (no debugger), calls `sar_form_image`, reaches the fabric kernel handshake.
- **Autonomous M2 register-verification harness** (`u54_1.c`) — runs on boot, latches results
  to DDR `0xB0050000` + globals, read back over ONE short JTAG burst. Results:

| M2 test | Result (pre-fix, 2026-06-25) | Result (with ID_FIX, 2026-06-29) |
|---|---|---|
| T0 clock/reset | `SUBBLK_CLOCK_CR=0x0f800021`, `SOFT_RESET_CR=0x307dffde` | same ✓ (FIC0–3 clocks ON, resets released) |
| T1 control decode | all 5 kernels `0x6000_x008` = `0` (idle ✓) | same ✓ |
| T2 AXI4-Lite latch | RESAMPLE args write/read-back exact ✓ | same ✓ |
| T3 resample run (`tag=0x30`) | `st=3` HANG; status busy-forever; SCRATCH still `0xDEADBEEF` ✗ | **`st=0` PASS**; kernel reaches *done*; **SCRATCH `0xDEADBEEF`→`0`** ✅ |
| T5 DMA slave (`tag=0x50`) | `0x60005000` read hung the hart (M1) → harness compiled with `M2_PROBE_DMA=0` | **VERIFIED ✅** (2026-06-30) — tags `0x50–0x53` read distinct DMA registers (VER=`0x00020064`), no hang. Fixed via CIC slave-5 → AXI4-Lite (see §6.2) |

**Net (2026-06-29):** `g_m2_done=0xC0FFEE02`, `total=14 pass=13 fail=1`. The resample kernel now
completes a full DDR round-trip (read coeff bank + write SCRATCH) **through `ID_FIX`** — the data
plane is **alive**. The one remaining failure at that point was the DMA control slave (`tag=0x50`),
a separate issue the converter does not touch (see §6.2). **Update (2026-06-30):** the DMA control
slave is now also fixed — both the data plane **and** the DMA control slave are verified on silicon
(`tag=0x50–0x53` read distinct DMA registers, VER=`0x00020064`, no hang).

---

## 4. Root-cause diagnosis

**Symptom:** every fabric AXI-master read to DDR (and the DMA control-slave access) gets no
response and hangs. The *same* DDR address works from the hart but hangs from the fabric →
isolated to the **`FIC_0_AXI4_S` (fabric→MSS→DDR) path**.

**Ruled out** (by evidence + Libero source trace):
- MSS FIC clock/reset gating — T0 shows FICs enabled.
- Fabric clock/PLL/reset dead — the control plane + kernels run on the same `CCC_OUT0_FABCLK_0`
  + `RST_FABRIC_RESET_N` and work, so the clock is live and reset released. (An earlier
  subagent's "PLL never locks" theory is therefore **false**.)
- Kernel clock dead — T2 (AXI4-Lite latch) proves the kernel clock runs.
- Address routing / MPU — AXIIC_C0 SLAVE0 window `0x80000000-0xBFFFFFFF` covers all buffers;
  FIC0 MPU = `0x1F00000FFFFFFFFF` (allow-all); FIC0 Target interface = enabled.

> ✅ **Address-tie co-suspect RULED OUT (2026-06-29).** §9.1 flagged the doc-warned "FIC locks
> up if upper address bits are tied off" as a co-primary candidate. The shipped fix drives the
> FIC0_S upper bits with a **static constant `6'h0`** (no gated shim) and the data plane works —
> so for our 32-bit cached window (upper bits genuinely 0) the static tie is **benign**, and the
> ID-truncation theory below was the **sole** root cause. The gated shim was not needed.

**CONFIRMED ROOT CAUSE (fixed): AXI ID-width truncation at FIC0_S.**
- `AXIIC_C0` (`ID_WIDTH=8`, `NUM_MASTERS=6`) drives a **9-bit** slave-side ID; per the
  CoreAXI4Interconnect handbook the core **prepends Log2(NUM_INITIATORS) source-routing bits**
  to the target ID (it widens; it does **not** FIFO-compress).
- `MSS FIC_0_AXI4_S` accepts only a **4-bit** ID.
- SmartDesign's auto-wrapper **truncates 9→4 outbound** (`SAR_TOP.v` slice) and **hard-zeros
  the upper 5 bits of the response ID** (`RID/BID = {5'h0, …}`). The dropped upper bits are the
  master-routing tag, so read/write **responses cannot route back to the originating master →
  the master waits forever**. This matches the hang exactly.
- **CONFIRMED on silicon:** inserting `ID_FIX` (which preserves the full 9-bit ID via stash/
  restore) cleared the hang — `tag=0x30` went `st=3`→`st=0` and SCRATCH was written. So the
  dropped routing bits were indeed the cause; no `ARREADY`-stall probe was needed.

---

## 5. The fix (DONE — integrated, built, verified on silicon)

`sar_axi_idconv.v` — a **full AXI4 pass-through ID converter** spliced between
`DIC:AXI4mslave0` and `MSS:FIC_0_AXI4_S`:
- `S_AXI` matches DIC:SLAVE0 (9-bit ID, 32-bit addr, 2-bit LOCK, has REGION/USER).
- `M_AXI` matches FIC0_S (4-bit ID, 38-bit addr, **1-bit LOCK, no REGION/USER** — validated).
- On AR/AW it **stashes the upper-5 ID bits keyed by the low-4 tag** and forwards the 4-bit tag;
  on R/B it **restores** the full 9-bit ID → responses route home. Address zero-extended 32→38.
- Safe because the design is single-outstanding-per-tag (sequential kernels, NUM_THREADS=1).

> ✅ **Constant `6'h0` upper-address extend is fine here** — the converter zero-extends with a
> static constant (`M_AXI_ARADDR = {6'b0, S_AXI_ARADDR}`). §9.1 worried this matched the doc's
> "tied-off FIC lock-up." On silicon it works, because our 32-bit cached window's upper bits are
> genuinely 0. The gated `ARESETN∧VALID` shim was **not** required. (It would only matter if the
> design ever drives the non-cached 38-bit alias `0x14_00000000`, where upper bits are non-zero.)

**Integration (done):** inserted in the **Libero GUI** via `idconv_gui_steps.md` ("Create Core
from HDL" → `S_AXI` Target-mirrored + `M_AXI` Initiator → delete the old `DIC:AXI4mslave0 ↔
FIC_0_AXI4_TARGET` wire → 2 bus connects + ACLK/ARESETN to the DIC's nets). Then headless:
synth → P&R (with `REPAIR_MIN_DELAY`, see §6.8) → bitstream → program → `run_m2.sh`.
**Verified 2026-06-29: M2 `tag=0x30` `st=3` (HANG) → `st=0` (PASS), SCRATCH written.**

> ⚠ **Do NOT headless-reconfigure `AXIIC_C0`.** A `delete_component AXIIC_C0` +
> `create_and_configure_core -params` (the old §6.5 "reconfigure" idea) silently builds the IP's
> **2-master/2-slave default** instead of the real 6m/1s, breaking SAR_TOP (`MASTER2_AWVALID
> doesn't exist` at synth) with no clean `.cxf` backup. If `AXIIC_C0` ever needs rebuilding, do it
> in the **GUI CoreAXI4Interconnect configurator**: Masters=6, Slaves=1, Data 64, ID 8, Addr 32,
> Threads 1, all master data-widths 64, Slave0 `0x80000000–0xBFFFFFFF`, all 6 masters R+W→S0; then
> Update the DIC instance and reconnect the 6 masters (CT/WIN/DET/RES/FEED `axi4initiator`, DMA
> `AXI4InitiatorDMA_IF`; FEED is read-only so `MASTER4` write tied to GND is normal).

---

## 6. Existing issues / open risks

1. ~~**Data-plane hang (PRIMARY).**~~ **RESOLVED 2026-06-29** — `sar_axi_idconv.v` integrated,
   built, programmed, M2-verified (`tag=0x30` `st=3`→`st=0`, SCRATCH written). ID truncation
   confirmed as the cause; no `ARREADY`-stall probe needed.
2. ~~**DMA control slave (`0x60005000`) — STILL OPEN.**~~ **RESOLVED 2026-06-30.** A CPU read of
   this region previously hung the hart un-haltably in M1 (no response, no error), and the M2
   harness was compiled with `M2_PROBE_DMA=0` so `tag=0x50` was a placeholder. **Confirmed root
   cause:** CIC slave-5 was **`TARGET_TYPE=0` (Full AXI4)** feeding the DMA's reduced **AXI4-Lite**
   control interface through a 64→32 DWC, so control reads were **black-holed** (the un-haltable
   hang). **Fix:** set CIC **`TARGET5_TYPE=1` (AXI4-Lite)** + an **11-bit address slice** (via
   `sd_create_pin_slices`); this required upgrading **both** interconnects to **CoreAXI4Interconnect
   3.0.130** (was 2.9.100), since the AXI4-Lite target type is only available in 3.0.130. **Note:**
   the *earlier* guess in this doc — "set CIC Slave-5 **data width** to 32 in the GUI" — was **NOT**
   the fix; the protocol-**TYPE** change to AXI4-Lite was. **Verified:** tags `0x50–0x53` read
   distinct DMA registers (VER=`0x00020064`), no hang. **→ See `docs/fpga/dma_fix_plan.md` §7g
   (RESOLVED).** Firmware register offsets (`I0ST 0x10`, `I0CLR 0x18`, were `0x08`) are corrected in
   `sar_sequencer.c` per `coreaxi4dmacontroller_regs.h`.
3. **New OpenOCD 0.12 HID instability.** The microchip-fpga OpenOCD can examine/halt/short-read
   reliably but **crashes on sustained traffic** (the 97 MB SIG stage, long function-call register
   writes, long polls). Worked around by the **autonomous-firmware** pattern (run off-JTAG, read
   results in one short burst). The old SoftConsole OpenOCD couldn't multi-hart-halt at all.
4. **Bulk JTAG transfer is SLOW but VIABLE (corrected 2026-06-30).** Earlier this was logged as
   "unviable / crashes the HID" — that was wrong. JTAG bulk DDR load is **measured at ~84 kbit/s
   (~111 s/MB)**, so 97 MB SIG ≈ **~2.7 hr**. It is **latency-bound** by the FlashPro6 USB-HID
   (~390 µs per JTAG word-scan), **not bandwidth-bound**: rate is independent of clock (2/6 MHz
   identical) and method (sysbus == progbuf), and no OpenOCD batching knob exists. Crucially the
   transfer is **reliable run-to-completion** — the HID wedges **only** if openocd is **killed
   mid-transfer** (short timeout) or a `verify_image` readback is interrupted; a completed transfer
   is clean. **Recovery = re-plug J33 USB** (not a hard USB requirement). Data integrity is **proven
   byte-identical** (1 MB and 8 MB loads, `dump_image` + host `cmp`, MD5 match). For real
   full-resolution runs the alternative remains the **USB (J33) device-mode** route (MSS USB
   currently disabled in the FPGA; would need MSS regen + USB firmware), but a one-time chunked
   background load (run to completion, never killed) + on-target CRC verify (§8.5/below) is viable
   for the full 97 MB.
5. **Headless Libero SmartDesign API friction (2025.2).** `create_hdl_core`,
   `sd_instantiate_hdl_module`, `sd_instantiate_hdl_core`, and `sd_disconnect_pins` all fail with
   unhelpful errors; `sd_connect_pins` works but can't remove an existing slice, so headless
   mid-connection insertion tangled (feedback loop) and was reverted. Hence the GUI step.
   Note: IP **reconfigure** *is* scriptable (`delete_component` + `create_and_configure_core`
   + `generate_component -component_name` + `run_tool` flow all work).
6. **Cached vs non-cached DDR for fabric masters.** SIG/SCRATCH/OUT are in cached DDR
   (`0x8/9/A`), tables/coeffs in non-cached (`0xB0…`). If the ID fix doesn't fully clear it,
   the next suspect is the fabric needing the **non-cached alias** (would require driving the
   FIC0_S upper address bits, currently tied `6'h0`). **Doc cross-check (§9.2):** even once
   reads complete, fabric reads of *cached* DDR risk L2 staleness — handle via non-cached
   buffers or CPU flush + fabric-port WayMask before trusting image data.
7. ~~**FIC address bits tied off (§9.1).**~~ **RULED OUT 2026-06-29** — the shipped converter
   ties FIC0_S upper bits to constant `6'h0` and the data plane works, so for the 32-bit cached
   window the static tie is benign. The gated shim was not needed (would only matter for the
   non-cached 38-bit alias). See §9.1.
8. **CoreFFT hold violations (build, fixed).** A first P&R of the ID_FIX design was setup-clean
   but had 2 small **hold** violations *inside* CoreFFT (`twid_wEn`, `rstAfterInit`; ~−0.25 ns),
   surfaced by placement variation from adding `ID_FIX` — not the converter. Re-running P&R with
   **`REPAIR_MIN_DELAY:true`** cleared them; `SAR_TOP_idfix.job` now meets timing (setup+hold).
9. **Bitstream FAILS TIMING @125 MHz — the real M3 FFT "hang" (RESOLVED 2026-06-30).** The M3 full
   pipeline's apparent range-FFT hang was **not** logic/firmware: `pinslacks.txt` shows **25,847 /
   315,348 pins negative slack, worst −3.7 ns, ALL on the CCC OUT0 125 MHz fabric clock** — real
   same-clock **setup** failures (by block: CT 14341, CIC 3957, DMA 3349, FEED 1973, DIC 1826, RES 249,
   DET 102, WIN 50; **CoreFFT = 0**). Silicon ran **non-deterministically**; stages 1–4 "completed" but
   almost certainly with **corrupt data** (only completion was checked, not correctness). **Fix:** lower
   fabric clock CCC OUT0 **125→62.5 MHz**, OUT1 (CoreFFT SLOWCLK) **15.625→7.8125 MHz** (SLOWCLK ≤ CLK/8);
   worst path ~11.7 ns < 16 ns @62.5 MHz; headless (`PF_CCC_C0_62p5.tcl`/`reconfig_ccc_62p5.tcl`) +
   `build_sartop.tcl`. **New build gate:** `build_timed.tcl` parses `pinslacks.txt` and **aborts before
   bitstream on any negative slack**. **Trade-off:** 62.5 MHz halves fabric + FIC↔DDR throughput (fine for
   bring-up). **Lesson:** always verify P&R timing closure before blaming logic/firmware; "stage completes"
   ≠ "data correct" ≠ "timing met"; Libero programs timing-failing bitstreams silently; `*_sdc_errors.log`
   = SDC *syntax*, not slack. Status: 62.5 MHz timing closure **PROVEN (2026-07-01)** — headless P&R
   (with the CoreFFT `CLK`↔`SLOWCLK` false-path `sar_fft_cdc.sdc`) **closes timing completely: 0 setup
   violations of 315,349 pins, 0 hold**, via the Libero VM-netlist custom flow (`mpfs/fpga/libero_vm`);
   the clock-lowering fix is confirmed. **Caveat:** a fully *bootable* bitstream still needs SAR_TOP
   rebuilt with the (already regenerated) 62.5 MHz CCC (the MSS is coupled to the SmartDesign flow and
   resists the pure headless netlist flow) — verified recipe in [`SAR_TOP_RECOVERY.md`](../SAR_TOP_RECOVERY.md).

---

## 7. File inventory (mpfs/ tree)

**Firmware** (`fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/application/hart1/u54_1.c`):
M2 autonomous harness (trap-protected probes, bounded waits, result table @0xB0050000,
globals `g_m2_done`/`g_m2_*`). Built with SoftConsole make → `…Release/mpfs-hal-ddr-demo.elf`.

**SAR driver/sequencer** (`fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/sar/`): `sar_sequencer.c` (sar_form_image),
`sar_kernels.h` (reg map), `sar_resample_coeffs.c`, `ddr_sar_layout.h`, `sar_accel_driver.c`.

**Fabric fix** (`mpfs/fpga/`): `sar_axi_idconv.v` (the converter, USE THIS),
`sar_id_restore.v` (earlier snoop-only version, superseded), `idconv_gui_steps.md` (GUI guide),
`build_dataplane_fix.tcl` (headless reconfigure+flow), `program_fabric.tcl` (FPExpress),
`run_fix_all.sh`, `run_build_fix.sh`, `axiic_c0_params.tcl` (full AXIIC_C0 params, ID_WIDTH lever).

**Diagnostics** (`mpfs/fpga/`): `dataplane_bringup_vplan.md` (3-axis register verification plan),
`dataplane_fix_plan.md`, `fic0s_probe_plan.md` + `fic0s_probe.tcl` (SmartDebug AR/R probe),
`sar_fic0s_mon.v` (in-fabric handshake monitor → readable over JTAG).

**JTAG / programming** (`mpfs/host/`, `Tools/openocd-new/`): new OpenOCD 0.12, `efp6_*.cfg`
(`efp6_m2.cfg` reads M2 results; `efp6_read.cfg`; `efp6_flow.cfg`), `run_m2.sh`, `run_read.sh`,
`run_program.sh` (eNVM bootmode via fpgenprog). Programmers: `mpfsBootmodeProgrammer.jar` +
`fpgenprog` (eNVM/boot mode), `FPExpress.exe` (fabric bitstream). `libero.exe` (headless flow).

**Programming tools:** `C:\Microchip\Libero_SoC_2025.2\Libero_SoC\Designer\bin\{libero,FPExpress,fpgenprog}.exe`;
SoftConsole `C:\Microchip\SoftConsole-v2022.2-RISC-V-747`.

---

## 8. Next steps (data plane + DMA control done; remaining work)
0. **Rebuild bootable SAR_TOP at 62.5 MHz, then re-run M3 (§6.9). Timing closure now PROVEN
   (2026-07-01).** The M3 FFT "hang" was a **bitstream timing failure @125 MHz**, not logic. Lowering
   CCC OUT0 → **62.5 MHz** / OUT1 → **7.8125 MHz** (with the CoreFFT `CLK`↔`SLOWCLK` false-path
   `sar_fft_cdc.sdc`) was **validated by headless P&R via the Libero VM-netlist custom flow
   (`mpfs/fpga/libero_vm`): timing closes completely — 0 setup violations of 315,349 pins, 0 hold**
   (vs 25,847 setup violations at 125 MHz). The remaining step is producing a fully *bootable* bitstream:
   the SAR_TOP SmartDesign must be rebuilt with the (already regenerated) 62.5 MHz CCC, because the MSS
   is coupled to the SmartDesign flow and resists the pure headless netlist flow (verified recipe in
   [`SAR_TOP_RECOVERY.md`](../SAR_TOP_RECOVERY.md)). Then **reprogram** and re-run the `PIPE` pipeline,
   checking **correctness** (host golden compare), not just stage completion. Firmware is unchanged/valid
   (`PIPE`/`CRC` mailboxes, DMA external-stream-descriptor, bounded-wait harness). **Standing rule:**
   verify P&R timing closure before blaming logic/firmware.
1. ~~**Full DMA *transfer* test.**~~ **OBSOLETE 2026-07-04** — the DMA was removed after it deadlocked
   on the 2nd back-to-back S2MM transaction. The FFT write-back is now the **`fft_unloader` HLS kernel**
   (AXI4-Stream slave → AXI4 write master), validated standalone on silicon; the remaining gate is the
   on-silicon full-pipeline retest with the rebuilt fabric (see the update note at top). *(Historical
   task text: program a descriptor + issue START + confirm the S2MM datamover moved data to DDR.)*
2. **First real end-to-end image (small scene).** Stage a small SIG + geometry over JTAG (fits a
   short burst), run the full pipeline through the now-working data plane, JTAG-dump OUT, compare
   to the host golden. Validates resample→window→FFT→corner-turn→FFT→detect with real data.
3. **L2 coherency for cached buffers (§9.2)** before trusting image data — non-cached buffers or
   CPU flush + fabric-port WayMask around SIG/SCRATCH/OUT.
4. **Full-resolution transport.** ~96 MB SIG in / 128 MB OUT over JTAG is **slow (~84 kbit/s,
   ~2.7 hr for 97 MB) but viable run-to-completion** (§6.4). Validated workflow: use a **reduced
   frame (8 MB)** for dev iteration, and for the full 97 MB do a **one-time chunked background load
   — run to completion, never killed** — then verify with the **on-target CRC32 mailbox** (below)
   instead of a slow `dump_image`+`cmp` (seconds vs hours). Enabling **MSS USB** (J33 device mode,
   currently disabled — MSS regen + USB firmware) remains the faster alternative.

5. **On-target CRC32 verify (NEW, firmware `u54_1.c`).** A **CRC32 mailbox** at DDR
   `0xB0058000` (6×u32: `+0` cmd, `+4` base, `+8` len, `+C` result, `+10` status, `+14` seq) lets
   the host check a loaded region without dumping it. The host writes `cmd=0x43524333` (`'CRC3'`),
   `base`, and `len`, then **RESUMES hart1**; the firmware computes a **zlib-compatible CRC32**
   (poly `0xEDB88320`) over the region at **~75 MB/s**, writes `result` + status `0xC0FFEE03`, and
   the host reads back 4 bytes. This **replaces the slow `dump_image`+`cmp`** (seconds vs hours).
   Host tool: `mpfs/host/run_crc_verify.sh FILE [BASE_HEX]`. **Validated:** `sig_head.bin` (1 MB) =
   `0x24775359`, `sigchunk_00` (8 MB) = `0x591213fe`, both matching host `zlib.crc32`.

**Companion docs (interconnect / DMA fix details):** `docs/fpga/AMBA_ARCHITECTURE.md`,
`docs/fpga/FABRIC_INTERCONNECT_CONVENTIONS.md`, `docs/fpga/dma_fix_plan.md` (§7g RESOLVED),
`docs/fpga/SMARTDEBUG_RUNBOOK.md`.

---

## 9. Cross-check vs Microchip PolarFire SoC documentation

Reviewed the implementation against `polarfire-soc-documentation-master`
(`knowledge-base/mpfs-memory-configuration.md`, `knowledge-base/mpfs-memory-hierarchy.md`,
`benchmarks/dma-benchmarking/…`, `knowledge-base/boot-modes/boot-mode-1-fundamentals.md`).
The differences that matter, highest-impact first:

### 9.1 ✅ RESOLVED — static `6'h0` upper-address tie is benign here (gating not needed)
> **Outcome (2026-06-29):** the shipped `sar_axi_idconv.v` ties the FIC0_S upper address bits to a
> static `6'h0` and the data plane works on silicon. So the doc's "tied-off lock-up" did **not**
> apply to our case — because our 32-bit cached window legitimately needs upper bits = 0. The ID
> truncation was the sole cause. The analysis below is retained for the record; the gated shim
> would only be needed if the design ever drives the non-cached 38-bit alias (`0x14_00000000`).

Original concern — fabric AXI address bits must be GATED, not tied off:
`mpfs-memory-configuration.md` (38-bit addressing section) documents, verbatim:
> *"It was seen during testing that the MSS FIC / PCIe AXI interface would **lock up if the
> address bits are simply tied off**. To avoid locking the interface up the address bits that
> need to be set are connected to the output of an **AND gate. This ANDs the resetn and
> read/write valid signals** … to allow for address generation only when the FPGA fabric is
> out of reset and a valid transaction is present."*

**Implementation difference:** both the current `SAR_TOP.v` auto-wrapper and the proposed
`sar_axi_idconv.v` drive the FIC0_S **upper address bits with a static constant** (`6'h0`).
This is precisely the "tied off" pattern the doc warns locks the FIC, and **our observed
symptom is a FIC-side lock-up (master hangs, no AXI response)** — so this is a **co-primary
root-cause candidate alongside the ID-truncation theory**, not a minor nit.
Caveat: the doc's lock-up was seen when bits needed to be *set to 1* (38-bit translation),
whereas our 32-bit cached window legitimately needs 0; a constant 0 *may* be benign. But given
the symptom match, the **gated address shim** (AND upper bits with `ARESETN & xVALID`) is the
documented-safe construction and should be folded into the converter.
**Action:** add the resetn∧valid gate to `M_AXI_ARADDR`/`M_AXI_AWADDR` upper bits in
`sar_axi_idconv.v`; if the ID fix alone doesn't clear the hang, this is the next thing to try
*before* the SmartDebug probe.

### 9.2 Fabric masters + cached DDR → L2 coherency is a real, configurable concern
`mpfs-memory-hierarchy.md` lists dedicated L2 **WayMask registers for the FPGA-fabric AXI4
ports**: `WayMask1=0x0201_0808` (fabric port 0) … `WayMask4=0x0201_0820` (fabric port 3).
**Implementation difference / risk:** SIG/SCRATCH/OUT live in **cached** 32-bit DDR
(`0x8/9/A…`). When the host JTAG-loads SIG and the CPU has touched it, fabric reads can see
**stale DDR vs L2** unless the CPU flushes (and the fabric port's WayMask is configured). This
won't cause the *first-read hang* (a coherency miss returns wrong data, not no-response), so it
is **downstream of** the current blocker — but it must be handled before image data is trusted.
**Action (already in the plan as risk #5/#6):** either move the fabric-visible buffers to
**non-cached** DDR (`0xB0…`/38-bit non-cached), or do explicit `FENCE`/L2 `Flush32/Flush64`
around fabric regions and set the fabric-port WayMask. Matches Microchip's recommended
"reserve ways for fabric+hart shared data" affinity pattern. This refines report risk #6, which
previously only flagged a possible *address-alias* need.

### 9.3 DDR has FOUR distinct windows; confirm the FIC0_S target maps the one we drive
`mpfs-memory-configuration.md`: any initiator sees **cached-32 / non-cached-32 / cached-38 /
non-cached-38** ranges; MSS AXI interfaces are **38-bit** with a *1 GiB range* and a *64 GiB
range*. Our converter zero-extends the kernel's 32-bit address into the **1 GiB (low) 38-bit
range**, which targets cached-32 DDR (`0x80000000…`). That is internally consistent with the
DDR map in §1, **but it has never been confirmed that FIC0_S's target decode actually places
DDR where the fabric is driving it** — this is the same uncertainty as the ARREADY-stall
hypothesis in §4. No change required if the probe shows AR is accepted; listed for completeness.

### 9.4 Minor — FIC choice and clock rate (informational, not bugs)
- **FIC selection:** the doc *recommends FIC1* for a fabric↔DDR target "due to its placement …
  to allow timing closure at higher frequencies." We use **FIC0_S**. Legal (FIC0/1/2 may all be
  AXI targets) and timing already met at our clock, so no action — just noted as a deviation
  from the doc's placement guidance should timing get tight.
- **Clock rate:** the reference design runs the FIC/AXI domain at **125 MHz** (max 250 MHz);
  our fabric runs off the 160 MHz oscillator through the CCC. Within spec; flagged only so the
  FIC0_S timing constraint is checked against whatever `CCC_OUT0_FABCLK_0` resolves to.

### 9.5 Confirmed-correct (no difference)
- **Boot mode 1** (`boot-mode-1-fundamentals.md`): MSS harts execute from eNVM on power-up,
  reset vectors from `U_MSS_BOOTCFG` in pNVM — exactly our boot path (§3). Default 80 MHz SCB
  clock before MSS clock config, consistent with our bring-up.
- **38-bit AXI target width** on FIC matches the converter's `M_AXI` 38-bit address.
- **Fabric→DDR throughput** (`fabric-dma-benchmarking.md`): F-DMA sustains ~7.4 Gb/s
  (≈93% of the 64-bit×125 MHz = 8 Gb/s ceiling). Corroborates the plan's decision to keep the
  corner-turn / bulk movement **in fabric DMA** rather than MSS PDMA — but note this ceiling
  (~0.9 GB/s effective) is the real throughput budget for the full-frame data plane once it runs.

---

## 10. Build & program procedure (what actually worked, 2026-06-29)

**Build (headless `libero.exe SCRIPT:`):** open `libero_sar/sar_accel.prjx` →
`run_tool SYNTHESIZE / PLACEROUTE / VERIFYTIMING / GENERATEPROGRAMMINGDATA / GENERATEPROGRAMMINGFILE`
→ `export_prog_job` → `export/SAR_TOP_idfix.job`. Add `configure_tool PLACEROUTE
{REPAIR_MIN_DELAY:true}` to clear the CoreFFT hold violations (§6.8). Timing then fully met
(setup + hold, "No Path" violations).

**Program fabric (FlashPro):** `libero.exe SCRIPT:` → `open_project` → `run_tool PROGRAMDEVICE`.
This regenerates programming data and programs over the embedded **FlashPro6 on connector J33**
(IDCODE `0x0F81A1CF` = MPFS250T_ES; "Scan and Check Chain PASSED"; "PROGRAM PASSED", ~1 min).
The `.ppd` programs **Fabric + sNVM + eNVM**, so do this **before** the firmware step.
- ⚠ **FlashPro Express *console* mode is broken on this install** — `new_project` fails to create
  its `.pro` ("Failed to create the new project file") in any location, so `program_fabric.tcl`
  (FPExpress) is unusable. Use Libero `PROGRAMDEVICE` (above) or the **FPExpress GUI** instead.
- ⚠ Connector: it's **J33** on this kit, not J11. (`mpfs/BRINGUP.md`'s J11 note is wrong.)

**Program firmware → eNVM + boot mode 1:** `bash mpfs/host/run_program.sh` (copies the
DDR-666MHz-Release `.elf` → `bm1/app.elf` → `mpfsBootmodeProgrammer.jar --bootmode 1`). Reliable
(`fpgenprog`, not OpenOCD). Do this **after** the fabric program (which wrote eNVM with the design
default).

**Verify:** power-cycle → `bash mpfs/host/run_m2.sh` (one short OpenOCD read of the `0xB0050000`
result table). Success = `tag=0x30` `st=0` + SCRATCH changed.

**Gotchas:** the git-bash `tasklist` is restricted (~3 lines) — judge background-job progress by
file mtimes, not process listings. Long `PROGRAMDEVICE`/build runs should go in the **background**
(a fixed 10-min foreground timeout will cut off a still-progressing program).
