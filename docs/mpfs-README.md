# MPFS port — embedded SAR focuser for the PolarFire SoC Icicle Kit

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`PROJECT_SOURCE_OF_TRUTH.md`](PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". The `CoreAXI4DMAController 2.2.107` and the "DMA control slave" referenced below are
> stale — the DMA deadlocked on the 2nd back-to-back S2MM transaction and was replaced by the
> `fft_unloader` HLS kernel (AXI4-Stream slave → AXI4 write master). Fabric-level change; firmware unchanged.

> ⚠ **Status (2026-06-30):** the design is built, programmed and silicon-verified
> on the Icicle Kit (**MPFS250T_ES**, **bare-metal RISC-V on U54_1, JTAG-only**;
> programmed via the embedded **FlashPro6 on J33**). The control plane, the data
> plane (fix = `sar_axi_idconv.v` AXI ID converter) and the DMA control slave (fix
> = CIC `TARGET5_TYPE=1` AXI4-Lite + address slice) are all verified on silicon;
> only the full DMA *transfer* test and bulk JTAG transport remain open. **The
> Linux / UIO / CMA / storage-to-storage deployment model described below is
> SUPERSEDED** — see [`fpga/AMBA_ARCHITECTURE.md`](fpga/AMBA_ARCHITECTURE.md) for
> the built design and [`fpga/SAR_BRINGUP_REPORT.md`](fpga/SAR_BRINGUP_REPORT.md)
> for the silicon report.

CPU + FPGA co-design that runs the `form_image_pfa.py` workload on the
**MPFS-Icicle-Kit-ES**. The board runs **bare-metal RISC-V** firmware on U54_1
and is driven **over JTAG only** (no network, no SD/storage medium): host-staged
I/Q is focused on-board and read back over JTAG.

```
host: *_CPHD.cphd (+ _METADATA.json)            host: *_detected.tif
        │                                                ▲
   [host] parse + build tables                           │
        │              ┌──────── shared LPDDR4 ────────┐ │
        └──► signal ──►│  [FPGA] resample→window→FFT   │ │
                       │         →corner-turn→FFT→detect│ │
                       └────────────► detected ─────────┘ │
                                 [host] geocode + GeoTIFF ─┘
```
(host PC ↔ board over JTAG; DDR staged and read back over JTAG.)

The laptop reference [`src/form_image_pfa.py`](../src/form_image_pfa.py) stays
the **algorithm source of truth**; this port reuses it (it is *not* duplicated)
and adds the host/JTAG staging, the CPU/FPGA partition, and the FPGA kernels.

## Layout
```
mpfs/
├── host/                 # host PC side (Python, drives the board over JTAG)
│   ├── sar_pipeline.py   #   stage I/Q → tables → focus → geocode → read-back
│   └── accel.py          #   accelerator seam: NumpyBackend (CPU) | FpgaBackend (fabric)
├── fpga/                 # FPGA side (HLS templates + build/integration docs)
│   ├── sar_accel_top.cpp #   on-fabric datapath skeleton  (UNVERIFIED template)
│   ├── fft1d.cpp         #   streaming BFP FFT kernel      (UNVERIFIED template)
│   └── README.md         #   Libero/SmartHLS flow, DMA/coherent port, verification
└── regmap.md             # AXI4-Lite control register map (host <-> fabric contract)
```

## What works today vs. what's a template
- **Works & verified:** the CPU host path (`--backend numpy`) runs end-to-end
  and is **pixel-identical** to the laptop reference's GeoTIFF. This is also the
  CPU-only fallback mode (slow, but correct).
- **Built & silicon-verified:** the fabric design — the 5-kernel SmartHLS model
  (corner-turn / window / detect / resample / fft-feeder) + **CoreFFT 8.1.100** +
  **CoreAXI4DMAController 2.2.107** on two **CoreAXI4Interconnect 3.0.130**
  instances. Control plane, data plane (`sar_axi_idconv.v`), and DMA control slave
  (CIC `TARGET5_TYPE=1`) are verified on the Icicle Kit; full DMA *transfer* test
  and bulk JTAG transport remain open. See [`fpga/AMBA_ARCHITECTURE.md`](fpga/AMBA_ARCHITECTURE.md)
  and [`fpga/SAR_BRINGUP_REPORT.md`](fpga/SAR_BRINGUP_REPORT.md).
- **Still templates:** the standalone HLS source `fpga/sar_accel_top.cpp` and
  `fpga/fft1d.cpp` remain unsynthesized — they are the dataflow spec, not the
  built design (which uses the per-kernel SmartHLS model + CoreFFT above).

## Run (CPU reference — works on laptop or host PC)
```bash
# single scene
python mpfs/host/sar_pipeline.py --in <path>/..._CPHD.cphd --out mpfs/output --backend numpy
```
`--backend fpga` drives the silicon-verified fabric over JTAG (host PC ↔ board);
the rest of the command is identical.

## Why this partition
The 2-D FFT dominates compute and is what the U54 cores are worst at (600 MHz,
no SIMD); it maps cleanly onto the fabric's 784 DSP blocks. The CPU keeps the
I/O, parsing, geometry/table prep, map projection, and GeoTIFF encoding it is
already fine at. Across a batch of scenes, the read / focus / encode stages
pipeline so both engines stay busy. See [fpga/README.md](fpga/README.md) and
[regmap.md](regmap.md) for the hardware details.
