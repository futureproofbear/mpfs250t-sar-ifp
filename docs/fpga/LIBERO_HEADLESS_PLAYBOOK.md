# Libero / PolarFire SoC Headless Playbook

Hard-won practices for driving **Libero SoC 2025.2**, the **PolarFire SoC MSS**, on-silicon
programming, and **OpenOCD/FlashPro6** JTAG debugging entirely from the command line (no GUI).
Distilled from the sarProcessor bring-up (MPFS250T_ES, Icicle-style custom board, JTAG-only).

> TL;DR of the biggest time-sinks and their fixes:
> 1. **Kill `synbatch.exe` + `c_hdl.exe`, not just `synplify_pro.exe`** — the real synthesis
>    workers. A leftover `synbatch.exe` holds `synwork/` handles and silently corrupts/crashes
>    every subsequent synthesis.
> 2. **Gate on output artifacts (reports/netlist/job files), never on `run_tool` return codes** —
>    Libero frequently reports "Synthesis failed" *after* the mapper already wrote a valid netlist.
> 3. **Re-create ALL HDL+ cores in ONE Libero session** — `build_design_hierarchy` in a later
>    session breaks the links of cores created in an earlier one.
> 4. **Read on-silicon registers with `mem2array`+`echo [format]`, not `mdw`** in the custom OpenOCD.
> 5. **Changing only a CCC frequency? `sd_update_instance`, NEVER `delete_component SAR_TOP`.**

---

## 1. Invoking Libero headless

```bash
LIBERO="/c/Microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin/libero.exe"
"$LIBERO" "SCRIPT:my_script.tcl"        # console/batch mode; runs the Tcl, then exits
```

- The script itself does `open_project -file .../sar_accel.prjx` … `save_project`.
- **Always `> logfile.txt 2>&1`** and grep the log — the console output is the only feedback.
- Long runs (synth/P&R ~10–40 min): launch with `nohup "$LIBERO" ... &` and poll, OR use a
  background waiter (see §7). Foreground Bash calls cap at 10 min and will *kill* the tool.
- `libero.exe` is the parent; it spawns `synbatch.exe`, `c_hdl.exe` (synthesis), `pa_designer`/
  place-route workers, `pfsoc_mss.exe`. **All must be dead before a clean restart** (§6).

Key MPFS toolchain executables (2025.2):
| Tool | Path (under `.../Libero_SoC/Designer/bin[64]/`) |
|---|---|
| Libero batch | `bin/libero.exe` |
| MSS Configurator | `bin64/pfsoc_mss.exe` |
| FlashPro CLI (used by mpfsBootmodeProgrammer) | `bin64/fpgenprog.exe` |

---

## 2. SmartDesign headless

### 2.1 Create + connect
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
- **Interface-level connect** (`{DIC:AXI4mtarget0 ID_FIX:S_AXI}`) is cleanest but Libero refuses
  it if the bus-interface *metadata* differs ("not compatible") even when the signals match. Fall
  back to **signal-level** (one `sd_connect_pins` per signal). Both are functionally equivalent —
  verify by grepping the generated `component/work/SAR_TOP/SAR_TOP.v`: the driver net name is
  shared between the two instance ports (e.g. `.M_AXI_AWVALID(ID_FIX_M_AXI_AWVALID)` **and**
  `.FIC_0_AXI4_S_AWVALID(ID_FIX_M_AXI_AWVALID)` → connected).
- **Always inspect the generated `SAR_TOP.v`, not the synthesized `.vm`** to confirm wiring — the
  `.vm` is flattened. Instance-port connections in the generated `.v` are the ground truth.
- **DRC warnings matter.** `generate_component` "succeeded with warnings" can hide real bugs:
  - `ID width mismatch between X[0-10] and Y[0-8] ... loss of data` → a real truncation (fix the
    HDL width or the interconnect config).
  - `ID width mismatch CIC:AXI4mtarget0 [0-7] vs kernel [0-0]` → harmless (kernel target IDs are
    1-bit; the interconnect pads).
  - `Floating output pin CCC:OUT2/OUT3` → harmless (unused clock outputs).

### 2.2 HDL+ cores (SmartHLS kernels, custom Verilog cores)
Create a core *with* AXI bus interfaces headless (the GUI is NOT required, contrary to older notes):
```tcl
create_links -hdl_source "$here/sar_axi_idconv.v"   ;# link the source FIRST
build_design_hierarchy
create_hdl_core -file "$here/sar_axi_idconv.v" -module {sar_axi_idconv} -library {work}
hdl_core_add_bif -hdl_core_name {sar_axi_idconv} -bif_definition {AXI4:AMBA:AMBA4:slave}  -bif_name {S_AXI} -signal_map {}
hdl_core_assign_bif_signal -hdl_core_name {sar_axi_idconv} -bif_name {S_AXI} -bif_signal_name {AWID} -core_signal_name {S_AXI_AWID}
# ... one assign per signal; generate the ~40 assigns programmatically from the .v port list
```
- SmartHLS kernel cores are created by sourcing each kernel's
  `hls_<k>/hls_output/scripts/libero/create_hdl_plus.tcl`. Those call `configure_tool SYNTHESIZE`,
  which needs a **root set first**: `catch { set_root -module {COREFFT_C0::work} }` (any component).
- **BROKEN-LINK TRAP (important):** re-creating cores across *separate* Libero sessions breaks the
  previously-created cores' internal HDL links → `Error: HDL module '<x>' cannot be found` at
  generate. **Fix: `rm -rf component/User/Private/<core>` for ALL cores, then re-create them ALL in
  ONE session** (see `recreate_all_root.tcl` = `recreate_cores.tcl` + a leading `set_root`).

### 2.3 CoreAXI4Interconnect reconfig
`generate_component` alone can emit **stale HDL** (e.g. config says `NUM_TARGETS=6` but only 5
target interfaces appear). Force a full reconfigure:
```tcl
# extract every <configurableElement referenceId="X" value="Y"/> from component/work/<IC>/<IC>.cxf
# into a backslash-continued  [list \  "K:V" \ ... ]  param list, then:
create_and_configure_core -core_vlnv {Actel:DirectCore:COREAXI4INTERCONNECT:3.0.130} -params $P
generate_component -component_name {AXIIC_CTRL}
```
- AXI4-**Lite** interconnect targets are named `AXI4Lmtarget<n>` (with an **L**); full-AXI are
  `AXI4mtarget<n>` / `AXI4minitiator<n>`.
- Target address decode lives in `TARGET<n>_START_ADDR/END_ADDR` (+`_UPPER`). With `NUM_TARGETS=1`,
  extra `TARGET1..n` ranges in the `.cxf` are ignored defaults.

---

## 3. PolarFire SoC MSS (the hard block)

The MSS is imported from a **`.cxz`** archive (a zip of `ICICLE_MSS.v`, `.cfg`, `_mss_cfg.xml`,
`.cxf`, and a `MSS_<FIC0>_<FIC1>_<FIC2>_<FIC3>_<FIC4>_syn_comps.v` whose **filename encodes DLL
bypass per FIC**: `NOBYP`=DLL used, `BYP`=bypassed):
```tcl
catch {delete_component -component_name SAR_TOP}    ;# SAR_TOP instantiates the MSS
catch {delete_component -component_name ICICLE_MSS}
import_mss_component -file "$here/mss_nodll/out/ICICLE_MSS.cxz"
build_design_hierarchy
```

### 3.1 Reconfigure the MSS headless (e.g. bypass FIC DLLs) — `pfsoc_mss.exe`
Editing the `.cfg` inside the `.cxz` is **not enough** — the generated HDL + syn_comps must match.
Regenerate the whole component:
```bash
PFSOC=".../Designer/bin64/pfsoc_mss.exe"
# edit a COPY of the current cfg (e.g. libero_sar/component/work/ICICLE_MSS/ICICLE_MSS.cfg):
sed 's/\(FIC_[012]_EMBEDDED_DLL_USED[[:space:]]*\)true/\1false/' in.cfg > out/ICICLE_MSS.cfg
"$PFSOC" -GENERATE -CONFIGURATION_FILE:<win\path\ICICLE_MSS.cfg> -OUTPUT_DIR:<win\path\out> -EXPORT_HDL:true -LOGFILE:<log>
# verify: the new syn_comps filename reflects the change, e.g. MSS_BYP_BYP_BYP_BYP_BYP_syn_comps.v
```
- After regenerating, re-import the `.cxz` (§3) then re-create cores + rebuild SAR_TOP.
- **`import_mss_component` uses the pre-generated HDL inside the `.cxz`** — it does NOT re-synthesize
  from the `.cfg`. So the `.cxz` must already contain the correct HDL (that's what `pfsoc_mss` does).
- **Stale-syn_comps trap:** old `mss_*_syn_comps.v` left in `component/work/ICICLE_MSS/` (or copies
  at `component/MSS_syn_comps.v`, `component/syn_comps.v` referenced by the Synplify `.prj`) get
  pulled into synthesis → duplicate/conflicting MSS modules → intermittent synth failure + a netlist
  whose `// file …` comments reference *multiple* DLL configs. Ensure only the intended one remains.

### 3.2 FIC usage / DDR access (this design)
- `FIC_0/FIC_1`: MSS-master → fabric-slave (**control plane**; AXIIC_CTRL hangs off FIC_0 initiator).
- `FIC_2`: fabric-master → MSS-slave — the *textbook* high-bandwidth **data plane** to DDR.
- `FIC_3`: MSS-master → fabric APB (low-bandwidth control).
- **This design deliberately used `FIC_0_AXI4_S` (target) for the data plane** with `FIC_2` tied off
  (verify in the netlist: `FIC_0_AXI4_S_AWVALID(DIC_AXI4mtarget0_AWVALID)` vs `FIC_2_AXI4_S_AWVALID(GND)`).
- **FIC embedded DLLs only lock within a frequency band.** Dropping the fabric clock below it (e.g.
  125→62.5 MHz for timing closure) leaves an *enabled* FIC DLL **unlocked**, which breaks that FIC's
  data path while low-rate control still limps through. Fix = **bypass** the DLL (`..._DLL_USED false`)
  — at low clocks the ns-scale insertion delay is negligible. Confirm on silicon via `DLL_STATUS_SR`
  (§5.3): enabled-but-unlocked reads bit=0; bypassed/disabled reads bit=1.

---

## 4. Synthesis / P&R / bitstream / program flow

```tcl
open_project -file "$pd/sar_accel.prjx"
build_design_hierarchy
set_root -module {SAR_TOP::work}
organize_tool_files -tool {PLACEROUTE}   -file $iopdc -file $sdc -file $cdc -module {SAR_TOP::work} -input_type {constraint}
organize_tool_files -tool {VERIFYTIMING} -file $sdc -file $cdc -module {SAR_TOP::work} -input_type {constraint}
catch { run_tool -name {SYNTHESIZE} }        ;# ignore return code (see below)
configure_tool -name {PLACEROUTE} -params {REPAIR_MIN_DELAY:true}
catch { run_tool -name {PLACEROUTE} }
catch { run_tool -name {VERIFYTIMING} }
# ... GATE on the reports, not the return codes ...
run_tool -name {GENERATEPROGRAMMINGDATA}
run_tool -name {GENERATEPROGRAMMINGFILE}
export_prog_job -job_file_name {SAR_TOP_62p5} -export_dir "$pd/export" -bitstream_file_type {TRUSTED_FACILITY}
```

### Gotchas
- **Spurious "Synthesis failed":** `run_tool SYNTHESIZE` often prints `Error: Synthesis failed` /
  `Starting Synplify Pro ME... Error` *even though* `synlog/SAR_TOP_fpga_mapper.srr` says
  `Mapper successful!` and a valid `synthesis/SAR_TOP.vm` (~18 MB) was written. **Trust the artifacts,
  not the return code.** Do the whole flow in ONE session with `catch` around each `run_tool` and
  gate on the actual outputs.
- **Timing gate from reports** (robust; parse instead of trusting exit status):
  - setup: `designer/SAR_TOP/pinslacks.txt`, col 2 < 0 ⇒ violation.
  - hold: `designer/SAR_TOP/SAR_TOP_mindelay_repair_report.rpt`, regex `min-delay slack:\s*(-?\d+) ps`.
- **`derive_constraints` is NOT a valid Tcl command.** Supply a pre-made SDC and overwrite
  `constraint/SAR_TOP_derived_constraints.sdc` so the flow picks it up.
- **62.5 MHz CDC:** CoreFFT `CLK`↔`SLOWCLK` (=CLK/8) is async → needs `set_false_path` both dirs
  between the CCC `OUT0`/`OUT1` (`sar_fft_cdc.sdc`), else a phantom −2.7 ns hold violation.
- **Bootable bitstream needs the MSS design-init** — `GENERATEPROGRAMMINGDATA` after a valid MSS
  import; without it only ~62.5 % of I/Os place and the job is not bootable.
- **Forcing a re-synth:** delete `synthesis/SAR_TOP.vm` — BUT a bare `run_tool PLACEROUTE` will then
  error `Unable to find SAR_TOP.vm` if synth doesn't auto-run. Prefer the single-session flow with an
  explicit `run_tool SYNTHESIZE` first.
- **VM-netlist flow (bypasses Synplify entirely):** a separate project with
  `project_settings -vm_netlist_flow TRUE` + `import_files -verilog_netlist {X.vm}` (extension MUST
  be `.vm`; root auto-sets). Run `COMPILE → PLACEROUTE → VERIFYTIMING` (no `SYNTHESIZE`). Invaluable
  when Synplify is wedged — feed it an already-good `.vm`. The existing SmartDesign project refuses a
  netlist root, so use a dedicated project (e.g. `libero_vm`). Rename the netlist top to a distinct
  name (`sed 's/^module SAR_TOP (/module SAR_TOP_NL (/'`) to match that project's root.

### Programming (FlashPro6 on J33)
```tcl
run_tool -name {PROGRAMDEVICE}          ;# programs Fabric+sNVM+eNVM directly via FlashPro6
```
- Firmware (application ELF) is separate: `mpfsBootmodeProgrammer.jar --bootmode 1 --die
  MPFS250T_ES --package FCVG484 app.elf` (via `fpgenprog`). Reprogramming the fabric (which rewrites
  eNVM) means you should re-flash the app afterward.
- FlashPro6 wedges often (`Unable to open Embedded FlashPro6 device`) — power-cycle / re-plug J33.
- Only ONE tool can own FlashPro6 at a time: kill OpenOCD before Libero `PROGRAMDEVICE`, and vice versa.

---

## 5. OpenOCD / JTAG debugging (bare-metal, on-silicon)

Custom OpenOCD build (the stock SoftConsole one lacks the board cfg):
```bash
NEW="/c/Users/<you>/Tools/openocd-new/xpack-openocd-0.12.0-4"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f efp6_<test>.cfg
```
Board cfg boilerplate (`efp6_*.cfg`):
```tcl
set DEVICE MPFS
source [find board/microchip_riscv_efp6.cfg]
init
targets mpfs.hart1_u54_1
mpfs.hart1_u54_1 arp_halt
mpfs.hart1_u54_1 arp_waitstate halted 5000
# ... reads/writes ...
shutdown
```

### 5.1 Reads: use `mem2array` + `echo [format]`, NOT `mdw`
`mdw` produced **no output** in this OpenOCD; `mem2array` works:
```tcl
mem2array v 32 0x60004008 1
echo [format ">>> fft_feeder START/busy = 0x%08x" $v(0)]
mem2array r 32 0xB0050000 200          ;# bulk read (200 words); parse in a Tcl loop
```
- Reading fabric control regs (`0x6000_n000`) works via the MSS→FIC0 path (control plane).
- The custom OpenOCD/FlashPro6 is **latency-bound (~84 kbit/s)**; keep JTAG bursts short.

### 5.2 Writes + the coherency trap
- `mww <addr> <val>` writes, but a **bare sysbus `mww` to cached DDR is NOT coherent** with a running
  hart's view — the firmware polling a cached mailbox won't see it. The firmware expects the mailbox
  written via the **hart's debug view** (GDB / verified progbuf), as the working `run_new.sh` did
  (OpenOCD + GDB in parallel). For fabric registers (non-cached, via FIC) `mww` is fine.
- Writing an internal descriptor then reading it back **immediately** vs **after a delay**
  disambiguates "never triggered" (bits stay unset) from "started then hung" (bits set then cleared
  by HW) — used to prove the DMA started but its data-plane transfer hung.

### 5.3 Useful on-silicon registers (MPFS)
| What | Addr | Notes |
|---|---|---|
| SYSREG base | `0x20002000` | `BASE32_ADDR_MSS_SYSREG` |
| `DLL_STATUS_SR` | `0x2000215C` | FIC0_LOCK=b0, FIC1=b1, FIC2=b2, FIC3=b4, FIC4=b5; UNLOCK sticky at b8+. **1=locked/bypassed-ready, 0=enabled-but-not-locked (BUG).** |
| `PLL_STATUS_SR` | `0x2000214C` | CPU/DFI/SGMII lock bits (sanity: MSS PLL up). |
| Fabric kernel ctrl | `0x6000_n000` | CT/WIN/DET/RES/FEED @ n=0..4; `fft_unloader` @ 0x60005000. |

### 5.4 Booting for JTAG
- Board only halts for JTAG in **boot mode 0** (WFI) unless the app cooperates; otherwise use the
  firmware mailbox to trigger tests and read results from DDR.
- On-target CRC32 mailbox (`0xB0058000`) verifies JTAG-loaded DDR in seconds vs a slow dump+compare.

---

## 6. Toolchain instability — recovery checklist

Repeated synthesis crashes / `Device or resource busy` on `synwork/` are almost always **leftover
worker processes**, not your design.

```bash
# Kill EVERY worker (the usual suspects PLUS the ones people miss):
for p in libero.exe synbatch.exe c_hdl.exe synplify.exe synplify_pro.exe acttclsh.exe \
         designer.exe pfsoc_mss.exe; do taskkill //F //IM "$p" 2>/dev/null; done
# synbatch.exe + c_hdl.exe are the REAL Synplify workers and hold synwork handles.
sleep 10
tasklist | grep -iE "synbatch|c_hdl|libero|synplify"   # must be empty
rm -rf libero_sar/synthesis/synwork                    # must succeed cleanly
```
- If `synwork` is *still* busy after killing everything, a handle is pending-release (or AV is
  scanning) — wait longer, or the environment/Libero needs a restart. Do NOT launch a new synth over
  a busy `synwork` (it inherits the corruption).
- No PowerShell / `wmic` on this host (GPO-blocked): use `tasklist` + `systeminfo` for process/memory.
- Memory is rarely the cause (synth peaks ~630 MB; check `systeminfo | grep "Available Physical"`).

---

## 7. General best practices (headless FPGA bring-up)

1. **One-session atomicity** for anything that touches `build_design_hierarchy` + component
   creation — cross-session re-scans break links.
2. **Gate on artifacts, not return codes.** Parse reports / check file mtimes+sizes; Libero lies in
   its exit status.
3. **Long tools in the background** (`nohup … &`) with a waiter that greps the log on completion;
   never block a foreground Bash call for >10 min (it kills the tool mid-run and orphans workers).
4. **Never `delete_component SAR_TOP` to change a CCC frequency** — regenerate the CCC and
   `sd_update_instance` it in place. Deleting the top with no faithful rebuild script cost a full
   headless reconstruction. Commit `libero_sar` SmartDesign `.cxf`/`.sdb` + `.prjx` to git.
5. **Verify wiring in the generated `.v`, functionality on silicon.** "Stage completes" ≠ "data
   correct" ≠ "timing met" ≠ "DLL locked". Check each explicitly.
6. **Always confirm P&R timing is MET (0 setup + 0 hold) before debugging silicon functionally** —
   Libero will happily program a timing-failing bitstream.
7. **Back up a good netlist the moment you have one** (and verify the copy is non-empty) — a later
   crashed synth can truncate `synthesis/SAR_TOP.vm`.
8. **Prefer headless/scripted first; before destructive ops** (`delete_component`, `rm`, overwrite)
   check recoverability and operate on copies.

---

## 8. Firmware rebuild + coherent pipeline debug (bare-metal MPFS)

### Rebuild the app (SoftConsole make)
```bash
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
export PATH="$SC/riscv-unknown-elf-gcc/bin:$SC/build_tools/bin:$PATH"
cd .../mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release
make all        # <-- 'make' (default target) does NOTHING here; you MUST say 'make all'
# ELF grows/mtimes update; then reflash via mpfsBootmodeProgrammer (run_program.sh, boot mode 1)
```
- Per-file flags live in `src/<dir>/subdir.mk` (e.g. `-Os` → `-O2` to speed FP-heavy code); these are
  Eclipse-generated but a headless `make all` honors edits to them.
- Reprogramming the fabric rewrites eNVM → **re-flash the app afterward.**

### Trigger the pipeline COHERENTLY over JTAG — GDB function call, not the mailbox
The firmware mailbox (`mww`-written) has a cache-coherency gap (§5.2). The clean path is to **call the
sequencer directly on the hart via GDB** — coherent, no mailbox:
```
# run_new.sh: launch OpenOCD server (background) + GDB with a flow script
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2                              # select U54_1
source load_geom.gdb                  # restore geometry/JOB to DDR (skip the 93 MB SIG if only testing control flow)
p (int)sar_form_image(0)              # runs the WHOLE pipeline on the hart; returns sar_seq_status_t
printf ">>> RETURN=%d\n", (int)$      # 0=OK, else failing stage (2 RESAMPLE..8 DMA)
```
- `sar_form_image(0)` uses `SAR_DEFAULT_SPINS = 0x40000000` (bounded, ~5 min/stalled-stage). A **smaller**
  `spin_limit` FALSE-times-out the last resample pulse (it skips the double-buffered coeff precompute so
  its `k_wait` doesn't overlap the kernel) — don't mistake that for a hang.
- The 93 MB SIG loads at the ~84 kbit/s JTAG ceiling = **~2.5 hr**; for control-flow/stall diagnosis skip
  it (garbage in the SIG region is still valid DDR — the data-plane read/write path is exercised either way).

### Progress / state instrumentation (see WHERE it is, not just that it stalled)
Add a few DDR writes to a free address, then poll/read them **halted** (halted JTAG reads are coherent —
same as how the M2 result table works):
```c
#define SAR_PROG_ADDR 0xB0059100u     /* free DDR (past stream desc @0xB0059000) */
/* in the hot loop, before each kernel start: */
volatile uint32_t *pg = (uint32_t*)SAR_PROG_ADDR; pg[0]=pass; pg[1]=idx; pg[2]=total; pg[3]++;
```
After a bounded run returns, the address holds the exact stalled index → distinguishes "hung at item 0"
from "advanced then stalled" from "false-timeout at the last item." This is what proved the resample
runs all 13,826 lines (not hung) and localized the real stall to the FFT stage.

### SmartHLS kernel re-synth (for a fabric-side kernel change)
Kernel C++ (e.g. `hls_resample/resample.cpp`) → re-run SmartHLS (`hls_resample/Makefile` + `config.tcl`)
→ new RTL → re-create the HDL+ core (§2.2) → rebuild SAR_TOP → P&R → reprogram. Kernel perf tip: a
random **gather** (`in[idx[i]]`) can't burst even with `max_burst_len` — pull the line into a local
`static` array with one sequential (burstable) read, then gather on-chip.

---

### Key scripts in `mpfs/fpga/` (this project)
Verified present as of 2026-07-20 (older notes referenced several scripts that no longer exist).

| Script | Purpose |
|---|---|
| `create_fresh_project_ffv.tcl` | Create a clean Libero project + all IP/MSS/HDL+ cores, with the hand-written Verilog feeder (sources `feeder_v_core.tcl`) instead of the SmartHLS one. The current SAR_TOP starting point. |
| `create_fresh_project.tcl` | Same, but with the SmartHLS feeder (the `libero_tdest` variant). |
| `sartop_assembly.tcl` | The SAR_TOP SmartDesign assembly (instantiate + connect + interconnect wiring). |
| `feeder_v_core.tcl` | Register `fft_feeder_top`/`fft_feeder_v` as an HDL+ core with the same bus interfaces the SmartHLS core had. |
| `gearbox_idconv_cores.tcl` | Register `corefft_stream64_adapter` + `sar_axi_idconv` as HDL+ cores (the create_hdl_core/add_bif pattern of §2.2). |
| `build_full_prog_ffv.tcl` | Single-session SYNTH → P&R → VERIFYTIMING → report gate → export, for the ffv project. |
| `build_gbxfix_ffv.tcl` | Same flow, rebuilding with the FIXED gearbox (linked HDL source). |
| `build_scaleexp_ffv.tcl` / `build_full_prog_fresh.tcl` | Sibling gated build flows (SCALE_EXP variant / `libero_tdest`). |
| `build_corefft_vm.tcl` | VM-netlist recovery flow at 62.5 MHz (no Synplify) — see `SAR_TOP_RECOVERY.md`. |
| `build_timed.tcl` | Build with a HARD timing gate (parses `pinslacks.txt`, aborts before bitstream). |
| `build_corefft_bootable.tcl` | Add the HSS eNVM boot client + export a bootable job. DEPLOYMENT ONLY — HSS does not cooperate with JTAG halt. |
| `finish_export.tcl` | Re-run only `export_prog_job` when a finished build failed solely on a missing export dir. |
| `stage_constraints_tdest.tcl` / `reconstrain.tcl` | Import the hand-written constraints and (re)generate the top-level derived SDC. |
| `PF_CCC_C0_62p5.tcl` | Regenerate the CCC at 62.5 / 7.8125 MHz. |
| `program_ffv.tcl` / `program_tdest.tcl` | `run_tool PROGRAMDEVICE` on an already-built project (FlashPro6). |
| `run_hlsfft_build.sh` / `create_fresh_project_hlsfft.tcl` / `build_full_prog_hlsfft.tcl` / `sartop_assembly_hlsfft.tcl` / `program_hlsfft.tcl` / `stage_constraints_hlsfft.tcl` | The abandoned HLS-FFT variant of the flow. Retained as scripts only; the shipping FFT is the fabric CoreFFT chain. |
| `hls_gate.sh` / `lint_netlist.sh` / `trim_mss.py` | SmartHLS output gate, netlist lint, MSS trim helper. |
| `mpfs/host/run_program.sh` | Flash app ELF via `mpfsBootmodeProgrammer` (boot mode 1). |
| `efp6_*.cfg` | OpenOCD JTAG test/probe scripts (m2 dump, rate tests, DLL status, ctrl reads). |
