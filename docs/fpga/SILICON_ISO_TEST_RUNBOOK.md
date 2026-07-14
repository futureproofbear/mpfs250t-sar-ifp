# Silicon Iso-Test + HLS-FFT Build Runbook

Reliable, repeatable procedures for isolating SAR kernels on silicon, coherent DDR reads,
SmartHLS validation, and the HLS-FFT fabric rebuild. Written after a long 2026-07-04 session
that re-derived these too many times. **Follow this before improvising.**

## 0. Verification / debugging test menu (what to run, and when)

Pick the narrowest test that covers the change. Board-free first; escalate to silicon only when needed.
After ANY fabric rebuild, re-verify by VALUE (corr), not just RETURN=0 — SmartHLS schedule ≠ silicon.

Board-free (no JTAG; run first):
- **Bit-accurate emulator** — `python silicon_emulator.py` — mirrors the whole fixed-point datapath end
  to end; == float golden (corr 1.0). The reference for isolating a hardware bug (diff board vs this).
- **SmartHLS cosim + schedule** — `shls sw` (kernel `main()` self-test, numeric PASS) then `shls hw`
  (per-loop II report). Run BEFORE committing to a bitstream build. See §5.
- **Phase-sensitive FFT** — `python corefft_phase_compare.py [N]` — catches conjugation / sign / bin-order
  errors that magnitude correlation cannot. See §9.
- **Model-on-real-scene** — `real_board_scene_test.py` / `real_data_model_test.py` — CPU-vs-fabric BFP
  model on the actual board scene (algorithm sound vs implementation bug).

On silicon (JTAG; observe §1 hygiene):
- **Full pipeline (acceptance)** — `bash run_pipe_small.sh` → expect **RETURN=0**; then dump the OUT band
  (`run_dump_bright.sh`) and correlate all 8 dihedral orientations vs golden (`compare_out_band.py`),
  expect **corr ≈ 0.99** in `transpose+rot180` (the T.rot180 orientation the golden spec allows).
- **CoreFFT 8-case iso-test** — `bash run_corefft_iso.sh` — isolates the fabric FFT chain with 8 known
  8192-pt rows: **impulse / impulse_k / dc / random / tone / twotone / twotone_hidr / dc_smalltone**
  (impulse-family corr=1.0, tone-family corr≥0.99998, incl. two 60 dB dynamic-range cases). Use for
  debugging or to re-prove the FFT survived a whole-SAR_TOP P&R even when only another kernel changed.
  `CASES=impulse bash run_corefft_iso.sh` runs one row as a fast smoke test (full suite ≈ 16 min). See §8.
- **Single-kernel iso-tests** — poke one kernel, read DDR back (§4): `resample_iso.gdb` (const-1000
  identity gather → SCRATCH[0]=0x03e80000), `detect_iso.gdb`, `fft_iso_test.gdb`.
- **Timing attribution** — the resample mcycle counters at `0xB0059120` (`run_read_prof.sh`) split the
  azimuth pass into coeff-compute / kernel-wait / flush (numerically inert; strip before shipping).

## 1. JTAG hygiene (DO NOT skip)
- **NEVER `taskkill /F` openocd/gdb** — wedges the FlashPro6 DM, needs board power-cycle.
  Clean shutdown: `python -c "import socket,time; s=socket.create_connection(('localhost',4444),5); time.sleep(.5); s.sendall(b'shutdown\n'); time.sleep(1.5); s.close()"` (openocd telnet port 4444), THEN kill the orphaned gdb (safe once openocd exited).
- **GOTCHA (2026-07-09): `run_corefft_iso.sh`'s openocd (board/microchip_riscv_efp6.cfg) has NO telnet 4444** —
  the clean-shutdown above FAILS ("telnet failed"), leaving no graceful stop. If gdb wedges you're forced to
  `taskkill /F` openocd → FP6 wedged. FIX before relying on it: launch openocd with an explicit `-c "telnet_port
  4444"` (or `gdb_port`/`tcl_port`) so the clean shutdown works. Until then, avoid situations that require killing.
- **GOTCHA (2026-07-09): after force-killing openocd, a BOARD power-cycle does NOT clear the wedge.** The
  FlashPro6 is USB-powered, independent of the board. Symptom: openocd connects (finds tap 0x0f81a1cf,
  enumerates regs, "Disabling abstract command…") then FREEZES before `monitor reset halt` (openocd log stops
  growing; no `>>>` echoes). RECOVERY: **unplug/replug the FlashPro6 USB, THEN power-cycle the board.**
- gdb scripts must end with `monitor resume` + `monitor shutdown`. The trailing
  "Remote communication error. Target disconnected." AFTER "shutdown command invoked" is **benign**.
- **Capture gdb output** — either `set logging file <path>` + `set logging on` in the .gdb, OR redirect
  the runner stdout to a file. NEVER `>/dev/null` (you lose the read values → wasted board run).
- **openocd startup**: `sleep 14` after launch before gdb connects (hart-examine race). Runner template:
  `run_status_probe.sh` (openocd + gdb -x <script.gdb>).
- Scene load = 1.5 MB over JTAG ≈ **2.4 min** (gdb prints nothing during `restore`). Full 128 MB OUT dump is impractical (hours); dump 256-row bands (4 MB) only.
- `libero.exe` lingers after PROGRAMDEVICE but **does NOT hold the FlashPro6** (released at "PROGRAM PASSED"). Don't over-wait — just launch openocd; it'll grab the FP6.

## 2. DDR + kernel-control map
| Buffer | Addr | Notes |
|---|---|---|
| SIG | `0x88000000` | scene / ping-pong. row R = `0x88000000 + R*0x8000` (8192 cplx u32) |
| SCRATCH | `0x98000000` | intermediate. row R = `0x98000000 + R*0x8000` |
| OUT | `0xA8000000` | uint16 magnitude image. row R = `0xA8000000 + R*0x4000` |
| TABLES | `0xB0000000` | geometry/coeffs/mailbox (CPU-read, cacheability per MPU) |
| COEF_IDX(0)/WQ(0) | `0xB0148000` / `0xB0158000` | int32[Np] / int16[Np] |
| mailbox | `0xB0058000` | +0 cmd, +4 base, +8 len, +C result, +10 status, +14 seq |
| SAR_PROG | `0xB0059100` | +0 pass, +4 idx, +8 total, +C heartbeat |

- **DDR is `0x80000000`–`0xBFFFFFFF` only. `≥0xC0000000` = ABOVE-DDR decode error** (NOT a cached/
  non-cached alias — cacheability is MPU-config, not address-aliased). Don't read `0xC8…`/`0xE8…`.
- Kernel control: `K_CORNER_TURN 0x60000000`, `K_WINDOW 0x60001000`, `K_DETECT 0x60002000`,
  `K_RESAMPLE 0x60003000`, `K_FFT 0x60004000`. Regs: `START +0x08` (write 1=go, read 0=done),
  `ARG0 +0xc, ARG1 +0x10, ARG2 +0x14, ARG3 +0x18`. **Never read an unused slave (e.g. 0x60005000) — hangs AXI un-haltably.**
- Kernel arg contracts: `detect(in,out)` no count (DN=8192²); `resample(in,idx,wq,out)`;
  `window(in,hamr,hamc,out)`; `corner_turn(src,dst)`; `fft_kernel(src,dst,nrows)`.

## 3. Coherent DDR read (FIC0 is non-coherent)
The fabric kernels read/write DDR via FIC0; the hart/gdb see L2. To read what a kernel actually wrote:
- **`call (void) flush_l2_cache(1)` from gdb** — evicts L2, so a subsequent *cached* read fetches
  physical DDR. (Also the way to push a gdb-loaded input to DDR before arming a kernel.) VERIFIED:
  load pattern → CRC(L2)=pattern → call flush → CRC(post-evict)=pattern ⇒ flush delivers to DDR.
- Mid-pipeline, SIG/SCRATCH data rows are **uncached** (kernels write via FIC0, hart never caches them;
  per-line resample flushes keep L2 cold) → a direct read already hits DDR. But `call flush` mid-run
  can perturb the sequencer (observed a restart) — read directly when possible.
- **CRC localization**: mailbox CRC32 (cmd `0x43524333`, zlib-compatible) over 16 MB of SIG/SCRATCH/OUT
  after a PIPE run (post-flush → DDR) pinpoints where data survives vs zeros. zero-CRC(16 MB)=`0xa47ca14a`.
- **GOTCHA**: resampled k-space cols 0–4 are legit **edge zero-fill** (first ~12 KC-grid pts out of
  range → idx=−1). Read **col 5+** to see real data. A truncated `x/8xw` (first line only) nearly
  mis-blamed pass-2/window when the FFT was the culprit.

## 4. Single-kernel isolation pattern (the workhorse)
`jtag_full/{detect,fft,resample}_iso*.gdb` + `run_*.sh`. Structure:
1. `monitor reset halt` + boot (`resume`, sleep 28–30 s, `arp_halt`, `thread 2`)
2. `restore <pattern>.bin binary <SIG>` (e.g. `fft_test_row.bin` = const re=1000)
3. pre-clear the dst first words (so a stale value can't fool you)
4. `call (void) flush_l2_cache(1)` (input → DDR)
5. arm the kernel (set ARG regs + START=1), `resume`, sleep, `arp_halt`, read START (0=done)
6. `call (void) flush_l2_cache(1)` (evict dst), read dst
- **Known-good expectations** (const re=1000 = `0x03e80000`): detect→`0x03e803e8` (mag 1000);
  resample identity coeffs→`0x03e80000` (passthrough); **FFT→DC delta `~0x7D000000` (32000 = 8192·1000>>8), NOT flat `0x00030000`** (flat = broken passthrough).

## 5. SmartHLS validation
- **vsim** is at `C:/Microchip/Libero_SoC_2025.2/Libero_SoC/QuestaSim_Pro/win64/` — **add to PATH**
  (the shls setup script wrongly points to `ModelSim_Pro`). `command -v vsim` must resolve first.
- `shls cosim` (RTL vs C) currently **segfaults in its C-testbench wrapper** (0xC0000005) — a tooling
  bug, not the design (`shls sw` runs clean). `shls sim` needs a custom Verilog TB.
- **C-logic validation** (does the fix compute right): `shls sw` + `python tb/gen_and_check.py gen <case>`
  / `check <case>` (cases: tone/twotone/pointtarget/random). tone → corr≈1.0, peak bin 137. **sw-sim
  passing does NOT prove the RTL** (the broken FFT also passed sw-sim). RTL truth = silicon fft_iso2.
- Regen RTL from fixed HLS: `shls hw` (produces `hls_output/rtl/*.v` + `scripts/libero/create_hdl_plus.tcl`).

## 6. HLS-FFT fabric rebuild + program
- `bash mpfs/fpga/run_hlsfft_build.sh` (3 stages, board-free, ~12 min): create project+cores+MSS+HDL+
  +assembly → stage constraints → synth/PnR/**VERIFYTIMING**/bitstream. Gates on DONE markers.
- **Check timing** before trusting: `SETUP nviol=0`, `HOLD nviol=0`, `TIMING_MET`, then `BITSTREAM_READY`
  + `BUILD_HLSFFT_DONE`. (Libero silently programs timing-failing bitstreams — see [[always-check-timing-closure]].)
- Program (board on): `libero.exe SCRIPT:program_hlsfft.tcl LOGFILE:...` → expect `PROGRAMDEVICE OK` +
  "Chain programming PASSED". Fabric-only change → firmware (eNVM) untouched, no reflash needed.
- Prereqs: `LM_LICENSE_FILE=C:\Users\lkwangsi\Documents\github\polarfire-soc\License.dat`;
  `libero.exe` at `C:/Microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin/`. No stale synth (synbatch
  zombies corrupt synth → host reboot clears them).
- **GOTCHA: a leftover `libero.exe` (from the previous program/build) holds a LOCK on `libero_hlsfft/`
  → `create_fresh_project_hlsfft.tcl`'s `file delete -force` fails "permission denied ... SAR_TOP.smat.seg"
  → STAGE 1 FAILED in ~18 s.** Fix: `taskkill //F //PID <libero>` FIRST (libero.exe is safe to /F-kill —
  the openocd/gdb no-force-kill rule is ONLY about the FlashPro6 DM, not libero), then re-run the build.
  Check `tasklist | grep libero` is empty before launching a rebuild.
- **When iterating the HLS kernel** (edit .hpp): `shls hw` regenerates RTL from the header (dependency
  tracking DOES pick up header edits — verified). Then `run_hlsfft_build.sh` picks up the new RTL via
  `create_hdl_plus.tcl`. Full cycle edit→hw→build→program→fft_iso2 ≈ 15 min.
- **Background chains**: launch long chains with the Bash tool's `run_in_background`, NOT a trailing `&`
  in a normal call (the tool waits and times out at 2 min even though `&` detaches — confusing). Append
  a sentinel (`CHAIN_DONE $(date)`) to the log so a Monitor can detect end.
- **`set_root` fails on RE-OPEN of a post-bitstream project** ("Please select a root ... set_root failed").
  The build session's `set_root -module {SAR_TOP::work}` works (fresh hierarchy) but `program_hlsfft.tcl`
  re-opening the finished project cannot re-select the root. **FIX: program INSIDE the build session** —
  build_full_prog_hlsfft.tcl now runs `run_tool PROGRAMDEVICE` right after export (root still set). Don't
  rely on a separate program_hlsfft.tcl for a fresh rebuild.
- **FALSE `TIMING_MET` gate**: the gate reads `designer/SAR_TOP/pinslacks.txt`; if the impl got named
  `impl2` (dirty project residue) that file is MISSING → the reader left `sv=0` → false TIMING_MET →
  bitstream silently not generated. FIXED: missing report now forces `sv=999` (fail). If you see
  `designer/impl2` instead of `designer/SAR_TOP`, the project is dirty → `rm -rf libero_hlsfft` (it's a
  regeneratable build artifact) and rebuild clean.

## 7. Debugging-methodology learnings (meta — apply these first)
Hard-won from the 2026-07-04 all-zero-image debug (see SAR_PIPELINE_STATUS.md):
- **"RETURN=0 / stage completes" ≠ "data is correct".** The pipeline reported RETURN=0 for a whole
  session while emitting an all-zero image. Always verify DATA (CRC / read-back / correlate), not just
  completion. Same trap as [[always-check-timing-closure]] ("stage completes"≠"data correct"≠"timing met").
- **A data-independent stage running fast proves nothing about the data.** The resample is a
  gather+lerp — it runs identically on zeros. "Resample sped up" did NOT mean data flowed.
- **Isolate every stage on silicon before blaming one.** The workhorse was the single-kernel iso test
  (§4): flush a known input to DDR, arm ONE kernel, read its output. That localized the failure to the
  FFT while proving resample/detect/corner-turn/coherency all work. Don't debug the whole pipeline.
- **Measure the input/output boundary of the suspect stage, not just the final output.** The FFT was
  confirmed as the zero-source only by reading its INPUT (rich) and OUTPUT (zero) directly — inference
  from "everything else works" was nearly wrong (a truncated `x/8xw` read of edge zero-fill columns
  briefly mis-blamed the wrong stage; read col 5+ past the edge zero-fill).
- **C-simulation passing does NOT prove the RTL.** SmartHLS `shls sw` + a numpy check passed at corr
  0.9999 for an FFT whose synthesized RTL was a passthrough. Only silicon (or RTL cosim, if it worked)
  is ground truth for HLS. Budget for the possibility that HLS output ≠ HLS source semantics.
- **When an HLS kernel is intractable, move the stage to the CPU.** A plain-C version on the U54 is
  provably correct, firmware-only (fast iteration), and fully controllable — a valid escape hatch when
  a synthesis bug resists multiple structural fixes and cosim is blocked. Trade throughput for correctness
  + iteration speed during bring-up; optimize later.
- **Image-correctness gotchas:** (a) a fixed-point FFT needs a block-exponent (BFP), not per-stage
  truncation, or the AC content rounds to zero (DC-only image). (b) SAR/FFT output matches the golden
  only "up to orientation" — always run an 8-dihedral + transpose search (correlate_cpufft.py), and mask
  saturated pixels before correlating (speckle is unforgiving; a few % saturation tanks the raw number).
- **Iteration-cost awareness:** a fabric rebuild is ~40 min and the Libero flow is fragile; a firmware
  rebuild is ~1.5 min. Push logic to firmware during bring-up whenever correctness allows — it turned an
  intractable multi-rebuild loop into minutes-per-iteration.

## 8. CoreFFT in-place range-FFT (fabric FFT, 2026-07-08) — build + iso-test
Sub-project to run the range-FFT on the **in-place CoreFFT** (8192-pt, 16-bit, conditional BFP)
instead of the CPU FFT. Wrapper `mpfs/fpga/corefft_inplace_wrap.v` (elastic LSRAM FIFO + SCALE_EXP)
is sim-validated vs the real core (see memory `corefft-streaming-vs-inplace`). CoreFFT STREAMING
maxes at 4096-pt + no BFP → 8192 REQUIRES in-place.

**Rebuild the CoreFFT bitstream (headless, ~1 hr, timing-gated):** the `libero_sar` SmartDesign is
the deleted-`.cxf` state, so use the VM-netlist flow — `libero.exe SCRIPT:mpfs/fpga/build_corefft_vm.tcl`
(fresh project `libero_corefft_vm`, `-vm_netlist_flow TRUE`, imports the surviving 62.5-MHz
`SAR_TOP_NL.vm`, associates `SAR_TOP_derived_constraints.sdc` (has the 62.5/7.8125 `create_generated_clock`)
+ `sar_fft_cdc.sdc` + `io/sar_io.pdc`, P&R, gate on `pinslacks.txt`, export). Result: **TIMING MET 0/0
(315,348 pins) → `SAR_TOP_corefft.job` (12.12 MB, FABRIC+SNVM)**. Preserved at
`mpfs/fpga/bitstreams/SAR_TOP_corefft.job`. GOTCHAS: `new_project` rejects `-instantiate_mss_component`
(use the minimal signature); `export_prog_job` needs `file mkdir $exportdir` first; the `.tcl` runs
setup-only first (`STOP_AFTER_SETUP 1`) to fail-fast on API errors before the ~1 hr P&R.

**⚠️ PROGRAM IT RIGHT (the mistake to never repeat):** program the fabric **FABRIC-ONLY**
(`SAR_TOP_corefft.job`, no eNVM), then **re-flash the APP** to eNVM with `bash mpfs/host/run_program.sh`
(`mpfsBootmodeProgrammer` --bootmode 1, via `fpgenprog` — reliable, NOT OpenOCD). **Boot mode 1 + the
APP is the debug state — the app cooperates with JTAG halt.** Do NOT build/flash an **HSS** eNVM
(`build_corefft_bootable.tcl` / boot-mode-1 HSS client): HSS does NOT cooperate with JTAG halt →
`openocd: "Target not halted" / gdb connection rejected`, and you must power-cycle. Re-flashing the
app is REQUIRED after any fabric program that touches eNVM (§6). `mpfs/fpga/bm1/` is run_program.sh's
working dir — `mkdir` it if a cleanup removed it.

**Run the CoreFFT iso-test:** `bash mpfs/host/run_corefft_iso.sh` — generates 8 known 8192-pt rows
(`fft_golden.py`), loads to `SIG`, drives `fft_feeder(0x60004000)→CoreFFT→fft_unloader(0x60005000)`
directly over JTAG (`jtag_full/corefft_iso.gdb.tmpl`), reads back `SCRATCH`, correlates each row vs
the **scale-invariant** BFP golden (CoreFFT's block exponent differs by a power of 2 — corr/nrmse
absorb it, proven in QuestaSim). Uses the §4 pattern: boot (resume, sleep 30, arp_halt), restore
input, `flush_l2_cache(1)` (input→DDR), arm feeder/unloader, `flush_l2_cache(1)` (evict dst), dump.
Offline plumbing self-checks corr=1.0. NOTE: in the CoreFFT build `0x60005000` is the unloader (a
REAL slave) — in the HLS build it's an unused slave (§2: reading it hangs AXI). Host-path GOTCHA:
run_corefft_iso.sh must pass **Windows (`C:/`) paths** to the Windows-native gdb (`restore`/`dump`/ELF)
— MSYS `/c/` paths silently fail "No such file". gdb runs with `-batch </dev/null` so a script error
can't park it at the prompt for 16 min. `CASES=impulse bash run_corefft_iso.sh` runs one row.

**⚠️ SILICON RESULT 2026-07-08 — the fabric's OLD `corefft_stream64_adapter` WEDGES.** First on-silicon
CoreFFT run: input loads fine (`SIG[0]=0x7d000000`), but after arming, **`feeder busy=1` never clears /
`unloader busy=0`** and SCRATCH is unwritten (pre-cleared `SCRATCH[0]` stays 0; rest = stale DDR) →
corr≈0. Reproduces at **1 row (4096 beats) too** → a fundamental FIRST-FRAME stall, not a between-frame
re-arm. Confirms `TIMEOUT_FFT1` is a real feeder/CoreFFT-handshake wedge, NOT a timing artifact (timing
MET 0/0). BUT this fabric (`SAR_TOP_NL.vm`) has the OLD adapter — the NEW sim-validated
`corefft_inplace_wrap` (better elastic FIFO + LSRAM show-ahead) is NOT in it. SmartDebug ROOT-CAUSED it (2026-07-08): the CoreFFT is FINE — `FFT:buf_ready_r=1` (ready, twiddle-init
done), `sync_ngrst delayLine=1` (out of reset). The wedge is the **`fft_feeder` SmartHLS read master**:
`FEED/axi4slv_inst/rd_controller` shows `arvalid=0`, `rd_cnt=0`, `rd_data_valid=0`, and the HLS loop
counter `FEED/…/fft_feeder_BB_4_phi_reg=0` — i.e. the read master **issues ZERO AXI reads** despite
correct config (readback confirmed `src=0x88000000`, `nbeats=4096` via feeder_diag.gdb) and `busy=1`.
Config landed, kernel started, but the read engine never fires -> read FIFO empty -> loop stuck at i=0
-> nothing reaches CoreFFT. This is the SAME class of SmartHLS-2025.2 synth bug as the K_FFT butterfly
([[m3-pipeline-silicon-status]]): cosim-PASS, silicon-DEAD RTL. The `fft_feeder` was never
silicon-validated. FIX: replace `fft_feeder` with a hand-written Verilog AXI read-burst master
(mem->stream, feeding the gearbox) — bypass SmartHLS (unreliable here). NOT the CoreFFT, NOT clocks, NOT
timing, NOT corefft_inplace_wrap. (SmartDebug on libero_corefft_vm/corefft_vm.prjx; diag:
mpfs/host/jtag_full/feeder_diag.gdb reads the ARG regs back.)
**PHASE A DONE (2026-07-08): `mpfs/fpga/fft_feeder_v.v` written + sim-validated** (sim/fft_feeder_v_tb.v,
AXI read-slave BFM + backpressuring stream sink): reads 600 beats via 4KB-aware multi-burst INCR, streams
IN ORDER under backpressure -> 600/600 errors=0 PASS. Single-outstanding AXI4 read master -> elastic LSRAM
FIFO -> AXI4-Stream; AXI4-Lite ctrl matches the HLS reg map (+0x08 START, +0x0c src, +0x10 nbeats). Watch:
`fifo_room` MUST be declared wide (a 1-bit decl truncated 512->0 and the AR branch never fired). PHASE B
(pending) = swap fft_feeder->fft_feeder_v in SAR_TOP + rebuild. **NETLIST-SPLICE RULED OUT (2026-07-08):**
in SAR_TOP_NL.vm the `fft_feeder_top` module is a synthesis-optimized BLOB — its FEED instance wires
corner_turn's ctrl (start_1/accel_active_1/finish_1=CT_*), detect's ctrl (start_0/..=DET_*), and gearbox
glue (in_phase/GBX_datai_valid/FFT_BUF_READY, out N_472_i/N_473_i), so replacing the module breaks CT/DET/GBX.
=> Phase B MUST reconstruct the SAR_TOP SmartDesign (recovery option 2: create_fresh_project.tcl +
sartop_assembly.tcl, instantiate fft_feeder_v as an HDL core in place of the SmartHLS feeder, re-synth/P&R)
— documented-fragile, a major multi-step fabric effort. The fix itself (fft_feeder_v) is DONE + proven.
**PHASE B step 1 DONE (2026-07-08):** `mpfs/fpga/fft_feeder_top.v` — drop-in Verilog wrapper exposing the
SAME bus interfaces as the HLS core (axi4initiator read master, axi4target 64-bit AXI4 control slave with a
built-in AXI4->AXI4-Lite/32-bit-lane bridge, out_var stream; clk + active-HIGH reset), wrapping fft_feeder_v.
Compiles clean; reuse component/User/Private/fft_feeder_top/1.0/fft_feeder_top.xml (same bifs). Register via
create_hdl_core (like gearbox_idconv_cores.tcl) instead of the HLS create_hdl_plus. VERIFY: IDW + axi4target
addr width vs CIC target4; read-master AXI ID vs DIC initiator4.
**PHASE B step 2 BLOCKED (prereqs cleaned):** ALL HLS core outputs (hls_{corner_turn,window,detect,resample,
fft_feeder,fft_unloader}/hls_output) were deleted in 198f5f8 -> create_fresh_project.tcl can't run (sources
per-core create_hdl_plus.tcl). Must FIRST regenerate the WORKING cores via SmartHLS `shls hw` (5 cores;
drop hls_fft_feeder), THEN modify create_fresh_project.tcl (remove hls_fft_feeder from the loop; add
fft_feeder_top.v via create_hdl_core) + sartop_assembly.tcl (FEED = fft_feeder_top; wiring unchanged:
axi4initiator->DIC:AXI4minitiator4, axi4target<-CIC:AXI4mtarget4, out_var->GBX), then full build + P&R gate +
program + iso-test. MSS component (mss_*/ICICLE_MSS.cxz) + COREFFT_C0 gen (libero_corefft) survive. This is a
multi-hour, board-dependent, fragile FOCUSED SESSION — the drafted fix + wrapper are ready to drop in. For integration the read master's AXI ID
width must match the DIC initiator port (DIC=8-bit ID -> ID_FIX/sar_axi_idconv -> 4-bit FIC_0; 32-bit addr,
zero-extended 32->38 by ID_FIX — see AMBA_ARCHITECTURE.md §4).

**PHASE B step 2 DONE (2026-07-08):** reconstructed SAR_TOP headless with the Verilog feeder —
regenerated the 5 working HLS cores (`shls hw`), `create_fresh_project_ffv.tcl` (drops hls_fft_feeder,
sources `feeder_v_core.tcl` to register fft_feeder_top via create_hdl_core + hdl_core_add_bif/assign for
axi4initiator[master]+axi4target[slave]), assembled SAR_TOP, `build_full_prog_ffv.tcl` → **P&R TIMING MET
(setup 0 / hold 0)** → `libero_ffv/export/SAR_TOP_ffv.job` (12.12 MB, committed to bitstreams/). Programmed
(PROGRAM PASSED) + re-flashed the debug APP (boot mode 1, cooperates with halt) via run_program.sh.

**PHASE B step 3 — FIRST SILICON ISO-TEST (2026-07-09): feeder ARMS but read txn WEDGES FIC0.** Result of
`run_corefft_iso.sh` on SAR_TOP_ffv: input loads fine (`SIG[0]=0x7d000000`), feeder+unloader arm, but after
the 10s compute wait **both stay `busy=1`** (should be <1ms for 32768 beats) AND the subsequent CPU
`flush_l2_cache(1)` **HANGS ~5min un-haltably**. PROGRESS vs the dead SmartHLS RTL: the Verilog feeder DOES
come out of reset and `start`→`busy=1` (the old core never even armed). But the stall+flush-hang is the
signature of an **outstanding AXI read on FIC0/DDR that never returns RLAST** → S_DATA hangs forever →
FIC0/DDR wedged → CPU flush stalls. Leading hypothesis (matches the step-1 VERIFY flag): the feeder's
**first AR to 0x88000000 misroutes through sar_axi_idconv/DIC→FIC0** — bad addr zero-extend (32→38) or ID
routing — so R never comes back. (A pure downstream-tready stall would NOT wedge the bus: S_ADDR only issues
an AR it can fully buffer, so the first 64-beat burst always completes cleanly; a hung R means the txn
itself misrouted.) Board must be **power-cycled** to clear the wedge before any re-run.
HARNESS UPGRADES for the next run (done, no board needed): (1) `corefft_iso.gdb.tmpl` now reads `busy` at
t=2s AND t=10s and does a **hang-proof raw SCRATCH read+dump BEFORE** the evict `flush_l2_cache` (so the
decisive signals survive even if the flush wedges again); (2) `run_corefft_iso.sh` honors `NBEATS_OVERRIDE`
for a **64-beat single-burst diagnostic** — if even one burst wedges FIC0 → first-AR addr/ID routing bug;
if 64 works but full-size wedges → mid-stream count/4KB-boundary bug. NEXT: power-cycle → `CASES=impulse
NBEATS_OVERRIDE=64 bash mpfs/host/run_corefft_iso.sh` → if it wedges, **SmartDebug probe** fft_feeder_v
internals (`m_arvalid/m_arready/m_rvalid/m_rlast/state/fcount`) + the sar_axi_idconv AR/R to see the misroute.

**PHASE B step 3 — FEEDER VALIDATED, BLOCKER MOVED TO UNLOADER/CoreFFT-EMIT (2026-07-09, power-cycled).**
Correction to the wedge read above: that was a MULTI-frame artifact, not the feeder. Two clean single-run
diagnostics settle it:
  * `CASES=impulse NBEATS_OVERRIDE=64` (64-beat single burst): `feeder busy=0` at t=2s, flush did NOT hang.
  * `CASES=impulse` (one full 8192-pt frame = 4096 beats): **`feeder busy=0`** (reads all 4096 beats, streams,
    drains FIFO — the CoreFFT INPUT side consumed the whole frame), flush did NOT hang, gdb finished clean.
    BUT **`unloader busy=1` forever and SCRATCH = all zeros** (`corr=0, |scale|=0`).
**CONCLUSION: the Verilog feeder (`fft_feeder_v`) WORKS on silicon — Phase B goal achieved.** The new,
isolated blocker is the CoreFFT-emit/unloader path producing NO output. Two candidates (need SmartDebug to
split): (A) CoreFFT in-place never emits — the old `corefft_stream64_adapter`/GBX may not drive the in-place
BUF_READY/DATAI_VALID/READ_OUTP/OUTP_READY handshake (twiddle-LUT init on SLOWCLK) correctly; my
`corefft_inplace_wrap.v` is NOT in this fabric. (B) the **`fft_unloader` (stream→mem SmartHLS kernel) is dead
RTL just like the feeder was** — its AXI WRITE master issues zero writes (mirror of the feeder's dead read
master); consumes the stream but never writes SCRATCH → `busy=1`. Given the feeder precedent (SmartHLS
mem↔stream masters synthesize dead), (B) is the leading hypothesis and the fix mirrors the feeder: a
hand-written Verilog stream→mem writer. NEXT: SmartDebug probe to split (A)/(B) — CoreFFT `READ_OUTP`/
`OUTP_READY`/`outp_valid` (does it EMIT?) + the `fft_unloader` write master `AW*/W*/aw_valid` (does it
WRITE?). If (B): write `fft_unloader_v.v` (AXI4-Stream slave → elastic FIFO → AXI4 write-burst master),
register + rebuild exactly like the feeder. Diagnostic harness (`corefft_iso.gdb.tmpl` t=2s/t=10s busy +
hang-proof dump; `NBEATS_OVERRIDE`) is in place.

**PHASE B step 3 FINAL VERDICT (2026-07-09, SmartDebug on the CORRECT ffv DB): blocker = CoreFFT output
phase, NOT the feeder or unloader.** Correction to the "leading = dead unloader (B)" guess above — SmartDebug
(from the RIGHT project) proved the unloader innocent:
  * **Feeder `fft_feeder_v` = VALIDATED** (busy=0, fed all 4096 beats, drained). Phase B deliverable done.
  * **Unloader `fft_unloader` = INNOCENT.** Source is a trivial `for(i<nbeats) dst[i]=in.read();` copy;
    SmartDebug: `UNLD/accel_active=1` (alive), it just BLOCKS on `in.read()` when the stream runs dry.
  * **CoreFFT config = correct 8192-pt.** `COREFFT_C0.v` instantiates `.POINTS(8192)` (drives the compute /
    `fft_inpl_sm_top`); synthesized FFT LSRAM array is large (R0C0..C5 A/B). `FFT_SIZE=256` in
    `coreparameters.v` is a HARMLESS leftover — it only feeds the AXI4-Stream TLAST logic, unused because
    `NATIV_AXI4=0` (we use the classic BUF_READY/DATAI_VALID/READ_OUTP/OUTP_READY interface). NOT the bug.
  * **ROOT CAUSE: CoreFFT drops OUTP_READY mid-frame.** SmartDebug (correct DB, `FFT/COREFFT_C0_0/
    genblk1.DUT_INPLACE/`): `outp_ready_r=0`, `datao_valid_r=0` while the gearbox holds `have_lo=1` with a
    real half-pair (`GBX/lo_Z=0x1F400000`, re=0x1F40) and its FIFO is drained (`GBX/wptr_Z=rptr_Z=0x67`).
    So CoreFFT emitted only PART of the 8192-pt frame then de-asserted OUTP_READY and stopped → gearbox
    can't form the next beat → unloader starves on in.read() → `busy=1`, SCRATCH≈0.
This is the known-hard in-place-CoreFFT output integration — the same wall that drove the pivot to the CPU
FFT ([[m3-pipeline-silicon-status]], shipping corr 0.9923). Feeder+unloader+gearbox-input all PROVEN good.
NEXT (deeper CoreFFT probe, new session): SmartDebug the CoreFFT internal state — SLOWCLK toggling +
twiddle-init complete (runbook §6 Phase A2), the `fftSm` state machine, PONG/SCALE_EXP, and whether
OUTP_READY EVER fully asserts for a whole frame. Also try a clean power-cycle + single impulse frame +
immediate probe (my 3 back-to-back arms without power-cycle may have accumulated fabric state:
`UNLD/rd_req_cnt=7053` > one frame's 4096). Compare our gearbox read_outp timing vs the golden
`in_place_FFT_tb.v` (read_outp held high, gated low only at cycleCnt==0 init). Harness + probe procedure are
in place (this file + SMARTDEBUG_RUNBOOK.md §6). CAUTION: SmartDebug MUST be launched from the `libero_ffv`
project — the old `libero_sar` DB has `have_beat`/DMA nets that DON'T exist in the programmed ffv fabric, so
its probe reads are garbage (cost us a round this session).

**PHASE B step 3 ROOT CAUSE CONFIRMED + FIXED IN RTL (2026-07-09, reference-grounded + QuestaSim).**
A 3-agent fan-out (CoreFFT UG extract + impl-vs-golden RTL audit + web) settled it. The blocker is a
GEARBOX defect, not the feeder/unloader/CoreFFT-config/SLOWCLK (all verified correct):
  * CoreFFT `DATAO_VALID` trails `READ_OUTP` by ~4 pipeline cycles (`fftSm.v:595-603`). The gearbox
    (`corefft_stream64_adapter.v`) de-asserted `read_outp` combinationally on `fifo_full` AND gated its
    capture on `read_outp` (`... & read_outp & datao_valid`). So when `read_outp` fell under DDR
    backpressure, the ~2 in-flight `DATAO_VALID` beats were DROPPED (core counted them, gearbox didn't) →
    sample loss + re/im pairing flip (`have_lo`) → unloader short of its 4096 beats → starves (busy=1).
  * The CoreFFT UG (in-place, MEMBUF=0) EXPLICITLY permits pausing READ_OUTP ("arbitrary breaks in the
    burst"); pausing only lengthens the cycle, never truncates. RULED OUT: "read_outp must stay high"
    (refuted by `fftSm.v` + golden TB which toggles it 50%), MEMBUF=1 overwrite (we're MEMBUF=0, no PONG),
    SLOWCLK too fast (GL1=7.8125MHz=CLK/8, meets ≤CLK/8), point-count (POINTS=8192; FFT_SIZE=256 feeds only
    the unused NATIV_AXI4 path).
  * WHY prior sim missed it: `corefft_behav.v` asserts DATAO_VALID same-cycle as READ_OUTP (ZERO latency),
    so backpressure never dropped in-flight beats. Real bug needs a latency-accurate TB.
**FIX (RTL, done + proven):** `corefft_stream64_adapter.v` now captures on `datao_valid` REGARDLESS of
`read_outp`, and de-asserts `read_outp` on `fifo_almost_full = fcount >= FDEPTH - LAT_MARGIN` (LAT_MARGIN=8
beats reserved for in-flight pipeline). Proven with the REAL CoreFFT RTL under heavy backpressure by
`mpfs/fpga/sim/corefft_stream64_lossck_tb.v` (run_stream64_lossck[_256].do): OLD adapter FAILs (16 samples
lost @256pt), FIXED adapter PASSes @256pt (0 lost, read_outp dropped 168×) AND @8192pt deployed config
(0 lost of 8192, read_outp dropped 26182×, FIFO peak 58/64). **VALIDATED ON SILICON
2026-07-09**: rebuilt `libero_ffv` with the fixed gearbox (`build_gbxfix_ffv.tcl`, TIMING MET 0/0) →
programmed `SAR_TOP_gbxfix.job` → re-flashed app → one-frame iso-test: **feeder busy=0, unloader busy=0
(starvation GONE), impulse corr=1.000000 nrmse=0, ALL ROWS PASS**, flush no hang, clean shutdown. Then the
**FULL 8-case suite (multi-frame, 32768 beats) ALL PASS** — impulse/impulse_k/dc/random corr=1.000000,
tone/twotone/twotone_hidr/dc_smalltone corr≥0.99998 (incl. both 60 dB dynamic-range cases). Multi-frame
wedge class RETIRED. The CoreFFT-on-fabric range-FFT path now works end-to-end on hardware. Bitstream: `bitstreams/SAR_TOP_gbxfix.job`.
Full write-up: `openspec/changes/fix-corefft-gearbox-backpressure/`. This class of work is now
codified as reusable `.claude/agents/` (fpga-ref-verifier, silicon-test-runner, smartdebug-planner,
libero-build) + `.claude/skills/` (fpga-ref-check, silicon-iso-test, smartdebug-probe, jtag-recover).

## 9. Phase-sensitive CoreFFT test (board-free, 2026-07-10) — proves the FFT phase, not just |·|

**Why:** the iso-test (§8) correlates *magnitude* only, which is scale- AND phase-invariant — it passes
even if the FFT were conjugated, bin-reversed, or per-bin phase-rotated. To rule a phase/sign fault in
or out without the board, compare the CoreFFT **complex** output to the exact float FFT.

**Method (decisive, ~35 min, no board):**
1. `mpfs/host/gen_phase_input.py [N]` — writes a SINGLE strong impulse to `sim/fft_vectors_n8192/phase_in.hex`.
   A lone impulse ⇒ every output bin is full-magnitude (flat |FFT|, clean phase ramp), so 16-bit
   quantization noise can't mask a phase error. (Multi-impulse / random inputs give a flat, weak-bin
   spectrum where mean-subtracted correlation drowns in quant noise — misleading; don't use them here.)
2. `sim/run_corefft_phase_{256,8192}.do` — the §8 loss-check TB (`corefft_stream64_lossck_tb.v`) with the
   new `OUT_HEX` param dumps CoreFFT's captured complex output (`emitted[]`) + SCALE_EXP. `BP_ON=0` = no
   backpressure = clean frame. 256 core = `libero_corefft256` (~2 min); 8192 = `libero_corefft` (~6 min).
3. `mpfs/host/corefft_phase_compare.py [N]` — the RIGHT metric is the **complex ratio** `core/gold` on
   strong bins: a correct FFT ⇒ `|ratio|` constant (= 2^-SCALE_EXP) and `angle(ratio)` a single constant.
   A phase bug breaks constancy. It also tests conj / bitrev / +j-convention candidates.

**RESULT (2026-07-10): CoreFFT is PHASE-EXACT at BOTH 256 and 8192.** Every bin = `float_FFT × 2^-2`
(SCALE_EXP=2), `|ratio|` spread 0.0%, phase spread **0.0°**, forward −j convention. conj/bitrev/+j all
~104° off. Combined with the §8 zero-loss gearbox and the corr-1.0000 per-row-BFP+renorm model
(`real_board_scene_test.py`), the **entire fabric FFT chain (feeder→CoreFFT→gearbox→unloader) + scaling
algorithm is proven sound board-free.** A fabric-pipeline corr~0 therefore is NOT the FFT/gearbox/scaling
— look at the corner-turn/transpose, feeder/unloader row addressing at 8192-row scale, FIC0 coherency, OR
confirm the corr~0 wasn't measured on a pre-renorm build (model's worst case with renorm fully broken is
corr 0.51, not 0 — a true ~0 needs garbage/zeros, not a scale error).

## 10. Value-level per-stage localization (2026-07-10) — found the detect sign-ext bug

**Why:** correlation is scale/phase-invariant AND was meaningless here (output saturated → corr ≈ −1
artifact). To localize a pipeline fault, compare COMPLEX SAMPLE VALUES per stage against a bit-accurate
model / the CPU path, not a scalar corr. This is what found the real bug after several false leads.

**Method + tooling (all in mpfs/host):**
- Inject a KNOWN input at the FFT stage: `gen_fft_value_input.py` → `inject_fft_value.gdb` ('FTES'
  mailbox = `sar_fft_pass_test`, runs `fft_pass` on pre-loaded SIG, no slow zeroing) → `fft_value_compare.py`.
  Proved the fabric range-FFT VALUE-correct (phase 0.0°, exact bins, uniform 1/N, relative-mag preserved).
- Per-stage magnitude trace: `flow_pipe_trace_run.gdb` dumps SCRATCH (range/cornerturn), SIG (azimuth),
  OUT (detect); `trace_stage_analyze.py`. **CAUTION: complex buffers are 4 B/px, OUT is 2 B/px — the
  same byte offset is DIFFERENT ROWS.** SIG rows R = `0x88000000 + R*8192*4`; OUT rows R = `0xA8000000 + R*8192*2`.
- Same-row SIG-vs-OUT peek (`peek_sig_out.gdb`, `x/`): revealed OUT=|SIG| where I≥0 but OUT=0xFFFF where I<0.
- ISOLATION (removes golden-orientation doubt): mode0 CPU-FFT SIG vs mode1 fabric SIG at the same band
  (`flow_pipe_mode0_sig.gdb` + `compare_mode0_mode1_sig.py`) = **0.9999** → fabric FFT == CPU FFT, fabric is fine.

**ROOT CAUSE of fabric-pipeline corr~0: the `detect` kernel.** Source (`hls_detect/detect.cpp`) is
correct (`hi16` casts int16_t) but SmartHLS **mis-synthesized the high-16 (I) sign-extension → I read
as unsigned** → negative I overflows `isqrt` → clamps 0xFFFF. ~50% of FFT outputs have I<0 → 49.6%
saturation → corr collapse. Same SmartHLS class as the K_FFT butterfly. **FIX applied:** branchless
`sext16(u)=(int32_t)((u&0xFFFF)^0x8000)-0x8000` for BOTH hi16/lo16 (symmetric). Needs a fabric rebuild;
de-risk first with a CPU-detect firmware path (confirms 0.99 end-to-end without a rebuild).

**HARD-WON gotchas:** never external-`timeout`/SIGTERM a gdb mid-JTAG — it wedged the FABRIC (hart
`reset halt` does NOT reset fabric; a kernel then hung, needed a power-cycle). Run board jobs in the
background so they self-terminate via `monitor shutdown`. This gdb build crashes (`find_inferior_pid`
assertion) on `call flush_l2_cache` if the hart is mid-execution — guard flush/dump behind a done-check.

See also `SAR_PIPELINE_STATUS.md` (status + latency roadmap), `SMARTDEBUG_RUNBOOK.md`,
`LIBERO_HEADLESS_PLAYBOOK.md`, `SAR_PIPELINE_PROCESS.md`.

## eMMC Milestone-1 iso-test (write -> read-back -> CRC) — PROVEN 2026-07-14

Runs the on-board eMMC self-test (`sar_emmc_selftest`) over JTAG and reads the verdict.
`bash mpfs/host/run_emmc_iso.sh` -> drives `jtag_full/emmc_selftest_iso.gdb`. PASS looks like:
`verdict=0 init=0 write=5 read=5 crcE==crcR memcmp=1`, and `SRS04 (OCR)` nonzero.

### Prereqs (the full eMMC recipe — all committed)
1. **MSS**: `mss_nodll/ICICLE_MSS.cfg` has eMMC enabled (EMMC/EMMC_DATA_7_4=MSSIO_B4,
   EMMC_SD_SWITCHING=ENABLED_EMMC, SD=MSSIO_B4 + SD_VOLT pins, Bank4=1.8V). Regen `.cxz`
   with `pfsoc_mss -GENERATE ... -EXPORT_HDL:true`. Regenerate the firmware
   `fpga_design_config` from the as-built `ICICLE_MSS_mss_cfg.xml` via
   `src/platform/soc_config_generator/mpfs_configuration_generator.py` (adds
   `CONFIGURED_PERIPHERALS=0x103` = the SDMMC clock/de-reset enable) and vendor it into
   `.../src/boards/icicle-kit-es-ddr-666MHz/fpga_design_config`.
2. **Fabric (the key fix)**: `sartop_assembly.tcl` ties `SDIO_SW_SEL0/SEL1/EN_N = 0`
   (pins D7/C7/B7, Bank1 LVCMOS33 in `constraints/sar_io.pdc`) -> mux U44/U29 = COM-NC =
   eMMC. `build_full_prog_ffv.tcl` imports `constraints/sar_io.pdc`. Rebuild ffv bitstream
   (create_fresh_project_ffv -> remove_det -> reconfig_ccc62p5 -> build_full_prog_ffv),
   program with `program_ffv.tcl`.
3. **Firmware** (`-DSAR_EMMC_ENABLE`): `sar_emmc.c` does mss_config_clk_rst(MSS_PERIPH_EMMC)
   + 8-bit/LEGACY/1.8V init + bounded watchdogs (send_mmc_cmd + HRS0). `mss_mmc` + `mss_gpio`
   un-excluded in `.cproject` and added to the generated makefiles. Build (`make all`),
   flash (`run_program.sh`).

### JTAG gotchas (why the iso-test is shaped this way)
- **Use the mailbox, NOT `p sar_emmc_selftest(...)`** — the gdb inferior-call crashes under
  openocd `-rtos hwthread` SMP ("failed to get register 33"). The script writes MBX_CMD_EMMC
  (0x454D4D43) to the mailbox @0xB0058000 (base=+4=LBA), resumes, waits, reads back.
- **Never read SDHCI regs (0x20008xxx) before the self-test runs** — clock-gated until
  MSS_PERIPH_EMMC is enabled; an unclocked read dead-buses/wedges hart1 (power-cycle only).
  The script gates the SRS04 read on mailbox `status==0xC0FFEE03`.
- **Attach in place; do NOT `monitor reset halt`** — power-on eNVM boot already lands hart1
  in its u54_1() mailbox loop; a JTAG reset won't reliably re-boot the U54 on this ES silicon.
  If a run ever wedges hart1 (unhaltable, dmstatus allrunning), only a **power-cycle** clears it.
- openocd launched with `-c "telnet_port 4444"`; teardown via `monitor shutdown` (or a telnet
  `shutdown`) — never SIGTERM/taskkill openocd (wedges the FP6 DM -> needs USB replug).

## eMMC Milestone-2 provisioning (bulk scene write to INPUT partition) — PROVEN 2026-07-14

Writes a host-packed `SARI` image to the eMMC INPUT partition (LBA `0x80000`), reads it back
and CRC-verifies, TIMING the write for a real throughput number. Firmware: `sar_emmc_provision()`
via mailbox `MBX_CMD_EMMC_PROV` (`0x45505256` 'EPRV'); record @ `0xB005D000`.

### Why SYNCHRONOUS single-block (not SDMA)
hart1 runs with `MSTATUS_MIE` cleared (`u54_1.c`). `MSS_MMC_sdma_write()` returns `IN_PROGRESS`
and its completion is ISR-driven (`mmc_main_plic_IRQHandler` updates `g_mmc_trs_status.state` +
services the 512 KB SDMA boundary) — with interrupts off that ISR never fires, so `get_transfer_status`
spins forever = un-haltable hang. The single-block primitive is fully synchronous, so it CANNOT
hang. (To use SDMA later, either enable the MMC PLIC IRQ on hart1, or "pump" `mmc_main_plic_IRQHandler`
in a bounded poll loop — it already handles the boundary re-arm + state update.)

### Measured rates (Centerfield 97.6 MB image, 190,534 × 512 B, LEGACY/25 MHz/8-bit)
- **WRITE 0.132 MB/s** (~3.9 ms/block, dominated by per-CMD24 program/busy) -> 97.6 MB ≈ 738 s (~12 min).
- **READ  1.544 MB/s** -> 97.6 MB ≈ 63 s. This is the payoff: a boot-time eMMC->DDR load replaces
  the ~3 h JTAG scene load (~170x). Both scale linearly; verified identical at 1 MiB and full 97.6 MB.

### Procedure (host-only pack, then two board legs)
1. **Pack** (host, board-free): `python mpfs/host/emmc_pack.py --stage <jtag_stage_deci1> --out
   mpfs/host/emmc_input.img`. Self-verifies all blob/segment CRCs + that the JOB reconstructs from
   each TOC entry. Note the host image CRC: `python -c "import zlib;print(hex(zlib.crc32(open('emmc_input.img','rb').read())&0xffffffff))"`.
   Stage dir must be CURRENT-format (10 role bins: sig,f0,df,pr,tans,invorder,krgrid,kcgrid,hamr,hamc)
   — NOT the stale pre-resample `jtag_stage/` (sig,kr,kc,tanphi,win). `jtag_stage_deci1` = Centerfield.
2. **Rate/integrity probe (optional, no data load)**: `bash mpfs/host/run_emmc_prov_iso.sh [SPAN] [SLEEP_MS] [SRC]`
   provisions a span of RESIDENT DDR (firmware CRCs the source right before writing, so
   source-vs-readback is self-consistent WITHOUT any JTAG load). Use to measure MB/s + prove the
   full 190,534-block path before committing the ~3 h restore. PASS = `verdict=0`, `crcE==crcR`.
3. **M2d-2a restore** (~3 h, one-time): `bash mpfs/host/run_emmc_restore.sh` -> JTAG `restore`s
   `emmc_input.img` into DDR `0x88000000`, then an on-hart CRC32 (mailbox 'CRC3') checks the DDR
   image against the host CRC in SECONDS (catches a corrupt load before the ~12 min write). DDR
   persists across JTAG sessions — **do NOT power-cycle** after this.
4. **M2d-2b provision**: `bash mpfs/host/run_emmc_prov_iso.sh 97553408 1100000 0x88000000` ->
   PASS = `verdict=0` and `crcE==crcR==<host image CRC>` (full host->DDR->eMMC->back proof).

### Gotchas earned here
- **gdb `restore` needs a WINDOWS path** (`C:/...`), not a git-bash `/c/...` path. MSYS translates
  `/c/...` for .exe *arguments* (so `-batch $ELF` works) but NOT for paths *inside* the .gdb script
  — `restore /c/...` fails "No such file or directory". `run_emmc_restore.sh` uses `cygpath -m`.
- Prov record @ `0xB005D000`: +0x00 magic(0xE3C0FF20) +0x10 crcE +0x14 crcR +0x18 byte_len
  +0x1C nblocks +0x20 dest_lba +0x24 fail_blk +0x28 write_us(u64) +0x30 read_us +0x38 write_cycles
  +0x40 verdict. Read-back staging = SCRATCH (`0x98000000`), source = SIG (`0x88000000`).
- Same JTAG hygiene as Milestone-1 (mailbox trigger, attach-in-place, telnet-4444 shutdown, never
  taskkill). No SDHCI-register reads in the prov path, so no dead-bus gate needed.
- **`MBX_CMD_CRC32` result is not L2-flushed** — its handler writes `mbx->result` with only a
  fence, so a gdb PHYSICAL read gets a stale value (seen: 0x00000000 after a good restore, CRC was
  actually correct). Until fixed (add `flush_l2_cache` to that handler), verify a restore with a
  DDR peek instead (`run_ddr_peek.sh` — SARI magic 0x53415249 at the load addr). The EPRV
  provisioner flushes its OWN record, so its crcE/crcR are trustworthy.
- **PROVEN 2026-07-14**: real Centerfield image (97.6 MB) provisioned end-to-end —
  crcE==crcR==0x58d0ea66 (host CRC), write 747.6 s / read 63.1 s, verdict=0.

## eMMC Milestone-3 boot-load + focus + output persistence — PROVEN 2026-07-14

Run a scene straight from the card (no host JTAG data load), then persist the result on the
card. Firmware `sar_emmc_load` / `sar_emmc_save_out` / `sar_emmc_roi` / `sar_emmc_verify_out`;
generic runner `mpfs/host/run_m3_iso.sh CMD BASE LEN SLEEP_MS REC_ADDR [DUMPADDR BYTES FILE]`.

Sequence (mailbox cmds; records in the 0xB005Exxx block):
1. **LOAD** `ELOD` 0x454C4F44, .base=scene idx (0). eMMC INPUT -> DDR: scatters the 10 blob
   segments to `sar_emmc_role_addr` + rebuilds the JOB. rec@0xB005E000: verdict, nseg(=10),
   sig_crc_exp==sig_crc_got, M/N. ~77 s. PROVEN: sig_crc 0x89fa12dc, M=5634 N=4319.
2. **PIPE** `MBX_CMD_PIPE` -> `sar_form_image`, result=stage status (0=OK). PROVEN status 0.
3. **ROI** `EROI` 0x45524F49 (from DDR) / **ROIE** `EROE` 0x45524F45 (from SARO image).
   .base=(r0<<16)|r1  .len=(c0<<16)|c1. Gathers OUT[r0:r1,c0:c1] uint16 -> SCRATCH
   (0x98000000); dump it with gdb `dump binary memory`; render with `render_crop.py`.
   rec@0xB005E200 (crc of crop). PROVEN: center 1024x1024 = coherent focused SAR image.
4. **SAVEOUT** `ESAV` 0x45534156, .base=scene_id .len=run_seq. Full OUT (8192x8192 uint16,
   128 MB) -> SARO (LBA 0x880000). ~16 min. rec@0xB005E100 (out_crc, io_status).
5. **VERIFY_OUT** `EVOU` 0x45564F55. Reads the SARO superblock + whole image, recompute CRC
   vs TOC out_crc. rec@0xB005E300 (out_crc_exp==out_crc_got). Detects a torn SAVEOUT (ROI's
   partial read cannot).

### Crash-safety (SAVEOUT ordering — earned the hard way)
SAVEOUT is **INVALIDATE (magic->0) -> write IMAGE -> COMMIT superblock LAST**. The superblock
is the sole "image valid" record, so it is written last as the (near-atomic) commit. A power
loss during the ~16 min image write leaves an INVALID superblock -> readers reject the torn
image, rather than trusting a half-written one. (First cut wrote superblock-first = a torn
image looked committed AND ROI wouldn't notice; fixed same day + added VERIFY_OUT.) A SAVEOUT
interrupted by power-off leaves INPUT intact and is fully recoverable by re-running LOAD/PIPE/
SAVEOUT. Never power-cycle between a load and its dependent test unless the data is on the card.

### Reminder
Host<->PC dump is STILL ~3 h regardless of eMMC (FP6 JTAG ~9 KB/s is the bottleneck) — eMMC
only accelerates on-board transfers. Verify via small ROI crops, keep the full image on the card.
