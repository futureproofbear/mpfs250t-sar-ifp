# SAR PolarFire SoC — User Guide / Application Note

> **New here?** Every acronym, magic value and stage nickname in this project is defined in [`docs/GLOSSARY.md`](GLOSSARY.md).

Operator's runbook for going from a fresh checkout of this repo to a focused SAR image on a
physical **Icicle Kit (MPFS250T_ES / FCVG484)** board. Procedure-only: for *why* a step exists,
follow the links out to the design docs. This document does not need to be read start-to-finish —
jump to the section for the task in front of you.

---

## 1. Overview

This board forms a synthetic aperture radar (SAR) image on-chip: it takes an Umbra CPHD phase-history
capture, runs the **Polar Format Algorithm (PFA)** — keystone resample, 2-D window, range FFT,
corner-turn, azimuth FFT, detect — almost entirely in FPGA fabric on a **PolarFire SoC MPFS250T_ES**
(Icicle Kit), and hands back a focused magnitude image. The RISC-V MSS (U54_1) only sequences kernels
and computes small per-line resample coefficients; it never touches bulk sample data.

For the algorithm, kernel contracts, memory map, and design rationale, see
[`docs/ARCHITECTURE.md`](ARCHITECTURE.md) and [`docs/SAR_IMPLEMENTATION_RECORD.md`](SAR_IMPLEMENTATION_RECORD.md). This document covers
only **how to run it** on real hardware.

This repository (`mpfs250t-sar-ifp`) is self-contained: firmware, host tooling, and the Libero fabric
build all live here. You do not need any sibling repository to complete anything in this guide.

One caveat, so it does not surprise you: **running** the board works from a clean clone, but
**rebuilding the fabric from scratch does not** — two large generated trees (the MSS component and
the SmartHLS output) are git-ignored and must be regenerated once on a new machine. See §5.0. If you
only need to run the board, use an archived bitstream and skip §5.

---

## 2. Prerequisites

### 2.1 Hardware
- Microchip **Icicle Kit**, **MPFS250T_ES** die, **FCVG484** package.
- **Embedded FlashPro6** debug probe — on this board it is on-board, reached via the **J33** USB
  connector (no separate FlashPro6 pod needed).
- A USB cable, host PC.
- LPDDR4 populated (it is, on a stock Icicle Kit) — the pipeline uses DDR `0x8000_0000`–`0xC000_0000`.

### 2.2 Toolchain (versions are pinned — do not substitute)
| Tool | Version |
|---|---|
| Libero SoC (+ SmartHLS) | **2025.2** |
| SoftConsole | **v2022.2-RISC-V-747** |
| OpenOCD | **0.12**, `microchip-efp6` driver build (the stock SoftConsole OpenOCD lacks this board's cfg) |
| FlashPro programmer | `fpgenprog` / `mpfsBootmodeProgrammer.jar` (ships inside the SoftConsole install) |

### 2.3 `config.local.yaml` (your machine's paths)
Every script in this repo resolves the repo root from its own file location — nothing is
hard-coded — **except** the four external tool installs, which live in `config.yaml` under
`toolchain:`. Create a git-ignored `config.local.yaml` at the repo root with only the keys that
differ on your machine:

```yaml
toolchain:
  libero:       C:/Microchip/Libero_SoC_2025.2
  softconsole:  C:/Microchip/SoftConsole-v2022.2-RISC-V-747
  openocd:      C:/Users/<you>/Tools/openocd-new/xpack-openocd-0.12.0-4
  python:       C:/ProgramData/Anaconda3-.../python.exe
  license_file: C:/Users/<you>/.../License.dat
```
`config.local.yaml` overrides `config.yaml` key-by-key; anything you omit falls back to the
checked-in default. It is loaded by `mpfs/host/lib/sar_env.sh` (bash scripts) and
`mpfs/fpga/lib/sar_env.tcl` (Libero Tcl scripts) — you never need to export these paths by hand.

---

## 3. Bringing up the board

### 3.1 Physical setup
1. Connect the FlashPro6 USB cable to **J33**.
2. Power the Icicle Kit.
3. Confirm the die is **MPFS250T_ES** and boot mode is **1** (eNVM boot — this is the mode the
   shipping application firmware requires; a boot-mode-1 HSS build does **not** cooperate with JTAG
   halt and must never be used here).

### 3.2 Confirm JTAG connectivity BEFORE doing anything else
Do this every session before touching the board. Any OpenOCD board script that sources
`board/microchip_riscv_efp6.cfg`, examines the target, and halts `hart1_u54_1` proves the link is
live:
```tcl
set DEVICE MPFS
source [find board/microchip_riscv_efp6.cfg]
init
targets mpfs.hart1_u54_1
mpfs.hart1_u54_1 arp_halt
mpfs.hart1_u54_1 arp_waitstate halted 5000
reg pc
```
**Success marker:** the log reaches `examined` / `U54_1 halted` and `reg pc` returns a real value.
- If the app is running normally, expect `pc ≈ 0x0a00xxxx` (hart1 parked in the `u54_1()` mailbox
  loop in L2 scratchpad).
- `pc ≈ 0x20220xxx` means the hart never left the eNVM reset vector — the application did not boot
  (see §8 Troubleshooting).

### 3.3 JTAG hygiene — read before running anything else
These rules prevent wedging the on-board FlashPro6, which otherwise costs a USB replug or worse:
- **JTAG clock ceiling is 6 MHz on this board/cable.** `adapter speed 15000` (15 MHz) **corrupts the
  debug module** (`dmstatus` starts reading a bogus "version 4" and harts go unavailable/reset).
  Never exceed 6 MHz; several working `.cfg` files in `mpfs/fpga/` use 2 MHz or 6 MHz — copy one of
  those, not a 15000 one.
- **Never kill a JTAG transfer mid-stream.** `taskkill /F` on `openocd.exe` or `gdb` while it holds a
  debug-module operation wedges the FlashPro6 DM; a board power-cycle alone will **not** clear it —
  it needs the FlashPro6 USB cable unplugged and replugged. Tear down cleanly instead: telnet to
  port `4444` and send `shutdown`, or end the `.gdb` script with `monitor resume` /
  `monitor shutdown`.
- **Never SIGTERM `libero.exe`'s FlashPro session while Libero owns the FlashPro6**, and never run
  OpenOCD and Libero `PROGRAMDEVICE` against the FlashPro6 at the same time — only one tool may own
  it.
- A bulk JTAG DDR transfer that **runs to completion is byte-exact**; the risk is entirely in
  interrupting it, not in the transfer itself.

---

## 4. Loading data onto the board

There are two paths. **(a) is the current, preferred path** — read
[`.claude/skills/emmc-onboard-pipeline/SKILL.md`](../.claude/skills/emmc-onboard-pipeline/SKILL.md)
for the full mailbox reference; the commands below are the exact ones it documents. **(b)** is the
fallback for a board whose eMMC has not been provisioned yet.

### 4.1 Path A — eMMC boot-load (preferred, ~81.5 s per run)
The CPHD scene is provisioned onto the board's soldered eMMC **once**; every subsequent run loads it
from eMMC into DDR in about 81.5 s instead of a multi-hour JTAG transfer.

**One-time provisioning** (only if the eMMC INPUT partition is not already populated with your scene):
```bash
# pack a staged scene (serialize_inputs.py output) into an eMMC image
python mpfs/host/emmc_pack.py --stage <jtag_stage_deci1> --out emmc_input.img
python -c "import zlib;print(hex(zlib.crc32(open('emmc_input.img','rb').read())&0xffffffff))"  # note the CRC

bash mpfs/host/run_emmc_restore.sh                          # ~3 h: JTAG image -> DDR + on-hart CRC32 check
bash mpfs/host/run_emmc_prov_iso.sh 97553408 1100000 0x88000000   # ~16 min: DDR -> eMMC INPUT + verify
```

**Every run after that** — from `mpfs/host`:
```bash
bash run_m3_iso.sh 0x454C4F44 0 0 120000 0xB005E000     # ELOD: eMMC -> DDR, ~81.5 s
```
**Success marker:** the result record at `0xB005E000` reads magic `0xE3C0FF30`, `verdict 0`,
`nseg = 10`, and `sig_crc_exp == sig_crc_got`.

#### Selecting a scene — the eMMC holds up to 64

The **`.base` argument is the scene index**, not a spare zero. Every example in this guide passes
`0`, which is the Centerfield bring-up scene:

```bash
bash run_m3_iso.sh 0x454C4F44 0 0 120000 0xB005E000     # scene 0
bash run_m3_iso.sh 0x454C4F44 1 0 120000 0xB005E000     # scene 1
```

`emmc_pack.py` takes repeatable `--stage` directories and writes one self-describing blob per
scene behind a TOC (`EMMC_MAX_SCENES = 64`, 88-byte entries), and `sar_emmc_load()` bounds-checks
the index — an out-of-range scene fails with `ERR_MAGIC` rather than loading garbage.

> **Provisioning rewrites the whole INPUT region.** `emmc_pack.py` builds the image as a unit, so
> adding a scene re-writes the ones already there. It is not an incremental append.

### 4.1a Recovering a staged scene — do this BEFORE reprovisioning

**The staged scene directories are git-ignored and the eMMC copy is not a backup.** On 2026-07-28
the Centerfield scene existed *only* on the card: `jtag_stage_deci1/` was absent, `jtag_full/`
retained `layout.json` but none of its ten `.bin` blobs, and no Centerfield CPHD was on disk.
Reprovisioning would have destroyed the scene that produces crop CRC `0x319037b2` — the correctness
anchor for every optimisation in `docs/SAR_IMPLEMENTATION_RECORD.md`.

Both scenes are public Umbra open data, so a scene is recoverable from source. The Centerfield key
is the default in `src/form_image_pfa.py`:

```bash
curl -C - --retry 5 -o data/centerfield_20231010/2023-10-10-16-57-44_UMBRA-04_CPHD.cphd   "https://umbra-open-data-catalog.s3.us-west-2.amazonaws.com/sar-data/tasks/Centerfield%2C%20Utah/c0dbd830-e863-42c5-97d0-2cfd291bcb2a/2023-10-10-16-57-44_UMBRA-04/2023-10-10-16-57-44_UMBRA-04_CPHD.cphd"

python mpfs/host/serialize_inputs.py --in <that file> --out mpfs/host/jtag_stage_deci1 --grid 8192
```

**Verify before trusting it**: `jtag_stage_deci1/layout.json` must report `crc32.sig = 0x89fa12dc`,
the same value every `ELOD` prints. Confirmed byte-identical on 2026-07-28 (196,358,384 B CPHD,
5634x4319 -> 8192 grid, deci 1/1, geometry self-check `corr = 1.000068`).

That re-stage is also the proof that **`--grid 8192` is load-bearing** (§5.0): without it the
per-scene next-pow2 path produces different tables and a different CRC.

### 4.2 Path B — host-JTAG bulk load (fallback, ~2.7 hr for a full scene)
Use this only when the eMMC is not yet provisioned. Stage the scene on the host, then load each
blob over JTAG:
```bash
python mpfs/host/serialize_inputs.py --in <scene>_CPHD.cphd --out jtag_full --grid 8192
# -> jtag_full/{sig.bin, f0/df/pr/tans/invorder/krgrid/kcgrid/hamr/hamc.bin, job.bin,
#              layout.json, load.gdb}
```
`--grid 8192` is **load-bearing** and is NOT the default: the fabric CoreFFT is fixed at 8192
(firmware `SAR_GRID`), but `--grid` defaults to `0` = legacy per-scene next-pow2. For the
Centerfield scene the natural pow2 happens to be 8192 too, so omitting it appears to work — on any
other scene it silently stages tables the fabric cannot use. Note also that `--in` is a required
flag, not a positional argument, and decimation is two knobs (`--deci-pulse` / `--deci-sample`,
both default 1); there is no `--deci`.

Then, from a halted GDB session, `source jtag_full/load.gdb` (or run the equivalent OpenOCD
`load_image` sequence). Measured rate is **~84 kbit/s (~111 s/MB)** — a full ~97 MB scene is
**~2.7 hr**. This is latency-bound, not bandwidth-bound; it is identical at 2 MHz and 6 MHz JTAG
clock. It is byte-exact **if it runs to completion uninterrupted** (§3.3). Verify without a slow
readback using the on-target CRC mailbox:
```bash
bash mpfs/host/run_crc_verify.sh <FILE> [BASE_HEX]
```
which resumes hart1 to compute a zlib-compatible CRC32 in DDR (~75 MB/s) and reports the result —
much faster than dumping the region back over JTAG to compare.

### 4.3 DDR is volatile — the rule that catches everyone once
A board power-cycle **wipes DDR**. eMMC survives; DDR does not. Never run `PIPE` on DDR that was not
freshly loaded in the *current* power cycle — it silently produces a plausible-looking but bogus
result. Re-run the LOAD/JTAG-load step after every power-cycle, before every `PIPE`.

---

## 5. Building and programming the FPGA from the latest source

Full details, gotchas, and the complete script table: read
[`docs/fpga/DEV_GUIDE.md`](fpga/DEV_GUIDE.md) §3. This section is the
current canonical path through it — the `SAR_TOP` build with the hand-written Verilog feeder
(`_ffv` scripts), which is the shipping entrypoint.

### 5.0 First build on a FRESH CLONE — read this before you run anything

**The fabric build does not work from a clean clone.** `create_fresh_project_ffv.tcl` imports two
trees that are deliberately git-ignored because they are large generated output:

| needed by | path | ignored at |
|---|---|---|
| `import_mss_component` (line 60) | `mpfs/fpga/mss_nodll/out/ICICLE_MSS.cxz` | `.gitignore:74` |
| `create_hdl_plus` (line 76) | `mpfs/fpga/hls_*/hls_output/scripts/libero/…` | `.gitignore:147` |

On a machine that has never generated them, the Libero run fails on a missing file. That failure is
**not** a broken repo and not a bad script — those artefacts have to be regenerated once:

1. **MSS component** — regenerate the `.cxz` with Libero's MSS Configurator, headless:
   `<Libero>/Designer/bin64/pfsoc_mss.exe`. See `docs/fpga/DEV_GUIDE.md` §3.6 for the exact
   invocation and the FIC-DLL-bypass configuration this design needs. Editing the `.cfg` inside the
   archive by hand does **not** work — the importer regenerates HDL from it, so the `.cxz` must
   already contain the correct HDL.
2. **SmartHLS output** — run `shls hw` in each `mpfs/fpga/hls_*/` directory that the assembly still
   instantiates. As of 2026-07-28 the datapath is down to **one** SmartHLS kernel (`resample`); the
   others are retained as scripts only.

Everything else in this guide — programming a pre-built `.job`, loading a scene, running the
pipeline, dumping and verifying the image — works from a clean clone with no regeneration, provided
you have a bitstream. The archived, silicon-verified bitstreams under
`mpfs/fpga/bitstreams/<stamp>_<commit>/` are the fast path; `mpfs/host/restore_bitstream.sh` puts
one back in place in one command.

> If you only need to *run* the board, skip §5 entirely and go to §6.

### 5.1 Headless fabric build (Libero, no GUI)
All scripts live in `mpfs/fpga/` and resolve their own paths via `mpfs/fpga/lib/sar_env.tcl`
(reads `config.yaml`/`config.local.yaml`). Invoke Libero in batch mode:
```bash
LIBERO="<your Libero install>/Designer/bin/libero.exe"   # from config.local.yaml toolchain.libero
"$LIBERO" "SCRIPT:mpfs/fpga/create_fresh_project_ffv.tcl" > create.log 2>&1
"$LIBERO" "SCRIPT:mpfs/fpga/build_full_prog_ffv.tcl"      > build.log 2>&1
```
- `create_fresh_project_ffv.tcl` — builds a clean Libero project with all IP/MSS/HDL+ cores from
  scratch, using the hand-written Verilog `fft_feeder` (not the SmartHLS one). This is the current
  `SAR_TOP` starting point. Output project: `mpfs/fpga/libero_ffv/` (gitignored, ~300 MB regenerated
  — a fresh clone must run this once before there is anything to build).
- `build_full_prog_ffv.tcl` — single Libero session: SYNTHESIZE → PLACEROUTE → VERIFYTIMING →
  timing gate → GENERATEPROGRAMMINGDATA → GENERATEPROGRAMMINGFILE → `export_prog_job`. No
  `PROGRAMDEVICE` (board can be off for this step).
- Long runs (synth/P&R, ~10–40 min) will be killed if run as a >10-minute foreground call — launch
  in the background and poll/grep the log instead.
- **Trust the log markers, not the process exit code** — Libero frequently reports a spurious
  "Synthesis failed" even when the mapper wrote a valid netlist. Gate on these markers appearing in
  the log, in order:
  - `TIMING_MET (pre-progdata)` — the authoritative multi-corner setup+hold reports came back clean
    (`No Path` on both the max and min timing violation XMLs — i.e. **0 setup and 0 hold violations**
    on the authoritative multi-corner report; the single-cycle `pinslacks.txt` is informational only
    and reads spuriously negative on some multicycle HLS paths).
  - `TIMING_MET (post-progdata, re-verified)` — programming-data generation is allowed to silently
    re-place the design; the script re-verifies timing against the layout that will actually ship
    and refuses to export if that re-check fails (`TIMING_NOT_MET_AFTER_PROGDATA`).
  - `BITSTREAM_DONE` then `FFV_BUILD_DONE` — the job file was exported to
    `mpfs/fpga/libero_ffv/export/SAR_TOP_ffv.job`.
- If a build fails immediately (~18 s) with a "permission denied" on a `.smat.seg` file, a leftover
  `libero.exe` process from a previous run/program still holds a lock — kill it
  (`taskkill //F //PID <pid>`, safe to force-kill Libero itself) and re-run.

### 5.2 Build the SoftConsole firmware
```bash
SC="<your SoftConsole install>"     # config.local.yaml toolchain.softconsole
export PATH="$SC/riscv-unknown-elf-gcc/bin:$SC/build_tools/bin:$PATH"
cd mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release
make all        # NOTE: plain `make` (default target) does nothing here — you must say `make all`
```
This build directory is git-ignored and regenerated by SoftConsole from the tracked `.cproject`
(which already has `-DSAR_EMMC_ENABLE` and `mss_mmc`/`mss_gpio` un-excluded, so a clean clone builds
the eMMC-capable firmware). A successful build produces/updates
`mpfs-hal-ddr-demo.elf` in that directory.

### 5.3 Program the device over FlashPro6/JTAG
Programming is two separate steps — **both are required, every time you touch the fabric**:

1. **Program the fabric** (from inside the same Libero session that just built it, so the project
   root is still selected):
   ```tcl
   # program_ffv.tcl: open_project -> set_root SAR_TOP::work -> run_tool PROGRAMDEVICE
   "$LIBERO" "SCRIPT:mpfs/fpga/program_ffv.tcl" > program.log 2>&1
   ```
   Only one tool may own the FlashPro6 at a time — make sure no OpenOCD session is attached first.

2. **Re-flash the application to eNVM** — mandatory after *any* fabric program, including a
   fabric-only program that never touches eNVM:
   ```bash
   bash mpfs/host/run_program.sh      # ~4 min; fpgenprog / mpfsBootmodeProgrammer, boot mode 1
   ```
   Then **power-cycle the board**. Flashing eNVM does not itself start the new app — until a
   power-cycle, hart1 still runs the old code. Confirm the new app is actually running by re-checking
   §3.2: `pc ≈ 0x0a00xxxx` is good, `pc ≈ 0x20220xxx` means the app never started.

Skipping step 2 (or the power-cycle) is the single most common way to lose an hour on this board: JTAG
still connects, mailbox commands appear to "arm" but their result records never populate, and OpenOCD
starts segfaulting or disconnecting mid-wait — symptoms that look exactly like a wedged FlashPro6.
See §8.

---

## 6. Running the program

Full control-interface/register reference: [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) §8 (Control interface).
Nothing runs automatically at boot —
the board waits in a command loop on the hart1 mailbox at `0xB0058000`
(`+0 cmd, +4 base, +8 len, +C result, +10 status, +14 seq`; `status == 0xC0FFEE03` means done).

### 6.1 Prerequisites for a run
By this point you must have, in the **current power cycle**:
1. A programmed, timing-clean fabric (§5).
2. A freshly re-flashed, running application (§5.3, confirmed via §3.2).
3. A scene loaded into DDR **this power cycle** (§4) — SIG does not survive a power-cycle.

### 6.2 Run the pipeline
From `mpfs/host`, using the generic mailbox runner:
```bash
DETMODE=3 GATHMODE=1 OVLMODE=1 CGENMODE=0x43474E31 DUALFFT=0x44464632 RWRKNW=0x52575204 FFTBLK=64 \n  bash run_m3_iso.sh 0x50495045 0 0 180000 0xB0058020
```

> **Every engine knob defaults to OFF** in `run_m3_iso.sh`. The bare command (no env vars)
> produces an unfused, single-chain run — several seconds slower and NOT the configuration any
> baseline in these docs was measured with. The line above is the shipping 18.45 s configuration;
> drop individual knobs only to build a deliberate A/B arm.

> **From the 2026-07-28 bitstream on, the range gather runs on `sar_resample_v` whether you ask for
> it or not.** `RSVMODE` (`0xB0059148`) is the one inverted knob on this project — the new core
> replaced the SmartHLS resample at the same CIC target, so there is no fallback and a cold-boot
> zero has to mean ON. Measured result (2026-07-29 baseline): frame **14.92 s** (was 18.45 s) and
> crop CRC `0x221e5e7a`. **CRC `0x319037b2` does not match, by design** — the kernel is fixed-point
> where the old path was float32, and that CRC was a CENTRE crop of the old path anyway. Validate by
> **correlation** against `jtag_full/crop_topleft.bin` (0.977 measured), not CRC equality.
> Read `0xB0059150` (line-0 `SH`/`A`/`B`, expect `0x00000018 0x4FE68946 0xE464BAAC 0xFFFFFFFC`) and
> `0xB005914C` (`STATUS2`, expect `0x52530000` — tag `0x5253`, zero error bits) **before** judging
> the image: a mismatch at the first explains a bad image outright, a match rules the CPU side out.
>
> **Use the TOP-LEFT crop to assess the image, not the centre.** Rows/cols 3584..4608 of the
> Centerfield scene are low-return (peak ~76 against ~3030 top-left), so a centre crop looks
> alarmingly dim and correlates near zero against a top-left reference. That mistake cost a full
> debugging session on 2026-07-29. `EROI` encodes `.base=(r0<<16)|r1`, `.len=(c0<<16)|c1`, so
> top-left 1024×1024 is `base=0x00000400 len=0x00000400`.
This is the `PIPE` command (`0x50495045`). The runner:
- selects the shipping **fabric CoreFFT** chain by setting `FFTMODE @0xB0059110 = 1` before arming
  (mode 0 is the legacy CPU-FFT fallback);
- polls rather than blind-sleeps, so it returns as soon as the run completes — the 300000 ms
  (5 min) argument is a timeout budget, not a fixed wait;
- prints per-stage timing from `sar_stage_ts[]` (start/resample/window/rangeFFT/cornerturn/
  azimuthFFT/detect, 1 µs/tick) on completion.

You can re-read the per-stage timing from the last completed run at any time, without re-running,
via:
```bash
bash mpfs/host/run_stage_timing.sh
```
**Seven** engine knobs exist as environment variables to `run_m3_iso.sh` (see [`docs/GLOSSARY.md`](GLOSSARY.md) §6 for the full table with addresses and shipping values). For A/B testing
(`GATHMODE` — fuse the azimuth-resample gather into the FFT-1 feeder; `DETMODE` — fuse detect into
the FFT-2 unloader; `OVLMODE` — overlap the second corner-turn with FFT-2); consult
`mpfs/host/run_m3_iso.sh` for their current defaults before relying on a specific combination.

**Success marker:** mailbox `result = 0` (`SAR_SEQ_OK`). Any other value is the failing stage code
from `sar_seq_status_t` (`sar_sequencer.h`) — a **timeout**, not a hang: every stage is bounded, so a
stuck kernel returns a `TIMEOUT_*` code rather than locking up JTAG.

**Current baseline runtime** (measured 2026-07-24, 100 MHz fabric clock, fused
azimuth-gather + fused detect + corner-turn/FFT-2 overlap, deci-1 Centerfield scene 5634×4319 →
8192 grid): **37.72 s** total, per
[`docs/SAR_IMPLEMENTATION_RECORD.md`](SAR_IMPLEMENTATION_RECORD.md) Part 3 (the single source of
truth for the per-stage breakdown — do not re-derive it here). With the eMMC boot-load (§4.1, 81.5 s)
this puts a full load-and-focus cycle at roughly **two minutes**.

---

## 7. Verifying the output

Full verification-contract reference: [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) §11 (Verification contract).

### 7.1 "Completed" is not "correct"
`result = 0` only means the pipeline ran to completion — it does not mean the data is right. This
project has been burned by exactly that gap before (a whole session of `RETURN=0` runs that were
emitting an all-zero image). Always verify data, not just completion.

### 7.2 Fast, on-target integrity check (no slow dump)
If you persisted the output to eMMC (`ESAV`, §4/skill), verify it without a full dump+compare using
the on-target CRC mailbox command:
```bash
bash mpfs/host/run_m3_iso.sh 0x45564F55 0 0 120000 0xB005E300     # EVOU: verify OUT vs TOC, ~63 s
```
**Success marker:** result record at `0xB005E300` (magic `0xE3C0FF60`) shows `verdict 0` and
`out_crc_exp == out_crc_got`.

### 7.3 Crop-verify the focused image
Dumping the full 128 MB OUT buffer over JTAG is impractical (hours, bounded by the ~84 kbit/s FP6
link — an eMMC-loaded scene doesn't change this). Instead, crop a center region from DDR and render
it:
```bash
bash mpfs/host/run_m3_iso.sh 0x45524F49 0x0E001200 0x0E001200 20000 0xB005E200 \
     0x98000000 2097152 jtag_full/crop.bin        # EROI: 1024x1024 crop, ~4 min JTAG dump
python mpfs/host/render_crop.py jtag_full/crop.bin 1024 1024 jtag_full/crop.png
```
**Success marker (eyeball):** coherent SAR speckle and recognizable scene structure (field
boundaries, roads, etc.) in the PNG — not flat noise, not an all-zero/all-saturated image.

### 7.3a A/B runs: CRC-FIRST, dump only on mismatch

For an A/B (does change X alter the output?) do **not** dump both crops. `EROI` runs entirely
on-board and writes its own CRC32 of the cropped region into the ROI record; the 2 MiB
`dump binary memory` is a *separate*, optional host-side step. So compare the board's CRCs first
and pull pixels only when they disagree.

```bash
# per run: crop on-board, then read just the record (a handful of words -- instant over JTAG)
bash mpfs/host/run_m3_iso.sh 0x45524F49 0x0E001200 0x0E001200 20000 0xB005E200
#   ROI record @0xB005E200: +0 magic(0xE3C0FF50) +4 verdict ... +0x20 crc
#   -> read the u32 at 0xB005E220 = the board-computed crop CRC
```
Require `verdict 0` on both runs, then compare the two `0xB005E220` values:
- **equal** → outputs are identical; no dump needed, the A/B correctness gate has PASSED.
- **differ** → now dump both crops (`+ 0x98000000 2097152 <file>`) and diff/render them to find out
  how they differ. The transfer is only worth paying for once there is something to look at.

**Why this matters:** the JTAG link is ~84 kbit/s (~111 s/MB) and *latency*-bound — ~390 µs per
word-scan through the FlashPro6 USB-HID, identical at 2 MHz and 6 MHz, with no OpenOCD batching
knob. A 1024×1024 uint16 crop is 2 MiB ≈ **230 s**, so two dumps are ~7.5 min of a ~12 min A/B
cycle — more than the scene loads (81 s each) and the pipeline itself (~37.5 s each) combined.
CRC-first takes the cycle to roughly 4.5 min.

Validated 2026-07-25: the board-computed ROI CRC matched the host `zlib.crc32` of the dumped bytes
exactly (`0x2d4786ef`), on both arms of an A/B — so the CRC is a faithful stand-in for the pixels.

### 7.4 Value-level correctness, not correlation
Correlation is scale-, phase-, and orientation-invariant, which has hidden real bugs on this project
before (a sign-extension defect in `detect` passed a correlation check while corrupting half the
image). The project's standing verification philosophy is to compare actual complex sample values
against a bit-accurate fixed-point emulator (`silicon_emulator.py`, which equals the float golden at
corr 1.0) and only then compare to the reference image — see the `sar-verification-methodology`
skill for the full method (orientation-search pitfalls, phase-sensitive FFT checks, per-stage value
injection). Do not re-derive that methodology here; load the skill.

When you do compare a board image to the golden, account for orientation first: the board result
matches in the `T.rot180` orientation (`board == golden.T[::-1,::-1]`). A naive band comparison has
read corr 0.06 on an image that was actually correct — run the full 8-dihedral orientation search
(`mpfs/host/correlate_cpufft.py`) before concluding a divergence is real. Current reference result:
**corr 0.9923** against `golden_small_mag.npy` on the Centerfield decimated scene.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Mailbox commands "arm" (echoed in the log) but their result record stays `0x00000000`/`0xdeadbeef`; OpenOCD segfaults or drops "Target disconnected" mid-wait; gdb reports `unable to halt hart 1` | You programmed the fabric (even fabric-only) and did **not** re-flash + power-cycle the app afterward | `bash mpfs/host/run_program.sh`, then power-cycle, then confirm `pc ≈ 0x0a00xxxx` (§3.2/§5.3) before retrying |
| LOAD (`ELOD`) returns `verdict 2` (`ERR_INIT`) with `init_status = 9` (`MSS_MMC_OP_COND_ERR`) | Looks like a dead eMMC or bad card, but almost always means **the fabric is not programmed** — the eMMC/SD mux select is a fabric-driven tie (`SDIO_SW_SEL0/1/EN_N`), so with a dark fabric the SD controller is wired to nothing | Program the fabric (FABRIC-ONLY `.job`), power-cycle, retry LOAD. DDR probes will pass in this state and mislead you — don't trust them here |
| A `PIPE`/`ELOD`/etc. run right after a power-cycle produces a plausible but wrong result | DDR was wiped by the power-cycle; you ran `PIPE` without re-loading SIG | Re-run `ELOD` (or the JTAG load) before every `PIPE` following a power-cycle (§4.3) |
| OpenOCD freezes after "Disabling abstract command…", before `monitor reset halt`; log stops growing | A previous force-kill of OpenOCD wedged the FlashPro6 DM; a board power-cycle alone does not clear it | Unplug/replug the FlashPro6 USB cable, **then** power-cycle the board |
| `dmstatus` reads a bogus "version 4" (`0x1e1904`); harts go unavailable/reset | JTAG adapter speed was set above 6 MHz (e.g. `adapter speed 15000`) | Use a `.cfg` with `adapter speed` ≤ 6000 (2000–6000 kHz); never copy a 15000 config |
| Libero build fails almost immediately (~18 s) with "permission denied" deleting a `.smat.seg` file | A leftover `libero.exe`/`synbatch.exe`/`c_hdl.exe` process from a prior run still holds the project dir | Kill the leftover processes (`taskkill //F //IM libero.exe` etc. — Libero itself is safe to force-kill, unlike OpenOCD/gdb), confirm `tasklist` is clean, then rebuild |
| A build reports success but `designer/impl2/` exists instead of `designer/SAR_TOP/`, or the timing-gate report file is simply missing | Dirty/leftover project residue named a second implementation; a naive gate that treats "missing report" as "0 violations" will falsely pass | Delete the (regeneratable) build dir and rebuild clean; always require the timing report to *exist*, not just be absent-therefore-clean |
| Build exports a bitstream, but silicon behaves non-deterministically (stages "complete" but data is wrong, or a stage hangs intermittently) | Timing was not actually met — Libero will silently program a timing-failing bitstream | Re-check the build log for `TIMING_MET (post-progdata, re-verified)` and `BITSTREAM_DONE`; if either is missing / `TIMING_NOT_MET*` appears, the export was refused or invalid — do not program it |
| Firmware `make` appears to do nothing | Plain `make` (no target) is a no-op in this project | Always run `make all` |
| Disk/host resource issues during a Libero rebuild | `libero_ffv/` is a ~300 MB regenerated tree; repeated rebuilds without cleanup can accumulate stale `synwork/` directories | Confirm no leftover Libero-family processes, then it is safe to delete `synthesis/synwork` and rebuild |

For anything JTAG-session-specific beyond this table (a hung `gdb`, an unresponsive OpenOCD), use the
`jtag-recover` skill rather than improvising a teardown.
