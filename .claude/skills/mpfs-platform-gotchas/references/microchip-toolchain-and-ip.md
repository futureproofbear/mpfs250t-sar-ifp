# Microchip/Microsemi toolchain + IP peculiarities (hard-won on this project)

Not in any errata doc — these are behaviours we discovered on this board/toolchain. Each cost real
debugging time; check here before assuming your design is at fault. Detail + evidence live in
`docs/fpga/*.md` and the agent memory (linked names in [[brackets]]).

## SmartHLS 2025.2
- **mem↔STREAM kernels synthesize to DEAD RTL on silicon.** A kernel whose top-level arg maps to an
  `hls::FIFO` AXI4-Stream master (mem→stream, e.g. the FFT feeder) or the reverse issues ZERO bus
  transactions on silicon despite passing cosim (read master `arvalid` stuck 0, rd_cnt=0). mem→mem
  kernels (corner_turn, resample, the trivial stream→mem unloader `dst[i]=in.read()`) are FINE. FIX:
  hand-write the mem↔stream piece in Verilog (see `fft_feeder_v.v`). [[corefft-feeder-fix-validated]]
- The **K_FFT butterfly is unsynthesizable** here (drops the twiddle term; DoubleBuffer/wide-ap_fixpt
  hazard) despite cosim PASS — the reason the shipping FFT is on the CPU. [[m3-pipeline-silicon-status]]
- **SIGN-EXTENSION miscompile (2026-07-10):** `(int16_t)(x >> 16)` in the detect kernel was synthesized
  with the high-16 (I) treated as UNSIGNED → every negative-I pixel overflowed `isqrt` → clamped 0xFFFF
  (~50% of image saturated). The low-16 `(int16_t)(x & 0xFFFF)` path was FINE — SmartHLS mis-handles
  the shift-then-cast, not the mask-then-cast. C source was correct; only silicon showed it. FIX: force
  it branchless + symmetric for both halves — `sext16(u)=(int32_t)((u&0xFFFF)^0x8000)-0x8000`. LESSON:
  after any HLS rebuild, value-check a kernel's output on silicon (not just cosim/corr); casts and
  sign-extension are the usual miscompile sites. [[detect-signext-bug-fabric-corr0]]
  - **UPDATE 2026-07-11: the branchless `sext16` fix did NOT survive synthesis either.** Rebuilt the
    fabric (TIMING MET, fresh detect RTL confirmed in the bitstream, digest changed) + programmed +
    value-checked on silicon: negative-I pixels STILL saturate 0xFFFF (49.9% sat, corr 0.12 vs 0.97
    for CPU detect). SmartHLS optimizes away the high-16 sign no matter how the C is written (plain
    cast AND branchless XOR-sub both fail). DON'T keep iterating C formulations blindly — each is a
    ~35 min rebuild. Working paths: (1) **CPU detect** (`detect_mode=1`, MSS `sqrt` — proven 0.97,
    the shipping path); (2) hand-write the detect in Verilog (mem→mem, guaranteed sign); (3) try
    `ap_int<16>` (SmartHLS-native signed) if a fabric-detect performance win is truly needed — but
    de-risk in a QuestaSim TB BEFORE another fabric rebuild.
- HLS cores are registered into Libero via each kernel's `hls_output/scripts/libero/create_hdl_plus.tcl`
  (`shls hw` regenerates them); a plain Verilog module uses `create_hdl_core` + `hdl_core_add_bif` /
  `hdl_core_assign_bif_signal` instead (see `feeder_v_core.tcl`).

## SmartDebug
- **The design database MUST match the PROGRAMMED bitstream.** This repo has several Libero projects
  (`libero_ffv`, `libero_sar`, `libero_corefft*`) with DIFFERENT netlists (e.g. `libero_sar` has
  `have_beat`/DMA nets absent from `libero_ffv`). Probing from the wrong project returns plausible-
  looking GARBAGE. Always launch SmartDebug from the project that built the programmed bitstream and
  confirm "design matches device". (See `smartdebug-probe` skill.)
- Active Probe reads static FF values over the **fabric probe network**, NOT the RISC-V DMI — so it works
  even when a hart is un-haltable, and won't reproduce the OpenOCD HID lockup. Only one tool may own the
  FlashPro6, so shut down openocd first.
- Prefer **registered** nets (survive P&R, DC-stable in a permanent stall). Combinational-only nets may
  not be probe-accessible after synthesis — fall back to a nearby FF (e.g. a FIFO `wptr`).
- Remember ES §3.8: a lone **zero** read may be the DRI-corruption erratum — re-read.

## Libero SoC 2025.2 (headless)
- **Programs TIMING-FAILING bitstreams silently.** ALWAYS gate on setup AND hold = 0 violations before
  trusting silicon (`build_*_ffv.tcl` parse `pinslacks.txt` + `*_mindelay_repair_report.rpt`).
  [[always-check-timing-closure]]
- A **CCC frequency reconfig once DELETED SAR_TOP** (not headless-recoverable). Change CCC freq by regen
  + `sd_update_instance`, NEVER delete_component the top. [[sartop-smartdesign-deleted-recovery]]
- `create_hdl_core` caches only the bus-interface **.xml**; the RTL is a LINK (`create_links -hdl_source`)
  to the actual `.v`. Editing internal logic (same ports/bifs) → re-synthesis re-reads the file; no
  re-registration needed. Changing ports/bifs → re-register.
- Invoke headless: `libero.exe "SCRIPT:x.tcl" "LOGFILE:x.log"`. It spawns synbatch/pa_designer children;
  watch the log (flushes live). Program via `run_tool PROGRAMDEVICE`.

## SoftConsole 2022.2 (firmware build + flash)
- `make` lives at `$SC/build_tools/bin/make.exe` (underscore `build_tools`, NOT `build-tools`); the
  riscv toolchain at `$SC/riscv-unknown-elf-gcc/bin`. Put BOTH on PATH, then build with **`make all`**
  in the `Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/` dir — a bare `make` resolves a stray
  single-object target and produces no ELF. The ELF is `.../Release/mpfs-hal-ddr-demo.elf`.
- Reflash eNVM with the new ELF via `mpfs/host/run_program.sh` (copies ELF→`bm1/app.elf`, runs
  `mpfsBootmodeProgrammer.jar --bootmode 1 --die MPFS250T_ES --package FCVG484`, uses fpgenprog not
  openocd). Firmware-only changes don't need a fabric rebuild — edit → `make all` → run_program.sh → run.
- Wall-clock timing in firmware: `readmtime()` reads CLINT MTIME at **1 MHz** (`LIBERO_SETTING_MSS_RTC_TOGGLE_CLK`)
  → 1 tick = 1 µs. `sar_form_image` stamps `sar_stage_ts[0..6]`; host diffs for per-stage µs.

## FlashPro6 (FP6) over J33
- **JTAG bulk-load ceiling ~84 kbit/s** (~111 s/MB), latency-bound by the USB-HID, not bandwidth. 15 MHz
  TCK corrupts the DM (use 4 MHz). 97 MB ≈ 2.7 h → chunk + on-target CRC. [[jtag-bulk-load-rate-ceiling]]
- **Force-killing openocd/gdb wedges the FP6 HID/DM.** A board power-cycle does NOT clear it (FP6 is
  USB-powered, independent of the board) — **unplug/replug the FP6 USB**. Symptom of a wedge: openocd
  connects (finds tap 0x0f81a1cf, enumerates regs) then freezes before `reset halt`. (See `jtag-recover`.)
- Only one tool owns the FP6 at a time (openocd XOR SmartDebug XOR programming). `run_corefft_iso.sh`'s
  openocd has no telnet 4444 → add `-c "telnet_port 4444"` for a graceful stop.

## FIC / AXI interconnect
- **FIC_0_AXI4_S accepts only a 4-bit ID.** The DIC (data interconnect) uses 8-bit IDs → the upper bits
  are TRUNCATED at FIC_0 → responses misroute. Fix = `sar_axi_idconv` (ID_FIX): stash/restore the upper
  ID bits and zero-extend addr 32→38. Any new fabric AXI master into FIC0 needs this. [[sar-onsilicon-fabric-dataplane]]
- **FIC_0 is NON-COHERENT.** JTAG/CPU reads of fabric-written DDR need `flush_l2_cache(1)` (push input
  L2→DDR before arming; evict dst before readback). Capture decisive signals BEFORE the evict-flush — a
  wedged fabric AXI txn makes the flush hang ~5 min.
- **CoreAXI4DMAController** (the old S2MM unloader) deadlocks on the 2nd back-to-back stream txn (AWVALID
  stuck) → replaced by the Verilog/HLS unloader. Its AXI4-Lite control needed CIC `TARGET5_TYPE=1`
  (protocol-conv before the 64→32 DWC) to read. [[dma-ctrl-slave-fixed-axi4lite-type]]

## CoreFFT (DirectCore 8.1.100)
- **in-place vs streaming**: streaming = Radix-2² DIF, max FFT_SIZE 4096, NO BFP; in-place = Radix-2 DIT,
  supports 8192, conditional BFP/SCALE_EXP. 8192-pt SAR needs in-place. [[corefft-streaming-vs-inplace]]
- **SLOWCLK ≤ CLK/8** for in-place (twiddle-LUT init on SLOWCLK after NGRST; a stale SDC comment saying
  15.625 MHz was wrong — the CCC is authoritative at 7.8125 MHz = CLK/8). BUF_READY only asserts after
  init completes.
- **MEMBUF=0 permits pausing READ_OUTP** ("arbitrary breaks in the burst"), only lengthening the cycle.
  **MEMBUF=1 (buffered) is WORSE for a slow sink** — its single output buffer is overwritten by the next
  frame if you read too slowly, and the core then drops OUTP_READY. Keep MEMBUF=0 for a backpressuring
  DDR drain.
- **The gearbox READ_OUTP/DATAO-latency trap**: CoreFFT `DATAO_VALID` trails `READ_OUTP` by ~4 cycles.
  A gearbox that gates its CAPTURE on `read_outp` drops the in-flight beats when it backpressures → data
  loss + re/im pairing desync → the unloader starves. Capture on `datao_valid` and de-assert `read_outp`
  on an almost-full threshold reserving the latency. Proven by `corefft_stream64_lossck_tb.v`; the fix is
  in `corefft_stream64_adapter.v`. FFT_SIZE feeds only the unused NATIV_AXI4 path (POINTS drives compute).
