# Pass-1 (range) on-fabric coefficient generator — design

Target: the **CPU-bound range gather** inside `resample`.

> **NUMBERS BELOW ARE STALE (2026-07-26).** They were written against resample 11.18 s of a
> 25.14 s frame. The hand-written corner-turn has since taken resample to **7.267 s** of an
> **18.45 s** frame (2026-07-27). The gather's own share has NOT been re-measured since the fabric
> coefficient generator landed — run E4 (`decode_ficmon.py`) before trusting any projection here.

Status: **arithmetic gated, RTL not written.** `mpfs/host/check_coeffgen1_fixed.py` (commit
`d676018`) proves the datapath below is bit-identical to `sar_coeffs_pass1_range()` on real staged
geometry — 0 mismatches on Centerfield and on NDSU at production 8192×8192 (195,383 in-range
outputs). Write the RTL to match that model exactly.

## 1. The maths, and why pass 1 is the cheap one

Pass 2 inverts `kc = kr·tanφ` onto a uniform `KC` grid. That is a **search** in `tan_s`, hence the
moving bracket, the sorted `tan_s`, and three 8192×32 tables.

Pass 1 inverts `kr(i,j) = 2·pr[i]/C · (f0[i] + j·df[i])` onto the uniform `KR` grid. `kr` is
**affine in j**, so it is closed form — no search, no bracket:

```
per row i (CPU):   a = 2·pr[i]/C ;  x0 = a·f0[i] ;  dx = a·df[i] ;  inv = 1/dx ;  tmax = N-1
per output q:      t   = (KR[q] - x0) · inv
                   out-of-range unless (t >= 0) and (t < tmax)   -> idx = -1, wq = 0
                   idx = (int32)t            (t >= 0, so truncation == floor)
                   wq  = clamp((int32)((t - (float)idx)·32768 + 0.5), 0, 32767)
```

The single divide is **per row, not per output**, so it stays on the CPU and arrives as a scalar —
exactly the split `RINV` already uses. No divider in fabric.

Write the out-of-range test as `NOT(t >= 0) OR NOT(t < tmax)`, not as `t < 0`, so a NaN takes the
out-of-range branch as the C does.

## 2. Reuse: extend `sar_coeffgen.v`, do not write a new module

| piece | pass 2 (existing) | pass 1 |
|---|---|---|
| AXI4-Lite slave, reg map | — | reuse |
| output FIFO + `m_idx/m_wq/m_valid/m_ready` | — | reuse |
| `fq15` weight quantiser, out-of-range bit | — | reuse |
| `sar_fp32_mul` / `sar_fp32_add` | — | reuse (already gate-validated) |
| query table | `kcmem` (KC) | **reuse `kcmem`, holds KR** |
| `tanmem` / `itanmem` | bracket search | **unused** |
| `idx` source | FSM bracket counter `e_k` | **integer part of `t`** ← the only real addition |

**Zero new LSRAM.** `kcmem` is 8192×32 and `KR` is 8192 float32. Pass 1 and pass 2 never run
concurrently — resample completes before FFT-1 starts — so the firmware loads `KR` into `kcmem`
before resample, then reloads `tan/itan/kc` before FFT-1 (~24k AXI4-Lite writes ≈ 8 ms per frame,
free against 5.8 s).

New datapath, ~3 stages: `f32→int32 truncate` → `int32→f32 convert` → `fp32 subtract` to form
`t - (float)idx`. Then the existing `fq15`.

`EMIT_LAT` (`sar_coeffgen.v:242`) is a localparam every delay line derives from
(`inv_d*`, `frac_d*`, `asc_d/vld_d/oor_d`, `kx_d`, and `OF_LIM = (1<<OF_AW) - EMIT_LAT - 2`).
Bump it by the added stages and everything follows; do not hand-adjust the delay lines.

`kx_d` must carry the **computed** `idx` in pass-1 mode instead of `e_k`. Widen it from `TAN_AW+1`
to 32 bits, or carry only the low `G_TAB_AW` bits plus the out-of-range flag — `idx` is bounded by
`N ≤ 8192`, so 14 bits suffice.

## 3. Register map additions

```
+0x20  MODE     [0] 0 = pass-2 (default, existing behaviour), 1 = pass-1
+0x24  X0       float32 x0  = a·f0[i]      (per row)
+0x28  INV      float32 inv = 1/dx         (per row)
+0x2c  TMAX     float32 (N-1)              (per scene)
```
`CGEN_CTRL_START` (`+0x00` bit0) arms a row in both modes. Keep MODE = 0 out of reset so the
bitstream is behaviour-neutral until firmware opts in — the same discipline as `SAR_CGENMODE`,
`SAR_DUALFFT` and `SAR_RWRK_NW`.

## 4. Delivery path — option (c), stream into a hand-written RES

Rejected option (b) (generator writes `idx`/`wq` to DDR, RES unchanged) for three reasons:

1. **It creates a fabric→fabric DDR handoff with no coherency mechanism.** Today the CPU writes
   `idx`/`wq` and does an explicit L2 flush before arming RES. Under (b) the generator writes via
   FIC_0 and RES reads via FIC_0, both non-coherent, so the sequencer must guarantee the generator
   has fully retired before arming RES.
2. **That ordering also kills the overlap** — generation time adds to gather time instead of
   running concurrently, unless double-buffered.
3. It adds a 7th DIC initiator, contending for the single outstanding read slot RES depends on.

Option (c) streams, and is a smaller step than it looks: **`fft_feeder_v.v` already contains a
silicon-proven gather that consumes exactly this stream.** Its documented contract
(`fft_feeder_v.v:497`) is

```
out[i] = lerp(src[idx[i]], src[idx[i]+1], wq[i])   (Q15, idx<0 || idx>=S-1 -> zero fill)
```

which is character-for-character the resample kernel's contract at `serialize_inputs.py:51`. The
two passes are the same operation on different axes. So `resample_v.v` is `fft_feeder_v.v`'s gather
datapath re-targeted, with `c_idx/c_wq/c_valid/c_ready` (`fft_feeder_v.v:653-654`) as the template
for the stream input.

It also removes the **last SmartHLS block from the datapath** — see `docs/fpga/DEV_GUIDE.md` §1 and
[[hls-runtime-loop-bound-gotcha]] (a compile-time→runtime loop bound cost 3.9× and was invisible to
every board-free gate).

## 5. Verification order (do not reorder)

1. `check_coeffgen1_fixed.py` — **done**, passing at production geometry.
2. Unit TB for the pass-1 datapath vs the model's vectors, both scenes, out-of-range and
   degenerate (`dx == 0`, `N < 2`) rows.
3. Mutation-test that TB (the pass-2 work used 5/5 mutants; a TB that cannot fail is worthless —
   `tb_sar_axi_idconv.v` was hollow and let a real defect through).
4. `resample_v.v` TB: stream vs DDR coefficients, beat-for-beat, same row.
5. Only then a Libero build.
6. Silicon: **one ELOD per PIPE run** (a run overwrites SIG — see `SAR_DUALFFT` note in
   `sar_sequencer.c`). Gate is CRC equality against `0x319037b2`.

## 6. Expected gain

~~Resample 11.18 s → ~5.5 s, frame 25.14 s → ~19.5 s.~~ **WITHDRAWN** — computed against a baseline
that no longer exists. The frame is already 18.45 s, below that projection's end state, without this
change.

What can still be said: the change removes CPU coefficient generation from the range gather and
deletes the `idx`/`wq` DDR round-trip, so it removes read traffic as well. The SIZE of the win is
unknown until E4 says how much of the 7.267 s resample stage is coefficient-bound versus
fabric-bound. The 2026-07 measurement (99.6% coeff-gen / 0.25% kernel wait) PREDATES the fabric
coeffgen and cannot be carried forward.

## 7. Post-mortem of the reverted attempt (2026-07-27)

Commit `7191894` implemented this and regressed **pass 2** on silicon; it was reverted in `e1ed702`.
Re-examined 2026-07-27, and the obvious suspect is ruled out — do not re-run this search:

- **Not a re-arm bug.** `busy` is set in `C_IDLE`, cleared in `C_DRAIN`; mutually exclusive FSM
  states, so the same-cycle override that broke `corner_turn_v` cannot occur here.
- **Taps were correct.** The pass-2 pipeline taps moved with the added stages, `asc_d[7]/frac_d2`
  → `asc_d[9]/frac_d4`, consistent with `EMIT_LAT` 11 → 13.
- **FIFO was correct.** `OF_LIM = (1<<OF_AW) - EMIT_LAT - 2` auto-scaled 19 → 17.
- **The bench already re-armed.** `tb_sar_coeffgen.v` issues a fresh START per case.

What that commit DID do to the shipping path: lengthen it from 11 to 13 stages and add two large
combinational blocks — `f2i_floor` (variable shift) and `i2f_small` (a 14-iteration priority-encoder
loop) — inside a module in the 100 MHz domain that has **+0.182 ns** of setup slack, on a critical
path already ~9.82 ns of a 10 ns period.

**Leading hypothesis: timing, not logic.** Per `CLAUDE.md`, a timing violation mimics a functional
bug perfectly and the toolchain programs a failing bitstream silently. Before retrying:

1. Pipeline `f2i_floor` and `i2f_small` into their own registered stages rather than leaving them
   combinational.
2. Build and read the timing report FIRST — treat any slack regression on `OUT0` as the finding.
3. Only then go to silicon.

This is a hypothesis, not a confirmed root cause. It has not been proven, because proving it needs
a build and a timing report that were not retained.

The other ~5.4 s in resample is the internal corner-turn (`sar_sequencer.c:1059-1066`), a blocking
full-frame transpose. It cannot be pipelined against its producer (a transpose needs all input rows
before any output row), but it can be overlapped against its **consumer** FFT-1, exactly as
`fft2_ct_overlap` does. That needs a 4th frame buffer — check whether the 1 GB ceiling in
`mpfs/host/ddr_layout.py:72` is real or convention, against the board's 2 GB.
