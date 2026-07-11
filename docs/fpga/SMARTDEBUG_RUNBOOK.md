# SmartDebug Runbook — DMA control-slave "deaf read" diagnosis

**Goal:** determine *why* the CoreAXI4DMAController AXI4-Lite control slave (`0x60005000`) never
completes a read (`RVALID` never asserts → hart-1 hangs). The RTL is deterministic, so a single
flip-flop — the target FSM state register `currState` — plus `ARVALID` resolves the root cause.

> Companion to [dma_fix_plan.md](dma_fix_plan.md). Background: §7b/§7c/§7d there.

---

## 0. Why this works (and why it's safe)

- When hart-1 reads a deaf slave, the AXI **address phase is held static forever** (`ARVALID=1`,
  waiting for `ARREADY`). There is no bus timeout (RC2). So the signals are **DC-stable** during the
  hang — perfect for **Active Probe**, which reads static FF values over the JTAG **probe network**.
- Active Probe uses the **fabric probe network**, *not* the RISC-V debug module (DMI). So it works
  **even though hart-1 is un-haltable**, and it does **not** hammer the DMI — i.e. it won't reproduce
  the OpenOCD HID-lockup we hit before. **Do not** run OpenOCD/SoftConsole-debug at the same time —
  only one tool may own the FlashPro6. Close them first.

## 1. The deterministic logic (from the RTL)

`coreaxi4dmacontroller_axi4_lite_target_ctrl.v`, IDLE state:
```verilog
IDLE: if (AWVALID) ... ; else if (ARVALID) begin ARREADYReg_d = 1; nextState = AXI_RD_ADDR; end
```
ARREADY is asserted on ARVALID **unconditionally** in IDLE. So if the slave is deaf, exactly one of:

| # | `currState` | `ARVALID` (at DMA) | Meaning → next action |
|---|---|---|---|
| A | **IDLE (0x001)** | **1** | FSM sees the request but won't advance ⇒ **clock not toggling at this FSM**, or **resetn asserted here**, or the probe `ARVALID` is a different net than the FSM input. Physically near-impossible (shared clk/rst work for kernels) ⇒ strong **Microchip support** signal. |
| B | **IDLE (0x001)** | **0** | Request **never reaches the DMA** ⇒ problem is **upstream** (CIC crossbar/decode/DWC), not the IP. Probe the CIC master-5 AR path next. |
| C | **non-IDLE** (e.g. `AXI_WAIT_RD=0x080`, `AXI_WAIT_RDY=0x008`) | any | FSM **stuck mid-transaction** from a prior access — `ctrlRdRdy`/`RREADY`/`BREADY` never completed. The control-register block isn't returning `ctrlRdRdy`, or a previous beat wedged it. |

`currState` one-hot encodings:
`IDLE=0x001  AXI_WR_ADDR=0x002  AXI_WAIT_VALID=0x004  AXI_WAIT_RDY=0x008  AXI_WR_DATA=0x010`
`AXI_WR_RESP=0x020  AXI_RD_ADDR=0x040  AXI_WAIT_RD=0x080  AXI_WAIT_RD_RREADY=0x100`

## 2. Probe targets (search these net names in SmartDebug's Add-Active-Probe dialog)

Top instance is **`DMA`** (`SAR_TOP/DMA/...`). Filter the probe tree by name:

| Net (substring to search) | What it tells you |
|---|---|
| `currState` (9 FFs `currState[0..8]`) | **The key.** Decodes per table above. |
| `ARREADYReg`, `RVALIDReg` | What the FSM is *driving* back (expect both 0 when deaf). |
| `ARVALID` / `CTRL_ARVALID` (DMA boundary) | Is the read request arriving at the IP? |
| `invalid_rdaddr` | If 1, the IP flagged the address invalid (would drive SLVERR, not hang). |
| CIC master-5 `*ARVALID*`, `*ARREADY*` | Only if case B — confirm where upstream it dies. |

> One-hot state regs sometimes survive P&R as individual FFs. If `currState` isn't listed, search
> `state` and look under `DMA/.../*lite_target*`.

## 3. Procedure

### Phase A — idle baseline (SAFE, no hung hart)
Use the **current firmware** already on the board (`M2_PROBE_DMA=0`, no DMA read).
1. Board powered, USB on **J33**. Close OpenOCD/SoftConsole debuggers.
2. Libero → **SmartDebug** → *Debug FPGA Array* → connect.
3. **Active Probes** tab → add `currState[*]`. **Read.**
   - **Expect `IDLE=0x001`.** If non-IDLE *at rest* → the FSM is wedged from boot (before any access)
     — that's the bug, found risk-free. Skip to §4.
   - If `IDLE` → FSM healthy at rest; proceed to Phase B.

### Phase B — during the hung read
1. Build firmware with `#define M2_PROBE_DMA 1` (in `application/hart1/u54_1.c`) and program it
   (`run_program.sh` / eNVM). **Re-program firmware after any `PROGRAMDEVICE`** (it wipes eNVM).
2. Power-cycle so hart-1 boots, runs M2, hits the `VER` read at `0x60005000`, and **hangs**.
3. SmartDebug → connect → **Active Probes** → add `currState[*]`, `ARVALID`(DMA), `ARREADYReg`,
   `RVALIDReg`. **Read** (read twice, a few seconds apart — values must be *stable*, since the hang
   is permanent).
4. Decode with the table in §1.

### Optional Phase C — Live Probe (needs scope)
Only if a *transient* view is wanted: assign `CTRL_ARVALID` + `CTRL_ARREADY` to the two Live-Probe
channels (routed to device probe pins) and scope them. For a permanently-hung read this is DC, so
Active Probe (Phase B) is usually sufficient.

## 4. Outcome → decision

- **Case C (stuck non-IDLE):** capture `currState`, the control-register-block `ctrlRdRdy`/`ctrlSel`
  nets if probe-able. This is an internal IP completion failure → **Microchip support** with the
  state value + this runbook.
- **Case B (ARVALID=0 at DMA):** the IP is innocent; the request dies in the CIC. Re-probe the CIC
  master-5 AR path; revisit the crossbar/DWC config (despite §7b verifying decode).
- **Case A (IDLE + ARVALID=1, no advance):** clock/reset-at-FSM anomaly or a genuine erratum →
  **Microchip support** (this is the strongest "IP defect on correct integration" evidence).

## 5. For a Microchip support case (if A or C)
Attach: this runbook's measured `currState`, dma_fix_plan.md §7b–§7d (full ruling-out), IP version
**2.2.107**, and the note that the *same* IP version works in the icicle-kit reference design.

---

## 6. CoreFFT `BUF_READY` stall diagnosis (M3 pipeline, stage 5)

**Goal:** the M3 PIPE run completes stages 1–4 but the range-FFT times out; the DMA-register probe
showed the **DMA armed but 0 bytes moved and the feeder still busy** ⇒ the gearbox gates the feeder
with `s_axis_tready = in_phase & buf_ready`, so **CoreFFT `BUF_READY` is not asserting**. Determine
whether that's because **twiddle-init never completed** (clocking/init root cause) or a **downstream
handshake** bug. See [SAR_PIPELINE_PROCESS.md](SAR_PIPELINE_PROCESS.md) §10 and
[m3 memory]. Instances (from `build_sartop.tcl`): `FFT` (COREFFT_C0), `GBX`
(corefft_stream64_adapter), `FEED` (fft_feeder), `DMA`.

### Why `BUF_READY` at idle is decisive
Per CoreFFT_UG (Table 2-2): *"BUF_READY — the core asserts the signal when it is ready to accept
data"*, and twiddle-LUT init runs automatically after `NGRST`. So a **healthy** core asserts
`BUF_READY=1` once init completes — **even before any data is fed**. Therefore probing `BUF_READY`
**at idle** (board booted, M2 battery done, command loop spinning, NO PIPE run) bifurcates the bug
with zero risk (DC-stable, no hung hart).

### Phase A — idle `BUF_READY` (SAFE, decisive)
1. Board powered, USB on **J33**. **Kill OpenOCD** (`taskkill /F /IM openocd.exe`) and close
   SoftConsole — only one tool may own the FlashPro6.
2. Libero → **SmartDebug** → *Debug FPGA Array* → connect.
3. **Active Probes** → search and add **`BUF_READY`** (FFT instance output; same net as `GBX:buf_ready`).
   **Read** (twice, a few seconds apart — must be stable).

| `BUF_READY` at idle | Meaning → next action |
|---|---|
| **0** | **Twiddle-init never completed** ⇒ clocking/init root cause CONFIRMED. Go to Phase A2 (SLOWCLK), then apply the rebuild fixes: add [sar_fft_cdc.sdc](../../mpfs/fpga/libero_sar/constraint/sar_fft_cdc.sdc) (CLK↔SLOWCLK false-paths) and set CCC **FF_REQUIRES_LOCK=1** ("wait for PLL lock"). |
| **1** | Core is healthy and ready ⇒ the stall is **downstream** (feeder→gearbox handshake or the stream not draining), NOT clocking. Go to Phase B. |

### Phase A2 — confirm SLOWCLK (only if `BUF_READY=0`)
- SmartDebug: check the **CCC PLL lock** status (probe `PLL_LOCK` / the CCC debug). If not locked →
  CCC/PLL problem.
- **Live Probe** `SLOWCLK` (CCC `OUT1_FABCLK_0`) to a device probe pin + scope → confirm it toggles at
  **15.625 MHz**. Dead/wrong-freq → CCC OUT1 issue (re-apply `reconfig_ccc.tcl`, rebuild). Toggling but
  `BUF_READY` still 0 → twiddle-init logic / CDC / reset-race → the false-path + FF_REQUIRES_LOCK fixes.

### Phase B — stream handshake during an FFT run (only if `BUF_READY=1`)
Needs the FFT stage *active*. Because OpenOCD and SmartDebug can't share the FlashPro6, the simplest
capture: trigger a PIPE run (mailbox `cmd=PIPE`, resume hart1) via OpenOCD, **kill OpenOCD**, then —
within the stall window — SmartDebug Active-Probe these (registered nets; for combinational
`s_axis_tready` probe its inputs `in_phase`+`buf_ready` instead):

| Probe (search substring) | Healthy-flowing | Stuck meaning |
|---|---|---|
| `FEED` `out_var_valid` | toggling/1 | 0 ⇒ feeder not producing (its DDR read path) |
| `GBX` `in_phase` | toggling | stuck ⇒ no beats consumed |
| `FFT` `DATAI_VALID` | toggling/1 | 0 ⇒ gearbox not forwarding to CoreFFT |
| `DMA` stream `TVALID`/`TREADY` (out side) | toggling | stuck ⇒ FFT not producing / DMA not draining |

(If Phase B is needed often, consider a small firmware "FFT-hold" command that arms DMA + starts the
feeder and spins forever — holds the stalled state indefinitely for unlimited SmartDebug probing.)
