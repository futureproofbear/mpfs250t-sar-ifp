# sarProcessor

SAR image formation from **Umbra CPHD** (compensated phase history data), in two
implementations:

1. **Laptop reference** (`src/form_image_pfa.py`) — downloads a public Umbra
   open-data CPHD, focuses it with the Polar Format Algorithm, and writes a
   detected, geocoded GeoTIFF. This is the golden reference.
2. **On-silicon SAR processor** (`mpfs/`) — the same pipeline running on a
   **PolarFire SoC** FPGA (MPFS250T_ES / Icicle Kit): keystone resample, window,
   range FFT, corner-turn, azimuth FFT, and detection, streaming DDR-to-DDR.
   Range/azimuth FFTs run on the fabric **CoreFFT**; the MSS RISC-V cores drive
   the pipeline and do the final detect.

**Status:** the full deci-1 Centerfield scene has been focused **end-to-end on
silicon** (RETURN=0, ~162 s), and the 8192² image reconstructed from DDR matches
the reference scene-for-scene (river, field parcels, pivot-irrigation circles,
roads) — ~0.97 correlation on the decimated scene, speckle-limited at full
single-look resolution. See [`docs/fpga/SAR_ARCHITECTURE_REPORT.md`](docs/fpga/SAR_ARCHITECTURE_REPORT.md)
for the architecture, per-stage fabric resource usage, and validation results.

## Layout

```
sarProcessor/
├── src/
│   └── form_image_pfa.py     # laptop PFA pipeline (download → focus → detect → geocode)
├── mpfs/                      # PolarFire SoC implementation
│   ├── fpga/                  # Libero design, HLS kernels (resample/window/detect), CoreFFT feeder
│   └── host/                  # JTAG load/run/dump scripts + bit-accurate silicon emulator
│       ├── silicon_emulator.py    # fixed-point mirror of the on-silicon datapath (== golden)
│       ├── stitch_silicon_deci1.py# reconstruct + correlate the dumped 8192² OUT
│       └── render_quarters.py      # per-quarter / stitched image render of silicon OUT
├── docs/
│   └── fpga/                  # architecture report, runbooks, silicon test procedures
├── data/                      # local mirror of the Umbra S3 bucket layout (git-ignored)
└── output/                    # generated products (images, .npy — git-ignored)
```

Paths are anchored to the project root, so scripts run the same from any working
directory.

## Run — laptop reference

```bash
python src/form_image_pfa.py
```

First run downloads the ~196 MB CPHD into `data/` (anonymous HTTPS, no AWS
credentials); later runs reuse the cache. The script prints a measured
resource/time estimate before any heavy compute.

Key knobs at the top of `src/form_image_pfa.py`:
- `MODE` — `"pfa"` (geometrically correct, ~12 s) or `"quicklook"` (single 2-D FFT, ~7 s)
- `DECIMATE_PULSE` / `DECIMATE_SAMPLE` — trade resolution for speed
- `ESTIMATE_ONLY` — print the estimate and stop
- `SAVE_GEOTIFF`, `OUT_TIF`, `GEO_EPSG`, `FLIP_COL/ROW` — detected GeoTIFF output

## Run — silicon emulator (board-free)

```bash
python mpfs/host/silicon_emulator.py            # both scenes, board config (deci 8, grid 8192)
```

Bit-accurate fixed-point mirror of the FPGA datapath — predicts exactly what the
board produces, and forms focused images without hardware. On-silicon bring-up,
JTAG load/run/dump, and test procedures are documented under
[`docs/fpga/`](docs/fpga/).

## Requires

Laptop pipeline: `numpy`, `scipy`, `matplotlib`, `sarpy`, `rasterio`, `pyproj`.
Emulator/host tools: `numpy`, `pillow`. On-silicon build/bring-up uses Microchip
Libero + SoftConsole and a FlashPro6 (see `docs/fpga/`).
