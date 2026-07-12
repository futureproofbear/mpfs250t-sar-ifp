---
name: mpfs-platform-gotchas
description: >-
  Platform-knowledge reference for the Microchip/Microsemi PolarFire SoC MPFS250T_ES engineering-
  sample chip + Icicle-style board + toolchain. Load it BEFORE bringing up or debugging anything
  on this silicon, to avoid re-hitting known ES-silicon errata (ER0219) and Microchip-toolchain /
  IP peculiarities (Libero, SmartHLS, SmartDebug, FlashPro6, CoreFFT, FIC/AXI-ID, DDR coherency,
  boot/eNVM). Triggers: "PolarFire SoC", "MPFS250T", "engineering sample / ES silicon", "errata",
  "why does <silicon thing> misbehave", "Microchip/Microsemi quirk", "SmartDebug returns zero",
  "eNVM", "boot mode", "FIC0 / AXI ID", "SmartHLS dead RTL", "FlashPro6 wedged".
---

# MPFS250T_ES platform gotchas

Hard-won + documented peculiarities of THIS silicon and toolchain. This board is a **PolarFire SoC
MPFS250T_ES, FCVG484, ES revision 1** (an *engineering sample*, not production silicon) driven over
a FlashPro6/J33. When a silicon symptom looks impossible, check here before assuming your design is
wrong — a good fraction of "impossible" behaviour on this board is a known ES erratum or a toolchain
quirk, not your RTL/firmware.

## How to use
1. Identify the symptom's domain (SmartDebug read / AXI / DDR / boot / eNVM / MSS clock / an IP block).
2. Read the matching reference file below for the known issue + workaround.
3. Only after ruling those out, treat it as a design bug (then use `fpga-ref-check` / `smartdebug-probe`).

## Sub-references
- **`references/es-silicon-errata.md`** — the MPFS250T_ES engineering-sample errata (ER0219) distilled,
  flagged by whether each applies to THIS project. Includes the one that bites us most: §3.8 SmartDebug
  JTAG reads can return **zero** and must be retried; plus MPU-disabled, MSS ≤600 MHz, no eNVM
  auto-program, ES operating limits (20–50 °C, no 1.05 V core).
- **`references/microchip-toolchain-and-ip.md`** — Microchip/Microsemi TOOL + IP peculiarities we have
  actually hit: SmartHLS mem↔stream kernels synthesize to dead RTL + the SIGN-EXTENSION miscompile
  (`(int16_t)(x>>16)` read unsigned → detect saturated ~50%); SmartDebug design-DB must match the
  programmed bitstream; Libero silently programs timing-failing bitstreams + HDL-core caching; FlashPro6
  USB-HID wedge behaviour; CoreFFT in-place SLOWCLK ≤ CLK/8 + MEMBUF overwrite hazard + the gearbox
  READ_OUTP/DATAO-latency trap; FIC_0 4-bit-ID truncation; FIC0 non-coherence; boot-mode-0 = the only
  JTAG-haltable state; and the on-target CRC32 mailbox for fast JTAG-load verification.
- **`references/silicon-debug-methodology.md`** — HOW to debug the datapath without chasing phantoms:
  value-level (not correlation) testing; build a bit-accurate silicon-MIRROR (`silicon_emulator.py`) and
  match it to golden before comparing to silicon; the golden-ORIENTATION gremlin (board = fft2.T +
  fftshift/flip/offset — the #1 false-alarm; run an exhaustive orientation scan); JTAG/gdb hygiene
  (NEVER SIGTERM gdb mid-JTAG → wedges the fabric; background board jobs; guard `call` behind a
  done-check); firmware value-test entry points ('FTES'/mailbox/runtime knobs incl. detect_mode CPU fallback).

## The short list (read the sub-files for detail + workarounds)
- **Debug by VALUE, not correlation** (scale/phase/orientation-invariant → hides real bugs). Build a
  bit-accurate silicon mirror, match it to golden, then diff silicon vs mirror. Always find the correct
  golden orientation (transpose+fftshift+offset) before declaring divergence. See silicon-debug-methodology.md.
- **NEVER SIGTERM/`timeout`-kill gdb mid-JTAG** → wedges the FABRIC (hart reset won't clear it; needs
  power-cycle). Run board jobs in the background; guard gdb `call` behind a completion check (this gdb
  crashes on inferior-call while the hart runs).
- **SmartDebug reads can be garbage for TWO reasons**: (a) ES §3.8 — a fabric APB DRI write can corrupt a
  JTAG read → returns 0 → just re-read; (b) the SmartDebug design database must match the PROGRAMMED
  bitstream (wrong Libero project = plausible-looking garbage). Rule out both before trusting a probe.
- **Never `taskkill /F` openocd/gdb** → wedges the FlashPro6 DM; a board power-cycle alone does NOT clear
  it — replug the FP6 USB.
- **Verify TIMING MET (setup + hold)** before trusting any silicon result — Libero programs failing
  bitstreams silently.
- **SmartHLS mem↔stream kernels are dead RTL on this toolchain** — the feeder (mem→stream) and any
  stream-master output must be hand-written Verilog. (mem→mem HLS kernels are fine.) Also value-check
  every HLS kernel's OUTPUT on silicon after a rebuild — casts/sign-extension miscompile silently
  (the detect `(int16_t)(x>>16)` read unsigned; cosim + corr both passed).
- **CPU-FALLBACK to isolate a suspect fabric kernel**: reimplement it on the MSS behind a runtime mode
  flag (detect_mode/fft_mode) and A/B vs the fabric — isolates the fault AND gives a working silicon
  fallback with no fabric rebuild. Firmware-only edits: `make all` (SoftConsole `build_tools/bin`) →
  `run_program.sh` (mpfsBootmodeProgrammer). See silicon-debug-methodology.md §5a.
- **eNVM**: never use boot auto-program/auto-update (ES §3.11); flash via `mpfsBootmodeProgrammer`
  (boot mode 1 = app that cooperates with JTAG halt; boot mode 0 = WFI).
- **Read the IP User Guide + golden TB first** (`reference/*_UG.txt`); most "hard IP" stalls are a
  handshake/config detail, not a fundamental limit — see the CoreFFT gearbox fix.
