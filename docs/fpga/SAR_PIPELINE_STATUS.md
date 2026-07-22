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
- `sar_form_image` (PIPE mailbox cmd) returns `SAR_SEQ_OK` in **79.79 s** (2026-07-21,
  window-fused-feeder build), with `fft_mode=1` (fabric CoreFFT) confirmed at runtime. Output
  image byte-identical to every prior build back to 110.8 s — top-left 1024² ROI crc `0xd596c9eb`.
  Reproducible: two consecutive runs at 79.794 s / 79.683 s (0.14% spread), stage-for-stage.
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

58.12 s is the current baseline (2026-07-21). Window and detect are both fused into fabric; no CPU
stage remains in the datapath. **Resample is now the target by a wide margin: 26.92 s, 46.3%.**
Per-stage breakdown: [`SAR_ARCHITECTURE_REPORT.md`](SAR_ARCHITECTURE_REPORT.md) §5. FFT axis naming:
[`../SAR_DESIGN.md`](../SAR_DESIGN.md) §2.3 (the code labels are swapped vs the true axis).

**Priority order (set 2026-07-22):**

**1. Increase the resample gather THROUGHPUT.** The kernel schedules at II=1 (verified) yet runs
~880 µs/line against a 361 µs schedule — 2.44× AXI stall on a correct schedule (`axi_ii_lie`). The
cause (short bursts vs long inter-burst gaps — opposite fixes) is not yet observable; the FIC_0
monitor (ARLEN histogram + busy/elapsed/max-gap counters, built into the 2026-07-22 bitstream, reg
base `0x6000_6000`) is the measurement that decides the fix. **Do this measurement first** — every
downstream resample decision depends on it. Firmware: clear-arm-read the monitor around one line.

**2. Fuse the AZIMUTH RESAMPLE into FFT-1 (the azimuth-axis FFT).** FFT-1 already has the 2-D window
fused into its feeder (`fft_feeder_v.v`), and the azimuth resample pass feeds FFT-1 directly with no
corner-turn between them (see SAR_DESIGN §2.3). So the azimuth gather can be folded into the same
feeder the window uses, deleting its separate DDR read/write pass — the exact pattern that deleted
the window and detect passes. Board-free RTL + TB first; value-gated by an A/B, since it changes the
fixed-point path (CRC gate no longer applies).

**3. Parallel fabric instances for resample and the FFT chains.** Rows are independent and FIC_0 has
~10× bandwidth headroom. This was blocked by `sar_axi_idconv` mis-routing concurrent masters'
responses; that is FIXED (2026-07-22, forwards `master_number`; silicon-confirmed inert with the
current sequential firmware, so it is ready for concurrent use). Needs per-instance instantiation +
wiring + a build; each added chain splits nothing because the bus is idle ~76% of the time.

**4. Increase the clock frequency.** CLK is the binding constraint (~110 MHz ceiling; SLOWCLK/CoreFFT
has +113 ns slack and is not the limiter). The 2026-07-22 register slices already broke the
interconnect combinational critical path (worst OUT0 path moved into a slice register, +7.024 ns), so
the prerequisite is in place. A CLK bump raises SLOWCLK with it (tied CLK/8) and speeds both FFTs;
needs a CCC reconfig + a fresh timing-gate pass. Lowest priority because it is the most uncertain and
the register-slice groundwork must be proven on silicon first.

**Historical note:** an earlier revision of this roadmap led with "multi-hart CPU detect" as the top
lever. Detect is now fused into fabric (0.00 s), so that lever is gone.

**2. Resample fabric-kernel interconnect — 28.53 s, still the single largest stage.**
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

#### Geometry analysis (2026-07-20) — what the coefficient structure permits

Measured on real geometry from two scenes: Centerfield as staged (705×540, deci 8) and the NDSU
production CPHD at native 8167×8999. Script logic mirrors `serialize_inputs.interp_coeffs` exactly.

| Scene | Pass | Valid outputs | Non-monotonic lines | Max Δidx |
|---|---|---:|---:|---:|
| Centerfield deci 8 | range | 5.5% | 0 / 705 | 2 |
| Centerfield deci 8 | azimuth | 8.6% | 0 / 8192 | 2 |
| NDSU deci 1 native | range | 70.1% | 0 / 8167 | 2 |
| NDSU deci 1 native | azimuth | 97.1% | 0 / 8999 | 2 |

Three structural facts, each provable from the code and confirmed across 26,063 lines:

1. **`idx` is monotonic non-decreasing.** It comes from `np.searchsorted` of an ascending query grid
   into a monotonic source, so the gather is a sequential scan, not random access. The kernel's
   full-row `buf[RS_IN]` LSRAM staging is therefore unnecessary — a two-element sliding window suffices.
2. **The valid region is a single contiguous interval `[lo,hi]`.** `serialize_inputs` builds the query
   grid as `KRp[:n] = KR` with an out-of-range sentinel beyond, so the pad tail is uniformly invalid;
   and within `[0:n]`, monotonicity means out-of-range can only be a prefix or suffix. Zero lines out
   of 8,897 had more than one valid run. The firmware already knows `lo`/`hi` — they are the first and
   last valid entry of the `idx` it just computed.
3. **Δidx ≤ 2 in every configuration measured.** Since the host decimates every scene to N ≤ 8192 and
   the output grid is 8192, inputs ≤ outputs by construction, so the average Δ is ≤ 1 and excursions
   come only from local non-uniformity in `kr = 2(f0 + j·df)/c · pr`. A 2-bit field with an escape code
   is therefore bounded by construction, not fitted to these two scenes.

Implied work per line (ideal cycles, current kernel = 8193 in-stage + 8192 idx + 8192 wq + 8192 gather
= 32,769; silicon measures ~103,000, so ~3.1× is exposed DDR latency on the shared port):

| Change | Saves | Basis |
|---|---:|---|
| Stream the input (monotonic) — delete `buf[RS_IN]` staging | 8,193 | fact 1 |
| Delta-encode `idx`, 2-bit + escape | ~7,900 | fact 3 |
| Beat-rate `wq` staging (int16 over a 64-bit bus) | ~6,100 | bus width |
| Bound the gather to `[lo,hi]`, zero the tail | ~3,300 | fact 2, ~40% of iterations |
| `max_outstanding_reads/writes` on the initiators | part of the 3.1× gap | latency, not bandwidth (39 MB/s peak) |

> **`max_outstanding` was tried on silicon 2026-07-20 and gave ZERO gain. Do not retry it.**
> The kernel's four `axi_initiator` pragmas set only `num_elements` and `max_burst_len`; adding
> `max_outstanding_reads(8)` / `max_outstanding_writes(2)` (SmartHLS's own values, from its
> `axi_initiator_optimization` example) provably reached hardware — the regenerated RTL shows the AXI
> read-address FIFO going from **depth 1 to 8** and `r_data` 256 → 2048, so the kernel really had been
> limited to one read burst in flight. It made no difference: resample 29.25 s against a 29.19/29.20 s
> baseline, pipeline 88.12 s against 88.04/88.11 s, image bit-identical (ROI crc `0xd596c9eb`).
> Cost +5 LSRAM blocks (15.02 → 15.64%), timing still MET (setup +6.545 ns, hold +0.049 ns).
>
> **What that rules out.** Two AXI request-management knobs have now been falsified by measurement:
> `max_burst_len` 64→256 (2026-07-12, zero gain) and outstanding depth 1→8 (2026-07-20, zero gain).
> The ~3.1× gap between the kernel's silicon time and its scheduled cycle count is therefore NOT in
> AXI request scheduling — it is internal to the kernel's dataflow. That promotes the streaming
> restructure (deleting the `buf[RS_IN]` staging that monotonicity proves unnecessary) from
> "nice alongside AXI tuning" to the actual lever.
>
> **Method lesson.** Both attempts inferred a bottleneck from arithmetic (measured ÷ ideal, plus a
> bandwidth estimate) and spent a ~40 min build to test it. The project already owns the right
> instrument: the Class-B ledger's `axi_ii_lie` metric derives EFFECTIVE II from an iso-test's
> busy-cycles ÷ elements. Scheduled II=1 against ~3.1× on silicon is exactly that phenomenon.
> Measure effective II and localise the stall BEFORE the next resample bitstream.

Correction to earlier guidance in this document's history: with the **pointer-based** `axi_initiator`
pragma there is no AXI-ID, bundle or port-separation option — the pragma manual exposes none — which
is why `in`/`idx`/`wq`/`out` share one port and read/write serialise. Do not plan around a pragma the
tool does not have.

Read/write concurrency IS reachable, but only by dropping to the **explicit AXI API**
(`hls/axi_interface.hpp`). Microchip's own `axi_initiator` example issues `axi_m_read_req` and
`axi_m_write_req` up front and then interleaves `axi_m_read_data` / `axi_m_write_data` inside a single
`#pragma HLS loop pipeline` — genuine concurrent read and write on one initiator, which the pointer API
cannot express. That is the structural fix for the 3.1× latency gap, at the cost of hand-managing the
AXI handshake and burst boundaries. Try `max_outstanding_*` first; escalate to the explicit API only if
it falls short.

Ideal falls 32,769 → ~7,200 cycles/line. **Sequence matters:** the span bound is worth only ~10% today
because the gather is a quarter of a staging-dominated budget, but ~31% once staging is gone. Do the
streaming restructure first and the span bound rides along.

Projected: resample 29.2 → ~7 s, at which point coefficient generation (~5.8 s single-hart) is the
floor and the multi-hart coefficient split — currently dead by Amdahl — becomes the next lever, taking
it to ~4 s. Note this is an Amdahl reversal: the moment the kernel gets fast, the coefficient work that
is presently hidden behind it becomes dominant. Plan the two together.

Preferred over replicating N kernel instances: parallel instances add DDR masters through FIC_0, which
has a documented 4-bit AXI-ID truncation history (see the ID_FIX/ID_RESTORE work). The single-instance
restructure captures most of the win with no new masters, and by cutting per-instance LSRAM from ~80 KB
to ~16 KB it makes instance replication cheap later if ~4 s is still not enough.

Every item needs a value-level iso-test, not a correlation check — the gather loop is precisely where
SmartHLS has miscompiled twice before (see [`SMARTHLS_ANTIPATTERNS.md`](SMARTHLS_ANTIPATTERNS.md)).
The delta encoding is the riskiest (new format + decode in the hot loop); the span bound is the safest.

**3. Coherent fabric path.**
A cache-coherent fabric-master configuration would eliminate the remaining pipeline flushes. Now
largely priced out: the coefficient flush that motivated it has already been removed in firmware (see
below), and what remains is a handful of once-per-stage flushes, not a per-line cost. Note the
mechanism is the DDR address alias a fabric master drives (cached `0x8000_0000` vs non-cached
`0xC000_0000`), not the FIC index — verify against the MSS User Guide before building.

**4. Corner-turn (7.32 s). Window is DONE — 0.00 s.** The window pass was fused into the range-FFT
feeder on 2026-07-21 (hand-written Verilog in `fft_feeder_v.v`), deleting a 512 MB-read +
512 MB-write full-frame pass for 6.0 s with bit-identical output. Note the earlier attempt to fuse
it into the resample gather is SmartHLS-infeasible and must not be retried — see
[`SMARTHLS_ANTIPATTERNS.md`](SMARTHLS_ANTIPATTERNS.md). The Verilog-feeder route is the one that
works. Corner-turn remains a small absolute cost, not worth a rebuild alone.

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
