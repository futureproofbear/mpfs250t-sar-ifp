# SAR Pipeline — Full Process (host → board → host)

> **✅ STATUS 2026-07-04 (LATEST — supersedes the CoreFFT/HLS-FFT notes below):** Pipeline **VALIDATED
> end-to-end on silicon, image corr=0.9923 vs golden**. The FFT now runs on the **MSS U54 CPU**
> (`src/sar/sar_fft.c`, L1-BFP) — the HLS `K_FFT` butterfly is unsynthesizable on SmartHLS 2025.2 (drops
> the twiddle term → passthrough). All other stages (resample/corner-turn/window/detect) stay on the
> fabric. See **[`SAR_PIPELINE_STATUS.md`](SAR_PIPELINE_STATUS.md)** for current status, per-stage timing,
> and the latency roadmap. The CoreFFT-era notes below are historical.
>
> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`PROJECT_SOURCE_OF_TRUTH.md`](../PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". Sections below that describe the CoreFFT output going to a `CoreAXI4DMAController`
> / S2MM stream descriptors predate this and are stale — the live FFT output path is now
> `CoreFFT → gearbox (with output skid FIFO) → fft_unloader (AXI4-Stream slave → AXI4 write master) → DDR`,
> driven by control base `K_FFT_UNLOADER @0x6000_5000` (no descriptors/TLAST).

End-to-end description of how a SAR scene becomes a focused image on this board, **anchored to the
base Python code** (the golden reference) and the **as-built fabric kernel contracts** (verified
against the generated SmartHLS RTL). Where the two disagree, the as-built fabric wins and the
discrepancy is called out.

**Authoritative sources** (read these, not paraphrases):
- Algorithm truth: [`src/form_image_pfa.py`](../../src/form_image_pfa.py) — the float PFA reference (`resample_kspace`, `focus`, `transform2d`).
- **Exact on-board datapath**: [`mpfs/host/emulate_fabric.py`](../../mpfs/host/emulate_fabric.py) — the quantized, kernel-decomposed path the firmware must replicate bit-for-bit in structure.
- Host serialization + coeffs: [`mpfs/host/serialize_inputs.py`](../../mpfs/host/serialize_inputs.py), [`mpfs/host/ddr_layout.py`](../../mpfs/host/ddr_layout.py).
- FFT/BFP contract: [`mpfs/host/fft_golden.py`](../../mpfs/host/fft_golden.py).
- Board orchestration: [`sar_sequencer.c`](../../mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/sar/sar_sequencer.c), coeffs [`sar_resample_coeffs.c`](../../mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/sar/sar_resample_coeffs.c), map [`ddr_sar_layout.h`](../../mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/sar/ddr_sar_layout.h) / [`sar_kernels.h`](../../mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/sar/sar_kernels.h).
- Topology/interconnect: [`AMBA_ARCHITECTURE.md`](AMBA_ARCHITECTURE.md).

---

## 0. Algorithm & partition

The board runs the **Polar Format Algorithm (PFA)**: it resamples the polar-collected phase
history onto a uniform Cartesian k-space grid (a 2-pass keystone), windows it, takes a 2-D FFT,
and detects magnitude. Heavy compute is in the FPGA fabric; the **RISC-V (U54_1) only programs
registers and polls done** — it does not touch sample data except to compute small per-line
resample coefficients.

| Where | Does |
|---|---|
| **Host PC (Python)** | parse CPHD → geometry → quantize to int16 BFP → serialize SIG + small geometry tables + JOB → JTAG-load DDR. Post: rescale, orient, AGC, compare. |
| **U54_1 (bare-metal C)** | read JOB, (optionally CRC-check SIG), compute keystone idx/wq per line, sequence the 5 kernels + FFT feeder/unloader, latch status. |
| **FPGA fabric** | resample / corner-turn / window / detect kernels + CoreFFT + `fft_feeder`/`fft_unloader` (the DMA was removed 2026-07-04), all mastering DDR over FIC0. |

---

## 1. Pipeline stages (the reconciled, authoritative order)

From `emulate_fabric.py` (the golden fabric path) and matched by `sar_sequencer.c::sar_form_image`:

```
SIG (M×N complex int16 I/Q)
 1. range resample   (per pulse, ×M)      SIG     → SCRATCH[invorder[i]]   (pulse-sorted by tan φ)
 2. corner-turn      (transpose)          SCRATCH → SIG
 3. azimuth resample (per range bin, ×Np) SIG     → SCRATCH                (now uniform k-space)
 4. window           (2-D Hamming)        SCRATCH → SCRATCH (in place)
 5. range FFT        (FEED→CoreFFT→UNLOAD) SCRATCH → SCRATCH
 6. corner-turn      (transpose)          SCRATCH → SIG
 7. azimuth FFT      (FEED→CoreFFT→DMA)    SIG     → SIG
 8. detect           (|·| magnitude)      SIG     → OUT
```

Stages 1–3 are `resample_2pass()`; 4 is `window`; **5+6+7 are one 2-D FFT factored** into
row-FFT → transpose → row-FFT (the only way a 1-D 8192-pt CoreFFT engine does a 2-D transform);
8 is detect. The golden's single `np.fft.fft2` (`emulate_fabric.py:112`) ≡ stages 5–7.

> **Reconciliation note (2026-06-30):** an earlier `AMBA_ARCHITECTURE.md §10.4` table interleaved
> the FFTs *between* the two resamples (range-resample → range-FFT → corner → azimuth-resample → …).
> That is **wrong** — neither the golden nor `sar_sequencer.c` does this. Both resamples complete
> *before* any FFT, and the window sits between resample and FFT. §10.4 has been corrected to match.

**Order facts the firmware honors** (golden subtleties):
- Window is **data-extent Hamming only** (`hr[:n]=hamming(n)`, zero in pad) — the kernel forms
  `hamr[j]·hamc[k]>>15` on the fly from two 1-D Q15 tapers (HAMR/HAMC). Not a full 128 MB taper.
- The fabric FFT is **plain** (`fft2`, no `ifftshift/fftshift`). Centering/orientation is recovered
  as **host post-processing** after dump, NOT on-board (`emulate_fabric.py:119-133` candidate search).
- Output is laid out **`[range][cross]`** (transpose of the float ref) — host resolves orientation.
- `idx < 0 → 0` (out-of-grid) is how the FFT **zero-pad** region is filled, via padded query grids.

---

## 2. DDR memory map & JOB descriptor

Cached LPDDR4 window `0x8000_0000–0xBFFF_FFFF`. (`ddr_sar_layout.h`, mirror of `ddr_layout.py`.)

| Region | Base | Role |
|---|---|---|
| app/heap/stack | `0x8000_0000` | firmware |
| **SIG** | `0x8800_0000` | input I/Q **and** reused as transpose scratch mid-run |
| **SCRATCH** | `0x9800_0000` | primary intermediate |
| **OUT** | `0xA800_0000` | detected magnitude (uint16) |
| TABLES | `0xB000_0000` | KR/KC/TANPHI/WIN + **JOB `0xB004_0000`** |
| GEOM | `0xB010_0000` | F0/DF/PR/TANS/INVORDER, KRGRID/KCGRID, HAMR/HAMC |
| COEF banks | `0xB014_8000` | per-line resample IDX(int32)/WQ(int16), double-buffered |
| M2 results | `0xB005_0000` | bring-up harness table |
| **CRC/PIPE mailbox** | `0xB005_8000` | host↔hart command mailbox (see §6) |

**JOB** (`sar_job_t`, 96 B at `0xB004_0000`; `pack_job` in `ddr_layout.py`): `magic='SAR1'`, `M`,`N`
(real pulses×samples), `fft_r=pow2(N)`, `fft_a=pow2(M)`, `out_dtype`, `bfp_in_exp`, `sig_len`,
`sig_crc`, then 64-bit `sig/kr/kc/tanphi/win/out/scratch` addresses. ⚠ `SGN` (FFT direction, from
CPHD metadata) is **not** currently carried in JOB — see §8 gaps.

> ⚠ **SIG is reused as transpose scratch** once resample consumes the raw input (stages 2/6 write
> SIG). A re-run must **reload SIG** first.

---

## 3. Host pre-processing (`serialize_inputs.py`)

1. Parse CPHD → per-pulse geometry; compute `f0[M]`, `df[M]`, `pr[M]` (radial projection),
   `tan_phi[M]`; sort by `tan_phi` → `tan_s` (ascending) and `inv_order` (pass-1 dst row).
2. Build **padded query grids** `KRGRID[Np]`, `KCGRID[Mp]` — real grid in `[0:n]`/`[0:m]`, an
   out-of-range **sentinel** beyond, so pad-region queries return `idx=-1` → zero-fill.
3. Build data-extent Hamming tapers `HAMR[Np]`, `HAMC[Mp]` (Q15, zero in pad).
4. Quantize I/Q to int16 **block-floating-point**: `exp=ceil(log2(max/32767))`, `code=floor(val/2^exp)`
   (truncating). `bfp_in_exp=exp`. CRC32 (zlib/IEEE-802.3) of `sig.bin` → `sig_crc`.
5. Self-check: quantized coeffs vs float `resample_kspace` must hit `corr ≥ 0.999` before emit.
6. Emit `sig.bin`, geometry `.bin`s, `layout.json`, and the packed JOB.

Host then JTAG-loads each blob to its DDR address (slow — see §7) and verifies (§6).

---

## 4. On-board kernels (verified contracts)

All 5 kernels share the SmartHLS control layout: **`START 0x08`** (write 1 = go; read 0 = done —
no STATUS/ERR/IRQ register), args **`ARG0 0x0c, ARG1 0x10, ARG2 0x14, ARG3 0x18`**, each a single
32-bit word (pointers are 32-bit DDR addresses). **Frame dims 8192² are compile-time-baked**; the
only runtime-variable is `fft_feeder.nbeats`. Control windows on CIC (FIC0) at `0x6000_n000`.

| Kernel | Base | Signature (verified vs RTL) | ARGs |
|---|---|---|---|
| corner_turn | `0x6000_0000` | `corner_turn(src,dst)` | 0=src 1=dst |
| window | `0x6000_1000` | `window(in,hamr,hamc,out)` | 0=in 1=hamr 2=hamc 3=out |
| detect | `0x6000_2000` | `detect(in,out)` uint16 mag | 0=in 1=out |
| resample | `0x6000_3000` | `resample(in,idx,wq,out)` **per line** | 0=in 1=idx 2=wq 3=out |
| fft_feeder | `0x6000_4000` | `fft_feeder(src,&stream,nbeats)` | 0=src 1=nbeats |
| fft_unloader | `0x6000_5000` | HLS kernel (AXI4-Stream slave → AXI4 write master), control base `K_FFT_UNLOADER`; drains CoreFFT output to DDR (**replaced the CoreAXI4DMAController S2MM path 2026-07-04**) | dst + nbeats (see `hls_fft_unloader/`) |

Element format throughout: complex int16 packed `uint32 = (I<<16)|Q`; tapers Q15; detect out uint16.
resample lerp: `out[i] = in[idx[i]] + (in[idx[i]+1]-in[idx[i]])·wq[i]/32768`, `idx<0 → 0`.

---

## 5. Keystone coefficient generation (`sar_resample_coeffs.c`)

The full 8192² idx/wq grid (~768 MB) is never stored/transferred; the MSS computes it **per line**
from the small geometry tables, double-buffered (bank `b` streams while bank `b^1` is filled):
- **Pass 1 (range), per pulse i:** source positions `kr[i,j] = 2·pr[i]/C · (f0[i] + j·df[i])`,
  `j=0..N-1`; `interp_coeffs(KRGRID, kr_i)`; result row = `INVORDER[i]`.
- **Pass 2 (azimuth), per range bin j:** source positions `src[k] = KRGRID[j]·tan_s[k]`, `k=0..M-1`;
  `interp_coeffs(KCGRID, src)`.

`sar_interp_coeffs` mirrors host `interp_coeffs` exactly (two-pointer, asc/desc xp, `idx=-1` for
out-of-range, `wq=round(frac·32768)` clamped Q15) — verified corr=1.0 vs `np.interp`.

---

## 6. The FFT datapath (fft_feeder → CoreFFT → fft_unloader)

> **Update 2026-07-04:** the `CoreAXI4DMAController` (S2MM) that used to drain CoreFFT→DDR is
> **removed** — it deadlocked on the 2nd back-to-back AXI4-Stream S2MM transaction. It is replaced by
> the HLS `fft_unloader` kernel (`mpfs/fpga/hls_fft_unloader/fft_unloader.cpp`): an AXI4-Stream **slave**
> input + a plain AXI4 **write master** to DDR, the same proven pattern as the other HLS kernels. It
> drains the whole frame continuously — no descriptors, no TLAST. The gearbox also gained an **elastic
> output skid FIFO** (64-deep, `syn_ramstyle=registers`) so it drains CoreFFT unconditionally and
> backpressures the unloader instead of CoreFFT (a 2nd range-FFT bug wedged the in-place CoreFFT when
> backpressure reached its `read_outp` mid-unload). Sim-validated in `mpfs/fpga/sim/corefft_stream64_bp_tb.v`.

```
DDR ─(FEED master)─► AXI4-Stream(64b) ─► gearbox ─► CoreFFT(8192,16,BFP) ─► gearbox(+skid FIFO) ─► AXI4-Stream(64b) ─► fft_unloader(AXI4 write master) ─► DIC→ID_FIX→FIC0 ─► DDR
```
CoreFFT is in-place radix-2, native (non-AXI) handshake; the **gearbox** (`corefft_stream64_adapter.v`)
bridges the 64-bit beat stream (2 samples/beat) to CoreFFT's 1-sample/cycle rate and now holds the
output skid FIFO. Firmware `fft_pass()` **arms the unloader, then the feeder, and waits for both idle**
(no DMA descriptor logic). `nbeats = 8192·8192/2 = 33,554,432`.

> **Superseded (old DMA path, kept for context):** the removed DMA was armed before the feeder started
> (descriptor 0: dst, byte-count `nbeats·8`, config `valid|dest-incr|src=stream`), polled via INTR0
> (`0x10`, W1C at `0x18`), and required the CIC Slave-5 AXI4-Lite fix ([`dma_fix_plan.md`](dma_fix_plan.md)).
> None of that applies to the current `fft_unloader` path.

---

## 7. Coherency & transport

- **Coherency:** all buffers are cached but the fabric reaches DDR over the **non-coherent FIC0**.
  The firmware must **flush L2 before `START`** (fabric sees loaded input / CPU-written coeffs) and
  **invalidate before reading results** (CPU/host sees fabric output). `sar_form_image` currently
  uses `fence rw,rw`; replace with explicit L2 flush/invalidate if FIC0 is non-coherent in the build.
- **Transport:** JTAG bulk DDR load is **~84 kbit/s** (~111 s/MB; 97 MB ≈ ~2.7 hr) — slow but
  reliable run-to-completion. Verify with the on-target CRC mailbox, not slow readback (§ below).

---

## 8. How to run it (the `PIPE` mailbox command)

`u54_1.c` runs the M2 bring-up battery at boot, then enters a **command loop** on the mailbox at
`0xB005_8000` (`{+0 cmd, +4 base, +8 len, +C result, +10 status, +14 seq}`):

| cmd | value | action |
|---|---|---|
| `CRC3` | `0x43524333` | CRC32 `[base,base+len)` → `result` (verify a JTAG-loaded region) |
| `PIPE` | `0x50495045` | run `sar_form_image(len)` (len=spin_limit, 0=default) → `result` = `sar_seq_status_t` |

**Run sequence (host, OpenOCD @ 6 MHz):**
1. Load `sig.bin`→SIG, geometry/tapers→GEOM, JOB→`0xB004_0000` (each `load_image`, run to completion).
2. `CRC3`-verify SIG == `sig_crc` (seconds; see [`run_crc_verify.sh`](../../mpfs/host/run_crc_verify.sh)).
3. Write mailbox `base=0`,`len=0`,`cmd=PIPE`; **`resume`** hart1.
4. Poll: halt, read `status`==`0xC0FFEE03` and `result` (0=`SAR_SEQ_OK`, else the failing stage:
   `TIMEOUT_RESAMPLE/WINDOW/FFT1/CORNER/FFT2/DETECT/DMA`).
5. Dump OUT (`0xA800_0000`, `pow2(M)×pow2(N)×2 B`) over JTAG.

`result` codes come from `sar_seq_status_t` (`sar_sequencer.h`). Bounded per-stage spins mean a
stuck kernel yields a TIMEOUT code, never an un-haltable lock-up.

---

## 9. Host post-processing & verification

1. **Rescale** OUT codes by the net BFP exponent (`bfp_in_exp` + per-stage FFT shifts; CoreFFT's
   `SCALE_EXP` sideband). Host compare is scale-invariant (corr/NRMSE), so an overall power-of-2
   from CoreFFT block scheduling is acceptable.
2. **Orient/center:** the fabric did a plain FFT, so the host searches `{identity, transpose,
   fftshift, fftshift+transpose, transpose+fftshift}` and keeps the candidate with `corr > 0.99`
   vs the float golden (`emulate_fabric.py:119-133`, `dump_output.py`).
3. **Compare** to `form_image_pfa.py` golden: PASS when `corr ≥ ~0.99` (scale-invariant).
4. Optional AGC (uint8 path) applied host-side using BFP_SHIFT.

---

## 10. Status & known gaps

- **Built & wired (2026-06-30):** `sar_form_image` links into the firmware via the `PIPE` mailbox
  command; coeff/order/kernel contracts validated against the Python golden.
- **First on-silicon `PIPE` run (2026-06-30): stages 1–4 ran, stage 5 (range FFT) appeared to hang.**
  Stages 1–4 (range resample, corner-turn, azimuth resample, window) reached *done*; the range-FFT
  stage looked stuck.
- **REAL ROOT CAUSE — the bitstream does NOT meet timing at 125 MHz (RESOLVED 2026-06-30).** After a
  long on-silicon debug (SmartDebug active-probes, DMA-sentinel test), the cause is **not** the FFT
  stream datapath at all but **P&R timing failure on the fabric clock.** `pinslacks.txt` shows
  **25,847 of 315,348 pins with negative slack, worst −3.7 ns, ALL on the single CCC OUT0 125 MHz
  fabric clock** — real same-clock **setup** failures, not CDC/false-paths. Violations by block:
  CT 14341, CIC 3957, DMA 3349, FEED 1973, DIC 1826, RES 249, DET 102, WIN 50; **CoreFFT itself = 0
  violations.** Consequence: silicon ran **non-deterministically** — the FFT compute looped endlessly,
  and stages 1–4 "completed" but almost certainly with **corrupt data** (only completion was ever
  checked, never correctness). This **supersedes** the earlier per-symptom theories (DMA descriptor
  model, gearbox framing, dead-SLOWCLK); the DMA external-stream-descriptor fix itself remains correct.
- **FIX — lower the fabric clock.** CCC OUT0 **125 → 62.5 MHz**, OUT1 (CoreFFT SLOWCLK)
  **15.625 → 7.8125 MHz** (keep SLOWCLK ≤ CLK/8 for the in-place CoreFFT). Worst path ~11.7 ns < 16 ns
  @ 62.5 MHz. Done **headless** (`PF_CCC_C0_62p5.tcl` + `reconfig_ccc_62p5.tcl`; verified generated
  SDC OUT0 ×5/4 = 62.5, OUT1 ×5/32 = 7.8125), then re-assemble SAR_TOP (`build_sartop.tcl`) + gated
  build. Trade-off: 62.5 MHz **halves fabric + FIC↔DDR throughput** (perf hit, fine for bring-up).
- **New build safety:** `build_timed.tcl` = synth → P&R → VerifyTiming → parse `pinslacks.txt` →
  **ABORT before bitstream if any negative slack.**
- **Lesson (standing rule):** ALWAYS verify P&R timing closure before blaming logic/firmware; "stage
  completes" ≠ "data correct" ≠ "timing met"; Libero programs timing-failing bitstreams **silently**;
  `*_sdc_errors.log` = SDC *syntax*, not slack.
- **Status:** 62.5 MHz timing closure **PROVEN (2026-07-01).** Headless P&R of the 62.5 MHz design
  (with the CoreFFT `CLK`↔`SLOWCLK` false-path `sar_fft_cdc.sdc`) **closes timing completely — 0 setup
  violations of 315,349 pins and 0 hold violations** (vs 25,847 setup violations, worst −3.7 ns, at
  125 MHz), validated via the Libero VM-netlist custom flow (`mpfs/fpga/libero_vm`). The timing-closure
  root cause and the clock-lowering fix are **confirmed**. **Caveat:** a fully *bootable* bitstream still
  needs the SAR_TOP SmartDesign rebuilt with the (already regenerated) 62.5 MHz CCC — the PolarFire-SoC
  MSS is coupled to the SmartDesign flow and resists the pure headless netlist flow; verified recipe in
  [`SAR_TOP_RECOVERY.md`](SAR_TOP_RECOVERY.md). Firmware still valid: `PIPE`/`CRC` mailboxes, DMA
  external-stream-descriptor (STR0ADDR `0x460`/cfg `0xD`), bounded-wait harness. See
  [`SMARTDEBUG_RUNBOOK.md`](SMARTDEBUG_RUNBOOK.md).
- **Gaps to close:** (a) `SGN` (FFT direction) not in JOB — fixed direction for now, host handles
  conjugation; (b) `sar_form_image` reads `M,N` from JOB but kernels are hard-8192 — scenes must be
  ≤8192² and are zero-padded; (c) `fence` may need replacing with explicit L2 flush/invalidate; (d)
  BFP_SHIFT is not yet read back to the host from the per-kernel path (host compare is scale-invariant).

### 10.1 On-silicon checkpoint — 2026-07-02 (the timing fix was necessary but not sufficient)

Running the 62.5 MHz bitstream on silicon revealed the earlier "stages 1–4 completed" claim was
optimistic: at 125 MHz (timing-failing) the pipeline ran non-deterministically, so *nothing* was
truly validated. With timing closed at 62.5 MHz, the pipeline stalled at **stage 1 (resample)** — a
**data-plane hang**, not the FFT. Full chase in memory `m3-pipeline-silicon-status`,
`sar-onsilicon-fabric-dataplane`, and [`LIBERO_HEADLESS_PLAYBOOK.md`](LIBERO_HEADLESS_PLAYBOOK.md):

- **ROOT CAUSE #2 (data-plane hang) — FIC embedded DLLs don't lock at 62.5 MHz.** Lowering the fabric
  clock dropped FIC0/1/2 below their DLL lock band, so the fabric→MSS→DDR path (`DIC→sar_axi_idconv→
  MSS FIC_0_AXI4_S`) hung for *every* master (proven: the on-chip DMA hung the same way, not just the
  kernels). Measured: `DLL_STATUS_SR @0x2000215C` = `0x00080010` (FIC0/1/2 LOCK=0). **FIX: regenerate
  the MSS with the FIC DLLs bypassed** (`pfsoc_mss -GENERATE`, `FIC_n_EMBEDDED_DLL_USED=false` →
  `MSS_BYP_BYP_BYP_BYP_BYP_syn_comps`). At 62.5 MHz the DLL is unnecessary (16 ns period absorbs the
  ~ns insertion delay). **Verified on silicon:** `DLL_STATUS_SR` → `0x000F0017` (LOCK=1=bypassed-ready),
  full M2 self-test battery passes, and **`sar_form_image` runs the resample over the WHOLE frame —
  13,826 lines (5,634 range + 8,192 azimuth), both passes.** The data plane is fixed end-to-end.
- **The "FFT stall" is real and separate — now reached for the first time.** With the data plane
  fixed, the pipeline advances resample→corner→window and stalls at **stage 5 (range FFT):
  `sar_form_image` returns 4 = `SAR_SEQ_TIMEOUT_FFT1`.** Mechanism nailed down: CoreFFT's `BUF_READY`
  is stuck low → the gearbox (`corefft_stream64_adapter`) only asserts `s_axis_tready = in_phase &
  buf_ready`, so it never accepts a beat → `fft_feeder` runs but can't push → stalls. **Ruled out by
  static analysis:** SLOWCLK config (see clock note below) and the entire FFT stream wiring
  (`FEED→GBX→FFT→DMA`, incl. `FFT:BUF_READY→GBX:buf_ready`, all correct in `build_sartop_330.tcl`).
  **Remaining unknowns (need live probe):** is SLOWCLK physically toggling, and does CoreFFT's
  reset/init complete. Next session: SmartDebug `BUF_READY`+SLOWCLK, or add a fabric OUT0/SLOWCLK
  frequency counter to the next fabric rebuild.
- **Clock formula (settles a recurring confusion):** PolarFire CCC output = **`VCO/(DIV×4)`**, NOT
  `VCO/DIV`. Verified against the known original (VCO 5000, DIV0 10 → **125 MHz**; DIV3 25 → 50 MHz).
  The 62.5 build: VCO **3000**, DIV0 12 → **OUT0 = 62.5 MHz**, DIV1 96 → **OUT1 (SLOWCLK) = 7.8125 MHz**
  (below CoreFFT's ~10–20 MHz SLOWCLK ceiling; ratio CLK:SLOWCLK = 8:1 preserved). Confirmed correct
  by 0/0 P&R timing + the 13,826-line resample run — a fabric at 4× would fail catastrophically.
- **Resample performance (`~42 ms/pulse`, gather-bound):** the `resample.cpp` inner loop reads
  `in[idx[i]]`/`in[idx[i]+1]` at *random* source positions — a gather that cannot burst (the
  `max_burst_len(64)` pragma is inert on it), so each output sample costs 2 single-word DDR
  round-trips → dominates runtime. **Staged fixes (coded, not yet built):** **#1** local-buffer the
  source line (`static uint32_t buf[RS_IN]` + one burst load, gather from BRAM) — ~50–100× the kernel;
  **#2** `-Os→-O2` for `src/sar/` + `src/application/hart1/` (the FPU coeff interp becomes the next
  bottleneck once #1 lands). #1 needs a SmartHLS re-synth (fabric); #2 a firmware rebuild. The
  resample-2pass double-buffered coeff design (§5) skips the `b^1` precompute on the last pulse, which
  is why a too-small `spin_limit` false-times-out only the final pulse (mistaken for a hang earlier).
