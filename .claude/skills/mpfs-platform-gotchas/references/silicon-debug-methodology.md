# Silicon debug methodology + firmware/MSS best practices (hard-won on this project)

How to debug the SAR datapath on THIS board without chasing phantoms. These are process rules, not
chip errata — they came from a multi-day fabric-pipeline debug (2026-07) that hit several false leads
before the real bug (a SmartHLS sign-extension miscompile in detect). Load these before debugging any
fabric kernel / firmware pipeline on silicon.

## 1. VALUE-level testing beats correlation — always
- **Correlation is scale-, phase-, AND orientation-invariant.** A magnitude iso-test passes even if the
  FFT is conjugated / bin-reversed / per-row-mis-scaled. A pipeline corr can read ~0 (saturated output)
  OR ~1 while individual sample values are wrong. Every "it passed" here that later proved wrong was a
  correlation/magnitude check.
- **Feed KNOWN inputs and diff the actual complex sample VALUES** against a bit-accurate model, element
  by element (real AND imag): exact-match %, max abs error, and WHERE divergence starts. Tools built for
  this: `corefft_phase_compare.py` (complex ratio = constant ⇒ correct FFT), `fft_value_compare.py`
  (injected rows vs `fixedpoint.fft1d_bfp_hw_perrow`), `silicon_emulator.py` (full-datapath mirror).
- For a phase test use a SINGLE strong impulse (every output bin full-magnitude ⇒ quant noise can't hide
  a phase error); a flat/random spectrum is noise-dominated and misleading. [[corefft-phase-exact-boardfree]]

## 2. Build a bit-accurate SILICON MIRROR to isolate silicon bugs
- `mpfs/host/silicon_emulator.py` mirrors the WHOLE datapath in fixed point (int16 quantize → fixed
  resample+window → adaptive BFP FFT + SCALE_EXP renorm → corner-turn → fixed detect). Validate it
  against the float golden FIRST (it matched at **corr 1.0**); THEN compare silicon to the mirror. If
  mirror==golden but board!=mirror ⇒ a real silicon bug, localized to whatever stage the mirror models
  that the board does differently. This is what finally pinned detect. [[silicon-mirror-emulator]]

## 3. The GOLDEN-ORIENTATION gremlin — the #1 false-alarm source
- Before declaring "silicon diverges from golden", find the CORRECT orientation: the board image is
  often the golden **transposed + fftshift/flipped + column-offset** (board = fft2.T here). A naive
  band/orientation comparison gave corr 0.06 and sent me chasing a phantom "resample bug"; an exhaustive
  orientation+offset scan then found **corr 0.97** at the right alignment. ALWAYS run the exhaustive
  scan (all transposes/flips + row/col offsets) before concluding a divergence is real.
- `correlate_cpufft.py`'s fixed candidate list is NOT exhaustive — trust it only after the scan agrees.
- Buffer byte-offset trap: complex buffers are 4 B/px, the uint16 OUT is 2 B/px, so the SAME byte offset
  = DIFFERENT rows. Compute row addresses explicitly (`base + row*GRID*bytes_per_px`).

## 4. JTAG / gdb board hygiene (avoid wedging the fabric)
- **NEVER external-`timeout`/SIGTERM a gdb mid-JTAG.** It wedges the FABRIC (a kernel stuck mid-AXI). A
  hart `reset halt` does NOT reset the fabric → the wedge persists → needs a **power-cycle or reprogram**.
  Symptom: the next clean run's `fft_pass`/pipeline never completes (mailbox stuck) though it worked before.
- **Run board jobs in the BACKGROUND** so they self-terminate cleanly via their own `monitor shutdown`
  (no external kill). Poll the gdb logfile for progress, not the process.
- This gdb build (SoftConsole riscv64 8.3.0) **crashes on `call <fn>` (find_inferior_pid assertion) if
  the hart is mid-execution** (e.g. a poll loop timed out). Guard every `call flush_l2_cache` / inferior
  call behind a `$done` check so it only runs when the hart is cleanly halted at the completion flag.
- FIC0 is NON-COHERENT: `flush_l2_cache(1)` before reading fabric-written DDR; a raw JTAG read may return
  stale L2. But the pipeline already flushes at its end, so a raw read of an untouched buffer is usually OK.

## 5. Firmware value-test entry points (no fabric rebuild needed)
- 'FTES' (0x46544553) = `sar_fft_pass_test` runs `fft_pass(BUF_SIG→BUF_SCRATCH)` on PRE-LOADED SIG — the
  clean way to inject a KNOWN FFT input over JTAG and read back the result. Prefer it over 'SCLE'
  (0x53434C45, `sar_fabric_scale_test`) which zeroes 268 MB on-chip first (slow, and hung the wedged fabric).
- Mailbox @0xB0058000: cmd; result @0xB005800C; status @0xB0058010 == 0xC0FFEE03 (MBX_DONE_MAGIC) = done.
- Runtime knobs (JTAG-pokeable, no reflash): fft_mode @0xB0059110 (0=CPU,1=fabric), headroom @0xB0059114,
  **detect_mode @0xB0059118 (1 = CPU detect, correct sqrt — the fabric-detect-bug fallback)**,
  per-stage MTIME timing in `sar_stage_ts[0..6]` (1 MHz → µs). Read `sar_row_exp[]` for captured CoreFFT exps.
- CoreFFT SCALE_EXP ≠ `fixedpoint` block exponent — CoreFFT does ~unconditional 1/N scaling; its
  SCALE_EXP reports a different (smaller) quantity. Don't compare `sar_row_exp` to `fft1d_bfp` exps.

## 5a. CPU-FALLBACK pattern — isolate a suspect fabric kernel WITHOUT a rebuild
- When an HLS fabric kernel is suspect, reimplement it on the MSS CPU behind a runtime mode flag
  (e.g. `detect_mode`, `fft_mode`) and A/B it against the fabric version. This does two things at once:
  (a) ISOLATES the bug — if the CPU version fixes the image, the fault is in that fabric kernel;
  (b) gives a WORKING FALLBACK on silicon immediately (no ~1-2 h fabric rebuild to prove the fix).
  `cpu_detect` (correct signed sqrt) confirmed the detect sign-ext bug end-to-end → board hit corr
  0.97 with fabric-FFT + CPU-detect, before touching the fabric. GCC compiles the sign-extension the
  SmartHLS synthesis got wrong, so the CPU version is also the reference for what the fabric SHOULD do.
- Coherency for a CPU-side kernel reading fabric-written DDR: `flush_l2_cache(1)` before the read
  (evict stale L2) and after the write (push result to DDR for the next kernel / JTAG readback).

## 6. SAR image display (not a datapath concern, but expected differences vs Umbra GEC)
- Our output is SINGLE-LOOK raw magnitude; Umbra's GEC is multi-looked + geocoded + 8-bit display-tuned.
  The speckle difference is single-look, not a bug (fixed-point matches float at corr 0.9992).
- Display: `fftshift` (center DC, kill the edge band) + **dB stretch** (20·log10, ~28 dB window, mild
  gamma) — NOT `log1p` (over-brightens the speckle floor). Both are display-only in `silicon_emulator.py`.
