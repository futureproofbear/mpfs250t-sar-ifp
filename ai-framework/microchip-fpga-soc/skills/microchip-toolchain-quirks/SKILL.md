---
name: microchip-toolchain-quirks
description: >-
  Family-general Microchip Libero SoC / SmartHLS / SmartDebug / FlashPro6 toolchain quirks and
  PolarFire SoC IP peculiarities that apply across the PolarFire SoC family (not tied to one exact
  die revision). Load BEFORE bringing up or debugging anything on a PolarFire SoC board, to avoid
  re-hitting known Microchip-toolchain / IP behaviour that looks like a design bug but isn't.
  Triggers: "PolarFire SoC", "Microchip/Microsemi toolchain quirk", "SmartDebug returns garbage",
  "boot mode", "FIC / AXI ID", "CoreFFT in-place", "SmartHLS dead RTL", "Libero silent timing fail".
---

# Microchip toolchain quirks (PolarFire SoC family)

Hard-won Microchip TOOLCHAIN and IP peculiarities that generalize across the PolarFire SoC family
(any die: MPFS250T, MPFS095T, etc.) using this toolchain. This deliberately excludes anything
specific to one exact die's engineering-sample silicon errata — that belongs in a die-specific
package layered on top of this one. If you hit a symptom that looks impossible, check here before
assuming your RTL/firmware is wrong; a good fraction of "impossible" toolchain behaviour is a known
quirk, not a design bug.

## Libero SoC

- **Libero will silently PROGRAM a timing-failing bitstream.** It does not refuse to export or
  program a design that failed setup or hold timing — your own build gate has to check and refuse
  explicitly. "Build completed" and "device programmed" are not evidence of "design is correct." See
  the `libero-build` agent for the full timing-gate discipline.
- **Libero project HDL-core caching**: a hand-registered HDL core (`create_hdl_core` +
  `hdl_core_add_bif`) can be cached by the project and NOT pick up a source-file edit unless the core
  is explicitly re-registered/refreshed. If a Verilog-source change doesn't seem to reach the
  synthesized netlist, check whether the HDL core needs re-registering rather than assuming synthesis
  itself is broken.

## SmartDebug

- **The SmartDebug design database must match the bitstream actually programmed on the board.**
  Probing from a different (even a very similar, previously-built) project's netlist returns
  plausible-looking garbage rather than an error. See the `smartdebug-active-probe` skill.

## FlashPro6

- **FlashPro6 has USB-HID-level wedge behaviour** independent of the target board: a board
  power-cycle alone does not clear a wedge caused by force-killing OpenOCD mid-operation; the
  FlashPro6 itself needs a USB replug. See `flashpro6-jtag-recovery`.
- Only one tool can own the FlashPro6/JTAG link at a time — a Libero `PROGRAMDEVICE` operation and a
  live OpenOCD session (or a SmartDebug session) cannot run concurrently against the same probe.

## SmartHLS

- **Pure memory-to-stream / stream-to-memory HLS kernels have been observed to synthesize to dead
  RTL** on this toolchain; a kernel that must stream data directly to/from an AXI-initiator interface
  (as opposed to a mem-to-mem read-compute-write shape) may need to be hand-written in RTL instead.
  See `smarthls-kernel-authoring` for the full mis-synthesis-class list and the pragma reference.

## Boot mode / JTAG halt interaction (MSS architecture)

- On PolarFire SoC's MSS, whether a hart can be halted over JTAG depends on the boot-mode image
  currently resident, not just on the fabric being programmed correctly. A Hart Software Services
  (HSS)-only image commonly refuses a JTAG halt outright. A cooperating application image (built to
  yield/WFI or otherwise cooperate with debug halt requests) is generally required for a JTAG
  debug session to reliably halt a hart. If gdb reports it cannot halt a hart, check which boot-mode
  image is actually resident before suspecting a wedged FlashPro6 or a hardware fault.
- Firmware-only changes (no fabric rebuild needed) are typically rebuilt with the SoftConsole
  toolchain (`make all` against its bundled build tools) and reprogrammed via Microchip's boot-mode
  programmer utility (`mpfsBootmodeProgrammer` or equivalent) — much faster than a full Libero
  rebuild when you only need to change what the MSS application does, not the fabric.

## SoftConsole / GDB

- **The RISC-V gdb bundled with SoftConsole (riscv64, toolchain build 8.3.0) crashes on an
  inferior `call <fn>` (a `find_inferior_pid` assertion) if the target hart is mid-execution**
  (e.g. a poll loop that hasn't reached its completion point yet). This is a bug in that specific
  gdb build, not a JTAG/hardware fault, and reproduces on any PolarFire SoC board using the same
  SoftConsole version. Guard every inferior `call` behind a completion-flag check (`$done`-style)
  so it only ever runs while the hart is cleanly halted at a known point, not mid-execution.

## FIC / interconnect architecture (general MSS characteristics)

- PolarFire SoC's Fabric Interface Controllers (FICs) connecting the MSS to fabric are commonly
  documented as **non-coherent** with the MSS's own cache hierarchy on at least some paths — a fabric
  write to DDR is not automatically visible to a hart's cached view without an explicit flush/
  invalidate, and vice versa. Confirm which of your design's specific FIC paths are coherent (check
  your MSS configuration) rather than assuming; treat non-coherence as the default expectation.
- FIC AXI-ID width has been observed to be narrower than a full AXI ID field on at least some FIC
  interfaces (ID truncation) — if multiple concurrent outstanding transactions on the same FIC need
  to be distinguished by ID, check the actual ID width the FIC interface provides rather than
  assuming your source IP's full ID width survives the crossing.

## CoreFFT (Microchip hard IP)

- CoreFFT's **in-place mode has a documented slow-clock ratio ceiling relative to its main clock**
  (check the CoreFFT User Guide for the exact ratio for your configuration) — driving the slow clock
  faster than that ceiling is a protocol violation, not just a performance choice.
- CoreFFT's in-place memory buffer has an overwrite hazard if the handshake around it isn't followed
  exactly as documented — read the CoreFFT User Guide's handshake section (not just the block
  diagram) before wiring a custom adapter around it.
- **The output-valid/output-ready latency trap:** CoreFFT's `DATAO_VALID` trails `READ_OUTP` by a
  fixed pipeline latency (on the order of a few cycles — verify the exact count for your
  configuration in the User Guide). An adapter that gates its capture directly on `READ_OUTP`
  rather than on `DATAO_VALID` drops the in-flight beats the instant it backpressures, causing data
  loss and real/imaginary-pair desync downstream. Capture on `DATAO_VALID`, and de-assert
  `READ_OUTP` early enough (reserving at least the pipeline-latency's worth of buffer slots) that no
  in-flight sample arrives to a full buffer — this is a handshake detail invisible to a purely
  functional (non-timing-aware) model of the interface, and only shows up under real backpressure.

See also: `libero-build` (timing-gate discipline), `smarthls-kernel-authoring` (SmartHLS pragma
reference + mis-synthesis classes), `smartdebug-active-probe` and `microchip-iso-test-harness`
(the debug workflows these quirks most often bite), `flashpro6-jtag-recovery` (FlashPro6-specific
recovery). Die-specific engineering-sample silicon errata is intentionally NOT covered here — check
your die-specific package/errata sheet for that.
