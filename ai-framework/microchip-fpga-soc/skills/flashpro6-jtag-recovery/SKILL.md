---
name: flashpro6-jtag-recovery
description: >-
  Safely tear down a wedged or stuck JTAG session (OpenOCD + gdb over a Microchip FlashPro6
  programmer) on a PolarFire SoC / Microchip FPGA board, and decide the correct recovery, without
  wedging the FlashPro6 further. Use when a gdb run hangs, OpenOCD is orphaned/unresponsive, or the
  board won't halt/connect. Triggers: "gdb is stuck", "openocd hung", "clean up the jtag",
  "board won't connect", "flashpro wedged", "FlashPro6".
---

# flashpro6-jtag-recovery

Safe teardown + recovery for a stuck JTAG toolchain (OpenOCD + gdb) talking to a Microchip
FlashPro6 programmer on a PolarFire SoC (or other Microchip FPGA/SoC) board. The whole point is to
NOT compound the problem: force-killing OpenOCD mid-operation wedges the FlashPro6's debug-module
(DM) state, and a board power-cycle alone does not clear that.

## Diagnose first (don't kill blindly)

- Read the OpenOCD log tail. If its last-modified time stopped growing right after connect (tap
  found + register enumeration + something like "Disabling abstract command...") and it never
  reached a `reset halt`, gdb wedged at CONNECT — usually a marginal FlashPro6/DM state, not the
  target design.
- If the log shows some test activity (an arm/flush/transaction sequence) then froze, it wedged
  MID-TEST — e.g. a cache-flush or similar routine hung on a stuck fabric/AXI transaction, which can
  hang un-haltably for several minutes before you should even suspect it as wedged rather than slow.

## Ordered teardown (least-invasive first)

1. Try the CLEAN path: send a `shutdown` command over telnet to OpenOCD's telnet port (commonly
   4444), e.g.:
   ```
   python -c "import socket,time;s=socket.create_connection(('127.0.0.1',4444),3);time.sleep(.3);s.recv(4096);s.sendall(b'shutdown\n');time.sleep(1)"
   ```
   If your OpenOCD launch doesn't expose a telnet port, this will fail there — add
   `-c "telnet_port 4444"` to the OpenOCD launch command in your test script so future runs can be
   stopped gracefully.
2. If there's no telnet port available: kill **gdb (the client) FIRST** — this does NOT touch the
   FlashPro6. Then try a fresh gdb connection issuing `monitor shutdown` to release OpenOCD cleanly.
3. Only if OpenOCD is still orphaned AND idle (log not growing for several minutes = no DMI
   operation actually in flight), terminate it directly. Killing an IDLE OpenOCD is far lower risk
   than killing one mid-operation.
4. Confirm no `gdb`/`openocd` processes remain running.

## Recovery decision

- Wedged at CONNECT after a fresh board power-cycle, OR you had to force-kill OpenOCD: **unplug and
  replug the FlashPro6's USB connection, THEN power-cycle the board.** The FlashPro6 is USB-powered
  and electrically independent of the target board — a board power-cycle alone does NOT clear an
  FP6 USB-HID-level wedge.
- Wedged MID-TEST on a fabric/AXI transaction (e.g. a flush routine hung): power-cycle the board to
  clear the wedged bus transaction, then re-run with the smallest possible test case (a single
  frame/burst/transaction) rather than the full multi-transaction run that triggered the wedge.

## Never

- Never force-kill (SIGKILL-equivalent, e.g. `taskkill /F` on Windows) OpenOCD while it holds a
  DMI/JTAG operation in flight.
- Never leave orphaned `gdb`/`openocd` processes for the user to clean up — confirm the process list
  is clear before handing control back.
- On Windows specifically: avoid PowerShell for this kind of process cleanup if it's blocked/
  disallowed in your environment; `cmd` or a POSIX shell (git-bash) work for the same `taskkill` /
  process-list commands.

See also: `microchip-iso-test-harness` (the normal, non-wedged run this skill recovers FROM), the
vendor-agnostic `kernel-isolation-testing` methodology's debug-session-hygiene rules (this skill is
the Microchip/FlashPro6-specific instance of that same discipline).
