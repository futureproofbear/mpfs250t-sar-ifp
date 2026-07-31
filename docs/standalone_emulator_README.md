# SAR Polar-Format Image Formation — standalone Python emulator

Forms a focused SAR image from an Umbra **CPHD** phase-history file, entirely in Python. No FPGA,
no board, no vendor toolchain.

Two pipelines live here and they are meant to be compared:

| | what it is |
|---|---|
| **float reference** | plain `float64` PFA — the algorithm as written |
| **bit-accurate mirror** | reproduces the FPGA datapath exactly: `int16` truncation, Q15 weights, block-floating-point FFT exponents, saturating detect |

The mirror is not an approximation of the hardware. It is bit-exact against it, which is what makes
it usable as the reference a silicon run is scored against.

---

## 1. Install

Python 3.9+.

```bash
python -m venv venv
venv/Scripts/activate        # Windows;  source venv/bin/activate on Linux/macOS
pip install -r requirements.txt
```

`sarpy` is the only unusual dependency — it is the CPHD reader. `scipy` and `pyyaml` are optional
(each has a fallback or serves a side path).

## 2. Get a CPHD (you supply this — no data ships with this folder)

The datasets are free from Umbra's open-data bucket. Anonymous HTTPS, no AWS account:

```
https://umbra-open-data-catalog.s3.amazonaws.com/sar-data/tasks/<task>/<collect>/<file>_CPHD.cphd
```

Two collects this pipeline is known to work on:

| scene | collect | CPHD size |
|---|---|---|
| Centerfield, Utah | `2023-10-10-16-57-44_UMBRA-04` | 188 MB |
| NDSU, Fargo ND | `2023-11-10-16-16-44_UMBRA-04` | 590 MB |

Browse the catalog at <https://registry.opendata.aws/umbra-open-data/>, or use the bundled helper:

```bash
python fetch_data.py <url> --out data/
```

> CPHD files are large and the download is the slow part. Grab one and keep it.

## 3. Run

```bash
# quick smoke test -- confirms the install works (heavily decimated, speckly by design)
python silicon_emulator.py --cphd path/to/scene_CPHD.cphd --deci 16 --grid 1024 --outdir ./output

# full resolution, both 32-tap sinc interpolators (the shipping configuration)
python silicon_emulator.py --cphd path/to/scene_CPHD.cphd --grid 8192 \
       --range-sinc --az-sinc --outdir ./output
```

Useful flags:

| flag | meaning |
|---|---|
| `--cphd PATH` | the input file (overrides the built-in scene table) |
| `--grid N` | output grid, `N x N`. **8192 is the real configuration**; smaller is for quick checks |
| `--deci D` | decimate pulses/samples by `D` — much faster, lower fidelity |
| `--range-sinc` | 32-tap polyphase sinc in the range pass (else 2-tap linear) |
| `--az-sinc` | 32-tap polyphase sinc in the azimuth pass |
| `--outdir DIR` | where results go. **Pass this.** The default is inherited from the parent project's layout and, in this standalone folder, resolves *above* the folder — somewhere you did not choose |

`--deci` is a fidelity knob, not just a speed knob: at `--deci 16` you keep 1/16 of the pulses and
samples, so the result is dominated by speckle with only faint structure. That is expected, and is
fine for confirming the install works. Use `--deci 1` for an image worth looking at.

A full `--grid 8192` run holds several complex arrays of `8192 x 8192` — budget **~8 GB of RAM**
and tens of minutes. Start with `--deci 8 --grid 2048` to confirm your install works.

## 4. View the output

```bash
python sar_display.py out.npy -o out.png --sigma 3.0
python sar_display.py crop.bin --shape 1024 1024 -o crop.png   # raw uint16
```

`sar_display.py` applies a **normal-score** (Gaussian) contrast stretch rather than sqrt/log plus a
percentile clip. SAR magnitude is Rayleigh-ish — a long bright tail over a dense speckle floor — so
a percentile clip spends most of the 8-bit range on a narrow band of speckle. The normal-score
transform maps each pixel to its rank and pushes that through the inverse Gaussian CDF, so every
grey level carries equal information regardless of the input distribution. Exact zeros (the
zero-pad region of a partly filled grid) are excluded from the mapping.

Add `--look 8` to multilook an 8192² image down to 1024² — much easier to view, and speckle drops.

## 5. What the pipeline does

```
CPHD phase history
  -> range resample     (keystone; uniform source grid, closed-form index)
  -> azimuth resample   (non-uniform source abscissa tan(phi), merge-scan index)
  -> window             (separable Hamming, Q15)
  -> FFT-1 + FFT-2      (with a corner-turn between; block floating point)
  -> detect             (|z| -> uint16)
```

Both resample passes ask the same question — *what is the data value at output location q?* — and
blend the same way. They differ only in how the source index and fractional offset are obtained.

## 6. Files

| file | role |
|---|---|
| `silicon_emulator.py` | **entry point** — the bit-accurate mirror |
| `form_image_pfa.py` | float reference and the CPHD reader |
| `sar_pipeline.py` | `prepare_tables()` — geometry to `f0/df/pr/tan_phi/KR/KC/window` |
| `serialize_inputs.py` | `interp_coeffs()` — the index/weight quantiser |
| `gen_resample_vectors.py` | `sinc_table_q15()` — the 32-tap polyphase table |
| `fixedpoint.py` | fixed-point helpers |
| `ddr_layout.py`, `accel.py` | support modules |
| `sar_display.py` | contrast stretch and PNG output |
| `fetch_data.py` | CPHD downloader |

## 7. Caveats

- **The grid matters.** `--grid 8192` is the real configuration; results at a smaller grid are not
  directly comparable to it.
- Correlation is a weak check. It is scale-, phase- and orientation-invariant, so it hides real
  bugs. To compare two runs properly, diff actual complex sample values, and make sure both sides
  use the *same* interpolator — a 32-tap result scored against a 2-tap golden looks broken when it
  is merely different.
- This folder is generated by `scripts/make_standalone_emulator.py` in the parent project. If you
  received it standalone that is fine; just be aware that edits here do not flow back.
