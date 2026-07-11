# Milestone 1 — FFT in fabric (Microchip CoreFFT), verified by co-simulation

Goal: get one fixed-point FFT running in the fabric using the **Microchip CoreFFT
IP** and prove it matches the bit-accurate emulator (`src/fixedpoint.py`) to a
tolerance, before committing to the full datapath. Everything here is
desk/simulator work **except the final on-board step** (see the end).

Decision: **CoreFFT IP** (not the hand-written `fft1d.cpp`). Vectors and the
verdict come from `mpfs/host/fft_golden.py`.

---

## 0. CoreFFT configuration (in-place Radix-2)

Confirmed against the CoreFFT User Guide (DS50003348D). The **in-place Radix-2**
architecture is the match: it takes **natural-order input and emits natural-order
output** (it reorders internally), which is exactly our golden's convention.

| Parameter | Value | Why |
|-----------|-------|-----|
| `POINTS` | **8192** | our padded grid; 8192 is supported (powers of 2 32…16384 — *not* radix-4-restricted, so no 16384/1 GB blow-up) |
| `WIDTH` | **16** | data **and** twiddle bit width (the in-place core shares one `WIDTH`, 8–32, default 18). 16 matches our 16-bit datapath and the 16-bit hex vector format. Use 18 only with a wider vector format. |
| `SCALE` | **0** | conditional block floating point (downscale a stage only on real overflow) |
| `SCALE_EXP_ON` | **1** | export the block exponent on the `SCALE_EXP` port |

`SCALE_EXP` = number of right-shifts the core applied; **`FFT Result = DATAO ·
2^SCALE_EXP`**. This is exactly the `BFP_SHIFT` register in `regmap.md` — the host
multiplies the dumped output by `2^SCALE_EXP` to recover absolute scale.

**Bit-exact is not the goal here.** The emulator normalizes to full scale every
stage; CoreFFT's conditional BFP shifts *only when a butterfly overflows*, so it
keeps more headroom, applies fewer shifts, and its mantissa/`SCALE_EXP` differ
from the golden. The output is the same transform up to an overall power-of-2 and
a few LSBs → verify with **scale-invariant** metrics (§3).

Ports (in-place, Table 2-2): `CLK`, `SLOWCLK` (≤CLK/8, twiddle-LUT init), `NGRST`
(async, active-low; LUT auto-inits on reset), `DATAI_RE/IM`+`DATAI_VALID`,
`BUF_READY`, `READ_OUTP`, `DATAO_RE/IM`+`DATAO_VALID`, `OUTP_READY`, `SCALE_EXP`.

---

## 1. Generate the golden vectors

Match `--bits` to CoreFFT `WIDTH` (=16) so the comparison is apples-to-apples:

```
cd mpfs/host
python fft_golden.py gen --n 8192 --bits 16 --tw-bits 16 --out fft_vectors
```

Per stimulus case (`impulse`, `dc`, `tone`, `twotone`, `random`):
`<case>_in.hex`/`.csv` (input codes, natural order), `<case>_out.hex`/`.csv`
(expected output codes), `manifest.json` (`e_in`, `e_out`, `bfp_shift`,
`stage_exps`). Hex word = `(uint16(I)<<16)|uint16(Q)`, `$readmemh`-loadable.

Start with a small `--n` (64/1024) for fast first-light; the known-answer cases
self-check (`impulse`→flat, `dc`→bin-0 spike, `tone`→single bin).

---

## 2. Simulate

- **RTL co-sim (ModelSim/QuestaSim):** use `corefft_fft_tb.v` in this dir. It
  `$readmemh`s `<case>_in.hex`, drives `DATAI_*`/`DATAI_VALID` gated by
  `BUF_READY`, captures `DATAO_*` during `OUTP_READY`, writes `rtl_out.hex`, and
  prints `SCALE_EXP`. Replace the `COREFFT` instance with your generated core.
- **Host value-oracle (no tools):** `fft_tb.cpp` is a bit-exact C reimplementation
  of `fixedpoint.fft1d_bfp`. It is **not** the kernel under test anymore (CoreFFT
  is) — keep it as an independent cross-check that the golden vectors are correct
  and as a portable reference for anyone without the Python stack:
  `g++ -O2 fft_tb.cpp -o fft_tb && fft_tb 8192 fft_vectors/random_in.hex fft_vectors/twiddle.csv ref_out.hex 16 16`
  (pass the same `--bits`/`--tw-bits` you generated with as the trailing args)
  then `fft_golden.py check --expected fft_vectors/random_out.hex --actual ref_out.hex --tol 0` → PASS.
  Generating with `--twiddle` is required for this path (it needs `twiddle.csv`).

---

## 3. Check against the golden (tolerance mode)

```
python fft_golden.py check --expected fft_vectors/random_out.hex \
                           --actual rtl_out.hex --corr-min 0.9999 --nrmse-max 0.01
```

Reports worst LSB error, **correlation**, **scale-aligned NRMSE**, and the fitted
`|scale|` (the power-of-2 between CoreFFT's `SCALE_EXP` and the golden). Both gate
metrics are scale-invariant, so a different CoreFFT block exponent is *not* a
failure. Run all five cases — `impulse`/`dc`/`tone` catch ordering/twiddle-sign
bugs cheaply; `random`/`twotone` catch accumulation/rounding drift.

**Pass:** `corr ≥ 0.9999` **and** `nrmse ≤ 0.01`. (Tighten once first results are
in; the in-place 16-bit core should land well inside this.)

---

## 4. Into the full datapath

Once the 1-D FFT passes, the 2-D path is two CoreFFT passes + the corner-turn (M2).
Validate the 2-D fixed-point result against the full oracle
`fixedpoint.focus_full_fixed()` (resample→window→FFT→detect, including the
now-closed resample-quantization gap) and against the numpy float golden via
`dump_output.py readback --golden` (correlation + PSLR), reusing the M0 readback.

---

## When the board is needed

Steps 0–3 and Libero synthesis/place-route are **simulator/tool only — no board**.
Plug in the Icicle Kit only for final M1 bring-up:
1. Program the FFT-only bitstream with FlashPro.
2. `sar_accel_selftest()` — AXI4-Lite register read-back — proves the host↔fabric
   control plane.
3. JTAG-load one `<case>_in.hex` into the SIG region, run the single FFT, dump the
   output, read `SCALE_EXP`/`BFP_SHIFT`, and `fft_golden.py check` it (same
   tolerance as §3). Confirms simulation and silicon agree.

### Source
- [CoreFFT User Guide (DS50003348D)](https://ww1.microchip.com/downloads/aemDocuments/documents/FPGA/ProductDocuments/UserGuides/ip_cores/directcores/CoreFFT_UG.pdf) — in-place Radix-2 vs streaming Radix-2², `POINTS` 32…16384, `WIDTH` 8–32, `SCALE`/`SCALE_EXP_ON`, `SCALE_EXP` port, natural output order.
