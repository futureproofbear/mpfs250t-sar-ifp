# FPGA accelerator (PolarFire SoC fabric)

> **▶ 2026-07-14:** repo now **standalone `mpfs250t-sar-ifp`**; on-board **eMMC pipeline (M1–M3) proven on
> silicon**. Current status: [`../PROJECT_SOURCE_OF_TRUTH.md`](../PROJECT_SOURCE_OF_TRUTH.md) +
> [`SILICON_ISO_TEST_RUNBOOK.md`](SILICON_ISO_TEST_RUNBOOK.md) § eMMC.

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`../PROJECT_SOURCE_OF_TRUTH.md`](../PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". The `CoreAXI4DMAController 2.2.107` listed below is stale — it deadlocked on the
> 2nd back-to-back S2MM transaction and was replaced by the `fft_unloader` HLS kernel (AXI4-Stream slave
> → AXI4 write master). Fabric-level change; firmware unchanged.

> ⚠ **Status (2026-06-30):** the fabric design is **built, programmed and
> silicon-verified** on the Icicle Kit (**MPFS250T_ES**, bare-metal RISC-V on
> U54_1, **JTAG-only**; programmed via embedded **FlashPro6 on J33**). Built design
> = the 5-kernel SmartHLS model + **CoreFFT 8.1.100** + **CoreAXI4DMAController
> 2.2.107** on two **CoreAXI4Interconnect 3.0.130** instances; control plane, data
> plane (`sar_axi_idconv.v`) and DMA control slave (CIC `TARGET5_TYPE=1`) all
> verified on silicon (full DMA *transfer* test + bulk JTAG transport still open).
> **The Linux / device-tree / UIO / CMA integration model described below is
> SUPERSEDED.** The two standalone `.cpp` files below do remain unsynthesized
> templates. See [`AMBA_ARCHITECTURE.md`](AMBA_ARCHITECTURE.md),
> [`FABRIC_INTERCONNECT_CONVENTIONS.md`](FABRIC_INTERCONNECT_CONVENTIONS.md) and
> [`SAR_BRINGUP_REPORT.md`](SAR_BRINGUP_REPORT.md).

Offloads the compute-dominant SAR focusing datapath from the U54 CPUs:
**range resample → window → 2-D FFT (range FFT → corner-turn → azimuth FFT) →
detect**. The CPU host drives it over AXI4-Lite (see [../regmap.md](../regmap.md))
and shares DDR buffers with it.

## Status — read this first
The **built** fabric design (5-kernel SmartHLS model + CoreFFT + DMA on two
CoreAXI4Interconnect instances) is silicon-verified — see the status note above.
These two standalone HLS source files, however, are **unsynthesized starting
templates**: they have **not** been compiled in SmartHLS, simulated, placed/routed,
or run on hardware, and they are *not* what the built design uses:
- `fft1d.cpp` — streaming radix-2 block-floating-point FFT (template)
- `sar_accel_top.cpp` — top-level dataflow stitching the kernels (skeleton; the
  corner-turn body is intentionally left as a stub)

The built design already uses the **Microchip CoreFFT IP** (verified,
characterized) rather than the hand-written `fft1d.cpp`; treat `sar_accel_top.cpp`
as the dataflow spec, not as drop-in RTL.

## Datapath
```
signal[M,N] ─DMA─► resample(KR) ─► window× ─► 1-D FFT ─┐
                                                       ▼
                                              corner-turn (tiled BRAM)
                                                       │
detected[M,N] ◄─DMA─ detect|·| ◄─ 1-D FFT ◄─ resample(KC) ◄┘
```
- **Power-of-2 FFT lengths** (`FFT_LEN_R`, `FFT_LEN_A`, e.g. 4096 × 8192): the
  raw 5634 × 4319 sizes are slow/odd, so the host zero-pads. Padding also
  improves the focus (free image-domain interpolation).
- **Block floating point, 18-bit** fixed point → matches the 784 18×18 DSP
  blocks and holds the ~50 dB scene dynamic range. `BFP_SHIFT` is reported back
  so the host can scale consistently with the laptop reference.
- **Parallelism**: one FFT core ≈ 24–40 DSPs of 784 → instantiate several and
  process multiple lines concurrently.

## Build flow (Libero SoC + SmartHLS)
1. **Generate twiddles**: produce `TW_RE[]`/`TW_IN[]` ROMs for the chosen NFFT.
2. **HLS**: `shls` build of the kernels (or instantiate CoreFFT instead of
   `fft1d`). Verify with C/RTL co-simulation against the CPU golden output
   (`host` numpy backend) using the speckle-smoothed correlation check.
3. **Libero**: build the fabric design — accelerator + `CoreAXI4DMAController`
   (or a SmartHLS datamover) + AXI4-Lite control, connected to the SoC's
   **cache-coherent** AXI port (FIC). Add the FFT cores' DSP/RAM.
4. **Place/route/timing** at the chosen fabric clock (~150 MHz target).
5. Export the bitstream and program the board via the embedded **FlashPro6 on
   J33**. The U54_1 bare-metal firmware drives the kernels over the MSS FIC0
   AXI4-Lite slaves (no Linux, no device-tree/UIO/CMA — JTAG-only).

## Host integration
The fabric is driven by **bare-metal RISC-V firmware on U54_1**, which writes the
AXI4-Lite control registers over MSS FIC0, sets the shared DDR buffer addresses
(signal/KR/KC/tanphi/window), starts each kernel, polls done, and reads the
detected image back. The host PC stages DDR and reads results over JTAG; the rest
of the pipeline (parse, table prep, geocode, GeoTIFF) is unchanged host code in
`host/sar_pipeline.py`.

## Verification oracle
The CPU reference (`--backend numpy`) is **pixel-identical to the laptop
reference** `src/form_image_pfa.py`. Use its detected GeoTIFF as golden and
compare the FPGA output with the same metric used during bring-up (smoothed
correlation r → 1.0 modulo fixed-point, plus a point-target PSLR check).
