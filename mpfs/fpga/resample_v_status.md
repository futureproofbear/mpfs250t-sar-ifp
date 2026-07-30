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

## Ready for silicon (2026-07-29) — bitstream and firmware both built

| artifact | state |
|---|---|
| Bitstream `libero_ffv/export/SAR_TOP_ffv.job` | exported 2026-07-28 22:46 |
| Timing, multi-corner post-layout | setup **and** hold report `No Path`; constraint coverage 100% |
| `RES` in the built netlist | `sar_resample_v_top` |
| Firmware `mpfs-hal-ddr-demo.elf` | builds clean, no warnings on the new files; `cppcheck` clean |
| Per-line scalars vs the Python reference | float64 path **identical** to exact rational over all 5634 lines |

The firmware now hands the kernel three scalars per line (`sar_resample_v.c`): the affine `A`/`SH`
derived from `unit = 2^24/(kr_scale·dx)`, and `B = round((kr_off − x0)·2^24/dx)`, with the int32
query table pushed once per scene. `tb/gen_resample_vectors.py`'s `pick_sh()` remains the reference,
and `mpfs/host/check_resample_v_scalars.py` now runs that derivation **both** ways — exact rational
and the float64 the U54 actually uses — and diffs them. Over 5634 lines and all 8192 table entries:
zero differences, worst distance to a rounding boundary 1.07e−5 against a double error near 1e−7.

### The knob is INVERTED, and that is deliberate

`SAR_RSVMODE` (`0xB0059148`) is **on by default**. Every other runtime knob on this project is
opt-in, because its predecessor is still in the bitstream. That is not true here — the built netlist
contains `sar_resample_v` and *no* SmartHLS resample, because the new core took the same CIC target
rather than being added beside it. There is nothing to fall back to.

An opt-in knob would therefore have made the default case the dangerous one. The legacy path writes
`HLS_ARG0..3` at `0x0c`/`0x10`/`0x14`/`0x18`, which on this core are `IN_BASE` / `OUT_BASE` /
`STATUS2` / `DIMS`: the `idx` pointer would land in `OUT_BASE` and the output pointer would be read
as `{SN,QN}`, so the kernel would gather with garbage geometry directly into the coefficient buffer.
Only the exact word `'RSV0'` (`0x52535630`) forces the legacy path, and that is correct **only** when
this ELF is deliberately paired with a pre-2026-07-28 bitstream.

### First board run — read these before judging the image

Because there is no gcc and no spike/qemu on the development host, this C has never been executed.
Two words are published so the first run checks it instead of assuming it:

| address | contents |
|---|---|
| `0xB0059150` | line-0 `SH`, `A`, `B` lo, `B` hi — expect `0x00000018 0x4FE68946 0xE464BAAC 0xFFFFFFFC` |
| `0xB005914C` | `STATUS2`, tagged `0x5253` so a cold-boot word cannot read as a clean frame |

A mismatch at `0xB0059150` explains a wrong image completely; a match rules the CPU side out.

The register contract the firmware now targets:

| register | meaning |
|---|---|
| `0x0c` `IN_BASE` / `0x10` `OUT_BASE` | source / destination line |
| `0x18` `DIMS` | `[15:0]` QN outputs, `[31:16]` SN source samples |
| `0x1c` `LCFG` | `[5:0]` SH, `[13:8]` FSH, `[16]` MODE |
| `0x20`/`0x24`/`0x28` | `COEF_A`, `COEF_BLO`, `COEF_BHI` — the affine scalars |
| `0x2c`/`0x30` | `TAB_CTRL` / `TAB_DATA` — on-chip table load |

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

## 32-TAP SINC GATHER (2026-07-30) — verified in simulation, not yet on silicon

A second interpolation kernel now lives in `sar_resample_v` beside the 2-tap lerp, selected by
`LCFG[17]` / `SAR_SINCMODE`. Both are in the bitstream so they can be A/B'd on one board run.

**Why.** The 2-tap lerp scallops **29.2 dB** at this scene's 0.978-Nyquist band edge — the
linear-interpolation null, gain `|cos(pi f/2)| -> 0.034` at mu=0.5 — so a scatterer's brightness
depends on where it lands *between* samples by up to 29 dB. 32 taps brings that to **3.46 dB**.

| bench | result |
|---|---|
| Small synthetic suite, 8 cases + re-arm | PASS, 0 mismatching words |
| Real geometry ×4 lines, **lerp** mode | PASS, 8192/8192 each |
| Real geometry ×4 lines, **sinc** mode | PASS, 8192/8192 each |
| Standalone core, dual-port fill + 1235 stall cycles | PASS, 3621/3621 bit-exact |
| Trial synthesis, standalone | +1.083 ns at 100 MHz; 64 MACC, 32 LSRAM, 256 uSRAM |

**Design notes worth keeping.** Banks are sample-index mod 32 and the window is 32 consecutive
samples, so every bank is hit *exactly once* — single-port RAMs suffice and the tap order is a
barrel rotation. `BANK_AW=9` gives headroom at no cost (a 20 kbit LSRAM holds 512×32 either way);
at 8 it exactly fitted NDSU's N=8192 and the read address wrapped. Latency is 8 cycles against the
lerp's 4, so the lerp is delayed 4 and the edge flag 8, and the *valid* comes from the delayed lerp
in both modes — only the data is switched.

**The coefficient table is loaded by the HOST**, not firmware: 16 KB does not fit in the L2
scratchpad (linking it overflowed by 15,584 bytes) and the C cannot compute it (no libm). It is
scene-independent, so `bash mpfs/host/run_sinc_table_load.sh` is a one-time push.

**NOT yet validated on silicon.** Simulation is bit-exact against the model, but no board run has
been made in sinc mode. Load the table *before* the first PIPE — an unloaded table is all zeros and
every query maps to the same place.

## BASELINE 2026-07-30 — 32-tap sinc range interpolation, on silicon

Same bitstream, both arms measured back to back on the Centerfield scene, one ELOD per PIPE.

| measure | 2-tap lerp | 32-tap sinc |
|---|---|---|
| Frame | 14.943 s | **14.964 s**  (+21 ms, +0.14%) |
| resample stage | 3.740373 s | 3.740419 s  (+46 us) |
| range-FFT / azimuth-FFT | 5.419 / 5.784 s | 5.401 / 5.823 s |
| Top-left 1024x1024 vs `crop_topleft.bin` | corr 0.976397 | **corr 0.985491** |
| crop max / mean | 3028 / 68.11 | 3235 / 69.37 |
| crop CRC (top-left) | `0xf7fb0e92` | — |

**32 taps cost 46 us over 2 taps in a 3.74 s stage.** That is the design bet paying off: the gather
is DDR-read-latency-bound, so 16x the arithmetic hides entirely under the memory wait. The sinc core
also costs the lerp path nothing — the lerp arm of THIS bitstream matches the 2026-07-29 lerp-only
bitstream to 1.4e-4 in correlation (0.976397 vs 0.976535).

### Read the correlation improvement carefully

Correlation rose 0.976 -> 0.985, but this is NOT yet proof that sinc is more accurate, for two
reasons, and the project's own rule (`CLAUDE.md`: prefer value-level testing over correlation)
applies:

  1. `crop_topleft.bin` is itself a 2-tap image from the float32 era. "Closer to the reference" is
     not "closer to truth", and a 32-tap kernel scoring HIGHER against a 2-tap reference than a
     2-tap kernel does is surprising enough to want explaining rather than celebrating.
  2. The difference is broad, not a targeted peak recovery: mean |sinc - lerp| is 8-10 counts in
     EVERY brightness band against a mean pixel of 57. On the top 0.1% brightest pixels lerp
     recovers 99.6% of the reference's energy and sinc 103.1% — a 3% OVERSHOOT, which is the
     expected Gibbs signature of the deliberately NON-WINDOWED kernel.

OPEN: value-level diff of the silicon sinc output against the bit-accurate model, the way pass 1 was
checked to 99.19%. Until that runs, the honest claim is "sinc works on silicon, costs 21 ms, and
moves the image" — not "sinc is more accurate".

### Operational: the sinc arm is not the cold-boot state

256 phases x 32 taps x int16 = 16 KB. It does not fit the image (linking it overflowed the L2
scratchpad by 15,584 bytes) and cannot be recomputed on the U54 (needs `sin()`; this firmware links
without libm). So it is pushed over JTAG and armed:

```bash
bash mpfs/host/run_sinc_table_load.sh      # 8192 word writes; ends by proving tab_wptr wrapped to 0
```

Both the table and `SAR_SINCMODE` (`0xB0059164` = `0x534E4331`) are wiped by a power-cycle or a
fabric reprogram, so a cold boot runs the 2-tap lerp arm. **Load the table BEFORE the first PIPE** —
an unloaded table is all zeros, every query then maps to the same place, and the image is wrong in a
way that looks like an interpolation bug rather than a missing load. `tab_wptr == 0` on readback is
the cheap proof that all 8192 writes landed rather than a prefix.

---

## BASELINE 2026-07-29 — SHIPPING, and it works

| measure | value |
|---|---|
| Frame | **14.92 s** (was 18.45 s) — **−3.53 s, −19%** |
| Top-left 1024x1024 vs the known-good baseline, same region | **corr 0.9765**, max 3030 vs 3069, mean 68.1 vs 67.3 |
| Crop CRC (top-left) | `0x221e5e7a` — **replaces nothing**; the old `0x319037b2` was a CENTRE crop of the float32 path |
| `STATUS2` @ `0xB005914C` | `0x52530000` — clean across all 5634 lines |
| Line-0 scalars @ `0xB0059150` | `0x00000018 0x4FE68946 0xE464BAAC 0xFFFFFFFC` — bit-exact vs the Python reference |
| Pass 1 on silicon, value level | 99.19% exact vs the bit-accurate model |

CRC not matching the old baseline is the DESIGNED outcome (fixed point vs float32), and the
correlation is what the header predicted. Validate future runs by correlation against
`jtag_full/crop_topleft.bin`, not by CRC equality with the float32 era.

### Reading a crop — get the region right

`EROI` encodes `.base=(r0<<16)|r1`, `.len=(c0<<16)|c1` (`u54_1.c:82`) — ROW range in base, COLUMN
range in len.

```bash
# top-left 1024x1024 -- the region worth assessing (the scene CENTRE is low-return)
bash run_m3_iso.sh 0x45524F49 0x00000400 0x00000400 20000 0xB005E200      0x98000000 2097152 "$(pwd)/jtag_full/crop_tl.bin"
```

**The centre crop is a trap.** Rows/cols 3584..4608 of this scene are dark: peak ~76 against ~3030
in the top-left. On 2026-07-29 a centre crop was correlated against `crop_100.bin` — which is a
TOP-LEFT crop, not a centre one — giving corr −0.04 and an apparent 40x "amplitude collapse" that
sent a whole debugging session after a nonexistent downstream bug. Two crops are comparable only if
the same `(r0,r1,c0,c1)` produced both; check that before believing any correlation.

## STATE AT 2026-07-29 POWER-OFF — read this first next session

**The board is NOT in a usable state and the ELF on it is stale.**

| thing | state |
|---|---|
| Fabric (persists across power-off) | `sar_resample_v` bitstream — **cannot form a correct image** |
| eNVM app on the board | the OLD build, with the M2 probe defect (`bb0c6c9` is **not** flashed) |
| Rebuilt ELF on disk | current, probe fixed, `make all` clean — needs flashing + power-cycle |
| eMMC scene 0 (Centerfield) | intact, reloadable in ~81.5 s (`ELOD`) |
| DDR | wiped by the power-off, as always |

To make the board useful again, either flash the rebuilt ELF and continue debugging, or run
`mpfs/host/restore_bitstream.sh` and set `RSVMODE='RSV0'` to get back the 18.45 s / CRC `0x319037b2`
configuration. There is no third option: this bitstream has no fallback pass-1 path.

### What is settled, and what is not

Settled — do not re-investigate:

- The RTL is correct. At the true silicon parameterisation (`TAB_AW=13 BUF_AW=12 MAX_BURST=64
  WF_AW=8`) and real scene scale (`SN=4319 QN=8192`, `SH=24 A=1340508486 B=-13348062548`), MODE 0
  gathers **8192/8192 words correctly** on both `IN_BASE` parities, reset and re-armed.
- The control port really does decode 6 bits — `mpfs/host/run_rsv_alias_test.sh` proves it on
  silicon in ~40 s without a scene. Table aliasing is NOT the fault.
- MODE 0 reads the KR table (sel 0), which is what the firmware loads.
- Coefficient math matches the CPU reference (98.66% identical `idx`, differences only ±1).
- Per-line scalars: float64 firmware path identical to exact rational over all 5634 lines.
- `err_align` came from the M2 boot probe arming with the SmartHLS contract (`qn=0`, `sn=0x9800`).
  Fixed in `bb0c6c9`.

**Still unexplained: the image itself** (corr −0.04, peak 76 vs 3069, no terrain structure). Nothing
above accounts for it. Do not treat the `err_align` fix as the diagnosis.

Cheapest next step: flash the rebuilt ELF, power-cycle, `ELOD`, `PIPE`, then read `0xB005914C` and
`0xB0059150`. Until `bb0c6c9` is on the board those two words are meaningless — `STATUS2` is sticky
with no software clear and the old probe latched it at every boot.
