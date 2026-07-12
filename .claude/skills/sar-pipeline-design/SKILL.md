---
name: sar-pipeline-design
description: >-
  The SAR image-formation datapath design — pipeline stages (resample / keystone / polar-format,
  2-D window, range FFT, corner-turn transpose, azimuth FFT, detect), the fixed-point + data
  contracts, block-floating-point FFT scaling, and the DDR-to-DDR streaming buffer model. Load
  when designing, porting, or reasoning about ANY SAR pipeline stage or its numeric contract.
  Triggers: "resample / keystone / polar format", "range/azimuth FFT", "corner-turn / transpose",
  "window", "detect", "block floating point / SCALE_EXP", "fixed-point contract", "SIG/SCRATCH/OUT".
---

# SAR pipeline design

Spotlight-mode SAR image former using the **Polar-Format Algorithm (PFA)**. The design is
**target-neutral** — described here as a datapath; the current implementation is a hybrid
MSS-CPU + FPGA-fabric realization on PolarFire SoC (see `docs/fpga/SAR_ARCHITECTURE_REPORT.md`
for the as-built block/timing detail and `docs/fpga/SAR_PIPELINE_PROCESS.md` for the math).

## Stages (per frame; frame = full complex array, e.g. 8192×8192 = 256 MiB)

Input is a CPHD phase-history array (see `umbra-cphd-data` skill for dimensions). Two passes:

1. **Resample (keystone / polar-format interpolation)** — 2-pass. A control processor computes, per
   output sample, a quantized source index `idx[]` + a Q15 fractional weight `wq[]` from the collection
   geometry; the datapath **gathers + linearly interpolates**. Contract (two-tap linear/lerp):
   `out = in[idx] + (in[idx+1] - in[idx]) * wq / 32768`  (== `in[idx]·(1−w) + in[idx+1]·w`, w = wq/2^15).
   Pulse reorder via an `inv_order` permutation. Range pass then azimuth pass.
2. **2-D window** — separable Hamming taper `hamr[j]·hamc[k]`, fixed-point, zero inside the zero-pad
   region.
3. **Range FFT** — 8192-pt row FFT with **block-floating-point** (per-row `SCALE_EXP`); see BFP below.
4. **Corner-turn (transpose)** — global transpose between the two FFT passes. This is the key
   data-movement primitive: it forces full DDR materialization (a global transpose cannot be fused) and
   is tiled through on-chip SRAM.
5. **Azimuth FFT** — a second 8192-pt FFT over the transposed frame (same FFT engine reused).
6. **Detect** — per-pixel magnitude `sqrt(I² + Q²)`, saturated to uint16. **I and Q MUST be sign-extended
   correctly** (see pitfall) before squaring.

## Fixed-point / data contracts
- **Complex samples are int16 I / int16 Q**, packed as one 32-bit word per pixel (hi16 = I, lo16 = Q).
  The detected OUT image is uint16 magnitude (2 bytes/pixel) — so a complex buffer is 4 B/px, OUT is
  2 B/px; the SAME byte offset addresses DIFFERENT rows in the two. Compute row addresses explicitly
  (`base + row·GRID·bytes_per_px`).
- **Resample lerp:** `out = in[idx] + (in[idx+1]-in[idx])*wq/32768`, wq ∈ Q15. Geometry (`idx`,`wq`)
  is computed in float on the control processor; the interpolation itself is fixed-point.
- **Block-floating-point (BFP) FFT:** the transform runs with an adaptive/per-row scale and reports a
  per-row exponent `SCALE_EXP`; the true value is `DATAO · 2^SCALE_EXP`. Firmware then applies a
  **global renormalization** across rows: `>> (emax − exp_i)` to a common block exponent. This
  preserves AC content (per-stage `>>1` truncation collapses AC → DC-only; global-block-exponent
  keeps AC). BFP is what let the fixed-point pipeline match the float golden.
  - The FFT IP's `SCALE_EXP` register is NOT the same quantity as a software BFP block exponent (the IP
    does an ~unconditional 1/N scale). Do not compare the two directly.

## DDR-to-DDR streaming buffer model
- The frame far exceeds on-chip SRAM, so **every stage is a DDR→DDR streaming pass** (read a buffer,
  compute, write a buffer). Stages run **sequentially** (arm a kernel, wait DONE, arm the next) — not a
  fused concurrent pipeline.
- Three DDR regions: **SIG** (signal), **SCRATCH**, **OUT** (detected image). Buffers **ping-pong
  SIG↔SCRATCH** so an in-place FFT never reads and writes the same page. On-chip each stage keeps only
  small buffers: one row, one transpose tile, or AXI burst FIFOs.
- **Corner-turn is the load-bearing data-movement primitive** — the only stage that must fully
  materialize the frame in DDR (global transpose between passes).

## Pitfalls / lessons
- **Detect sign-extension.** The magnitude `sqrt(I²+Q²)` requires I and Q read as SIGNED int16. A bug
  that read the high-16 (I) as UNSIGNED made every negative-I pixel overflow → saturate to 0xFFFF
  (~50 % of the image), collapsing correlation. The source was correct C (`(int16_t)(x>>16)`); the HLS
  toolchain mis-synthesized the shift-then-cast. Lesson: verify magnitude by VALUE on real hardware; a
  branchless `sext16(u) = (int32_t)((u & 0xFFFF) ^ 0x8000) - 0x8000` is the reference formula. See the
  `mpfs-platform-gotchas` skill for the toolchain-specific failure + the CPU-detect fallback that ships.
- **FFT engine choice.** For a streaming continuous FFT, a Radix-2² DIF *streaming* core may cap at a
  smaller max size and lack BFP; the larger size + conditional BFP needed here required an *in-place*
  (Radix-2 DIT) core. Check the max FFT size and BFP support against the workload BEFORE integrating.
  (IP-specific detail: `mpfs-platform-gotchas` → CoreFFT section.)
- **Scaling truncation.** Per-stage `>>1` after each FFT butterfly stage truncates AC to DC-only for
  small real inputs. Use full-precision + a global block exponent (BFP) instead.

## Verify by VALUE, not correlation
Correlation is scale/phase/orientation-invariant and hides real bugs. Build a bit-accurate fixed-point
emulator that equals the float golden, then diff hardware vs emulator element-by-element. See the
`sar-verification-methodology` skill.
