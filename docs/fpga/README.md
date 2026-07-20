# docs/fpga — index

FPGA-side documentation for the SAR image former on PolarFire SoC MPFS250T_ES. This file is an
index only; it deliberately carries no status claims of its own, because duplicated status is what
made these documents drift in the first place.

Start at [`../SAR_DESIGN.md`](../SAR_DESIGN.md) for the detailed current design, or
[`../../README.md`](../../README.md) for the project overview.

## Current

| Document | What it is | Reach for it when |
|---|---|---|
| [`SAR_ARCHITECTURE_REPORT.md`](SAR_ARCHITECTURE_REPORT.md) | As-built block usage and measured per-stage timing. **§5 is the single numeric source of truth** for stage timings and the pipeline total | You need a performance number, or fabric resource usage |
| [`SAR_PIPELINE_STATUS.md`](SAR_PIPELINE_STATUS.md) | Silicon status, engine history (why the FFT moved to the CPU and back to fabric), latency roadmap | You want to know what is proven and what to optimise next |
| [`SAR_PIPELINE_PROCESS.md`](SAR_PIPELINE_PROCESS.md) | The PFA math and its cross-reference to the host-side golden Python | You are reasoning about the algorithm rather than the implementation |
| [`AMBA_ARCHITECTURE.md`](AMBA_ARCHITECTURE.md) | Interconnect topology, AXI4-Lite control windows, master/slave map | You are wiring or debugging the fabric interconnect |
| [`SILICON_ISO_TEST_RUNBOOK.md`](SILICON_ISO_TEST_RUNBOOK.md) | JTAG single-kernel isolation harness, DDR/control map, arg contracts, known-good values, coherent-read technique | **Read before any silicon debug.** Also the eMMC M1 prerequisite recipe |
| [`LIBERO_HEADLESS_PLAYBOOK.md`](LIBERO_HEADLESS_PLAYBOOK.md) | Headless Libero: SmartDesign Tcl, MSS regen, interconnect reconfig, VM-netlist flow, the timing gate | You are rebuilding the fabric without the GUI |
| [`FABRIC_INTERCONNECT_CONVENTIONS.md`](FABRIC_INTERCONNECT_CONVENTIONS.md) | The four interconnect conventions and the `lint_netlist.sh` / `run_build_safe.sh` build gate they enforce | Before adding a master or slave to the fabric |
| [`SAR_TOP_RECOVERY.md`](SAR_TOP_RECOVERY.md) | The verified 62.5 MHz headless CCC recipe (PLL defparam values) and the never-`delete_component SAR_TOP` lesson | You are changing the fabric clock. `build_corefft_vm.tcl` depends on this |
| [`SMARTHLS_ANTIPATTERNS.md`](SMARTHLS_ANTIPATTERNS.md) | Living catalog of proven SmartHLS mis-synthesis shapes. Read by `hls_antipattern_lint.py` | **Before writing or changing any HLS kernel** |
| [`HLS_SILICON_STATS.md`](HLS_SILICON_STATS.md) | Rollup of `hls_silicon_stats.jsonl` — the report-vs-silicon phenomena SmartHLS cannot model | You are assessing whether to trust an HLS report |

## Historical

[`history/`](history/) holds superseded documents, kept for their root-cause narratives and because
they record how decisions were reached. They are not maintained and describe hardware and flows that
no longer exist — notably the `CoreAXI4DMAController` datamover (removed, replaced by
`fft_unloader`), a 125/150 MHz fabric target (the design runs at 62.5 MHz, timing MET), and
host-JTAG scene loading (superseded by the on-board eMMC load).

Do not cite anything in `history/` as current.

## Related material outside this directory

- [`../SAR_DESIGN.md`](../SAR_DESIGN.md) — detailed current design: dataflow, fixed-point contracts,
  DDR map, cache coherency, boot sequence, control interface, diagrams.
- [`../PROJECT_SOURCE_OF_TRUTH.md`](../PROJECT_SOURCE_OF_TRUTH.md) — authoritative index and
  anti-hallucination rules.
- `.claude/skills/` — operating rule cards that point into these documents. The skills carry the
  hygiene rules; these documents carry the procedures, addresses and values.
