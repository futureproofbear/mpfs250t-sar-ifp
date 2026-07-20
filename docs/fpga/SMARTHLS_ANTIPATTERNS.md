# SmartHLS anti-pattern catalog (living)

Code shapes and tool behaviours that SmartHLS 2025.2 on this project has been
**proven** to mis-synthesise or mis-report. This is the institutional memory that
keeps "schedule passes, silicon fails" from being rediscovered every session. It is
consumed by [`mpfs/host/hls_antipattern_lint.py`](../../mpfs/host/hls_antipattern_lint.py)
(Gate 0 of the HLS trust harness).

## Update discipline (constantly updating)

Add or amend an entry **the same session you confirm a new mis-synthesis** — with
the C trigger, the report-vs-silicon delta, and the guard. That is a project rule
(CLAUDE.md: "capture and UPDATE runbooks the same session"). An entry that is later
shown harmless gets its `severity` lowered and a note, not deletion (the negative
result is itself knowledge).

## Entry format

Human prose per entry, plus an optional machine block the linter reads:

```
<!-- LINT
id: short-kebab-id
severity: block | warn            # block => linter exits non-zero on a match
files: (informational)
pattern: <python regex>           # OMIT for a manual-review-only entry
message: one-line what/why
-->
```

Only give `severity: block` to a **high-precision** pattern (near-zero false
positives). A brittle regex that blocks the build is worse than the bug; leave
uncertain shapes as `warn`, or as a manual entry (no `pattern:`) so they print as a
review checklist instead of gating.

---

## 1. FFT radix-2 butterfly drops the twiddle term  `[block-class, manual]`

The `K_FFT` HLS kernel (`hls_fft/hls_fft.hpp` `fft_in_place_bfp`) synthesises to an
identity/passthrough on silicon: the generated RTL **contains** the 1703 multipliers
but the twiddle product never reaches the butterfly store. C-sim passes at corr
0.9999 every time; silicon output is `input >> out_shift`. Proven across three
independent FFT structures (ping-pong DoubleBuffer, explicit static ping-pong,
single-array in-place). **Resolution:** the HLS FFT was abandoned. The shipping FFT is the
fabric CoreFFT hard-IP streaming chain (`SAR_FFTMODE` @`0xB0059110` = 1); the MSS FFT
(`src/sar/sar_fft.c`) was the interim path and remains as the mode-0 fallback. See
SAR_PIPELINE_STATUS.md §"Engine history".
Guard: do not re-enable a fabric radix-2 FFT top without a board-free phase-exact
cosim (`sar-verification-methodology` §4) proving the twiddle survives.

<!-- LINT
id: twiddle-drop
severity: block
files: hls_fft/hls_fft.hpp
message: Fabric radix-2 FFT twiddle drops on silicon (C-sim lies). FFT belongs on the U54; prove twiddle survives before re-enabling.
-->

## 2. `shls cosim` C-testbench wrapper segfaults  `[tooling]`

`shls cosim` crashes `0xC0000005` regardless of testbench code, so RTL cosim could
not be used to debug the twiddle drop — only ~40-min silicon rebuilds. Consequence:
you cannot lean on cosim as the value gate for this project; use the board-free
phase-exact complex-ratio check on the real IP instead. Manual entry — nothing to
regex.

<!-- LINT
id: cosim-segfault
severity: warn
message: shls cosim wrapper segfaults on this install; use board-free phase-exact check as the value gate, not cosim.
-->

## 3. Detect stage sign-extension  `[manual]`

The fabric detect kernel mis-handled sign in a way schedule/C-sim did not surface;
confirmed on silicon and fixed with a correctly-signed CPU detect A/B
(`sar-verification-methodology` §5). Guard: value-test detect on signed full-scale
inputs, not magnitude/correlation. Manual entry.

<!-- LINT
id: detect-sign-extension
severity: warn
message: Detect stage mis-handled sign; value-test on signed full-scale inputs, never magnitude only.
-->

## 4. DDR reads on the II-critical loop path  `[warn]`

Reading a top-level `axi_initiator` pointer argument (a DDR fetch) inside the
inner, II-critical loop makes the SmartHLS `II=1/2` schedule a fiction: the DDR
round-trip serialises the loop to an effective II ~10x worse (the resample
`idx[]/wq[]` case). **Fix pattern:** stage the per-output operands into on-chip
LSRAM first, so the II-critical loop only touches on-chip memory — then the
report's II becomes true on silicon (see `resample.cpp` header comment). This is a
design-review reminder; the shape is not reliably regexable line-by-line, so it is
a manual entry. Quantify any suspicion with `hls_stats.py eff-ii`.

<!-- LINT
id: ddr-read-in-ii-loop
severity: warn
message: A DDR (axi_initiator) read inside the II-critical loop makes the scheduled II a fiction; stage operands into LSRAM first. Measure eff_ii to confirm.
-->

## 5. `pipeline` pragma without an explicit `II()`  `[warn, auto]`

A `#pragma HLS loop pipeline` that omits `II(k)` lets SmartHLS pick the II and then
silently degrade it with no build failure. Always pin `II(k)` so Gate 1
(`hls_report_lint.py`) has a target to check the achieved II against.

<!-- LINT
id: unpinned-pipeline-ii
severity: warn
files: mpfs/fpga/**/*.cpp, *.hpp
pattern: #pragma\s+HLS\s+loop\s+pipeline\s*$
message: `pipeline` pragma with no II() -- pin II(k) so Gate 1 can catch schedule degradation.
-->
