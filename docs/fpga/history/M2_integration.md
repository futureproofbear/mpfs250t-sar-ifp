# Milestone 2 — full datapath, bitstream, driver (integration runbook)

Goal: assemble the complete fabric accelerator (resample → window → range-FFT →
**corner-turn** → azimuth-FFT → detect), close timing, build a bitstream, and
bring it up over JTAG against the oracles. The corner-turn (the deliberately-
stubbed piece) is now implemented; this doc covers the Libero/DMA integration, the
memory plan, the burst analysis that makes or breaks throughput, and the bring-up.

Board is needed only at the final bring-up steps (§6). Everything before is
Libero/simulator work.

---

## 1. Datapath & buffer ping-pong

The 2-D FFT is separable and the resample axes are orthogonal to the FFT axes, so
the reference's "resample-all then FFT2" equals the fabric's interleaved
"range(resample+FFT) → corner-turn → azimuth(resample+FFT)" (cross-axis ops
commute). Implemented in `sar_accel_top.cpp`:

```
SIG (in, M x N, cplx16) --PASS1--> SCRATCH (FFT_LEN_A x FFT_LEN_R, range-major)
                                      |  corner_turn_cplx (tiled transpose)
                                      v
                          SIG reused (FFT_LEN_R x FFT_LEN_A, azimuth-major)
                                      |  PASS2 (az resample + FFT + detect)
                                      v
                          OUT (FFT_LEN_R x FFT_LEN_A, range-major uint16)
```

**Ping-pong** keeps the working set at SIG(256 MB) + SCRATCH(256 MB) + OUT(128 MB)
= 640 MB (fits 1 GB; confirm DDR size — see risk). PASS1 consumes SIG then the
corner-turn writes the azimuth-major frame back into SIG, so no third 256 MB
buffer is needed. OUT is range-major (contiguous PASS2 writes); the host
transposes to (A,R) on readback (`dump_output.py`).

The 256 MB frame is ~100× on-chip SRAM ⇒ every pass streams from DDR. Throughput
is bound by DDR/FIC bandwidth and corner-turn tiling, **not** DSP count.

---

## 2. Corner-turn: the burst analysis (make-or-break)

`corner_turn_cplx` (in `sar_accel_top.cpp`; standalone verified model in
`corner_turn.cpp`) moves a TxT tile through BRAM so each DDR access is a
contiguous run, not a per-element column stride (which forces one DRAM
row-activate per element). Per-tile-row contiguous burst = **T × 4 bytes**:

| T | tile buffer (cplx16) | contiguous burst | note |
|---|----------------------|------------------|------|
| 32 | 4 KB | 128 B | small bursts, more overhead |
| 64 | 16 KB | 256 B | reasonable default |
| **128** | **64 KB** | **512 B** | recommended start; tile fits LSRAM |
| 256 | 256 KB | 1 KB | uses a large LSRAM share |

Microchip throughput flattens by ~64 KB *transfers*, which a single tile-row
(≤1 KB) does not reach — so the corner-turn will not hit peak DDR on burst length
alone. Levers, in order of value:
1. **Wider fabric AXI** (256-bit into the DDR controller) — moves 8 cplx16/beat;
   the cheapest throughput win since DSP is abundant (plan §9.3.5).
2. **T = 128** so the tile maps to a useful DRAM-row span and reads/writes amortize
   row activates.
3. **Double-buffer tiles** (read tile k+1 while writing tile k) — `tile[2][T][T]`,
   overlaps DMA with DMA.
4. **Dual FIC** (FIC0+FIC1 ≈ 3.2 GB/s) splitting read vs write streams.

Budget: corner-turn touches the 256 MB frame twice (read+write) = ~0.5 GB; the
whole focus streams ~2–2.8 GB/frame (plan §9.3). Tune T and AXI width in
simulation against these numbers, not by guesswork.

---

## 3. Libero design

- **Accelerator**: SmartHLS export of `sar_accel_top` (or hand-RTL wrapping the
  CoreFFT instances from M1). Two CoreFFT cores (range, azimuth) or one time-shared.
- **DMA**: `CoreAXI4DMAController` (or the SmartHLS datamover) generating the AXI
  masters for SIG/SCRATCH/OUT and the tables. Descriptors set up by the bare-metal
  driver before START.
- **Control**: AXI4-Lite slave exposing the `regmap.md` registers at
  `SAR_ACCEL_BASE` (the placeholder in `ddr_sar_layout.h` — set to the real FIC
  address from the Libero memory map).
- **Memory port**: start on the **cache-coherent FIC (ACE-Lite)** for correctness
  (zero-copy with the U54s, no manual flush). Move to non-coherent FIC for peak
  bandwidth only if bandwidth-bound, adding the cache flush/invalidate the driver
  already accounts for.
- **Clocking**: fabric/FIC ~150–200 MHz; CoreFFT needs `SLOWCLK ≤ CLK/8` for
  twiddle-LUT init. Place/route and timing-close at the chosen fabric clock.
- **Export**: bitstream (FlashPro) + the `SAR_ACCEL_BASE` and IRQ wiring used by
  the driver.

---

## 4. Host / driver contract

No change to the M0 contract — the driver already programs dims + buffer addresses
and runs START/poll/DONE/BFP_SHIFT (`sar_accel_driver.c::sar_run`). For M2:
- `sar_accel_config` writes SIG/SCRATCH/OUT + KR/KC/TANPHI/WIN addresses and dims.
- The fabric uses SCRATCH internally for the corner-turn; the host just provides
  its address (already in the job descriptor and `regmap.md`).
- After DONE, read `BFP_SHIFT` (= CoreFFT `SCALE_EXP` of the azimuth pass) for the
  host's output rescale.

---

## 5. Verification (against the oracles, in simulation first)

1. **Unit**: corner-turn — `corner_turn.cpp` self-test (transpose + double-transpose
   identity, ragged shapes) in C-sim; in RTL, transpose a known ramp and diff.
2. **Unit**: each CoreFFT pass — M1 flow (`fft_golden.py`, tolerance mode).
3. **Full datapath (sim)**: feed a decimated scene; compare the fabric OUT to the
   **fixed-point oracle** `dump_output.py make-golden-fixed` (resample→window→FFT→
   detect, all quantized — the closest reference; validated corr 1.0000 / 60 dB vs
   float at deci-16) and to the **float golden** `make-golden` via
   `dump_output.py readback --golden` (correlation + PSLR). Use matching `--deci`
   on serialize and golden so dims line up.
4. **Pass criteria**: correlation → 1.0 (modulo fixed point) and point-target PSLR
   within a dB of the float reference.

---

## 6. Bring-up on the board (when the board is needed)

1. Program the full bitstream with FlashPro.
2. `sar_accel_selftest()` — AXI4-Lite register read-back — proves the control plane.
3. JTAG-load a **decimated** scene (`serialize_inputs.py --deci-pulse K
   --deci-sample K`) so the first on-silicon frame is small and fast to move; run
   `sar_run(with_fabric=1)`; the board prints `BFP_SHIFT` + DONE.
4. JTAG-dump OUT (`dump_output.py gen-dump` → `source dump.gdb`), then
   `dump_output.py readback --golden golden_fixed.npy` — expect correlation → 1.0.
5. Scale up to full resolution; re-check timing/throughput; tune corner-turn T and
   AXI width if DDR-bound.

---

## 6b. Turn-key SoC integration (all pieces known, headless)

State: every component is generated & configured in `libero_sar` — CoreFFT_C0,
AXIDMA_C0, AXIIC_C0 (AXI4 5M→1S), 4 HLS kernels (HDL+), corefft_stream_adapter,
ICICLE_MSS. Clocks/resets wired in `sar_datapath`; interconnect is AXI4.

Remaining wiring (exact interfaces):

**Inside `sar_datapath` (rebuild internal connects, replacing the raw top-promotion):**
- DDR masters → interconnect: `corner_turn_0:axi4initiator`, `window_0:axi4initiator`,
  `detect_0:axi4initiator`, `resample_0:axi4initiator`, `axidma_0:<AXI master>` →
  `axiic_0:MASTER0..MASTER4`.
- `axiic_0:SLAVE0` → boundary port `DDR_M` (one AXI master out of the accelerator).
- Control: boundary port `CTRL_S` (AXI4-Lite in) → a 2nd interconnect → each
  `*_0:axi4target` + `axidma_0:<control slave>`.
- Stream: `axidma_0:<AXI4-Stream master>` → `corefft_stream_adapter:s_axis*`;
  adapter `datai_*/buf_ready/datao_*/outp_ready/read_outp` ↔ `corefft_0`;
  adapter `m_axis*` → `axidma_0:<AXI4-Stream slave>`.
- Expose only `{DDR_M, CTRL_S, CLK, SLOWCLK, ARESETN}` at the `sar_datapath` boundary.

**Top SmartDesign (MSS + accelerator):**
- `ICICLE_MSS:FIC_0_AXI4_S`  ← `sar_datapath:DDR_M`   (accelerator → DDR)
- `ICICLE_MSS:FIC_0_AXI4_M`  → `sar_datapath:CTRL_S`  (CPU → control)
- `ICICLE_MSS:FIC_0_ACLK`    → `sar_datapath:CLK` (+ a CLK/8 divider → `SLOWCLK`)
- CORERESET_PF (pattern: `script_support/CORERESET.tcl`): MSS power-on reset →
  `sar_datapath:ARESETN`.
- Constraints: reuse `icicle-kit-reference-design/.../constraint/fic_clocks.sdc`.

**Build (headless):**
`run_tool -name {SYNTHESIZE}` → `{PLACEROUTE}` → `{VERIFYTIMING}` →
`{GENERATEPROGRAMMINGDATA}`; then `export` the job/bitstream.

**Bare-metal driver:** extend `sar_accel_driver.c` — per scene: program the DMA
descriptors (DDR↔CoreFFT stream) + each kernel's `axi4target` registers
(addresses, start), poll done, advance stage (resample→window→FFT→corner-turn→
FFT→detect), read `SCALE_EXP`/`BFP_SHIFT`.

## 6c. Option A — graft onto the reference design (chosen path)

The Icicle reference design generates a complete, timing-clean SoC base **headless**
on Libero 2025.2 (verified, exit 0):
`libero SCRIPT:MPFS_ICICLE_KIT_REFERENCE_DESIGN.tcl SCRIPT_ARGS:MSS_BAREMETAL+MPFS250T`
→ project `icicle-kit-reference-design/MSS_BAREMETAL_FD0AEBB9/`, top design
`MSS_BAREMETAL_FD0AEBB95776A726`, with MSS + clocks + resets + derived constraints.

Graft point: the baremetal top **exposes FIC0 at its boundary** —
`FIC_0_ACLK` (in), `FIC_0_AXI4_INITIATOR` (MSS→fabric, CPU control),
`FIC_0_AXI4_TARGET` (fabric→DDR). So the accelerator connects straight to these:

- `accel data interconnect SLAVE0` → `FIC_0_AXI4_TARGET`  (kernels/DMA → DDR)
- `FIC_0_AXI4_INITIATOR` → `accel control interconnect MASTER0`  (CPU → registers)
- drive `FIC_0_ACLK` from the fabric clock (OSC→CCC `OUT0_FABCLK_0`, 125 MHz)
- reset from CORERESET (gated by CCC `PLL_LOCK_0` + MSS DLL lock)

Two ways to assemble (same result):
1. **In the reference project:** bring the accelerator components in (regenerate the
   IP via the saved gen scripts + `create_hdl_core` for the kernels/adapter), add a
   top SD that wraps `MSS_BAREMETAL_*` + the accelerator + OSC/CCC/CORERESET, connect
   FIC0. Reuses the reference's constraints directly.
2. **In `libero_sar` (already has every component incl. MSS, OSC, CCC, CORERESET,
   both interconnects):** build the top SD here, importing the reference's
   `*_derived_constraints.sdc` + `fic_clocks.sdc`. No component re-gen needed.

Path 2 is fewer steps (libero_sar already holds all components). Then:
`run_tool SYNTHESIZE → PLACEROUTE → VERIFYTIMING → GENERATEPROGRAMMINGDATA` → bitstream.

## 7. Risks (M2-specific)

1. **Corner-turn DDR efficiency** — §2. Start T=128 + 256-bit AXI + double-buffer;
   measure in sim before trusting full-res throughput.
2. **DDR size** — ping-pong needs 640 MB. The bare-metal repo defines 1 GB
   (`DDR_SIZE 0x40000000`); REPORT.md says 2 GB. Confirm the populated size (M0
   soak test + board docs) before committing the fixed addresses in
   `ddr_layout.py` / `ddr_sar_layout.h`.
3. **AGC / detect scaling** — fabric emits uint16 magnitude + `BFP_SHIFT`; the
   host (or on-board U54) applies the dB/percentile clip. Do not truncate to uint8
   on-fabric (loses the ~50 dB scene dynamic range) unless using the on-board AGC
   path that halves the JTAG dump.
4. **Coherent vs non-coherent FIC** — start coherent (correct by default); only go
   non-coherent for bandwidth, with disciplined flush/invalidate.
5. **`SAR_ACCEL_BASE`** — placeholder until the Libero memory map fixes the real
   AXI4-Lite address; update `ddr_sar_layout.h` then.
