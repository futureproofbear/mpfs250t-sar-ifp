# Silicon Iso-Test Runbook

Reliable, repeatable procedures for isolating SAR kernels on silicon, coherent DDR reads,
SmartHLS validation, and the CoreFFT fabric rebuild. Written after a long 2026-07-04 session
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
  `K_RESAMPLE 0x60003000`, `K_FFT`/`fft_feeder 0x60004000`, `fft_unloader 0x60005000`. Regs:
  `START +0x08` (write 1=go, read 0=done), `ARG0 +0xc, ARG1 +0x10, ARG2 +0x14, ARG3 +0x18`.
  **Never read a slave that is not present in the programmed fabric — an unmapped AXI4-Lite read
  hangs the bus un-haltably.** (0x6000_5000 IS present: it is `fft_unloader`, §8.)
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

## 6. Fabric rebuild gotchas (headless Libero) — apply to ANY SAR_TOP rebuild
- **GOTCHA: a leftover `libero.exe` (from a previous program/build) holds a LOCK on the project dir**
  -> a `file delete -force` in the project-creation Tcl fails "permission denied ... SAR_TOP.smat.seg"
  -> the build fails in ~18 s. Fix: `taskkill //F //PID <libero>` FIRST (libero.exe is safe to /F-kill —
  the openocd/gdb no-force-kill rule is ONLY about the FlashPro6 DM, not libero), then re-run the build.
  Check `tasklist | grep libero` is empty before launching a rebuild.
- **Background chains**: launch long chains with the Bash tool's `run_in_background`, NOT a trailing `&`
  in a normal call (the tool waits and times out at 2 min even though `&` detaches — confusing). Append
  a sentinel (`CHAIN_DONE $(date)`) to the log so a Monitor can detect end.
- **`set_root` fails on RE-OPEN of a post-bitstream project** ("Please select a root ... set_root failed").
  A build session's `set_root -module {SAR_TOP::work}` works (fresh hierarchy) but a separate program
  script re-opening the finished project cannot re-select the root. **FIX: program INSIDE the build
  session** — run `run_tool PROGRAMDEVICE` right after export, while the root is still set.
- **FALSE `TIMING_MET` gate**: the gate reads `designer/SAR_TOP/pinslacks.txt`; if the impl got named
  `impl2` (dirty project residue) that file is MISSING → a naive reader leaves `sv=0` → false TIMING_MET
  → bitstream silently not generated. A missing report must force a FAIL. If you see `designer/impl2`
  instead of `designer/SAR_TOP`, the project is dirty → delete the build dir (it is a regeneratable
  artifact) and rebuild clean.
- **Check timing** before trusting any build: `SETUP nviol=0`, `HOLD nviol=0`, `TIMING_MET`, then the
  bitstream marker. (Libero silently programs timing-failing bitstreams — see
  [[always-check-timing-closure]].)
- Prereqs: `LM_LICENSE_FILE=C:\Users\<you>\Documents\github\polarfire-soc\License.dat`;
  `libero.exe` at `C:/Microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin/`. No stale synth (synbatch
  zombies corrupt synth → host reboot clears them).

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
The shipping fabric FFT: the **in-place CoreFFT** hard IP (8192-pt, 16-bit, conditional BFP) in the
streaming chain `fft_feeder -> gearbox -> CoreFFT -> fft_unloader`, selected at runtime by
`SAR_FFTMODE @0xB0059110 = 1` (0 = CPU FFT). Wrapper `mpfs/fpga/corefft_inplace_wrap.v` (elastic LSRAM FIFO + SCALE_EXP)
is sim-validated vs the real core (see memory `corefft-streaming-vs-inplace`). CoreFFT STREAMING
maxes at 4096-pt + no BFP → 8192 REQUIRES in-place.

**Rebuild the CoreFFT bitstream (headless, ~1 hr, timing-gated):** the `libero_sar` SmartDesign is
the deleted-`.cxf` state, so use the VM-netlist flow — `libero.exe SCRIPT:mpfs/fpga/build_corefft_vm.tcl`
(fresh project `libero_corefft_vm`, `-vm_netlist_flow TRUE`, imports the surviving 62.5-MHz
`SAR_TOP_NL.vm`, associates `SAR_TOP_derived_constraints.sdc` (has the 62.5/7.8125 `create_generated_clock`)
+ `sar_fft_cdc.sdc` + `io/sar_io.pdc`, P&R, gate on `pinslacks.txt`, export). Result: **TIMING MET 0/0
(315,348 pins) → `SAR_TOP_corefft.job` (12.12 MB, FABRIC+SNVM)**, written to the project's
`export/` dir (bitstreams are build artifacts and are NOT kept in this repo — rebuild to
regenerate). GOTCHAS: `new_project` rejects `-instantiate_mss_component`
(use the minimal signature); `export_prog_job` needs `file mkdir $exportdir` first; the `.tcl` runs
setup-only first (`STOP_AFTER_SETUP 1`) to fail-fast on API errors before the ~1 hr P&R.

**⚠️ PROGRAM IT RIGHT (the mistake to never repeat):** program the fabric **FABRIC-ONLY**
(`SAR_TOP_corefft.job`, no eNVM), then **re-flash the APP** to eNVM with `bash mpfs/host/run_program.sh`
(`mpfsBootmodeProgrammer` --bootmode 1, via `fpgenprog` — reliable, NOT OpenOCD). **Boot mode 1 + the
APP is the debug state — the app cooperates with JTAG halt.** Do NOT build/flash an **HSS** eNVM
(`build_corefft_bootable.tcl` / boot-mode-1 HSS client): HSS does NOT cooperate with JTAG halt →
`openocd: "Target not halted" / gdb connection rejected`, and you must power-cycle. Re-flashing the
app is REQUIRED after any fabric program that touches eNVM. `mpfs/fpga/bm1/` is run_program.sh's
working dir — `mkdir` it if a cleanup removed it.

**Run the CoreFFT iso-test:** `bash mpfs/host/run_corefft_iso.sh` — generates 8 known 8192-pt rows
(`fft_golden.py`), loads to `SIG`, drives `fft_feeder(0x60004000)→CoreFFT→fft_unloader(0x60005000)`
directly over JTAG (`jtag_full/corefft_iso.gdb.tmpl`), reads back `SCRATCH`, correlates each row vs
the **scale-invariant** BFP golden (CoreFFT's block exponent differs by a power of 2 — corr/nrmse
absorb it, proven in QuestaSim). Uses the §4 pattern: boot (resume, sleep 30, arp_halt), restore
input, `flush_l2_cache(1)` (input→DDR), arm feeder/unloader, `flush_l2_cache(1)` (evict dst), dump.
Offline plumbing self-checks corr=1.0. NOTE: `0x60005000` is the `fft_unloader` — a REAL AXI4-Lite
slave in the shipping fabric (it replaced the removed CoreAXI4DMAController). Host-path GOTCHA:
run_corefft_iso.sh must pass **Windows (`C:/`) paths** to the Windows-native gdb (`restore`/`dump`/ELF)
— MSYS `/c/` paths silently fail "No such file". gdb runs with `-batch </dev/null` so a script error
can't park it at the prompt for 16 min. `CASES=impulse bash run_corefft_iso.sh` runs one row.

**RESOLVED 2026-07-09 — root cause was the GEARBOX, fixed in RTL and validated on silicon.**
The long chronological debug log (feeder-stall hypotheses, SmartDebug rounds, and the several
self-corrections along the way) is archived verbatim in `history/corefft-gearbox-saga.md`.
Summary of what is true now:

- **Root cause:** CoreFFT asserts `DATAO_VALID` ~4 pipeline cycles AFTER `READ_OUTP`
  (`fftSm.v:595-603`). The gearbox (`corefft_stream64_adapter.v`) de-asserted `read_outp`
  combinationally on `fifo_full` AND gated its capture on `read_outp`
  (`... & read_outp & datao_valid`). Under DDR backpressure the in-flight `DATAO_VALID` beats
  were DROPPED — the core counted them, the gearbox did not — causing sample loss plus a re/im
  pairing flip (`have_lo`), so the unloader never reached its beat count and starved (`busy=1`,
  SCRATCH ≈ 0). The CoreFFT UG (in-place, MEMBUF=0) explicitly permits pausing `READ_OUTP`;
  pausing lengthens the cycle, it never truncates. NOT the feeder, NOT the unloader, NOT the
  CoreFFT config (`POINTS=8192`), NOT SLOWCLK, NOT timing.
- **Why simulation missed it:** `corefft_behav.v` asserts `DATAO_VALID` in the SAME cycle as
  `READ_OUTP` (zero latency), so backpressure could never drop an in-flight beat. Catching this
  required a latency-accurate TB driving the REAL core RTL.
- **Fix:** `corefft_stream64_adapter.v` now captures on `datao_valid` REGARDLESS of `read_outp`,
  and de-asserts `read_outp` on `fifo_almost_full = fcount >= FDEPTH - LAT_MARGIN`
  (LAT_MARGIN = 8 beats reserved for the in-flight pipeline).
- **Validation:** `mpfs/fpga/sim/corefft_stream64_lossck_tb.v` (`run_stream64_lossck[_256].do`)
  against the real CoreFFT RTL under heavy backpressure — OLD adapter loses 16 samples @256 pt;
  FIXED adapter loses 0 @256 pt AND 0 of 8192 in the deployed config (read_outp dropped 26,182x,
  FIFO peak 58/64). Then on silicon (`build_gbxfix_ffv.tcl`, TIMING MET 0/0): one-frame iso-test
  **feeder busy=0, unloader busy=0, impulse corr=1.000000 nrmse=0**, then the FULL 8-case
  multi-frame suite ALL PASS (impulse/impulse_k/dc/random corr=1.000000; tone/twotone/
  twotone_hidr/dc_smalltone corr >= 0.99998, incl. both 60 dB dynamic-range cases).
- **Engineering lesson:** verify an IP integration against the User Guide AND the golden testbench
  BEFORE designing the fix, and never trust a behavioural model for a HANDSHAKE-LATENCY property —
  a zero-latency stub hides exactly the class of bug that only shows up under backpressure.
  Full write-up: `openspec/changes/fix-corefft-gearbox-backpressure/`. This class of work is
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
`sext16(u)=(int32_t)((u&0xFFFF)^0x8000)-0x8000` for BOTH hi16/lo16 (symmetric). **Current state: detect
runs on the MSS CPU** — the firmware detect path is the shipping one; the fabric detect kernel remains
unused pending a rebuild.

**HARD-WON gotchas:** never external-`timeout`/SIGTERM a gdb mid-JTAG — it wedged the FABRIC (hart
`reset halt` does NOT reset fabric; a kernel then hung, needed a power-cycle). Run board jobs in the
background so they self-terminate via `monitor shutdown`. This gdb build crashes (`find_inferior_pid`
assertion) on `call flush_l2_cache` if the hart is mid-execution — guard flush/dump behind a done-check.

See also `SAR_PIPELINE_STATUS.md` (status + latency roadmap), `history/SMARTDEBUG_RUNBOOK.md`,
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

## eMMC Milestone-2 / Milestone-3 (provision, boot-load, focus, persist)

Superseded here. The authoritative, more complete procedure is the skill
`.claude/skills/emmc-onboard-pipeline/SKILL.md` — it carries the full mailbox command table,
all four result-record layouts, the measured rates, and the end-to-end command sequence
(provision -> LOAD -> PIPE -> ROI -> SAVEOUT -> VERIFY_OUT). Use it, not a copy here.
The Milestone-1 prerequisites above (MSS `.cxz` regen, fabric SDIO_SW_SEL ties, `-DSAR_EMMC_ENABLE`)
still apply and are documented only here.