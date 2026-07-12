# The AI framework in `.claude/`

This repo ships a Claude Code / Agent framework so that a new researcher (human or model)
inherits the accumulated project knowledge automatically instead of re-deriving it. The framework was built around a sar processor example with task-scoped knowledge that loads on
demand, sub-agents that own long or hands-on jobs, a spec workflow, and a discipline layer that
governs how work is done.

The design goal is continuity. Silicon bring-up on engineering-sample hardware accumulates hard-won,
non-obvious knowledge (errata, toolchain traps, verification pitfalls) that is easily lost between
sessions. This framework captures that knowledge next to the code and surfaces it at the moment it
is relevant.

## Layers at a glance

| Layer | Location | What it is | When it activates |
|-------|----------|------------|-------------------|
| Discipline | `CLAUDE.md` | Engineering rules that override default behaviour | Always in context |
| Skills | `.claude/skills/*/SKILL.md` | Task-scoped knowledge packets | Auto-loaded when a trigger phrase matches, or on `/skill` |
| Agents | `.claude/agents/*.md` | Specialized sub-agents with scoped tools | Delegated to for long / hands-on flows |
| Commands | `.claude/commands/opsx/*.md` | OpenSpec slash-command workflow | On `/opsx:*` invocation |
| Handoff / docs | `HANDOFF.md`, `docs/**` | The knowledge base the above point into | Read on demand |

## Discipline layer — `CLAUDE.md`

`CLAUDE.md` is loaded into every session and its instructions override default model behaviour. It
carries two things: generic anti-mistake guidance (think before coding, simplicity first, surgical
changes, goal-driven execution) and the project-specific engineering practices earned on this
SAR-on-silicon work:

- Read the IP User Guide and the golden testbench *before* designing or fixing — not after it fails
  on hardware; check what the golden TB does not exercise.
- Verify timing MET (setup and hold) in place-and-route before treating an on-silicon symptom as a
  logic or firmware bug — the toolchain will silently program a timing-failing bitstream.
- Prefer value-level testing over correlation; correlation hides scale/phase/orientation bugs.
- Headless first; check recoverability before any destructive operation; fix your own mess.
- Capture and update runbooks the same session a procedure or gotcha is proven.

Each of these encodes a real failure that cost time on this project. The discipline layer is what
keeps the skills and agents from being ignored under time pressure.

## Skills — task-scoped knowledge

A skill is a markdown packet with a YAML front-matter `description` that lists trigger phrases. When
the conversation matches a trigger (or the user invokes it explicitly), the skill body loads into
context; otherwise it stays out of the way. This keeps the base context small while making deep
knowledge reachable exactly when needed.

Read `project-orientation` first — it is the entry point that states what the project is, what is
PROVEN vs OPEN, where the source-of-truth docs live, and how the other skills map out.

Project skills, grouped by purpose:

Orientation
- `project-orientation` — start here; project summary, proven/open status, skill and doc map.

Design and domain knowledge
- `sar-pipeline-design` — the datapath stages and the fixed-point / block-floating-point / DDR-streaming contracts.
- `sar-verification-methodology` — value-level testing, the bit-accurate emulator, the golden-orientation pitfall, board-free phase checks.
- `umbra-cphd-data` — the CPHD input format, where the array dimensions actually live, sizing and decimation.

Platform and hands-on procedure (current FPGA target)
- `mpfs-platform-gotchas` — PolarFire SoC ES-silicon errata and Microchip toolchain / IP peculiarities. Has a `references/` sub-folder (es-silicon-errata, microchip-toolchain-and-ip, silicon-debug-methodology) for detail loaded only when drilled into.
- `fpga-ref-check` — verify an IP/RTL integration against its authoritative references before committing to a design or fix.
- `silicon-iso-test` — run a JTAG single-kernel iso-test end-to-end with JTAG hygiene enforced.
- `smartdebug-probe` — produce a SmartDebug Active-Probe plan from the programmed netlist and decode the readings.
- `jtag-recover` — safely tear down a wedged openocd / gdb / FlashPro6 session.

Spec workflow (tooling)
- `openspec-propose`, `openspec-apply-change`, `openspec-sync-specs`, `openspec-archive-change`, `openspec-explore` — the OpenSpec change lifecycle (also reachable as `/opsx:*` commands).

Skills are knowledge, not execution — they tell the current session *what to know and how to
proceed*. When a flow is long-running or hands-on, the skill hands off to a matching agent.

## Agents — specialized sub-agents

An agent is a sub-process launched with its own prompt, its own scoped toolset, and a narrow charter.
Delegating to an agent isolates a long or risky job from the main conversation and enforces its
guardrails. Each agent here has a paired skill (the knowledge) and a hard job (the execution):

- `libero-build` — headless Libero synth → place-and-route → timing-gate → bitstream export for
  SAR_TOP. Refuses to return a bitstream unless setup *and* hold timing are MET. Board-independent;
  does not program the device. Tools: Read, Edit, Bash, Glob, Grep.
- `silicon-test-runner` — runs a JTAG silicon iso-test end-to-end (openocd + gdb over FlashPro6) and
  reports busy/SCRATCH/correlation, with JTAG hygiene baked in so the FlashPro6 is never wedged.
  Board must be powered. Tools: Read, Edit, Bash.
- `smartdebug-planner` — given a silicon symptom, resolves exact net names from the programmed
  netlist and produces an Active-Probe plan plus a reading→verdict decode table. Tools: Read, Grep,
  Glob, Bash.
- `fpga-ref-verifier` — read-only gate that verifies an IP/RTL integration matches the vendor User
  Guide and golden testbench, returning exact-quoted protocol facts, a diff against our RTL, and a
  ranked root-cause list. Tools: Read, Grep, Glob, Bash, WebSearch, WebFetch.

The division of labour: skills carry the *why* and the *contract*; agents carry the *do it safely and
completely*, with the correctness gate (timing MET, JTAG un-wedged, spec-quoted facts) built into
the agent so it cannot be skipped.

## Commands — the OpenSpec workflow

`.claude/commands/opsx/*.md` define the `/opsx:*` slash commands that drive a lightweight
spec-change lifecycle: `propose` (create a change with proposal / design / tasks), `apply` (implement
the tasks), `sync` (fold delta specs into the main specs), `archive` (finalize), and `explore` (a
thinking-partner mode before committing to a change). These mirror the `openspec-*` skills and depend
on the OpenSpec CLI.

## How a session uses it

1. `CLAUDE.md` is always present, so the engineering discipline is in force from the first turn.
2. `project-orientation` (or `HANDOFF.md`) gives the lay of the land and points at the source-of-truth
   docs under `docs/`.
3. As the task takes shape, the matching skill auto-loads its knowledge (e.g. mention CPHD dimensions
   → `umbra-cphd-data`; a stalling IP → `fpga-ref-check`).
4. For a long or hands-on job — a fabric rebuild, an on-board iso-test, a probe plan, an IP
   verification — the work is delegated to the paired agent, which enforces its correctness gate.
5. Any newly proven procedure or gotcha is written back into the relevant runbook or skill the same
   session, so it survives into the next one.

That last step is the whole point: the framework is only as good as the knowledge fed back into it.
Keep the discipline alive.

## Maintaining the framework

- A skill is the right home for durable, reusable knowledge with clear trigger phrases; put the deep
  detail in a `references/` sub-folder so it loads only when drilled into (see `mpfs-platform-gotchas`).
- An agent is the right home for a repeatable multi-step execution flow that needs a scoped toolset
  and a non-negotiable correctness gate.
- Keep skill and agent `description` triggers concrete — they are how the right knowledge finds the
  right moment.
- When a skill and an agent cover the same area, keep them paired: skill = knowledge, agent = gated
  execution.
