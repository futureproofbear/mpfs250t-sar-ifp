# SAR Pipeline — Silicon Status & Latency Roadmap (checkpoint 2026-07-04)

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
2. **Multi-hart / faster resample (~32 s → ~8 s).** The azimuth resample is MSS-coefficient-bound
   (per-line float geometry on one hart + a per-line whole-L2 flush). Parallelize the coeff computation
   across harts, and/or make FIC0 cache-coherent (MSS config) to drop the per-line `flush_l2_cache`
   (each flush walks all 16 L2 ways). The per-line flush is a large hidden cost.
   - **[Step A — IMPLEMENTED, pending silicon verification] Per-chunk L2 flush (firmware-only).**
     `resample_2pass()` now precomputes `RESAMPLE_CHUNK` (=16) lines of coeffs per fabric-arm batch and
     flushes ONCE per chunk instead of per line (16× fewer whole-L2 flushes), double-buffering the next
     chunk's coeffs against the current chunk's kernel runs. Numerically identical (pure orchestration);
     no bitstream rebuild. New DDR scratch `SAR_COEFC_*` (chunk banks) in `ddr_sar_layout.h`
     (0xB020_0000, 1.5 MiB, reserved in `ddr_layout.py`). Compiles clean under the RISC-V toolchain;
     addressing + chunk-loop bookkeeping validated board-free (`scratchpad/chunk_check.c` logic).
     **Verify:** rebuild the SoftConsole app (firmware only), reprogram, run the full-pipeline iso-test;
     confirm OUT correlation is UNCHANGED (T.rot180 vs golden) and read the resample stage time (SAR_PROG
     heartbeat / per-stage timing) vs the ~32 s azimuth baseline. This measurement decides whether Step B
     is worth the RTL rebuild: if the per-line flush was the dominant cost, resample should drop sharply
     from ~32 s; if it barely moves, the cost is the single-hart coeff compute → do the multi-hart split.
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

## Key references
- `docs/fpga/SILICON_ISO_TEST_RUNBOOK.md` — the JTAG single-kernel isolation harness, coherent-DDR-read
  technique (`call flush_l2_cache(1)` then cached read = DDR), DDR/control map, SmartHLS/Libero gotchas,
  FlashPro6 hygiene. **Read this before any silicon debug.**
- `docs/fpga/SAR_PIPELINE_PROCESS.md` — pipeline math/orchestration.
- `mpfs/host/correlate_cpufft.py` — image correlation (8-dihedral orientation search).
- Firmware: `src/sar/sar_fft.{c,h}`, `sar_fft_twiddle.h`, `sar_sequencer.c` (`fft_pass`).
