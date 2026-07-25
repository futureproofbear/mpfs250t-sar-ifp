---
name: smarthls-kernel-authoring
description: >-
  SmartHLS-specific technical reference for authoring PolarFire SoC/FPGA fabric kernels: the pragma
  syntax, the two AXI-initiator interface APIs (pointer-based vs. explicit), the pin-don't-infer
  discipline as applied to SmartHLS, where to find the authoritative SmartHLS docs for your
  installed version, and toolchain-level mis-synthesis classes observed on SmartHLS itself (as
  opposed to chip-specific silicon errata). Load BEFORE writing or changing any SmartHLS kernel or
  pragma. Complements the vendor-agnostic hls-output-distrust methodology with the Microchip-tool
  specifics. Triggers: "SmartHLS", "shls", "which SmartHLS pragma", "axi_initiator",
  "max_burst_len / max_outstanding", "SmartHLS memory partition", "SmartHLS mis-synthesis",
  "fpga-hls-examples", "shls-assistant".
---

# SmartHLS kernel authoring

This skill is the SmartHLS-tool-specific counterpart to the vendor-agnostic `hls-output-distrust`
methodology (gate structure, Class-A/Class-B framing, the report-vs-silicon ledger). Load that
skill for the *why* and the gate sequence; this one is the *how* for Microchip's SmartHLS compiler
specifically — pragma syntax, the AXI-initiator APIs, and SmartHLS-version-specific mis-synthesis
classes.

## Rule: read the SmartHLS reference before writing or asserting a pragma exists

- **TRIGGER**: about to add, change, or reason about any `#pragma HLS`, or to claim SmartHLS
  can/cannot do something.
- **ACTION**: check the authoritative sources, in this order, for a version matching what's
  actually installed:
  - Pragma manual (exact syntax + every option):
    `https://microchiptech.github.io/fpga-hls-docs/<version>/pragmas.html`
  - User guide (concepts, limitations):
    `https://microchiptech.github.io/fpga-hls-docs/<version>/userguide.html`
  - Official examples (working reference code):
    `https://github.com/MicrochipTech/fpga-hls-examples`
  - Then check your own project's record of previously-confirmed SmartHLS mis-synthesis shapes, if
    one exists.
- **HALT**: if you cannot cite the option in the manual, do NOT assert it exists and do NOT plan a
  design around it. Guessing a pragma knob that doesn't exist (e.g. assuming there is a per-argument
  AXI-ID assignment option on the pointer-based `axi_initiator` pragma when there is not) wastes a
  full synthesis-through-place-and-route build discovering the guess was wrong.
- **Version caveat**: the published docs are commonly pinned to an older version number in the URL
  than what your toolchain installs (e.g. docs published for 2023.1, install running 2025.2). Treat
  the published syntax as indicative and verify against your installed toolchain's own bundled
  manual/help when a documented option doesn't take effect as described.

## Pragma quick reference (syntax — verify against your installed version's own manual)

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

## Pin Class-A behaviour with an explicit pragma, never rely on SmartHLS's inference

- **TRIGGER**: a kernel depends on a specific memory architecture, achieved II, or port count for
  correctness or performance (e.g. a comment or design assumption that a buffer is dual-ported and
  can service two reads per cycle).
- **ACTION**: state it as an explicit `#pragma HLS memory partition ... type(cyclic) factor(<n>)` (or
  the equivalent for the property you need). Relying on SmartHLS inferring the same memory
  architecture from array-access patterns alone is an unpinned assumption that can silently change
  between builds or SmartHLS versions.

## Latency-bound kernels: tune AXI-initiator transaction limits before restructuring

- **TRIGGER**: a kernel's silicon time exceeds its scheduled cycle count and the memory interface is
  not bandwidth-saturated (compute achieved MB/s before assuming bandwidth is the limit).
- **ACTION**: set `max_outstanding_reads(<n>)` / `max_outstanding_writes(<n>)` on the
  `axi_initiator` interface pragma before restructuring the kernel's algorithm. They are documented,
  cheap to try, and are frequently the actual lever for a kernel that's latency-bound on
  unconstrained outstanding requests rather than compute-bound.

## Two AXI-initiator APIs — pick deliberately

- **Pointer-based** (`type(axi_initiator)` on a `T*` argument) — the simple, common path. Bursts are
  inferred from the access pattern, but ALL arguments on that interface share ONE port: reads and
  writes to it serialise, and there is no per-argument AXI-ID, bundle, or port-separation option.
- **Explicit** (`#include <hls/axi_interface.hpp>`, `AxiInterface<>` + `axi_m_read_req` /
  `axi_m_write_req` / `axi_m_read_data` / `axi_m_write_data`) — you drive the AXI channels yourself,
  so a single pipelined loop can issue a read request and a write request and interleave both data
  streams. This is the only way to get genuine read/write concurrency out of one kernel. Cost:
  hand-managed handshake and burst-boundary logic. See the `axi_initiator` example in the
  `fpga-hls-examples` repo for the reference shape.

If a design needs read/write concurrency and only has the pointer-based API in use, that is a real
throughput ceiling, not a tuning problem — the fix is switching that argument to the explicit API,
not more pragma tuning on the pointer-based one.

## SmartHLS-version-specific mis-synthesis classes (toolchain facts, not chip errata)

These are observed characteristics of the SmartHLS *compiler* on the kernel-authoring patterns
below — they are not tied to any one PolarFire SoC die and should reproduce on any board using the
same SmartHLS version. Value-check kernel output on hardware after any rebuild rather than trusting
`shls`'s own report or cosim alone for these shapes:

- **Pure memory-to-stream / stream-to-memory dataflow kernels have been observed to synthesize to
  dead RTL.** A kernel whose job is to stream data directly to/from an AXI-initiator interface
  (rather than a mem-to-mem read-then-compute-then-write kernel) may need to be hand-written in
  RTL/Verilog and integrated as an HDL core instead of authored in SmartHLS. Mem-to-mem kernels
  (read fully, compute, write fully) have not shown this failure mode.
- **A signed narrowing cast following a right-shift has been observed to mis-synthesize as
  unsigned** — e.g. a pattern shaped like `(int16_t)(x >> 16)` on a wider signed value can be
  synthesized to read as unsigned, passing both `shls`'s own report AND cosim/correlation checks
  while being silently wrong on hardware. Treat any signed-narrowing-after-shift cast as a pattern
  to explicitly value-test on real hardware, not just in cosim.
- SmartHLS's own co-simulation (`shls cosim`) has been observed to be unreliable (including outright
  crashing) for at least some kernel shapes on at least one 2025.x installation — verify cosim
  actually works for your kernel before relying on it as a gate; if it doesn't, fall back to a
  board-free bit-accurate value check (see `value-level-verification`) as your pre-silicon value
  proof instead.

## Microchip's own Claude Code plugin (evaluate before hand-rolling pragma advice)

`MicrochipTech/fpga-hls-examples` ships an official Claude Code plugin (`shls-assistant`): an MCP
server (`shls-mcp`) plus a RAG index over the SmartHLS docs, targeted at a specific SmartHLS
release. It generates pragma-correct C++, answers doc questions with citations, and can drive
`shls` commands directly. Prefer it over reciting pragma syntax from memory or from this file when
it's available and its indexed version matches your install — it does NOT know your project's own
silicon scar tissue (which kernels have burned you, which shapes to avoid), which is exactly what a
project-local ledger/catalog (see `hls-output-distrust`) is for. Caveats before installing: it needs
an Anthropic API key, downloads an embedding model and an executable, and expects a local SmartHLS +
Libero install to actually drive builds.

See also: `hls-output-distrust` (the vendor-agnostic gate sequence and Class-A/Class-B framing this
skill's pragmas and mis-synthesis classes plug into), `value-level-verification` (the board-free
value gate to use when cosim is unusable), `microchip-toolchain-quirks` (Libero/SmartDebug-side
Microchip toolchain facts outside SmartHLS itself).
