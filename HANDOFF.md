# HANDOFF

A clean-handoff summary for the next researcher. This is target-neutral: it describes the SAR
image-formation design and its verified state so the work can be continued (or retargeted) from the
repo alone. Implementation-specific detail (the FPGA/toolchain realization) is called out where it
applies; the design and verification method are general.

## What the project is
A spotlight-mode **SAR image-formation processor** implementing the Polar-Format Algorithm: it turns
Umbra open-data CPHD phase-history into a focused magnitude image. The datapath is
resample (keystone/polar-format) → 2-D window → range FFT → corner-turn (transpose) → azimuth FFT →
detect, streamed DDR→DDR because a frame (8192² complex, 256 MiB) far exceeds on-chip memory. The
current implementation is a hybrid control-processor (MSS CPU) + FPGA-fabric realization on a
PolarFire SoC MPFS250T_ES engineering-sample board, brought up JTAG-only.

## What is proven (on silicon)
- Full pipeline runs end-to-end and forms a correctly focused image at full resolution — **corr ~0.97**
  vs the CPHD-derived golden. Resample, window, and corner-turn are validated.
- The fabric FFT chain is **phase-exact** (0.0° phase spread at 256 and 8192 points) and value-equals
  the CPU FFT (**corr 0.9999**); the feeder→FFT→gearbox→unloader path is zero-loss.
- A **bit-accurate fixed-point emulator** (`mpfs/host/silicon_emulator.py`) reproduces the float golden
  (**corr 1.0**) and is the reference for isolating hardware bugs.
- Detect ships as a correct-signed control-processor implementation (the fabric-detect path is bypassed;
  see Open items and the `mpfs-platform-gotchas` skill for why).

## What is open / next
The image is already correct; these are latency and quality items.

Latency (baseline is a bring-up ~160 s per frame, not optimized; per-stage timing in
`docs/fpga/SAR_ARCHITECTURE_REPORT.md`). The range/azimuth FFTs already run on the fabric FFT engine
(phase-exact, see What is proven) — the dominant cost is the **resample** stage (~103 s of ~162 s),
then corner-turn:
1. Resample is the top target. Diagnose FIRST whether it is bound by **control-plane serialization**
   (the kernel is armed once per line — ~16k processor→fabric arm/poll handshakes across both passes)
   or by **DDR random-access latency** — the effective rate (~1 MB/s) is ~100× below DDR bandwidth, so
   the loss is latency/orchestration, not bandwidth. Fixes, in order: batch the kernel to self-sequence
   all lines on one arm (collapses ~16k handshakes to ~2); stage a row/tile in on-chip SRAM and
   double-buffer (turns scattered DDR access into bursts); then parallel lanes across DDR banks.
2. Corner-turn is a DDR-hostile transpose — use a tiled block transpose through on-chip SRAM (bursts,
   bank-interleaved) and/or fuse it into the azimuth-FFT read to delete a whole DDR round-trip.
3. A cache-coherent fabric interconnect removes the per-stage cache flushes (pure orchestration cost).

Deferred quality studies:
- **FFT-size trade** — revisit the transform length vs resolution/throughput.
- **Higher-order (sinc) resample** — evaluate a windowed-sinc resample kernel against the current
  two-tap linear interpolation (`out = in[idx] + (in[idx+1]-in[idx])*wq/32768`).

Cosmetic:
- ~50 % OUT saturation at full scale — raise the detect / out-shift headroom (firmware-cheap).

Implementation-specific (current FPGA target): the fabric detect kernel cannot be fixed through the HLS
toolchain (sign-extension is optimized away); if a fabric-detect performance win is needed, hand-write
it in RTL or de-risk an `ap_int<16>` variant in simulation first. See `mpfs-platform-gotchas`.

## Where to look
Docs (source of truth — read before re-deriving):
- `docs/PROJECT_SOURCE_OF_TRUTH.md` — authoritative index + anti-hallucination rules.
- `docs/fpga/SAR_ARCHITECTURE_REPORT.md` — as-built pipeline, block usage, per-stage timing.
- `docs/fpga/SAR_PIPELINE_STATUS.md` — status + per-stage timing + latency roadmap.
- `docs/fpga/SAR_PIPELINE_PROCESS.md` — pipeline math/orchestration.
- `docs/fpga/SILICON_ISO_TEST_RUNBOOK.md`, `LIBERO_HEADLESS_PLAYBOOK.md`, `SMARTDEBUG_RUNBOOK.md`,
  `SAR_TOP_RECOVERY.md` — board/build runbooks.

Skills (`.claude/skills/`) — start with `project-orientation`, then:
- `sar-pipeline-design` — datapath stages + fixed-point/BFP/streaming contracts.
- `sar-verification-methodology` — value-level testing, bit-accurate emulator, orientation pitfall,
  board-free phase test.
- `umbra-cphd-data` — CPHD input format, dimensions, sizing, decimation.
- `mpfs-platform-gotchas` — PolarFire SoC ES silicon + Microchip toolchain/IP peculiarities.
- `silicon-iso-test`, `smartdebug-probe`, `jtag-recover`, `fpga-ref-check` — hands-on procedures.

## How the AI framework is meant to be used
This repo ships a Claude Code / Agent framework so a new researcher gets the accumulated knowledge
automatically:
- `.claude/skills/*` — task-scoped knowledge that loads when its trigger matches. Read
  `project-orientation` first.
- `.claude/agents/*` — specialized sub-agents for long/hands-on jobs (headless Libero builds, silicon
  iso-tests, SmartDebug planning, IP reference verification). Delegate those flows rather than
  reconstructing them.
- `CLAUDE.md` — engineering discipline for this repo (read the IP User Guide + golden testbench before
  designing/fixing; verify timing MET before functional silicon debug; try headless first and check
  recoverability before destructive ops; capture reusable procedures in runbooks and update them the
  same session; prefer value-level testing over correlation).
Keep the discipline alive: when a procedure or gotcha is proven, write it into the relevant runbook /
skill the same session so it survives into the next.
