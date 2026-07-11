# Fabric Interconnect Conventions (SAR on PolarFire SoC)

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`../PROJECT_SOURCE_OF_TRUTH.md`](../PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". The `CoreAXI4DMAController` whose AXI4-Lite control slave motivated the conventions
> below has been **removed** — so its CIC slave-5 (`TARGET5_TYPE=1` + address slice) is no longer in the
> built design. The conventions themselves (isolate the config plane, match target `TYPE` to protocol,
> explicit width-mismatch slices, lint-gate every build) still hold as general rules; only the specific
> "current DMA control" example is stale.

Conventions + tooling that prevent the silent-integration failures that cost the DMA control-slave
bring-up many build cycles. See [dma_fix_plan.md](dma_fix_plan.md) §7 for the full root-cause saga.

## Why this exists — two silent failures Libero allowed
1. **Protocol-inference mismatch.** A 32-bit reduced-AXI4-Lite peripheral (CoreAXI4DMAController's
   `AXI4TargetCtrl`) was attached to the shared 64-bit crossbar with the interconnect target left at
   `TYPE=0` (Full AXI4). The 64→32 down-converter (DWC) then tried full-AXI4 (burst/ID) conversion onto
   a strict single-beat Lite target → `CTRL_ARVALID` never reached the DMA → hart hung un-haltably.
   No warning. (SmartDebug proved it: the target FSM stayed IDLE during the hung read.)
2. **Asymmetric address grounding.** `sd_connect_pins` of a 32-bit interconnect address to the DMA's
   11-bit `CTRL_ARADDR` **silently left it tied to `0`** (default const) — no error. Only offset-0
   (VER) would have been reachable; every other register access would have aliased to register 0.

## Convention 1 — isolate the config plane behind an AXI4-Lite firebreak
Do **not** wire AXI4-Lite config/register ports *directly* onto the wide (64-bit, multi-master) data
crossbar. Route config-plane access through a dedicated **AXI4→AXI4-Lite bridge / isolated 32-bit
config sub-bus**. Everything downstream of that bridge is then *structurally guaranteed* single-beat,
ID-stripped, native-width — so the width-DWC and protocol-inference traps **cannot occur**.
- ~~Current DMA control: on the shared CIC with `TARGET_TYPE=1` + explicit address slice (functional).~~
  *(Stale 2026-07-04 — the DMA was removed; see update note at top.)* The dedicated bridge/sub-bus is
  the cleaner pattern to adopt for *future* config peripherals.

## Convention 2 — set interconnect target TYPE to match the peripheral protocol
`CoreAXI4Interconnect` `TARGETn_TYPE` enum (from `TrgtProtocolConverter.v`): **0=AXI4, 1=AXI4-Lite,
3=AXI3**. A reduced-AXI4-Lite peripheral (no `AxID`/`AxBURST`/`AxPROT`) **must** be `TYPE=1` so the
interconnect inserts the AXI4→AXI4-Lite protocol converter *before* the DWC.
- Reduced-Lite peripherals here: **DMA `AXI4TargetCtrl`** (no `AxPROT`, 11-bit addr) → CIC slave-5 = `TYPE=1`.

## Convention 3 — wire width-mismatched buses with EXPLICIT slices
`sd_connect_pins` silently leaves a width-mismatched bus disconnected (falls back to the default const
tie). A bare `pin[10:0]` name is **rejected** (`SDCTRL05: Pin '' does not exist`). Correct headless:
```tcl
sd_create_pin_slices -sd_name SAR_TOP -pin_name {CIC:TARGET5_ARADDR} -pin_slices {[10:0]}
sd_connect_pins      -sd_name SAR_TOP -pin_names {"CIC:TARGET5_ARADDR[10:0]" "DMA:CTRL_ARADDR"}
```
(Create the slice first, then connect it.) See `mpfs/fpga/build_addrfix.tcl`.

## Convention 4 — lint-gate every build (pre-synth firebreak)
Since Libero won't flag these, gate it ourselves. Run the linter **after `generate_component`, before
`run_tool SYNTHESIZE`** — a 1-second grep vs a ~30-min synth+P&R:
- **`mpfs/fpga/lint_netlist.sh`** — fails (exit 1) on slave-side address/data tied to const; warns on
  floating AXI pins; audits interconnect target `TYPE`s (flags reduced-Lite-on-TYPE=0 risk).
- **`mpfs/host/run_build_safe.sh`** — the build wrapper: `[prep.tcl] -> lint gate -> synth/P&R/program`.
  Use this instead of calling `build_dmafix.tcl` directly so a broken netlist never burns a P&R run.

## Gotchas (cross-cutting)
- Two versions of the same DirectCore can't coexist (module-name collision: both define
  `module COREAXI4INTERCONNECT`). If you upgrade one interconnect, upgrade **all**.
- After any IP reconfigure, refresh the SmartDesign instance headless via
  `sd_update_instance -sd_name SAR_TOP -instance_name <INST>` (= GUI "Update Instance with Latest
  Component") before reconnecting/generating.
- IP version upgrades **reset** the configurator to defaults (2 init/2 target) — re-enter the full
  config (counts, per-target addr/width/type, crossbar) and re-run the reconnect script.
