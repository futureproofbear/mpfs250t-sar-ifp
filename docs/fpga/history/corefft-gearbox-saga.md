# Archived debugging narrative — CoreFFT gearbox / feeder stall, and the SAR_TOP recovery

This file is an ARCHIVE. Nothing here is a current procedure. It preserves, verbatim, two
chronological debugging narratives that were removed from the live runbooks once their outcome
was settled. They are kept because the self-corrections are instructive: several confident
hypotheses in the text below were later refuted by the next experiment.

- Part 1 — the CoreFFT feeder/gearbox stall (2026-07-08 → 2026-07-09). Conclusion is summarized
  in `docs/fpga/SILICON_ISO_TEST_RUNBOOK.md` §8; read that for what is true today.
- Part 2 — the SAR_TOP SmartDesign deletion incident (2026-06-30 → 2026-07-01). The surviving
  62.5 MHz headless recipe and the lesson stay in `docs/fpga/SAR_TOP_RECOVERY.md`; the incident
  state snapshot and the recovery options below are of historical interest only (recovery
  completed 2026-07-01 and was later superseded by `create_fresh_project_ffv.tcl`).

Read the moved text as a dated log, not as instructions.

---

## Part 1 — CoreFFT feeder / gearbox stall (verbatim, from SILICON_ISO_TEST_RUNBOOK.md §8)

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

---

## Part 2 — SAR_TOP SmartDesign deletion incident (verbatim, from SAR_TOP_RECOVERY.md)

## What happened
While lowering the fabric clock to close timing (125 → 62.5 MHz), the CCC was reconfigured with
`reconfig_ccc_62p5.tcl`, which — modeled on the existing `reconfig_ccc.tcl` — runs
`delete_component SAR_TOP` before regenerating `PF_CCC_C0`. **This deleted the as-built SAR_TOP
SmartDesign.** The CCC regenerated correctly to 62.5/7.8125 MHz, but SAR_TOP could not then be
faithfully rebuilt headless.

**Root issue:** the as-built SAR_TOP was an *iterative* product — `build_sartop.tcl` (a stale
scaffold) plus a chain of rewire/fix steps (`reconnect_dic_330.tcl`, `reconnect_cic_330.tcl`,
`sd_insert_idfix.tcl` = the `sar_id_restore`/idconv ID-width fix) **and manual GUI steps**
(`docs/fpga/history/idconv_gui_steps.md`, `id_restore_integration.md`). The scripts do not cleanly
replay (interconnect port names/counts differ across core versions: `AXI4mmaster*` vs `MASTER*`;
masters actually route through `sar_axi_idconv`). `build_sartop.tcl` alone reconstructs a *different*,
unvalidated topology — attempts failed at the data-plane connections (line 64 → fixed via
`build_design_hierarchy`; then line 68, interconnect master mismatch).

`libero_sar/` was **never committed to git** and there is **no project/SmartDesign backup** on disk
(only a broken 23:28 `SAR_TOP.cxf/.sdb` from the failed re-assembly).

## What SURVIVES (intact)
- `synthesis/SAR_TOP.vm` (mtime 07:12) — the **complete as-built synthesized netlist** (125 MHz).
  CCC is a hierarchical module `PF_CCC_C0_PF_CCC_C0_0_PF_CCC` wrapping `PLL pll_inst_0`.
  PLL: `VCOFREQUENCY=5000`, `DIV0_VAL=0x0A→OUT0 125 MHz`, `DIV1_VAL=0x50→OUT1 15.625 MHz`,
  `DIV3_VAL=0x19→50 MHz`. (OUT = 5000/(DIV_VAL×4).)
- All sub-components: **`PF_CCC_C0` now regenerated to 62.5/7.8125 MHz** (verified SDC ×5÷4, ×5÷32),
  plus AXIDMA_C0, AXIIC_C0, AXIIC_CTRL, ICICLE_MSS, CORERESET_C0, COREFFT_C0, and all 8 HDL+ cores
  (corner_turn/window/detect/resample/fft_feeder + corefft_stream64_adapter + sar_axi_idconv).
- Firmware: untouched. All markdown docs: updated for the timing-closure finding.

## Recovery options (board is OFF — no urgency)
1. **Restore from a backup (BEST, if one exists).** If a copy of the Libero project / SAR_TOP from
   before 2026-06-30 ~23:25 exists anywhere, restore it, then change the clock the *safe* way:
   regenerate `PF_CCC_C0` (already done) and **`sd_update_instance`** the CCC in SAR_TOP (do NOT
   delete SAR_TOP), regenerate SAR_TOP, then `build_timed.tcl`.
2. **GUI reconstruction (faithful, manual).** Rebuild the SAR_TOP SmartDesign in Libero GUI using the
   surviving components (CCC already 62.5 MHz) + the documented steps: `build_sartop.tcl` instantiate/
   clock/reset scaffold → data-plane through `sar_axi_idconv` → `idconv_gui_steps.md` /
   `id_restore_integration.md` → interconnect reconnect. Then `build_timed.tcl` (gated).
3. **Netlist defparam splice (headless, fragile — not recommended unsupervised).** Synthesize the new
   62.5 MHz `PF_CCC_C0` alone, extract its PLL defparams, splice the CCC module body into the surviving
   `synthesis/SAR_TOP.vm`, then run **P&R-only** on the patched netlist → `build_timed.tcl` gate →
   bitstream. Note `DIV1_VAL=160` for 7.8125 MHz overflows the 7-bit divider, so the new CCC uses a
   different VCO/divider arrangement — the splice must take the *full* new defparam set, not a 2-value
   edit. Risk: hand-editing a 19 MB netlist + forcing P&R without source.
