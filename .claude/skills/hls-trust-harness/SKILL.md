---
name: hls-trust-harness
description: >-
  Treat SmartHLS as an untrusted, behavioural-only tool: constrain its inputs, gate
  its outputs, and COLLECT the report-vs-silicon statistics it cannot model (DDR
  latency, AXI backpressure / the II=1 lie, L2 coherency, FIC/AXI-ID, ES errata,
  cross-IP re-arm). Load before committing any HLS change toward a bitstream, when
  quantifying why an HLS kernel is slower on silicon than its schedule, or when a
  silicon symptom smells like SmartHLS mis-synthesis. Triggers: "HLS gate", "II lie",
  "why is the kernel slow on silicon", "SmartHLS mis-synthesis", "report vs silicon",
  "effective II", "guide the HLS", "anti-pattern catalog", "collect DDR/AXI stats".
---

# HLS trust harness

SmartHLS 2025.2 on this project has a documented record of **schedule-passing /
silicon-failing** RTL (twiddle drop, detect sign-extension, II=2→21). Its report is
a behavioural model that cannot see the system. This harness does three things:
**reduce the tool's freedom on the inputs, gate its outputs, and collect what it
cannot predict** — so failures are caught, attributable, and never rediscovered.

## Two classes of intricacy — don't conflate them

- **Class A (the tool CAN respect if constrained):** bit widths, II, memory arch,
  interface bursts, clock period. Fix by pinning them and gating. Levers: explicit
  `ap_int`/`ap_fixed` (no width inference), `#pragma HLS loop pipeline II(k)` on
  every loop, a real `CLOCK_PERIOD` matching the fabric CCC.
- **Class B (the tool STRUCTURALLY cannot see):** DDR latency, AXI arbitration/
  backpressure, L2 coherency, FIC/AXI-ID, ES errata, cross-IP handshakes. You do
  **not** make the tool model these — you **restructure so they're off the critical
  path** (e.g. stage DDR operands into LSRAM so the scheduled II becomes true) and
  you **measure** them into the ledger.

## The gates (board-free first; silicon last)

Run in order; each is cheap relative to the next. All live in `mpfs/host/`.

0. **Anti-pattern pre-screen** — `python mpfs/host/hls_antipattern_lint.py`
   Checks source against `docs/fpga/SMARTHLS_ANTIPATTERNS.md` (proven mis-synthesis
   shapes). Blocks on high-precision patterns; prints the manual checklist.
1. **Report gate (II)** — `python mpfs/host/hls_report_lint.py`
   Parses the pipelining report, fails if achieved II > requested II (the silent
   degradation). `--selftest` proves the FAIL path; `--ledger` also records the
   scheduled II (opt-in, so the gate can run every build without spamming the log).

**Wired as a firebreak:** `bash mpfs/fpga/hls_gate.sh [kernel_dir ...]` runs Gates 0+1
together and exits non-zero on failure — the SmartHLS analog of `lint_netlist.sh`.
Run it AFTER `shls hw` and BEFORE Libero (it is Stage 0 in `run_hlsfft_build.sh`); a
1-second check vs a ~30-min synth on silently-degraded RTL. To adopt in another build
wrapper, add before the Libero synth step:
`if ! bash mpfs/fpga/hls_gate.sh <kernels>; then exit 1; fi`.
2. **Value gate (board-free)** — the phase-exact complex-ratio / bit-accurate
   emulator check from the `sar-verification-methodology` skill. `shls cosim` is
   unusable here (segfaults — see catalog), so this is your pre-silicon value proof.
3. **Timing gate** — post-P&R setup+hold MET via the `libero-build` agent (refuses a
   bitstream otherwise). The only gate that sees physical timing.
4. **Silicon value gate** — corr + phase test + iso-test (`silicon-iso-test`), the
   final backstop for Class-B mis-synthesis nothing upstream catches.

## Collecting the Class-B statistics (constantly updating)

The ledger is `docs/fpga/hls_silicon_stats.jsonl`, rolled up in
`docs/fpga/HLS_SILICON_STATS.md`. Six phenomena: `axi_ii_lie`, `ddr_latency`,
`l2_coherency`, `fic_axi_id`, `es_errata`, `corefft_rearm`.

```
# the II lie: effective II from an iso-test's busy-cycles / elements
python mpfs/host/hls_stats.py eff-ii --build resample-lsram \
     --busy-cycles <N> --elements <M> --scheduled 1 --source run_resample_iso

# any other measurement
python mpfs/host/hls_stats.py append --phenomenon l2_coherency --build resample \
     --metric flush_frac --value 0.02 --unit frac --source profiling

python mpfs/host/hls_stats.py report            # roll up
```

**Discipline:** append the same session you measure; add a catalog entry the same
session you confirm a new mis-synthesis. Both are CLAUDE.md runbook rules.

## How this feeds batch-confidence

Gates 0–2 are exactly the per-change, board-free value verification a change must
pass before it is eligible to be batched onto silicon (see the batch-confidence
protocol in `SAR_PIPELINE_STATUS.md`). The ledger's `lie_ratio → 1.0` is the
evidence that a restructure actually removed a Class-B dependency.

See also: `sar-verification-methodology` (the value gate), `mpfs-platform-gotchas`
(ES errata + toolchain quirks), `libero-build` agent (timing gate), `silicon-iso-test`
(gate 4), `smartdebug-probe` (DDR/AXI counter reads).
