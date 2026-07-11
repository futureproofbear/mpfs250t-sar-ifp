---
name: fpga-ref-check
description: >-
  Verify an FPGA IP/RTL integration against its authoritative references (vendor User Guide +
  golden testbench + the generated config) BEFORE committing to a design or fix. Use when
  integrating or debugging a hard IP block (CoreFFT, DMA, CCC, interconnect) or when a silicon
  symptom might be a spec/handshake violation. Triggers: "check the datasheet/UG", "verify the
  handshake", "is our CoreFFT wiring correct", "why does <IP> stall".
---

# fpga-ref-check

The project's first rule (CLAUDE.md + memory `check-docs-and-refdesigns-first`): **read the IP
User Guide and the golden testbench BEFORE committing to a design or fix.** This skill makes that
a repeatable gate.

## When to run
- Before writing/regenerating RTL that drives a hard IP block.
- When a silicon symptom (stall, wrong data, hang) could be a handshake/config violation.
- Before a multi-hour fabric rebuild premised on a hypothesis — confirm the hypothesis first.

## Procedure
1. **Pin the ACTUAL built config.** Grep the generated `coreparameters.v` and the `*_C0.v`
   instantiation (not comments, not memory) for the real parameter values. A leftover parameter
   feeding an UNUSED code path (e.g. `FFT_SIZE` when `NATIV_AXI4=0`) is not the bug — note it and
   move on.
2. **Delegate the deep read** to the `fpga-ref-verifier` agent (or run these inline for a small
   check): extract the protocol from `reference/<IP>_UG.txt` with exact quotes + section numbers
   (only the architecture variant actually built), diff every control pin against the golden TB
   in `mpfs/fpga/libero_*/component/.../test/user/*.v` and the core state machine in
   `.../core/*.v`, and rank candidate causes with RULED-OUT reasoning.
3. For high-stakes or ambiguous points, spin a second `fpga-ref-verifier` (or general agent with
   web tools) to corroborate from microchip.com / the Microchip FPGA forum, and reconcile.
4. **Produce a verdict**: true built config, reference protocol (quoted), pin/handshake diff,
   ranked root cause with evidence, and the single cheapest next probe/change to confirm it.

## Fan-out pattern
For a real diagnosis, launch the reference-extraction, implementation-vs-golden audit, and
web/known-issues checks as PARALLEL agents, then synthesize — that is how the 2026-07-09 CoreFFT
root cause (gearbox read_outp / DATAO-latency desync) was found and how the "READ_OUTP must stay
high" and "MEMBUF" hypotheses were refuted.

## Output
A structured report saved into the relevant runbook (`docs/fpga/*`) so the finding survives new
sessions — per the `capture-learnings-in-runbooks` / `update-docs-with-tested-approaches` rules.
