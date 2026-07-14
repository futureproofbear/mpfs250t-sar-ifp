# An AI Framework for Accelerating Fabric + Firmware Application Design

*Working discussion document. Grounded in the on-board SAR pipeline work on the
PolarFire SoC MPFS250T_ES with data loaded from eMMC (this repo). Purpose: describe how an AI-assisted workflow measurably
speeds up bring-up of applications that span FPGA fabric and embedded firmware, what it does and
does not do, and how to adopt it.*

> **Status legend — practice vs. blueprint.** This document deliberately mixes what runs today with
> where it is heading. Each part is one of:
> - **`[As-run]`** — how the project is actually orchestrated today: a **single** AI agent (Claude
>   Code) over a substrate of repo-checked-in **skills**, hygiene-baked **harnesses**, value-level
>   verification, and **human-in-the-loop** gates. This is §1–3, the *Skills* of §4, §5, and §7–12.
> - **`[Available]`** — capabilities defined in the repo (`.claude/agents/`) but **not yet routinely
>   orchestrated** into the work: the domain agents (the *Agents* column of §4) and, as of this
>   revision, the three debugging personas (§6.1). They are invocable, but this project's sessions
>   have so far run mostly as the single main agent.
> - **`[Target]`** — the dedicated, deterministic multi-agent system with an **automated** closed-loop
>   sim→silicon gate (§6). Partially instantiated (the persona agents now exist; the orchestrator is
>   the main session), **not yet** a fully autonomous gated loop — the sim gate and auto-feedback are
>   still to build (§6.4, §12).
>
> In short: the **substrate and methodology are as-run**; the **multi-agent topology is now
> defined and partly wired, not yet autonomous.** Do not read §6 as describing today's execution.

---

## 1. The problem this addresses

Bringing up an application that lives across FPGA fabric and MSS firmware is slow for reasons that
have little to do with the application logic itself:

- **Tacit, perishable knowledge.** The hard part is rarely the algorithm; it is the hundred small
  platform truths — an engineering-sample erratum, a driver that hangs instead of erroring, a JTAG
  action that wedges the debugger. These live in one engineer's head and evaporate between sessions
  and between people.
- **Long, fragile hardware loops.** A single on-silicon test is minutes of DDR-train + program +
  JTAG, and one wrong move (force-killing the debugger, reading a clock-gated register) costs a
  power-cycle or a USB replug. Iteration is expensive and easy to corrupt.
- **Verification is deceptive.** Correlation/magnitude checks pass on wrong data; a timing-failing
  bitstream programs silently and mimics a logic bug. "It ran" is not "it is correct."
- **Handoff loses everything.** A new engineer inherits a repo but not the reasoning, the gotchas,
  or the exact procedure. Re-discovery is the dominant cost.

The framework treats these — not the RTL or the C — as the real bottleneck, and attacks each.

## 2. The framework at a glance

![AI framework: a HUMAN layer (intent, hardware actions, approval gates, judgement) over an AI
agent with four stacked layers — Knowledge (skills + runbooks + memory), Execution (hygiene-baked
headless harnesses), Verification (goal-driven, value-level, loop-until-proven), and Handoff
(self-contained baselines + skills).](ai_framework_diagram.svg)

The AI does the headless, repeatable, knowledge-heavy work; the human keeps the decisions that need
a person (the physical board, timing closure, "is this what we want").

## 3. The five pillars

### Pillar 1 — Durable knowledge capture (skills, runbooks, memory)

Every hard-won fact is written back the moment it is proven, into artifacts that live *in the repo*
and load automatically:

- **Skills** — named, trigger-activated knowledge packs (`.claude/skills/`). Examples in this repo:
  `mpfs-platform-gotchas` (the ES-silicon errata + toolchain traps), `emmc-onboard-pipeline` (the
  full eMMC operational runbook), `sar-verification-methodology`, `silicon-iso-test`. A skill loads
  before the AI touches a domain, so known traps are avoided rather than re-hit.
- **Runbooks** — proven procedures with the exact command, expected output, and the failure mode
  each step avoids (`docs/fpga/*RUNBOOK*.md`), updated the same session a procedure is established.
- **Memory** — session-spanning notes for context that isn't in the code.

The effect: knowledge stops being tacit. It survives the session, and — critically — it survives the
*engineer*. This is the difference between a tool and an institutional capability.

### Pillar 2 — Hygiene-baked headless execution

The AI drives the real toolchain (Libero/SmartHLS, SoftConsole `make`, `fpgenprog`, OpenOCD + GDB
over FlashPro6) through scripted harnesses that have the platform's safety rules built in, so the
common ways to wreck a board are structurally prevented:

- Never force-kill the debugger (wedges the FP6); tear down via a graceful telnet/`monitor shutdown`.
- Bound every wait with a watchdog so a stuck kernel yields a timeout, never an un-haltable hang.
- Attach-in-place on this ES silicon; never blind-reset.
- Refuse a bitstream unless setup AND hold timing are met.

These harnesses (`run_m3_iso.sh`, `run_emmc_*`, the iso-test runners) are reusable and parameterised,
so an on-silicon experiment is one command, repeatable, and logged.

### Pillar 3 — Goal-driven, value-level verification loops

Work is framed as a verifiable goal, then looped until the goal is objectively met — not until it
"seems to run":

- Define success as a concrete check (a CRC match, a bit-accurate diff against a golden model, an
  image that shows coherent speckle), not "it completed."
- Verify by **value**, not correlation — correlation is scale/phase/orientation-invariant and hides
  real bugs. Build a bit-accurate mirror of the hardware, match it to golden first, then diff silicon.
- Treat AI output as plausible-until-proven. Adversarial and cross-check passes catch the confident-
  but-wrong answer before it becomes a committed bug.

### Pillar 4 — Human-in-the-loop for the physical and the irreversible

The AI is aggressive on headless work and conservative on anything a person must own: powering the
board, closing timing, destructive/outward actions, and ambiguous requirements. It surfaces the
tradeoff and asks rather than guessing when the answer is genuinely the human's to make.

### Pillar 5 — Self-contained handoff

The end state of any effort is a baseline another engineer can continue cold: a standalone repo whose
firmware source equals the silicon-proven state, whose build is verified, and which carries the
operational skill inside it. A new person clones the repo, opens a fresh AI session, and the skill
tells them where things stand and the exact next step — no shoulder-tapping the original author.

## 4. The agent + skill fabric, by domain

The framework is built from two kinds of block, and it helps to keep them distinct:

- **Skills** = *knowledge* packs that load INTO the working session when their topic comes up. They
  carry a domain's facts, proven procedures, and traps. Repo-checked-in, so they travel with the code.
- **Agents** = *execution* specialists that RUN as sub-processes with a scoped toolset and a single
  job — e.g. "build a bitstream, but refuse to hand it back unless setup AND hold timing are met."
  Each encapsulates a workflow together with the guardrail that workflow must never violate.

Skills tell the session *what is true and what to avoid*; agents *do a bounded job correctly*.
Together they cover the full fabric → firmware lifecycle:

| Domain | Skills (knowledge that loads) | Agents (specialists that run) | The trap it removes / guarantee |
|---|---|---|---|
| **Orientation & input** | `project-orientation`, `umbra-cphd-data` | `Explore`, `Plan` | a new engineer/session starts from proven-vs-open + a source-of-truth map, not from zero |
| **Fabric** (RTL + hard IP) | `sar-pipeline-design`, `fpga-ref-check`, `mpfs-platform-gotchas` | `fpga-ref-verifier`, `smartdebug-planner` | RTL/IP matches the vendor User Guide + golden TB *before* silicon; catches the CoreFFT/DMA handshake class |
| **Firmware** (MSS bare-metal) | `emmc-onboard-pipeline`, `mpfs-platform-gotchas`, `jtag-recover` | `silicon-test-runner` | coherency / boot / clock-gating traps avoided; the debugger is never wedged |
| **Synthesis / P&R / timing** | `hls-trust-harness`, `mpfs-platform-gotchas` | `libero-build` | no bitstream is trusted unless setup AND hold are MET; HLS output is gated, not assumed |
| **Verification** | `sar-verification-methodology`, `hls-trust-harness`, `fpga-ref-check` | `fpga-ref-verifier` | correctness by VALUE against a bit-accurate mirror (not correlation); per-kernel silicon value-check |
| **On-silicon testing** | `silicon-iso-test`, `smartdebug-probe`, `jtag-recover` | `silicon-test-runner`, `smartdebug-planner` | one-command iso-test with JTAG hygiene; internal fabric visibility when register reads can't see |

**How they compose — a fabric change, end to end.** `fpga-ref-verifier` confirms the RTL/IP
integration matches the reference and generated config → `libero-build` runs synthesis + place &
route + the timing gate and *refuses to emit a bitstream unless timing closes* → `silicon-test-runner`
runs the iso-test over JTAG with hygiene baked in → `sar-verification-methodology` checks the output
by value against a bit-accurate emulator, in the correct golden orientation. If a kernel stalls,
`smartdebug-planner` produces an active-probe plan against the *programmed* netlist; if the debugger
wedges, `jtag-recover` tears it down without a further wedge. Every new trap found along the way is
written back into `mpfs-platform-gotchas` (or the relevant domain skill) so the next pass avoids it.

**Reusable substrate vs. application layer.** Most of this is *platform*-specific, not
*application*-specific, and is reused unchanged for the next application on this silicon:
`mpfs-platform-gotchas`, `fpga-ref-check`, `hls-trust-harness`, `silicon-iso-test`, `smartdebug-probe`,
`jtag-recover`, and every agent. Only a thin layer is swapped per application — here the SAR-specific
`sar-pipeline-design`, `sar-verification-methodology`, `umbra-cphd-data`, and `emmc-onboard-pipeline`.
A new application inherits the substrate and writes only its own domain + verification skills.

## 5. Case studies (the evidence)

### 5.1 — eMMC on-board SAR pipeline (a capability built end-to-end)

A concrete, end-to-end run of the framework on a real capability: **store a radar scene on the
board's eMMC, load and focus it entirely on-board, and persist the image back to the card** — which
retires a ~3-hour JTAG scene load per run.

| Milestone | What was built | Proven on silicon |
|---|---|---|
| M1 | eMMC bring-up: 512 B write→read→CRC | Yes |
| M2 | Provision the scene to the INPUT partition + CRC verify | Yes (`crcE==crcR`, 97.6 MB scene) |
| M3 | Boot-load eMMC→DDR + reconstruct job + run the pipeline + persist the output | LOAD/focus/crop proven; crash-safe save built |

What the framework contributed, concretely:

- **Gotchas captured, then never re-hit.** e.g. multi-block SDMA hangs un-haltably because hart1
  runs with interrupts off; a GDB path quirk; a driver result that reads stale without an L2 flush.
  Each was diagnosed once, written into the runbook + skill, and avoided thereafter.
- **A design flaw caught by review, not by a crash.** The output-save was reordered to a crash-safe
  "commit-last" sequence after reasoning through a mid-write power loss — before it bit anyone.
- **Board time spent deliberately.** A ~13-minute full-scale de-risk probe was run before committing
  to a ~3-hour irreversible load, because the framework reasons about cost/recoverability first.
- **Verification by value.** The focused image was confirmed by dumping a crop and seeing coherent
  SAR speckle + real scene structure — not by a correlation number.
- **A standalone baseline + handoff skill** were produced and pushed, so a colleague continues with
  no live handover.

### 5.2 — CoreFFT + DMA fabric integration (overcoming a "cosim-passes, silicon-fails" bug class)

The hardest bugs on this platform are the ones where every off-line check is green and only the
silicon is wrong. Getting the 8192-point range FFT running on the **CoreFFT hard IP** with a fabric
streaming/DMA datapath was exactly this class, and it is where the framework earned its keep.

The failures were subtle and mutually disguising:

- **A SmartHLS mem→stream feeder that was dead RTL on silicon.** The HLS-generated feeder passed
  cosim but issued *zero* bus transactions on the board (`arvalid` stuck low). The mem↔stream
  interface simply does not synthesize to working hardware on this toolchain — so the feeder had to
  be hand-written in Verilog.
- **A gearbox latency trap.** CoreFFT's `DATAO_VALID` trails `READ_OUTP` by ~4 cycles; a gearbox that
  gated its capture on `READ_OUTP` silently dropped in-flight beats whenever it backpressured,
  desyncing the real/imaginary pairing and starving the unloader. The fix — capture on `DATAO_VALID`,
  release `READ_OUTP` on an almost-full threshold that reserves the latency — is a handshake detail
  invisible to a functional model.
- **A DMA unloader that deadlocked on the *second* transfer.** The stock `CoreAXI4DMAController`
  hangs on the second back-to-back stream transaction — a re-arm path the vendor golden testbench
  never exercised because it only ran a single transform.
- **An in-place-core config hazard** (MEMBUF buffering that corrupts under a slow, backpressuring
  sink) that looks like a data bug but is a configuration choice.

What the framework contributed to untangling this:

- **Reference-first, and "what does the golden TB *not* exercise?"** The re-arm deadlock was found by
  reading the IP User Guide and noticing the golden testbench only ran one transform — before it cost
  another silicon cycle. This discipline is written into the platform skill so it is applied by
  default, not rediscovered.
- **Value-level, single-kernel localization.** Rather than infer from "everything else works," the
  method flushes a known input to DDR, arms exactly one kernel, and reads its input and output
  directly. That localized an all-zero image to the true offending stage — and caught a near-miss
  where a truncated memory read of edge zero-fill columns briefly blamed the wrong stage (the fix:
  read past the zero-fill).
- **CPU-fallback isolation.** Reimplementing a suspect fabric kernel on the MSS behind a runtime flag
  both isolated the fault and gave a working shipping path with no fabric rebuild.
- **Each fix captured once.** The gearbox rule, the DMA-unloader type fix, the MEMBUF hazard, and the
  "hand-write mem↔stream in Verilog" rule are now in the platform skill and runbook — so this bug
  class is paid down permanently, not re-encountered.

The honest takeaway: the framework did not make these bugs trivial — they took real silicon time. What
it did was stop them being *repeatedly* expensive, and convert one-time pain into permanent,
transferable knowledge.

## 6. The implementation blueprint — agents, skills, and the harness

Sections 1–5 describe the framework as it operates today inside an agentic coding tool (an AI with a
skill + tool loop). This section is the reference blueprint for building it as a *dedicated,
deterministic multi-agent system* — e.g. on AutoGen or LangGraph — specialised for the highest-value
loop on this platform: diagnosing and repairing a silicon deadlock. Three parts: the team (agents),
the toolset (skills), and the execution model (the harness).

### 6.1 The team — multi-agent topology

Cross-domain silicon debugging is split across three specialised, non-overlapping personas under an
orchestrator, so no single context carries software bias into a hardware problem.

![Multi-agent topology: an Orchestrator/Judge over three agents — Ingestion & Triage (raw JTAG/ILA
to semantic JSON state), Architectural Critic (concurrency/arbitration/handshake laws), and Synthesis
& Repair (localized HLS/Verilog/C patches).](ai_agent_topology.svg)

- **Orchestrator / Judge** — routes work between agents, holds the debugging loop, and decides when a
  fix is genuinely done (all gates green), not when an agent merely claims success.
- **① Ingestion & Triage Agent** — the machine-domain parser. Ingests raw JTAG register dumps, ILA
  traces, and hardware-description dictionaries and normalises them into semantic JSON state maps. It
  establishes ground-truth runtime state and nothing else — it proposes no fixes.
  > *"You are an expert low-level embedded hardware diagnostics interface. You ingest raw JTAG
  > register hex, ILA traces, and hardware dictionaries and normalise them into semantic JSON state
  > maps. You do not fix code; you only establish ground-truth runtime execution state."*
- **② Architectural Critic Agent** — the hardware-wise brain. Evaluates the system by the laws of
  spatial concurrency, arbitration, clock-domain crossings, and interface specs (AXI4, APB, Avalon).
  It assumes every software-correctness claim is false until the physical routing / handshake is
  shown unblocked, and hunts specifically for shared-resource contention loops and circular handshake
  dependencies.
  > *"You are a rigid micro-architectural verification engineer. You evaluate by spatial concurrency,
  > arbitration, clock-domain crossings, and interface specs. Assume all software-correctness claims
  > are false if the underlying routing or handshake is blocked. Look for shared-resource contention
  > and circular handshake dependencies."*
- **③ Synthesis & Repair Agent** — the co-design generator. Writes precise, localised corrections in
  HLS C++, Verilog/SystemVerilog, and low-level C, strictly within the constraints the Critic
  established. Every patch must state its compilation requirements, target pragma updates, and stream
  destinations.
  > *"You are an expert RTL + firmware co-design engineer. You synthesize localized corrections in
  > HLS C++, Verilog/SV, and C, strictly within the Architectural Critic's constraints. Every patch
  > states its compile requirements, pragma updates, and stream destinations."*

The division mirrors what this project needed by hand. The CoreFFT/DMA deadlock (§5.2) was a *Critic*
problem — a circular handshake (`DATAO_VALID` trailing `READ_OUTP`; a DMA unloader starving on a
re-arm path the golden testbench never exercised), not a code-logic problem — and diagnosing it
required *Ingestion* discipline (read the actual input and output of one isolated kernel) before any
*Repair* was allowed.

### 6.2 The toolset — skills as typed functions

In AutoGen/LangGraph the skills are typed Python functions the agents call to touch the real
environment. Three are foundational — and each maps onto a harness this project already runs by hand:

```python
import subprocess, json
from pathlib import Path

# SKILL 1 — physical hardware interaction   (here: run_m3_iso.sh / run_*_iso.sh)
def execute_jtag_telemetry_capture(target_cfg_path: str, probe_script_tcl: str) -> dict:
    """Connect to the local debug server (OpenOCD / XSDB / HW Manager) over JTAG and
    capture the live state-machine bits + bus registers of frozen hardware -> JSON."""
    cmd = ["openocd", "-f", target_cfg_path, "-f", probe_script_tcl]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(result.stdout)            # raw hex -> structured telemetry

# SKILL 2 — structural graph extraction
def extract_rtl_data_flow_graph(source_file_path: str) -> dict:
    """Parse HDL into a Control/Data-Flow Graph via a synthesis front-end (Yosys /
    Clang AST) so the Critic reasons over the netlist, not the source text."""
    out = Path(source_file_path).with_suffix(".json")
    subprocess.run(["yosys", "-p", f"prep; write_json {out}"], check=True)
    return json.loads(out.read_text())

# SKILL 3 — local toolchain compilation + lint   (here: SoftConsole make / libero-build)
def verify_hardware_compilation(project_dir: str, build_target: str) -> dict:
    """Run the native compiler/linker (vitis_hls / riscv64-elf-gcc / make) to confirm a
    patch is syntactically valid and fits the micro-architectural constraints."""
    r = subprocess.run(["make", "-C", project_dir, build_target],
                       capture_output=True, text=True)
    return {"success": r.returncode == 0, "stdout": r.stdout, "stderr": r.stderr}
```

The discipline that makes them safe is the one already baked into this project's harnesses: the JTAG
skill must never force-kill the debug server (it wedges the FlashPro6), every wait is bounded so a
frozen target cannot hang the loop, and a capture never reads a clock-gated register.

### 6.3 The execution model — the closed-loop harness

The agents and skills are wrapped in a deterministic cycle with a multi-stage validation gate. This
is what turns a text generator into a tool-wielding system: **the AI cannot deliver a fix until it
passes every gate.**

![Closed-loop harness: deadlock -> JTAG capture -> Agents 1+2 diagnose -> Agent 3 repair -> compile
gate -> virtual-sim gate (reproduce then clear the lockup) -> hardware-in-the-loop gate (TREADY high,
count past threshold, deadlock cleared) -> verified fix; any gate failure feeds telemetry back to the
Critic.](ai_closed_loop_harness.svg)

- **Gate 0 — compile.** The patch must build in the native toolchain. Fail → errors go back to the
  Critic/Repair pair.
- **Gate 1 — virtual simulation.** The framework writes the patch into the workspace and fires a
  behavioural testbench (Cocotb + Verilator / Icarus). The patch must first *reproduce* the lockup
  under high-pressure traffic, then pass a targeted unit check that clears it. Reproducing the failure
  first is what rejects a plausible-but-irrelevant fix.
- **Gate 2 — physical silicon (hardware-in-the-loop).** Only if Gate 1 passes: the full
  bitstream/binary is generated, the board is programmed over JTAG/UART, the firmware runs, and the
  Ingestion agent fires `execute_jtag_telemetry_capture` one last time to confirm the *actual running*
  system — e.g. `DMA_TREADY` stays high, the accumulated stream count passes the failure threshold,
  and the deadlock state is cleared.

Any failure appends the compiler errors or live JTAG telemetry back into the agent conversation graph
and re-prompts the Architectural Critic to re-evaluate the spatial constraints (the red rail in the
diagram). The loop exits only on a fix verified on real silicon.

This is Pillars 2–3 (hygiene-baked execution + value-level verification) hardened into an explicit
machine: two independent gates, the second on real hardware, with failure fed back as data rather
than trusted away. It is exactly the loop that would have caught the CoreFFT re-arm deadlock
automatically — Gate 1 reproducing the second-transaction lockup the vendor testbench skipped, Gate 2
confirming `TREADY` on silicon.

### 6.4 From blueprint to running — what exists now `[Available]` / `[Target]`

This revision takes the first concrete step from blueprint toward practice: the three personas are
now **real, invocable, repo-committed agents** under `.claude/agents/`, with tools scoped to their
role. They compose with the domain agents this project already ships:

| Blueprint persona | Repo agent (`.claude/agents/`) | Tools (role scope) | Composes with |
|---|---|---|---|
| Orchestrator / Judge | the **main session** (no separate file) | all | routes work, runs the gates, decides "done" |
| ① Ingestion & Triage | `ingestion-triage` | Read/Grep/Glob/Bash — read-only | `silicon-test-runner` + the iso-test harnesses for live JTAG capture |
| ② Architectural Critic | `architectural-critic` | +WebFetch — read-only | `fpga-ref-verifier` (spec conformance) + `smartdebug-planner` (internal visibility) |
| ③ Synthesis & Repair | `synthesis-repair` | +Edit/Write — writes code | `libero-build` (synth/P&R/timing gate) + the compile gate |

**What is now true `[Available]`:** the personas can be spawned and composed today; the
Orchestrator is the main coordinating agent; the read-only/write tool split is enforced by each
agent's definition (Triage and Critic literally cannot edit code).

**What is still `[Target]`:** the *automated* closed-loop of §6.3. The Cocotb/Verilator sim gate and
the autonomous fail → re-diagnose feedback rail are **not yet wired**, so the loop remains
human-orchestrated — a person runs the harness, reads the gate result, and routes the next step.
Closing that gap — a deterministic runner that spawns the personas and enforces the two gates with
no human in the *inner* loop — is the concrete next milestone (§12).

## 7. What it accelerates (honestly)

Demonstrated in this project:

- **No re-learning.** Platform traps that historically cost hours each were paid once and then
  designed around, because the knowledge was captured in-repo.
- **Continuous multi-milestone progress.** M1→M2→M3 proceeded as one sustained effort rather than
  stalling on tacit-knowledge gaps between them.
- **Cheaper hardware loops.** Headless, logged, guardrailed runs; de-risking before expensive
  irreversible operations; parallelisable background jobs.
- **Near-zero-friction handoff.** A cold engineer + fresh AI session can continue from a cloned repo.

What is *not* claimed: this does not remove the need for hardware, for timing closure, or for
engineering judgement, and it does not turn a wrong design into a right one. Its speedup is in the
overhead around the design — knowledge, iteration hygiene, verification, and handoff — which on this
class of work is the majority of the elapsed time.

## 8. Where humans stay essential

- **The physical board** — power, jumpers, cabling, the actual FlashPro.
- **Timing closure** — a person owns the decision that a bitstream is trustworthy.
- **Judgement on intent** — ambiguous requirements, "is this the right thing," risk acceptance on
  irreversible operations.
- **Final accountability** — the AI proposes and executes; the engineer signs off.

## 9. How to adopt it

1. **Seed a gotchas skill per platform/domain first.** Before bring-up, capture the known errata and
   toolchain traps. This is the highest-leverage artifact.
2. **Write the runbook the same session a procedure is proven** — exact command, expected output,
   failure mode avoided. Stale runbooks are worse than none.
3. **Build hygiene-baked harnesses, not one-off commands.** Bake the safety rules in so they can't be
   forgotten under time pressure.
4. **Frame every task as a value-level verifiable goal**, and loop until it is objectively met.
5. **End every effort at a self-contained baseline** with its operational skill committed alongside.

## 10. Limitations and risks (and the mitigations)

- **Plausible-but-wrong output.** Mitigation: value-level verification, bit-accurate mirrors,
  adversarial cross-checks — never trust "it ran."
- **Silent hardware failure modes** (timing-failing bitstream, clock-gated dead-bus). Mitigation:
  timing gates in the harness; platform gotchas skill; verify-before-trust.
- **Knowledge drift.** A skill/runbook that isn't updated misleads. Mitigation: same-session capture
  discipline; treat the skill as part of the deliverable, not documentation-after-the-fact.
- **Over-automation of the irreversible.** Mitigation: explicit human-in-the-loop gates for physical
  and destructive actions.

## 11. Outstanding challenges

These are open engineering problems the framework *helps manage* but has not eliminated — the honest
frontier of this work.

- **HLS synthesis is not trustworthy for silicon (the biggest one).** On this toolchain, SmartHLS
  silently miscompiles in ways that pass both cosim and correlation: mem↔stream kernels synthesize to
  *dead RTL* (zero bus transactions), and a sign-extension cast in the detect kernel was optimized
  wrong, saturating ~50 % of the image. The consequence is a standing tax: every HLS kernel must be
  value-checked on silicon after each rebuild, and streaming interfaces routinely fall back to
  hand-written Verilog. HLS does not yet deliver the productivity it promises here.
- **Verification is still largely manual.** The only reliable catch for the above is value-level
  silicon comparison against a bit-accurate mirror with the correct golden orientation — and building
  that mirror, and doing the orientation scan, is hand work today.
- **Timing closure remains a human-owned gate.** The toolchain will silently program a
  timing-failing bitstream; a person still has to own "this bitstream is trustworthy."
- **Host↔board bandwidth.** The FlashPro6 JTAG link is ~9 KB/s, so moving a scene or an image
  to/from the PC is a ~3-hour operation. On-board eMMC fixes *on-board* transfers only; large-data
  offload to a host is unsolved on this hardware.
- **Bootstrap and interrupt-model constraints.** The first scene still needs a one-time ~3-hour JTAG
  load to reach the card; and faster eMMC DMA (SDMA) is currently unusable because the firmware runs
  with interrupts off — using it needs a rework of the interrupt model.

## 12. Future research directions

Where the framework could go next — several already have first steps in this repo.

- **An automated HLS trust harness.** Systematic antipattern linting plus a living
  report-vs-silicon ledger, so HLS output is either trustable-by-construction or automatically
  flagged. First steps exist here (`hls_antipattern_lint.py`, `SMARTHLS_ANTIPATTERNS.md`, the
  HLS-stats ledger, the `hls-trust-harness` skill); the direction is to make per-kernel silicon
  value-checking automatic and mandatory after every synthesis.
- **AI-assisted RTL for what HLS cannot do.** Auto-generate — and property/assertion-check — the
  hand-written mem↔stream feeders and unloaders that HLS produces as dead RTL, closing the one gap
  that forces a drop to manual Verilog.
- **Automated golden-testbench gap analysis.** Have the AI read the vendor IP User Guide and its
  golden testbench and report which protocol paths are *not* exercised (the DMA re-arm deadlock came
  from exactly such an unexercised path). Turn a discipline into an automated check.
- **Verification at multi-agent scale.** Fan-out finders plus adversarial verifiers, automatic
  construction of the bit-accurate silicon mirror, and exhaustive orientation/edge scans — so
  correctness coverage scales beyond one engineer's patience rather than sampling.
- **Self-updating institutional knowledge.** The AI proposing skill/runbook diffs automatically from
  each debugging session (human-reviewed), lowering the discipline cost of same-session capture and
  keeping the knowledge base from drifting.
- **Assertion-based iso-test harnesses.** Protocol and timing assertions baked into the on-silicon
  runners so handshake violations surface in simulation before they cost a board cycle.
- **(Hardware, for completeness — the one thing the AI framework can't touch):** a faster host link
  (fabric UART/Ethernet/USB) to retire the ~3-hour JTAG offload.

---

### One-line summary

The application logic is the easy part; the platform knowledge, iteration hygiene, verification, and
handoff are where the time goes — and that is exactly what this AI framework captures, automates, and
makes durable, as demonstrated end-to-end by the eMMC on-board SAR pipeline in this repository.
