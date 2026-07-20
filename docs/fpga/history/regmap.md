# SAR accelerator register map (AXI4-Lite, control plane)

> ⚠ SUPERSEDED (2026-06-30): this is the older monolithic host-offload register map
> (`sar_accel_top.cpp`, UIO/mmap) which is NOT the built design. The built hardware
> is the per-kernel SmartHLS model — each kernel has its own AXI4-Lite control window
> on the CIC: CT 0x60000000, WIN 0x60001000, DET 0x60002000, RES 0x60003000,
> FEED 0x60004000, DMA-ctrl 0x60005000. See docs/fpga/AMBA_ARCHITECTURE.md.

Shared contract between the CPU host (`host/accel.py::FpgaBackend`) and the
fabric accelerator (`fpga/sar_accel_top.cpp`). Offsets are from the
accelerator's AXI4-Lite base address (mapped on the host via UIO + `mmap`).

| Offset | Name            | R/W | Description |
|--------|-----------------|-----|-------------|
| 0x00   | `CTRL`          | RW  | bit0 `START` (1=launch), bit1 `RESET` |
| 0x04   | `STATUS`        | R   | bit0 `DONE`, bit1 `BUSY`, bit2 `ERR` |
| 0x08   | `IRQ_EN`        | RW  | bit0 enable done-interrupt (UIO wakeup) |
| 0x0C   | `M`             | RW  | pulses (rows) in the input signal |
| 0x10   | `N`             | RW  | samples (cols) in the input signal |
| 0x14   | `FFT_LEN_R`     | RW  | range FFT length (power of 2, padded) |
| 0x18   | `FFT_LEN_A`     | RW  | azimuth FFT length (power of 2, padded) |
| 0x1C   | `BFP_SHIFT`     | RW  | block-floating-point scale exponent out |
| 0x20   | `SIG_ADDR`      | RW  | DDR phys addr of signal buffer (complex, M*N) |
| 0x28   | `KR_ADDR`       | RW  | DDR phys addr of KR resample grid (N floats) |
| 0x30   | `KC_ADDR`       | RW  | DDR phys addr of KC resample grid (M floats) |
| 0x38   | `TANPHI_ADDR`   | RW  | DDR phys addr of per-pulse tan(phi) (M floats) |
| 0x40   | `WIN_ADDR`      | RW  | DDR phys addr of 2-D window (or two 1-D tapers) |
| 0x48   | `OUT_ADDR`      | RW  | DDR phys addr of detected output (uint8/16, M*N) |
| 0x50   | `SCRATCH_ADDR`  | RW  | DDR phys addr of corner-turn scratch buffer |

64-bit address registers occupy two 32-bit words (e.g. `SIG_ADDR` = 0x20 lo,
0x24 hi). All buffers are CMA-contiguous so the fabric DMA sees a single
physical extent.

## Handshake
1. Host fills SIG/KR/KC/TANPHI/WIN buffers, sets dims + addresses.
2. Host writes `CTRL.START=1`.
3. Fabric runs: range-resample → window → range-FFT → corner-turn →
   azimuth-resample → azimuth-FFT → detect, streaming to `OUT_ADDR`.
4. Fabric sets `STATUS.DONE` (and raises the UIO IRQ if `IRQ_EN`).
5. Host reads the detected image from `OUT_ADDR`.

## Memory ports
Use the PolarFire SoC **cache-coherent AXI port** (ACE-Lite) for zero-copy
sharing with the U54 cores, or the non-coherent FIC for peak bandwidth with
explicit cache flush/invalidate around the START/DONE handshake.
