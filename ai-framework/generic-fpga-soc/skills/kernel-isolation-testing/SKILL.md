---
name: kernel-isolation-testing
description: >-
  The ISO-TEST concept for hardware debugging -- isolate ONE kernel/IP block in the pipeline, feed
  it a known input directly, and read its output directly, so a bug is localized to one pipeline
  stage by direct evidence rather than inferred from "everything else works." Vendor- and
  transport-agnostic: applies whether the debug link is JTAG, a UART/serial console, a PCIe debug
  BAR, or any other on-chip-debug path. Triggers: "run an iso-test", "test this stage on hardware",
  "isolate the kernel/IP block", "check this stage alone on the board".
---

# Kernel isolation testing

## The concept
When a full pipeline produces a wrong result, do not infer which stage is at fault from "the other
stages already passed their own tests" — that argument is exactly what misses bugs that only appear
under the full pipeline's real timing, backpressure, or data pattern. Instead, isolate the suspect
kernel/IP block: drive it directly with a known input (bypassing the stages before it), and read its
output directly (bypassing the stages after it). A localized pass/fail on that one stage is direct
evidence, not an inference chain.

This is the hardware-debug analogue of a unit test, but it must be run ON the target hardware (or as
close to it as possible) because many of the bugs it exists to catch — backpressure, arbitration,
clock-domain timing, coherency — are exactly the class of bug that only manifests on real silicon
and not in simulation (see `value-level-verification` and `hls-output-distrust` for why).

## Running one, in principle
1. **Pick the smallest decisive case.** A single minimal, well-understood input (e.g. one frame, one
   burst, one impulse) that is enough to distinguish pass from fail is far cheaper and far less
   likely to trip an unrelated multi-transaction issue than a large multi-frame run. Escalate to a
   larger case only once the minimal case passes.
2. **Watch the debug transport's own live log, not just the summary at the end.** Client-side output
   (a debugger's stdout, a test harness's captured output) is often buffered and can hide the
   difference between "still connecting" and "wedged and never going to finish." Watching the
   transport's own live log (e.g. the debug-probe server's log) is usually the more honest signal.
3. **Capture the decisive signals before any risky cleanup step.** If part of the teardown sequence
   (e.g. a cache flush/invalidate, a bus reset) is itself known to sometimes hang, capture the
   decisive evidence (busy/done flags at key timestamps, a raw dump of the output buffer) BEFORE
   that step runs, so the test still produces usable data even if the cleanup step itself hangs.
4. **Report per stage:** the isolated kernel's busy/done/valid signals at meaningful checkpoints, a
   sample of its actual output values, a comparison against the expected/golden output for that
   stage alone, and a clear PASS/FAIL.

## Hard rules (debug-session hygiene — apply regardless of transport)
- NEVER force-kill the debug-probe server or client mid-session. Depending on the transport, this
  can wedge the physical debug adapter or the target's debug logic in a way that a simple retry does
  not clear. Always prefer the tool's own graceful shutdown/disconnect command.
- If a clean shutdown is genuinely not possible, stop the client (debugger) before the server
  (probe-adapter process) — never the reverse — and expect that a wedged adapter may need a physical
  power-cycle or USB/connection replug to recover, not just a software retry.
- On a non-coherent path between fabric/accelerator and CPU memory, flush/invalidate the CPU cache
  both before arming the isolated kernel (so it sees fresh input) and before reading its output back
  (so the CPU doesn't read stale cached data).
- Always leave the debug toolchain shut down cleanly at the end of a session; confirm no orphaned
  debug-server or client processes remain before starting the next one.

## After
If a new gotcha or a reusable procedure comes out of the test, write it into the project's own
runbook the same session — a hard-won debug-session detail that isn't captured immediately tends to
get rediscovered at full cost later.

See also: `value-level-verification` (what to check for once you can read a stage's output in
isolation), `reference-first-verification` (what the isolated stage is supposed to do, per its own
IP documentation).
