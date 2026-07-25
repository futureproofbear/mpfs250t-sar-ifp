---
name: smartdebug-active-probe
description: >-
  Produce a Microchip SmartDebug Active-Probe plan (exact net names from the PROGRAMMED design's
  netlist) and a decode table mapping readings to a verdict, then interpret the values the user
  reads back, on a PolarFire SoC / Microchip FPGA design. Use when a fabric kernel/IP stalls and
  JTAG register reads aren't enough. Triggers: "probe the fabric", "smartdebug", "active probe",
  "what nets should I read", "internal signal visibility".
---

# smartdebug-active-probe

Plans and interprets Microchip SmartDebug Active-Probe sessions for an FPGA fabric design. You
cannot drive the SmartDebug GUI yourself — produce an exact probe list for the user to add/read,
then decode what comes back.

## THE critical rule

The SmartDebug design database MUST match the bitstream actually programmed on the board. Any
project that has accumulated multiple Libero project variants over its history (an older build
alongside a current one, or several experimental branches) will have netlists that DIFFER — nets
that existed under an older architecture (e.g. handshake/status signals from an IP block that has
since been removed) will NOT exist in a currently-programmed different project's fabric. Probing
from the wrong design database returns plausible-looking GARBAGE (it's a real, DC-stable value from
SOME net — just not the one you think you're reading). So:

1. Determine which bitstream/project is programmed right now (ask, or infer from what a JTAG test
   just drove — e.g. a specific status register reading a specific way implies a specific build).
2. Resolve every net name from THAT project's own synthesized netlist (grep the real signal names +
   instance prefixes out of the post-synthesis Verilog — never from memory or a different project's
   netlist).
3. Tell the user to launch SmartDebug FROM THAT project and confirm "design matches device" (no
   mismatch warning) before trusting any reading.

## Procedure

1. Arm the stall and make it DC-stable — drive the smallest test case that reproduces it (see
   `microchip-iso-test-harness`), then ensure any JTAG/OpenOCD debug session is shut down cleanly —
   SmartDebug and an OpenOCD session cannot share the same FlashPro6 physically.
2. Build the probe plan: map the symptom to a MINIMAL set of decisive, preferably REGISTERED nets
   (they survive place-and-route and stay DC-stable during a permanent stall). For each: give the
   search substring, the instance, and value -> meaning.
3. Give a decode TABLE (observation -> verdict -> next action) that bifurcates the candidates in as
   few reads as possible.
4. When values come back, cross-check the net-path prefixes actually match the programmed project,
   decode against the table, and state the verdict + the next probe.

## Notes

- Active Probe reads static flip-flop values over the fabric's own probe network — it works even
  when a hart/core is un-haltable and does NOT go through the processor's debug-module interface.
- Combinational-only nets may not be probe-accessible after synthesis/place-and-route; fall back to
  a nearby registered signal (e.g. a FIFO write-pointer register instead of a combinational
  valid/ready line).
- Treat any decode table from a previous debugging session as provisional, not permanent — if the
  design has changed (an IP removed, a net renamed, a project variant swapped), an old decode table
  can describe signals or IP that no longer exist in the current netlist and will silently apply to
  nothing.

See also: `microchip-iso-test-harness` (getting the stall into a DC-stable, probeable state),
`microchip-toolchain-quirks` (other Microchip toolchain/IP peculiarities worth ruling out before
trusting a probe result as a design bug).
