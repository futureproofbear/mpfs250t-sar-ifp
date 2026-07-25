---
name: microchip-iso-test-harness
description: >-
  The Microchip-toolchain HOW for running a JTAG silicon iso-test on a PolarFire SoC / Microchip
  FPGA board: OpenOCD + gdb over a FlashPro6 programmer, the exact command patterns, telnet-based
  graceful shutdown, and FIC/DDR coherency handling. Complements the vendor-agnostic
  kernel-isolation-testing methodology (what an iso-test is and why) with the concrete Microchip
  mechanics (how to actually run one). Triggers: "run the iso-test", "test on silicon with
  OpenOCD", "FlashPro6 gdb session", "openocd -f efp6", "poke a fabric kernel over JTAG".
---

# microchip-iso-test-harness

This skill is the Microchip-tool-specific counterpart to the vendor-agnostic
`kernel-isolation-testing` methodology. That skill covers the *concept* (isolate one kernel/IP,
drive it directly, read its output directly, pick the smallest decisive case, capture decisive
signals before a risky teardown step). This skill covers the *mechanics* of doing that over
OpenOCD + gdb + a Microchip FlashPro6 programmer specifically.

## Prerequisites (confirm first)

- Board powered ON; fabric programmed with the build under test; the on-chip debug application
  (whatever eNVM/boot-mode image the JTAG debug session needs) must actually cooperate with a JTAG
  halt request — never a Hart Software Services (HSS)-only build, which commonly can't halt at all.
- No stale `openocd` process already running (`tasklist | grep openocd` on Windows, or the
  equivalent process check on your platform).

## Command patterns

Launch OpenOCD against your board's config, with a telnet port exposed so the session can be
stopped gracefully later:
```bash
"<openocd-install>/bin/openocd.exe" -s "<openocd-install>/openocd/scripts" -f <your-board>.cfg -c "telnet_port 4444"
```
If your OpenOCD build is a stock/vendor-bundled one that lacks your board's `.cfg`, you may need a
custom OpenOCD build (or a config file addition) — check whether the stock SoftConsole/vendor
OpenOCD ships a config matching your exact board before assuming a target-support gap is a hardware
problem.

Register/memory reads over the resulting Tcl RPC interface: some OpenOCD builds' `mdw` command has
been observed to silently produce no output. If that happens, use `mem2array` instead:
```tcl
mem2array v 32 <addr> 1
echo [format ">>> value = 0x%08x" $v(0)]
mem2array r 32 <addr> <count>          ;# bulk read; parse in a Tcl loop
```

Writes via `mww <addr> <val>` work for non-cached/fabric-side registers reached through a
control-plane interconnect path. For a write meant to be visible to a running hart's CACHED view of
memory (e.g. a mailbox word the firmware polls), a bare sysbus `mww` may NOT be coherent with what
the hart sees — the write needs to go through the hart's own debug view (i.e. via gdb / a verified
program-buffer write) instead, or the firmware must itself invalidate before reading. Check your
project's coherency model before assuming a raw `mww` is visible to firmware.

## Procedure

1. Pick the smallest decisive case (kernel-isolation-testing's own guidance) — for a JTAG-driven
   test this specifically also protects the JTAG link itself: a large multi-transaction run is more
   likely to leave a bus transaction stuck mid-flight (wedging the fabric) than a single minimal
   case is.
2. Run the test IN THE BACKGROUND so it can self-terminate via its own clean shutdown sequence
   rather than being killed externally (see `flashpro6-jtag-recovery` for why external kill is
   dangerous here specifically). Watch OpenOCD's OWN log (it flushes live) rather than gdb's stdout
   piped through a filter — a filtering pipe (e.g. `| grep`) commonly block-buffers and hides the
   difference between "still connecting" and "wedged."
3. Capture the decisive pass/fail signals (busy/done flags at known checkpoints, a raw output dump)
   in the gdb script BEFORE any coherency-related cleanup step (an evict/flush) that is itself known
   to sometimes hang — so the run still produces usable data even if that step hangs.
4. Report per test: busy/done signal states, output sample values, comparison against expected/
   golden values for that isolated stage, and PASS/FAIL.

## Hard rules (NEVER violate — see `flashpro6-jtag-recovery` for the full recovery procedure)

- NEVER force-kill OpenOCD or gdb — it can wedge the FlashPro6 DM. Clean stop = gdb's own `monitor
  resume` + `monitor shutdown`, or a telnet `shutdown` sent to OpenOCD's telnet port.
- If forced to kill: gdb (the client) first, then OpenOCD. A wedged FlashPro6 needs a USB replug
  PLUS a board power-cycle — a board power-cycle alone does not clear an FP6 wedge.
- On a non-coherent fabric-to-memory path, flush/invalidate before arming (push fresh input) and
  before readback (evict stale cached destination data) — check your MSS/interconnect documentation
  for which paths on your specific SoC are coherent vs. not; do not assume.
- Some gdb builds crash on an inferior function call (`call <fn>`) if the target hart is
  mid-execution rather than cleanly halted. Guard any such call behind a completion-flag check, and
  capture a raw pre-call dump as a hang-proof fallback.
- On Windows, a Windows-native gdb build needs native (`C:/...`) paths for restore/dump/ELF
  arguments, not MSYS-style (`/c/...`) paths.
- Always leave the toolchain shut down cleanly at the end; confirm no orphaned gdb/OpenOCD processes
  remain before starting the next run.

## After

If a new gotcha or a reusable command pattern comes out of a session, write it into your project's
own runbook the same session — a hard-won JTAG-session detail that isn't captured immediately tends
to get rediscovered at full cost later.

See also: `kernel-isolation-testing` (the underlying methodology), `flashpro6-jtag-recovery` (what
to do when this goes wrong), `smartdebug-active-probe` (follow-up when JTAG register reads alone
aren't enough internal visibility), `value-level-verification` (what to check for once output is
readable).
