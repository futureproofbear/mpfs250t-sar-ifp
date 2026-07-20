# SAR Pipeline — Silicon Status & Latency Roadmap (checkpoint 2026-07-04)

> **▶ 2026-07-20 update (newest) — full deci-1 per-stage timing now MEASURED.** The pipeline runs from
> the **on-board eMMC-resident scene** (LOAD 78 s, `sig_crc 0x89fa12dc` verified) and focuses it in
> **110.8 s** (`SAR_SEQ_OK`, `fft_mode=1` fabric CoreFFT confirmed at runtime), with a coherent focused
> image confirmed via a top-left 1024×1024 ROI crop:
>
> | resample | detect | azFFT | rangeFFT | cornerturn | window | **TOTAL** |
> |---:|---:|---:|---:|---:|---:|---:|
> | **53.6 s** (48%) | 19.7 s (18%) | 12.2 s | 12.0 s | 7.3 s | 6.0 s | **110.8 s** |
>
> That is **~32% faster than the 162 s** in the prior baseline (resample 103.3 → 53.6 s, from burst-256
> + hoisted-window). **Detect (CPU) is now the #2 cost.** Re-read anytime with
> `bash mpfs/host/run_stage_timing.sh` (no re-run needed). The 2026-07-04 table below is a prior
> decimated-scene measurement, kept for history. Full current status:
> [`../PROJECT_SOURCE_OF_TRUTH.md`](../PROJECT_SOURCE_OF_TRUTH.md) + [`SILICON_ISO_TEST_RUNBOOK.md`](SILICON_ISO_TEST_RUNBOOK.md) § eMMC.

## Status: ✅ VALIDATED END-TO-END ON SILICON

The full PFA (polar-format) SAR pipeline runs on the PolarFire SoC **MPFS250T_ES** (Icicle-style board,
JTAG/FlashPro6) and produces the **correct focused image**:

- **Correlation vs golden reference = 0.9923** (Centerfield decimated 705×540 scene, band rows 896:1152,
  1.05 M unsaturated pixels; a point-target crop hits 0.9962). The board image matches `golden_small_mag.npy`
  in the **`T.rot180`** orientation (`board == golden.T[::-1,::-1]`), exactly the "match up to orientation"
  the golden spec allows. Same speckle + same bright point-target in the same location (see
  `mpfs/host/polarfire_sar_image.png`, `polarfire_crop.png`).
- `sar_form_image` (PIPE mailbox cmd) returns **RETURN=0** in **~120 s**.

### Pipeline (stage → engine → time)
| Stage | Engine | Time |
|---|---|---|
| Resample range (705 pulses) + transpose | fabric kernel + MSS coeffs | ~8 s |
| Resample azimuth (8192 lines) | fabric kernel + MSS coeffs | ~32 s |
| Window (2-D Hamming) | fabric kernel | ~4 s |
| **Range FFT** (8192 rows) | **MSS U54 CPU** | ~32 s |
| Corner-turn (transpose) | fabric kernel | ~4–8 s |
| **Azimuth FFT** (8192 rows) | **MSS U54 CPU** | ~32 s |
| Detect (magnitude) | fabric kernel | ~4 s |
| **Total** | | **~120 s** |

Data flow: `resample → corner-turn → window → range-FFT → corner-turn → azimuth-FFT → detect`, buffers
SIG `0x88M` / SCRATCH `0x98M` / OUT `0xA8M` (see `sar_sequencer.c`).

## Why the FFT is on the CPU (the key architectural decision)

The HLS `K_FFT` kernel (`hls_fft/hls_fft.hpp` `fft_in_place_bfp`, control slave `0x60004000`) is
**unsynthesizable on SmartHLS 2025.2**: its radix-2 butterfly network **drops the twiddle term** in the
generated RTL, collapsing to an identity/passthrough on silicon — while every C-simulation passes at
corr 0.9999. Proven across **three** independent FFT structures (all rebuilt + tested on silicon):

1. `hls::DoubleBuffer` ping-pong (original) → const-1000 → flat `0x00030000` (= input>>out_shift).
2. Explicit `static buf[2][SIZE<<1]` ping-pong → identical passthrough.
3. Single-array in-place `re[]/im[]`, no `int()` truncation → identical passthrough (output 0 after per-stage >>1).

Ruled out: the buffer mechanism (3 structures), the twiddle ROM (mem_init `.mem` verified correct
`0x7FFF`), `int()` truncation, the bank index. The RTL **contains** the multipliers (1703 `legup_mult`),
so the twiddle multiply is synthesized — its result just never reaches the butterfly store. It's a deep
SmartHLS scheduling/optimization bug. **RTL cosim is blocked** (the `shls cosim` C-testbench wrapper
segfaults `0xC0000005` regardless of code), so it could not be debugged in simulation — only via ~40-min
silicon rebuilds.

**Resolution:** move only the FFT to the MSS U54 (`src/sar/sar_fft.c`). Everything else in the pipeline
was already silicon-verified on the fabric. This turned FFT iteration into **firmware-only** (~1.5-min
reflash vs 40-min fabric rebuild). The fabric `K_FFT` kernel is present in the bitstream but unused.

### CPU FFT design (`sar_fft.c`)
- Plain-C radix-2 DIT 8192-pt FFT. **L1-BFP scaling** is essential: full-precision `int32` accumulation
  (int64 twiddle multiply, **no per-stage `>>1`**) + ONE global block exponent (`out_shift` from the
  max-row L1 norm) applied at the output.
- The first version used per-stage `>>1` (classic 1/N). That **truncated the small AC bins to zero over
  13 stages → a DC-only image, corr ~0**. Full-precision + a single block exponent preserved the AC →
  corr 0.99. **Lesson: fixed-point FFT dynamic range must be managed with a block exponent, not per-stage
  truncation.**
- Precomputed twiddle header (`sar_fft_twiddle.h`) — `nano.specs` doesn't link `cos/sin/lround` (libm),
  so no runtime trig. Bit-reversal is computed at init (pure bit ops).
- Coherency: `fft_pass()` in `sar_sequencer.c` calls `sar_cpu_fft` between `flush_l2_cache(1u)` (before:
  read the kernel-written `src` from DDR; after: push the CPU-written `dst` to DDR for the next FIC0 kernel).

## Latency roadmap (the standing goal — reduce processing time)

Current ~120 s is a bring-up baseline, not optimized. Biggest levers, in rough ROI order:

1. **Multi-hart CPU FFT (~4×).** The FFT is single-hart U54. Split the 8192 rows across the 4 U54 harts →
   each FFT pass ~8 s instead of ~32 s. Saves ~48 s → pipeline ~72 s. Straightforward (rows are
   independent; needs per-hart working buffers + a barrier + L2 flush after). **Highest ROI.**
2. **Faster resample — it is FABRIC-GATHER-KERNEL-BOUND (measured), not coefficient-bound.**
   On-silicon mcycle profiling of the azimuth pass (counters in `resample_2pass`, JTAG-read @0xB0059120)
   gives the per-line time split: **kernel-wait 78 % / coeff-compute 20 % / flush 2 %.** So the earlier
   "MSS-coefficient-bound" belief is REFUTED. The CPU spends 78 % of resample spinning in `sar_k_wait`
   for the fabric gather kernel; the coeff compute (20 %) is already double-buffered behind it, and the
   flush is 2 % (Step A removed most of that). Consequence: coefficient optimizations (multi-hart coeff
   split, reciprocal-hoist, fabric coeff-gen, CORDIC) are dead by Amdahl (~0 % of resample). The lever
   is the **fabric gather kernel throughput** (`hls_resample/resample.cpp`). ROOT CAUSE (pass-1 probe +
   SmartHLS report): pass-1 (reads ~540) vs pass-2 (reads 8193) kernel-wait/line = 1.69M vs 2.01M cyc =
   only 1.19× despite 15× more read → read is ~1.3% of the time, NOT read-bound (so runtime-`nin`/Step-B
   is useless). Cost is per-output: ~21 fabric-cyc/output vs II=1 ideal. The SmartHLS report shows the
   gather loop scheduled **II=2** (single-read-port `resample_buf` serializes `buf[j]`+`buf[j+1]`) and
   in/idx/wq/out **sharing one m_axi port**; silicon's ~21/output is ~10× past that (the shared port
   serializing idx-read+wq-read+out-write per output at DDR latency — another report-vs-silicon gap).
   FIX (kernel redesign + bitstream rebuild, value-verify on silicon): (1) stage idx+wq into LSRAM
   (burst up front like `in`) → zero per-output DDR reads; (2) pair/partition `buf` (cyclic factor 2)
   → `buf[j]`,`buf[j+1]` in one cycle → II→1; (3) dedicate `out` to its own AXI ID. Est ~10–20× on the
   kernel → resample ~28 s → ~2–3 s → pipeline ~144 s → ~110 s, after which the fabric FFT / corner-turn
   stages become the top cost (the pipeline uses the fabric CoreFFT chain, not CPU FFT).
   - **[Step A — IMPLEMENTED + VERIFIED ON SILICON] Per-chunk L2 flush (firmware-only).**
     `resample_2pass()` now precomputes `RESAMPLE_CHUNK` (=16) lines of coeffs per fabric-arm batch and
     flushes ONCE per chunk instead of per line (16× fewer whole-L2 flushes), double-buffering the next
     chunk's coeffs against the current chunk's kernel runs. Numerically identical (pure orchestration);
     no bitstream rebuild. New DDR scratch `SAR_COEFC_*` (chunk banks) in `ddr_sar_layout.h`
     (0xB020_0000, 1.5 MiB, reserved in `ddr_layout.py`).
     **Silicon result (2026-07-12, small scene, new fw programmed to eNVM, full `sar_form_image`):**
     RETURN=0, OUT correlation **0.9923** (T.rot180 vs golden) — image correct, numerically identical.
     BUT resample was only ~28–32 s (range 705 lines ≤4 s + azimuth 8192 lines ~28 s), ~3.4 ms/line vs
     the ~3.9 ms/line baseline — a **~10–15 % (~4 s) improvement, NOT a multiplier**. So the per-line
     whole-L2 flush was NOT the dominant cost (the "large hidden cost" belief above is refuted by
     measurement): azimuth resample is bound by the single-hart per-line coefficient geometry compute.
     **The real latency win is the multi-hart coefficient split (item 1 above), not flush batching and
     not Step B's kernel rebuild.** Step A stays (a clean ~10 % win, zero cost/risk) but is not the lever.
   - **[Step B — kernel written + validated, needs `libero-build` + board] Kernel self-sequences C
     lines per arm.** HLS `resample_chunk` (`mpfs/fpga/hls_resample_chunk/resample_chunk.cpp`) loops all
     `nlines` internally: the MSS arms it ONCE per chunk and the fabric streams the lines back-to-back
     (one arm/poll per chunk instead of per line). Same on-chip line-buffer + local gather as the
     per-line kernel; numeric contract bit-identical. Validated board-free: compiles under the RISC-V
     toolchain, and a self-sequencing model equals the per-line reference across permuted/identity/
     padded-stride/zero-fill cases (Python equivalence check). Only worth the bitstream rebuild if Step A
     shows arm/poll still dominates after the flush is gone (unlikely — arm/poll is a few register writes
     + a spin). Wiring the bitstream rebuild needs:
     - Register map: 9 args → `HLS_ARG0..ARG8` at `0x0c..0x2c` in `sar_kernels.h`
       (ARG0 in, ARG1 idx, ARG2 wq, ARG3 out, ARG4 out_off, ARG5 nlines, ARG6 nin, ARG7 nout,
       ARG8 in_stride). SmartHLS auto-generates these control registers from the signature.
     - Coeff layout: Step B packs coeffs CONTIGUOUSLY per line (idx[C·nout] int32, wq[C·nout] int16)
       plus an `out_off[C]` int32 table — distinct from Step A's fixed 48 KiB slots; place both in the
       reserved `SAR_COEFC_*` tables area. `out_off[l] = invord[l]·Np` (pass 1) or `l·Mp` (pass 2).
     - Sequencer: replace the per-line inner arm loop with per-chunk fill (idx/wq/out_off for C lines) →
       one `flush_l2_cache` → write the 9 arg regs → `sar_k_start` → `sar_k_wait`.
     - Core register + assembly: `shls hw` the new core, register `resample_chunk_top`, and instantiate
       it in `sartop_assembly.tcl` (mirrors the `resample_top`/`RES` instance). Build via `libero-build`
       (timing MUST close — setup AND hold — before the bitstream is exported).
     - Consideration (PolarFire): to later overlap line l+1's read with line l's write inside the kernel,
       give `in` (read) and `out` (write) separate AXI IDs / `m_axi` ports so they don't stall each other.
3. **Fix / replace the fabric FFT (~32 s → ~4 s/pass).** If the SmartHLS butterfly bug is resolved
   (Microchip support, a different FFT structure, or a hardened FFT IP), the FFT returns to fabric at
   II=1 throughput. Would also free the harts. Highest ceiling but highest risk/effort.
4. **Coherent FIC0 (removes all pipeline `flush_l2_cache` calls).** A cache-coherent MSS fabric-master
   config eliminates the per-line resample flushes AND the per-FFT flushes — pure orchestration overhead
   today. Investigate the MSS PMP/ACE-Lite / non-cached-buffer options.
5. **CPU FFT micro-opt.** `-O2` already on; consider `int32` radix-4 (fewer stages/passes), or SIMD-ish
   packing. Secondary to multi-hart.

**Recommended next step:** multi-hart CPU FFT (item 1) — biggest, safest win, firmware-only.

## Open items (image is correct regardless)
- **~50% OUT saturation at 65535.** Traced to the **detect kernel** (`SAR_REG_BFP_SHIFT` @`0x6000001C`,
  r/w in `sar_accel_driver.c`), NOT the CPU FFT — raising the CPU-FFT out_shift headroom self-cancels
  across the two passes (smaller range-FFT output → smaller azimuth L1 norm → azimuth out_shift auto-drops).
  De-saturate by lowering that register from firmware (cheap) or adjusting detect (fabric). Cosmetic —
  correlation is on the unsaturated pixels.

## HLS trust harness & batch-confidence

SmartHLS is treated as an untrusted, behavioural-only tool (documented record: twiddle drop,
detect sign-extension, II=2→21). The harness constrains its inputs, gates its outputs, and
**collects the report-vs-silicon statistics it cannot model**. Load the `hls-trust-harness`
skill for the full flow; the pieces:

- **Gate 0 — anti-pattern pre-screen:** `python mpfs/host/hls_antipattern_lint.py` checks source
  against the living catalog `docs/fpga/SMARTHLS_ANTIPATTERNS.md` (proven mis-synthesis shapes).
- **Gate 1 — II report gate:** `python mpfs/host/hls_report_lint.py` fails the build if SmartHLS
  scheduled a worse II than the source pragma requested (the silent degradation), `--selftest`
  proves the FAIL path.
- **Class-B ledger:** `docs/fpga/hls_silicon_stats.jsonl` (+ rollup `HLS_SILICON_STATS.md`),
  written with `python mpfs/host/hls_stats.py` — six phenomena SmartHLS can't see: `axi_ii_lie`
  (effective II vs scheduled, the II=1 lie), `ddr_latency`, `l2_coherency`, `fic_axi_id`,
  `es_errata` (ER0219), `corefft_rearm`. `eff-ii` derives the lie ratio from an iso-test's
  busy-cycles ÷ elements — no new RTL.

**Batch-confidence protocol.** A silicon commit stays to one logical change UNLESS every batched
change is (a) proven **additive** by the validated cost model (no Amdahl reordering among the set),
(b) **value-gated board-free** (Gates 0–2 + phase-exact check), and (c) **runtime-toggleable with
per-stage counters** so one bitstream yields N independent measurements and a regression is still
bisectable. Absent all three, sequence the changes and measure between. Gates 0–1 and the ledger
are the per-change eligibility test that feeds this decision.

## Key references
- `docs/fpga/SILICON_ISO_TEST_RUNBOOK.md` — the JTAG single-kernel isolation harness, coherent-DDR-read
  technique (`call flush_l2_cache(1)` then cached read = DDR), DDR/control map, SmartHLS/Libero gotchas,
  FlashPro6 hygiene. **Read this before any silicon debug.**
- `docs/fpga/SAR_PIPELINE_PROCESS.md` — pipeline math/orchestration.
- `mpfs/host/correlate_cpufft.py` — image correlation (8-dihedral orientation search).
- Firmware: `src/sar/sar_fft.{c,h}`, `sar_fft_twiddle.h`, `sar_sequencer.c` (`fft_pass`).
