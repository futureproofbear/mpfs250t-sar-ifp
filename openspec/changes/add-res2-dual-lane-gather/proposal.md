# Proposal: 2-lane double-buffered range gather (RES2)

## Status: REJECTED (2026-07-25) — see tasks.md for evidence. Kept as a record, not a plan to resume as-is.

## What & why

The range-gather sub-stage of resample was diagnosed as READ-LATENCY-BOUND: a v2 FIC_0 monitor
decomposed one gather line (908.8 us at 100 MHz) as 16% read-busy / 40% read-outstanding-DDR-not-
returning / 9% write-busy / 35% idle. With the FIC_0 data plane only ~25% active during the
gather, the diagnosis (`docs/SAR_IMPLEMENTATION_RECORD.md` Part 3 / memory `gather-stall-read-latency-bound`) was
that a second, independent gather instance could stall in parallel rather than in series, since a
second FIC (AXI-channel conflict) is not the bottleneck — the shared DDR controller is.

RES2 repurposed the unused `detect_top`/DET SmartDesign slot (detect already runs fused into the
FFT-2 unloader in the shipping path — the standalone `K_DETECT` HLS kernel was dead code) into a
2nd `resample_top` instance, driven by 2-lane double-buffered firmware in `sar_sequencer.c`, to
gather two range lines concurrently instead of serially.

## Non-goals

- Does not touch window, FFT, corner-turn, or detect — those stages are unchanged.
- Does not add a second FIC (`docs/fpga/RESAMPLE_PARALLELISM_STUDY.md`'s original study ruled that
  out: the stall is in the shared DDR controller, not an AXI-channel conflict).
- Not a claim that 2-lane parallelism is the wrong direction in principle — only that this
  specific implementation is unsafe. See "Reconsideration" in tasks.md.

## Evidence this proposal is now closed against

- Fabric: `mpfs/fpga/sartop_assembly.tcl` — RES2 instance, RSLICE_DIC/RSLICE_CIC timing-fix
  regslices, FIC0MON monitor. Built clean: `TIMING_MET` (0 real setup/hold violations on the
  authoritative multi-corner report), `SAR_TOP_ffv.job` exported 2026-07-25.
- Firmware: `mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/sar/sar_sequencer.c`,
  `sar_kernels.h` — `K_RESAMPLE2`, 2-lane double-buffered pass-1 gather, 4 coefficient banks.
- Silicon A/B result: see `tasks.md` and memory `res2-dual-lane-correctness-regression`.
