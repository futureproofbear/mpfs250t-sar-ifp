---
name: silicon-iso-test
description: >-
  Run a JTAG silicon iso-test of a fabric kernel path end-to-end (openocd + gdb over FlashPro6),
  with the project's JTAG hygiene enforced so the FlashPro6 is never wedged. Use to drive
  run_corefft_iso.sh / run_*_iso.sh, poke a fabric kernel over JTAG, and read DDR back. Triggers:
  "run the iso-test", "test on silicon", "check the feeder/unloader/CoreFFT on the board".
---

# silicon-iso-test

> The generic isolation-testing concept is also a portable package:
> `ai-framework/generic-fpga-soc/skills/kernel-isolation-testing/`. The Microchip-specific
> openocd/gdb/FlashPro6 mechanics are portable too: `ai-framework/microchip-fpga-soc/skills/
> microchip-iso-test-harness/`. This project-local skill stays authoritative for this project's
> exact scripts/addresses.

Runs a silicon iso-test on the PolarFire SoC SAR board. JTAG hygiene correctness beats speed:
a violated rule wedges the FlashPro6 and forces a physical recovery. Full detail in
`docs/USER_GUIDE.md` §3.3 (JTAG hygiene) and `docs/fpga/DEV_GUIDE.md` §4 (iso-test methodology).

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

## A/B runs: CRC-FIRST, dump only on mismatch (DEFAULT — do not skip)
A 1024x1024 crop is 2 MiB and the JTAG link is ~84 kbit/s (~111 s/MB), LATENCY-bound (~390 us per
word-scan through the FlashPro6 USB-HID; identical at 2 and 6 MHz, no OpenOCD batching knob). So a
dump is ~230 s and two of them are ~7.5 min of a ~12 min A/B — more than the scene loads (81 s each)
and the pipeline runs (~37.5 s each) combined.

`EROI` crops and CRCs **on-board**; the `dump binary memory` is a SEPARATE, optional host step.
So for "did change X alter the output?":
1. Run `EROI` per arm WITHOUT the dump args, require `verdict 0`.
2. Read the u32 at **`0xB005E220`** (ROI record `0xB005E200` + 0x20 = board-computed crop CRC).
3. CRCs equal -> outputs identical, correctness gate PASSED, no dump. CRCs differ -> only then dump
   both (`+ 0x98000000 2097152 <file>`) and diff/render to see HOW they differ.

Takes the A/B cycle ~12 min -> ~4.5 min. Validated 2026-07-25: the board's ROI CRC matched the host
`zlib.crc32` of the dumped bytes exactly (`0x2d4786ef`) on both arms, so the CRC faithfully stands in
for the pixels. Full write-up: `docs/USER_GUIDE.md` §7.3a.

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
