# Dual-device fit (Icicle + Discovery) + non-engineer delivery

Requirement (2026-07-12): the SAR fabric must fit **both** boards, and the **delivery** target must
be programmable by a **non-engineer who does not have Libero SoC installed**.

- **Development board:** Icicle Kit — **MPFS250T-FCVG484**, 2 GiB LPDDR4. Engineer builds/debugs here.
- **Delivery board:** Discovery Kit — **MPFS095T-FCSG325**, LPDDR4, 64-bit DDR addressing exposed.
- The operator on the delivery side flashes a pre-built image; they have **no Libero, no HLS, no P&R** —
  only a USB FlashPro and a click/script.

## 1. Dual-fit strategy: design to the SMALLER device (095T)

A bitstream is device-specific, so we ship **two bitstreams built from the same RTL/HLS source** — one
targeting MPFS250T (dev), one MPFS095T (delivery). The only per-board differences are the *wrapper*:
- I/O constraints (`sar_io.pdc` — FCVG484 vs FCSG325 pinout differ),
- the MSS config + `fpga_design_config` (both boards' configs already vendored under
  `src/boards/{icicle-kit-es-ddr-666MHz,mpfs-discovery-kit}/`),
- the CCC instance (same 62.5 MHz / SLOWCLK=CLK/8 target on both).
The datapath RTL (resample, window, CoreFFT chain, corner-turn, detect, coeff, any 16k-FFT combine) is
identical. **Because 095T ⊂ 250T in resources, if it fits 095T it fits 250T** — so the 095T is the
binding budget for every design decision.

### Resource budget — the 095T is the ceiling
Current design (measured on 250T) vs the 095T (≈37% the fabric):

| Resource | Used | MPFS250T | % 250T | ≈ % **095T** |
|---|---|---|---|---|
| 4LUT | 32,655 | 254,196 | 12.9% | ~35% (→~31% if bypassed DET stripped) |
| LSRAM (20 Kb) | 83 | 812 | 10.2% | **~27%** ← the tight one |
| Math (18×18) | 18 | 784 | 2.3% | ~6% |

**Design rules to stay within 095T** (verify LSRAM against the MPFS095T datasheet — it binds first):
- **Strip the bypassed fabric DET kernel** (CPU detect ships) → frees ~3.8 K LUT + 2 MACC.
- **Parallel lanes: ≤ 2** for the delivery build. Each fused lane ≈ 55–60 LSRAM (resample buffers 32 +
  CoreFFT 21 + window taper 7); 2 lanes ≈ 49% of 095T LSRAM. (3 lanes ~67% fits but is bandwidth-capped
  by the single LPDDR4 anyway — see the parallel-paths analysis.)
- **16k FFT** (if enabled): reuses the same 8192 CoreFFT + a twiddle LUT (~13 LSRAM) + a combine kernel;
  fits, but for a strictly-8k delivery the checker (`plan_frame`) always picks the native 8192 path, so
  the 16k combine can be omitted from the delivery build to save LSRAM.
- **Common DDR memory map:** keep SIG/SCRATCH/OUT/tables in the cached `0x8000_0000` window that exists
  on both boards; only reach 64-bit/upper-DDR on the Discovery-specific >8k path (not in the 8k build).

## 2. Delivery: non-engineer programming without Libero

The engineer (with Libero, on dev) produces a **self-contained FlashPro Express job** for the 095T; the
operator programs it with **FlashPro Express** — Microchip's free, standalone production programmer (no
Libero license, no design tools). This is the vendor-intended operator flow.

### Build side (engineer, one time per release)
1. Build + timing-gate the **095T** bitstream from the shared RTL (same gated flow as the 250T build).
2. **Bundle fabric + eNVM firmware into ONE `.job`** so a single program action loads everything:
   `export_prog_job` with the fabric bitstream *and* the eNVM boot client (from
   `mpfsBootmodeProgrammer`) as components — the operator flashes once, not fabric-then-firmware.
3. Ship a **delivery package**: the `.job` + the FlashPro Express installer (or portable) + a one-click
   `program.bat` (`FPExpress.exe RUN_PROJECT ...` / job-runner) + a one-page runbook.

### Operator side (non-engineer, per board)
1. Plug the board's USB (embedded FlashPro).
2. Double-click `program.bat` **or** open FlashPro Express → load the `.job` → **RUN**.
3. Wait for `PROGRAM PASSED`; power-cycle. No tool knowledge required.

FlashPro Express `.job`s are designed for exactly this (production operators). The engineer owns
timing closure + verification; the operator only re-flashes a signed, pre-verified image.

## 3. Consequences for the roadmap
Every future fabric change (parallel lanes, DDR-efficiency rework, 16k FFT, coeff-gen) is now gated by
the **095T budget**, not the 250T's. Practically: cap parallelism at ~2 lanes, prefer *fusion* (reduces
DDR traffic without adding fabric) over replication, and keep the delivery build's feature set to what
8k×8k needs (native 8192 path) so the 095T image stays comfortably within resources.
