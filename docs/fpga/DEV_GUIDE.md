# Fabric Development Guide — Extending & Debugging the SAR Fabric Design

This document is for someone actively **developing or extending** this fabric design: writing a new
SmartHLS kernel, changing the SmartDesign interconnect, or debugging a silicon issue. It is not:

- **How to operate the finished board** (bring-up, build, program, run, verify, troubleshooting table) —
  that is [`docs/USER_GUIDE.md`](../USER_GUIDE.md).
- **What the processor computes and how it got here** (algorithm, staged Python→fabric port,
  optimization history) — that is [`docs/SAR_GUIDE.md`](../SAR_GUIDE.md).
- **What the system is** (block diagram, memory map, resource usage) — that is
  [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md).

Everything here is a "gotcha or convention that prevents you from re-discovering a bug or mistake this
project already hit." It assumes you've already read the three documents above.

## Table of contents

1. [SmartHLS antipattern catalog](#1-smarthls-antipattern-catalog)
2. [Fabric interconnect integration conventions & lint tooling](#2-fabric-interconnect-integration-conventions--lint-tooling)
3. [Libero / Tcl headless development reference](#3-libero--tcl-headless-development-reference)
   - [3.1 Invoking Libero headless](#31-invoking-libero-headless)
   - [3.2 SmartDesign headless — create + connect](#32-smartdesign-headless--create--connect)
   - [3.3 HDL+ core creation (SmartHLS kernels, custom Verilog cores)](#33-hdl-core-creation-smarthls-kernels-custom-verilog-cores)
   - [3.4 Editing an EXISTING SmartDesign headless — four traps](#34-editing-an-existing-smartdesign-headless--four-traps)
   - [3.5 CoreAXI4Interconnect reconfiguration](#35-coreaxi4interconnect-reconfiguration)
   - [3.6 PolarFire SoC MSS regeneration](#36-polarfire-soc-mss-regeneration)
   - [3.7 Console output & long-run mechanics](#37-console-output--long-run-mechanics)
   - [3.8 Synthesis / P&R / bitstream flow — deeper gotchas](#38-synthesis--pr--bitstream-flow--deeper-gotchas)
   - [3.9 OpenOCD / JTAG register access technique](#39-openocd--jtag-register-access-technique)
   - [3.10 Toolchain instability — recovery checklist](#310-toolchain-instability--recovery-checklist)
   - [3.11 Coherent pipeline debug via GDB (bypassing the mailbox)](#311-coherent-pipeline-debug-via-gdb-bypassing-the-mailbox)
   - [3.12 Script inventory](#312-script-inventory)
4. [Iso-test / debug methodology](#4-iso-test--debug-methodology)
   - [4.1 Verification test menu — what to run, and when](#41-verification-test-menu--what-to-run-and-when)
   - [4.2 DDR + kernel-control map](#42-ddr--kernel-control-map)
   - [4.3 Coherent DDR read pattern (FIC0 is non-coherent)](#43-coherent-ddr-read-pattern-fic0-is-non-coherent)
   - [4.4 Single-kernel isolation pattern — how to write a new iso-test](#44-single-kernel-isolation-pattern--how-to-write-a-new-iso-test)
   - [4.5 SmartHLS validation practices](#45-smarthls-validation-practices)
   - [4.6 Value-level per-stage localization methodology](#46-value-level-per-stage-localization-methodology)
   - [4.7 Phase-sensitive FFT check](#47-phase-sensitive-fft-check)
   - [4.8 JTAG session mechanics specific to iso-tests](#48-jtag-session-mechanics-specific-to-iso-tests)
   - [4.9 Methodology lessons (apply these first)](#49-methodology-lessons-apply-these-first)
5. [Libero SmartDesign editing gotchas (short)](#5-libero-smartdesign-editing-gotchas-short)

---

## 1. SmartHLS antipattern catalog

A living catalog of code shapes and tool behaviours that **SmartHLS 2025.2 on this project has been
proven to mis-synthesise or mis-report** — the institutional memory that keeps "schedule passes, silicon
fails" from being rediscovered every session. It is consumed by
[`mpfs/host/hls_antipattern_lint.py`](../../mpfs/host/hls_antipattern_lint.py) (Gate 0 of the HLS trust
harness — see the `hls-trust-harness` skill for the full gate pipeline).

For the *narrative* of how the first three of these were discovered (FFT twiddle drop, window-fusion
miscompile, detect sign-extension), see `docs/SAR_GUIDE.md` Part 2 "The FFT's own staged journey." What
follows is the durable, actionable guard for each — what code pattern to avoid and what catches it.

**Update discipline:** add or amend an entry the same session you confirm a new mis-synthesis — with the
C trigger, the report-vs-silicon delta, and the guard (CLAUDE.md: "capture and UPDATE runbooks the same
session"). An entry later shown harmless gets its severity lowered and a note, not deleted — the negative
result is itself knowledge.

**Entry format** consumed by the linter — human prose plus an optional machine block:
```
<!-- LINT
id: short-kebab-id
severity: block | warn            # block => linter exits non-zero on a match
files: (informational)
pattern: <python regex>           # OMIT for a manual-review-only entry
message: one-line what/why
-->
```
Only give `severity: block` to a **high-precision** pattern (near-zero false positives). A brittle regex
that blocks the build is worse than the bug it catches; leave uncertain shapes as `warn`, or as a manual
entry (no `pattern:`) so it prints as a review checklist instead of gating.

---

### 1.1 FFT radix-2 butterfly drops the twiddle term `[block-class, manual]`

The `K_FFT` HLS kernel (`hls_fft/hls_fft.hpp` `fft_in_place_bfp`) synthesises to an identity/passthrough
on silicon: the generated RTL **contains** the 1,703 multipliers, but the twiddle product never reaches
the butterfly store. C-sim passes at corr 0.9999 every time; silicon output is `input >> out_shift`.
Proven across three independent FFT structures (ping-pong `DoubleBuffer`, explicit static ping-pong,
single-array in-place).

**Resolution:** the HLS FFT was abandoned; the shipping FFT is the fabric CoreFFT hard-IP streaming chain
(`SAR_FFTMODE` @`0xB0059110` = 1), with the MSS FFT (`src/sar/sar_fft.c`) retained as the mode-0 fallback.

**Guard:** do not re-enable a fabric radix-2 FFT top without a board-free phase-exact cosim (§4.7 below)
proving the twiddle survives.

```
<!-- LINT
id: twiddle-drop
severity: block
files: hls_fft/hls_fft.hpp
message: Fabric radix-2 FFT twiddle drops on silicon (C-sim lies). FFT belongs on the U54 / CoreFFT; prove twiddle survives before re-enabling.
-->
```

### 1.2 `shls cosim` C-testbench wrapper segfaults `[tooling]`

`shls cosim` crashes `0xC0000005` regardless of testbench code, so RTL cosim cannot be used to debug an
HLS mis-synthesis on this install — only silicon rebuilds (~40 min each) can. **Consequence:** don't lean
on cosim as this project's value gate; use the board-free phase-exact complex-ratio check (§4.7) on the
real IP instead. Manual entry — nothing to regex.

```
<!-- LINT
id: cosim-segfault
severity: warn
message: shls cosim wrapper segfaults on this install; use board-free phase-exact check as the value gate, not cosim.
-->
```

### 1.3 Detect stage sign-extension `[manual]`

The fabric detect kernel mis-handled sign in a way schedule/C-sim did not surface; confirmed on silicon
and fixed with a correctly-signed CPU detect A/B (see §4.6). **Guard:** value-test detect on signed
full-scale inputs, not magnitude/correlation.

```
<!-- LINT
id: detect-sign-extension
severity: warn
message: Detect stage mis-handled sign; value-test on signed full-scale inputs, never magnitude only.
-->
```

### 1.4 DDR reads on the II-critical loop path `[warn]`

Reading a top-level `axi_initiator` pointer argument (a DDR fetch) inside the inner, II-critical loop
makes the SmartHLS `II=1/2` schedule fictional: the DDR round-trip serialises the loop to an effective II
~10x worse (the resample `idx[]/wq[]` case). **Fix pattern:** stage the per-output operands into on-chip
LSRAM first, so the II-critical loop only touches on-chip memory — then the report's II becomes true on
silicon (see `resample.cpp` header comment). This is a design-review reminder; the shape is not reliably
regexable line-by-line, so it is manual. Quantify any suspicion with `hls_stats.py eff-ii`.

```
<!-- LINT
id: ddr-read-in-ii-loop
severity: warn
message: A DDR (axi_initiator) read inside the II-critical loop makes the scheduled II a fiction; stage operands into LSRAM first. Measure eff_ii to confirm.
-->
```

### 1.5 `pipeline` pragma without an explicit `II()` `[warn, auto]`

A `#pragma HLS loop pipeline` that omits `II(k)` lets SmartHLS pick the II and then silently degrade it
with no build failure. Always pin `II(k)` so Gate 1 (`hls_report_lint.py`) has a target to check the
achieved II against.

```
<!-- LINT
id: unpinned-pipeline-ii
severity: warn
files: mpfs/fpga/**/*.cpp, *.hpp
pattern: #pragma\s+HLS\s+loop\s+pipeline\s*$
message: `pipeline` pragma with no II() -- pin II(k) so Gate 1 can catch schedule degradation.
-->
```

### 1.6 `memory partition` pragma placed in the function body `[warn, manual]`

Confirmed 2026-07-21 while widening the resample staging loops to full 64-bit AXI beats.

A `#pragma HLS memory partition variable(v) ...` must sit **immediately above the declaration of `v`**.
Placed anywhere else in the function body — e.g. grouped with the other pragmas at the top, which reads
naturally — SmartHLS emits

```
warning: [HLS pragma] ignored: expected a variable after the pragma
```

**drops the pragma, and exits 0.** The build "succeeds" with the partitioning silently absent.

What makes this dangerous is that the failure is partial and can hide itself. Two arrays were partitioned
in the same edit: `wqb` (factor 4) and `idxb` (factor 2). With both pragmas ignored, the `wq` unpack loop
degraded to II=2 — `'@resample_wqb@_local_memory_port' has 4 uses per cycle but only 2 units available` —
while the `idx` loop coincidentally still made II=1 on the LSRAM's two native ports. So half the
regression was invisible, and the half that showed up did so only in the pipelining report, never as an
error.

Nothing upstream catches this: `shls hw` returns 0, no RTL is obviously wrong, and the kernel is
functionally correct — just slower. **Gate 1 (`hls_report_lint.py`) is the only thing that catches it**,
which is the whole argument for running the II gate on every build rather than trusting a clean exit
code.

**Guard:** put each partition pragma directly above its own declaration, include `dim(1)`, and confirm
the achieved II in the pipelining report afterwards. Treat a `[HLS pragma] ignored` warning as a build
failure.

Related: `cyclic` returns zero string hits when grepping the SmartHLS Python/source tree, which makes it
look unsupported. It is supported — the pragma reference is embedded in `clang-15.exe`, which documents
`block|cyclic|complete` with `dim` and `factor`.

```
<!-- LINT
id: partition-pragma-placement
severity: warn
message: `memory partition` must immediately precede the variable's DECLARATION; elsewhere SmartHLS warns "[HLS pragma] ignored", drops it and exits 0. Verify the achieved II in the pipelining report.
-->
```

### 1.7 Outer-loop bound made a RUNTIME argument collapses read overlap `[block-class, manual]`

Confirmed 2026-07-23 on `hls_corner_turn/corner_turn.cpp` while adding strip-transpose support (two new
scalar args `c_base`/`c_count` so the kernel could transpose a range-bin band instead of only the whole
frame, for a corner-turn/FFT overlap design).

The tiled DDR↔DDR transpose has two nested loops: `for (r0=0; r0<CT_H; r0+=CT_T)` outer, then
`for (c0=cb; c0<ce; c0+=CT_T)` — originally `c0<CT_W`, a **compile-time constant**. Changing only the
bound (`ce = c_count==0 ? CT_W : c_base+c_count`, still equal to `CT_W` for the full-frame case) is
enough to regress the kernel **~3.9x on silicon** (6.20 s → 24.36 s, reproducible to within microseconds
across two runs) — with the *inner* pipelined loops still reporting `II=1` in the pipelining report (Gate
1 does not catch this; the degradation is at the outer-loop/tile-boundary level, invisible to the
inner-loop II check).

The FIC_0 monitor (`sar_fic0s_mon`) confirmed the mechanism at the bus level during the CT-alone run:
read-channel **utilization 6.4%** (busy 1.63 s of 25.3 s elapsed, vs a healthy pipelined kernel
near-saturated), AR burst count **exactly 2x** what a clean one-burst-per-row schedule would produce
(every row's read appears to split into two shorter transactions), and a single **MAX_GAP ~5.19 ms**
stall. The write side was *already* single-beat/unbursted in the fast `CT_T=128` build (so that isn't the
delta) — the regression is specific to making the READ-issue loop bound a runtime value, which evidently
costs the scheduler its ability to overlap read-issue of tile N+1 with the write-drain of tile N across
the outer-loop boundary.

**This was caught by silicon A/B, not by any board-free gate** — `shls sw`/`shls hw` both passed,
`hls_gate.sh` passed (II=1 both loops), and the timing gate passed (setup/hold MET) because P&R has no
opinion on AXI transaction scheduling. Only a same-scene A/B against the last known-good bitstream
(mandated by the batch-confidence protocol) surfaced it, and only the FIC_0 monitor localised it to
read-issue overlap rather than a burst-length or write-side regression.

**Guard:** NEVER change an `axi_initiator`-facing loop's bound from a compile-time constant to a
runtime-computed value without an A/B against the constant-bound baseline on the SAME bitstream family,
even when `c_count==0`/full-range makes the two mathematically equivalent. Prefer one of:
(a) keep the loop bound a compile-time constant and gate the tile BODY with a cheap runtime `if`
(untested — may hit the same scheduling loss, verify before relying on it); (b) synthesize N separate
compile-time-bounded kernel instances for a fixed strip count instead of one dynamically-bounded kernel;
(c) the explicit `axi_m_read_req`/`write_req` interface (hand-managed handshake, not schedule-dependent).
Do not ship a dynamically-bounded `axi_initiator` loop kernel on schedule/timing gates alone.

**Resolution confirmed 2026-07-23 — option (a) works.** Rebuilt `corner_turn` with BOTH outer loop bounds
kept as the original compile-time constants (`r0 < CT_H`, `c0 < CT_W` — never a runtime `ce`), gating
only the tile BODY with `if (c0 >= cb && c0 < ce)`. Same board-free gates (II=1, timing MET), but this
time the silicon A/B matched: corner-turn back to 6.20 s, bit-identical output to the pre-strip baseline
— the regression is specific to changing the loop's own trip count, not to a runtime skip condition
guarding an unconditionally-full-trip-count loop. Options (b) and (c) were never needed and remain
untested.

```
<!-- LINT
id: axi-initiator-runtime-loop-bound
severity: warn
message: Making an axi_initiator kernel's outer loop bound a RUNTIME value (even when equal to the old compile-time constant) can collapse read-issue overlap ~4x on silicon while II/timing gates stay green. A/B against the constant-bound baseline before shipping.
-->
```

---

## 2. Fabric interconnect integration conventions & lint tooling

Conventions and tooling that prevent the class of **silent** interconnect-integration failure that cost
the original DMA control-slave bring-up many build cycles — Libero gives no warning for either failure
mode below.

> **Historical note:** the conventions were written against the `CoreAXI4DMAController`'s AXI4-Lite
> control slave. That DMA has since been **removed** from the design — CoreFFT→DDR write-back is now the
> HLS `fft_unloader` + a gearbox output skid FIFO, and the specific "CIC slave-5 = `TARGET5_TYPE=1`"
> example below no longer describes a live component. The conventions themselves (isolate the config
> plane, match target `TYPE` to protocol, use explicit width-mismatch slices, lint-gate every build) are
> general rules and still apply to any future config-plane peripheral.

### Why this exists — two silent failures Libero allowed

1. **Protocol-inference mismatch.** A 32-bit reduced-AXI4-Lite peripheral (the (now-removed)
   `CoreAXI4DMAController`'s `AXI4TargetCtrl`) was attached to the shared 64-bit crossbar with the
   interconnect target left at `TYPE=0` (Full AXI4). The 64→32 down-converter then tried full-AXI4
   (burst/ID) conversion onto a strict single-beat Lite target → `CTRL_ARVALID` never reached the DMA →
   the hart hung un-haltably, with no warning. (SmartDebug proved it: the target FSM stayed IDLE during
   the hung read.)
2. **Asymmetric address grounding.** `sd_connect_pins` of a 32-bit interconnect address to a peripheral's
   11-bit `CTRL_ARADDR` **silently left it tied to `0`** (default const) — no error. Only offset-0 would
   have been reachable; every other register access would have aliased to register 0.

### Convention 1 — isolate the config plane behind an AXI4-Lite firebreak

Do **not** wire AXI4-Lite config/register ports *directly* onto the wide (64-bit, multi-master) data
crossbar. Route config-plane access through a dedicated **AXI4→AXI4-Lite bridge / isolated 32-bit config
sub-bus**. Everything downstream of that bridge is then *structurally guaranteed* single-beat,
ID-stripped, native-width — so the width-DWC and protocol-inference traps **cannot occur**. This is the
cleaner pattern to adopt for any future config peripheral (the shared-CIC-with-explicit-TYPE approach
used for the now-removed DMA control slave worked, but is not the pattern to imitate going forward).

### Convention 2 — set interconnect target TYPE to match the peripheral protocol

`CoreAXI4Interconnect` `TARGETn_TYPE` enum (from `TrgtProtocolConverter.v`): **0=AXI4, 1=AXI4-Lite,
3=AXI3**. A reduced-AXI4-Lite peripheral (no `AxID`/`AxBURST`/`AxPROT`) **must** be `TYPE=1` so the
interconnect inserts the AXI4→AXI4-Lite protocol converter *before* the down-width-converter.

### Convention 3 — wire width-mismatched buses with EXPLICIT slices

`sd_connect_pins` silently leaves a width-mismatched bus disconnected (falls back to the default const
tie). A bare `pin[10:0]` name is **rejected** (`SDCTRL05: Pin '' does not exist`). Correct headless
pattern — create the slice first, then connect it:
```tcl
sd_create_pin_slices -sd_name SAR_TOP -pin_name {CIC:TARGET5_ARADDR} -pin_slices {[10:0]}
sd_connect_pins      -sd_name SAR_TOP -pin_names {"CIC:TARGET5_ARADDR[10:0]" "DMA:CTRL_ARADDR"}
```
See `mpfs/fpga/build_addrfix.tcl` for the full pattern.

### Convention 4 — lint-gate every build (pre-synth firebreak)

Since Libero won't flag either failure above, gate it yourself. Run the linter **after
`generate_component`, before `run_tool SYNTHESIZE`** — a 1-second grep vs a ~30-min synth+P&R:
- **`mpfs/fpga/lint_netlist.sh`** — fails (exit 1) on slave-side address/data tied to const; warns on
  floating AXI pins; audits interconnect target `TYPE`s (flags reduced-Lite-on-`TYPE=0` risk).
- **`mpfs/host/run_build_safe.sh`** — the build wrapper: `[prep.tcl] → lint gate → synth/P&R/program`.
  Use this instead of calling a build script directly so a broken netlist never burns a P&R run.

### Gotchas (cross-cutting)

- Two versions of the same DirectCore can't coexist (module-name collision — both would define e.g.
  `module COREAXI4INTERCONNECT`). If you upgrade one interconnect instance, upgrade **all** instances.
- After any IP reconfigure, refresh the SmartDesign instance headless via
  `sd_update_instance -sd_name SAR_TOP -instance_name <INST>` (equivalent to the GUI's "Update Instance
  with Latest Component") before reconnecting/generating.
- IP version upgrades **reset** the configurator to defaults (e.g. 2 init/2 target) — re-enter the full
  config (counts, per-target addr/width/type, crossbar) and re-run the reconnect script.

---

## 3. Libero / Tcl headless development reference

Hard-won practices for driving **Libero SoC 2025.2**, the PolarFire SoC MSS, on-silicon programming, and
OpenOCD/FlashPro6 JTAG debugging entirely from the command line. `docs/USER_GUIDE.md` §5 already covers
the *canonical current build sequence* — `create_fresh_project_ffv.tcl` → `build_full_prog_ffv.tcl` →
`program_ffv.tcl`, the `TIMING_MET`/`BITSTREAM_DONE` log markers, and the `.smat.seg` permission-denied
fix — none of that is repeated here. What follows is the deeper Tcl-API and headless-flow knowledge
behind that sequence.

> TL;DR of the biggest time-sinks and their fixes:
> 1. **Kill `synbatch.exe` + `c_hdl.exe`, not just `synplify_pro.exe`** — the real synthesis workers. A
>    leftover `synbatch.exe` holds `synwork/` handles and silently corrupts/crashes every subsequent
>    synthesis.
> 2. **Gate on output artifacts (reports/netlist/job files), never on `run_tool` return codes** — Libero
>    frequently reports "Synthesis failed" *after* the mapper already wrote a valid netlist.
> 3. **Re-create ALL HDL+ cores in ONE Libero session** — creating/instantiating cores across separate
>    sessions breaks the links of cores created in an earlier one.
> 4. **Read on-silicon registers with `mem2array`+`echo [format]`, not `mdw`**, in the custom OpenOCD.
> 5. **Changing only a CCC frequency? `sd_update_instance`, NEVER `delete_component SAR_TOP`** (§5).

### 3.1 Invoking Libero headless

```bash
LIBERO="/c/Microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin/libero.exe"
"$LIBERO" "SCRIPT:my_script.tcl"        # console/batch mode; runs the Tcl, then exits
```
- The script itself does `open_project -file .../sar_accel.prjx` … `save_project`.
- **Always `> logfile.txt 2>&1`** and grep the log — the console output is the only feedback.
- Long runs (synth/P&R, ~10–40 min): launch with `nohup "$LIBERO" ... &` and poll, or use a background
  waiter. **Foreground Bash calls cap at 10 min and will *kill* the tool mid-run**, orphaning worker
  processes — always background a long chain (the Bash tool's `run_in_background`, not a trailing `&` in
  a normal foreground call, since the tool still waits for the call to return). Append a sentinel line
  (e.g. `CHAIN_DONE $(date)`) to the log so you can detect completion.
- `libero.exe` is the parent process; it spawns `synbatch.exe`, `c_hdl.exe` (synthesis), place-route
  workers, `pfsoc_mss.exe`. **All must be dead before a clean restart** (§3.10).

Key MPFS toolchain executables (2025.2), under `.../Libero_SoC/Designer/bin[64]/`:

| Tool | Path |
|---|---|
| Libero batch | `bin/libero.exe` |
| MSS Configurator | `bin64/pfsoc_mss.exe` |
| FlashPro CLI (used by `mpfsBootmodeProgrammer`) | `bin64/fpgenprog.exe` |

### 3.2 SmartDesign headless — create + connect

```tcl
set sd SAR_TOP
catch {delete_component -component_name $sd}     ;# safe ONLY if you have a faithful rebuild script
create_smartdesign -sd_name $sd
sd_instantiate_component -sd_name $sd -component_name {ICICLE_MSS} -instance_name {MSS}
sd_instantiate_hdl_core  -sd_name $sd -hdl_core_name {sar_axi_idconv} -instance_name {ID_FIX}
sd_connect_pins -sd_name $sd -pin_names {"DIC:AXI4mtarget0" "ID_FIX:S_AXI"}   ;# interface-level
sd_connect_pins -sd_name $sd -pin_names {"ID_FIX:M_AXI_AWVALID" "MSS:FIC_0_AXI4_S_AWVALID"} ;# signal-level
generate_component -component_name $sd
```
- **Interface-level connect** (a single `sd_connect_pins` naming both bus-interface endpoints) is
  cleanest, but Libero refuses it if the bus-interface *metadata* differs ("not compatible") even when
  the underlying signals match. Fall back to **signal-level** (one `sd_connect_pins` call per signal).
  Both are functionally equivalent — verify by grepping the generated `component/work/SAR_TOP/SAR_TOP.v`:
  the driver net name is shared between the two instance ports (e.g. `.M_AXI_AWVALID(ID_FIX_M_AXI_AWVALID)`
  **and** `.FIC_0_AXI4_S_AWVALID(ID_FIX_M_AXI_AWVALID)` → connected).
- **Always inspect the generated `SAR_TOP.v`, not the synthesized `.vm`**, to confirm wiring — the `.vm`
  is flattened. Instance-port connections in the generated `.v` are ground truth.
- **DRC warnings matter.** `generate_component` "succeeded with warnings" can hide real bugs:
  - `ID width mismatch between X[0-10] and Y[0-8] ... loss of data` → a real truncation (fix the HDL
    width or the interconnect config).
  - `ID width mismatch CIC:AXI4mtarget0 [0-7] vs kernel [0-0]` → harmless (kernel target IDs are 1-bit;
    the interconnect pads).
  - `Floating output pin CCC:OUT2/OUT3` → harmless (unused clock outputs).

### 3.3 HDL+ core creation (SmartHLS kernels, custom Verilog cores)

Create a core *with* AXI bus interfaces headless — the GUI is not required, contrary to older notes:
```tcl
create_links -hdl_source "$here/sar_axi_idconv.v"   ;# link the source FIRST
build_design_hierarchy
create_hdl_core -file "$here/sar_axi_idconv.v" -module {sar_axi_idconv} -library {work}
hdl_core_add_bif -hdl_core_name {sar_axi_idconv} -bif_definition {AXI4:AMBA:AMBA4:slave} -bif_name {S_AXI} -signal_map {}
hdl_core_assign_bif_signal -hdl_core_name {sar_axi_idconv} -bif_name {S_AXI} -bif_signal_name {AWID} -core_signal_name {S_AXI_AWID}
# ... one assign per signal; generate the ~40 assigns programmatically from the .v port list
```
- SmartHLS kernel cores are created by sourcing each kernel's
  `hls_<k>/hls_output/scripts/libero/create_hdl_plus.tcl`. Those call `configure_tool SYNTHESIZE`, which
  needs a **root set first**: `catch { set_root -module {COREFFT_C0::work} }` (any component works).
- **BROKEN-LINK TRAP (important):** re-creating cores across *separate* Libero sessions breaks the
  previously-created cores' internal HDL links → `Error: HDL module '<x>' cannot be found` at generate.
  **Fix: `rm -rf component/User/Private/<core>` for ALL cores, then re-create them ALL in ONE session**
  (see `recreate_all_root.tcl` = `recreate_cores.tcl` + a leading `set_root`).

### 3.4 Editing an EXISTING SmartDesign headless — four traps

All hit 2026-07-21 while editing an already-assembled `SAR_TOP`.

1. **`open_smartdesign` first.** `create_smartdesign` implicitly opens; for a design that already exists
   you must `open_smartdesign -sd_name SAR_TOP` before any edit. Without it every `sd_update_instance` /
   `sd_connect_pins` fails **with an EMPTY error message** (the caught error string is blank, so a
   `catch`-based script cannot tell you why), `sd_instantiate_hdl_core` / `sd_invert_pins` deceptively
   still succeed, and the following `generate_component` **crashes `libero.exe`** on the resulting
   half-wired design. `remove_det.tcl` shows the correct pattern.
2. **Regenerating a sub-component deletes the parent's generated HDL.** After regenerating a sub-IP (e.g.
   an interconnect instance), `component/work/SAR_TOP/SAR_TOP.v` is **removed** and `SAR_TOP.cxf` shrinks
   to a ~1 KB stub. This is *not* damage — the design source `SAR_TOP.sdb` (a zip of `SD_MODEL_DATA`)
   survives intact. Recovery: `open_smartdesign` → `sd_update_instance` on each changed instance →
   `save_smartdesign` → `generate_component`. Skipping `sd_update_instance` gives `Error: Out-of-date
   Instance / Component definition is not consistent for instance DIC` and generate fails. To read the
   true design state when `SAR_TOP.v` is gone, unzip the `.sdb` and grep `SD_MODEL_DATA` for
   `name="<INST>"`.
3. **Broken-link trap, instantiation direction.** §3.3's trap covers cores *created* in an earlier
   session. The inverse also bites: `sd_instantiate_hdl_core` of an HDL+ core in a session where that
   core was **not created** gives the NEW instance a broken link — `Error: Missing Core Definition / HDL
   module 'resample_top' cannot be found` — while existing instances of the very same core stay fine. So
   a second instance of an existing HLS kernel **cannot be added incrementally**; it needs the
   one-session `create_fresh_project_*.tcl` path (all cores created + `SAR_TOP` assembled in a single
   session).
4. **`smartgen/<IP>_work.ixf` is the definition SmartDesign actually reads — not the `.cxf`.** Rolling
   back an interconnect width can regenerate `component/work/<IP>/<IP>.cxf` **and** `<IP>.v` to the new
   (smaller) size while leaving `smartgen/<IP>_work.ixf` **stale at the old size**. Every
   `sd_update_instance` then faithfully re-adds the phantom 7th bus interface (`AXI4mtarget6` /
   `AXI4minitiator6`), and the generated `SAR_TOP.v` ties off ports the regenerated `<IP>.v` no longer
   declares → synthesis `@E: CS168 Port TARGET6_AWREADY does not exist`. Symptoms that identify this
   exactly: the `.cxf` says `NUM_TARGETS=6`, `<IP>.v`'s module port list stops at `TARGET5_*`, the `.sdb`
   contains **zero** `TARGET6` strings — and `SAR_TOP.v` *still* comes back with the tie-offs after
   `sd_update_instance`. Restoring a clean `.sdb` does **not** help (the phantom is re-added from the
   `.ixf`, not carried in the `.sdb`).
   **Fix:** `delete_component` + `create_and_configure_core` + `generate_component` on BOTH interconnects
   (that is what rewrites the `.ixf`), then `sd_update_instance`. Gate on the `.ixf`, not the `.cxf`:
   ```tcl
   if {[string first "AXI4mtarget6" $ixf_text] >= 0} { error "stale .ixf" }
   ```
   Then gate the result: `SAR_TOP.v` must contain **zero** `TARGET6`/`INITIATOR6` matches.

### 3.5 CoreAXI4Interconnect reconfiguration

`generate_component` alone can emit **stale HDL** (e.g. config says `NUM_TARGETS=6` but only 5 target
interfaces appear). Force a full reconfigure — extract every
`<configurableElement referenceId="X" value="Y"/>` from `component/work/<IC>/<IC>.cxf` into a
backslash-continued param list, then:
```tcl
create_and_configure_core -core_vlnv {Actel:DirectCore:COREAXI4INTERCONNECT:3.0.130} -params $P
generate_component -component_name {AXIIC_CTRL}
```
- AXI4-**Lite** interconnect targets are named `AXI4Lmtarget<n>` (with an **L**); full-AXI are
  `AXI4mtarget<n>` / `AXI4minitiator<n>`.
- Target address decode lives in `TARGET<n>_START_ADDR/END_ADDR` (+`_UPPER`). With `NUM_TARGETS=1`, extra
  `TARGET1..n` ranges in the `.cxf` are ignored defaults.

**Reconfiguring an interconnect that ALREADY exists** — `create_and_configure_core` **refuses** to touch
an existing component: `Error: The core AXIIC_C0 cannot be created because the folder
...\component\work\AXIIC_C0 already exists.` The following `generate_component` then happily regenerates
the **old** config and reports success — so the reconfigure is a **silent no-op that looks like it
worked**. Delete the sub-component first (this is safe — unlike `delete_component SAR_TOP`, §5):
```tcl
delete_component -component_name {AXIIC_C0}
create_and_configure_core -core_vlnv {...} -component_name {AXIIC_C0} -params $P
generate_component -component_name {AXIIC_C0}
```
Always gate on the regenerated `.cxf`, never on the return code:
```tcl
regexp {referenceId="NUM_INITIATORS" value="([0-9]+)"} $cxf_text -> got
```

### 3.6 PolarFire SoC MSS regeneration

The MSS is imported from a **`.cxz`** archive (a zip of `ICICLE_MSS.v`, `.cfg`, `_mss_cfg.xml`, `.cxf`,
and a `MSS_<FIC0>_<FIC1>_<FIC2>_<FIC3>_<FIC4>_syn_comps.v` whose **filename encodes DLL bypass per FIC**:
`NOBYP`=DLL used, `BYP`=bypassed):
```tcl
catch {delete_component -component_name SAR_TOP}    ;# SAR_TOP instantiates the MSS
catch {delete_component -component_name ICICLE_MSS}
import_mss_component -file "$here/mss_nodll/out/ICICLE_MSS.cxz"
build_design_hierarchy
```

**Reconfigure the MSS headless** (e.g. bypass FIC DLLs) via `pfsoc_mss.exe`. Editing the `.cfg` inside the
`.cxz` is **not enough** — the generated HDL + `syn_comps` must match. Regenerate the whole component:
```bash
PFSOC=".../Designer/bin64/pfsoc_mss.exe"
sed 's/\(FIC_[012]_EMBEDDED_DLL_USED[[:space:]]*\)true/\1false/' in.cfg > out/ICICLE_MSS.cfg
"$PFSOC" -GENERATE -CONFIGURATION_FILE:<win\path\ICICLE_MSS.cfg> -OUTPUT_DIR:<win\path\out> -EXPORT_HDL:true -LOGFILE:<log>
# verify: the new syn_comps filename reflects the change, e.g. MSS_BYP_BYP_BYP_BYP_BYP_syn_comps.v
```
- After regenerating, re-import the `.cxz` then re-create cores + rebuild `SAR_TOP`.
- **`import_mss_component` uses the pre-generated HDL inside the `.cxz`** — it does NOT re-synthesize
  from the `.cfg`. So the `.cxz` must already contain the correct HDL (that's what `pfsoc_mss` does).
- **Stale-`syn_comps` trap:** old `mss_*_syn_comps.v` left in `component/work/ICICLE_MSS/` (or copies at
  `component/MSS_syn_comps.v`, `component/syn_comps.v` referenced by the Synplify `.prj`) get pulled into
  synthesis → duplicate/conflicting MSS modules → intermittent synth failure + a netlist whose
  `// file …` comments reference *multiple* DLL configs. Ensure only the intended one remains.

**FIC usage / DDR access (this design):**

| FIC | Direction | Role |
|---|---|---|
| `FIC_0`/`FIC_1` | MSS-master → fabric-slave | Control plane (`AXIIC_CTRL` hangs off `FIC_0` initiator). |
| `FIC_2` | fabric-master → MSS-slave | The *textbook* high-bandwidth data plane to DDR. |
| `FIC_3` | MSS-master → fabric APB | Low-bandwidth control. |

This design deliberately used `FIC_0_AXI4_S` (target) for the data plane instead, with `FIC_2` tied off —
verify in the netlist: `FIC_0_AXI4_S_AWVALID(DIC_AXI4mtarget0_AWVALID)` vs `FIC_2_AXI4_S_AWVALID(GND)`.

**FIC embedded DLLs only lock within a frequency band.** Dropping the fabric clock below it (e.g. a
125→62.5 MHz change for timing closure) leaves an *enabled* FIC DLL **unlocked**, which breaks that FIC's
data path while low-rate control still limps through. Fix = **bypass** the DLL
(`..._DLL_USED false`) — at low clocks the ns-scale insertion delay is negligible. Confirm on silicon via
`DLL_STATUS_SR` (§3.9): enabled-but-unlocked reads bit=0; bypassed/disabled reads bit=1.

### 3.7 Console output & long-run mechanics

`libero.exe` console output is lost on exit: redirected stdout is buffered and gets **truncated
mid-line** when the process exits, so `puts` markers vanish exactly when you need them. Append every
marker to a file with an explicit flush instead:
```tcl
proc mark {msg} { global MARKS; puts $msg; set f [open $MARKS a]; puts $f $msg; flush $f; close $f }
```
Also: a detached launcher returning **does not** mean Libero finished — poll `tasklist | grep -i libero`
alongside the marks file. `build_design_hierarchy` on this design takes ~10 min on its own.

### 3.8 Synthesis / P&R / bitstream flow — deeper gotchas

Beyond the canonical `create_fresh_project_ffv.tcl` → `build_full_prog_ffv.tcl` sequence and its
`TIMING_MET`/`.smat.seg` handling (`docs/USER_GUIDE.md` §5.1):

- **The timing gate can pass on STALE reports.** The gate reads `pinslacks.txt` + the multi-corner
  violation XMLs off disk. If a *previous* successful run left them there and this run's P&R/VERIFYTIMING
  dies early, the gate re-validates the OLD reports and exports a bitstream that was never timed.
  Existence + content checks are not enough. **Fix:** at the top of the build script, capture
  `set RUN_START [clock seconds]`, **delete** all four artifacts (`pinslacks.txt`,
  `SAR_TOP_mindelay_repair_report.rpt`, `SAR_TOP_{max,min}_timing_violations_multi_corner.xml`), and in
  the gate require each one to exist AND have `[file mtime $f] >= $RUN_START-2`. This is implemented as
  `proc fresh {f}` in `build_pack_ffv.tcl`, which prints `PURGED_STALE:` / `FRESH_OK:` lines so the log
  itself proves the reports belong to this run.
- **`derive_constraints` is NOT a valid Tcl command.** Supply a pre-made SDC and overwrite
  `constraint/SAR_TOP_derived_constraints.sdc` so the flow picks it up.
- **Async CCC outputs need an explicit false-path.** Two clock outputs of the same CCC driven at
  different frequencies (e.g. CoreFFT's `CLK`↔`SLOWCLK` when `SLOWCLK = CLK/8`) are asynchronous to each
  other and need `set_false_path` in both directions between the CCC's outputs (see `sar_fft_cdc.sdc`),
  else the timing report shows a phantom hold violation.
- **Bootable bitstream needs the MSS design-init.** `GENERATEPROGRAMMINGDATA` must run after a valid MSS
  import; without it only ~62.5% of I/Os place and the job is not bootable.
- **Forcing a re-synth:** delete `synthesis/SAR_TOP.vm` — BUT a bare `run_tool PLACEROUTE` will then
  error `Unable to find SAR_TOP.vm` if synth doesn't auto-run. Prefer the single-session flow with an
  explicit `run_tool SYNTHESIZE` first.
- **VM-netlist flow (bypasses Synplify entirely)** — a recovery path for when Synplify is wedged. A
  separate project with `project_settings -vm_netlist_flow TRUE` + `import_files -verilog_netlist {X.vm}`
  (extension MUST be `.vm`; root auto-sets). Run `COMPILE → PLACEROUTE → VERIFYTIMING` (no `SYNTHESIZE`)
  — feed it an already-good `.vm`. The existing SmartDesign project refuses a netlist root, so use a
  dedicated project. Rename the netlist top to a distinct name
  (`sed 's/^module SAR_TOP (/module SAR_TOP_NL (/'`) to match that project's root.
- **`set_root` fails on RE-OPEN of a post-bitstream project** ("Please select a root ... set_root
  failed"). A build session's `set_root -module {SAR_TOP::work}` works against a fresh hierarchy, but a
  separate program script re-opening the finished project cannot re-select the root. **Fix: program
  INSIDE the build session** — run `run_tool PROGRAMDEVICE` right after export, while the root is still
  set.
- **Spurious "Synthesis failed":** `run_tool SYNTHESIZE` often prints `Error: Synthesis failed` /
  `Starting Synplify Pro ME... Error` *even though* `synlog/SAR_TOP_fpga_mapper.srr` says `Mapper
  successful!` and a valid `synthesis/SAR_TOP.vm` (~18 MB) was written. Trust the artifacts, not the
  return code — run the whole flow in ONE session with `catch` around each `run_tool` and gate on the
  actual outputs.

**Programming:** `run_tool -name {PROGRAMDEVICE}` programs Fabric+sNVM+eNVM directly via FlashPro6. Only
one tool can own the FlashPro6 at a time — kill OpenOCD before Libero `PROGRAMDEVICE`, and vice versa
(this rule and the app-reflash-after-fabric-program requirement are covered operationally in
`docs/USER_GUIDE.md` §5.3 — not repeated here).

### 3.9 OpenOCD / JTAG register access technique

Custom OpenOCD build (the stock SoftConsole one lacks this board's cfg):
```bash
NEW="/c/Users/<you>/Tools/openocd-new/xpack-openocd-0.12.0-4"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f efp6_<test>.cfg
```

**Reads: use `mem2array` + `echo [format]`, NOT `mdw`.** `mdw` produced no output in this OpenOCD build;
`mem2array` works:
```tcl
mem2array v 32 0x60004008 1
echo [format ">>> fft_feeder START/busy = 0x%08x" $v(0)]
mem2array r 32 0xB0050000 200          ;# bulk read (200 words); parse in a Tcl loop
```
Reading fabric control regs (`0x6000_n000`) works via the MSS→FIC0 path (control plane). The custom
OpenOCD/FlashPro6 link is **latency-bound (~84 kbit/s)** — keep JTAG bursts short.

**Writes + the coherency trap.** `mww <addr> <val>` writes, but a **bare sysbus `mww` to cached DDR is
NOT coherent** with a running hart's view — firmware polling a cached mailbox won't see it. The firmware
expects the mailbox written via the **hart's debug view** (GDB / verified progbuf) — see §3.11. For
fabric registers (non-cached, via FIC) `mww` is fine.

Writing an internal descriptor then reading it back **immediately** vs **after a delay** disambiguates
"never triggered" (bits stay unset) from "started then hung" (bits set then cleared by hardware).

**Useful on-silicon registers (MPFS):**

| What | Addr | Notes |
|---|---|---|
| SYSREG base | `0x20002000` | `BASE32_ADDR_MSS_SYSREG` |
| `DLL_STATUS_SR` | `0x2000215C` | FIC0_LOCK=b0, FIC1=b1, FIC2=b2, FIC3=b4, FIC4=b5; UNLOCK sticky at b8+. **1=locked/bypassed-ready, 0=enabled-but-not-locked (BUG).** |
| `PLL_STATUS_SR` | `0x2000214C` | CPU/DFI/SGMII lock bits (sanity: MSS PLL up). |
| Fabric kernel ctrl | `0x6000_n000` | CT/WIN/DET/RES/FEED @ n=0..4; `fft_unloader` @ `0x60005000`. |

The board only halts for JTAG in **boot mode 0** (WFI) unless the app cooperates; otherwise use the
firmware mailbox to trigger tests and read results from DDR.

### 3.10 Toolchain instability — recovery checklist

Repeated synthesis crashes / `Device or resource busy` on `synwork/` are almost always **leftover worker
processes**, not your design.
```bash
# Kill EVERY worker (the usual suspects PLUS the ones people miss):
for p in libero.exe synbatch.exe c_hdl.exe synplify.exe synplify_pro.exe acttclsh.exe \
         designer.exe pfsoc_mss.exe; do taskkill //F //IM "$p" 2>/dev/null; done
# synbatch.exe + c_hdl.exe are the REAL Synplify workers and hold synwork handles.
sleep 10
tasklist | grep -iE "synbatch|c_hdl|libero|synplify"   # must be empty
rm -rf libero_sar/synthesis/synwork                    # must succeed cleanly
```
- If `synwork` is *still* busy after killing everything, a handle is pending-release (or AV is scanning)
  — wait longer, or restart the environment/Libero. Do NOT launch a new synth over a busy `synwork` (it
  inherits the corruption).
- No PowerShell / `wmic` on this host (GPO-blocked): use `tasklist` + `systeminfo` for process/memory.
- Memory is rarely the cause (synth peaks ~630 MB; check `systeminfo | grep "Available Physical"`).
- Prereqs: `LM_LICENSE_FILE` must point at the license file (see `config.local.yaml`); no stale synth —
  `synbatch` zombies corrupt synthesis and, in the worst case, only a host reboot clears them.

### 3.11 Coherent pipeline debug via GDB (bypassing the mailbox)

The firmware mailbox (written via a bare `mww`) has the cache-coherency gap described in §3.9. The clean
alternative for driving the pipeline over JTAG during development is to **call the sequencer directly on
the hart via GDB** — coherent, no mailbox:
```
# launch OpenOCD server (background) + GDB with a flow script
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2                              # select U54_1
source load_geom.gdb                  # restore geometry/JOB to DDR (skip the 93 MB SIG if only testing control flow)
p (int)sar_form_image(0)              # runs the WHOLE pipeline on the hart; returns sar_seq_status_t
printf ">>> RETURN=%d\n", (int)$      # 0=OK, else failing stage (2 RESAMPLE..8 DMA)
```
- `sar_form_image(0)` uses `SAR_DEFAULT_SPINS = 0x40000000` (bounded, ~5 min per stalled stage). A
  **smaller** `spin_limit` can FALSE-timeout the last resample pulse (it skips the double-buffered coeff
  precompute so its `k_wait` doesn't overlap the kernel) — don't mistake that for a hang.
- The 93 MB SIG loads at the ~84 kbit/s JTAG ceiling = ~2.5 hr; for control-flow/stall diagnosis skip it
  (garbage in the SIG region is still valid DDR — the data-plane read/write path is exercised either
  way).

**Progress/state instrumentation** — see WHERE the pipeline is, not just that it stalled. Add a few DDR
writes to a free address, then poll/read them **halted** (halted JTAG reads are coherent):
```c
#define SAR_PROG_ADDR 0xB0059100u     /* free DDR (past stream desc @0xB0059000) */
/* in the hot loop, before each kernel start: */
volatile uint32_t *pg = (uint32_t*)SAR_PROG_ADDR; pg[0]=pass; pg[1]=idx; pg[2]=total; pg[3]++;
```
After a bounded run returns, the address holds the exact stalled index → distinguishes "hung at item 0"
from "advanced then stalled" from "false-timeout at the last item." This is what proved the resample runs
all 13,826 lines (not hung) and localized a stall to the FFT stage.

**SmartHLS kernel re-synth** (for a fabric-side kernel change): kernel C++ (e.g.
`hls_resample/resample.cpp`) → re-run SmartHLS (`hls_resample/Makefile` + `config.tcl`) → new RTL →
re-create the HDL+ core (§3.3) → rebuild `SAR_TOP` → P&R → reprogram. Kernel perf tip: a random **gather**
(`in[idx[i]]`) can't burst even with `max_burst_len` — pull the line into a local `static` array with one
sequential (burstable) read, then gather on-chip.

### 3.12 Script inventory

Key scripts in `mpfs/fpga/` — verified present as of 2026-07-20 (older notes referenced several scripts
that no longer exist). `create_fresh_project_ffv.tcl` / `build_full_prog_ffv.tcl` / `program_ffv.tcl` are
the shipping entrypoint and are already documented operationally in `docs/USER_GUIDE.md` §5.

| Script | Purpose |
|---|---|
| `create_fresh_project_ffv.tcl` | Create a clean Libero project + all IP/MSS/HDL+ cores, with the hand-written Verilog feeder (sources `feeder_v_core.tcl`) instead of the SmartHLS one. The current `SAR_TOP` starting point. |
| `create_fresh_project.tcl` | Same, but with the SmartHLS feeder (the `libero_tdest` variant). |
| `sartop_assembly.tcl` | The `SAR_TOP` SmartDesign assembly (instantiate + connect + interconnect wiring). |
| `feeder_v_core.tcl` | Register `fft_feeder_top`/`fft_feeder_v` as an HDL+ core with the same bus interfaces the SmartHLS core had. |
| `gearbox_idconv_cores.tcl` | Register `corefft_stream64_adapter` + `sar_axi_idconv` as HDL+ cores (the `create_hdl_core`/`add_bif` pattern of §3.3). |
| `build_full_prog_ffv.tcl` | Single-session SYNTH → P&R → VERIFYTIMING → report gate → export, for the ffv project. |
| `build_gbxfix_ffv.tcl` | Same flow, rebuilding with the fixed gearbox (linked HDL source). |
| `build_scaleexp_ffv.tcl` / `build_full_prog_fresh.tcl` | Sibling gated build flows (SCALE_EXP variant / `libero_tdest`). |
| `build_corefft_vm.tcl` | VM-netlist recovery flow (§3.8) — see also §5. |
| `build_timed.tcl` | Build with a HARD timing gate (parses `pinslacks.txt`, aborts before bitstream). |
| `build_corefft_bootable.tcl` | Adds the HSS eNVM boot client + exports a bootable job. **Deployment only** — HSS does not cooperate with JTAG halt. |
| `finish_export.tcl` | Re-run only `export_prog_job` when a finished build failed solely on a missing export dir. |
| `stage_constraints_tdest.tcl` / `reconstrain.tcl` | Import the hand-written constraints and (re)generate the top-level derived SDC. |
| `PF_CCC_C0_62p5.tcl` | Regenerate the CCC at 62.5 / 7.8125 MHz (historical — superseded by the 100 MHz build; the regenerate-in-place pattern it demonstrates is still the template for any future CCC change, §5). |
| `program_ffv.tcl` / `program_tdest.tcl` | `run_tool PROGRAMDEVICE` on an already-built project (FlashPro6). |
| `run_hlsfft_build.sh` / `create_fresh_project_hlsfft.tcl` / `build_full_prog_hlsfft.tcl` / `sartop_assembly_hlsfft.tcl` / `program_hlsfft.tcl` / `stage_constraints_hlsfft.tcl` | The abandoned HLS-FFT variant of the flow. Retained as scripts only; the shipping FFT is the fabric CoreFFT chain (§1.1). |
| `hls_gate.sh` / `lint_netlist.sh` / `trim_mss.py` | SmartHLS output gate, netlist lint (§2), MSS trim helper. |
| `mpfs/host/run_program.sh` | Flash app ELF via `mpfsBootmodeProgrammer` (boot mode 1). |
| `efp6_*.cfg` | OpenOCD JTAG test/probe scripts (M2 dump, rate tests, DLL status, ctrl reads). |

---

## 4. Iso-test / debug methodology

Reliable, repeatable procedures for isolating SAR kernels on silicon, coherent DDR reads, SmartHLS
validation, and per-stage debug localization. `docs/USER_GUIDE.md` §3.3/§7/§8 already covers the JTAG
clock ceiling, never-kill-mid-transfer rule, single-FlashPro6-owner rule, and the operator troubleshooting
table — not repeated here. This section is technique/reference for isolating and debugging a fabric
kernel path, not a copy of that operational material.

### 4.1 Verification test menu — what to run, and when

Pick the narrowest test that covers the change. Board-free first; escalate to silicon only when needed.
**After ANY fabric rebuild, re-verify by VALUE (correlation), not just RETURN=0 — SmartHLS schedule ≠
silicon behaviour.**

**Board-free (no JTAG; run first):**
- **Bit-accurate emulator** — `python silicon_emulator.py` — mirrors the whole fixed-point datapath end
  to end; equals the float golden (corr 1.0). The reference for isolating a hardware bug (diff board vs
  this).
- **SmartHLS cosim + schedule** — `shls sw` (kernel `main()` self-test, numeric PASS) then `shls hw`
  (per-loop II report). Run BEFORE committing to a bitstream build. See §4.5.
- **Phase-sensitive FFT** — `python corefft_phase_compare.py [N]` — catches conjugation / sign / bin-order
  errors that magnitude correlation cannot. See §4.7.
- **Model-on-real-scene** — `real_board_scene_test.py` / `real_data_model_test.py` — CPU-vs-fabric BFP
  model on the actual board scene (distinguishes an algorithm-sound-but-implementation-bug case).

**On silicon (JTAG; observe `docs/USER_GUIDE.md` §3.3 hygiene, plus §4.8 below):**
- **Full pipeline (acceptance)** — `bash run_pipe_small.sh` → expect **RETURN=0**; then dump the OUT band
  (`run_dump_bright.sh`) and correlate all 8 dihedral orientations vs golden (`compare_out_band.py`),
  expect **corr ≈ 0.99** in `transpose+rot180` (the `T.rot180` orientation the golden spec allows).
- **CoreFFT 8-case iso-test** — `bash run_corefft_iso.sh` — isolates the fabric FFT chain with 8 known
  8192-pt rows: **impulse / impulse_k / dc / random / tone / twotone / twotone_hidr / dc_smalltone**
  (impulse-family corr=1.0, tone-family corr≥0.99998, incl. two 60 dB dynamic-range cases). Use this to
  debug the FFT chain, or to re-prove the FFT survived a whole-`SAR_TOP` P&R even when only another
  kernel changed. `CASES=impulse bash run_corefft_iso.sh` runs one row as a fast smoke test (full suite ≈
  16 min).
- **Single-kernel iso-tests** — poke one kernel, read DDR back (§4.4): `resample_iso.gdb` (const-1000
  identity gather → `SCRATCH[0]=0x03e80000`), `detect_iso.gdb`, `fft_iso_test.gdb`.
- **Timing attribution** — the resample mcycle counters at `0xB0059120` (`run_read_prof.sh`) split the
  azimuth pass into coeff-compute / kernel-wait / flush (numerically inert; strip before shipping).

### 4.2 DDR + kernel-control map

| Buffer | Addr | Notes |
|---|---|---|
| SIG | `0x88000000` | scene / ping-pong. row R = `0x88000000 + R*0x8000` (8192 cplx u32) |
| SCRATCH | `0x98000000` | intermediate. row R = `0x98000000 + R*0x8000` |
| OUT | `0xA8000000` | uint16 magnitude image. row R = `0xA8000000 + R*0x4000` |
| TABLES | `0xB0000000` | geometry/coeffs/mailbox (CPU-read, cacheability per MPU) |
| COEF_IDX(0)/WQ(0) | `0xB0148000` / `0xB0158000` | int32[Np] / int16[Np] |
| mailbox | `0xB0058000` | +0 cmd, +4 base, +8 len, +C result, +10 status, +14 seq |
| SAR_PROG | `0xB0059100` | +0 pass, +4 idx, +8 total, +C heartbeat |

- **DDR is `0x80000000`–`0xBFFFFFFF` only. `≥0xC0000000` = ABOVE-DDR decode error** (not a cached/
  non-cached alias — cacheability is MPU-config, not address-aliased). Don't read `0xC8…`/`0xE8…`.
- Kernel control: `K_CORNER_TURN 0x60000000`, `K_WINDOW 0x60001000`, `K_DETECT 0x60002000`,
  `K_RESAMPLE 0x60003000`, `K_FFT`/`fft_feeder 0x60004000`, `fft_unloader 0x60005000`. Regs:
  `START +0x08` (write 1=go, read 0=done), `ARG0 +0xc, ARG1 +0x10, ARG2 +0x14, ARG3 +0x18`. **Never read
  a slave that is not present in the programmed fabric — an unmapped AXI4-Lite read hangs the bus
  un-haltably.**
- Kernel arg contracts: `detect(in,out)` no count (DN=8192²); `resample(in,idx,wq,out)`;
  `window(in,hamr,hamc,out)`; `corner_turn(src,dst)`; `fft_kernel(src,dst,nrows)`.

### 4.3 Coherent DDR read pattern (FIC0 is non-coherent)

The fabric kernels read/write DDR via FIC0; the hart/gdb see L2. To read what a kernel actually wrote:
- **`call (void) flush_l2_cache(1)` from gdb** — evicts L2, so a subsequent *cached* read fetches
  physical DDR. (Also the way to push a gdb-loaded input to DDR before arming a kernel.) Verified: load
  pattern → CRC(L2)=pattern → call flush → CRC(post-evict)=pattern ⇒ flush delivers to DDR.
- Mid-pipeline, SIG/SCRATCH data rows are **uncached** (kernels write via FIC0, the hart never caches
  them; per-line resample flushes keep L2 cold) → a direct read already hits DDR. But `call flush`
  mid-run can perturb the sequencer (an observed restart) — read directly when possible instead.
- **CRC localization**: mailbox CRC32 (cmd `0x43524333`, zlib-compatible) over 16 MB of SIG/SCRATCH/OUT
  after a PIPE run (post-flush → DDR) pinpoints where data survives vs zeros. zero-CRC(16 MB) =
  `0xa47ca14a`.
- **Gotcha**: resampled k-space cols 0–4 are legitimate **edge zero-fill** (the first ~12 KC-grid points
  fall out of range → `idx=-1`). Read **col 5+** to see real data. A truncated `x/8xw` (first line only)
  nearly mis-blamed pass-2/window when the FFT was the actual culprit.

### 4.4 Single-kernel isolation pattern — how to write a new iso-test

The workhorse pattern behind `jtag_full/{detect,fft,resample}_iso*.gdb` + `run_*.sh`:
1. `monitor reset halt` + boot (`resume`, sleep 28–30 s, `arp_halt`, `thread 2`).
2. `restore <pattern>.bin binary <SIG>` (e.g. `fft_test_row.bin` = const `re=1000`).
3. Pre-clear the destination's first words (so a stale value can't fool you).
4. `call (void) flush_l2_cache(1)` (pushes the gdb-loaded input → DDR).
5. Arm the kernel (set `ARG` regs + `START=1`), `resume`, sleep, `arp_halt`, read `START` (0=done).
6. `call (void) flush_l2_cache(1)` (evict dst), read dst.

**Known-good expectations** (const `re=1000` = `0x03e80000`): detect → `0x03e803e8` (mag 1000); resample
identity coeffs → `0x03e80000` (passthrough); **FFT → DC delta `~0x7D000000` (32000 = 8192·1000>>8), NOT
flat `0x00030000`** (flat = a broken passthrough).

### 4.5 SmartHLS validation practices

- **vsim** is at `C:/Microchip/Libero_SoC_2025.2/Libero_SoC/QuestaSim_Pro/win64/` — **add to PATH** (the
  `shls` setup script wrongly points to `ModelSim_Pro`). `command -v vsim` must resolve first.
- `shls cosim` (RTL vs C) currently **segfaults** in its C-testbench wrapper (`0xC0000005`) — a tooling
  bug, not a design bug (`shls sw` runs clean); see catalog entry §1.2. `shls sim` needs a custom Verilog
  TB instead.
- **C-logic validation** (does the fix compute right): `shls sw` + `python tb/gen_and_check.py gen <case>`
  / `check <case>` (cases: `tone`/`twotone`/`pointtarget`/`random`). `tone` → corr≈1.0, peak bin 137.
  **sw-sim passing does NOT prove the RTL** (the broken FFT — catalog §1.1 — also passed sw-sim). RTL
  truth requires silicon.
- Regen RTL from a fixed HLS kernel: `shls hw` (produces `hls_output/rtl/*.v` +
  `scripts/libero/create_hdl_plus.tcl`).

### 4.6 Value-level per-stage localization methodology

**Why:** correlation is scale/phase-invariant, and can be actively misleading (a saturated output can
read as corr ≈ −1, an artifact, not a signal). To localize a pipeline fault, compare COMPLEX SAMPLE
VALUES per stage against a bit-accurate model / the CPU path, not a scalar correlation. This is the
methodology that found the real detect sign-extension bug (catalog §1.3) after several false leads; see
also the `sar-verification-methodology` skill for the general philosophy.

**Method + tooling (all in `mpfs/host`):**
- Inject a KNOWN input at a stage boundary: e.g. `gen_fft_value_input.py` → `inject_fft_value.gdb`
  (`'FTES'` mailbox = `sar_fft_pass_test`, runs `fft_pass` on pre-loaded SIG, no slow zeroing) →
  `fft_value_compare.py`.
- Per-stage magnitude trace: `flow_pipe_trace_run.gdb` dumps SCRATCH (range/corner-turn), SIG (azimuth),
  OUT (detect); analyze with `trace_stage_analyze.py`. **Caution: complex buffers are 4 B/px, OUT is
  2 B/px — the same byte offset is a DIFFERENT row.** SIG rows R = `0x88000000 + R*8192*4`; OUT rows R =
  `0xA8000000 + R*8192*2`.
- Same-row SIG-vs-OUT peek (`peek_sig_out.gdb`, `x/`) can reveal a bit-level pattern directly (e.g.
  `OUT=|SIG|` where `I≥0` but `OUT=0xFFFF` where `I<0` is the signature of a sign-extension bug).
- **Isolation technique that removes golden-orientation doubt:** compare the mode-0 CPU-FFT SIG output vs
  the mode-1 fabric-FFT SIG output at the same band (`flow_pipe_mode0_sig.gdb` +
  `compare_mode0_mode1_sig.py`). If they match near-exactly, the FFT stage is cleared and the fault is
  downstream — this sidesteps the orientation-search step entirely for a stage-vs-stage A/B.

**Hard-won gotchas discovered doing this:**
- Never external-`timeout`/SIGTERM a gdb session mid-JTAG — it can wedge the fabric itself (`reset halt`
  resets the hart, not the fabric; a kernel left mid-run then stays hung, requiring a board power-cycle).
  Run board jobs in the background so they self-terminate via `monitor shutdown`.
- This gdb build crashes (`find_inferior_pid` assertion) on `call flush_l2_cache` if the hart is
  mid-execution — guard any flush/dump behind a done-check first.

### 4.7 Phase-sensitive FFT check

**Why:** a magnitude-only iso-test (§4.1) passes even if the FFT were conjugated, bin-reversed, or
per-bin phase-rotated, since magnitude correlation is scale- AND phase-invariant. To rule a phase/sign
fault in or out without the board, compare the FFT's **complex** output to the exact float FFT.

**Method (board-free, ~35 min):**
1. `mpfs/host/gen_phase_input.py [N]` — writes a SINGLE strong impulse. A lone impulse ⇒ every output bin
   is full-magnitude (flat |FFT|, clean phase ramp), so 16-bit quantization noise can't mask a phase
   error. (Multi-impulse / random inputs give a flat, weak-bin spectrum where mean-subtracted correlation
   drowns in quant noise — misleading; don't use them for this check.)
2. A latency-accurate RTL testbench dumps the FFT's captured complex output + block-exponent for the same
   input, with backpressure disabled for a clean frame.
3. `mpfs/host/corefft_phase_compare.py [N]` — the right metric is the **complex ratio** `core/gold` on
   strong bins: a correct FFT ⇒ `|ratio|` constant (= 2^-SCALE_EXP) and `angle(ratio)` a single constant.
   A phase bug breaks that constancy. It also tests conj / bit-reversal / +j-convention candidates so a
   divergence can be diagnosed, not just detected.

This check is what proved the shipping CoreFFT chain phase-exact (0.0° spread at both 256 and 8192
points, forward −j convention) — see `docs/SAR_GUIDE.md` for that result in context. Use this technique
again any time a future FFT/gearbox change needs to be cleared of a phase/sign fault without a silicon
rebuild.

### 4.8 JTAG session mechanics specific to iso-tests

Beyond the general JTAG hygiene in `docs/USER_GUIDE.md` §3.3 (6 MHz clock ceiling, never kill mid-transfer,
single FlashPro6 owner):
- **`run_corefft_iso.sh`'s OpenOCD config (`board/microchip_riscv_efp6.cfg`) has NO telnet port 4444
  open by default** — the normal clean-shutdown-via-telnet fails ("telnet failed"), so if gdb wedges you
  are forced into a `taskkill /F` on openocd → FlashPro6 wedged. **Fix:** launch openocd with an explicit
  `-c "telnet_port 4444"` (or `gdb_port`/`tcl_port`) so clean shutdown works. Until that's wired in, avoid
  situations that would require killing it.
- gdb scripts must end with `monitor resume` + `monitor shutdown`. The trailing "Remote communication
  error. Target disconnected." AFTER "shutdown command invoked" is benign.
- **Capture gdb output** — either `set logging file <path>` + `set logging on` in the `.gdb` script, or
  redirect the runner's stdout to a file. NEVER `>/dev/null` — you lose the read values, which wastes an
  entire board run.
- **openocd startup**: `sleep 14` after launch before gdb connects (avoids a hart-examine race). Runner
  template: `run_status_probe.sh` (openocd + `gdb -x <script.gdb>`).
- A small iso-test scene load (1.5 MB over JTAG) takes ≈ 2.4 min (gdb prints nothing during `restore`).
  Dump 256-row bands (4 MB) rather than attempting the full 128 MB OUT buffer, which is impractical
  (hours) over JTAG.
- `libero.exe` lingers after `PROGRAMDEVICE` but does **NOT** hold the FlashPro6 (it's released at
  "PROGRAM PASSED"). Don't over-wait for the process to exit — just launch openocd; it will grab the
  FlashPro6 once free.

### 4.9 Methodology lessons (apply these first)

Hard-won from a debug session on an all-zero-image regression:
- **"RETURN=0 / stage completes" ≠ "data is correct."** The pipeline reported RETURN=0 for a whole
  session while emitting an all-zero image. Always verify data (CRC / read-back / correlate), never just
  completion.
- **A data-independent stage running fast proves nothing about the data.** The resample stage is a
  gather+lerp — it runs identically on zeros. "Resample sped up" did not mean data was flowing correctly.
- **Isolate every stage on silicon before blaming one.** The single-kernel iso test (§4.4) is the
  workhorse: flush a known input to DDR, arm ONE kernel, read its output. That localizes a failure while
  proving the other stages work — don't debug the whole pipeline at once.
- **Measure the input/output boundary of the suspect stage, not just the final output.** A stage is only
  confirmed as the fault source by reading its INPUT (rich) and OUTPUT (zero/wrong) directly — inference
  from "everything else works" can be wrong (a truncated `x/8xw` read of edge zero-fill columns briefly
  mis-blamed the wrong stage; read col 5+, see §4.3).
- **C-simulation passing does NOT prove the RTL.** `shls sw` + a numeric check passed at corr 0.9999 for
  an FFT whose synthesized RTL was a passthrough. Only silicon (or RTL cosim, when it works) is ground
  truth for HLS output. Budget for the possibility that HLS-generated RTL ≠ HLS source semantics.
- **When an HLS kernel is intractable, move the stage to the CPU.** A plain-C version on the U54 is
  provably correct, firmware-only (fast iteration), and fully controllable — a valid escape hatch when a
  synthesis bug resists multiple structural fixes and cosim is blocked. Trade throughput for correctness
  + iteration speed during bring-up; optimize later.
- **Image-correctness gotchas:** (a) a fixed-point FFT needs a block exponent (BFP), not per-stage
  truncation, or AC content rounds to zero (a DC-only image). (b) SAR/FFT output matches the golden only
  "up to orientation" — always run an 8-dihedral + transpose search (`correlate_cpufft.py`), and mask
  saturated pixels before correlating (speckle is unforgiving; a few percent saturation tanks the raw
  number).
- **Iteration-cost awareness.** A fabric rebuild is ~40 min and the Libero flow is fragile; a firmware
  rebuild is ~1.5 min. Push logic to firmware during bring-up whenever correctness allows — it turns an
  intractable multi-rebuild debug loop into minutes-per-iteration.

---

## 5. Libero SmartDesign editing gotchas (short)

**Never `delete_component SAR_TOP` to change only a CCC (clock) frequency.** Regenerate the CCC component
and `sd_update_instance` it onto the existing `SAR_TOP` in place instead. Deleting the top-level
SmartDesign is only safe if a known-good, faithful rebuild script already exists to reconstruct it headless
— this project once lost the as-built `SAR_TOP` SmartDesign that way, after a CCC-reconfig script called
`delete_component` with no such rebuild script in hand, and had to reconstruct it from scratch.

A verified, fully headless CCC-reconfiguration recipe (regenerate the CCC via its config script, byte-splice
the new PLL parameters into the surviving netlist if needed, then re-associate constraints and re-run
P&R with a timing gate) does exist in this project's history and is what the current build scripts
descend from — the specific frequency values in that recipe are now historical (superseded by later clock
changes) and are not reproduced here.

**Always commit `libero_sar`'s SmartDesign `.cxf`/`.sdb` + `.prjx` to git** so the top-level design is
recoverable without a from-scratch headless reconstruction.
