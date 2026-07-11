# SAR PolarFire SoC — Board Bring-Up Guide

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`PROJECT_SOURCE_OF_TRUTH.md`](PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". The "DMA control slave" / "full DMA *transfer* test" watch-items below are stale —
> the `CoreAXI4DMAController` deadlocked on the 2nd back-to-back S2MM transaction and was replaced by the
> `fft_unloader` HLS kernel (AXI4-Stream slave → AXI4 write master). Fabric-level change; firmware unchanged.

Everything off-board is built and validated; this is the on-hardware sequence.
Target: **Microchip Icicle Kit, MPFS250T_ES (FCVG484)**, **boot mode 1**, JTAG/FlashPro only.

Artifacts you'll use (all already produced):
- Bitstream / programming job: the ID-fix build
  `mpfs/fpga/libero_sar/export/SAR_TOP_idfix.job` (equivalently
  `designer/SAR_TOP/SAR_TOP.ppd`) — NOT the original `SAR_TOP.job`.
- Host stage output: run `serialize_inputs.py` → `jtag_full/` (`sig.bin`, geometry
  `.bin`s, `job.bin`, `load.gdb`, `layout.json`)
- Bare-metal app: the SoftConsole project `mpfs-hal-ddr-demo` under
  `mpfs/fpga/libero_sar/softconsole/` (with `src/sar/*` + `src/application/hart0/e51.c`)
- Read-back / compare: `dump_output.py`

---

## 0. Hardware setup
1. Power the Icicle Kit; connect the **embedded FlashPro6** USB (connector **J33**) to the PC.
2. Confirm the on-board **50 MHz oscillator** drives the fabric ref-clock pin used
   by the CCC (`REF_CLK_50MHz` → pin **W12**, per `constraints/sar_io.pdc`).
3. Confirm **LPDDR4** is populated (the design uses DDR `0x8800_0000`–`0xC000_0000`).

## 1. Program the FPGA
Option A — FlashPro Express (GUI): open `SAR_TOP_idfix.job` (the ID-fix build),
connect, **RUN** (PROGRAM).
Option B — headless:
```
libero.exe SCRIPT:program.tcl     # program.tcl: open_project; run_tool -name {PROGRAMDEVICE}
```
After this the fabric is `SAR_TOP` (MSS + accelerator). LEDs/UART banner confirm.

## 2. Build the bare-metal app (SoftConsole v2022.2)
1. Import/refresh the `mpfs-hal-ddr-demo` SoftConsole project (it includes
   `src/sar/sar_sequencer.c`, `sar_resample_coeffs.c`, `sar_kernels.h`,
   `sar_resample_coeffs.h`, `ddr_sar_layout.h`, and the `hart0/e51.c` hooks).
2. Build (riscv64-unknown-elf-gcc, `-march=rv64gc -mabi=lp64d`) → `.elf`.
   - NOTE: resample coefficient gen is float; for speed run it on a **U54** (has
     FPU). On the E51 it works via soft-float but is slow (acceptable for a batch).

## 3. Stage the inputs on the host
```
python mpfs/host/serialize_inputs.py --in <scene>_CPHD.cphd --out jtag_full
#   -> jtag_full/{sig.bin, f0/df/pr/tans/invorder/krgrid/kcgrid/hamr/hamc.bin,
#                 job.bin, load.gdb, layout.json}
#   prints "resample-geometry self-check ... corr=1.0"  (sanity before the board)
```
Full resolution is fine — only ~97 MB signal + ~206 KB geometry cross JTAG (the
MSS computes the per-line coefficients on-chip). JTAG bulk load is **measured
~84 kbit/s** (~111 s/MB; 97 MB ≈ ~2.7 hr) — slow but reliable run-to-completion.
Use a **6 MHz stable JTAG clock** (15 MHz corrupts the debug module; never >6 MHz);
HID only wedges if OpenOCD is killed mid-transfer (recovery: re-plug J33 USB). For
dev iteration, use a reduced-frame (8 MB) load; do the full 97 MB once in background.

## 4. Load DDR + run (SoftConsole GDB / OpenOCD)
1. Start a debug session attached to the board; **load the `.elf`**.
2. Set a breakpoint at **`sar_loopback_report`** (i.e. *after* the DDR packet test,
   so it can't clobber the staged data), then `run` to it.
3. From the GDB console, stage DDR over JTAG:
   ```
   (gdb) source <path>/jtag_full/load.gdb     # restores sig + geometry + job
   ```
4. `continue`. The app prints over **MMUART_0** (115200 8N1):
   - `SAR Milestone 0` — SIG CRC32 **PASS** (confirms JTAG load survived).
     - Additionally, an **on-target CRC mailbox** (firmware `u54_1.c` @ DDR `0xB005_8000`)
       can verify *any* JTAG-loaded region in seconds via host tool
       `mpfs/host/run_crc_verify.sh FILE [BASE_HEX]` — it resumes hart1 to compute a
       zlib-compatible CRC32 (~75 MB/s) and returns the result, replacing the slow
       `dump_image`+cmp readback (validated: `sig_head.bin` 1 MB = `0x24775359`,
       `sigchunk_00` 8 MB = `0x591213fe`).
   - `SAR Milestone 2` — runs resample→window→FFT→corner-turn→FFT→detect, then
     `image ready at OUT (0xA8000000)` or a `TIMEOUT@<stage>` code.

## 5. Read back + compare to golden (host)
```
python mpfs/host/dump_output.py gen-dump --stage jtag_full      # -> dump.gdb
#  (gdb) source dump.gdb        # JTAG-dumps OUT to out.bin
python mpfs/host/dump_output.py readback --stage jtag_full \
       --dumped out.bin --bfp-shift <SCALE_EXP> --golden golden_fixed.npy
#  applies fftshift+transpose + rescale; prints correlation vs the golden image
```
Expected: correlation → ~1.0 (speckle-smoothed), matching the emulation/golden.

---

## Bring-up order (de-risk incrementally)
1. **M0 loopback only** — confirms FPGA programmed + JTAG DDR load + MSS↔DDR.
2. **Single stage** — temporarily call only `resample_2pass` (or one kernel) and
   JTAG-dump `SCRATCH`; compare to `emulate_fabric.py`'s intermediate. Localizes
   any issue to one stage before running the whole pipeline.
3. **Full pipeline** — then OUT vs golden.

## Watch-items (most-likely first issues)
1. **FFT write-back path — DMA removed 2026-07-04.** The data plane is fixed via
   `sar_axi_idconv.v` (AXI ID converter on the DIC `SLAVE0`↔`FIC_0_AXI4_S` path).
   The CoreFFT→DDR write-back is now the **`fft_unloader` HLS kernel** (AXI4-Stream
   slave → AXI4 write master), which replaced the `CoreAXI4DMAController` after it
   deadlocked on the 2nd back-to-back S2MM transaction; the gearbox also gained an
   output skid FIFO so backpressure doesn't wedge CoreFFT. Watch-item: confirm the
   full-pipeline retest completes with no `TIMEOUT@FFT-range/azimuth`. *(The earlier
   "DMA control slave fixed / full DMA transfer test" item is obsolete.)* See
   `docs/fpga/AMBA_ARCHITECTURE.md`.
2. **Cache coherency** — if FIC0 is non-coherent, the `fence`s in `sar_form_image`
   aren't enough: add explicit cache flush (before fabric reads) / invalidate
   (after fabric writes) around SIG/SCRATCH/OUT (MSS HAL cache ops).
3. **Padding clear cost** — the CPU zeroing of padded pulse rows is ~tens of MB;
   if it dominates, move it to a fabric/DMA memset.
4. **Coefficient gen speed** — run on a U54 (FPU) if the E51 soft-float is slow.
5. **Timing margin — DID NOT close at 125 MHz (root cause of the M3 FFT hang, 2026-06-30).**
   P&R reported 25,847/315,348 pins with negative slack (worst −3.7 ns), **all** on the single
   125 MHz fabric clock (CT/CIC/DMA/FEED/DIC/RES/DET/WIN; CoreFFT itself 0 violations) — real
   same-clock setup failures, so silicon was non-deterministic and stages 1-4 likely produced
   corrupt data even where they "completed". Fix: CCC `OUT0` 125→**62.5 MHz**, `OUT1` (CoreFFT
   SLOWCLK) 15.625→**7.8125 MHz** (SLOWCLK ≤ CLK/8). Rebuilt via a **gated** flow
   (`build_timed.tcl`, aborts on negative slack). 62.5 MHz halves fabric/FIC throughput
   (acceptable for bring-up). **Standing rule: verify P&R timing closure before blaming
   logic/firmware.** Status (**PROVEN** 2026-07-01, headless): 62.5 MHz + `sar_fft_cdc.sdc`
   **CLOSES TIMING — 0 setup + 0 hold** (of 315,349 pins; vs 25,847 @125 MHz). A bootable bitstream
   still needs the `SAR_TOP` SmartDesign rebuilt with the ready 62.5 MHz CCC (MSS coupling); see
   [SAR_TOP_RECOVERY.md](fpga/SAR_TOP_RECOVERY.md).

## Quick reference — DDR map (fixed addresses)
| Region | Addr | Use |
|---|---|---|
| SIG | `0x8800_0000` | input signal (reused as transpose scratch) |
| SCRATCH | `0x9800_0000` | resample/FFT intermediate |
| OUT | `0xA800_0000` | detected magnitude (JTAG-dump this) |
| geometry | `0xB010_0000` | f0/df/pr/tans/invorder/KR/KC/hamr/hamc |
| job | `0xB004_0000` | 96-byte job descriptor |
