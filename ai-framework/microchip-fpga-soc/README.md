# microchip-fpga-soc

A Claude Code plugin capturing Microchip-toolchain-specific knowledge for developing on the
PolarFire SoC FPGA family: Libero SoC headless build flows, SmartHLS kernel authoring, SmartDebug
Active-Probe workflows, and FlashPro6/OpenOCD JTAG mechanics and hygiene.

None of the content here is tied to one exact die revision or one exact board's silicon errata. It
was extracted from a real PolarFire SoC bring-up project's `.claude/` framework, generalized to the
level of "true for any PolarFire SoC part using this toolchain" rather than "true for this one
engineering-sample chip on this one board."

## Who this is for

Anyone building on a PolarFire SoC board — any die in the family (MPFS250T, MPFS095T, and others) —
using Microchip's own toolchain: Libero SoC for synthesis/place-and-route/bitstream, SmartHLS for
fabric kernel authoring, SmartDebug for internal fabric visibility, and a FlashPro6 programmer with
OpenOCD/gdb for JTAG-based silicon bring-up and test.

## Install

```
claude --plugin-dir /path/to/ai-framework/microchip-fpga-soc
```

Point `--plugin-dir` at this directory (or wherever you copy it) from any other PolarFire SoC
project. It can be combined with tier 1 for the full methodology:

```
claude --plugin-dir /path/to/ai-framework/generic-fpga-soc --plugin-dir /path/to/ai-framework/microchip-fpga-soc
```

## What's in it

### Agents (`agents/`)

- **libero-build** — headless Libero SoC synth -> place&route -> timing-gate -> bitstream-export
  agent. Refuses to hand back a bitstream unless setup AND hold timing are verified MET (Libero will
  silently program a timing-failing bitstream otherwise). Carries the stale-timing-report trap, the
  `GENERATEPROGRAMMINGDATA`-needs-a-valid-MSS-import trap, the async-CCC-output false-path
  requirement, and other Libero Tcl-flow gotchas. Does not program the device.
- **smartdebug-planner** — given a silicon symptom, produces a SmartDebug Active-Probe plan (exact
  net names resolved from the currently-PROGRAMMED design's own netlist) and a decode table mapping
  readings to a verdict. Also interprets values read back.
- **silicon-test-runner** — runs a JTAG silicon iso-test end-to-end (OpenOCD + gdb over FlashPro6)
  with FlashPro6/JTAG hygiene baked in, so the programmer is never wedged by an unsafe teardown.

### Skills (`skills/`)

- **smarthls-kernel-authoring** — SmartHLS-specific technical reference: pragma syntax, the two
  AXI-initiator APIs (pointer-based vs. explicit) and when each is required, the pin-don't-infer
  discipline applied to SmartHLS pragmas, where to find the authoritative docs for your installed
  version, SmartHLS-version-specific mis-synthesis classes (as distinct from chip-specific errata),
  and Microchip's own `shls-assistant` Claude Code plugin.
- **flashpro6-jtag-recovery** — safely tear down a wedged or stuck JTAG session (OpenOCD + gdb over
  FlashPro6) and decide the correct recovery (telnet shutdown vs. ordered kill vs. USB replug +
  power-cycle) without wedging the FlashPro6 further.
- **microchip-iso-test-harness** — the Microchip-specific HOW for running a JTAG silicon iso-test:
  exact OpenOCD/gdb command patterns, telnet-based graceful shutdown, FIC/DDR coherency handling.
  Complements (does not duplicate) tier 1's `kernel-isolation-testing`, which covers the underlying
  methodology.
- **smartdebug-active-probe** — produce and interpret a SmartDebug Active-Probe plan: the critical
  rule that the SmartDebug design database must match the programmed bitstream, how to resolve real
  net names from the actual synthesized netlist, and the registered-vs-combinational probe-ability
  distinction.
- **microchip-toolchain-quirks** — family-general Microchip Libero/SmartHLS/SmartDebug/FlashPro6
  toolchain quirks and PolarFire SoC IP peculiarities (boot-mode/JTAG-halt interaction, FIC
  non-coherence and AXI-ID width, CoreFFT in-place handshake constraints, Libero's silent
  timing-failing-bitstream behaviour, HDL-core caching) that apply across the family. Deliberately
  excludes any one die's engineering-sample silicon errata.

`fpga-ref-check`, the source project's IP-verification skill, was evaluated and NOT copied here —
its content, once you strip the project's own proper nouns, is identical to tier 1's
`reference-first-verification` skill (same procedure: pin the built config, extract the protocol
with quotes, diff against the golden testbench, corroborate, produce a verdict). It has no
Microchip-specific angle beyond that generic methodology, so duplicating it here would just be the
same skill under a different name.

## Three-tier framework

This package is **tier 2** of a 3-tier system built for FPGA/SoC AI-assisted engineering work:

- **Tier 1 (`../generic-fpga-soc/`)** — vendor-agnostic methodology (reference-first verification,
  HLS-output distrust, value-level verification, kernel-isolation testing, an architectural-critic /
  ingestion-triage / synthesis-repair diagnosis pipeline). Take it to any FPGA/SoC project regardless
  of vendor. This package depends on it: several skills here explicitly reference tier 1 skills by
  name for the underlying methodology and only add the Microchip-specific mechanics on top.
- **Tier 2 (this package, `microchip-fpga-soc`)** — Microchip-toolchain-specific knowledge (Libero,
  SmartHLS, SmartDebug, FlashPro6/OpenOCD) that applies across the whole PolarFire SoC family.
- **Tier 3 (`../mpfs250t/`)** — knowledge specific to one exact chip/board (an MPFS250T engineering
  sample on a specific board), including its engineering-sample silicon errata and board-specific
  bring-up detail. Layers on top of this package for a project on that exact part.

A project on a different vendor's FPGA/SoC should take tier 1 only. A project on a different
Microchip PolarFire SoC part should take tiers 1 and 2. A project on the exact same
MPFS250T-engineering-sample-class board this was extracted from should take all three tiers.
