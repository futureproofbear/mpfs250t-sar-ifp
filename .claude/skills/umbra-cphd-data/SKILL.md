---
name: umbra-cphd-data
description: >-
  The Umbra open-data CPHD input for the SAR pipeline — S3 layout, the CF8 complex-float format,
  where the array dimensions actually live (the CPHD XML header, NOT METADATA.json), typical sizes
  for buffer/FFT sizing, and the decimation knobs. Load when ingesting/sizing CPHD input or reading
  array dimensions. Triggers: "CPHD", "Umbra open data", "NumVectors / NumSamples", "phase history
  dimensions", "range-FFT length / buffer sizing", "CF8", "how big is a capture".
---

# Umbra CPHD input data

Phase-history input for the SAR image former. Target-neutral: these are properties of the DATA, not
of any processing target.

## Source + layout
- `s3://umbra-open-data-catalog` (us-west-2, public HTTP, no auth). Path:
  `sar-data/tasks/<task>/<uuid>/<timestamp>_UMBRA-NN/`. Each capture has `CPHD.cphd` + `GEC.tif` +
  `SICD.nitf` + `SIDD.nitf` + `METADATA.json`.
- Catalog measured 2026-07: **4,072 CPHD files, ~34 TB** raw signal. All sampled files were uniformly
  single-channel, **SPOTLIGHT, X-band, format CF8** (complex float32 I/Q, 8 bytes/sample) — no
  integer/compressed formats.

## Where the array dimensions live (important)
- Array dims are **NOT in METADATA.json** (that holds collect geometry only). They live in the CPHD
  file's own XML metadata header. The file starts with an ASCII header
  (`XML_BLOCK_BYTE_OFFSET`/`_SIZE`, `SIGNAL_BLOCK_SIZE`, …) then an XML block:
  `<Data><Channel><NumVectors>N</NumVectors><NumSamples>M</NumSamples>`.
- Read them with a single HTTP range GET of the first ~20 KB — no need to download the multi-GB signal
  block.
- `NumSamples` = samples per vector = fast-time / range-frequency (FX-domain) bins.
- `NumVectors` = phase-history vectors = radar pulses = slow-time / azimuth.
- Sanity check (held 100 % of sampled files): `SIGNAL_BLOCK_SIZE == NumVectors × NumSamples × 8`.

## Typical sizes (for buffer / FFT-length sizing)
Measured over a random ~477-file sample of the catalog:
- **NumSamples/vector:** min 3,839 · p25 16,000 · median 22,499 · p75 60,984 · p95 143,748 · max
  258,048. Modal band 16k–24k. Common canonical values: 16875, 21599, 22499, 15999, 23999, 17999.
- **NumVectors:** min 4,346 · median 18,632 · p95 44,143 · max 203,449.
- Mean signal block ~8.5 GB.
- Sizing implication: a representative range line is ~16k–24k complex samples, worst case ~258k. This
  bounds range-FFT length and per-vector buffer depth. The current implementation grids to an 8192²
  frame; a full capture is decimated down to it.

## Decimation knobs
- The current tooling exposes a decimation factor (`deci`) and a grid size (`grid`, e.g. 8192). A
  small-scene bring-up run uses deci 8 / grid 8192; a full-resolution run uses deci 1. Choose deci so
  the decimated capture fits the target grid.

See `sar-pipeline-design` for how these dimensions feed the FFT/buffer contracts, and
`docs/fpga/SAR_ARCHITECTURE_REPORT.md` §1 for the as-built frame size.
