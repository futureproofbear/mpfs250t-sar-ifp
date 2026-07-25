# On-fabric azimuth resample coefficient generation — `sar_coeffgen.v`

Design note for the hand-written Verilog module that computes the azimuth (pass-2) resample
coefficients in fabric, so `idx[]`/`wq[]` never touch DDR or the CPU.

Status: **integrated, board-free.** RTL + testbench + numeric gate, plus the SAR_TOP wiring
(CIC target7 @0x60007000, stream into `fft_feeder_v`) and the firmware driver — all compile-clean.
No Libero run, no synthesis, no place-and-route, no bitstream, no board. Every resource and timing
number below is analytic and is explicitly flagged as such. The fabric path is OFF by default at
both the fabric bit and the firmware knob (§8), so a build made from these sources is
behaviour-neutral until deliberately switched.

---

## 1. Why

`fft1_gather_pass()` (`src/sar/sar_sequencer.c`) costs 15.15 s of a 36.6 s frame. Silicon
telemetry 2026-07-25 splits that as **1499 µs/row of CPU coefficient generation
(`sar_coeffs_pass2`) against 0.53 µs/row of residual fabric wait** — the
feeder → gearbox → CoreFFT → unloader chain is already idle by the time the CPU hands over.
Over 8192 rows that is 12.28 s of pure CPU.

The table cannot be precomputed: the full 8192×8192 `idx`+`wq` set is ~768 MB. But the two big
inputs are **row-invariant**:

| array | size | per row? |
|---|---|---|
| `tan_s[]` | M×4 B (5634 → 22.5 KB) | no — identical every row |
| `inv_tan[]` = 1/(tan_s[k+1]−tan_s[k]) | (M−1)×4 B | no — built once by `sar_coeffs_init()` |
| `KC[]` | Mp×4 B (8192 → 32 KB) | no — identical every row |
| `KR[j]` | 4 B | **yes — one scalar** |

So the whole per-row input is one float. Loaded on-chip once per scene, a fabric kernel needs
only a register write per row.

---

## 2. Arithmetic contract

`sar_coeffs_pass2_range(g, j, ..., 0, Mp)` in `src/sar/sar_resample_coeffs.c` **is** the
specification. Reproduced exactly, in the same order:

```
asc = (kr >= 0)                       ; kr == 0  -> degenerate line, all {-1, 0}
r   = 1.0f / kr                       ; the only divide in the line
rr  = asc ? r : -r                    ; SIGN FLIP -- load-bearing, see below
SRC(k)     = fl32( kr * tan_s[ asc ? k     : S-1-k ] )
INVSPAN(k) = fl32( inv_tan[ asc ? k : S-2-k ] * rr )
xlo = SRC(0) ; xhi = SRC(S-1)
k = 0 ; x0 = SRC(0) ; inv = INVSPAN(0)
for qi in 0..Mp-1:
    q = KC[qi]
    if (q < xlo || q >= xhi):  idx=-1 ; wq=0 ; continue        # checked BEFORE any advance
    while (k+2 < S && SRC(k+1) <= q):  k++ ; x0=SRC(k) ; inv=INVSPAN(k)
    frac = fl32( fl32(q - x0) * inv )
    emit( asc ? k : S-2-k ,  asc ? frac : fl32(1.0f - frac) )
emit(k, w): wi = (int32)( fl32( fl32(w*32768.0f) + 0.5f) ) ; clamp [0, 32767]
```

The `rr` sign flip is the subtlety the C header calls out: for `kr < 0` the ascending *view*
walks `tan_s` backwards, so the view span is `−kr·(tan_s[t+1] − tan_s[t])`. Using `r` for both
orders yields a negative weight on **every** descending line. The testbench proves this is caught
(§6).

---

## 3. The fixed-point decision — and the evidence

The brief offered (a) bit-exact float32 in fabric, or (b) a fixed-point reformulation proven to
land on identical `idx`/`wq`. **Neither, exactly: the implementation is pure integer hardware
that reproduces IEEE-754 binary32 values.** That is (a)'s exactness at close to (b)'s cost, and
here is why (b) cannot be made to work and why (a) is not expensive.

### 3.1 Why a fixed-point reformulation cannot be bit-identical

The C's float32 *rounding* is load-bearing, not incidental:

- The bracket test is `SRC(k+1) <= q` with `SRC(k+1) = fl32(kr·tan_s[k+1])`. Rounding that
  product moves the bracket edge by ~0.5 ulp. A query landing inside that window takes the
  **other** bracket: `idx` off by one and `wq` flipping between ~0 and ~32767.
- `frac = fl32(fl32(q − x0)·inv)` with `x0 = fl32(kr·tan_s[k])`. On the staged geometry
  0.5 ulp of `x0` is ~1.7e-8 against a bracket span of ~8.2e-4 — about **0.67 Q15 LSB**. A
  "close enough" `x0` therefore moves `wq` by ±1 on a large fraction of outputs.

Any reformulation (work in `tan_s` space via `u = q·(1/kr)`; rescale to a common Q format) is a
*different rounding sequence*, so it cannot be bit-identical by construction. Measured, not
assumed — `mpfs/host/check_coeffgen_fixed.py` GATE 3, real staged geometry, both source orders:

| variant | idx differs | wq differs | max abs Δwq |
|---|---:|---:|---:|
| tan_s-space fixed point, Q24 | 2 / 1398 | 1385 / 1398 | 32752 |
| tan_s-space fixed point, Q30 | 0 | 961 / 1398 | 4 |
| tan_s-space fixed point, Q36 | 0 | 691 / 1398 | 2 |

Even at Q36 — far past the point where extra width is free — **49% of in-range outputs move**.
Physically those are sub-quantisation shifts, but they change the pipeline CRC and destroy the
one cheap regression gate the project has. Not acceptable for a change of this size.

### 3.2 Why binary32 in fabric is cheap here

Three structural facts collapse the cost:

1. **Every multiply has normalized operands.** The product of two 24-bit significands is in
   `[2^46, 2^48)`, so normalization is a **one-bit shift decided by one bit** — no leading-zero
   count, no barrel shifter. `sar_fp32_mul` is a 24×24 multiply, a 1-bit shift, and
   round-to-nearest-even. Latency 2, one result per cycle.
2. **No divider.** The line's only divide, `1.0f/kr`, stays on the CPU — which already computes
   it — and arrives as register `RINV`. This is not a shortcut: it keeps the *same float
   expression* the C uses, which is what makes `inv` bit-exact. `inv_tan[]` is handled the same
   way: it is already built once by `sar_coeffs_init()` and is pushed in as a table, because
   recomputing it in fabric would round differently (exactly the trap the C header warns about).
3. **Only three operations need a real aligner/normalizer**: `fl32(q − x0)`, `fl32(1.0f − frac)`
   and `fl32(w·32768.0f + 0.5f)`. One 3-stage `sar_fp32_add` design covers all three.
   `w · 32768.0f` is *exponent-only* and therefore exact — no multiplier, no rounding.

No NaN/Inf/denormal path exists. Any such operand latches a sticky `err_fmt` bit rather than
being silently mis-evaluated.

### 3.3 Bit-exactness evidence (board-free, reproducible now)

```
python mpfs/host/check_coeffgen_fixed.py
```

```
stage=jtag_stage_small  Mp=8192 Np=8192 S(M)=705
GATE 1 primitives: 160968 ops, fmul mismatches=0, fadd mismatches=0  -> PASS
GATE 2 datapath: rows tested=64 (half with kr<0), in-range outputs=45038,
                 mismatching rows=0, fmt_err=0, ovf=0  -> PASS
PASS: sar_coeffgen's integer binary32 datapath is BIT-IDENTICAL to
      sar_coeffs_pass2_range() on real staged geometry, both source orders.
```

- **GATE 1** fuzzes the integer primitives in `mpfs/host/coeffgen_model.py` against numpy
  float32 over 160,968 structured + random + heavy-cancellation operand pairs. Zero mismatches.
  This is what turns GATE 2 from a coincidence into a proof.
- **GATE 2** runs the pure-integer model of the fabric datapath against a faithful float32
  mirror of `sar_coeffs_pass2_range()` over the real staged geometry
  (`mpfs/host/jtag_stage_small`, M=705, Mp=8192), 32 rows spread across the grid, each mirrored
  with `kr` negated so the descending path is exercised (the staged scene has `KR > 0`
  throughout — the same trick `check_coeff_split.py` uses, for the same reason). 45,038 in-range
  outputs, **byte-identical**.

Chain of evidence for the RTL: `tb_sar_coeffgen.v` checks the Verilog against vectors produced
by that same model, so a TB pass means *RTL == integer model == float32 C reference*.

**Consequence: enabling this cannot move the pipeline CRC.** That is the property that makes the
change safe to ship.

---

## 4. Interface

### 4.1 AXI4-Lite control slave (style follows `fft_feeder_v.v`)

| offset | name | access | meaning |
|---|---|---|---|
| 0x00 | `CTRL` | W | `[0]` start row · `[1]` rewind tan ptr · `[2]` rewind itan ptr · `[3]` rewind KC ptr |
| 0x00 | `CTRL` | R | `[0]` busy |
| 0x04 | `KR` | RW | float32 bits of `KR[j]` (per row) |
| 0x08 | `RINV` | RW | float32 bits of `1.0f/KR[j]` (per row, CPU-computed — §3.2) |
| 0x0c | `DIMS` | RW | `[13:0]` = S (=M source samples), `[29:16]` = QN (=Mp outputs) |
| 0x10 | `TANW` | W / R | write `tan_s[k]` fp32 bits, pointer auto-increments / read fill level |
| 0x14 | `ITANW` | W / R | write `inv_tan[k]` fp32 bits, auto-increments / read fill level |
| 0x18 | `KCW` | W / R | write `KC[qi]` fp32 bits, auto-increments / read fill level |
| 0x1c | `STAT` | R | `[0]` busy · `[1]` err_fmt · `[2]` err_dims · `[3]` degenerate · `[29:16]` outputs emitted |

Per-row parameters are **latched at START**, so a late AXI4-Lite write cannot split a row — the
same rule `fft_feeder_v.v` enforces for `win_scale`/`gath_en`.

`err_dims` covers "tables not filled to S / S−1 / QN"; that is the fabric equivalent of the C's
`s_inv_tan_n != S` guard, and it takes the same fail-safe branch (emit a correctly-typed
degenerate line rather than values from a different expression).

### 4.2 Coefficient stream

```
output [31:0] m_idx     // int32 bracket index, 0xFFFFFFFF (-1) = out of range
output [15:0] m_wq      // Q15 weight
output        m_valid
input         m_ready
```

One entry per output `qi`, strictly in `qi` order, exactly QN entries per row. `idx = -1, wq = 0`
marks out-of-range — byte-for-byte what the feeder's gather engine reads from
`K_FFT_IDX_BASE`/`K_FFT_WQ_BASE` today.

### 4.3 Table load

`tan_s` / `inv_tan` / `KC` are pushed by AXI4-Lite writes against auto-incrementing pointers,
**once per scene**: 5634 + 5633 + 8192 = 19,459 writes ≈ 2 ms. Deliberately *not* a DMA — the
same reasoning `fft_feeder_v.v` records for its taper table: a second AXI read mode would have to
arbitrate for AR/R against the row feed, and 2 ms once is free against 12.28 s saved.

---

## 5. Microarchitecture and throughput

Three engines, each one item per cycle:

- **SRC producer** — for `k = 0..S−2` reads `tan_s[]`/`inv_tan[]` and computes
  `{SRC(k), INVSPAN(k)}` through two `sar_fp32_mul`, pushing into a 16-deep lookahead FIFO. This
  decouples the consumer from the multiply latency, so a bracket advance costs **one** cycle and
  never a pipeline refill.
- **KC prefetch** — streams `KC[qi]` into an 8-deep FIFO.
- **Consumer** — holds the moving bracket `(k, x0, inv)`. Each cycle it performs *either* one
  bracket advance *or* one output issue — structurally the C's `while`/`for`.
- **Emit pipe (11 stages)** — `fl32(q−x0)` (3) → `×inv` (2) → `fl32(1.0f−frac)` (3) →
  `fl32(w·32768 + 0.5f)` (3) → truncate/clamp. Free-running; `EMIT_LAT+2` slots are reserved in
  the 32-deep output FIFO so it can never find the FIFO full — the same reservation pattern (and
  the same reason) as `fft_feeder_v.v`'s `PIPE_D`/`FIFO_CAP`.

The `1.0f − frac` stage and the `asc` select are **delay lines, not muxes**, so latency is
identical in both source orders. A mode-dependent depth would let a `kr` sign change corrupt the
tail of a row.

**Cost per row** = QN + (bracket advances) + ~30 cycles of edge/prime/drain. Measured in
simulation (100 MHz clock, mild `m_ready` backpressure throughout):

| case | QN | S | cycles | cyc/output |
|---|---:|---:|---:|---:|
| asc_real | 8192 | 705 | 9452 | 1.15 |
| desc_real | 8192 | 705 | 9425 | 1.15 |
| asc_dense | 4096 | 705 | 4826 | 1.18 |
| stutter (50% ready gaps) | 2048 | 705 | 4034 | 1.97 |

Extrapolating to production (S = 5634, Mp = 8192): 8192 + 5633 ≈ 13,825 cycles plus the ~6%
overhead observed above ≈ **~147 µs/row at 100 MHz, versus 1499 µs/row on the CPU — 10.2×**.
Backpressure from the gather engine is absorbed 1:1 (the `stutter` row shows the module degrades
gracefully rather than stalling).

---

## 6. Verification

### 6.1 Numeric gate (board-free, no simulator needed)

`mpfs/host/check_coeffgen_fixed.py` — §3.3. Run this before anything else; it is the gate that
decides whether the arithmetic is allowed near the pipeline.

### 6.2 RTL testbench

```
cd mpfs/fpga/tb
python gen_coeffgen_vectors.py
MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
$MS/vlib cgwork && $MS/vlog -work cgwork +incdir+. ../sar_coeffgen.v tb_sar_coeffgen.v
$MS/vsim -c -do "run -all; quit -f" cgwork.tb_sar_coeffgen
```

Current result:

```
[coeffgen] fp32 primitives: 2656 vectors, 0 mismatches  ok
[coeffgen] case asc_real   QN=8192  9452 cycles (1.15 cyc/output)  ok
[coeffgen] case desc_real  QN=8192  9425 cycles (1.15 cyc/output)  ok
[coeffgen] case asc_dense  QN=4096  4826 cycles (1.18 cyc/output)  ok
[coeffgen] case desc_dense QN=4096  4827 cycles (1.18 cyc/output)  ok
[coeffgen] case stutter    QN=2048  4034 cycles (1.97 cyc/output)  ok
[coeffgen] case edges      QN=1024  1754 cycles (1.71 cyc/output)  ok
[coeffgen] case degen_kr0  QN=1024  1074 cycles (1.05 cyc/output)  ok
checked 12613 non-trivial interpolated weights
==== sar_coeffgen: PASS (0 mismatching coefficients) ====
```

The TB compares **every** streamed `{idx, wq}` pair, in order, against the bit-exact reference,
and refuses to report PASS unless it saw ≥5000 genuinely interpolated (non-clamped, in-range)
weights — a deliberate guard against the `tb_sar_axi_idconv.v` failure mode of a testbench that
passes on handshakes while proving nothing.

### 6.3 Mutation coverage — measured, not asserted

Each mutation was applied to `sar_coeffgen.v` and the TB re-run:

| mutation | result |
|---|---|
| drop the `INVSPAN` sign flip when `kr<0` | `desc_real` + `desc_dense` FAIL — 4800 coefficients |
| emit `k` instead of `S−2−k` when `kr<0` | `desc_real` + `desc_dense` FAIL — 4801 |
| truncate instead of round-to-nearest-even in `sar_fp32_mul` | **all six** value cases FAIL — 3131 |
| `q > xhi` instead of `q >= xhi` | `edges` FAIL by exactly 1 (the query sitting on `xhi`) |
| drop the alignment sticky bit in `sar_fp32_add` | geometry cases **do not** catch it; the fp32 primitive vectors do — 66 mismatches |
| advance the bracket *before* the out-of-range test | **not observable.** On a non-decreasing `KC` an out-of-range query can never satisfy the advance test either, so the two orderings are equivalent here. Stated, not claimed as covered. |

The last two are the honest ones. The sticky-bit gap is precisely why the TB binds
`sar_fp32_mul`/`sar_fp32_add` instances directly and drives 2656 adversarial operand vectors at
them: the only wide-alignment add in the datapath is `w·32768 + 0.5f`, whose 1 ulp lands far
below the integer truncation, so a broken sticky bit is invisible end-to-end.

Two real bugs were found by this TB during development and are worth recording, because both
would have looked like arithmetic errors on silicon:

- the SRC-producer FIFO push tap was `pv[3]` where the multiply result is valid at `pv[2]`,
  shifting the whole SRC table by one bracket (`x0 = SRC(1)` for bracket 0). Symptom: every
  bracket-0 weight clamps to 0.
- the KC prefetch push tap was `qv[1]` where `kc_q` is valid at `qv[0]`, dropping `KC[0]` and
  shifting the query stream by one.

---

## 7. Resource estimate

**Not synthesized** — no Libero run was permitted for this task. LSRAM and Math counts are
structural and should hold; 4LUT/DFF are analytic and must be confirmed by the first synthesis.

| resource | this module | basis |
|---|---:|---|
| LSRAM (20 Kb) | **48** | 3 tables × 8192×32 b; 512×36 mode → 16 blocks each |
| Math (18×18) | **~12** | 3 × `sar_fp32_mul`, 24×24 unsigned ≈ 4 MACC each |
| 4LUT | **~3.5–4.5 k** | 3 × fp32 add (aligner + 27-bit LZC + normalizer + RNE ≈ 450 each), 3 × fp32 mul round/normalize (~120 each), 3 small FIFOs, FSM/counters/compare, AXI4-Lite |
| DFF | **~2.2 k** | 11-stage delay lines (kx 11×14, asc/vld/oor 33, inv/frac 6×32), fp32 pipeline registers, FIFO pointers, control |

Against the stated baseline (45.7 k 4LUT / 18%, 38 k DFF / 15%, 210 LSRAM / 25.9%, 30 Math):

| | before | after (as integrated, §8) |
|---|---:|---:|
| 4LUT | 45.7 k (18.0%) | ~50 k (19.7%) |
| DFF | 38 k (15.0%) | ~40 k (15.8%) |
| LSRAM | 210 (25.9%) | **258 (31.8%)** |
| Math | 30 (3.8%) | 42 (5.4%) |

It fits — but note the LSRAM column is the STANDALONE number, not the reduced one an earlier
draft of this note projected. That draft assumed the feeder's `idxbuf0/1` (2×4096×32 b) and
`wqbuf0..3` (4×2048×16 b) — roughly 24 LSRAM — would become dead once coefficients arrive by
stream. **They are deliberately kept**, because the DDR coefficient path is retained as a
runtime-selectable fallback (§8). That is a considered trade: ~24 LSRAM (≈3% of the device) buys
the ability to A/B fused-vs-DDR coefficients on silicon without spending another multi-hour
fabric build. If LSRAM turns out to be the binding constraint at place-and-route, the two offsets
below (the never-armed `WIN`/`DET` kernels, and `TAN_AW` 13→12.6) are the levers — dropping the
fallback should be the LAST resort, not the first.

Two further offsets if LSRAM or LUT gets tight: `ARCHITECTURE.md` §10.1 records the standalone
`WIN` (3,361 LUT / 16 LSRAM) and `DET` (3,809 LUT) kernels as **instantiated but never armed** —
stripping either more than pays for this module. And `TAN_AW` can be dropped from 13 to 12.6
worth of depth (6144 entries covers M = 5634) for 8 fewer LSRAM, at the cost of the C's
`SAR_COEFF_MAXS = 8192` generality.

---

## 8. Integration plan

### Phase 1 — standalone bring-up (recommended first build)

Instantiate `sar_coeffgen` on the control interconnect as a new `AXIIC_CTRL` slave
(`SAR_FIC0_CTRL_BASE + 0x7000`, i.e. SLAVE7; alternatively reclaim SLAVE1, the never-armed
standalone window kernel). Leave `m_ready` tied high into a small capture buffer, or simply run
one row and read `STAT`. This proves timing closure and the table-load path with **zero** risk to
the shipping datapath, because nothing consumes the stream yet.

### Phase 2 — fuse into `fft_feeder_v.v`'s gather engine

The consumption side already exists. `fft_feeder_v.v`'s gather engine today runs three sequential
DDR load passes — `G_SRC`, `G_IDX`, `G_WQ` — then `G_GATHER`, where stage 0 reads
`idxbuf0/1[gi>>1]` and `wqbuf0..3[gi>>2]` and stage 1 forms `idx1`/`wq1`. Those two loads and
those six banks are exactly what the stream replaces. Concretely:

AS IMPLEMENTED (2026-07-25) — the plan below was followed except that **nothing was deleted**:
both coefficient sources coexist and are selected at runtime.

| change | detail |
|---|---|
| load FSM | `G_SRC → G_GATHER` directly **when `gr_cstream`**; otherwise the `G_IDX`/`G_WQ` passes run exactly as before. One extra term in the `gpass == 2'd2` test |
| banks | `idxbuf0`, `idxbuf1`, `wqbuf0..3` and their address muxes are **KEPT** — they are the fallback path. See the §7 note on the LSRAM cost of that choice |
| stage-1 sources | `idx1 = gr_cstream ? c_idx_r : idx1_ddr`, `wq1 = gr_cstream ? c_wq_r : wq1_ddr`. `c_idx_r`/`c_wq_r` capture the stream entry AT ISSUE, i.e. exactly where the registered bank reads land, so the two sources are latency-matched and the select is value-neutral. Nothing downstream changes — `g_inr1`, `ge_ra`/`go_ra`, the lerp and the fused window are untouched |
| issue gate | `g_want` (slot wanted) is split from `g_issue = g_want && (!gr_cstream \|\| c_valid)`; `c_ready = gen & g_want & gr_cstream`, so READY never depends on VALID |
| registers | `K_FFT_IDX_BASE` (0x24) and `K_FFT_WQ_BASE` (0x28) keep their decode and are still written per row, so a mid-run flip of the control bit lands on a valid DDR fallback |
| control | `K_FFT_GATHER_CTRL` (0x20) **bit1** selects stream vs DDR coefficients — runtime, not a rebuild. **0 out of reset**, so the build is behaviour-neutral until firmware sets it |
| firmware knob | `SAR_CGENMODE_ADDR` = `0xB0059138`, accepted value `0x43474E31` ('CGN1') ONLY; anything else (including cold-boot garbage) leaves the DDR path running |

Proven board-free by `tb/tb_fft_feeder_gather.v`: every gather case runs twice on identical
inputs, DDR-coefficients then stream-coefficients, and the two output streams must be
beat-for-beat identical. The DDR banks are POISONED before the stream run — without that the A/B
is vacuous (reset does not clear LSRAM and the stream run skips the loads, so the banks still hold
the previous run's correct values; a feeder ignoring the stream entirely still passed). The stream
run's DDR read-beat count is also asserted to be the source row only: 18 vs 42 beats on the toy
geometry, the analogue of 2817 vs 8961 in production.

Sequencing per row in `fft1_gather_pass()`:

1. write `KR`/`RINV` and pulse `sar_coeffgen` START;
2. arm the feeder in gather mode as today.

They run concurrently: the coeffgen produces ~1/cycle and the gather consumes ~1/cycle, so the
short output FIFO rate-matches them. The coeffgen's `G_SRC`-equivalent head start is free —
the feeder spends its first pass loading the source row from DDR anyway.

### CPU-side changes (`src/sar/`)

- `sar_coeffs_init()` still runs — its `s_inv_tan[]` is now *pushed to fabric* instead of used
  locally. That is deliberate: it keeps the exact float expression.
- One-time per scene: push `tan_s[]`, `s_inv_tan[]`, `KC[]` (≈19,459 AXI4-Lite writes, ~2 ms).
- Per row: two register writes (`KR` bits, `1.0f/KR[j]` bits) plus START, replacing the
  `sar_cwrk_line()` call, the multi-hart dispatch, the 96 KB coefficient-bank publish and the
  per-bank `flush_l2_cache`.
- `SAR_COEF_IDX/WQ` DDR banks and `SAR_CWRK_NW` become unused in fused mode (keep them for the
  fallback path).
- **Coherency:** this change *removes* DMA traffic rather than adding it — nothing new crosses
  FIC0, and the coefficient bank flush disappears with the bank. The existing `flush_l2_cache`
  calls around the source row and the FFT output are unchanged and still required (FIC0 is
  non-coherent).

---

## 9. Build / toolchain requirements

| item | requirement |
|---|---|
| files added | `mpfs/fpga/sar_coeffgen.v`, `mpfs/fpga/sar_coeffgen_core.tcl`, `mpfs/fpga/tb/tb_sar_coeffgen.v`, `mpfs/fpga/tb/gen_coeffgen_vectors.py`, `mpfs/host/coeffgen_model.py`, `mpfs/host/check_coeffgen_fixed.py`, this note |
| files changed (integration) | `sartop_assembly.tcl` (COEFG instance + CIC target7 + stream connects), `axiic_ctrl_params.tcl` (`NUM_TARGETS:8`, TARGET7 = AXI4-Lite @0x60007000), `create_fresh_project_ffv.tcl` (source the core tcl), `fft_feeder_v.v` + `fft_feeder_top.v` (coefficient stream + 0x20 bit1), `tb/tb_fft_feeder_gather.v` (the A/B), `src/sar/sar_kernels.h`, `src/sar/sar_sequencer.c`, `src/sar/sar_resample_coeffs.{c,h}` |
| HLS | **none.** No SmartHLS involvement, no pragmas, no interface bundles. This is hand-written Verilog by mandate (`docs/SAR_GUIDE.md` Part 2, `docs/fpga/DEV_GUIDE.md` §1) |
| simulation | `vlib cgwork && vlog -work cgwork +incdir+. ../sar_coeffgen.v tb_sar_coeffgen.v` then `vsim -c -do "run -all; quit -f" cgwork.tb_sar_coeffgen` (ModelSim Pro 2024.3, from Libero 2025.2). Compiles clean, no warnings |
| numeric gate | `python mpfs/host/check_coeffgen_fixed.py` (numpy only) |
| Libero (NOT run here) | wired: `sar_coeffgen_core.tcl` registers the HDL+ core, `sartop_assembly.tcl` instantiates it as `COEFG` on `CIC:AXI4Lmtarget7` @0x60007000 with `CCC:OUT0_FABCLK_0` / `RST:FABRIC_RESET_N`. No FIC/AXI4 data-plane ports and no new interconnect master — the module has **no AXI4 initiator at all**; its only data-plane connection is `COEFG:m_*` → `FEED:c_*` |
| firmware | no new build flag. `make all` in `.../mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release` with `-DSAR_EMMC_ENABLE` (already in `subdir.mk`). No new .c file, so `src/sar/subdir.mk` is unchanged |

---

## 10. Risks not retired board-free

1. **Timing closure is unknown.** The critical paths are the 24×24 multiply (stage 1 of
   `sar_fp32_mul`) and the aligner + 27-bit LZC in `sar_fp32_add`. Both are deliberately split
   across registers, but neither has been through place-and-route at 100 MHz. Per the project
   rule, confirm setup **and** hold MET before treating any on-silicon misbehaviour as a logic
   bug. If the multiply misses, the fix is a third pipeline stage in `sar_fp32_mul` (the emit
   latency is a `localparam`, and the FIFO reservation is derived from it).
2. **The FFT chain's true row time is unmeasured.** The 0.53 µs/row figure is the residual wait
   *after* `sar_coeffs_pass2` returned — it proves the chain finishes before the CPU does, not
   how long the chain takes. So the post-change stage time is bounded below by an unknown.
   *Cheap board-free-adjacent measurement that retires it:* run `fft1_gather_pass()` with
   `sar_cwrk_line()` called once and the same coefficient bank reused for every row (wrong image,
   correct timing) — `RPROF[9]` then reads the true fabric row time directly. Worth doing before
   spending a fabric build.
3. **`err_fmt` behaviour on real scene geometry is untested at scale.** The gate and TB see one
   staged scene. A scene whose `tan_s` contains an exact duplicate (zero span → `inv_tan = 0`) is
   handled (the C's own degenerate branch, reproduced), but a denormal or NaN in staged geometry
   would latch `err_fmt` and produce garbage rather than failing loudly. MITIGATED: the firmware
   now reads `STAT` once per row (alongside the `K_FFT_SCALE_EXP` read it already did) and aborts
   the pass on `err_fmt` **or** `err_dims`, returning `SAR_SEQ_TIMEOUT_FFT1` with the raw STAT in
   `RPROF[11]` as `0xC0EF8sss`. A degenerate line (`kr == 0`) is NOT an error and does not abort;
   firmware writes `RINV = 0` rather than `1.0f/0.0f` so a legitimately degenerate line cannot
   latch `err_fmt` on an Inf.
4. **AXI4-Lite table load has no CRC.** 19,459 writes go in unverified. RETIRED as far as it can
   be board-free: `cgen_load_tables()` reads the three fill-level registers back at 0x10/0x14/0x18
   and compares against S / S−1 / QN, and on any shortfall disables the fabric path for the whole
   pass (the DDR coefficients run instead) and records the failing mask in `RPROF[11]` as
   `0xC0EF000m`. A fill level counts WRITES, not payload, so a corrupted-but-complete load would
   still pass — the value gate for that is the silicon CRC A/B in item 5.
5. **Silicon value check is still required.** Nothing here has run on hardware. The gate proves
   the arithmetic is bit-identical to the C, so the correct hardware acceptance test is a
   **CRC equality A/B**: run the same scene with the coefficients from the CPU and from fabric
   and require the ROI CRC to be *unchanged*. That is a stronger and cheaper check than a
   correlation number, and it is only available because the arithmetic is bit-exact — which is
   the entire reason for choosing binary32 emulation over a fixed-point reformulation.
