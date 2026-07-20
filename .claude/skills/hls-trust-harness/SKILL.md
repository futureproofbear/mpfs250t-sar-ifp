---
name: hls-trust-harness
description: >-
  Everything SmartHLS on this project: how to AUTHOR a kernel (pragma reference, the two AXI
  initiator APIs, pin-don't-infer, reference-first rule) and how to DISTRUST the result
  (constrain inputs, gate outputs, collect the report-vs-silicon statistics the tool cannot
  model — DDR latency, AXI backpressure / the II=1 lie, L2 coherency, FIC/AXI-ID, ES errata,
  cross-IP re-arm). Load BEFORE writing or changing any HLS kernel or pragma, before committing
  an HLS change toward a bitstream, when quantifying why a kernel is slower on silicon than its
  schedule, or when a silicon symptom smells like mis-synthesis. Triggers: "write/change an HLS
  kernel", "which pragma", "axi_initiator", "max_burst_len / max_outstanding", "memory partition",
  "loop pipeline II", "shls hw", "HLS gate", "II lie", "why is the kernel slow on silicon",
  "SmartHLS mis-synthesis", "report vs silicon", "effective II", "anti-pattern catalog".
---

# HLS trust harness

## Rule: Read the reference before writing a pragma
- **TRIGGER**: about to add, change or reason about any `#pragma HLS`, or to claim the tool
  can/cannot do something.
- **ACTION**: check the authoritative sources first, in this order:
  - Pragma manual (exact syntax + every option):
    `https://microchiptech.github.io/fpga-hls-docs/2023.1/pragmas.html`
  - User guide (concepts, limitations):
    `https://microchiptech.github.io/fpga-hls-docs/2023.1/userguide.html`
  - Official examples (working reference code):
    `https://github.com/MicrochipTech/fpga-hls-examples`
  Then check `docs/fpga/SMARTHLS_ANTIPATTERNS.md` for whether that shape has already burned us.
- **HALT**: if you cannot cite the option in the manual, do NOT assert it exists and do NOT plan
  around it. On 2026-07-20 a roadmap recommended "give `out` its own AXI ID" — no such option
  exists on the pointer-based `axi_initiator` pragma. Guessing a knob wastes a ~40 min build.

## Rule: Pin Class-A behaviour, never rely on inference
- **TRIGGER**: a kernel depends on a specific memory architecture, II, or port count.
- **ACTION**: state it as a pragma. Relying on the tool inferring it is an unpinned assumption
  that can silently change between builds.
- **HALT**: `hls_resample/resample.cpp` comments claim "buf[j]/buf[j+1] read in one cycle via
  PolarFire's two-port LSRAM" but carries NO partition pragma — the dual-port behaviour is
  inferred. Pin it: `#pragma HLS memory partition variable(buf) type(cyclic) factor(2)`.

## Rule: Latency-bound kernels get outstanding transactions before restructuring
- **TRIGGER**: a kernel's silicon time exceeds its scheduled cycle count and DDR bandwidth is
  not saturated (compute MB/s before assuming bandwidth).
- **ACTION**: set `max_outstanding_reads(<n>)` / `max_outstanding_writes(<n>)` on the
  `axi_initiator` pragmas. They are documented and cheap; the resample kernel sets neither while
  running 3.1x off its ideal schedule at ~39 MB/s (nowhere near LPDDR4 limits).
- **HALT**: do not restructure a kernel for latency before trying the pragma that addresses it.

## Pragma quick reference (verbatim from the manual — do not paraphrase)

```
#pragma HLS function top
#pragma HLS function pipeline | dataflow | noinline
#pragma HLS loop pipeline II(<int>)
#pragma HLS loop unroll
#pragma HLS memory partition variable(<v>) type(block|cyclic|complete|struct_fields|none) dim(<int>) factor(<int>)
#pragma HLS memory impl variable(<v>) pack(bit|byte) byte_enable(true|false)
#pragma HLS memory impl variable(<v>) contention_free(true|false)
#pragma HLS interface argument(<a>) type(axi_initiator) ptr_addr_interface(<simple|axi_target>) num_elements(<int>) max_burst_len(<int>) max_outstanding_reads(<int>) max_outstanding_writes(<int>)
#pragma HLS interface argument(<a>) type(axi_target) num_elements(<int>) dma(true|false) requires_copy_in(true|false)
```

Docs are published for 2023.1; this project builds with **2025.2**. Treat syntax as indicative and
verify against the installed toolchain's own manual when something does not take effect.

## Two AXI initiator APIs — pick deliberately

- **Pointer-based** (`type(axi_initiator)` on a `T*` argument) — what all our kernels use. Simple,
  burst-inferred, but all arguments share ONE port: reads and writes serialise, and there is no ID,
  bundle or port-separation option.
- **Explicit** (`#include <hls/axi_interface.hpp>`, `AxiInterface<>` + `axi_m_read_req` /
  `axi_m_write_req` / `axi_m_read_data` / `axi_m_write_data`) — you drive the channels yourself, so a
  single pipelined loop can issue a read request and a write request and then interleave both data
  streams. This is the only way to get genuine read/write concurrency. Cost: hand-managed handshake
  and burst boundaries. See the `axi_initiator` example in the examples repo.

## Microchip's own Claude plugin (evaluate before hand-rolling)

`MicrochipTech/fpga-hls-examples/shls-assistant` is an official Claude Code plugin: an MCP server
(`shls-mcp`) plus a RAG index over the SmartHLS docs, with setup targeting **2025.2.1 — our exact
version**. It generates pragma-correct C++, answers doc questions with citations, and drives
`shls` commands. Prefer it over reciting pragma syntax from memory.

It does NOT know this project's silicon scar tissue — the twiddle drop, the detect sign-extension,
dead mem<->stream kernels, or that `shls cosim` segfaults here. That delta is what THIS skill owns:
Microchip's tool tells you what the tool should do; this skill records what it actually did on our
board. Caveats before installing: needs an Anthropic API key, downloads an embedding model and an
executable, and expects local SmartHLS + Libero.

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
