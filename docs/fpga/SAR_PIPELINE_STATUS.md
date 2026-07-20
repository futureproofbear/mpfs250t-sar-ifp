# SAR Pipeline — Silicon Status & Latency Roadmap

> **Numbers live in one place.** Per-stage timings, the pipeline total and the resource table are
> maintained in [`SAR_ARCHITECTURE_REPORT.md`](SAR_ARCHITECTURE_REPORT.md) §5 — the single numeric
> source of truth. This document covers *status*, *why the design is shaped the way it is*, and the
> *latency roadmap*. Re-read live timings any time with `bash mpfs/host/run_stage_timing.sh`
> (no pipeline re-run needed).

## Status: VALIDATED END-TO-END ON SILICON

The full PFA (polar-format) SAR pipeline runs on the PolarFire SoC MPFS250T_ES (Icicle-style board,
JTAG/FlashPro6) and produces the correct focused image, autonomously from the board's own eMMC:

- Scene loads eMMC → DDR in **81.5 s** (`sig_crc 0x89fa12dc` verified), retiring the ~3 h JTAG input load.
- `sar_form_image` (PIPE mailbox cmd) returns `SAR_SEQ_OK` in **88.1 s**, with `fft_mode=1`
  (fabric CoreFFT) confirmed at runtime. Reproducible across consecutive runs (88.04 / 88.11 s), with
  the output image byte-identical between runs and to the previous build.
- Correlation vs golden reference = **0.9923** (Centerfield decimated 705×540 scene, band rows
  896:1152, 1.05 M unsaturated pixels; a point-target crop hits 0.9962). The board image matches
  `golden_small_mag.npy` in the **`T.rot180`** orientation (`board == golden.T[::-1,::-1]`) — exactly
  the "match up to orientation" the golden spec allows.
- A top-left 1024×1024 ROI crop confirms a coherent focused image (speckle, field boundaries, roads,
  point scatterers).

Stage-by-stage engine assignment and detailed dataflow: [`../SAR_DESIGN.md`](../SAR_DESIGN.md).
Data flow: `resample → corner-turn → window → range-FFT → corner-turn → azimuth-FFT → detect`,
buffers SIG `0x88000000` / SCRATCH `0x98000000` / OUT `0xA8000000` (see `sar_sequencer.c`).

## Engine history: the FFT went to the CPU, then back to fabric

This is the most-misread part of the design, so it is recorded explicitly.

**Phase 1 — the HLS FFT was unsynthesizable.** The HLS `K_FFT` kernel (`hls_fft/hls_fft.hpp`
`fft_in_place_bfp`, control slave `0x60004000`) **drops the twiddle term** in the generated RTL on
SmartHLS 2025.2, collapsing to an identity/passthrough on silicon — while every C-simulation passes at
corr 0.9999. Proven across three independent FFT structures, all rebuilt and tested on silicon:

1. `hls::DoubleBuffer` ping-pong (original) → const-1000 → flat `0x00030000` (= input>>out_shift).
2. Explicit `static buf[2][SIZE<<1]` ping-pong → identical passthrough.
3. Single-array in-place `re[]/im[]`, no `int()` truncation → identical passthrough.

Ruled out: the buffer mechanism (3 structures), the twiddle ROM (mem_init `.mem` verified correct
`0x7FFF`), `int()` truncation, the bank index. The RTL *contains* the multipliers (1703 `legup_mult`),
so the twiddle multiply is synthesized — its result just never reaches the butterfly store. RTL cosim
was blocked (the `shls cosim` C-testbench wrapper segfaults `0xC0000005` regardless of code), so it
could only be characterised via ~40-min silicon rebuilds.

**Phase 2 — CPU FFT as the interim path.** The FFT moved to the MSS U54 (`src/sar/sar_fft.c`), turning
FFT iteration into a ~1.5-min reflash instead of a 40-min fabric rebuild. Its enduring lesson is the
BFP one below.

**Phase 3 — CURRENT: fabric CoreFFT.** The shipping path is the hard-IP **CoreFFT** streaming chain
(`fft_feeder → gearbox → CoreFFT → fft_unloader`), *not* HLS and *not* the CPU. It is selected at
runtime by `SAR_FFTMODE` @ `0xB0059110` = 1, which is what the pipeline runs with; mode 0 is the
retained legacy CPU path. The fabric chain is phase-exact (0.0° spread @ 256 and 8192) and
value-equals the CPU FFT at corr 0.9999.

> Any statement that "the FFT runs on the MSS U54 CPU" describes Phase 2 and is historical.
> `sar_fft.c` is still in the tree as the mode-0 fallback.

### CPU FFT design lesson (`sar_fft.c`, mode-0 fallback)
- Plain-C radix-2 DIT 8192-pt FFT with **L1-BFP scaling**: full-precision `int32` accumulation
  (int64 twiddle multiply, no per-stage `>>1`) + ONE global block exponent (`out_shift` from the
  max-row L1 norm) applied at the output.
- The first version used per-stage `>>1` (classic 1/N). That truncated the small AC bins to zero over
  13 stages → a DC-only image, corr ~0. **Lesson: fixed-point FFT dynamic range must be managed with a
  block exponent, not per-stage truncation.** This is why CoreFFT is run in its BFP mode.
- Precomputed twiddle header (`sar_fft_twiddle.h`) — `nano.specs` doesn't link `cos/sin/lround`, so no
  runtime trig. Bit-reversal is computed at init.

## Latency roadmap

88.1 s is a bring-up baseline, not optimised. Levers in measured-ROI order. The ordering changed on
2026-07-20: with resample down to 29.2 s, **detect (20.6 s, 23%) is now the largest structural
target** and the only stage still running on the CPU. The FFTs are already on fabric and are not a
lever. Per-stage breakdown: [`SAR_ARCHITECTURE_REPORT.md`](SAR_ARCHITECTURE_REPORT.md) §5.

**1. Detect — 20.6 s, and it is on the CPU.**
The fabric detect kernel is bypassed because SmartHLS mis-synthesised its sign extension
(`(int16_t)(x>>16)` read unsigned → ~50% saturation); the shipping path is a correct-signed CPU
detect selected by `detect_mode` @`0xB0059118`. Two routes: fix or replace the fabric detect (largest
win, needs a rebuild and a value-gate), or split the CPU detect across the 4 U54 harts (firmware-only,
rows are independent, no bitstream risk). The multi-hart split is the best effort-to-payoff ratio
available today.

**2. Resample fabric-kernel interconnect — 29.2 s, still the single largest stage.**
Measured on-silicon mcycle profiling of the azimuth pass (counters in `resample_2pass`, JTAG-read
@`0xB0059120`) gives the per-line split: kernel-wait 78% / coeff-compute 20% / flush 2%. The CPU
spends 78% of resample spinning in `sar_k_wait` for the fabric gather kernel, and the coeff compute is
already double-buffered behind it. Consequence: *coefficient* optimisations (multi-hart coeff split,
reciprocal-hoist, fabric coeff-gen, CORDIC) are dead by Amdahl.

(That split describes the current low-flush build. It did *not* describe the per-line-flush build it
was once quoted against — see "Correcting the record" below before citing it.)

Root cause (pass-1 probe + SmartHLS report): pass-1 (reads ~540) vs pass-2 (reads 8193) kernel-wait/line
= 1.69M vs 2.01M cyc = only 1.19× despite 15× more reads → read is ~1.3% of the time, so it is **not**
read-bound. Cost is per-output. The gather loop was scheduled II=2 (single-read-port `resample_buf`
serialising `buf[j]`+`buf[j+1]`) with in/idx/wq/out **sharing one `m_axi` port**.

- *Done (banked ~2.3×):* kernel redesign — stage idx+wq into LSRAM, cyclic-partition `buf`. Gather loop
  II 2→1; fabric kernel ~4× (tw 16.4G→4.2G); azimuth resample ~28→~12 s. Correlation held at 0.9923.
- *Ruled out by measurement:* AXI `max_burst_len` 64→256 gave **zero** silicon gain (tw 4.17G→4.19G).
  Not burst-length-bound.
- *Remaining lever:* the single shared `m_axi` port still serialises read+write at DDR latency
  (silicon is ~3.4× off the II=1 schedule). Fix is interconnect-level — separate AXI IDs/ports so
  read and write don't stall each other, more outstanding transactions, or dual-FIC. Needs a bitstream
  rebuild; value-verify on silicon.

**3. Coherent fabric path.**
A cache-coherent fabric-master configuration would eliminate the remaining pipeline flushes. Now
largely priced out: the coefficient flush that motivated it has already been removed in firmware (see
below), and what remains is a handful of once-per-stage flushes, not a per-line cost. Note the
mechanism is the DDR address alias a fabric master drives (cached `0x8000_0000` vs non-cached
`0xC000_0000`), not the FIC index — verify against the MSS User Guide before building.

**4. Corner-turn (7.3 s) and window (6.0 s).** Small absolute costs; not worth a rebuild alone. Note
that fusing the window into the resample gather was attempted and is SmartHLS-infeasible — see
[`SMARTHLS_ANTIPATTERNS.md`](SMARTHLS_ANTIPATTERNS.md).

**Recommended next step:** multi-hart CPU detect (lever 1) — the largest firmware-only win, no
bitstream risk.

### Banked: targeted coefficient-bank flush (2026-07-20)

`resample_2pass()` published its coefficient banks with the HAL's `flush_l2_cache()`, a way-by-way
walk that reads 131 KiB from the L2 zero device for each of 16 ways (~268k dependent volatile loads)
— evicting the whole 2 MiB L2 to publish 48 KiB, once per line. Replaced with
`flush_coef_bank_to_ddr()`, which writes only the covering lines to the CCACHE `FLUSH64` register
(~768 stores).

Measured: resample 53.6 → 29.2 s, pipeline 110.8 → 88.1 s, output bits unchanged (ROI crc
`0xd596c9eb` identical to the previous build). Removing 13,826 flushes saved 24.4 s = 1.76 ms per
flush, which matches the ~1.6 ms the way-walk mechanism predicts.

> The bank is not 48 KiB contiguous: `idx` is Np·4 B at +0x0000 and `wq` is Np·2 B at +0x10000, with a
> hole between. Flushing one 48 KiB run from the bank base covers `idx` plus half the hole and misses
> `wq` entirely → the kernel gathers with stale weights → a still-focused but subtly wrong image that
> a correlation check would likely not catch. Flush the two ranges separately.

**Correcting the record on "flush is 2%".** The 78/20/2 split above is accurate for a *low-flush*
build — it was profiled while an experimental per-chunk flush (16× fewer flushes) was active, and it
describes the current build well (29.2 s ≈ 22.8 s kernel-wait + 5.8 s coeff + 0.6 s flush). What it
never described was the build that actually shipped, which had reverted to per-line flushes when the
chunking experiment was rolled back. The number outlived the code it was measured on, and was then
cited for eight days as a reason not to pursue the flush. Profile the shipping path, not a branch.

## Open items (image is correct regardless)
- **~50% OUT saturation at 65535.** Traced to the detect path (`SAR_REG_BFP_SHIFT` @`0x6000001C`,
  r/w in `sar_accel_driver.c`), NOT the FFT — raising FFT out_shift headroom self-cancels across the
  two passes. De-saturate by lowering that register from firmware. Cosmetic — correlation is measured
  on the unsaturated pixels.
- Temporary mcycle profiling counters (`tc`/`tw`/`tf` @`0xB0059120`) remain in `sar_sequencer.c` and in
  the programmed eNVM firmware. Numerically inert; strip before a clean ship.

## HLS trust harness & batch-confidence

SmartHLS is treated as an untrusted, behavioural-only tool (documented record: twiddle drop, detect
sign-extension, II=2→21, the window-fusion miscompiles). The harness constrains its inputs, gates its
outputs, and collects the report-vs-silicon statistics it cannot model. Load the `hls-trust-harness`
skill for the full flow; the pieces:

- **Gate 0 — anti-pattern pre-screen:** `python mpfs/host/hls_antipattern_lint.py` checks source
  against the living catalog [`SMARTHLS_ANTIPATTERNS.md`](SMARTHLS_ANTIPATTERNS.md).
- **Gate 1 — II report gate:** `python mpfs/host/hls_report_lint.py` fails the build if SmartHLS
  scheduled a worse II than the source pragma requested; `--selftest` proves the FAIL path.
- **Class-B ledger:** `docs/fpga/hls_silicon_stats.jsonl` (+ rollup
  [`HLS_SILICON_STATS.md`](HLS_SILICON_STATS.md)), written with `python mpfs/host/hls_stats.py` — six
  phenomena SmartHLS can't see: `axi_ii_lie`, `ddr_latency`, `l2_coherency`, `fic_axi_id`, `es_errata`
  (ER0219), `corefft_rearm`.

**Batch-confidence protocol.** A silicon commit stays to one logical change UNLESS every batched change
is (a) proven additive by the validated cost model (no Amdahl reordering among the set), (b) value-gated
board-free (Gates 0–2 + phase-exact check), and (c) runtime-toggleable with per-stage counters so one
bitstream yields N independent measurements and a regression is still bisectable. Absent all three,
sequence the changes and measure between.

## Key references
- [`../SAR_DESIGN.md`](../SAR_DESIGN.md) — the detailed current design: dataflow, buffer map,
  fixed-point contracts, eMMC layout, register semantics, diagrams.
- [`SAR_ARCHITECTURE_REPORT.md`](SAR_ARCHITECTURE_REPORT.md) §5 — measured per-stage timing (numeric
  source of truth).
- [`SILICON_ISO_TEST_RUNBOOK.md`](SILICON_ISO_TEST_RUNBOOK.md) — the JTAG single-kernel isolation
  harness, coherent-DDR-read technique, DDR/control map, FlashPro6 hygiene. **Read before any silicon debug.**
- [`SAR_PIPELINE_PROCESS.md`](SAR_PIPELINE_PROCESS.md) — pipeline math/orchestration.
- `mpfs/host/correlate_cpufft.py` — image correlation (8-dihedral orientation search).
- Firmware: `src/sar/sar_sequencer.c`, `sar_fft.{c,h}` (mode-0 fallback), `sar_emmc.c`.
