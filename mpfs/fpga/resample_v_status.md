# `sar_resample_v` — status, 2026-07-28

Hand-written replacement for the SmartHLS `resample` kernel, **with coefficient generation fused
in**. Targets the **5.212 s range gather**, the largest single block in the 18.45 s frame.

## What it replaces, and what it does not

| pass | today | with this core |
|---|---|---|
| **Pass 1 — range gather** | `K_RESAMPLE` (SmartHLS) + CPU coefficients + 32 KB `idx` / 16 KB `wq` per line through DDR | `sar_resample_v` **MODE 0**, closed form, coefficients never reach DDR |
| **Pass 2 — azimuth gather** | already fused into the FFT-1 feeder, fed by `sar_coeffgen`'s stream (shipping, verified) | **MODE 1 is redundant** — do not wire it |

So this does **not** collide with `sar_coeffgen`: that core serves pass 2 and stays. What MODE 0
does supersede is `sar_coeffgen`'s *pass-1* mode (fixed and silicon-verified 2026-07-28), which
becomes the fallback rather than the path.

## Verification state

| gate | result |
|---|---|
| 8 functional cases, reset per case | **8/8**, 0 mismatching words |
| 8 re-armed cases, **no reset between** | **8/8** — mutation-verified |
| Power-up behaviour-neutrality | **pass** — mutation-verified |
| Elaboration at its own defaults | **pass** |
| Wiring gate (`check_sartop_wiring.tcl`) | **pass** |
| Netlist lint | 0 critical, 0 warning |
| Synthesis | `SYN_OK`; DSP 68 → 74 of 784 |

Five defects the previous session documented (D1–D5) are all fixed — see commits `216c79a`,
`704bd21`. Two of them were bug classes seen elsewhere on this project the same week: the
`bresp_left` inc/dec race is `corner_turn_v`'s `nfull` race in another module, and the zero-extended
signed partial product is the sign-extension family that has bitten this design repeatedly.

Both bench gaps that put bugs on silicon this week are now closed **here**, and both were proven
non-vacuous by mutation:

- **re-arm** — firmware arms this kernel once per line, thousands of times, never resetting between
  lines. Making the per-run bracket re-init a no-op leaves all 8 reset-per-case runs passing while
  REARM 3/4/5 fail.
- **power-up** — removing `mode` from the reset list (literally `sar_coeffgen`'s defect) passes all
  16 functional cases, because every one writes `mode` before arming, and is caught only here.

## NOT DONE — this cannot go to silicon yet

**The firmware still arms `RES` the SmartHLS way.** It writes four `HLS_ARG` registers (`in`, `idx`,
`wq`, `out`) and supplies CPU-computed coefficients in DDR. This core implements a different
contract entirely:

| register | meaning |
|---|---|
| `0x0c` `IN_BASE` / `0x10` `OUT_BASE` | source / destination line |
| `0x18` `DIMS` | `[15:0]` QN outputs, `[31:16]` SN source samples |
| `0x1c` `LCFG` | `[5:0]` SH, `[13:8]` FSH, `[16]` MODE |
| `0x20`/`0x24`/`0x28` | `COEF_A`, `COEF_BLO`, `COEF_BHI` — the affine scalars |
| `0x2c`/`0x30` | `TAB_CTRL` / `TAB_DATA` — on-chip table load |

Programming a bitstream containing this core, with today's firmware, **produces a wrong image**.

The firmware work is the substantial remainder: per line the CPU stops computing 8192 coefficients
and instead computes two fixed-point scalars, `A = 1/dx` and `B = -x0/dx`, with a shift `SH` chosen
so `A` fits in `int32`. That arithmetic has to match the RTL bit-exactly;
`tb/gen_resample_vectors.py`'s `pick_sh()` is the validated reference for deriving it.

## Known limitations, recorded rather than discovered later

- **`STATUS2` has no software clear.** The five sticky error latches are set-only and cleared only
  by reset. Armed per line with no reset, one bad line flags the whole frame and per-line
  attribution is impossible. Fine for a frame-level "did anything go wrong"; if per-line is ever
  wanted, that is an RTL change and is cheapest now.
- **`SH = 44` is arithmetically unreachable** for this datapath — `QTAB` and `A` are both `int32`,
  so the product cannot reach `t·2^(SH+24)`. The vector generator backs off to the largest feasible
  `SH` (30 for MODE 0, 25–27 for MODE 1). Widening the product is an RTL change, not a table
  rescale.
- **The control port needs 6 address bits**, not the HLS core's 5, because of the table registers at
  `0x2c`/`0x30`. Taking 5 would alias them onto `CTRL`/`IN_BASE` and silently corrupt every table
  load.

## If a better interpolator is wanted later

Measured 2026-07-28 on real NDSU geometry (`sinc_resample_study.py --cphd ...`): the phase history
occupies **~97.8% of Nyquist** and 40% of fractional delays fall in `[0.3, 0.7]`, so the 2-tap
linear lerp is genuinely lossy here — it droops −3.01 dB at 0.5 Nyquist and −10.20 dB at 0.8, with
only ~−13 dB image rejection. A Farrow/Lagrange cubic would drop in cleanly, because this core
**already produces exactly `(idx, μ)`** and the coefficient side would not change at all; only the
gather would, from a 2-tap lerp to a 4-tap Horner cascade (which also needs 4-way source banking).

**Do that as a separate, separately-gated change.** Cubic alters every output pixel, so it
invalidates CRC `0x319037b2` and the golden reference itself (`sar_pipeline.py` uses `np.interp`,
which is linear). Land this core bit-exact first.
