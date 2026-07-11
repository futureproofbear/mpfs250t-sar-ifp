# DMA Control-Slave Fix Plan (Blueprint)

**Goal:** clear the structural debt around the **CoreAXI4DMAController** so the S2MM datamover
(FFT-stream → DDR) works end-to-end — not a band-aid. Scope = the DMA *control* path only; the
fabric *data* plane is already fixed (see `SAR_BRINGUP_REPORT.md` §4–§5: `sar_axi_idconv`, M2 PASS).

Status as of 2026-06-29: **planned.** The data-plane fix is verified on silicon; the DMA control
slave at `0x60005000` (CIC `SLAVE5`) still does not respond. This plan closes it.

---

## 1. Why this matters (what's blocked)
`DMA` (`AXIDMA_C0`, CoreAXI4DMAController) is the **S2MM datamover** that writes CoreFFT's output
AXI-Stream (via the `GBX` gearbox) into DDR. The full pipeline
`resample → window → FFT → corner-turn → FFT → detect` needs it for the FFT-stage writeback. With
its control slave dead, the sequencer can't program/kick a descriptor, so the pipeline can't
complete past the FFT stages. (The resample stage we validated does **not** use the DMA.)

---

## 2. Root causes (the structural defects)

| # | Defect | Evidence | Severity |
|---|---|---|---|
| **RC1** | **Data-width mismatch, no DWC.** CIC `SLAVE5` is **64-bit** (`SLAVE5_DATA_WIDTH=64` in `AXIIC_CTRL.cxf`); the DMA control interface is **fixed 32-bit AXI4-Lite**. The interconnect drives 64-bit into the 32-bit port with no Data-Width Converter → the AXI4-Lite handshake never completes → read hangs. | DRC: `CIC:AXI4mslave5_WDATA[0-63]` vs `DMA:AXI4TargetCtrl_IF:CTRL_WDATA[0-31]`. It is the **only** control slave with a *data*-width mismatch — and the only one that hangs. | **Primary** |
| **RC2** | **No interconnect timeout / default-slave.** A non-responding slave blocks the master forever (no DECERR), so the fault is un-observable and froze the hart in M1. | Docs: CoreAXI4Interconnect has no built-in timeout. M1: CPU read of `0x60005000` hung the hart un-haltably. | High (observability) |
| **RC3** | **Wrong control-register offsets in firmware.** `sar_sequencer.c` used `DMA_INTR0_STATUS=0x08` for both status-read and W1C-clear; the IP's interrupt-0 status is **`I0ST=0x10`** and clear is **`I0CLR=0x18`**. | `coreaxi4dmacontroller_regs.h`: `I0ST_REG_OFFSET 0x10`, `I0CLR_REG_OFFSET 0x18`. (FIXED in this commit — see §4 step 3.) | Medium |
| **RC4** | **No on-silicon DMA test.** Harness is compiled `M2_PROBE_DMA=0`, so `tag=0x50` is a hard-coded placeholder; the DMA is never actually probed. | `u54_1.c:189–199`. | Medium (test gap) |

**Authoritative references:** register map = `polarfire-soc-bare-metal-examples/.../CoreAXI4DMAController/
coreaxi4dmacontroller_regs.h`; driver = `core_axi4dmacontroller.c`/`.h`. No IP handbook PDF is installed.

---

## 3. Confirmed register map (CoreAXI4DMAController control slave, base `0x60005000`)
```
0x00  VER_REG      version (build/minor/major) — a known-nonzero read = "slave responds"
0x04  START_REG    write bit n = start descriptor n
0x10  I0ST         interrupt-0 status   (bit0 = descriptor-0 complete)
0x14  I0MASK       interrupt-0 mask
0x18  I0CLR        interrupt-0 clear    (W1C)
0x1C  I0EXADDR     interrupt-0 external address
0x60  ID0CFG       descriptor-0 config  (bit31 DESCVALID, bit3 dest-incr, bit0 src=stream, …)
0x64  ID0BYTECNT   descriptor-0 byte count
0x68  ID0SRCADDR   descriptor-0 source address
0x6C  ID0DESTADDR  descriptor-0 destination address
0x70  ID0NEXTDESC  descriptor-0 next-descriptor pointer
      (descriptor n at 0x60 + n*0x20)
```

---

## 4. The fix (ordered; each step clears one structural defect)

### Step 1 — RC1: make CIC Slave-5 32-bit (GUI; the primary fix)
In Libero, open the **`AXIIC_CTRL` (CIC)** CoreAXI4Interconnect configurator →
**Slave Configuration → Slave 5 → Data Width = 32** (leave Slaves 0–4 at 64). This makes the
interconnect insert a Data-Width Converter on that leg, matching the 32-bit DMA control slave.
- **GUI only.** Do **NOT** `delete_component`/`create_and_configure_core` headless — that defaults the
  whole core to 2m/2s (the AXIIC_C0 lesson; see `SAR_BRINGUP_REPORT.md` §5 warning).
- After: **Update the CIC instance** in SAR_TOP if prompted; Generate; re-run DRC and confirm the
  `CIC:AXI4mslave5 … CTRL_WDATA` data-width-mismatch warning is **gone**.

### Step 2 — RC2: enable a default-slave / access timeout (GUI/IP)
On the interconnect(s), enable an **access timeout / default-slave** so an unmapped or
non-responding target returns **DECERR** instead of hanging. This is both a safety net (no more
un-haltable hangs) and what makes Step 4's probe trap-catchable. If the installed
CoreAXI4Interconnect lacks a timeout option, add a small fabric watchdog/decode-error responder on
the `SLAVE5` leg, or rely on Step 1 removing the hang and keep `m2_safe_r` as the guard.

### Step 3 — RC3: correct firmware register offsets (DONE)
`sar_sequencer.c` updated: `DMA_INTR0_STATUS 0x08 → 0x10` (I0ST) and added
`DMA_INTR0_CLEAR 0x18` (I0CLR, used for the W1C). Descriptor offsets verified correct
(CFG/BYTECNT/SRC/DST = `0x60/0x64/0x68/0x6C`). **Recommended further:** replace the hand-rolled
register poking with the vendor `core_axi4dmacontroller.c`/`_regs.h` driver to remove the debt
permanently.

### Step 4 — RC4: re-enable the on-silicon DMA probe
In `u54_1.c` set `#define M2_PROBE_DMA 1`. With Step 1 (responds) + Step 2 (timeout), the
trap-protected `m2_safe_r()` now either reads a real value or catches a DECERR as `M2_FAULT` —
never an un-haltable hang. Probe order: read `VER_REG (0x00)` first (cheapest "does it respond").

---

## 5. Build & program (after Steps 1–2 in the GUI)
1. Headless rebuild: `libero.exe SCRIPT:` → `run_tool SYNTHESIZE / PLACEROUTE` (keep
   `configure_tool PLACEROUTE {REPAIR_MIN_DELAY:true}`) `/ VERIFYTIMING / GENERATEPROGRAMMINGDATA /
   GENERATEPROGRAMMINGFILE` → `export_prog_job`.
2. Rebuild firmware (SoftConsole make) with `M2_PROBE_DMA=1` + the offset fix.
3. Program fabric: `libero.exe SCRIPT: run_tool PROGRAMDEVICE` (FlashPro6 / **J33**).
4. Program firmware: `bash mpfs/host/run_program.sh` (boot mode 1, eNVM).
5. Power-cycle → `bash mpfs/host/run_m2.sh`.
(See `SAR_BRINGUP_REPORT.md` §10 for the full procedure + gotchas.)

---

## 6. Acceptance criteria (definition of done)
- [ ] DRC: **no data-width mismatch** on `CIC:AXI4mslave5` (RC1 cleared).
- [ ] `tag=0x50` (with `M2_PROBE_DMA=1`) reads a **non-zero `VER_REG`** — the control slave responds
      (was an un-haltable hang).
- [ ] A test S2MM descriptor (program `ID0` CFG/BYTECNT/SRC/DST, write `START_REG` bit0, poll
      `I0ST` bit0) **completes**, writing a known pattern from a stream source to a DDR address,
      verified by host JTAG read-back.
- [ ] Dead/unmapped accesses return **DECERR**, not a hang (RC2 cleared) — verify by probing an
      unmapped offset.
- [ ] Firmware DMA offsets match `coreaxi4dmacontroller_regs.h` (RC3 — done) and ideally use the
      vendor driver.

---

## 7. Risks & fallbacks
- **Step 1 is the leading hypothesis, not proven.** If the slave still hangs after the width fix,
  Step 2's timeout makes it *diagnosable*: next suspects = DMA core clock/reset, or a descriptor/
  enable precondition before the control slave answers. SmartDebug live-probe the `SLAVE5`
  `AWREADY/ARREADY` to localize (asserts ⇒ accepted; never ⇒ width/decode).
- **GUI reconfigure caution:** changing CIC slave widths can perturb placement → re-check timing
  (the `REPAIR_MIN_DELAY` flow already handles the CoreFFT hold paths).
- **Scope creep:** if the DMA proves deep, the resample/window/detect stages can still be exercised
  without it for partial-pipeline validation; the DMA gates only the FFT-stream writeback.

---

## 7b. On-silicon results & exhaustive ruling-out (2026-06-29)

**RC1 (width fix) is DONE but CONFIRMED INSUFFICIENT on silicon.** With CIC Slave-5 = 32-bit + DWC
programmed and firmware rebuilt with `M2_PROBE_DMA=1`, the on-hart read of `VER (0x60005000)` **still
hangs hart 1 un-haltably** (`Error: unable to halt hart 1`, `dmstatus=0x00030c82`, "Fatal: Hart 1
failed to halt"). No DECERR, no response — identical to the original M1 symptom.

**This is an ORIGINAL issue, not a regression** — the DMA control slave never responded (M1, before any
of this work). The data plane and control plane are unaffected (M2 `tag=0x30` still PASS on this fabric).

**Everything addressable on-disk/in-docs has been verified CORRECT, yet the slave does not ACK:**
- Address decode: `SLAVE5 = 0x60005000–0x60005fff` ✓ (matches the access).
- Master→Slave5 read/write enabled ✓.
- Data width: CIC Slave-5 = 32-bit, matches DMA `CTRL` (RC1) ✓ — DRC mismatch gone.
- Clock: `CCC_OUT0_FABCLK_0` (same as working kernels/interconnects) ✓.
- Reset: `RST_FABRIC_RESET_N` active-low, correct polarity ✓; no CDC (single clock domain).
- **Full `CTRL_*` handshake wired** (AR/AW/W/R/B VALID+READY, ADDR/DATA/RESP) to `CIC_AXI4mslave5_*` ✓.
- IP config complete: `AXI4TargetCtrl` + `AXI4Initiator` + `AXI4_STREAM_IF=1`, 32 descriptors ✓.
- Tied/floating ports all correct & benign: `STRTDMAOP=4'h0` (software-start, *not* a perpetual
  hardware trigger), `TSTRB/TKEEP=0xFF`, `TDEST=0`, `TLAST/TID=0` (fine for fixed-`ID0BYTECNT`
  single-stream S2MM), `INTERRUPT` open (poll `I0ST`). **None can block a control-register read.**
- No CoreAXI4DMAController/Interconnect handbook PDF is installed; the driver docs say the control
  slave "responds immediately to register reads if properly connected" — which it appears to be.

**Conclusion:** the non-response is **internal to the CoreAXI4DMAController control interface** (or a
config/erratum the visible parameters don't expose) — not width, clock, reset, CDC, decode, access, or
wiring. On-disk/documentation avenues are **exhausted**.

**⚠ Do NOT probe this slave with OpenOCD or an on-hart read** — both hang the hart un-haltably and can
lock the FlashPro HID (cost us several board power-cycles). The ONLY safe probe is **SmartDebug
Live/Active Probe** of `DMA:CTRL_ARREADY` / `CTRL_AWREADY` (signal-level, no AXI transaction): does the
IP ever assert READY? If never → IP-internal (regenerate `AXIDMA_C0` fresh, or Microchip IP support).
If it asserts but no `RVALID` → response-path issue. This is a GUI/interactive step.

## 7c. Handbook review (2026-06-29) — `CoreAXI4DMAController_HB.pdf`

The IP handbook (in the doc-mirror root) **confirms our symptom is a real, known class of bug** but
also that **our version already contains the fixes**, so it's not a version/config defect we can patch:

- **Instantiated IP = v2.2.107 (latest).** Changelog resolved-issues that match our symptom — all in
  ≤ v2.2, i.e. **already fixed in 2.2.107**:
  - v2.1: *"hang issue when accessing register addresses"*, *"Combinational loops when stream support
    is enabled … STRTDMAOP"*, *"Not getting TREADY in STREAM transaction"*.
  - v2.2: *"AXI interconnect issue when crossbar set for 64-bit accessing CoreAXI4DMAController"*
    (our exact CIC-64-bit case), *"register access issue when all write-strobe bits are zero"*.
- **Reset spec:** `RESETN` de-assertion must be synchronized to `CLOCK` externally — **met** here
  (CORERESET_C0 synchronizes `FABRIC_RESET_N` to `CCC_OUT0_FABCLK_0`; working kernels share it).
- **Control addr = `CTRL_AWADDR[10:0]`** (2 KB) — CIC Slave5 (`0x60005000–fff`) decodes it fine.
- **Synthesis: "No combinational loops were detected."** The read-path FSM
  (`coreaxi4dmacontroller_axi4_lite_target_ctrl.v`) **does** assert `ARREADY` on `ARVALID` (line 185).
- `TSTRB=0xFF` satisfies the handbook's "TSTRB must be AXI_DMA_DWIDTH/8".

**Net:** latest IP, all documented bugs fixed, no comb loops, FSM correct, integration correct — yet the
slave is deaf on silicon. **Static/doc analysis is exhausted.** The on-silicon behavior contradicts the
RTL, so the only paths left are **(1) SmartDebug** (observe the FSM/handshake live) or **(2) Microchip
IP support** (latest IP + everything correct + still fails ⇒ candidate erratum or a board/integration
subtlety only signal-level observation can expose). Regenerating the IP fresh is a cheap pre-step before
opening a support case.

## 7d. Regenerate-fresh & final lead sweep (2026-06-29) — CLOSED

- **Regenerate from catalog = futile.** Only **v2.2.107** exists in the vault
  (`C:/Microchip/Common/vault/...`), the project, **and the icicle-kit reference design**.
  Regenerating produces byte-identical RTL. The version match also **proves the IP is good** —
  it's the build Microchip ships in their own reference design.
- **CORERESET temporal lockout — ruled out.** M2 runs as hart-1 application code seconds after
  boot. Decisive: in the *same* M2 run, tag=0x30 reads the resample kernel @ `0x60003000` (st=0),
  which is reset by `~RST_FABRIC_RESET_N` — it can't answer unless fabric reset is released. The
  DMA shares that reset net.
- **POST_INV inversion mismatch — ruled out.** DMA uses raw `.RESETN(RST_FABRIC_RESET_N)`, not any
  `_POST_INV` net. POST_INV nets feed the 5 active-high kernels, which work (tag=0x30).

**CONCLUSION:** IP proven-good + integration exhaustively verified + every static lead ruled out ⇒
the only remaining diagnostics are **SmartDebug** (live/active-probe `CTRL_ARREADY`/FSM state) or a
**Microchip IP support case**. Static/config analysis is formally closed.

## 7e. SmartDebug VERDICT (2026-06-29) — ROOT CAUSE = CIC slave-5 delivery (Case B)

Ran the runbook on silicon. **DMA IP is innocent; the CIC does not deliver the read to slave-5.**

- **Phase A (idle):** `U_AXI4LiteTARGETCtrl.currState = 0x001` (IDLE) — control-slave FSM alive,
  clocked, out of reset, correctly idle at rest.
- **Phase B (during hung read, `M2_PROBE_DMA=1`):** `run_m2.sh` → "unable to halt hart 1"
  (`dmstatus=0x00030c82`) confirms the hart is frozen on the `0x60005000` read. SmartDebug active-probe
  *during that hang*: `currState` STILL `0x001` (IDLE), `ARREADY` (`currState[6]`) = 0.
- **RTL corroboration:** lite-target FSM asserts `ARREADY` on `ARVALID` *unconditionally* in IDLE;
  `ECC=0`; no `init_done`/`ram_init`/`init_complete` signal exists; `CTRL_ARVALID`→FSM and
  FSM→`CTRL_ARREADY` are wired **directly** (coreaxi4dmacontroller.v:450/468), no gating.
- Therefore: FSM stuck in IDLE during an in-flight read ⟹ **`ARVALID` never reaches the DMA** ⟹ the
  read is held **upstream in the CIC**. The CIC delivers fine to slaves 0-4 (kernel tags 0x10-0x23 PASS)
  but not slave-5 (the DMA — the only slave needing the RC1 64→32 width-converter).
- `currState`/handshake net mapping (from synthesis): `[6]`=ARREADY/AXI_RD_ADDR, `[8]`=RVALID,
  `[1]`=AWREADY, `[4]`=WREADY, `[5]`=BVALID. `CTRL_ARVALID` is combinational (no probeable FF).

**TARGETED FIX (attempted):** upgrade `AXIIC_CTRL` (CIC) → CoreAXI4Interconnect 3.0.130.
Ruled out by RTL+silicon: DMA IP, init/RAM gating, STRTDMAOP, clock/reset, FIC enable.

## 7f. 3.0.130 upgrade RESULT (2026-06-29) — did NOT fix; root cause = 64→32 DWC vs AXI4-Lite

- **Module-name collision:** both interconnect versions define `module COREAXI4INTERCONNECT`, so the
  CIC (3.0.130) and DIC (2.9.100) can't coexist → had to upgrade **both** AXIIC_CTRL **and** AXIIC_C0
  to 3.0.130 (each: GUI Update + reconfigure 2/2→correct + reconnect via `reconnect_{cic,dic}_330.tcl`).
- **Data plane: INTACT on 3.0.130** ✓ — M2 (`M2_PROBE_DMA=0`): tags 0x10-0x14, 0x20-0x23, 0x30, 0x40
  all PASS; SCRATCH written. The DIC upgrade did **not** regress anything.
- **DMA: STILL hangs** — M2 (`M2_PROBE_DMA=1`): hart un-haltable on `0x60005000` read
  (`dmstatus=0x00030c82`), identical to 2.9.100. **The interconnect version was NOT the cause.**
- **ROOT CAUSE (refined):** the **64→32 down-converter (DWC) on CIC slave-5 cannot deliver a
  single-beat AXI4-Lite read** to the 32-bit DMA control slave — fails **identically in 2.9.100 and
  3.0.130**. Slaves 0-4 (kernels) are 64-bit → no DWC → they work; slave-5 is the only down-converted
  one → black-holed. Mechanism (consistent with SmartDebug "frozen bridge": DWC accepts AR from FIC,
  never presents `CTRL_ARVALID`): the DWC's AXI4↔AXI4-Lite / narrow-burst / ID-FIFO handling stalls
  mid-conversion. No exposed AXI4-Lite-target `TYPE` to bypass it.

**REMAINING FIX OPTIONS (architectural — version upgrade exhausted):**
1. **Native 32-bit path for the DMA control** (no width conversion): route it off a dedicated 32-bit
   FIC (e.g. FIC_3) or a separate 32-bit bridge, *not* the shared 64-bit CIC. Moderate redesign +
   firmware base-addr change. Highest-confidence fix.
2. **Microchip support case** — precise, reproducible: "CoreAXI4Interconnect (2.9.100 & 3.0.130)
   64→32 DWC black-holes a single-beat AXI4-Lite read to a down-converted target; SmartDebug shows the
   target FSM never receives ARVALID." Attach §7b-§7f.
3. **Accept / defer** — data plane (the milestone) is verified on 3.0.130; DMA writeback can be
   host-offloaded. Current board state: clean firmware, data plane working.

State now: both interconnects 3.0.130, data plane verified, `M2_PROBE_DMA=0` clean firmware loaded.

## 7g. ✅ FIXED (2026-06-30) — TARGET5_TYPE = AXI4-Lite (protocol conversion before the DWC)

**Root cause (final):** CIC slave-5 was `TARGET_TYPE=0` (Full AXI4). Per `TrgtProtocolConverter.v`,
TYPE=0 is a *direct/pass-through* connection — so the DWC tried full-AXI4 (burst/ID) conversion onto
the DMA's strict **reduced-AXI4-Lite** control target, stalling mid-conversion → `CTRL_ARVALID` never
reached the DMA (the SmartDebug "frozen bridge"). Version-independent (2.9.100 & 3.0.130 both failed).

**Fix:** set CIC **`TARGET5_TYPE = 1` (AXI4-Lite, `2'b01`)** — engages the AXI4→AXI4-Lite protocol
converter (`TrgtProtocolConverter.v:308`, "drop signals not used by AXI4Lite") *before* the DWC, so the
DWC down-converts a clean single-beat Lite transaction. Enum (from RTL): `0=AXI4, 1=AXI4-Lite, 3=AXI3`.

**On-silicon result:** DMA control reads **COMPLETE** — `tag 0x50 @0x60005000 obs=0x00020064 (VER) st=0`,
no hang (previously hart-un-haltable). Data plane still PASS (tags 0x10-0x40).

**Wiring note / gotcha:** the DMA control is *reduced* AXI4-Lite (**no `AxPROT`**, 11-bit addr), while the
interconnect's AXI4-Lite target has `AxPROT` + 32-bit addr — so the BIF won't auto-connect. Done via
**pin-level** connect (skip `TARGET5_ARPROT/AWPROT`). Headless `sd_connect_pins` bridged the 1-bit
handshakes + 32-bit data, but **could not bridge the 32→11 address** (slice) — `CTRL_ARADDR/AWADDR`
remain tied to `0`. So only offset-0 (VER) is reachable now; **address must be wired in the GUI**
(`TARGET5_ARADDR[10:0]→CTRL_ARADDR`, AW too) for full register access (START @0x04, descriptors @0x60+).

**Address slice — DONE (2026-06-30, headless).** `sd_connect_pins` can't bridge 32→11 and a bare
`pin[10:0]` is rejected; the correct mechanism is **`sd_create_pin_slices`** then `sd_connect_pins` on
the created slice (see `mpfs/fpga/build_addrfix.tcl`). Verified on silicon: tags 0x50-0x53 now read
**distinct** registers (VER@0x00=0x00020064, START@0x04=0, 0x08=0, desc0@0x60=0), all st=0 — the address
carries the real offset, full register access confirmed.

**Prevention shipped:** `mpfs/fpga/lint_netlist.sh` (pre-synth gate: fails on slave addr/data tied to
const + audits target TYPE) wired into `mpfs/host/run_build_safe.sh`; conventions in
`FABRIC_INTERCONNECT_CONVENTIONS.md`.

**Remaining (optional, next milestone):** (1) re-point M2 summary-global read addrs (stale for rebuilt
fw — record table @0xB0050000 is valid); (2) full DMA *transfer* verify (write descriptor + START, move
data, confirm completion) — the control plane is now fully accessible for it.

**→ SmartDebug procedure: [SMARTDEBUG_RUNBOOK.md](SMARTDEBUG_RUNBOOK.md).** The AXI4-Lite target FSM
(`currState`, 9-bit one-hot) responds to a read unconditionally in IDLE, so probing `currState`+`ARVALID`
during the hung read deterministically isolates the cause (stuck FSM / request-not-arriving / clk-rst
anomaly). H1 (internal address-match drop) and H2 (RAM-init lockout) ruled out in RTL (combinational
read mux + SLVERR-on-invalid; ARREADY ungated in IDLE).

**Contingent fix (Case B only) — CoreAXI4Interconnect upgrade.** Libero reports **3.0.130** available
in the vault; project uses **2.9.100** for *both* `AXIIC_CTRL` (CIC, control — carries DMA reads) and
`AXIIC_C0` (DIC, data — WORKING). If SmartDebug shows **Case B** (read dies in the CIC before reaching
the DMA), upgrade **`AXIIC_CTRL` only** to 3.0.130: back up project → update that one instance → DRC →
rebuild → re-verify tag 0x30 *and* DMA. Do **not** bump `AXIIC_C0` (risks the verified data plane); watch
for CIC crossbar/width config-reset (cf. the AXIIC_C0 corruption incident). If Case A/C, the upgrade is
irrelevant — skip it.

## 7h. FFT-stage stall reattributed (2026-06-30) — bitstream timing, NOT the DMA

When the M3 full PFA pipeline (PIPE mailbox → `sar_form_image`) was wired, stages 1-4 ran on silicon
but the range-FFT appeared to hang — superficially the same "FFT-stage doesn't complete" symptom this
plan was written to fix. **It was NOT a DMA issue.** Real root cause: the **bitstream does not meet
timing at 125 MHz** — P&R reported 25,847/315,348 pins with negative slack (worst −3.7 ns), all on the
single 125 MHz fabric clock (CoreFFT itself: 0 violations), i.e. real same-clock setup failures →
non-deterministic silicon, so the FFT looped and stages 1-4 likely produced **corrupt** data even
where they "completed". Fix is a clock drop (CCC OUT0 125→62.5 MHz, OUT1 15.625→7.8125 MHz) + a gated
rebuild that aborts on negative slack — see `AMBA_ARCHITECTURE.md` §3 and `BRINGUP.md` watch-item #5.

**The DMA work in this plan is still correct and stands** — the §7g `TARGET5_TYPE=1` control-slave fix
and the external-stream descriptor fix (STR0ADDR `0x460`, cfg `0xD`) are unaffected; they were a real,
separately-verified defect. This note only reattributes the *FFT-stage stall* away from the DMA.
**Standing lesson: verify P&R timing closure before blaming logic/firmware.**

## 8. One-glance task list
1. [ ] (GUI) CIC `SLAVE5` data width 64 → 32; regenerate; DRC clean.
2. [ ] (GUI/IP) interconnect default-slave/timeout → DECERR on dead access.
3. [x] (FW) `sar_sequencer.c` I0ST/I0CLR offsets corrected (this commit).
4. [ ] (FW) `u54_1.c` `M2_PROBE_DMA=1`.
5. [ ] Rebuild bitstream + firmware → program (J33) → power-cycle → `run_m2.sh`.
6. [ ] Verify acceptance criteria (§6); update `SAR_BRINGUP_REPORT.md` §6.2 to RESOLVED.
