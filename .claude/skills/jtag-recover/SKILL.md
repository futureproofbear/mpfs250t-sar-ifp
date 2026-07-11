---
name: jtag-recover
description: >-
  Safely tear down a wedged or stuck JTAG session (openocd + gdb over FlashPro6) and decide the
  correct recovery, without wedging the FlashPro6 further. Use when a gdb run hangs, openocd is
  orphaned/unresponsive, or the board won't halt/connect. Triggers: "gdb is stuck", "openocd
  hung", "clean up the jtag", "board won't connect", "flashpro wedged".
---

# jtag-recover

Safe teardown + recovery for a stuck JTAG toolchain on the PolarFire SoC SAR board. The whole
point is to NOT compound the problem: force-killing openocd mid-operation wedges the FlashPro6
DM, and a board power-cycle alone does not clear that. Reference: runbook §1.

## Diagnose first (don't kill blindly)
- Read the openocd log tail. If its mtime stopped growing right after connect (tap found +
  register enumeration + "Disabling abstract command...") and never reached `reset halt`, gdb
  wedged at CONNECT — usually a marginal FlashPro6/DM state, not the design.
- If the log shows arm/flush activity then froze, it wedged mid-test (e.g. `flush_l2_cache` on a
  wedged FIC0 transaction — that hangs ~5 min un-haltably).

## Ordered teardown (least-invasive first)
1. Try the CLEAN path: telnet `shutdown` to openocd port 4444
   (`python -c "import socket,time;s=socket.create_connection(('127.0.0.1',4444),3);time.sleep(.3);s.recv(4096);s.sendall(b'shutdown\n');time.sleep(1)"`).
   NOTE: run_corefft_iso.sh's openocd has NO telnet 4444 — this will fail there. Add
   `-c "telnet_port 4444"` to that openocd launch so future runs can stop gracefully.
2. If no telnet: kill **gdb (the client) FIRST** (`taskkill //PID <gdb> //F`) — this does NOT
   touch the FlashPro6. Then try a fresh gdb `monitor shutdown` to release openocd cleanly.
3. Only if openocd is still orphaned + idle (log not growing for minutes = no DMI op in flight),
   terminate it. Killing an IDLE openocd is far lower risk than mid-operation.
4. Confirm no `gdb`/`openocd` processes remain.

## Recovery decision
- Wedged at connect after a fresh board power-cycle, OR you had to force-kill openocd:
  **unplug/replug the FlashPro6 USB, THEN power-cycle the board.** The FP6 is USB-powered and
  independent of the board — a board power-cycle alone does NOT clear an FP6 HID wedge.
- Wedged mid-test on a fabric AXI transaction (flush hung): power-cycle the board to clear the
  wedged FIC0/DDR transaction, then re-run with a SINGLE frame (`CASES=impulse`).

## Never
- Never `taskkill /F` openocd while it holds a DMI operation. Never use PowerShell (blocked;
  use cmd/git-bash). Never leave orphaned processes for the user to clean up.
