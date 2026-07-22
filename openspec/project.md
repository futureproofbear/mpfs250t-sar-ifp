# Project — SAR Processor on PolarFire SoC

## What this is
A Synthetic Aperture Radar (SAR) image-formation pipeline on a Microchip PolarFire SoC
(MPFS250T_ES / FCVG484). Constraint: JTAG-only bring-up — there is no ethernet/UART data path,
so the system is bare-metal C on the MSS + fabric kernels + host-offload over a FlashPro6.

## Architecture (source of truth: `docs/PROJECT_SOURCE_OF_TRUTH.md`)
- **MSS (bare-metal C, `src/`)** — control, the shipping detect (the fabric detect is bypassed —
  SmartHLS mis-synthesizes its sign extension), the legacy mode-0 CPU FFT fallback
  (`src/sar/sar_fft.c`), and JTAG mailboxes.
- **Fabric kernels (`mpfs/fpga/`)** — resample, corner-turn, window (HLS), plus the shipping
  range/azimuth FFT path (Verilog feeder + gearbox + CoreFFT IP + HLS `fft_unloader`), selected by
  `SAR_FFTMODE` @`0xB0059110` = 1. Data moves DDR -> kernel -> DDR over FIC_0 (non-coherent).
- **Host (`mpfs/host/`)** — gdb/openocd iso-test harnesses, golden-vector generators, correlators.

## Conventions
- **Read the IP User Guide + golden testbench BEFORE committing to a design or fix** (`reference/`).
- **Verify TIMING MET (setup + hold) before trusting any silicon result.** Libero will program a
  timing-failing bitstream silently. Gated build template: `mpfs/fpga/build_full_prog_ffv.tcl`.
- **JTAG hygiene is non-negotiable** — never `taskkill /F` openocd/gdb (wedges the FlashPro6).
  See `docs/fpga/SILICON_ISO_TEST_RUNBOOK.md` §1.
- Prefer headless/scripted flows; before destructive ops check recoverability and work on copies.
- RTL is Verilog; every RTL change is proven in QuestaSim before a fabric rebuild, then on silicon.
- No PowerShell (blocked) — use cmd / git-bash.

## Where things live
- Runbooks / hard-won facts: `docs/fpga/*.md`.
- OpenSpec capabilities: `openspec/specs/`. Proposed/completed changes: `openspec/changes/`.
- Reusable agents: `.claude/agents/`. Skills: `.claude/skills/`.

## Status
The CoreFFT-on-fabric pipeline is the shipping product — complete and proven on silicon
(`fft_mode=1` confirmed at runtime, 48.19 s per frame (2026-07-22, azimuth-gather fused), corr 0.9923 vs golden). The CPU FFT remains
only as the mode-0 fallback. See `openspec/specs/fabric-range-fft/` and `docs/SAR_DESIGN.md`.
