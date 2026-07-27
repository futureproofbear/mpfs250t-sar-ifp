# mpfs250t-sar-ifp

SAR (synthetic aperture radar) image formation from **Umbra CPHD** (compensated phase history
data), in two implementations:

1. **Laptop reference** (`src/form_image_pfa.py`) — downloads a public Umbra open-data CPHD,
   focuses it with the Polar Format Algorithm, and writes a detected, geocoded GeoTIFF. This is
   the golden reference.
2. **On-silicon SAR processor** (`mpfs/`) — the same pipeline running on a **PolarFire SoC**
   FPGA (MPFS250T_ES / Icicle Kit): keystone resample, window, range FFT, corner-turn, azimuth
   FFT, and detection, streaming DDR-to-DDR. Range/azimuth FFTs run on the fabric **CoreFFT**
   hard IP; the MSS RISC-V cores drive the pipeline.

**Status:** the full deci-1 Centerfield scene focuses **end-to-end on silicon** in current
best case ~37.7 s (100 MHz), scene loaded from the board's own eMMC (no host JTAG data load),
and the reconstructed 8192² image matches the reference scene-for-scene (0.9923 correlation vs.
golden, speckle-limited at full single-look resolution).

## Start here

| I want to... | Read |
|---|---|
| Bring up the board, load data, build/program the latest bitstream, run it, and verify the output | **[`docs/USER_GUIDE.md`](docs/USER_GUIDE.md)** |
| Understand the algorithm, how it was ported from Python to fabric, and what was optimized (and by how much) | **[`docs/SAR_IMPLEMENTATION_RECORD.md`](docs/SAR_IMPLEMENTATION_RECORD.md)** |
| Get the detailed as-built design reference (fixed-point contracts, memory map, register semantics, diagrams) | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Work on this repo with an AI coding agent | [`docs/PROJECT_SOURCE_OF_TRUTH.md`](docs/PROJECT_SOURCE_OF_TRUTH.md) (authoritative index for an LLM, including §10 on the AI agent framework) |
| Go deep on FPGA architecture (interconnect topology, HLS gotchas, headless build internals) | [`docs/fpga/`](docs/fpga/) |

## Layout

```
mpfs250t-sar-ifp/
├── src/
│   └── form_image_pfa.py     # laptop PFA pipeline (download → focus → detect → geocode)
├── mpfs/                      # PolarFire SoC implementation
│   ├── fpga/                  # Libero design, HLS kernels (resample/window/detect), CoreFFT feeder
│   └── host/                  # JTAG load/run/dump scripts + bit-accurate silicon emulator
│       ├── silicon_emulator.py    # fixed-point mirror of the on-silicon datapath (== golden)
│       ├── stitch_silicon_deci1.py# reconstruct + correlate the dumped 8192² OUT
│       └── render_quarters.py      # per-quarter / stitched image render of silicon OUT
├── docs/
│   ├── USER_GUIDE.md          # operate the board: bring-up, load, build+program, run, verify
│   ├── SAR_IMPLEMENTATION_RECORD.md           # algorithm, staged fabric port, optimization history
│   └── fpga/                  # deep architecture reference, runbooks, silicon test procedures
├── data/                      # local mirror of the Umbra S3 bucket layout (git-ignored)
└── output/                    # generated products (images, .npy — git-ignored)
```

Paths are anchored to the project root, so scripts run the same from any working directory.

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

## Quick run — laptop reference

```bash
python src/form_image_pfa.py
```

First run downloads the ~196 MB CPHD into `data/` (anonymous HTTPS, no AWS credentials); later
runs reuse the cache. See [`docs/SAR_IMPLEMENTATION_RECORD.md`](docs/SAR_IMPLEMENTATION_RECORD.md) for the algorithm this
implements and the knobs at the top of the script.

## Quick run — silicon emulator (board-free)

```bash
python mpfs/host/silicon_emulator.py            # both scenes, board config (deci 8, grid 8192)
```

A bit-accurate fixed-point mirror of the FPGA datapath — predicts exactly what the board
produces, without hardware. For actual on-board bring-up, data loading, building, running, and
verification, see [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md).

## Requires

Laptop pipeline: `numpy`, `scipy`, `matplotlib`, `sarpy`, `rasterio`, `pyproj`.
Emulator/host tools: `numpy`, `pillow`. On-silicon build/bring-up uses Microchip Libero +
SoftConsole and a FlashPro6 (see [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md)).
