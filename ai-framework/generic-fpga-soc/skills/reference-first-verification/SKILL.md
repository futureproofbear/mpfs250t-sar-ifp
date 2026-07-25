---
name: reference-first-verification
description: >-
  Verify an FPGA/SoC IP or RTL integration against its authoritative references (vendor User Guide +
  its own golden testbench + the actually-generated/built configuration) BEFORE committing to a
  design or a fix. Use when integrating or debugging a hard IP block (an FFT core, a DMA controller,
  a clock-conditioning circuit, an interconnect) or when a hardware symptom might be a spec/handshake
  violation rather than a logic bug. Triggers: "check the datasheet/UG", "verify the handshake", "is
  our wiring to this IP correct", "why does this IP stall", "reference-first".
---

# Reference-first verification

The governing rule: **read the IP's User Guide and its own golden testbench BEFORE committing to a
design or a fix.** This skill makes that a repeatable gate instead of a one-off gut check.

## When to run
- Before writing/regenerating RTL that drives a hard IP block.
- When a hardware symptom (stall, wrong data, hang) could be a handshake/configuration violation
  rather than a logic bug.
- Before a multi-hour rebuild premised on a hypothesis — confirm the hypothesis first, cheaply.

## Procedure
1. **Pin the ACTUAL built configuration.** Read the tool-generated parameter/instantiation source
   (not comments, not memory, not the docs you wrote when you designed it) for the real parameter
   values actually wired into the build. A leftover parameter that feeds an UNUSED code path (e.g.
   a size parameter for a mode the build doesn't select) is not the bug — note it and move on.
2. **Extract the protocol with exact quotes + section/table numbers.** Only the architecture variant
   that is actually built (see step 1) — a User Guide describing multiple variants (buffered vs
   unbuffered, in-place vs streaming, etc.) is a common source of chasing the wrong handshake rule.
   Cover: handshake timing, backpressure rules, reset/clock initialization requirements, and which
   signals gate progress versus are merely informational outputs.
3. **Diff the integration against the golden testbench and the core's own state machine.** For every
   control pin, state how the testbench drives it versus how the project ties it, and whether it
   even reaches the built configuration. Flag floating inputs, mis-tied pins, clock-ratio
   violations, and handshake-timing or pipeline-latency mismatches.
4. **Corroborate ambiguous points.** For high-stakes or ambiguous protocol facts, check the vendor's
   own site and its official support/community forum, and state your confidence.
5. **Produce a verdict:** the true built configuration, the reference protocol (quoted), a pin/
   handshake diff, a ranked root cause with evidence — explicitly marking which candidates were
   RULED OUT and why ("refuted by the golden testbench" beats speculation) — and the single cheapest
   next probe or change that would confirm the top candidate.

## Fan-out pattern
For a real diagnosis, run the reference-extraction, implementation-vs-golden audit, and
web/known-issues corroboration as PARALLEL, independent passes, then synthesize the results together
— an ambiguous single-pass read is much more likely to anchor on the first plausible hypothesis and
fail to refute it.

## Output
A structured report: built configuration, quoted reference protocol, diff table, ranked root cause
with ruled-out alternatives, and the next cheapest probe. Save it somewhere durable in the project
(a runbook / design-notes doc) so the finding survives into future sessions rather than being
rediscovered at the same cost.
