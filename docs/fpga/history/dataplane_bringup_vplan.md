# SAR Fabric Data-Plane Bring-Up — Register Verification Plan

Every protocol field/register below carries the mandated three axes:

1. **Stimulus Profile** — how to drive/randomize it.
2. **Completion Checker** — the *exact* response or memory change that validates it.
3. **Boundary Matrix** — max / min / overflow / illegal values to stress it.

## 0. Methodology & platform realization

A checker is only valid if it is **observable on this board**. Three drive/observe
mechanisms, in priority order:

- **M1 — JTAG poke** (OpenOCD `mww <addr> <val>` / `mdw <addr>`, hart halted).
  Direct, but bounded by the **HID budget** (≈ examine + a few dozen ops before the
  flaky hidapi crashes — keep each script short, one `shutdown` per burst). Good for
  AXI4-Lite control regs; cannot sustain bulk or long polls.
- **M2 — autonomous-firmware harness** (the `u54_1()` self-test pattern). The hart
  drives the full stimulus/checker on-silicon with **no debugger in the loop**, then
  latches results to fixed globals the host reads with ONE short M1 burst. This is the
  only way to exercise long sequences / data movement under the HID wall. Randomness:
  seed an LFSR from the `mcycle` CSR (no host RNG needed); log the seed to a global so a
  failing case is replayable.
- **M3 — off-board RTL/HLS co-sim** (cocotb/SmartHLS vs `src/fixedpoint.py`). The
  bit-accurate mirror: every boundary case below must pass here *before* it is trusted
  on silicon. Failures that reproduce in M3 are RTL bugs; failures only on silicon are
  integration (clock/reset/decode/coherency).

**Pass/fail discipline:** a register passes only when (a) its Completion Checker fires
AND (b) every Boundary Matrix entry produces the *specified* response — and critically,
**no illegal input may hang the AXI bus** (no-response → kernel busy-forever is the exact
failure we are chasing). "Clean error" = SLVERR/decode-error returned, hart read fails
*fast*, kernel does not assert/keep busy.

---

## 1. LIVE BUG — resample data-plane isolation ladder (do this first)

Current silicon state: `K_RESAMPLE @0x60003008 = 1` (busy, never clears); `DMA_CTRL
@0x60005000` read-faults; control plane otherwise clean. The ladder localizes *which*
AXI master transaction stalls. Each rung is one short M1 burst (hart halted first).

| Rung | Stimulus | Completion Checker | If it fails → |
|---|---|---|---|
| L0 | `mdw` each DMA reg 0x60005000/04/08/60..6c | every offset returns a value (no "Failed to read") | DMA slave not mapped / wrong base → Libero AXIIC SLAVE5 connection |
| L1 | seed SCRATCH dst sentinel: `mww 0x98000000 0xDEADBEEF`; set RESAMPLE ARG0=0x88000000, ARG1=coef_idx, ARG2=coef_wq, ARG3=0x98000000; `mww 0x60003008 1` | within ~1 s poll: `0x60003008`→0 **and** `0x98000000`≠0xDEADBEEF | status stays 1 → master stalled on a **read** (ARG0/1/2). sentinel intact + status 0 → master never issued a **write** |
| L2 | point ALL of ARG0/1/2 at one known-good, CPU-pre-filled 4 KiB DDR page (0x88000000) | status→0 | a *specific* source addr (coeff bank 0xB0148000 / SCRATCH 0x98000000) is the unreachable one → data-FIC address-decode gap |
| L3 | drive a **minimal 64-beat** job (ARG sizes = 64) instead of full frame | status→0 fast | full-frame only → master works but DDR region/length crosses an unmapped window |
| L4 | repeat L1 with data FIC forced **coherent** vs **non-coherent** build | dst changes & matches `fixedpoint.py` | matches only coherent → cache flush/invalidate missing around fabric DDR |

The rung that first turns `status 1→0` (or first writes the dst) is the boundary between
working and broken in the data path.

---

## 2. Register-by-register plan

### A. HLS kernel control window (×5: CORNER_TURN 0x60000000, WINDOW …1000, DETECT …2000, RESAMPLE …3000, FFT_FEEDER …4000)

**A1 — START/STATUS `+0x08`** (write 1 = start; reads 0 = idle/done)
- *Stimulus:* write `1` to start. Randomize **context not value**: sweep the 5 kernel
  bases; vary arg setup order; inject back-to-back re-start and start-while-busy; M2 loop
  over 1000 start/done cycles with LFSR-chosen args.
- *Completion Checker:* read transitions `1→0` within the spin budget **AND** the dst
  region (ARG3/ARG1-out) differs from a pre-written sentinel. Status-clear alone is
  insufficient (a kernel could clear without moving data) — require the side effect.
- *Boundary:* `0`→no-op (stays idle); `2`,`4`,`0x80000000`,`0xFFFFFFFF`→bit0 only may
  start, upper bits ignored (read-back proves which bits are RAZ); start-while-busy→
  ignored, no corruption; read-before-first-start→`0`.

**A2–A5 — ARG0..ARG3 `+0x0c/+0x10/+0x14/+0x18`** (DDR pointers; FFT_FEEDER ARG1 = nbeats scalar)
- *Stimulus:* pointers = random **8-byte-aligned** addr in `[0x80000000, 0xC0000000)`
  (64-bit beat movers). nbeats = random `[1, SAR_FRAME_BEATS]`. Drive via `mww` / `sar_reg_w`.
- *Completion Checker:* (i) read-back **exact equality** (AXI4-Lite latch); (ii) functional —
  pre-seed src with a known pattern, after start+done verify `dst == f(src)` byte-exact vs M3.
- *Boundary:* `0x00000000` (null ptr → **clean error, not bus hang**); `0xFFFFFFF8` (above
  DDR → SLVERR); unaligned `+1/+4` (must error, never corrupt); `0x60000000` (the fabric
  ctrl space — a kernel master must NOT be allowed to write its own control plane);
  `0x20220000` (eNVM); nbeats `0` (no-op, not run-forever) and `0xFFFFFFFF` (clamp/error).

### B. CoreAXI4DMAController (DMA_CTRL 0x60005000) — currently read-faulting

**B1 — DESC0.CONFIG `+0x60`** (bit31 valid, bit3 dest-incr, bit0 src=stream; full field set per IP handbook)
- *Stimulus:* known-good `0x80000009`; then per-bit sweep + the handbook's data-width/op
  fields (driver flags these as **unconfirmed** — enumerate every documented field).
- *Completion Checker:* read-back equality; after START_OP, DSTADDR memory receives the
  streamed beats AND INTR0_STATUS bit0 sets.
- *Boundary:* valid=`0`→must not fetch; src=memory while stream is the actual source
  (mismatch)→error not hang; reserved/illegal opcodes→SLVERR.

**B2 — DESC0.BYTES `+0x64`**
- *Stimulus:* random in `[8, SAR_FRAME_BEATS*8]`, 8-byte-multiple; plus the exact
  `SAR_FRAME_BEATS*8` (=128 MiB transfer) used in `fft_pass`.
- *Completion Checker:* exactly BYTES bytes land at DSTADDR (first/last beat sentinel
  check); INTR0 sets only after the **last** beat.
- *Boundary:* `0` (no transfer / immediate done — must not stall); not-8-multiple (error);
  > region size → must not run past DSTADDR+region into a neighbor buffer.

**B3 — DESC0.SRCADDR `+0x68`** (unused when src=stream; populated path otherwise)
- *Stimulus:* aligned DDR addrs; with src=stream this is don't-care → verify it is ignored.
- *Completion Checker:* in stream mode, changing SRCADDR has **no** effect on output (proves stream wins).
- *Boundary:* null / above-DDR / unaligned with src=memory → SLVERR.

**B4 — DESC0.DSTADDR `+0x6c`**
- *Stimulus:* random aligned DDR; plus the real `BUF_SCRATCH`/`BUF_SIG` targets.
- *Completion Checker:* the moved data appears **only** at DSTADDR; a guard word just
  below/above DSTADDR stays untouched (no off-by-one / wrap).
- *Boundary:* null, above-DDR, unaligned, overlap with SRC region.

**B5 — START_OP `+0x04`** (write bit n starts descriptor n)
- *Stimulus:* write `0x1` (desc0); sweep other bits to confirm only implemented descriptors react.
- *Completion Checker:* INTR0_STATUS bit0 sets after the transfer; status before start is clear.
- *Boundary:* start with **invalid** (valid=0) descriptor → no transfer, no hang; double-start.

**B6 — INTR0_STATUS `+0x08`** (W1C, bit0 = desc0 complete)
- *Stimulus:* read during/after transfer; write-1-to-clear.
- *Completion Checker:* reads `0` before done, `1` after the last beat; writing `1` clears
  it to `0`; writing `0` does nothing.
- *Boundary:* clear-before-set (no effect); double transfer without clear (sticky until W1C).

### C. Accelerator top status / BFP_SHIFT (SAR_ACCEL_BASE 0x60000000) — **decode ambiguity to resolve**

`SAR_REG_STATUS=0x60000004` and `SAR_REG_BFP_SHIFT=0x6000001C` *alias the K_CORNER_TURN
window*. Bring-up must decide whether these are real top-level regs or stray reads of the
corner-turn kernel's AXI4-Lite space.
- *Stimulus:* read both with all kernels idle, then after a full pipeline run.
- *Completion Checker:* STATUS bit0 (DONE) sets only after K_DETECT completes; bit2 (ERR)
  sets on any kernel SLVERR; BFP_SHIFT holds the CoreFFT block exponent (range-checkable
  `[-N, +N]`) and matches `fixedpoint.py`'s emitted shift.
- *Boundary:* read while busy (DONE must be 0); force a kernel error (illegal arg) → ERR=1;
  BFP_SHIFT out of `[-64,64]` → flag as wrong wiring.

### D. Job descriptor `sar_job_t` @ 0xB0040000 (DDR, host→app contract, 96 B packed)

**D1 — magic `+0x00`**
- *Stimulus:* correct `0x53415231`; random 32-bit otherwise.
- *Completion Checker:* `sar_job_load` returns OK only on exact match (g_sar_status path);
  any other value → `SAR_SEQ_BAD_JOB` (status 1).
- *Boundary:* off-by-one `0x53415230/32`, byte-swapped `0x31524153`, `0x00000000`, `0xFFFFFFFF`.

**D2/D3 — M, N `+0x04/+0x08`** (input rows/cols)
- *Stimulus:* random `[1, 8192]`; plus the real scene dims.
- *Completion Checker:* resample PASS-1 loop runs exactly M iters, PASS-2 runs Np; output
  frame dims match; `invord[i]` never indexes a SCRATCH row ≥ Mp.
- *Boundary:* `0` (degenerate — must early-exit cleanly, not loop), `8193`/`0xFFFFFFFF`
  (> grid → must reject, not over-run buffers), `M>N`, `N` not pow2.

**D4/D5 — fft_r, fft_a `+0x0c/+0x10`**
- *Stimulus:* `8192` (the only built size) + non-8192 to prove rejection.
- *Completion Checker:* CoreFFT runs the fixed 8192; mismatch with built length → rejected.
- *Boundary:* non-pow2, `0`, `>8192`.

**D6 — out_dtype `+0x14`** (0=uint16, 1=uint8)
- *Stimulus:* `{0,1}`; illegal `2..0xFFFFFFFF`.
- *Completion Checker:* OUT region written at the dtype's stride (2 B vs 1 B/px); dump size matches.
- *Boundary:* illegal dtype → default-to-uint16 or reject (define which), never undefined stride.

**D7 — bfp_in_exp `+0x18`** (signed input-quant exponent)
- *Stimulus:* random `int32` in `[-32, 31]`; the host's real value.
- *Completion Checker:* output magnitude scale tracks `2^exp` vs `fixedpoint.py`.
- *Boundary:* extreme `±denorm`, `INT32_MIN/MAX` (must saturate, not UB-shift).

**D8/D9 — sig_len, sig_crc `+0x1c/+0x20`**
- *Stimulus:* correct len/CRC of a seeded SIG; corrupted CRC.
- *Completion Checker:* `sar_job_check_sig` returns OK only on CRC match (note: the live
  `sar_form_image` path does NOT call it — verify whether it should before trusting SIG).
- *Boundary:* len `0`, len > SIG region (256 MiB), CRC `0`/`0xFFFFFFFF`.

**D10–D17 — sig/kr/kc/tanphi/win/out/scratch addr (64-bit each)**
- *Stimulus:* the fixed layout addrs; random aligned DDR; note `sar_form_image` currently
  uses the compiled `SAR_*_ADDR`/`BUF_*` not these fields — so the test is **read-back +
  documenting the dead-field divergence** (a real correctness gap).
- *Completion Checker:* if/when wired, the kernels' masters target exactly these addrs
  (cross-check ARG read-backs in §A).
- *Boundary:* null, unaligned, above-DDR, overlap between SIG/SCRATCH/OUT (aliasing → corruption).

### E. Data-plane buffers (the AXI targets — root of the live bug)

`coef_idx`/`coef_wq` (0xB0148000+ banks), SIG 0x88000000, SCRATCH 0x98000000, OUT 0xA8000000.
- *Stimulus:* CPU pre-seeds each with a recognizable pattern (addr-as-data) and a guard
  word above/below; M2 runs one kernel.
- *Completion Checker:* idx value `-1`(0xFFFFFFFF) for the zeroed-geom self-test reads back
  intact from DDR (proves CPU writes are **coherent to the fabric** — if it reads garbage,
  cache flush is missing); after a kernel run, dst pattern == `f(src)` byte-exact vs M3;
  guard words untouched.
- *Boundary:* coeff `idx` at the legal extremes `-1, 0, N-1, N`(out-of-range must zero-fill
  not read OOB), `wq` at `0, 32767, -1`; addresses at DDR-window edges; a deliberately OOB
  `idx` to confirm the fabric clamps/zero-fills (matches `sar_interp_coeffs` `idx=-1` path)
  rather than issuing an unbounded AXI read (← the suspected hang mechanism).

---

## 3. Cross-cutting illegal-value catalog (apply to every pointer/length field)

| Class | Value | Required response (NEVER a bus hang) |
|---|---|---|
| Null | `0x00000000` | SLVERR / fast read-fail |
| Above DDR | `≥0xC0000000` | decode error |
| Control aliasing | `0x6000_xxxx` | reject — master may not hit ctrl plane |
| Misalign | addr `&7 != 0` | error for 64-bit movers |
| Length overflow | `> region size` | bounded to region, INTR fires, no neighbor write |
| Length zero | `0` | immediate done, no stall |
| OOB index | `idx<0 or ≥N` | zero-fill (per `sar_interp_coeffs`), no OOB AXI read |

## 4. Coverage closure

- **Per register:** all 3 axes green in **M3 (sim)** → then **M2 (autonomous silicon)** →
  spot-checked in **M1 (JTAG)**.
- **System:** the §1 ladder reaches L4 with byte-exact dst vs `fixedpoint.py`, then the full
  `sar_form_image` returns `SAR_SEQ_OK` (status 0) with `g_sar_done=0xC0FFEE01`.
- **Regression:** every boundary case that ever hung the bus becomes a permanent M2 case
  (replayable via its logged LFSR seed).
