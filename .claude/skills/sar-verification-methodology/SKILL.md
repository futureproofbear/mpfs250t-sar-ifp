---
name: sar-verification-methodology
description: >-
  How to verify SAR datapath correctness without chasing phantoms — prefer VALUE-level testing over
  correlation, build a bit-accurate fixed-point emulator that equals the float golden, watch for the
  golden-ORIENTATION artifact, and use board-free phase-exact (complex-ratio) checks. Load before
  claiming a stage is correct/broken or before debugging a "it doesn't match golden" symptom.
  ALSO: before trusting any testbench result, confirm the bench instantiates the SAME parameters
  synthesis builds (§6, `mpfs/fpga/tb/check_tb_params.py`) — a passing bench on the wrong
  parameterisation proves nothing and has already cost a full board bring-up.
  Triggers: "verify the FFT/pipeline", "compare to golden", "correlation is low", "phase test",
  "emulator / silicon mirror", "orientation / transpose mismatch", "is this a real bug",
  "the bench passes but silicon is wrong", "testbench parameters".
---

# SAR verification methodology

> The vendor- and application-agnostic principle here (value-level over correlation, match a
> bit-accurate emulator to golden first, watch for orientation artifacts) is also maintained as a
> portable package: `ai-framework/generic-fpga-soc/skills/value-level-verification/`. This
> project-local skill stays authoritative for the SAR/CPHD-specific application of it.

Process rules learned from a multi-day pipeline debug that hit several false leads before the real
bug. The theme: **correlation lies; test by value; find the right orientation before declaring a
divergence.** These are target-neutral; the current tools live under `mpfs/host/`.

## 1. VALUE-level testing beats correlation — always
- Correlation (and magnitude comparison) is scale-, phase-, AND orientation-invariant. It passes even
  when the FFT is conjugated, bin-reversed, or per-row mis-scaled; a pipeline can score corr ~0
  (saturated output) OR ~1 while individual sample values are wrong. Every "it passed" that later
  proved wrong here was a correlation/magnitude check.
- Instead: feed KNOWN inputs and diff the ACTUAL complex sample values (real AND imag) against a
  bit-accurate model, element by element — report exact-match %, max abs error, and WHERE divergence
  starts.
- For a phase test use a SINGLE strong impulse (every output bin full-magnitude → quantization noise
  cannot hide a phase error). A flat or random spectrum is noise-dominated and misleading.

## 2. Build a bit-accurate emulator ("silicon mirror") and match it to golden FIRST
- Mirror the WHOLE datapath in fixed point: int16 quantize → fixed resample + window → adaptive-BFP
  FFT + per-row `SCALE_EXP` + global renorm → corner-turn → BFP azimuth FFT + renorm → fixed detect →
  uint16 saturate. (`mpfs/host/silicon_emulator.py` is the current one.)
- Validate the emulator against the FLOAT golden and require it to match (it reached corr 1.0000,
  identical peaks). ONLY THEN compare hardware to the emulator. If emulator == golden but
  hardware != emulator, you have a real hardware bug, LOCALIZED to whatever stage the emulator models
  that the hardware does differently. This is what finally pinned the detect bug.

## 3. The golden-ORIENTATION pitfall — the #1 false alarm
- Before declaring "hardware diverges from golden", find the CORRECT orientation. The hardware image is
  often the golden **transposed + fftshifted/flipped + row/column-offset** (here board ≈ fft2.T with a
  ud/lr flip and a column offset). A naive band/orientation comparison gave corr 0.06 and sent the
  investigation chasing a phantom "resample bug"; an exhaustive orientation+offset scan then found
  corr 0.97 at the right alignment — there was no resample bug.
- ALWAYS run the exhaustive scan (all 8 transposes/flips × row/col offsets) before concluding a
  divergence is real. A fixed candidate-orientation list is not exhaustive; trust it only after the
  scan agrees.
- Byte-offset trap: complex buffers are 4 B/px, uint16 OUT is 2 B/px → the same byte offset is a
  different row. Compute row addresses explicitly.

## 4. Board-free phase-exact check (complex-ratio test)
- A magnitude iso-test is phase- and scale-invariant — blind to conjugation / bin-reversal / phase
  error. To prove an FFT is phase-exact WITHOUT hardware: drive a single strong impulse through the
  real IP in simulation, dump the complex output, and compute the **complex ratio `core/golden` on the
  strong bins**. A correct FFT gives `|ratio|` = a single constant (the scale, e.g. 2^−SCALE_EXP) and
  `angle(ratio)` = a single constant (the convention). Conjugate / bit-reversed / wrong-sign variants
  show ~100° phase spread.
- This cleared the whole FFT chain (feeder → FFT → gearbox → unloader) + scaling board-free, so a
  later pipeline corr~0 could be attributed elsewhere (it was detect). Do the cheap board-free proof
  before spending board time.

## 5. Isolation tactics
- **CPU/reference fallback for a suspect hardware kernel:** reimplement the suspect stage on the
  control processor behind a runtime mode flag and A/B it against the hardware version. This isolates
  the fault (if the reference version fixes the image, the fault is that kernel) AND gives a working
  fallback with no rebuild. A correct-signed CPU detect confirmed the detect bug end-to-end and shipped.
- **A/B two hardware configs** on the same input (e.g. CPU-FFT SIG vs fabric-FFT SIG scored 0.9999 →
  proved the fabric FFT was NOT the bug).

## 6. The bench must instantiate what SYNTHESIS builds — run `check_tb_params.py` FIRST

**The most expensive failure on this project to date (2026-07-29).** `sar_resample_v` passed 16/16
functional cases, a re-arm pass and a power-up pass, every one mutation-verified non-vacuous — then
produced a completely wrong image on silicon (corr **−0.04** against the known-good crop, peak 76 vs
3069). The bench was not weak. It was testing **a different module**:

| parameter | bench | silicon | what it sizes |
|---|---|---|---|
| `TAB_AW` | 14 | **13** | on-chip table depth (16384 vs 8192) |
| `BUF_AW` | 6 | **12** | source buffer (128 vs 8192 samples) |
| `MAX_BURST` | 4 | **64** | AXI beats per burst |
| `WF_AW` | 4 | **8** | write FIFO depth |

Those parameters size the exact structures the gather indexes into. Zero of the passing runs said
anything about the bitstream.

**The divergence was documented and still not caught.** `tb_sar_resample.v`'s own header records that
`TAB_AW=14` was *forced* because the module would not elaborate at its default 13 (vsim-8607,
negative replication multiplier). A later fix removed that obstruction — `sar_resample_v_top` now
elaborates clean at 13 — but the forced override was never revisited. **A comment is not a gate.**

Rules:
- **Run `python mpfs/fpga/tb/check_tb_params.py` before believing ANY bench result**, and before any
  build. It text-parses the module defaults, the synthesis wrapper's overrides and the TB's
  instantiation, and fails on any divergence — no simulator, milliseconds, no excuse to skip.
- **Register every hand-written core in its `REGISTRY`.** A core with no row is ungated, which is
  precisely the state `sar_resample_v` was in.
- If an override is genuinely unavoidable (runtime — a 8192-tile frame at full size is hours of
  simulation), then **add a second run at the silicon values** covering at least one full-scale line,
  and state in the commit which properties the small run can and cannot establish. `corner_turn_v`
  has the same gap (`GRID` 16 vs 8192, `T_LOG2` 2 vs 7) — its risk was retired by an end-to-end
  bit-exact silicon result, *not* by the bench. Know which of the two you have.
- **Mutation testing does not close this.** It proves the bench is non-vacuous for the cases it has.
  It is silent about the space it does not cover. Do not report "mutation-verified" as if it were
  coverage.
- **Scale is part of the parameterisation.** Bench `SN≤64`/`QN≤32` vs silicon `SN=4319`/`QN=8192` is
  ~128×. Anything that only appears past a few hundred samples cannot manifest.

Corollary — **never REPLACE a working kernel when you can add beside it.** `sar_resample_v` took the
SmartHLS resample's CIC target instead of a new one, so there is no A/B on the same bitstream and no
fallback: the first end-to-end evidence that existed anywhere was the final image. Keep the incumbent
reachable until the replacement is silicon-proven.

See also: `sar-pipeline-design` (the contracts being verified), `mpfs-platform-gotchas` →
`references/silicon-debug-methodology.md` (the platform-specific value-test entry points and JTAG
hygiene), and `docs/fpga/DEV_GUIDE.md` §4.
