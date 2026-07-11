---
name: silicon-iso-test
description: >-
  Run a JTAG silicon iso-test of a fabric kernel path end-to-end (openocd + gdb over FlashPro6),
  with the project's JTAG hygiene enforced so the FlashPro6 is never wedged. Use to drive
  run_corefft_iso.sh / run_*_iso.sh, poke a fabric kernel over JTAG, and read DDR back. Triggers:
  "run the iso-test", "test on silicon", "check the feeder/unloader/CoreFFT on the board".
---

# silicon-iso-test

Runs a silicon iso-test on the PolarFire SoC SAR board. JTAG hygiene correctness beats speed:
a violated rule wedges the FlashPro6 and forces a physical recovery. Full detail in
`docs/fpga/SILICON_ISO_TEST_RUNBOOK.md` §1-§4.

## Prerequisites (confirm first)
- Board powered ON; fabric programmed with the build under test; eNVM holds the debug APP
  (boot mode 1 or boot-mode-0 WFI) so hart1 can halt — NEVER an HSS build.
- No stale `openocd.exe` running (pre-flight `tasklist | grep openocd`).

## Procedure
1. Pick the smallest decisive case: `CASES=impulse` (one 8192-pt frame) for a clean diagnostic;
   `NBEATS_OVERRIDE=64` for a single-burst probe. Multi-frame runs can wedge FIC0 and hang
   `flush_l2_cache` ~5 min.
2. Delegate to the `silicon-test-runner` agent, or run `run_corefft_iso.sh` directly. Watch the
   **openocd log** (flushes live) to distinguish "connecting -> progressing" from "wedged at
   connect" — the gdb stdout is block-buffered through the grep pipe and hides progress.
3. The gdb template captures the decisive signals (feeder/unloader `busy` at t=2s and t=10s, a
   raw SCRATCH dump) BEFORE the coherent evict-flush, so data survives even if the flush hangs.
4. Report per row: feeder busy, unloader busy, SCRATCH samples, correlation vs golden, PASS/FAIL.

## Hard rules (NEVER violate)
- NEVER `taskkill /F` openocd/gdb — wedges the FlashPro6 DM. Clean stop = gdb's `monitor resume`
  + `monitor shutdown`, or telnet `shutdown` to openocd 4444 (note: run_corefft_iso.sh's openocd
  has no telnet port yet — add `-c "telnet_port 4444"` if graceful mid-run stop is needed).
- If forced to kill: gdb (client) first, then openocd. A wedged FlashPro6 needs a **USB replug +
  board power-cycle** — a board power-cycle ALONE does not clear an FP6 wedge.
- FIC0 is non-coherent: `flush_l2_cache(1)` before arming (push input) and before readback (evict
  dst). Windows-native gdb needs `C:/` paths, not MSYS `/c/`.
- Always leave the toolchain shut down cleanly; confirm no orphaned gdb/openocd remain.

## After
Update the runbook the SAME session if a new gotcha appears (per `update-docs-with-tested-
approaches`). If internal fabric visibility is needed, follow with the `smartdebug-probe` skill.
