# SAR on PolarFire SoC — Implementation Progress Report

> **▶ 2026-07-14 status (newest — supersedes older status in this file for repo layout + eMMC).**
> This repo is now **standalone `mpfs250t-sar-ifp`** (builds without a sibling `sarProcessor`), and the
> **on-board eMMC pipeline (M1–M3) is proven on silicon** — a CPHD scene is stored on the eMMC, loaded +
> focused on-board (`sar_form_image` → SAR_SEQ_OK; focused image confirmed via ROI crop), and the output
> persisted back to the card, retiring the recurring ~3 h JTAG scene load. Authoritative current status:
> [`PROJECT_SOURCE_OF_TRUTH.md`](../../PROJECT_SOURCE_OF_TRUTH.md) + [`fpga/SILICON_ISO_TEST_RUNBOOK.md`](../SILICON_ISO_TEST_RUNBOOK.md) § eMMC M1/M2/M3.
> The 2026-06/07 status below is retained as history.

**Scope:** GUI-free SAR image formation (Polar Format Algorithm) on the Microchip
PolarFire SoC Icicle Kit (MPFS250T-FCVG484E), JTAG-only, bare-metal RISC-V + FPGA
fabric, with the irregular work off-loaded to a host PC.
**Date:** 2026-06-22
**Companion docs:** [`REPORT.md`](REPORT.md) (algorithm + device study),
[`fpga/history/M1_cosim.md`](M1_cosim.md), [`fpga/history/M2_integration.md`](M2_integration.md)

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`PROJECT_SOURCE_OF_TRUTH.md`](../../PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". Wherever this report describes `CoreAXI4DMAController` / the DMA as the live
> FFT-stream datamover (the "full DMA *transfer* test" item, the S2MM path, the `corefft_stream_adapter`
> DMA↔CoreFFT bridge), that is stale — the DMA deadlocked on the 2nd back-to-back S2MM transaction and
> was replaced by the `fft_unloader` HLS kernel (AXI4-Stream slave → AXI4 write master); the gearbox
> gained an output skid FIFO. Fabric-level fixes only (firmware unchanged); fabric rebuilding, retest pending.

---

## 1. Constraints that shaped the design

Discovered during planning and decisive for the architecture:

- **JTAG / FlashPro is the only I/O path** — no Ethernet, no SD card; UART is far
  too slow for the ~256 MB working frame.
- Therefore **Linux on the board is impractical** (no boot medium), so the on-board
  runtime is **bare-metal C** (built on the MPFS-HAL scaffolding in the
  `mpfs-hal-ddr-demo` SoftConsole project), and all irregular/floating-point/one-time work (CPHD parse, PVP
  geometry, resample-coefficient generation, geocode) runs **off-board on a host
  PC** and is JTAG-loaded into fixed DDR addresses.

**Partition:** fabric does the whole-frame, regular, fixed-point streaming
(window, 2-D FFT, detect, resample *application*, corner-turn); the RISC-V is the
**sequencer** (programs registers/descriptors, START, poll DONE) — there is no
fabric control FSM; the host precomputes everything irregular.

**Datapath order (per axis):** resample → window → FFT. Resampling must precede the
Hamming window so the taper sits on the uniform k-space grid and aligns with the FFT
support. The full 2-D window is split across the two passes — range taper
`hamming(N)` in PASS1, azimuth taper `hamming(M)` in PASS2 — whose product equals
the reference's `outer(hamming(M), hamming(N))` (verified). Detect runs after the
azimuth FFT.

```
 HOST PC (Python, off-board)         JTAG          PolarFire SoC
 parse CPHD + geometry + tables  ──load DDR──►  bare-metal C: program accel regs,
 quantize signal -> 16b BFP I/Q                  START, poll DONE, read BFP_SHIFT
 (golden oracle)                 ◄─dump DDR──   FPGA fabric: window->resample->2D FFT
 rescale + magnitude + PNG                       ->corner-turn->FFT->detect
                DDR: [ SIG | tables/job | SCRATCH | OUT ]  fixed addresses
```

---

## 2. Milestone status

| Milestone | State | Evidence |
|-----------|-------|----------|
| **M0** — JTAG data path, CPU-only | ✅ done, run on real CPHD | loopback CRC PASS; readback vs golden corr **1.0000** |
| **M1** — FFT in fabric (CoreFFT) | ✅ **verified in RTL** | real CoreFFT @8192 vs bit-exact emulator, **5/5 cases PASS** (corr 1.0, NRMSE ≤6.4e-4) |
| **M2** — full datapath, bitstream | ✅ **done** — built, P&R, timing-clean bitstream | 5 HLS kernels + CoreFFT 8.1.100 + DMA over two CoreAXI4Interconnect 3.0.130 crossbars; worst slack +0.163 ns |
| On-board bring-up | 🟡 **data plane + DMA control verified on silicon** | MPFS250T_ES via FlashPro6/J33; data plane M2 tag 0x30 HANG→PASS (`sar_axi_idconv.v`); DMA-ctrl tags 0x50-0x53 read VER=0x00020064, no hang. Full DMA *transfer* test still open. |
| **M3** — full PFA pipeline on silicon | 🟢 **timing-closure fix PROVEN (62.5 MHz: 0 setup + 0 hold); bootable bitstream needs SmartDesign rebuild** | PIPE mailbox → `sar_form_image`; stages 1–4 ran, range-FFT (st5) "hung". Real cause: **bitstream fails timing at 125 MHz** (25,847/315,348 pins neg slack, worst −3.7 ns, single fabric clock; CoreFFT 0). **Validated headless 2026-07-01:** 62.5 MHz + `sar_fft_cdc.sdc` → **0 setup + 0 hold**. Bootable bitstream still needs `SAR_TOP` SmartDesign rebuilt with the ready 62.5 MHz CCC (MSS coupling). See §5c + `docs/fpga/SAR_TOP_RECOVERY.md`. |

---

## 3. What is done and verified

### 3.1 Host harness (off-board, `mpfs/host/`)
- [`ddr_layout.py`](host/ddr_layout.py) — single source of DDR addresses, AXI4-Lite
  register map, 16-bit BFP I/Q quantization, CRC-32, 96-byte job descriptor.
- [`serialize_inputs.py`](host/serialize_inputs.py) — CPHD → `sig/kr/kc/tanphi/win/job.bin`
  + `layout.json` + a JTAG `load.gdb`. Run on the real 196 MB Centerfield CPHD (8 s).
- [`dump_output.py`](host/dump_output.py) — JTAG dump script, loopback CRC verify,
  readback (reshape→rescale by `BFP_SHIFT`→PNG→compare), and `make-golden` /
  `make-golden-fixed` oracles. Float golden corr **1.0000**; fixed oracle corr
  **1.0000 / 60 dB** vs float at deci-16.
- [`fft_golden.py`](host/fft_golden.py) — bit-exact FFT test vectors ($readmemh) +
  scale-aligned checker (LSB / correlation / NRMSE).
- [`run_crc_verify.sh`](host/run_crc_verify.sh) `FILE [BASE_HEX]` — fast post-load
  verify via the **on-target CRC32 mailbox** (§3.2): instead of a slow JTAG dump +
  host compare (hours), it has firmware compute the CRC32 of a DDR region on the board
  (~75 MB/s) and reads back 4 bytes (seconds). Validated byte-for-byte against host
  `zlib.crc32`: `sig_head.bin` (1 MB) = `0x24775359`, `sigchunk_00` (8 MB) = `0x591213fe`.

### 3.2 Board (bare-metal, `mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/sar/`)
- `ddr_sar_layout.h` (mirrors `ddr_layout.py`; `sar_job_t` = 96 B, static-asserted),
  `sar_accel_driver.{c,h}` (job load, SIG CRC loopback, AXI4-Lite config/start/poll,
  `sar_accel_selftest`). Loopback wired into `hart0/e51.c`. Compiles with SoftConsole
  RISC-V GCC 8.3.0.
- **On-target CRC32 mailbox** (`u54_1.c`) — a 6×u32 mailbox at DDR `0xB0058000`
  (`cmd / base / len / result / status / seq`). The host writes `cmd = 0x43524333`
  (`'CRC3'`), `base`, `len` and resumes hart1; firmware computes a zlib-compatible
  CRC32 (poly `0xEDB88320`) over the region at **~75 MB/s**, writes `result` and
  `status = 0xC0FFEE03`, and the host reads back the 4-byte CRC. This replaces the slow
  dump+compare with an on-board verify (seconds vs hours); host driver is
  [`run_crc_verify.sh`](host/run_crc_verify.sh) (§3.1).

### 3.3 Verification oracle (`src/fixedpoint.py`)
- Added `resample_fixed()` / `focus_full_fixed()` — closes the documented
  resample-quantization gap so the oracle covers resample→window→FFT→detect.

### 3.4 FPGA fabric (`mpfs/fpga/`) — built with Libero SoC 2025.2 + SmartHLS
- **CoreFFT 8.1.100** generated headless ([`gen_corefft.tcl`](../gen_corefft.tcl)):
  in-place, POINTS=8192, WIDTH=16, conditional BFP, `SCALE_EXP` enabled. Verified in
  QuestaSim with the real PolarFire primitives ([`sim/`](../sim/)).
- **SmartHLS kernels** ([`hls_corner_turn`](../hls_corner_turn/),
  [`hls_window`](../hls_window/), [`hls_detect`](../hls_detect/),
  [`hls_resample`](../hls_resample/)) — all `shls sw` PASS; corner-turn also
  `shls cosim` PASS and `shls rtl_synth` = **3.3 % 4LUT, 0 DSP, ~134 MHz** on the
  MPFS250T. Resample uses CPU-precomputed index+weight tables (gather+lerp), matching
  the partition.
- **Assembly** ([`assemble_sar.tcl`](../assemble_sar.tcl)) — Libero project
  `fpga/libero_sar/` with all components in one SmartDesign (`sar_datapath`),
  clocks + resets wired (active-low `ARESETN` direct to CoreFFT/DMA, inverted to the
  active-high HLS kernels), all data/control/AXI promoted to the boundary, and the
  SmartDesign **generated** (synthesizable).
- **Datapath stitch (in progress):**
  - **CoreFFT↔DMA stream adapter** ([`corefft_stream_adapter.v`](../corefft_stream_adapter.v))
    — bridges AXI4-Stream ↔ CoreFFT's load/read handshake. **Verified** with the
    real CoreFFT @8192 through the stream interface (corr **1.0000**, NRMSE 6.4e-4)
    — [`sim/corefft_stream_tb.v`](../sim/corefft_stream_tb.v).
  - **CoreAXI4Interconnect 3.0.130** ×2 (upgraded from 2.9.100): a **data** crossbar
    (DIC / `AXIIC_C0`, 6 masters → 1 DDR target) and a **control** crossbar (CIC /
    `AXIIC_CTRL`, 1 master → 6 targets), the latter carrying the AXI4-Lite kernel
    control + the DMA control slave (CIC slave-5 @ `0x60005000`).
  - **Done (2026-06-30):** crossbar wiring, AXI4-Lite control fan-out, DMA-stream↔CoreFFT
    adapter, and MSS/FIC integration are all complete — the design is built, programmed,
    and brought up on silicon (see §5 and [`fpga/SAR_BRINGUP_REPORT.md`](../SAR_BRINGUP_REPORT.md)).

### 3.5 Resource footprint on the MPFS250T (measured, per component)

| Component | LUT | DSP (Math) | LSRAM | Fmax |
|-----------|----:|-----------:|------:|------|
| CoreFFT 8192 (in-place) | 4,219 | 4 | 21 | meets 100 MHz |
| corner-turn | 8,332 | 0 | 2 (+6 µSRAM) | ~134 MHz |
| window | 2,222 | 5 | — | — |
| detect | 3,279 | 2 | — | — |
| resample | 2,824 | 6 | — | — |
| DMA (est.) | ~5–8 k | 0 | a few | — |
| **Total (approx.)** | **~10 %** of 254,196 | **~17 (2 %)** of 784 | **~4 %** of 812 | — |

The whole accelerator fits with large margin — ample room for parallel FFT cores.
CoreFFT is tiny (4 DSPs) because the in-place radix-2 reuses one butterfly.

> **Structural note:** the accelerator cannot be synthesized as a standalone top
> (promoting all AXI to physical I/O = 2,207 ports ≫ 144 device pins). Its AXI must
> terminate **internally** — a `CoreAXI4Interconnect` to DDR and AXI4-Lite from the
> MSS via FIC — which is the integration step below. Resource sizing is therefore
> per-component (above), not a standalone top synth.

---

## 4. Correction recorded (engineering honesty)

An earlier interim claim that the corner-turn "did not generate AXI bursts / would
be too slow / needed a DMA pivot" was **wrong**. It came from reading the LLVM-IR
*scheduling* report (`ar_len.write(0)`), not the generated RTL. The **RTL does
burst** (`ar_len/aw_len` are computed up to the burst length), confirmed for the
corner-turn, a plain copy, and SmartHLS's own example. The SmartHLS cosim cycle
counts reflect a **generic AXI BFM**, not real LPDDR4, so they are not a hardware
throughput measure. By bandwidth, the corner-turn moves ~512 MB/frame at FIC
~1.6–3.2 GB/s ≈ **0.16–0.32 s**, within the ~1 s/frame budget. No DMA pivot was
needed. Lesson: check bursts in `hls_output/rtl/*.v`, and treat cosim-BFM cycles as
*functional*, not *throughput*, numbers.

---

### 3.6 SoC integration — MSS generated GUI-free

The PolarFire SoC MSS is generated **headless** from the Icicle Kit reference
design's bare-metal config via `pfsoc_mss -GENERATE -CONFIGURATION_FILE:
MPFS_ICICLE_MSS_baremetal.cfg` → `ICICLE_MSS.cxz`, then `import_mss_component`
into `libero_sar`. **The MSS Configurator GUI is not needed** — so the entire flow
to a bitstream is scriptable. FIC0 provides exactly the two interfaces the design
needs: `FIC_0_AXI4_M` (MSS→fabric, CPU AXI4-Lite control), `FIC_0_AXI4_S`
(fabric→MSS→LPDDR4 for the DDR masters), and `FIC_0_ACLK` (fabric clock). Bare-metal
maps DDR into the 1 GB cached window (`0x8000_0000`), which holds the ~0.9 GB
working set (board is physically 2 GB).

**Definitive:** GUI is needed **nowhere**; the board is needed **only** to program
the final bitstream and run bring-up.

### 3.7 Component inventory — all generated & configured headless

The `libero_sar` project now holds every block of the full design, each created in
batch (no GUI): `CoreFFT_C0` (8192 BFP, 8.1.100), `AXIDMA_C0` (CoreAXI4DMAController
2.2.107), two `CoreAXI4Interconnect 3.0.130` crossbars — `AXIIC_C0` (DIC, data, 6 masters
→ 1 DDR target) and `AXIIC_CTRL` (CIC, control, 1 master → 6 targets) — the five SmartHLS
kernels as HDL+ cores, `corefft_stream_adapter` (HDL+, verified), and `ICICLE_MSS`.
SmartDesign wiring + P&R are now **done** (bitstream built and programmed); the turn-key
recipe (every interface name, the FIC0 connections, CORERESET, constraints, build commands)
is in [`fpga/history/M2_integration.md` §6b](M2_integration.md), and the
authoritative interconnect reference is [`fpga/AMBA_ARCHITECTURE.md`](../AMBA_ARCHITECTURE.md).

## 5. Bitstream — DONE (fully GUI-free, 2026-06-22)

The complete fabric + SoC implementation now builds end-to-end **headless** and
produces a **timing-clean bitstream** on the MPFS250T-FCVG484E:

| Stage | Result |
|---|---|
| Scripted top SmartDesign `SAR_TOP` (15 blocks) | ✅ generated, DRC passed ([`build_sartop.tcl`](../build_sartop.tcl)) |
| Synthesis | ✅ |
| Place & route | ✅ Placer + Router completed |
| Timing | ✅ **met** — worst slack **+0.163 ns** (all corners positive) |
| Bitstream / programming data | ✅ `BITSTREAM_OK` |
| FlashPro Express job | ✅ [`libero_sar/export/SAR_TOP.job`](../libero_sar/export/SAR_TOP.job) (JTAG-programmable) |

**Key integration problems solved (all headless):**
1. DMA can't *source* a stream → added the `fft_feeder` HLS kernel (DDR→AXI4-Stream→gearbox→CoreFFT).
2. Kernels not CPU-driveable → `#pragma HLS interface default type(axi_target)` (memory-mapped start/args; SmartHLS auto-generated the drivers).
3. AXI bus-interface bif names (`AXI4mmaster*/AXI4mslave*`, `AXI4InitiatorDMA_IF`, etc.) discovered empirically; connect via `sd_connect_pins -pin_names {"a:bif" "b:bif"}`.
4. HDL+ core catalog corruption on re-import → delete `component/User/Private/<core>` on disk + clean re-import-all (with `set_root` first).
5. 1302 I/O > 144 fabric limit → **minimal MSS** (FIC_0 + LPDDR4 + MMUART_0; `trim_mss.py` + `pfsoc_mss -GENERATE`) and tied off `MSS_INT`.
6. CCC reference clock unroutable → `CLKINT` buffer (`REF_CLK_50MHz → W12 → CLKINT → CCC`).
7. CoreFFT `SLOWCLK` (PF_CLK_DIV macro wouldn't route on globals) → **second CCC output at 15.625 MHz** (CLK/8).

**Known-good headless flow:** rm 6 `User/Private` core dirs → `reimport_all.tcl` →
`build_sartop.tcl` → rm `synthesis/synwork` → `synth2.tcl` → `add_pdc_pnr.tcl`
(imports `constraints/sar_io.pdc` + `sar_clocks.sdc`) → `gen_bitstream.tcl`.

## 5b. On-silicon bring-up — data plane + DMA control verified (2026-06-30)

Board: **MPFS250T_ES (FCVG484)**, boot mode 1, programmed via the **embedded FlashPro6
on connector J33** (not FlashPro5/J11). Runtime: bare-metal RISC-V (U54_1) over JTAG.

**Fixed and verified on silicon:**
- **Data plane** — root cause was AXI **ID-width truncation** at `FIC_0_AXI4_S` (fabric master
  IDs wider than the MSS slave port). Fix = `sar_axi_idconv.v`, which stashes/restores the AXI
  ID across the bridge. M2 tag 0x30 went **HANG→PASS**, SCRATCH written.
- **DMA control slave** — root cause: CIC slave-5 was `TARGET_TYPE=0` (Full AXI4) feeding the
  DMA's reduced **AXI4-Lite** control through a 64→32 DWC, which **black-holed reads** and hung
  the hart un-haltably. Fix = CIC `TARGET5_TYPE=1` (AXI4-Lite) + wire the 11-bit control address
  via `sd_create_pin_slices`. Verified: tags 0x50-0x53 read distinct DMA registers
  (VER=`0x00020064`), no hang.

**Remaining (board phase):**
1. **Bare-metal driver / sequencer** — stitch the SmartHLS auto-generated per-kernel drivers
   (`hls_*/hls_output/accelerator_drivers/`) with the DDR layout (`ddr_sar_layout.h`) into a
   sequencer (resample → window → FFT → corner-turn → FFT → detect).
2. **Full DMA *transfer* test** — control is verified; a real descriptor + START data-move is
   not yet run. Bulk-data transport over JTAG is **slow but viable run-to-completion**: measured
   **~84 kbit/s** (~111 s/MB, ~2.7 hr for 97 MB), latency-bound by FlashPro6 USB-HID (~390 µs per
   JTAG word-scan), independent of clock (2/6 MHz identical) and method (sysbus == progbuf); there
   is no OpenOCD batching knob. A **completed** transfer is clean and byte-identical (proven on 1 MB
   and 8 MB loads, MD5 match); the HID only wedges if openocd is **killed mid-transfer** or a
   `verify_image` readback is interrupted (recovery = re-plug J33 USB) — it is not a hard USB
   requirement. Verification no longer needs a slow dump+compare: the **on-target CRC32 mailbox**
   (§3.1) reads back a region's CRC in seconds.
3. **End-to-end run** — JTAG-load DDR (`serialize_inputs.py`), run, JTAG-dump (`dump_output.py`),
   compare to `golden_fixed`. For dev iteration use the reduced-frame (8 MB) signal; the full 97 MB
   is a one-time chunked **background** load (run-to-completion, never killed) verified by on-target
   CRC.

See [`fpga/SAR_BRINGUP_REPORT.md`](../SAR_BRINGUP_REPORT.md) for the full bring-up log and
[`fpga/FABRIC_INTERCONNECT_CONVENTIONS.md`](../FABRIC_INTERCONNECT_CONVENTIONS.md) for the
interconnect lint gate / conventions.

## 5c. M3 full PFA pipeline — root-caused to FPGA timing closure (2026-06-30)

The full PFA pipeline was wired into firmware (PIPE mailbox → `sar_form_image`). Stages 1–4 ran on
silicon; the range-FFT (stage 5) appeared to hang.

**Real root cause: the FPGA bitstream does NOT meet timing at 125 MHz.** P&R `pinslacks.txt` shows
**25,847 / 315,348 pins with negative slack** (worst **−3.7 ns**), **all on the single 125 MHz
fabric clock** — by block: CT 14341, CIC 3957, DMA 3349, FEED 1973, DIC 1826, RES 249, DET 102,
WIN 50; **CoreFFT itself has 0 violations**. These are real same-clock setup failures, **not** a CDC
issue.

**Consequence:** non-deterministic silicon. The FFT looped, and although stages 1–4 *completed*, the
firmware only checked completion — so **their data is likely corrupt and is unverified pending the
timing-closed rebuild**. This supersedes the earlier per-symptom theories.

**Fix:** lower the fabric-clock CCC `OUT0` 125→**62.5 MHz** and `OUT1` (CoreFFT `SLOWCLK`)
15.625→**7.8125 MHz** (`SLOWCLK ≤ CLK/8`), headless via `PF_CCC_C0_62p5.tcl` +
`reconfig_ccc_62p5.tcl` (verified), re-assemble `SAR_TOP`, and rebuild through the **timing-gated**
`build_timed.tcl`, which **aborts before bitstream on any negative slack**. Trade-off: 62.5 MHz
halves fabric/FIC throughput (acceptable for bring-up).

**Lesson (standing rule):** always verify P&R timing closure before blaming logic or firmware —
Libero programs a timing-failing bitstream **silently**, and `*_sdc_errors.log` reports SDC *syntax*,
not *slack*.

**Status (PROVEN 2026-07-01, headless):** 62.5 MHz + `sar_fft_cdc.sdc` **CLOSES TIMING — 0 setup + 0 hold**
(of 315,349 pins; vs 25,847 @125 MHz). A bootable bitstream still needs the `SAR_TOP` SmartDesign rebuilt
with the ready 62.5 MHz CCC (MSS coupling); full recipe in `docs/fpga/SAR_TOP_RECOVERY.md`.
The firmware itself is valid (PIPE/CRC mailboxes, DMA external-stream-descriptor, bounded harness).

---

## 6. Toolchain notes (reproducibility)

- Libero SoC 2025.2 (`C:\Microchip\Libero_SoC_2025.2`), QuestaSim 2024.3, SmartHLS,
  Synplify; license at `LM_LICENSE_FILE`. CoreFFT + CoreAXI4DMAController in
  `C:\Microchip\Common\vault`.
- Headless invocation: `libero.exe SCRIPT:foo.tcl LOGFILE:foo.log`;
  `vsim -c -do ...`; `shls sw|hw|cosim|rtl_synth`.
- Gotchas: compile the PolarFire primitive lib with `vlog -sv`; `SCALE_EXP_ON:true`
  (boolean); set a design **root** before HDL+ import (`configure_tool` needs it);
  `shls cosim` needs `vsim` on PATH, `rtl_synth` needs `LIBERO_TOOL_PATH`.

---

## 7. Bottom line

The algorithm path is complete and **verified end-to-end against the real CoreFFT
IP and a bit-exact fixed-point oracle**; the full custom datapath exists as verified
SmartHLS kernels; and the entire accelerator + SoC is assembled into one Libero
SmartDesign that **synthesizes, places & routes, meets timing (+0.163 ns), and
produces a JTAG-programmable bitstream — all generated headless / GUI-free.** The
earlier prediction that integration "necessarily meets the Libero GUI" proved
unnecessary: the whole flow, including the top SmartDesign wiring, MSS reconfig,
clock/reset infrastructure, and bitstream export, was driven by Tcl scripts.

The bitstream has since been **programmed and brought up on silicon** (MPFS250T_ES via
FlashPro6/J33): the **data plane** is fixed and verified (AXI ID-width truncation at
`FIC_0_AXI4_S` → `sar_axi_idconv.v`; M2 tag 0x30 HANG→PASS) and the **DMA control slave**
is fixed and verified (CIC slave-5 made AXI4-Lite; tags 0x50-0x53 read VER=0x00020064, no
hang). The full PFA pipeline (M3) is now wired into firmware and **root-caused to FPGA timing
closure** — the bitstream fails timing at 125 MHz on the single fabric clock (25,847 pins negative
slack, worst −3.7 ns; CoreFFT clean), so silicon was non-deterministic and stages 1–4 "completed"
with unverified data. The **62.5 MHz fix is PROVEN headless** (§5c: 0 setup + 0 hold vs 25,847 @125 MHz).
A bootable bitstream still needs the `SAR_TOP` SmartDesign rebuilt with the ready 62.5 MHz CCC; once
rebuilt and reprogrammed, the remaining work is the end-to-end load/run/dump/compare-to-golden over JTAG
plus the **full DMA *transfer* test** (control verified; real descriptor + START data-move not yet
run).
