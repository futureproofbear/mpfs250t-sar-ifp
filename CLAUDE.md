# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

## Engineering practices (project discipline)

Project-specific rules earned on this SAR-on-silicon work. They complement the generic guidance above.

- **Read the reference before designing/fixing.** Read the relevant IP User Guide section (exact
  operating mode + handshake) AND the golden testbench BEFORE committing to a design or a fix — not
  after it fails on hardware. Check what the golden TB does NOT exercise. (Cost real time on the FFT
  integration: the golden TB only ran one transform, never the re-arm path.)
- **Verify timing MET before functional silicon debug.** Confirm setup AND hold closed in place-and-route
  before treating any on-silicon misbehaviour as a logic/firmware bug — timing violations mimic
  functional bugs perfectly, and the toolchain will program a timing-failing bitstream silently.
  "Stage completes" ≠ "data correct" ≠ "timing met".
- **Prefer value-level testing over correlation.** Correlation/magnitude is scale-, phase-, and
  orientation-invariant and hides real bugs. Feed known inputs, diff actual complex sample values
  against a bit-accurate model, and find the correct golden orientation before declaring a divergence.
- **Headless first; check recoverability before destructive ops.** Reach for scripted/CLI paths over
  the GUI. Before any destructive or hard-to-reverse operation (delete, overwrite, reconfigure), verify
  the target is recoverable (in git / backed up), prefer in-place edits and work on copies. Fix your own
  messes headless rather than handing cleanup to the user.
- **Capture and UPDATE runbooks the same session.** Store reusable procedures/gotchas in the runbook
  docs (`docs/fpga/*RUNBOOK*.md`, `SAR_PIPELINE_STATUS.md`, `SAR_TOP_RECOVERY.md`, …) and write a proven
  procedure or new gotcha back into the relevant runbook in the SAME turn it is established — with the
  exact command, expected output, and the failure mode it avoids — so it survives into new sessions.
- **Environment:** no PowerShell (a standing preference and GPO-blocked here) — use `cmd`/git-bash;
  `wmic` and `winget` are unavailable, prefer `reg query`/`pnputil`/`mode`.
- **Prose style:** use **bold** sparingly — reserve it for a few key labels or the single headline
  result per document; keep body prose and equations plain.