# fpga-soc-generic

A vendor-agnostic Claude Code plugin capturing the methodology for taking a system from a
high-level requirement / algorithm through HLS/RTL to FPGA fabric + firmware implementation:
reference-first design discipline, distrust of HLS tool output, value-level (not correlation-level)
verification, and hardware-aware architectural critique of concurrency/arbitration/handshake
correctness.

None of the content here names a specific vendor, chip, toolchain, or project. It was extracted
from a real multi-month FPGA/SoC bring-up effort, generalized to the underlying engineering
discipline that produced good outcomes there — independent of which vendor's tools were used.

## Who this is for

Any FPGA/SoC project moving a design from a high-level description (an algorithm, a spec, a
reference model) down through HLS and/or hand-written RTL into programmable fabric plus firmware —
on any vendor's silicon and toolchain (Xilinx/AMD, Intel/Altera, Microchip, Lattice, or otherwise).
If your project involves hard IP blocks, an on-chip interconnect, DMA, clock domains, and a
CPU-plus-fabric split, the methodology here applies.

## Install

```
claude --plugin-dir /path/to/ai-framework/generic-fpga-soc
```

Point `--plugin-dir` at this directory (or wherever you copy it) from any other project — it has no
dependency on this repository beyond the files inside it.

## What's in it

### Agents (`agents/`)
- **architectural-critic** — read-only hardware verification brain. Reasons over AXI4/APB/Avalon/
  AXI4-Stream-class interfaces and the laws of spatial concurrency, arbitration, and clock-domain
  crossings; assumes software-correctness claims are false until the physical handshake is shown
  unblocked. Root-causes deadlocks/stalls; does not write fixes.
- **fpga-ref-verifier** — read-only verification that an IP/RTL integration matches its
  authoritative references (vendor User Guide + the IP's own golden testbench) before a design or
  fix is committed to. Returns exact-quoted protocol facts, a pin-by-pin diff, and a ranked
  root-cause list.
- **ingestion-triage** — read-only parser that turns raw hardware-debug-probe register/memory dumps
  into a clean, semantic JSON ground-truth state map. First step of any on-silicon investigation;
  does not diagnose or fix.
- **synthesis-repair** — turns a verified root cause + architectural constraints into a minimal,
  compilable patch across HLS C++, RTL, and firmware C, with every patch stating its build
  requirements, directive/pragma changes, and the hardware interface it touches.

These three agents form a pipeline: **ingestion-triage** (facts) -> **architectural-critic**
(diagnosis) -> **synthesis-repair** (fix). **fpga-ref-verifier** is a standalone gate used before
committing to any of those steps.

### Skills (`skills/`)
- **hls-output-distrust** — the discipline of treating an HLS tool's schedule/report as a
  behavioural model that can be silently wrong: constrain its inputs, gate its outputs, and keep a
  ledger of what the report predicted versus what hardware actually did (DRAM latency, bus
  backpressure, cache coherency, cross-IP handshake effects the tool cannot model).
- **reference-first-verification** — verify an IP/RTL integration against its vendor User Guide and
  its own golden testbench, and against the actually-built configuration (not comments or memory),
  before committing to a design or a fix.
- **value-level-verification** — prefer value-level diffs over correlation/magnitude comparisons
  (which are scale-, phase-, and orientation-invariant and hide real bugs); build a bit-accurate
  fixed-point emulator that matches a floating-point golden reference first; watch for
  orientation/transpose artifacts before declaring a divergence real.
- **kernel-isolation-testing** — the iso-test concept: isolate one kernel/IP block, drive it with a
  known input directly, read its output directly, and localize a bug to one pipeline stage by direct
  evidence instead of inference from "everything else works."

### OpenSpec workflow (`skills/openspec-*`, `commands/opsx/`)

[OpenSpec](https://github.com/Fission-AI/OpenSpec) is a spec-driven change-management workflow:
propose a change (proposal + design + spec deltas + tasks) -> apply it (implement the tasks) ->
sync the spec deltas into the project's main specs -> archive the completed change. It is bundled
into this tier because it is generic project-workflow tooling with no FPGA/hardware content at
all — a consuming project uses it for spec-driven change management on top of whatever FPGA/SoC
work the rest of this tier (and tiers 2/3) cover. It requires the `openspec` CLI to be installed
separately; these skills/commands are the Claude-side wrapper around it.

- **skills/openspec-propose** — create a new change and generate all its artifacts (proposal,
  design, spec deltas, tasks) in one step.
- **skills/openspec-apply-change** — implement a change's tasks one by one, tracking progress
  against the tasks file.
- **skills/openspec-sync-specs** — merge a change's delta specs into the project's main specs
  without archiving.
- **skills/openspec-archive-change** — archive a completed change once its artifacts and tasks are
  done (optionally syncing specs first).
- **skills/openspec-explore** — a thinking-partner mode for exploring a problem/idea before or
  during a change, without implementing anything.
- **commands/opsx/{propose,apply,sync,archive,explore}.md** — `/opsx:*` slash-command entry points
  for the same five actions, for direct invocation instead of relying on skill auto-trigger.

These five skills and five commands were copied as-is from the source project's `.claude/`
directory — they are OpenSpec's own generic tool-usage instructions and needed no project-specific
adaptation.

## Three-tier framework

This package is **tier 1** of a 3-tier system built for FPGA/SoC AI-assisted engineering work:

- **Tier 1 (this package, `fpga-soc-generic`)** — vendor-agnostic methodology. Take it to any
  FPGA/SoC project regardless of vendor.
- **Tier 2 (`../microchip-fpga-soc/`)** — Microchip-family-specific knowledge (PolarFire SoC family
  toolchain conventions, Libero, SmartHLS, SmartDebug, FlashPro programmers) for any project on that
  vendor's silicon.
- **Tier 3 (`../mpfs250t/`)** — knowledge specific to one exact chip/board (MPFS250T on a specific
  board), including its engineering-sample silicon errata and board-specific bring-up detail.

A project on a different vendor's FPGA/SoC should take tier 1 only. A project on a different
Microchip PolarFire SoC part should take tiers 1 and 2. This repository's own project uses all
three tiers together.
