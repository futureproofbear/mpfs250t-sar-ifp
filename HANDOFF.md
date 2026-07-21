# HANDOFF

> **▶ 2026-07-14 status (newest).** This repo is now **standalone `mpfs250t-sar-ifp`** (builds without a
> sibling `sarProcessor`). The **on-board eMMC pipeline (M1–M3) is proven on silicon** — a CPHD scene is
> stored on the board eMMC, loaded + focused entirely on-board (`sar_form_image` → SAR_SEQ_OK; focused image
> confirmed via an ROI crop), and the output persisted back to the card, retiring the recurring ~3 h JTAG
> scene load. Continue from here: [`docs/PROJECT_SOURCE_OF_TRUTH.md`](docs/PROJECT_SOURCE_OF_TRUTH.md) +
> [`docs/fpga/SILICON_ISO_TEST_RUNBOOK.md`](docs/fpga/SILICON_ISO_TEST_RUNBOOK.md) § eMMC + the
> `emmc-onboard-pipeline` skill. Next board task: reflash → LOAD → PIPE → SAVEOUT(commit-last) → VERIFY_OUT → ROIE.

A clean-handoff summary for a new user. This is target-neutral: it describes the SAR
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
- Full pipeline runs end-to-end and forms a correctly focused image at full resolution — **corr 0.9923**
  vs the CPHD-derived golden. Resample, window, and corner-turn are validated.
- The fabric FFT chain is **phase-exact** (0.0° phase spread at 256 and 8192 points) and value-equals
  the CPU FFT (**corr 0.9999**); the feeder→FFT→gearbox→unloader path is zero-loss.
- A **bit-accurate fixed-point emulator** (`mpfs/host/silicon_emulator.py`) reproduces the float golden
  (**corr 1.0**) and is the reference for isolating hardware bugs.
- Detect ships as a correct-signed control-processor implementation (the fabric-detect path is bypassed;
  see Open items and the `mpfs-platform-gotchas` skill for why).

## What is open / next
The image is already correct; these are latency and quality items.

Latency (measured 2026-07-21: **58.12 s** per frame, window+detect fused; per-stage timing in
`docs/fpga/SAR_ARCHITECTURE_REPORT.md` §5, re-readable via `bash mpfs/host/run_stage_timing.sh`).
The range/azimuth FFTs already run on the fabric CoreFFT engine (phase-exact, and `fft_mode=1` is
verified at runtime, see What is proven). Two rounds of resample work are now banked: the fabric gather
kernel redesign (gather loop II 2→1) took resample 103.3 → 53.6 s, and replacing the per-line whole-L2
`flush_l2_cache()` in `resample_2pass()` with a targeted CCACHE `FLUSH64` writeback of only the
coefficient banks took it 53.6 → 29.2 s, cutting the frame 110.8 → 88.1 s (−20.6%) with the output
bits unchanged. That flush was ~45% of resample, not the ~2% previously documented here — the old
figure came from an `mcycle` profile taken while an experimental per-chunk flush was active, and the
number outlived the reverted code.

With resample no longer dominant, the ranking has changed:
1. **Detect (18.88 s, 23.7%) is the largest structural target** and the only stage still on the CPU.
   Moving it back to fabric is blocked on the SmartHLS sign-extension miscompile (see below); the
   firmware-only alternative is splitting CPU detect across the 4 U54 harts.
2. Resample (28.53 s) is still the largest single stage but is now bound by the fabric gather kernel
   itself — its shared `m_axi` port serialises the gather, so widen/split the interconnect; then stage
   a row/tile in on-chip SRAM and double-buffer; then parallel lanes across DDR banks.
3. Corner-turn is a DDR-hostile transpose — use a tiled block transpose through on-chip SRAM (bursts,
   bank-interleaved) and/or fuse it into the azimuth-FFT read to delete a whole DDR round-trip.
4. A cache-coherent fabric interconnect removes the remaining per-stage cache flushes.

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
- `docs/SAR_DESIGN.md` — the detailed current design (dataflow, buffer map, fixed-point contracts,
  eMMC layout, register semantics, diagrams).
- `docs/fpga/SAR_ARCHITECTURE_REPORT.md` — as-built pipeline, block usage, and the single numeric
  source of truth for per-stage timing (§5).
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
