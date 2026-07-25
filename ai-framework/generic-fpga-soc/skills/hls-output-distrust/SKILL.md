---
name: hls-output-distrust
description: >-
  The vendor-agnostic discipline of DISTRUSTING high-level-synthesis (HLS) tool output: constrain
  its inputs, gate its outputs, and collect the report-vs-silicon statistics the tool structurally
  cannot model (DRAM/DDR latency, bus backpressure and the "II lie", cache/coherency gaps, bus-ID/QoS
  effects, cross-IP re-arm behaviour). Applies to any HLS toolchain (Vitis HLS, Intel HLS Compiler,
  SmartHLS, or similar). Load BEFORE writing or changing any HLS kernel or pragma/directive, before
  committing an HLS change toward a bitstream, when quantifying why a kernel is slower on hardware
  than its schedule predicts, or when a hardware symptom smells like mis-synthesis. Triggers:
  "write/change an HLS kernel", "which pragma/directive", "HLS gate", "II lie", "why is the kernel
  slow on hardware", "HLS mis-synthesis", "report vs silicon", "effective II", "anti-pattern
  catalog", "distrust the HLS report".
---

# HLS output distrust

An HLS tool's schedule/timing report is a **behavioural model**. It can be accurate about what it
modelled and silently wrong about what it didn't. This skill is the discipline of never accepting
that report as the final word on hardware behaviour: reduce the tool's freedom on its inputs, gate
its outputs before they reach the next stage, and keep an ongoing ledger of what the report said
versus what the hardware actually did.

## Rule: A gate must require positive evidence, never the absence of a match
- **TRIGGER**: writing or trusting any check that concludes "0 violations", "PASS", or "OK".
- **ACTION**: make the check fail when its input is missing, empty, or stale. Require a minimum
  parsed-row count, an explicit clean marker, and a fresh timestamp — not merely the absence of a
  bad line.
- **WHY THIS MATTERS**: a report-parsing check that only scans a "repaired paths" section will
  report zero violations when there is nothing to repair — including when nothing was checked at
  all. A stale log from a previous run, re-read by a later gate, will report a success that never
  happened for the current change. Always read the CURRENT run's own output, never a file that could
  predate it.

## Rule: Measure the shipping path — do not derive it, do not trust an old number
- **TRIGGER**: about to spend a hardware build cycle or a design decision on a bottleneck you
  inferred rather than measured.
- **ACTION**: measure it first, on the actual shipping configuration. If an "effective II" or
  similar throughput instrument exists, use it to localise whether a stall is in request issue or
  in the loop body, before touching the design.
- **WHY THIS MATTERS**: a documented bottleneck figure can be real but describe an experimental
  branch that was later reverted, and no longer describe the shipping code. A "latency-bound"
  conclusion derived from a bandwidth estimate rather than a measurement can send an interface-level
  fix (e.g. tuning outstanding-transaction limits) at a bottleneck that measurement would have shown
  lives elsewhere. When a derived number and a mechanism disagree, that disagreement is itself a
  finding worth chasing, not something to average away.

## Rule: Read the tool's own reference before writing a pragma/directive
- **TRIGGER**: about to add, change, or reason about any synthesis pragma/directive, or to claim
  the tool can/cannot do something.
- **ACTION**: check the tool's own authoritative documentation (pragma/directive manual, user
  guide, official examples) for the INSTALLED version before asserting or planning around a
  capability. Then check whatever project-local record of past mis-synthesis exists.
- **WHY THIS MATTERS**: guessing that an option exists (e.g. assuming a per-argument bus-ID
  assignment knob exists on an interface pragma when it does not) wastes an entire build cycle
  discovering the guess was wrong. If you cannot cite the option in the manual, do not assert it
  exists and do not plan around it.

## Rule: Pin Class-A behaviour, never rely on inference
- **TRIGGER**: a kernel depends on a specific memory architecture, initiation interval, or port
  count for correctness or performance.
- **ACTION**: state it as an explicit pragma/directive. Relying on the tool inferring it (e.g. a
  comment claiming a buffer is dual-ported with no partition/banking directive backing it) is an
  unpinned assumption that can silently change between tool versions or builds.

## Rule: Latency-bound kernels get outstanding-transaction/burst tuning before restructuring
- **TRIGGER**: a kernel's hardware time exceeds its scheduled cycle count and the memory interface
  is not bandwidth-saturated (compute achieved MB/s before assuming bandwidth is the limit).
- **ACTION**: tune the interface's outstanding-transaction and burst-length parameters (whatever the
  toolchain calls them) before restructuring the kernel's algorithm. They are documented, cheap to
  try, and often the actual lever — many "slow kernel" cases are latency-bound on unconstrained
  outstanding requests, not compute-bound.

## Two classes of intricacy — don't conflate them
- **Class A (the tool CAN respect if constrained):** bit widths, initiation interval, memory
  architecture, interface burst behaviour, clock period. Fix by pinning them explicitly and gating
  the build on the achieved value matching the requested value (a silent II degradation is the
  single most common Class-A failure).
- **Class B (the tool STRUCTURALLY cannot see):** DRAM/DDR latency, bus arbitration/backpressure,
  cache coherency, bus-ID/QoS effects, silicon errata, cross-IP handshake/re-arm behaviour. You do
  **not** make the tool model these — you **restructure so they're off the critical path** (e.g.
  stage off-chip-memory operands into on-chip block RAM so the scheduled II becomes true) and you
  **measure** them into a ledger.

## The gates — board/hardware-free first, silicon last
Order matters; each gate is cheap relative to the next:
1. **Anti-pattern pre-screen** — check the kernel source against a project-local catalog of proven
   mis-synthesis shapes before running the tool at all.
2. **Report gate** — parse the tool's own pipelining/scheduling report and fail the build if the
   achieved metric (e.g. II) is worse than what was requested. This is the single check that catches
   silent degradation; wire it as a firebreak between HLS and the next (synthesis/place-and-route)
   stage so it costs seconds, not the tens of minutes a full downstream build would cost on already-
   degraded RTL.
3. **Value gate (hardware-free)** — a bit-accurate/value-level functional check run in simulation or
   emulation (see the `value-level-verification` methodology) — especially important if the
   toolchain's own co-simulation is unreliable or unusable for your kernel shapes.
4. **Timing gate** — post place-and-route setup AND hold timing MET. The only gate that sees
   physical timing; refuse to produce a bitstream/programming file without it.
5. **Silicon/hardware value gate** — an isolated, on-hardware functional check (see the
   `kernel-isolation-testing` methodology) as the final backstop for Class-B mis-synthesis nothing
   upstream can catch.

## Collecting the Class-B statistics
Keep a running, append-only ledger of every measured Class-B effect (latency/backpressure ratios,
coherency-flush cost fractions, bus-ID or QoS effects, silicon-errata workarounds, cross-IP re-arm
costs), each entry tagged with the phenomenon, the build/kernel it was measured on, the metric, and
the source of the measurement. Pair it with a catalog of confirmed mis-synthesis shapes (the
anti-pattern list gate 1 checks against).

**Discipline:** append the ledger entry the same session you measure the effect; add a catalog
entry the same session you confirm a new mis-synthesis shape. A measurement or a scar that isn't
written down the same session it's discovered gets rediscovered at full cost later.

See also: `value-level-verification` (the value gate), `kernel-isolation-testing` (gate 5),
`reference-first-verification` (verifying the surrounding IP/RTL this kernel talks to).
