# Project — SAR Processor on PolarFire SoC

## What this is
A Synthetic Aperture Radar (SAR) image-formation pipeline on a Microchip PolarFire SoC
(MPFS250T_ES / FCVG484). Constraint: JTAG-only bring-up — there is no ethernet/UART data path,
so the system is bare-metal C on the MSS + fabric kernels + host-offload over a FlashPro6.

## Architecture (source of truth: `docs/PROJECT_SOURCE_OF_TRUTH.md`)
- **MSS (bare-metal C, `src/`)** — control, the shipping FFT (`src/sar/sar_fft.c`, L1-BFP
  full-precision radix-2 on the CPU, validated end-to-end at corr 0.9923), and JTAG mailboxes.
- **Fabric kernels (`mpfs/fpga/`)** — resample, corner-turn, window, detect (HLS), plus the
  in-progress CoreFFT range-FFT path (Verilog feeder + gearbox + CoreFFT IP + Verilog/HLS
  unloader). Data moves DDR -> kernel -> DDR over FIC_0 (non-coherent).
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
The CPU-FFT pipeline is the shipping product. CoreFFT-on-fabric is the acceleration path in
progress — see `openspec/specs/fabric-range-fft/` and the open changes.
