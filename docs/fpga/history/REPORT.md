# SAR Processor — Progress Report

> **▶ 2026-07-14 status (newest — supersedes older status in this file for repo layout + eMMC).**
> This repo is now **standalone `mpfs250t-sar-ifp`** (builds without a sibling `sarProcessor`), and the
> **on-board eMMC pipeline (M1–M3) is proven on silicon** — a CPHD scene is stored on the eMMC, loaded +
> focused on-board (`sar_form_image` → SAR_SEQ_OK; focused image confirmed via ROI crop), and the output
> persisted back to the card, retiring the recurring ~3 h JTAG scene load. Authoritative current status:
> [`PROJECT_SOURCE_OF_TRUTH.md`](../../PROJECT_SOURCE_OF_TRUTH.md) + [`fpga/SILICON_ISO_TEST_RUNBOOK.md`](../SILICON_ISO_TEST_RUNBOOK.md) § eMMC M1/M2/M3.
> The 2026-06/07 status below is retained as history.

**Project:** Lightweight SAR image formation from Umbra Complex Phase History Data (CPHD), with a PolarFire SoC (MPFS Icicle Kit) embedded port
**Date:** 2026-06-16 (status updated 2026-06-30)
**Status:** Algorithm complete and verified; CPU port works; FPGA fabric **built, programmed, and brought up on silicon** — data plane and DMA control slave both fixed and verified on the board (see [`fpga/SAR_BRINGUP_REPORT.md`](../SAR_BRINGUP_REPORT.md)). **M3 full PFA pipeline root-caused to FPGA timing closure** (bitstream fails timing at 125 MHz on the single fabric clock); the **62.5 MHz fix is now PROVEN** — headless P&R closes timing completely (0 setup violations of 315,349 pins, 0 hold) — with a bootable bitstream still pending a SAR_TOP rebuild (see §5).

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`PROJECT_SOURCE_OF_TRUTH.md`](../../PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". The `CoreAXI4DMAController 2.2.107` referenced below as the FFT-stream datamover is
> stale — it deadlocked on the 2nd back-to-back S2MM transaction and was replaced by the `fft_unloader`
> HLS kernel (AXI4-Stream slave → AXI4 write master). The fixes are fabric-level (firmware unchanged);
> the fabric is rebuilding and on-silicon retest is pending.

---

## 1. Objective

Focus raw Synthetic Aperture Radar phase-history data (Umbra **CPHD** — Compensated Phase History Data) into a detected, geocoded **GeoTIFF**, and port that workload to the **PolarFire SoC MPFS Icicle Kit** as a storage-to-storage batch processor (CPHD pre-loaded on board storage → focused on-board → GeoTIFF written back, no network link).

The image-formation method is the **Polar Format Algorithm (PFA)**.

---

## 2. Input data: Umbra CPHD

**CPHD (Compensated Phase History Data)** is the SAR equivalent of a camera RAW file: the radar's *unfocused* complex return, recorded pulse-by-pulse across the synthetic aperture, plus all the geometry needed to focus it. "Compensated" means platform-motion phase has already been removed (motion compensation to a reference point), so an image-formation algorithm can consume it directly. It is a published NGA standard (CPHD 1.0, the sibling of the focused SICD format); Umbra distributes it as open data.

The pipeline starts from CPHD — not the finished image — because focusing it *is* the signal-processing workload being ported to the PolarFire fabric.

### 2.1 File structure (as consumed by the pipeline)

A `.cphd` file has three parts:

1. **XML metadata header** — collection geometry, domain type, sample spacing, scene reference. Read via `reader.cphd_meta`; the pipeline asserts `Global.DomainType == "FX"` (frequency domain).
2. **PVP arrays (Per-Vector Parameters)** — one record *per radar pulse*, carrying the time-varying geometry the focuser needs:
   - `TxPos`, `RcvPos` — transmit/receive antenna phase-center positions (ECEF) per pulse
   - `SRPPos` — Scene/Stabilized Reference Point position
   - `SC0`, `SCSS` — start frequency and per-sample frequency step (frequency `= SC0 + k·SCSS`)
   - `SGN` — FFT sign convention
3. **Signal array** — the raw complex samples, a 2-D matrix of **(pulses × samples)** = (slow-time × fast-time), read as `complex64`.

### 2.2 The test scene

| Property | Value |
|----------|-------|
| Sensor / band | UMBRA-04, X-band (9.6 GHz), HH polarization |
| Imaging mode | SPOTLIGHT |
| Collected | 2023-09-06, ~1.2 s aperture |
| Location | Strait of Hormuz (lat 27.14°, lon 56.24°) — ship-detection test scene |
| Geometry | ~595 km slant range, 60° grazing, descending pass, left-looking |
| Raw signal dimensions | 7586 × 8191 (pulses × samples); focused on an 8192 × 8192 power-of-2 grid |
| Resolution | ~0.92 m azimuth × 0.91 m ground range |

### 2.3 Reference products (validation only)

Umbra ships already-focused derived products alongside the CPHD in the same folder: **GEC** (Geocoded Ellipsoid Corrected, the `.tif`) and **SICD** (focused complex). These are finished images and are **not** inputs to the pipeline — the GEC product is kept solely as the validation reference to confirm the home-grown focuser produces a geometrically correct, correctly geocoded image.

---

## 3. What has been done

### 3.1 Laptop reference pipeline — *complete and verified*

Location: [src/](src/)

| File | Purpose | Status |
|------|---------|--------|
| [form_image_pfa.py](src/form_image_pfa.py) | End-to-end PFA focuser: download → parse CPHD/PVP → polar-to-Cartesian keystone resample → Hamming window → 2-D FFT → magnitude detect → ECEF→UTM geocode → GeoTIFF | Working, verified |
| [fixedpoint.py](src/fixedpoint.py) | NumPy block-floating-point (BFP) fixed-point **emulator** of the FPGA datapath; quantization study that measures information loss vs. bit width | Working |
| [form_image_pfa_fixed.py](src/form_image_pfa_fixed.py) | Full pipeline in 16-bit BFP fixed point; reuses the reference's resample/geocode and emits a comparison-grade float32 GeoTIFF on the same pow2 grid | Working |
| [compare_float_fixed.py](src/compare_float_fixed.py) | Differences the float and fixed GeoTIFFs → error metrics (SNR/ENOB/NRMSE/DR) JSON + 3-panel diff PNG | Working |
| [config.yaml](config.yaml) | Input dataset + processing knobs (mode, decimation, windowing, geocoding) | — |

**Key results:**
- Produces a geometrically correct, geocoded GeoTIFF validated against Umbra's own GEC reference product.
- The fixed-point emulator quantifies datapath precision (SNR, ENOB, correlation, dynamic-range loss, and the per-stage BFP guard-bit growth) — this is the hardware-sizing study that drives FPGA bit-width choices.
- Real outputs exist in [output/](output/) (`*_fixed16bit_detected.tif`, `*_fixed16bit_full.png`).

### 3.2 PolarFire SoC port — *CPU host complete; FPGA fabric built, programmed, and verified on silicon*

> **Note (2026-06-30):** This section reflects the original 2026-06-16 design framing. The
> realized fabric is **not** the monolithic `sar_accel_top.cpp` / `fft1d.cpp` template below
> (those remain unsynthesized). It is **5 HLS kernels** (corner-turn, window, detect, resample,
> fft-feeder), each with an AXI4-Lite control slave + AXI4 data master, plus **CoreFFT 8.1.100**
> and **CoreAXI4DMAController 2.2.107**, stitched over two **CoreAXI4Interconnect 3.0.130** crossbars
> (data + control) to the MSS/FIC — built into a programmed bitstream and brought up on silicon. The
> Linux/UIO/CMA `FpgaBackend` runtime model below was **abandoned** in favor of bare-metal RISC-V
> (U54_1) over JTAG. See [`fpga/SAR_BRINGUP_REPORT.md`](../SAR_BRINGUP_REPORT.md),
> [`fpga/AMBA_ARCHITECTURE.md`](../AMBA_ARCHITECTURE.md).

Location: [mpfs/](mpfs/)

Architecture — storage-to-storage batch processor with a CPU/FPGA partition:

```
/data/in/*_CPHD.cphd (+ _METADATA.json)              /data/out/*_detected.tif
        │                                                      ▲
   [CPU] parse + build tables                                  │
        │              ┌──────── shared LPDDR4 ────────┐       │
        └──► signal ──►│  [FPGA] resample→window→FFT    │      │
                       │         →corner-turn→FFT→detect│──────┘
                       └────────────► detected ─────────┘
                                  [CPU] geocode + GeoTIFF
```

| Component | File | Status |
|-----------|------|--------|
| CPU host pipeline + `--watch` batch daemon | [sar_pipeline.py](mpfs/host/sar_pipeline.py) | **Works** — reuses the reference, pixel-identical output |
| Backend seam (Numpy / FPGA interchangeable) | [accel.py](mpfs/host/accel.py) | NumpyBackend works; FpgaBackend is a documented stub |
| FPGA top-level dataflow | [sar_accel_top.cpp](mpfs/fpga/sar_accel_top.cpp) | **Unsynthesized template**; corner-turn is a stub |
| Streaming BFP FFT kernel | [fft1d.cpp](mpfs/fpga/fft1d.cpp) | **Unsynthesized template** |
| AXI4-Lite register map (host↔fabric contract) | [regmap.md](regmap.md) | Specification only |

**Design rationale for the partition:** the 2-D FFT dominates compute and is what the U54 cores (625 MHz, no SIMD) are worst at; it maps cleanly onto the fabric's 784 18×18 DSP blocks. The CPU keeps the I/O, parsing, geometry/table prep, map projection, and GeoTIFF encoding it already handles well. Across a pre-loaded queue, read / focus / encode stages pipeline so both engines stay busy.

---

## 4. What works today vs. what is a template

- **Works & verified:** the CPU host path (`--backend numpy`) runs end-to-end and is **pixel-identical** to the laptop reference's GeoTIFF. This doubles as the board's CPU-only fallback mode (slow but correct) **and** the golden oracle for verifying the fabric later.
- **Built & on silicon (2026-06-30):** the realized fabric is **5 HLS kernels** (corner-turn, window, detect, resample, fft-feeder) + **CoreFFT 8.1.100** + **CoreAXI4DMAController 2.2.107** *(the DMA was removed 2026-07-04 and replaced by the `fft_unloader` HLS kernel — see the update note at top)*, stitched over two **CoreAXI4Interconnect 3.0.130** crossbars to the MSS/FIC and built into a programmed bitstream. Synthesis, simulation, place/route, and bitstream are all done; the data plane and DMA control slave are fixed and verified on the board. The runtime is **bare-metal RISC-V over JTAG** — the Linux/UIO/CMA `FpgaBackend` model was abandoned. The monolithic `sar_accel_top.cpp` / `fft1d.cpp` templates remain unsynthesized (superseded by the HLS kernels).

---

## 5. Remaining work to reach the board

> **Status (2026-06-30):** Milestones 0-2 below are **done** — the original Linux-on-Icicle plan
> was replaced by a JTAG-only, bare-metal RISC-V runtime (see [`mpfs-REPORT.md`](mpfs-REPORT.md) and
> [`fpga/SAR_BRINGUP_REPORT.md`](../SAR_BRINGUP_REPORT.md)). The board is an **MPFS250T_ES
> (FCVG484)** programmed via the **embedded FlashPro6 on connector J33** (boot mode 1). What remains
> open is only the full DMA *transfer* test (control verified; real descriptor + START data-move not
> yet run). Bulk-data transport over JTAG is **slow but viable run-to-completion** — measured
> **~84 kbit/s** (~111 s/MB, ~2.7 hr for the full 97 MB), latency-bound by FlashPro6 USB-HID; an
> on-target CRC32 mailbox now verifies loaded DDR in seconds instead of a slow dump+compare
> (see [`mpfs-REPORT.md`](mpfs-REPORT.md) §5b). The historical milestone plan is kept below.

In priority order (lowest risk / highest value first):

**Milestone 0 — CPU-only path on real hardware.** *(superseded — JTAG-only bare-metal, no Linux boot)*
Originally: boot Linux on the Icicle Kit and run `sar_pipeline.py --backend numpy --watch /data/in`. The host pipeline still serves as the golden oracle, but it runs **off-board** on a host PC; the board runs bare-metal C (no Linux boot medium over JTAG-only I/O).

**Milestone 1 — FFT in fabric, verified.** *(done)*
**Microchip CoreFFT 8.1.100** (BFP, 8192-pt, 16-bit) generated and verified in RTL vs. the bit-exact emulator. Datapath bit width locked using the `fixedpoint.py` study.

**Milestone 2 — Full datapath, bitstream, on-silicon bring-up.** *(done)*
- The **corner-turn** and the other kernels (window, detect, resample, fft-feeder) are implemented as SmartHLS kernels — tiled, burst-friendly — and verified.
- Libero design: 5 HLS kernels + **CoreFFT 8.1.100** + **CoreAXI4DMAController 2.2.107** over two **CoreAXI4Interconnect 3.0.130** crossbars (data 6m/1s; control 1m/6s), wired to the MSS via FIC; placed, routed, timing-clean bitstream produced.
- Runtime is **bare-metal RISC-V (U54_1) over JTAG** — the device-tree / UIO / CMA / `FpgaBackend` model was abandoned.
- On-silicon bring-up: **data plane fixed and verified** (root cause was AXI ID-width truncation at `FIC_0_AXI4_S`; fix = `sar_axi_idconv.v` ID stash/restore; M2 tag 0x30 went HANG→PASS, SCRATCH written), and the **DMA control slave fixed and verified** 2026-06-30 (root cause: CIC slave-5 was `TARGET_TYPE=0`/Full-AXI4 feeding the DMA's reduced AXI4-Lite control through a 64→32 DWC, black-holing reads and hanging the hart un-haltably; fix = CIC `TARGET5_TYPE=1` (AXI4-Lite) + 11-bit address slice via `sd_create_pin_slices`; tags 0x50-0x53 read distinct DMA regs, VER=0x00020064, no hang).

**Milestone 3 — Full PFA pipeline on silicon.** *(root-caused to timing closure; 62.5 MHz fix PROVEN, bootable bitstream pending)*
The full PFA pipeline was wired into firmware (PIPE mailbox → `sar_form_image`). Stages 1–4 ran on
silicon; the range-FFT (stage 5) appeared to hang. **Real root cause: the FPGA bitstream does not
meet timing at 125 MHz** — P&R `pinslacks.txt` shows 25,847/315,348 pins with negative slack
(worst −3.7 ns), **all on the single 125 MHz fabric clock** (CT/CIC/DMA/FEED/DIC/RES/DET/WIN);
CoreFFT itself has 0 violations — real same-clock setup failures, not CDC. Consequence:
non-deterministic silicon — the FFT looped, and although stages 1–4 *completed*, only completion
was checked, so **their data is likely corrupt and remains unverified pending the timing-closed
rebuild** (this supersedes earlier per-symptom theories). **Fix:** lower the fabric-clock CCC OUT0
125→62.5 MHz and OUT1 (CoreFFT `SLOWCLK`) 15.625→7.8125 MHz (`SLOWCLK ≤ CLK/8`), headless via
`PF_CCC_C0_62p5.tcl` + `reconfig_ccc_62p5.tcl`, re-assemble `SAR_TOP`, and rebuild with the
**timing-gated** `build_timed.tcl` (aborts before bitstream on any negative slack). Trade-off:
62.5 MHz halves fabric/FIC throughput (acceptable for bring-up). **Lesson (standing rule):** always
verify P&R timing closure before blaming logic/firmware — Libero programs timing-failing bitstreams
silently, and `*_sdc_errors.log` reports SDC *syntax*, not *slack*. **Status (2026-07-01): timing
closure PROVEN.** Headless P&R of the 62.5 MHz design (with the CoreFFT `CLK`↔`SLOWCLK` false-path
`sar_fft_cdc.sdc`) **closes timing completely — 0 setup violations of 315,349 pins and 0 hold** (vs
25,847 setup violations at 125 MHz), validated via the Libero VM-netlist custom flow
(`mpfs/fpga/libero_vm`); the clock-lowering fix is confirmed. **Caveat:** a fully *bootable* bitstream
still needs the SAR_TOP SmartDesign rebuilt with the (already regenerated) 62.5 MHz CCC — the MSS is
coupled to the SmartDesign flow and resists the pure headless netlist flow (verified recipe in
[`fpga/SAR_TOP_RECOVERY.md`](../SAR_TOP_RECOVERY.md)). Pending: that bootable rebuild + reprogram +
re-run; the firmware itself is valid (PIPE/CRC mailboxes, DMA external-stream-descriptor, bounded harness).

### Risks / items to flag
1. **Emulator coverage gap.** `fixedpoint.py` currently quantizes only the **FFT**, not the **resample** step. Extend it to quantize resampling so the golden oracle validates the entire offloaded datapath before trusting the fabric.
2. **The corner-turn is the hard part**, not the FFT (CoreFFT is off-the-shelf). Budget accordingly.
3. **On-fabric detection/scaling** ([sar_accel_top.cpp](mpfs/fpga/sar_accel_top.cpp)) currently truncates magnitude to uint8 with a naive cast; the BFP_SHIFT-based AGC needs proper definition to match the host's dB/percentile view.

---

## 6. Measured compute resources & per-step timing

### 6.1 Host (development / reference) platform

The machine that produced the timings below — the **reference**, not the deployment target. The fixed-point step is a bit-accurate *emulation* in scalar-style NumPy and is **not** representative of FPGA wall-time (see §9.4).

| Resource | Value |
|----------|-------|
| CPU | Intel® Core™ Ultra 7 165U |
| Cores / threads | 12 physical / 14 logical |
| Base clock | ~1.7 GHz (turbo higher) |
| RAM | 16.6 GB |
| OS / Python | Windows 11 (build 26100) / CPython 3.13.9 |
| FFT backend | NumPy `pocketfft` (multi-threaded) |

### 6.2 Per-step wall-time (ship scene, full resolution)

Each run writes its own breakdown to `output/<stem>_*.timing.json`.

**Float reference (`form_image_pfa.py`) — total 22.5 s**

| Step | Time (s) |
|------|---------:|
| open + read CPHD header | 3.62 |
| read PVP geometry | 0.01 |
| read signal (phase history) | 0.67 |
| resample + window | 7.40 |
| zero-pad + 2-D FFT | 6.61 |
| detect + geocode + GeoTIFF | 4.19 |

**Fixed-point emulation (`form_image_pfa_fixed.py`) — total 66.3 s**

| Step | Time (s) |
|------|---------:|
| open + read header + PVP | 3.56 |
| read signal (phase history) | 0.87 |
| resample + window | 5.33 |
| input quant + **BFP 2-D FFT** + detect | **47.66** |
| geocode + GeoTIFF | 8.92 |

The 47.7 s is the per-stage block-floating-point `fit_scale`/`quant` bookkeeping done element-wise in NumPy; on the fabric that is a hard-wired arithmetic shift (free). Do not read it as the FPGA's speed.

---

## 7. Float vs fixed-point comparison

Produced by `compare_float_fixed.py` → `output/<stem>_float_vs_fixed.{json,png}`. Both images peak-normalized (detected magnitude has an arbitrary linear / BFP scale).

| Metric | Value | Meaning |
|--------|------:|---------|
| Geo-aligned (grid, CRS, affine) | ✅ true | the two GeoTIFFs are directly differenceable |
| SNR (fixed vs float) | **29.3 dB** | error power vs signal power |
| ENOB | **4.57 bits** | effective number of bits delivered |
| NRMSE | 0.034 | 3.4 % normalized RMS error |
| Pearson correlation | 0.9992 | structurally identical images |
| Max \|error\| (normalized) | 0.013 | worst single-pixel deviation |
| Mean bias (normalized) | 5e-6 | floor truncation is ~unbiased after detection |
| Usable dynamic range — float | 57.7 dB | |
| Usable dynamic range — fixed | 53.2 dB | |
| **Dynamic-range loss** | **4.5 dB** | cost of 16-bit BFP + truncation |

**Reading:** at 16-bit the fixed image is visually identical (corr 0.9992) and keeps 53 dB usable dynamic range — adequate for ship detection — while delivering ~4.6 ENOB and ~4.5 dB less floor headroom than float. This high-energy ship scene costs ~1.3 bits more than the calmer Centerfield collect (≈5.9 ENOB) because more BFP down-shifts ⇒ more truncation events.

---

## 8. Bit-growth analysis for the PolarFire SoC datapath

The 2-D FFT is the only stage with non-trivial word growth. Captured block-exponent schedule (one entry per radix-2 stage, from `output/<stem>_fixed16bit.timing.json`):

| FFT pass | Block-exponent trajectory (input → output) | Guard bits |
|----------|---------------------------------------------|-----------:|
| Range (cols, 8192-pt = 13 stages) | −6 −6 −5 −5 −4 −4 −3 −2 −1 0 0 1 2 **3** | **+9** |
| Azimuth (rows, 8192-pt = 13 stages) | 3 3 4 4 5 5 6 7 8 9 10 11 12 **13** | **+10** |

**Where the bits come from** (per radix-2 butterfly `a ± w·b`):

| Operation | Growth | PolarFire mapping |
|-----------|--------|-------------------|
| Input sample | 16-bit signed I/Q | LSRAM / DDR |
| Twiddle `w` | 18-bit signed (≈[−1,1)) | 18×18 ROM, **truncated** |
| Complex mult `w·b` | 16 b × 18 b → 34-bit product; `wr·br − wi·bi` → ~35-bit | **18×18 MACC → 48-bit accumulator** |
| Butterfly add `a ± (w·b)` | +1 bit | fabric adder |
| Per-stage worst case | +1 bit/stage ⇒ +13 b over 8192-pt | — |
| **Measured (BFP)** | **+9 (range), +10 (azimuth)** | shared 5-bit block exponent |

**Word-width recommendation:**
- A *linear* (non-BFP) 8192×8192 transform would need 16 + 13 + 13 = **42-bit** datapath to never overflow — wasteful.
- **Block floating point** holds the mantissa at **16-bit** and tracks a per-stage block exponent; the measured swing is only +9 / +10 bits, covered by a **5-bit exponent** per FFT line.
- The math block's **48-bit accumulator** absorbs the 35-bit complex-multiply product with >12 bits of headroom — no saturation inside a butterfly.
- **Recommended config: 16-bit mantissa, 18-bit twiddle, 48-bit accumulate, BFP arithmetic-shift (floor) after every stage** — matches Microchip CoreFFT's BFP mode and the emulation in `fixedpoint.py`. If 53 dB DR is marginal, **18-bit mantissa** buys ~12 dB more and still fits one 18×18 DSP per multiply.

> Note (carried from §5): the emulator currently quantizes only the FFT, not the resample; extend it to quantize resampling before trusting the full fabric datapath.

---

## 9. PolarFire SoC: device limits, architecture & data-transfer budget

Assumed evaluation board: **PolarFire SoC Icicle Kit (MPFS250T-FCVG484E)**.

### 9.1 Device & board limits

| Resource | MPFS250T / Icicle | Relevance |
|----------|-------------------|-----------|
| FPGA logic | 254K logic elements (4-LUT + FF) | ample for FFT control + DMA |
| **Math blocks** | **784 × 18×18 MACC, 48-bit accumulator** | FFT butterflies; many parallel FFT cores possible |
| On-chip SRAM | LSRAM (20 Kb blocks, ~2 MB-class) + µSRAM | FFT line buffers + twiddle ROM — **cannot hold a frame** |
| CPU (MSS) | 4× SiFive U54 RV64GC @ **625 MHz** + 1× E51 monitor | orchestration, geometry, geocode |
| MSS L2 | 2 MB (configurable as LIM / scratchpad) | CPU working set |
| Fabric / FIC clock | **200 MHz** (Microchip reference config) | sets fabric throughput |
| Board DRAM | **2 GB LPDDR4, ×32** | frame + intermediates |
| At-rest storage | 1 Gb SPI flash, 8 GB eMMC / SD | CPHD before it is staged in DDR |
| DDR4/LPDDR4 controller | up to 1600 MHz / 3200 MT/s per pin ⇒ **~12.8 GB/s peak (×32)** | upper bound on memory bandwidth |
| Measured MSS-PDMA throughput (LIM↔fabric LSRAM) | **~6.2 Gbps read / 5.85 Gbps write** (≈0.78 / 0.73 GB/s, ≥64 KB bursts) | the *conservative* DMA path |

**Key constraint:** the working frame (8192×8192 complex, 16-bit I/Q = **268 MB**; input CPHD chip = 248 MB) is ~100× larger than all on-chip SRAM ⇒ **the image cannot live on-chip; it must stream from LPDDR4 every FFT pass.** This dominates the architecture.

### 9.2 Recommended CPU + FPGA partition

```
                 PolarFire SoC (MPFS250T)
 ┌─────────────────────────────┐        ┌──────────────────────────────────┐
 │  MSS  (4× U54 @ 625 MHz)     │  FIC   │  FPGA fabric  (200 MHz)           │
 │  ── control / float / I/O ──│◄══════►│  ── streaming fixed-point ──      │
 │ • CPHD ingest from DDR/eMMC │ AXI4   │ • input quantize (→16-bit I/Q)    │
 │ • PVP → look vectors, KR/KC │        │ • Hamming window (× ROM)          │
 │ • resample index+weight gen │        │ • CoreFFT BFP, range (cols)       │
 │   (geometry-only, 1×/collect)│       │ • corner-turn DMA (tiled, via DDR)│
 │ • GeoTIFF / geocode (affine)│        │ • CoreFFT BFP, azimuth (rows)     │
 │ • scheduling, double-buffer │        │ • detect |·| (x²+y², CORDIC √)    │
 └──────────────┬──────────────┘        └─────────────────┬────────────────┘
                │   AXI switch / DDR controller            │
                └──────────────┬───────────────────────────┘
                       2 GB LPDDR4 (×32) — CPHD pre-stored here
            [ raw CPHD | k-space buffer | corner-turn buffer | detected image ]
```

- **Fabric (fixed-point, the heavy lifting):** window + 2-D FFT + detect via **CoreFFT in BFP mode** (16/18/48-bit, truncating). The 784 DSPs allow several parallel row/column engines. Resample *application* runs on fabric MACCs using indices/weights the CPU precomputes once per collect (they depend only on geometry, not pixel data). Magnitude via CORDIC.
- **MSS / RISC-V CPU (control + float + irregular):** CPHD parse, PVP geometry, KR/KC grid + resample-coefficient generation, geocoding affine + GeoTIFF/metadata, and orchestration (program DMA descriptors, manage double-buffering; local interrupt latency = 30 core cycles).

This matches the project's existing partition (§3.2); the refinement is keeping resample *coefficient generation* on the CPU and the *application* on the fabric.

### 9.3 Memory budget & data-transfer recommendations (CPHD pre-stored in LPDDR4)

Store the CPHD as **16-bit I/Q (248 MB)**, not complex64, to halve footprint and match the datapath. One-frame LPDDR4 budget:

| Buffer (16-bit complex) | Size |
|-------------------------|-----:|
| Raw CPHD chip (input) | 248 MB |
| k-space / FFT working frame | 268 MB |
| Corner-turn (transpose) buffer | 268 MB |
| Detected output image | 134 MB |
| **Total** | **~0.9 GB of 2 GB** ✅ leaves room for double-buffering |

**DDR traffic per focused frame** (must stream — frame ≫ on-chip SRAM): input-quant + range FFT + corner-turn + azimuth FFT + detect ≈ **2.0–2.8 GB**.

**Recommendations:**
1. **Move data with a fabric-side AXI master over FIC, not the MSS PDMA.** At the measured PDMA rate (~0.78 GB/s), 2.5 GB/frame ≈ **3.2 s** of pure movement. A fabric AXI4 master on FIC0 (64-bit @ 200 MHz = **1.6 GB/s**), using **FIC0 + FIC1 ≈ 3.2 GB/s**, cuts that to **~0.8 s/frame** — still far under the ~12.8 GB/s LPDDR4 ceiling, so the **FIC bridge width**, not DDR, is the limiter.
2. **Burst ≥ 64 KB** — Microchip's throughput flattens by 64 KB; smaller bursts pay per-transfer overhead.
3. **Tile the corner-turn** (e.g. 32×32 / 64×64 sub-blocks) so the transpose hits DDR in row-friendly bursts; a naïve single-column stride forces a row-activate per element and wrecks LPDDR4 efficiency. *(This is the project's deliberately-stubbed piece — §5, Milestone 2.)*
4. **Double-buffer** input/output frames so fabric compute overlaps DMA; the pipeline then runs at `max(compute, DMA)`, not their sum.
5. **Widen the fabric AXI** (256-bit into the DDR controller) if one FIC is the limiter — the cheapest path to higher frame rate since DSP is abundant.

### 9.4 Throughput projection (PolarFire vs the laptop emulation)

A single pipelined 8192-pt FFT core at 200 MHz processes ~1 sample/cycle ⇒ ~41 µs/line; 8192 lines ⇒ ~0.34 s/dimension. Both dimensions + corner-turn ≈ **0.7–1.0 s/frame on one core**; the 784 DSPs allow several parallel cores ⇒ **sub-100 ms compute** is feasible, at which point the **~0.8 s DMA dominates** (mitigated by double-buffering + wider AXI). Net: the target should match or beat the laptop's 6.6 s float FFT at far lower power; the 47.7 s NumPy fixed-point figure is purely an emulation artifact.

### Sources
- [PolarFire SoC Product Overview (DS60001656)](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/ProductBrief/PolarFire-SoC-Product-Overview-60001656.pdf) · [MPFS250T product page](https://www.microchip.com/en-us/product/mpfs250t)
- [PolarFire SoC FPGA: Interrupt Latency and Data Transfer Throughput Measurements (DS60001712B)](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/SupportingCollateral/whitepapers/Microchip_PolarFire_SoC_FPGA_Interrupt_Latency_Data_Transfer_Throughput_Measurements_White_Paper.pdf) — 625 MHz CPU, 200 MHz FIC, ~6.2/5.85 Gbps PDMA
- [PolarFire SoC Icicle Kit User Guide (UG0882)](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/UserGuides/microchip_polarfire_soc_fpga_icicle_kit_user_guide_vb.pdf) · [PolarFire FPGA Fabric User Guide (UG0680)](https://web.pa.msu.edu/people/edmunds/Disco_Kraken/MPFS250T_FPGA/polarfire_fpga_fabric_user_guide_rev_7.0.pdf)

---

## 10. Summary

The algorithm and the complete CPU/FPGA architecture are done, and the CPU path is verified pixel-identical to the reference. On the ship scene, the 16-bit BFP fixed-point path is structurally identical to float (corr 0.9992) at ~4.6 ENOB / 53 dB usable dynamic range, with a measured FFT block-exponent growth of +9/+10 bits — driving a **16-bit mantissa / 18-bit twiddle / 48-bit accumulate** datapath on the MPFS250T's 18×18 MACCs. The frame (268 MB) far exceeds on-chip SRAM, so the design is **memory-bound**: stream from the pre-staged 2 GB LPDDR4 over fabric AXI/FIC (~3.2 GB/s dual-FIC, ≥64 KB bursts, tiled corner-turn, double-buffered). The remaining gap to a working Icicle Kit deployment is entirely **fabric implementation and on-hardware integration** — the corner-turn transpose and the bitstream/driver bring-up being the bulk of the effort.
