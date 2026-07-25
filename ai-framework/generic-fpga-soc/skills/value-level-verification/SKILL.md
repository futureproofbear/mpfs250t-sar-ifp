---
name: value-level-verification
description: >-
  How to verify a signal-processing or datapath pipeline's correctness without chasing phantoms --
  prefer VALUE-level testing over correlation/magnitude comparison, build a bit-accurate fixed-point
  emulator that matches a float golden reference FIRST, watch for the golden-ORIENTATION artifact
  when comparing image/array outputs, and use implementation-free phase-exact (complex-ratio) checks
  before spending hardware time. Load before claiming a pipeline stage is correct/broken, or before
  debugging a "it doesn't match golden" symptom. Triggers: "verify the pipeline", "compare to
  golden", "correlation is low", "phase test", "emulator / hardware mirror", "orientation / transpose
  mismatch", "is this a real bug".
---

# Value-level verification

The theme: **correlation lies; test by value; find the right orientation before declaring a
divergence.** This methodology is vendor- and application-neutral — it applies to any pipeline that
transforms arrays or signals through multiple fixed-point stages (a DSP chain, an image-formation
pipeline, a codec, a filter bank) and is checked against a floating-point or software golden
reference.

## 1. VALUE-level testing beats correlation — always
- Correlation (and plain magnitude comparison) is scale-, phase-, AND orientation-invariant. It
  passes even when a transform stage is conjugated, bin-reversed, or per-row mis-scaled; a pipeline
  can score correlation near 0 (e.g. a saturated output) OR near 1 while individual sample values are
  still wrong. Any "it passed" that later proves wrong was very likely a correlation/magnitude check
  and nothing more discriminating.
- Instead: feed KNOWN inputs and diff the ACTUAL output values (both real and imaginary components,
  if complex) against a bit-accurate model, element by element — report exact-match percentage,
  maximum absolute error, and WHERE the divergence starts.
- For a phase-sensitive test, use a SINGLE strong impulse so every output bin is full-magnitude and
  quantization noise cannot hide a phase error. A flat or random input spectrum is noise-dominated
  and will hide the same bug a value-level check would catch.

## 2. Build a bit-accurate emulator ("hardware mirror") and match it to the golden FIRST
- Mirror the WHOLE datapath, stage by stage, in the same fixed-point/scaling scheme the hardware
  uses (quantization, fixed-point arithmetic at each stage, any block-floating-point rescaling,
  saturation at the output).
- Validate the emulator against the FLOATING-POINT golden reference and require it to match closely
  (e.g. correlation effectively 1.0, identical peak locations) before comparing anything to hardware.
- ONLY THEN compare hardware output to the emulator, not to the float golden directly. If the
  emulator matches golden but hardware does not match the emulator, that is a real hardware bug,
  LOCALIZED to whichever stage the emulator models differently from what the hardware actually does
  — a much smaller search space than "hardware disagrees with float golden."

## 3. The golden-ORIENTATION pitfall — the most common false alarm
- Before declaring "hardware diverges from golden," find the CORRECT orientation/alignment first.
  Array/image outputs are frequently the golden reference **transposed and/or flipped and/or offset**
  by some fixed row/column amount relative to how the golden reference is laid out — a naive direct
  comparison can score very low correlation and send an investigation chasing a phantom bug in an
  earlier stage, when an exhaustive orientation-and-offset scan reveals a high-correlation match at
  a different alignment (i.e. there was no bug at all — just a comparison-orientation mismatch).
- ALWAYS run the exhaustive scan (all relevant transposes/flips crossed with row/column offsets)
  before concluding a divergence is real. A hand-picked list of "likely" orientations is not
  exhaustive; trust a "no match" result only after the full scan agrees.
- Byte-offset trap: if different stages of the pipeline use different sample widths (e.g. a complex
  intermediate buffer at 4 bytes/sample versus a final output at 2 bytes/sample), the same byte
  offset denotes a DIFFERENT logical row/element at each stage. Compute element/row addresses
  explicitly per stage rather than reusing a byte offset across stages.

## 4. Implementation-free phase-exact check (complex-ratio test)
- A magnitude-only check is phase- and scale-invariant — blind to conjugation, bin-reversal, or a
  constant phase error. To prove a complex transform stage is phase-exact WITHOUT full hardware
  bring-up: drive a single strong impulse through the stage in simulation, dump the complex output,
  and compute the complex ratio (stage-output / golden) on the strong bins.
- A correct stage gives a CONSTANT `|ratio|` (the scale factor) and a CONSTANT `angle(ratio)` (the
  phase convention) across those bins. Conjugated, bit-reversed, or wrong-sign variants show a wide
  phase spread instead of a single constant angle.
- Do this cheap, implementation-free proof before spending hardware/board time — it can clear an
  entire multi-stage transform chain (and its associated scaling) so that a later end-to-end
  divergence can be confidently attributed to a different, later stage.

## 5. Isolation tactics
- **Software/CPU reference fallback for a suspect hardware stage:** reimplement the suspect stage in
  software (behind a runtime mode flag) and A/B it against the hardware version on the same input.
  This both isolates the fault (if the reference version fixes the output, the fault is in that
  hardware stage) and gives a working fallback with no rebuild required.
- **A/B two implementations of the same stage** on identical input (e.g. a software transform versus
  a hardware transform feeding the same downstream pipeline) to prove or clear a specific stage
  before looking elsewhere.

See also: `reference-first-verification` (verifying the IP/RTL contracts being exercised here),
`kernel-isolation-testing` (isolating a single stage on hardware to run these checks against it).
