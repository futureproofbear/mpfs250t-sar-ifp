---
name: smartdebug-probe
description: >-
  Produce a SmartDebug Active-Probe plan (exact net names from the PROGRAMMED design's netlist)
  and a decode table mapping readings to a verdict, then interpret the values the user reads
  back. Use when a fabric kernel/IP stalls and JTAG register reads aren't enough. Triggers:
  "probe the fabric", "smartdebug", "what nets should I read", "internal signal visibility".
---

# smartdebug-probe

Plans and interprets SmartDebug Active-Probe sessions for the SAR fabric. You cannot drive the
GUI — produce an exact probe list for the user to add/read, then decode. See
`docs/fpga/history/SMARTDEBUG_RUNBOOK.md` (ARCHIVED — its DMA one-hot decodes describe a removed IP; this skill is authoritative).

## THE critical rule (cost a full round on 2026-07-09)
The SmartDebug design database MUST match the bitstream programmed on the board. This repo has
several Libero projects (`libero_ffv` = current feeder-v build; `libero_sar` = older DMA build;
`libero_corefft*`). Their netlists differ — `libero_sar` has `have_beat`/DMA nets that DO NOT
exist in the programmed `libero_ffv` fabric, and probing the wrong DB returns plausible-looking
GARBAGE. So:
1. Determine which bitstream is programmed (ask, or infer from what the JTAG test drove — e.g. a
   working `fft_feeder_v` busy=0 implies `libero_ffv`).
2. Resolve every net name from THAT project's `synthesis/SAR_TOP.vm` (grep the real signal
   names + instance prefixes: FFT/GBX/UNLD/FEED/ID_FIX).
3. Tell the user to launch SmartDebug FROM THAT project and confirm "design matches device"
   (no mismatch warning) before trusting any reading.

## Procedure
1. Arm the stall and make it DC-stable (a single frame via the `silicon-iso-test` skill), then
   ensure openocd is shut down — SmartDebug and openocd cannot share the FlashPro6.
2. Delegate to the `smartdebug-planner` agent, or build the plan inline: map the symptom to a
   MINIMAL set of decisive, preferably REGISTERED nets (survive P&R, DC-stable in a permanent
   stall). For each: search substring, instance, and value->meaning.
3. Give a decode TABLE (observation -> verdict -> next action) that bifurcates the candidates in
   as few reads as possible.
4. When values come back, cross-check the net-path prefixes match the programmed project, decode,
   and state the verdict + next probe.

## Notes
Active Probe reads static FF values over the fabric probe network — works even when a hart is
un-haltable and does not touch the RISC-V DMI. Combinational-only nets may not be probe-
accessible after synthesis; fall back to a nearby registered signal (e.g. a FIFO `wptr` instead
of a combinational `tvalid`).
