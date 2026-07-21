---
name: project-orientation
description: >-
  START HERE for a new researcher on this SAR image-formation project — what it is, what is PROVEN
  vs OPEN, where the source-of-truth docs live, and the map of the other skills. Load at the start
  of a session or when unsure which skill/doc to reach for. Triggers: "what is this project",
  "where do I start", "orient me", "what's proven / what's open", "which skill / which doc",
  "project status", "source of truth".
---

# Project orientation — SAR image former

## What this is
A spotlight-mode **SAR image-formation processor** (Polar-Format Algorithm): it turns Umbra open-data
CPHD phase-history into a focused magnitude image. The current implementation is a hybrid
control-processor (MSS CPU) + FPGA-fabric datapath on a Microchip **PolarFire SoC MPFS250T_ES**
(engineering-sample silicon), brought up JTAG-only. The pipeline and numeric contracts are
target-neutral (see `sar-pipeline-design`); the FPGA/toolchain specifics are scoped in
`mpfs-platform-gotchas`.

## Read the source-of-truth docs first (do not re-derive)
- `docs/PROJECT_SOURCE_OF_TRUTH.md` — authoritative index + anti-hallucination rules (never invent a
  register offset / DDR address / AXI signal / Tcl command; two SAR register-map models coexist — the
  hardware uses the per-kernel `sar_kernels.h` model, not the monolithic one).
- `docs/SAR_DESIGN.md` — the detailed current design (dataflow, buffer map, fixed-point contracts,
  eMMC layout, register semantics, diagrams).
- `docs/fpga/SAR_ARCHITECTURE_REPORT.md` — the as-built pipeline, block usage, and the single source of
  truth for per-stage timing (§5).
- `docs/fpga/SAR_PIPELINE_STATUS.md` — status + per-stage timing + latency roadmap.
- `docs/fpga/SAR_PIPELINE_PROCESS.md` — the pipeline math/orchestration.
- `docs/fpga/SILICON_ISO_TEST_RUNBOOK.md` — the JTAG single-kernel isolation harness + coherent-DDR
  read technique. Read before ANY silicon debug.
- Repo layout: this repo is canonical (algorithm + FPGA + host tooling + board firmware). A sibling
  `polarfire-soc` repo is the vendor reference (HSS + bare-metal HAL). `orbitDesign` is unrelated.

## What is PROVEN vs OPEN
Proven (on silicon):
- **Full autonomous on-board run (re-confirmed 2026-07-20):** scene loaded from the board's own eMMC
  (81.5 s, `sig_crc 0x89fa12dc` verified) → focused in **58.12 s** (`SAR_SEQ_OK`, `fft_mode=1` FABRIC
  CoreFFT confirmed at runtime) → ROI crop rendered to a coherent focused image. No host JTAG data load.
  Reproducible: the superseded 88.1 s baseline ran 88.04 s / 88.11 s, output byte-identical to the previous
  88.1 s pre-flush-fix build had the same top-left 1024² ROI crc `0xd596c9eb`).
  Per-stage breakdown (single source of truth): `docs/fpga/SAR_ARCHITECTURE_REPORT.md` §5; re-read
  anytime with `bash mpfs/host/run_stage_timing.sh`.
- Full pipeline runs end-to-end and forms a correctly focused image (corr 0.9923 vs the CPHD-derived
  golden). Resample, window, corner-turn all validated.
- The fabric FFT chain is phase-exact (0.0° spread @ 256 & 8192) and value-equals the CPU FFT
  (corr 0.9999); zero-loss gearbox.
- Bit-accurate emulator (`silicon_emulator.py`) == float golden (corr 1.0).
- Detect: the FFT-toolchain mis-synthesized the fabric detect's sign-extension; the shipping path uses
  a correct-signed CPU detect (see `sar-pipeline-design` + `mpfs-platform-gotchas`).

Open / next (image is already correct; these are latency + hardening):
- Latency reduction (58.12 s). The FFT is already on fabric, and the targeted coefficient-bank CCACHE
  FLUSH64 writeback is now DONE and measured (resample 53.6 → 29.2 s, frame 110.8 → 88.1 s, output bits
  unchanged) — do not treat the per-line L2 flush as a pending lever, and disregard the old "2% L2
  flush" split, which came from a profile of a since-reverted experiment. The live levers, in order:
  (1) **resample at 26.92 s (46.3%) — the largest target by far**, gather is II=1 on all loops but
  ~2.44x AXI-stalled (361 us scheduled vs ~880 us measured; an earlier single-beat-reads claim was
  a stale-report error, see `hls_silicon_stats.jsonl` `axi_ii_lie`). Needs the FIC_0 monitor. Window and detect are FUSED
  into the FFT passes and no longer exist as stages;
  moving it to fabric is blocked on the SmartHLS sign-extension miscompile, so the firmware-only path is
  splitting CPU detect across the 4 U54 harts; (2) the resample fabric kernel's interconnect — its shared
  `m_axi` port serialises the gather; (3) the corner-turn's DDR round-trip.
- Deferred quality studies: FFT-size trade and a higher-order (sinc) resample kernel vs the current
  two-tap linear interpolation.
- Cosmetic: ~50 % OUT saturation (raise the detect/out-shift headroom).
See `HANDOFF.md` for the consolidated open-items list.

## Map of the other skills
- `sar-pipeline-design` — the datapath stages + fixed-point/BFP/streaming contracts. (design)
- `sar-verification-methodology` — value-level testing, bit-accurate emulator, orientation pitfall,
  board-free phase test. (how to prove correctness)
- `umbra-cphd-data` — the CPHD input format, dimensions, sizing, decimation. (input)
- `mpfs-platform-gotchas` — PolarFire SoC ES silicon + Microchip toolchain/IP peculiarities (Libero,
  SmartHLS, SmartDebug, FlashPro6, CoreFFT, FIC/AXI, DDR coherency, boot/eNVM). (current-target detail)
- `silicon-iso-test`, `smartdebug-probe`, `jtag-recover`, `fpga-ref-check` — hands-on board/IP
  procedures. (current-target workflow)

## Adjacent (out-of-repo) work
A next-gen X-band SAR RX front-end (ADC/RFSoC) hardware trade study lives OUTSIDE this repo (under a
personal `Documents\02_Digital Electronics\` folder, not in git). It is a system-level SWaP / dynamic-
range trade study for scaling the receiver bandwidth; it does NOT drive this processor's design and is
noted only so the next researcher knows it exists.
