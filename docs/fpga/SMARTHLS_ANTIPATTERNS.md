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

## 6. `memory partition` pragma placed in the function body  `[warn, manual]`

Confirmed 2026-07-21 while widening the resample staging loops to full 64-bit AXI beats.

A `#pragma HLS memory partition variable(v) ...` must sit **immediately above the
declaration of `v`**. Placed anywhere else in the function body — for example grouped
with the other pragmas at the top, which reads naturally — SmartHLS emits

```
warning: [HLS pragma] ignored: expected a variable after the pragma
```

**drops the pragma, and exits 0.** The build "succeeds" with the partitioning silently
absent.

What makes this dangerous is the failure is partial and can hide itself. Two arrays were
partitioned in the same edit: `wqb` (factor 4) and `idxb` (factor 2). With both pragmas
ignored, the `wq` unpack loop degraded to II=2 —
`'@resample_wqb@_local_memory_port' has 4 uses per cycle but only 2 units available` —
while the `idx` loop coincidentally still made II=1 on the LSRAM's two native ports. So
half the regression was invisible, and the half that showed up did so only in the
pipelining report, never as an error.

Nothing upstream catches this: `shls hw` returns 0, no RTL is obviously wrong, and the
kernel is functionally correct — just slower. **Gate 1 (`hls_report_lint.py`) is the only
thing that catches it**, which is the whole argument for running the II gate on every
build rather than trusting a clean exit code.

Guard: put each partition pragma directly above its own declaration, include `dim(1)`,
and confirm the achieved II in the pipelining report afterwards. Treat a `[HLS pragma]
ignored` warning as a build failure.

Related: `cyclic` returns zero string hits when grepping the SmartHLS Python/source tree,
which makes it look unsupported. It is supported — the pragma reference is embedded in
`clang-15.exe`, which documents `block|cyclic|complete` with `dim` and `factor`.

<!-- LINT
id: partition-pragma-placement
severity: warn
message: `memory partition` must immediately precede the variable's DECLARATION; elsewhere SmartHLS warns "[HLS pragma] ignored", drops it and exits 0. Verify the achieved II in the pipelining report.
-->

## 7. Outer-loop bound made a RUNTIME argument collapses read overlap  `[block-class, manual]`

Confirmed 2026-07-23 on `hls_corner_turn/corner_turn.cpp` while adding strip-transpose support
(two new scalar args `c_base`/`c_count` so the kernel could transpose a range-bin band instead of
only the whole frame, for a corner-turn/FFT overlap design).

The tiled DDR<->DDR transpose has two nested nests: `for (r0=0; r0<CT_H; r0+=CT_T)` outer, then
`for (c0=cb; c0<ce; c0+=CT_T)` — originally `c0<CT_W`, a **compile-time constant**. Changing only
the bound (`ce = c_count==0 ? CT_W : c_base+c_count`, still equal to `CT_W` for the full-frame
case) is enough to regress the kernel **~3.9x on silicon** (6.20 s -> 24.36 s, reproducible to
within microseconds across two runs) — with the *inner* pipelined loops still reporting `II=1` in
the pipelining report (Gate 1 does not catch this; the degradation is at the outer-loop/tile-
boundary level, invisible to the inner-loop II check).

FIC_0 monitor (`sar_fic0s_mon`) confirmed the mechanism at the bus level during the CT-alone run:
read-channel **utilization 6.4%** (busy 1.63 s of 25.3 s elapsed, vs a healthy pipelined kernel
near-saturated), AR burst count **exactly 2x** what a clean one-burst-per-row schedule would
produce (every row's read appears to split into two shorter transactions), and a single
**MAX_GAP ~5.19 ms** stall. The write side was *already* single-beat/unbursted in the fast
CT_T=128 build (so that isn't the delta) — the regression is specific to making the READ-issue
loop bound a runtime value, which evidently costs the scheduler its ability to overlap read-issue
of tile N+1 with the write-drain of tile N across the outer-loop boundary.

**This was caught by silicon A/B, not by any board-free gate** — `shls sw`/`shls hw` both passed,
`hls_gate.sh` passed (II=1 both loops), and the timing gate passed (setup/hold MET) because P&R has
no opinion on AXI transaction scheduling. Only a same-scene A/B against the last known-good
bitstream (mandated by the batch-confidence protocol) surfaced it, and only the FIC_0 monitor
localised it to read-issue overlap rather than a burst-length or write-side regression.

Guard: NEVER change a `axi_initiator`-facing loop's bound from a compile-time constant to a
runtime-computed value without an A/B against the constant-bound baseline on the SAME bitstream
family, even when `c_count==0`/full-range makes the two mathematically equivalent. Prefer one of:
(a) keep the loop bound a compile-time constant and gate the tile BODY with a cheap runtime `if`
(untested here — may hit the same scheduling loss, verify before relying on it); (b) synthesize
N separate compile-time-bounded kernel instances for a fixed strip count instead of one
dynamically-bounded kernel; (c) the explicit `axi_m_read_req`/`write_req` interface (hand-managed
handshake, not schedule-dependent). Do not ship a dynamically-bounded `axi_initiator` loop kernel
on schedule/timing gates alone.

<!-- LINT
id: axi-initiator-runtime-loop-bound
severity: warn
message: Making an axi_initiator kernel's outer loop bound a RUNTIME value (even when equal to the old compile-time constant) can collapse read-issue overlap ~4x on silicon while II/timing gates stay green. A/B against the constant-bound baseline before shipping.
-->
