# SAR Guide — algorithm and the software-to-fabric journey

> **New here?** Every acronym, magic value and stage nickname in this project is defined in [`docs/GLOSSARY.md`](GLOSSARY.md).

This is the SAR-specific companion to `docs/USER_GUIDE.md`. That document covers board bring-up,
build, run and verify procedures. This document covers a different question: **what** the processor
computes, and **how** it got from a laptop Python script to a PolarFire SoC fabric datapath — so an
engineer can extend or re-target it. No build/program/run instructions are repeated here.

---

## Part 1: Python reference implementation

### 1.1 Umbra CPHD input data

The pipeline's input is **Umbra CPHD** — Compensated Phase History Data, the SAR equivalent of a
camera RAW file: the radar's unfocused complex return recorded pulse-by-pulse across the synthetic
aperture, plus the geometry needed to focus it. "Compensated" means platform-motion phase has already
been removed to a fixed Stabilization Reference Point (SRP), so an image-formation algorithm can
consume it directly. It is the NGA CPHD 1.0 standard; Umbra distributes it as open data.

Per the `umbra-cphd-data` skill, the practical facts an implementer needs:

- Public S3 layout: `s3://umbra-open-data-catalog/sar-data/tasks/<task>/<uuid>/<timestamp>_UMBRA-NN/`,
  each capture shipping `CPHD.cphd` + `GEC.tif` (reference product) + `SICD.nitf` + `SIDD.nitf` +
  `METADATA.json`. A 2026-07 catalog sample (4,072 files, ~34 TB) was uniformly single-channel,
  spotlight, X-band, **format CF8** — complex float32 I/Q, 8 bytes/sample, no integer/compressed
  variants.
- **Array dimensions live in the CPHD file's own XML header, not in `METADATA.json`** (which holds
  only collect geometry): `<Data><Channel><NumVectors>` (pulses / slow-time) and `<NumSamples>`
  (range-frequency bins / fast-time), readable with a single ~20 KB HTTP range GET.
- Typical sizes across a ~477-file catalog sample: NumSamples/vector median 22,499 (p95 143,748, max
  258,048); NumVectors median 18,632 (max 203,449) — this is what bounds range-FFT length and
  per-vector buffer depth, and is why the fabric grids to a fixed 8192² frame with the capture
  decimated down to it.

`form_image_pfa.py`'s own docstring records the verified facts for the project's primary test
collect (Centerfield, Utah): **5,634 pulses × 4,319 samples, CF8, `DomainType=FX`, `SGN=-1`, fc 9.60
GHz (λ 3.1 cm), BW 113.6 MHz (range res ≈1.32 m), scene ±2000 m**, image-plane axes given by
`ReferenceSurface.Planar` `uIAX`/`uIAY`. A second scene (Strait of Hormuz ship-detection, UMBRA-04,
7,586 × 8,191 pulses × samples, ~0.92 m × 0.91 m resolution) is used elsewhere in the project as a
higher-dynamic-range stress case.

### 1.2 The Polar Format Algorithm pipeline (`src/form_image_pfa.py`)

In the FX (frequency) domain, CPHD phase history is the 2-D Fourier transform of the scene
reflectivity sampled on a **polar** grid (radius = range frequency, angle = look aspect). The Polar
Format Algorithm (PFA) resamples that polar grid onto a Cartesian k-space grid so a single separable
2-D FFT focuses it — an O(N log N) method, not O(pixels × pulses) like backprojection, so it forms the
*full* scene cheaply.

The script implements two modes (`MODE` config knob):

- **`"quicklook"`** — window the raw signal and take a single 2-D FFT, treating the polar grid as
  Cartesian. ~7 s, mild geometric warp. Implemented in `quicklook()`.
- **`"pfa"`** — the real two-pass keystone resample, geometrically correct over the whole scene. ~12–15
  s. Implemented in `resample_kspace()` + `focus()`, chained by `pfa()`.

The PFA pipeline, stage by stage (all in `form_image_pfa.py`):

1. **Geometry setup** — per-pulse antenna phase centre (`0.5*(TxPos+RcvPos)`), unit look direction to
   the SRP, projected into the image plane via `uIAX`/`uIAY` to get per-pulse `(ax, ay)`.
2. **Keystone / polar-format resample (`resample_kspace`)** — two interpolation passes:
   - *Pass 1 (range):* each pulse's samples, whose true range-wavenumber `kr = |k|·pr` differs pulse
     to pulse, are resampled onto one common uniform grid `KR` via 1-D linear interpolation
     (`np.interp`).
   - *Pass 2 (azimuth/cross):* per range bin, the pulses are resampled across a uniform cross-range
     grid `KC`, using `tan_phi = pc/pr` as the per-pulse coordinate.
3. **2-D window** — a separable Hamming taper (`hamming2d`, outer product of two 1-D Hamming windows)
   applied to the resampled k-space, when `WINDOW` is set.
4. **Zero-pad + 2-D FFT (`focus`)** — the windowed k-space is zero-padded to the next power-of-2 grid
   (`to_pow2`), matching the radix-2 grid the FPGA fabric forms on, then `transform2d` runs a centred
   2-D FFT honoring the CPHD `SGN` convention (`np.fft.fft2` for `SGN<0`).
5. **Detect + geocode (`save_detected_geotiff`)** — magnitude `|img|`, an ECEF→UTM affine derived from
   the scene-centre pixel and per-pixel ground displacement vectors (`geo["dr"]`/`geo["dc"]`,
   `dhat`/`chat`), written as a GeoTIFF.

**Running it:** `python src/form_image_pfa.py`. All knobs are read from `config.yaml` (or the file
pointed to by `SAR_CONFIG`), with these defaults in the script: `MODE` (`"pfa"` default),
`DECIMATE_PULSE` / `DECIMATE_SAMPLE` (integer decimation of pulses/samples for faster/coarser runs),
`WINDOW` (Hamming taper on/off), `ESTIMATE_ONLY` (print a measured-on-this-laptop RAM/time estimate
and exit), `SAVE_GEOTIFF`, `GEO_EPSG` (`"auto"` derives the UTM zone from the scene), `FLIP_COL` /
`FLIP_ROW` (orientation convention verified against the GEC reference product). The script downloads
the CPHD from the Umbra S3 bucket on first use and caches it under `data/`.

### 1.3 The other Python-side golden and emulation files

| File | Role |
|---|---|
| `src/fixedpoint.py` | NumPy fixed-point / block-floating-point (BFP) **emulator** of the FPGA datapath: quantizes signal and twiddles to N-bit fixed point (`fit_scale`/`quant`, floor-truncating like the fabric's arithmetic shift) and runs a radix-2 BFP FFT (`fft1d_bfp`) that rescales per stage. Used to size datapath bit widths and quantify information loss vs. the float reference. Runnable standalone as the quantization study (`python src/fixedpoint.py`). |
| `src/form_image_pfa_fixed.py` | The fixed-point twin of the float reference. **Imports** `form_image_pfa` for the resample/geocode/pow2-grid path so the two pipelines cannot drift, and swaps in `fixedpoint.py`'s BFP FFT + fixed detect for the offloaded part — the two differ *only* in FFT/detect arithmetic. Default `NBITS=16` (datapath), `NBITS_TW=18` (twiddle), matching the CoreFFT config. Produces a float32 GeoTIFF pixel-aligned with the float reference's, for direct differencing. |
| `src/compare_float_fixed.py` | Diffs the float and fixed GeoTIFFs, confirms geo-alignment, and reports SNR, ENOB, NRMSE, Pearson correlation, peak error, bias and usable dynamic range — the quantitative fixed-point-loss study (a 3-panel diff PNG + JSON). |
| `mpfs/host/silicon_emulator.py` | A **bit-accurate mirror of the on-silicon datapath end-to-end**, matching `src/sar/sar_sequencer.c` + the HLS kernels + CoreFFT's in-place BFP exactly: int16 quantize → fixed-point 2-pass keystone resample (int16 gather, `>>15` truncating lerp) → fixed-point 2-D Hamming window → adaptive BFP FFT (models CoreFFT's per-row `SCALE_EXP` + firmware's global renormalize) → corner-turn → adaptive BFP azimuth FFT → fixed (signed) detect. Predicts exactly what the board's `sar_form_image` produces, for both the Centerfield and ship scenes. |
| `mpfs/host/emulate_fabric.py` | A NumPy emulation of the **exact fabric/MSS orchestration** — not BFP numeric fidelity — validating per-line keystone resample with MSS-quantized `idx`/`wq`, pulse reorder via `inv_order`, corner-turn transpose between passes, and window/detect layout, reusing the float reference's FFT/detect so only orchestration is under test. This is the spec the C sequencer and HLS kernels must match, especially output orientation. |

---

## Part 2: Staged approach — from Python to fabric

The project moved through five real stages, each gated by comparison against the previous stage's
output before the next was trusted: **float Python → fixed-point emulation → per-stage HLS
kernel/cosim (Milestone 1) → fabric RTL integration (Milestone 2) → silicon validation (Milestone
3)**.

### Stage 0 — float Python reference

`form_image_pfa.py` (Part 1) is the golden oracle for every later stage: a geometrically correct,
geocoded GeoTIFF validated against Umbra's own GEC reference product.

### Stage 1 — fixed-point / BFP emulation and bit-width sizing

Before committing any RTL, the project ran the quantization study in `fixedpoint.py` /
`form_image_pfa_fixed.py` / `compare_float_fixed.py` to decide the datapath word widths.

Measured on the ship scene, 16-bit BFP fixed point vs. float:

| Metric | Value |
|---|---:|
| SNR (fixed vs float) | 29.3 dB |
| ENOB | 4.57 bits |
| NRMSE | 0.034 |
| Pearson correlation | 0.9992 |
| Max \|error\| (normalized) | 0.013 |
| Usable dynamic range — float / fixed | 57.7 / 53.2 dB |
| Dynamic-range loss | 4.5 dB |

The bit-growth analysis captured the block-exponent trajectory per radix-2 stage of the 8192-pt FFT:
range pass **−6 → 3 (+9 guard bits)** over 13 stages, azimuth pass **3 → 13 (+10 guard bits)**. A
*linear* (non-BFP) transform would need a 42-bit datapath (16 + 13 + 13) to never overflow; BFP holds
the mantissa at 16 bits and tracks the measured +9/+10-bit swing with a 5-bit exponent. This drove the
recommended (and shipped) datapath: **16-bit mantissa, 18-bit twiddle, 48-bit accumulator, BFP
arithmetic-shift (floor) after every stage** — matching Microchip CoreFFT's own BFP mode.

### Stage 2 — per-stage HLS kernel + CoreFFT cosim (Milestone 1)

Milestone 1 (HLS kernel + CoreFFT cosim) settled the decision to use the **Microchip CoreFFT hard IP**, not the
hand-written `fft1d.cpp` template, for the FFT itself. Confirmed CoreFFT configuration (in-place
Radix-2, natural-order in/out matching the golden's convention):

| Parameter | Value | Why |
|---|---|---|
| `POINTS` | 8192 | the padded grid; powers of 2 32…16384 supported |
| `WIDTH` | 16 | shared data/twiddle bit width, matches the 16-bit datapath from Stage 1 |
| `SCALE` | 0 | conditional BFP — downscale a stage only on real overflow |
| `SCALE_EXP_ON` | 1 | exports the block exponent on `SCALE_EXP` (`FFT Result = DATAO · 2^SCALE_EXP`) |

Golden vectors came from `fft_golden.py` (five stimulus cases: impulse/dc/tone/twotone/random). The
gate was **scale-invariant** on purpose — CoreFFT's conditional BFP shifts only on overflow, so its
mantissa/exponent legitimately differ from the emulator's unconditional per-stage normalize — passing
at `corr ≥ 0.9999` and `nrmse ≤ 0.01`.

### Stage 3 — fabric RTL integration (Milestone 2)

Milestone 2 (fabric RTL integration) covered assembling the full datapath: resample → window →
range-FFT → **corner-turn** → azimuth-FFT → detect, closing timing, and bringing it up over JTAG.

- **Buffer ping-pong**: SIG (256 MB) ↔ SCRATCH (256 MB) + OUT (128 MB), so an in-place FFT never feeds
  and drains the same page, and PASS1's output becomes PASS2's input via the corner-turn without a
  third 256 MB buffer.
- **Corner-turn burst analysis** — the make-or-break piece, since the 256 MB frame is ~100× larger
  than on-chip SRAM: tile size `T` sets the contiguous DDR burst per tile-row (`T × 4 bytes`).
  `T=128` (64 KB tile buffer, 512 B bursts) was the recommended starting point; `T=256` uses a
  disproportionate LSRAM share for diminishing burst gain.
- **Libero design (as first assembled)**: 5 HLS kernels (corner-turn, window, detect, resample,
  fft-feeder) + CoreFFT 8.1.100 + `CoreAXI4DMAController` 2.2.107, over two `CoreAXI4Interconnect`
  crossbars (data 6-master/1-slave, control 1-master/6-slave) to the MSS via FIC.
- Integration path chosen: **Option A**, grafting the accelerator onto the Icicle Kit reference
  design's exposed `FIC_0` boundary ports, rather than building the whole SoC from scratch — fewer
  steps since `libero_sar` already held every IP component.

### Stage 4 — silicon validation (Milestone 3) and the timing-closure detour

Bring-up found two real silicon bugs before the pipeline ran at all:

1. **AXI ID-width truncation** at `FIC_0_AXI4_S` — fixed with `sar_axi_idconv.v` (ID stash/restore);
   the M2 diagnostic tag `0x30` went from HANG to PASS with `SCRATCH` correctly written.
2. **DMA control-slave hang** — the crossbar's slave-5 was `TARGET_TYPE=0` (full AXI4) feeding the
   DMA's reduced AXI4-Lite control port through a 64→32 downsizer, black-holing reads; fixed by
   setting `TARGET5_TYPE=1` (AXI4-Lite) with an 11-bit address slice.

The full PFA pipeline then appeared to hang at the range-FFT stage. The real root cause was **not**
logic: P&R at 125 MHz left **25,847 of 315,348 pins with negative slack** (worst −3.7 ns), all on the
single 125 MHz fabric clock (CoreFFT itself had zero violations) — a timing-failing bitstream that
Libero programmed silently. The fix was lowering the fabric CCC OUT0 125 → 62.5 MHz (and CoreFFT's
`SLOWCLK` 15.625 → 7.8125 MHz, respecting `SLOWCLK ≤ CLK/8`); headless P&R of the 62.5 MHz design then
closed timing completely — **0 setup violations of 315,349 pins, 0 hold**. This is the origin of the
project's standing rule to verify P&R timing closure before treating any on-silicon misbehaviour as a
logic bug (see CLAUDE.md engineering practices). The pipeline was later re-validated end-to-end on
silicon (Part 3), and the fabric clock was subsequently raised again to 100 MHz once the timing margin
and the actual bottleneck were both understood.

### The FFT's own staged journey — and the concrete lesson about SmartHLS

This is the most-misread part of the design, because
the FFT alone went through three engines, not one:

**Phase 1 — the HLS FFT was unsynthesizable.** The HLS `K_FFT` kernel
(`hls_fft/hls_fft.hpp::fft_in_place_bfp`) **dropped the twiddle term in the generated RTL** on
SmartHLS 2025.2, collapsing to an identity/passthrough on silicon — while every C-simulation passed at
corr 0.9999. This was proven across **three independent FFT structures**, each rebuilt and tested on
silicon: an `hls::DoubleBuffer` ping-pong (const-1000 → flat passthrough), an explicit
`static buf[2][SIZE<<1]` ping-pong (identical passthrough), and a single in-place `re[]/im[]` array
with no `int()` truncation (identical passthrough). The buffer mechanism, the twiddle ROM (verified
correct `0x7FFF` in the `.mem` init), `int()` truncation, and the bank index were all individually
ruled out. The generated RTL *did* contain the multiplier logic (1,703 `legup_mult` instances) — the
twiddle multiply was synthesized, its result just never reached the butterfly store. RTL cosim was
blocked entirely (the `shls cosim` C-testbench wrapper segfaulted `0xC0000005` regardless of source
code), so this could only be characterised through ~40-minute silicon rebuilds.

**Phase 2 — CPU FFT as the interim path.** The FFT moved to the MSS U54 (`src/sar/sar_fft.c`), turning
FFT iteration into a ~1.5-minute reflash instead of a 40-minute fabric rebuild. Its own history
carries the BFP lesson directly: the first version used classic per-stage `>>1` scaling, which
truncated the small AC bins to zero over 13 stages and collapsed the image to DC-only (corr ~0). Fixed
by switching to full-precision `int32` accumulation with **one global block exponent** applied only at
the output — the same block-floating-point discipline as CoreFFT's own BFP mode, learned the hard way
before CoreFFT was back in the loop.

**Phase 3 — current: fabric CoreFFT.** The shipping FFT is the hard-IP streaming chain
(`fft_feeder → gearbox → CoreFFT → fft_unloader`), selected at runtime by `SAR_FFTMODE`
@`0xB0059110`=1 (mode 0 is the retained CPU fallback). It is phase-exact (0.0° spread at 256 and 8192
points) and value-equals the CPU FFT at corr 0.9999.

### Stage engine assignment, and where SmartHLS wasn't viable

| Stage | Engine | SmartHLS-generated? |
|---|---|---|
| Resample (keystone gather) | `K_RESAMPLE` HLS mem→mem kernel | **Yes** — works |
| Corner-turn (transpose) | `K_CORNER_TURN` HLS mem→mem kernel | **Yes** — works |
| Window (2-D Hamming) | hand-written Verilog, fused into `fft_feeder_v.v` | **No.** A standalone HLS `K_WINDOW` kernel exists in fabric but is never armed. Fusing the window into the *resample* HLS kernel was tried twice — bit-exact and II=1 in both `shls sw`/`hw` simulation — and hit two distinct SmartHLS miscompiles on real silicon. |
| Range/azimuth FFT core | Microchip **CoreFFT** hard IP (DirectCore 8.1.100) | **No — hard IP.** The HLS `fft_in_place_bfp` kernel silently dropped the twiddle term in synthesis (Phase 1 above); CoreFFT was substituted after that failure was proven across three independent HLS structures. |
| FFT feeder / unloader (DDR↔stream) | hand-written Verilog | **No.** SmartHLS synthesizes mem-to-stream and stream-to-mem kernels to dead RTL on this toolchain — not a style choice. |
| Detect (magnitude) | hand-written Verilog, fused into `fft_unloader_v.v` | **No.** The standalone HLS `K_DETECT` kernel mis-synthesized its sign extension — source-correct `(int16_t)(x >> 16)` was read as **unsigned** in the generated RTL, saturating every negative-I pixel to `0xFFFF` (~half the image). Both `shls` cosim and a correlation check passed anyway; only a value-level comparison caught it. |

The pattern across all four SmartHLS failures (FFT twiddle drop, window-fusion miscompile ×2,
feeder/unloader dead RTL, detect sign-extension) is consistent: SmartHLS was trustworthy for
straightforward mem-to-mem, regular-access kernels (resample, corner-turn), and untrustworthy —
sometimes passing every board-free gate while wrong on silicon — for anything involving streaming
interfaces, fusion into a hot loop, or FFT-specific structure. The project's response was not to keep
debugging SmartHLS output but to substitute a hard IP (CoreFFT) or hand-written RTL (feeder, unloader,
window, detect) wherever HLS had been shown unsafe, and to gate every future HLS change with the
value-level checks (not correlation) that had actually caught these bugs.

---

## Part 3: Optimized approach — what was actually sped up on fabric, and by how much

Once the full pipeline first ran end-to-end on silicon, a sequence of measured optimizations brought
it from a **110.8 s** baseline down to the current **18.45 s**. Every number below is a real
on-silicon measurement (this section is the project's stated single numeric source of truth).

### 3.1 Chronological before/after

| # | Optimization | Before | After | Δ | Note |
|---|---|---:|---:|---:|---|
| 0 | Resample kernel redesign (gather II 2→1, hoisted window taper) | resample 103.3 s / pipeline — | resample 53.6 s / **pipeline 110.8 s** | — | earliest full-datapath baseline |
| 1 | Targeted coefficient-bank cache flush (`CCACHE FLUSH64`) replacing whole-L2 `flush_l2_cache()` | resample 53.6 s / pipeline 110.8 s | resample 29.2 s / **pipeline 88.1 s** | −24.4 s pipeline | 13,826 whole-L2 flushes removed, ≈1.76 ms/flush |
| 2 | Resample AXI beat packing (`idx`/`wq` read as 64-bit) | resample 29.17 s | resample 28.58 s | −0.59 s | 31% fewer beats bought only 2% — resample is not beat-bound |
| 3 | 2-D Hamming window fused into range-FFT feeder (`fft_feeder_v.v`) | window 6.0 s / pipeline 87.58 s | window 0.00 s / **pipeline 79.79 s** | −7.79 s | FFT passes did not slow down (25.06 vs 25.07 s) |
| 4 | Magnitude detect fused into azimuth-FFT unloader (`fft_unloader_v.v`, `DETMODE=3`) | detect 19.24 s, azimuth-FFT 12.777 s | detect 0.00 s, azimuth-FFT 11.274 s | **pipeline 78.557 → 58.121 s (−20.44 s, −26%)** | azimuth-FFT itself sped up: unloader writes uint16 mag instead of complex int32, halving write traffic |
| 5 | Azimuth resample gather fused into FFT-1 feeder (`SAR_GATHERMODE=1`) | resample 27.19 s | resample 13.46 s | −13.73 s (net −10.13 s after +3.61 s resurfaced in the FFT-1 feeder) | combined with fused detect: **pipeline 58.12 → 48.19 s (−9.93 s, −17%)** |
| 6 | Corner-turn tile size `CT_T` 32 → 128 | each corner-turn 7.68 s | each corner-turn 6.20 s | −1.48 s each | burst 128 B→512 B, throughput 67→82.6 MB/s (×1.23) — latency-bound, not burst-bound; **pipeline 48.19 → 45.26 s (−2.93 s)** |
| 7 | Corner-turn / FFT-2 concurrent overlap (`SAR_OVERLAPMODE=1`) | merged corner-turn+FFT-2 17.57 s | merged corner-turn+FFT-2 12.90 s | −4.67 s | ~75% of the corner-turn hidden under FFT-2; **pipeline 45.62 → 40.91 s (−4.35 s, −9.6%)** |
| 8 | Fabric clock, CCC OUT0 62.5 → 100 MHz | pipeline 40.91 s | pipeline 37.72 s | **−3.19 s (−7.8%)** | only FFT-2's compute scaled with clock; FFT-1 (gather-latency-bound) did not |
| 9 | Multi-hart resample coefficients (`SAR_CWRK_NW=4`) | pipeline 37.72 s | pipeline 32.97 s | **−4.75 s** | coefficient generation, not the fabric, was pacing FFT-1: 1499 → ~508 µs/row across 4 U54 harts |
| 10 | On-fabric azimuth coefficient generator (`sar_coeffgen.v`, `SAR_CGENMODE='CGN1'`) | pipeline 32.88 s | pipeline 31.36 s | **−1.52 s** | ~147 µs/row vs 1499 on one hart. Also deletes 6,144 of a row's 8,961 read beats (68.6%) and the per-row L2 flush — the stage stops being coefficient-paced and becomes FFT-paced |
| 11 | Second CoreFFT chain (`SAR_DUALFFT='DFF2'`, rows split in blocks of `SAR_FFTBLK`=64) | FFT-1 10.351 s / FFT-2 10.694 s | FFT-1 7.313 s / FFT-2 9.792 s | **−4.7 s** | only pays off *because* of step 10: on the CPU coefficient path there is no budget to feed a second chain, so the firmware refuses and records it in `RPROF[11]` |
| 12 | Multi-hart block-exponent renormalize epilogue (`SAR_RWRK_NW=0x52575204`) | pipeline 27.83 s | pipeline 25.14 s | **−2.69 s** | beat its ~1.8 s prediction because it runs in **both** FFT passes, not just FFT-1 |

| 13 | Hand-written corner-turn `corner_turn_v.v` replacing the SmartHLS kernel (full-width `arsize=3'b011` bursts, double-buffered fill/drain) | pipeline 25.16 s | pipeline 18.45 s | **−6.71 s** | biggest single win of the campaign. Costs ~3x the LSRAM (128 vs ~43 blocks). Its FIRST build was bit-WRONG on silicon — see the re-arm bug below |

**Current shipping baseline: 18.45 s** (2026-07-27, 100 MHz), verified bit-exact against the
reference crop CRC `0x319037b2` from a cold start. Correlation vs. golden reference **0.9923** on
the Centerfield scene; output bit-identical across every fusion/overlap/clock configuration tested.

Per stage at that baseline: resample 7.267 s (39.4%) · range-FFT (FFT-1, the **azimuth** transform)
5.788 s · azimuth-FFT (FFT-2, the **range** transform, with corner-turn #2 overlapped into it) 5.396 s.

> **ONE ELOD PER PIPE RUN.** The internal corner-turn transposes SCRATCH → SIG, so a run
> **overwrites its own input**. A second PIPE without reloading the scene processes the previous
> run's intermediate data and returns a wrong, run-dependent CRC. Not corruption, and not specific
> to any configuration — single chain does it identically. This cost a full debugging session
> before it was understood, and several "failures" attributed to the second chain were only this.

**Steps 9–12 are one story, not four independent wins.** Step 9 revealed that FFT-1 was
*coefficient-paced*, not fabric-paced — the residual fabric wait was 0.53 µs/row against 1499 µs of
CPU. Step 10 moved that work into fabric and made the stage FFT-paced. Only *then* was there
anything for step 11's second CoreFFT chain to do, which is why the firmware couples them and
silently refuses a second chain without the fabric generator. Doing 11 before 10 would have bought
nothing.

All fusion/overlap changes above were value-gated against the CPU-path golden or an A/B against the
known-good path rather than by CRC alone where rounding order deliberately changed (e.g. detect
fusion: max |diff| 2 LSB, zero pixels beyond that over 1,048,576, correlation 0.999866, a bound
`model_detect_fusion.py` predicted *before* any RTL existed).

### 3.2 Why these particular fusions/overlaps worked

- **Window and detect fusion** both follow the same pattern: a standalone DDR-round-trip pass (read
  512 MB / write 512 MB for window; read/write for detect) was deleted by computing the same result
  inline as data already streamed through a neighbouring kernel (the FFT feeder or unloader) — for
  window, exactly zero added wall-clock; for detect, the unloader's traffic actually *dropped* because
  uint16 magnitudes are half the size of the complex int32 it used to write.
- **Corner-turn/FFT-2 overlap** (`docs/ARCHITECTURE.md` §2.4a) is a narrower trick than fusion: a global
  transpose cannot be fused into a neighbouring stage (its read side needs the *entire* source matrix
  to exist first), but its *output* can be streamed strip-by-strip to a downstream row-consumer once
  each strip's kernel-DONE fires. This works for corner-turn→FFT-2 specifically because FFT-2 reads
  SIG row-by-row and the corner-turn's destination rows are exactly SIG rows — and it does **not**
  generalize to the other two transpose boundaries in the pipeline (range-gather↔its own corner-turn,
  or FFT-1↔the corner-turn that follows it), both of which are still-writing producers at the point a
  consumer would need to start reading.
- **Corner-turn tile size and the fabric clock** both delivered *less* than a naive throughput estimate
  predicted (4× longer bursts → only 1.23× throughput; 1.6× clock → only 1.08× wall-clock), and both
  times the shortfall was diagnosed the same way: the stage was **latency-bound**, not
  bandwidth/compute-bound, so the lever that should have worked on paper didn't, and that result is
  what redirected the roadmap toward parallelism.

### 3.3 Current bottleneck and the next lever

At the **18.45 s** baseline (2026-07-27) the decomposition is:

| stage | time | share |
|---|---:|---:|
| **resample** (range gather + internal corner-turn) | **7.267 s** | **39.4%** |
| range-FFT (FFT-1) | 5.788 s | 31.4% |
| azimuth-FFT (FFT-2 + corner-turn #2 overlapped in) | 5.396 s | 29.2% |

The three stages are now within 1.9 s of each other — there is no dominant stage left, which means
no single remaining change can produce another 25%+ cut. The corner-turn replacement took resample
11.175 → 7.267 s and the FFT-2/CT#2 overlap 8.610 → 5.396 s.

Range-FFT went the WRONG way across that change, 5.374 → 5.788 s (+0.41 s), and is UNEXPLAINED.

### 3.3a Where the time actually goes (E4, measured 2026-07-27)

Bus telemetry from `sar_fic0s_mon.v`, decoded with `mpfs/host/decode_ficmon.py`. This section
replaces argument with measurement; several earlier plans were re-ranked by it.

Resample sub-stages (`run_stage_timing.sh`): range gather **5.212 s**, internal corner-turn (CT#1)
**2.064 s**, azimuth gather 0 (fused into the FFT-1 feeder).

| kernel | port active | DDR read-wait | genuine idle | burst shape |
|---|---:|---:|---:|---|
| CT#1 — before (SmartHLS) | 22.7% | 35.8% | **41.5%** | half-width |
| CT#1 — after (`corner_turn_v`) | 26.2% | **71.8%** | **2.0%** | 64-beat avg |
| range gather (RES, SmartHLS) | 23.2% | 36.9% | **~40%** | **98.2% in 65–256** |
| FFT-1 row group | 5.2% | 7.3% | **~80%** | 17–64 |

Three conclusions, each of which overturned a plan:

- **The corner-turn is finished as a kernel problem.** Idle collapsed 41.5% → 2.0%; the rewrite
  did exactly what it was for. It now moves 256 MiB in 2.06 s (~260 MB/s against an 800 MB/s FIC_0
  ceiling), so ~3x port headroom remains but is blocked by DDR read latency. The next lever is
  outstanding-read depth / prefetch, an interconnect change — **not** a third rewrite.
- **`resample_v.v` is NOT justified as a burst fix.** The range gather already issues long bursts
  (98.2% in the 65–256 bucket, avg 71.9 beats), unlike the corner-turn it was modelled on. Its
  ~40% idle points off-bus, at the CPU pass-1 coefficient path — which bounds the pass-1 fabric
  coeffgen win at roughly **2 s** and makes it the one clearly justified lever.
- **The range-FFT regression is not bus contention.** FFT-1 is ~80% bus-idle, so the +0.42 s must
  be off-bus: CoreFFT on the 12.5 MHz `SLOWCLK`, coefficient generation, or the renormalize.

Run-to-run spread over three ELOD+PIPE cycles: total 18.477 / 18.484 / 18.591 s. Resample is
deterministic to **0.4 ms**; range-FFT is the noisy stage at **120 ms**. The +0.42 s regression is
~3.5x that spread, so it is real and not sampling noise.

> **FICMON has exactly TWO slots**, and `FICMON_REC()` is bare address arithmetic with no bounds
> check. A `ficmon_snapshot(2, ...)` writes 80 bytes at `0xB00592E0`, 48 of them onto `SAR_CWRK_ADDR`
> (`0xB0059300`) — the coefficient-worker control block. Measured cost when this happened
> accidentally: the renormalize epilogue silently dropped to single-hart, frame 18.48 → 22.04 s
> (+2.0 s range-FFT, +1.6 s azimuth-FFT, resample untouched). An unintended but clean measurement of
> what the multi-hart epilogue is worth.
The plausible reading is FIC_0 contention shifting now that the corner-turns finish sooner, but it
has not been measured. Treat it as an open item, not a known cost.

#### The corner-turns are ~11 s of the frame, and now measured

E4 (FICMON around the whole internal corner-turn, 2026-07-27) moved this from inference to fact.
5.974 s to move a 256 MiB frame = **85.7 MB/s** against a FIC_0 ceiling of 64 bit × 100 MHz =
**800 MB/s**:

| | share |
|---|---:|
| moving data (`TOTAL_ACTIVE`) | 22.7% |
| asked, DDR did not deliver (`R_DATAWAIT`) | 35.8% |
| not even asking (idle) | 41.5% |

and 524,288 write bursts × 128 beats = 67.1 M beats — **512 MiB of 64-bit beat capacity to move a
256 MiB frame.** The SmartHLS kernel writes one `uint32` per beat and discards half the data bus.
Three separate defects, of which two are ours to fix (full-width beats ≈ 2×; double-buffered tiles
close the idle) and one is **not**: `R_DATAWAIT` is inherent to a transpose, because each tile row
is a separate DRAM page at 32 KiB stride. Double-buffering *hides* that 35.8% under write traffic,
it does not remove it. `corner_turn_v.v` is in progress.

#### Two earlier conclusions in this section were WRONG — recorded so they are not retried

**"Parallelism is the lever; add a second gather instance (`RES2`)."** The range gather is
**coefficient-bound, not fabric-bound**: step 9 showed 1499 µs/row of CPU coefficient generation
against 0.53 µs/row of residual fabric wait — 99.95% of the stage was the CPU. A second gather lane
parallelises the 0.25%. `RES2` no longer exists in the fabric either; its slot was reclaimed for the
second FFT chain's unloader. The real lever there is the **pass-1 fabric coefficient generator**
(~5.8 s, `mpfs/fpga/coeffgen1_design.md`), whose arithmetic is already gated bit-exact at production
geometry.

**"The interconnect allows one outstanding transaction, so raise it."** The core RTL says otherwise:
`MAX_OUTSTNDG_TRANS` is per-thread with valid range 1–8 and
`OPEN_RDTRANS_MAX = max(MAX_OUTSTNDG_TRANS, 2)`, so the design already runs **two** outstanding
reads per initiator. Even at two the arithmetic permits ~800 MB/s, so the 85.7 MB/s shortfall was
never an outstanding-transaction limit. Step 6 in the table above had already said as much —
quadrupling the burst bought only ×1.23, which is not how a latency-bound transfer with too few
requests in flight behaves.

#### What is left, ranked

1. **Production run on NDSU** — staged at 8192², all coefficient gates pass at that geometry. This
   is the deliverable; everything else optimises a pipeline that has never processed the real target.
2. **Hand-written corner-turn** (`corner_turn_v.v`) — ~11 s of frame, measurement-justified above.
3. **Pass-1 fabric coefficient generator** — ~5.8 s, arithmetic already proven.
4. **Clock 100 → 125 MHz** — worth only ~1.2 s and currently impossible: setup slack is **+0.182 ns
   on a 10 ns period**, i.e. a ~9.82 ns critical path. Needs path surgery first.

A dead end worth recording: overlapping the internal corner-turn against FFT-1 needs a third frame
buffer, and there is nowhere to put one. The cached window is full to the byte (SIG + SCRATCH + OUT
+ code end exactly at `0xB000_0000`) and the non-cached segment at `0xC000_0000` is **outside the
DIC's decode** — the fabric cannot reach it. Widening that window corrupts the baseline while still
passing timing. Verified on silicon, twice.

---

## Notes on source material

- Two pre-consolidation documents disagreed on which engine implements the FFT feeder/unloader:
  the old `SAR_ARCHITECTURE_REPORT.md` §2 (dated 2026-07-11) labelled `K_FFT_UNLOADER` as an "HLS
  unloader," while the old `SAR_DESIGN.md` §4 (more detailed, and explicit that this is "not a style
  choice") stated both the feeder and unloader are hand-written Verilog because SmartHLS produces
  dead RTL for stream-to-mem/mem-to-stream kernels on this toolchain. This guide follows
  the project's own build timeline (the HLS `fft_unloader` was the 2026-07-04 design,
  later superseded once window/detect fusion moved the unloader to hand-written Verilog on
  2026-07-21) and treats `docs/ARCHITECTURE.md` §2.4 as the current, authoritative statement — but the
  contradiction is unresolved in the original source material and worth flagging if precision here
  matters for a future change.
- The 78.557 s CPU-detect baseline used in the detect-fusion A/B and the 79.79 s window-fused
  baseline quoted above (Part 3) are both cited from real
  measurements but are not the same run; the original measurement notes detect's run-to-run
  variance spans ~1.8 s (~9%), which plausibly accounts for the gap. Both numbers are reproduced here
  as given rather than reconciled.
- The Milestone 2 integration work's memory-budget risk note flags a discrepancy between the bare-metal repo's
  compile-time `DDR_SIZE` (1 GB) and the build report's stated board DRAM (2 GB); this
  guide did not re-resolve it, since it is a pre-silicon planning note rather than part of the
  optimization or algorithm narrative.

### 3.4 Remaining levers, ranked by MEASUREMENT (2026-07-27)

Ranked after E4, not before it. Two entries were demoted and one promoted by the measurement, so
prefer this table to any earlier prose. Frame 18.45 s; resample 7.267 · range-FFT 5.788 ·
azimuth-FFT 5.396.

| lever | est. payoff | basis | status |
|---|---:|---|---|
| Pass-1 fabric coeffgen | **~2 s** | measured: ~40% of a 5.212 s gather is bus-idle | RTL fixed + 12/12 gated; build pending |
| Range-FFT regression | ~0.4 s | measured, 3.5x the run spread | off-bus; cause unknown |
| Corner-turn prefetch / outstanding reads | unknown | 71.8% read-wait, ~3x port headroom | interconnect change, not RTL |
| `resample_v.v` | small alone | bursts ALREADY long — no burst defect | only as the coefficient-stream consumer |
| CT#1 / FFT-1 overlap | ≤2 s | CT#1 measured 2.064 s | needs WORK buffer; DIC window blocks it |
| Four FFT chains | ~0 | serial epilogue (measured worth 3.6 s) dominates | not recommended |
| Raise fabric clock | 0–3 s | +0.182 ns slack on a ~9.82 ns path | needs path surgery; raises power |

Sanity ceiling: stacking the plausible wins optimistically lands near **11–13 s**, not single
digits. The three stages are within 1.9 s of each other, so no single change can repeat the
corner-turn's 26.7%.
