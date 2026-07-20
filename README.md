# sarProcessor  ·  repo `mpfs250t-sar-ifp`

> **▶ 2026-07-14 status (newest — supersedes the status note below for repo layout + eMMC).**
> This repo is now **standalone `mpfs250t-sar-ifp`** — it builds and runs on its own, no sibling
> `sarProcessor` checkout needed. The **on-board eMMC pipeline (M1–M3) is proven on silicon**: a CPHD scene
> is stored on the board eMMC, loaded eMMC→DDR (81.5 s, retiring the ~3 h JTAG scene load) and focused
> on-board (`sar_form_image` → SAR_SEQ_OK; focused image confirmed via an ROI crop), and the output is
> persisted back to the card. Current status + recipe:
> [`docs/PROJECT_SOURCE_OF_TRUTH.md`](docs/PROJECT_SOURCE_OF_TRUTH.md) and
> [`docs/fpga/SILICON_ISO_TEST_RUNBOOK.md`](docs/fpga/SILICON_ISO_TEST_RUNBOOK.md) § eMMC M1/M2/M3. See also
> [`docs/AI_FABRIC_FIRMWARE_FRAMEWORK.md`](docs/AI_FABRIC_FIRMWARE_FRAMEWORK.md) (AI-assisted workflow).

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
silicon** (`SAR_SEQ_OK`, **88.1 s**, measured 2026-07-20 — scene loaded from the
board's own eMMC in 81.5 s, no host JTAG data load), and the 8192² image reconstructed from DDR matches
the reference scene-for-scene (river, field parcels, pivot-irrigation circles,
roads) — 0.9923 correlation vs the golden, speckle-limited at full
single-look resolution. See [`docs/fpga/SAR_ARCHITECTURE_REPORT.md`](docs/fpga/SAR_ARCHITECTURE_REPORT.md)
for the architecture, per-stage fabric resource usage, per-stage timing (§5, the single numeric source
of truth) and validation results, and [`docs/SAR_DESIGN.md`](docs/SAR_DESIGN.md) for the detailed
current design.

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

## Configuration — paths are relative; only external tools are pinned

Nothing in this repo hard-codes a user or a checkout location. Every script derives the repo
root from its own location, so you can clone or move it anywhere:

| Language | How the root is found |
|---|---|
| shell (`.sh`) | `source .../mpfs/host/lib/sar_env.sh` → `$SAR_ROOT`, `$SAR_FPGA`, `$SAR_SCRATCH` |
| Libero (`.tcl`) | `source .../mpfs/fpga/lib/sar_env.tcl` → `$SAR_ROOT`, `$SAR_FPGA` |
| gdb (`.gdb`) | paths are **relative to `mpfs/host/jtag_full`** (the `run_*.sh` drivers `cd` there) |
| openocd (`.cfg`) | `$env(SAR_ROOT)` (inherited from the calling script) |
| Python | repo root derived from `__file__` |

Only **external tool installs** need pinning, in [`config.yaml`](config.yaml) under `toolchain:`
(Libero, SoftConsole, openocd, Python, vault, license) plus `board:` (UART port, scratch dir).

**Set your machine's paths in `config.local.yaml`** — it is git-ignored and overrides
`config.yaml` key-by-key, so your local paths are never committed:

```yaml
# config.local.yaml
toolchain:
  openocd:      C:/Users/me/Tools/openocd-new/xpack-openocd-0.12.0-4
  license_file: C:/Users/me/polarfire-soc/License.dat
```

Scripts fail fast with a clear message if a tool path is missing or still a `<you>` placeholder.

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
