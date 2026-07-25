---
name: mpfs250t-es-errata
description: >-
  Die/package-specific facts for the exact PolarFire SoC MPFS250T_ES engineering-sample part
  (FCVG484, ES revision 1): the ER0219 engineering-sample errata catalog, ES-only operating limits
  (temperature, core voltage, MSS clock ceiling), and which of those workarounds do NOT carry over
  to production silicon. Load it BEFORE bringing up or debugging anything on THIS exact die, to
  avoid re-hitting a known ES-silicon erratum. Triggers: "MPFS250T_ES", "engineering sample / ES
  silicon", "ER0219", "errata", "SmartDebug returns zero", "MPU disabled", "eNVM auto-program",
  "MSS clock limit", "ES operating limits / temperature / voltage", "does this port to production
  silicon".
---

# MPFS250T_ES engineering-sample errata

Facts specific to the **exact die/package this project runs on** — PolarFire SoC
**MPFS250T, FCVG484EES, ES revision 1** (an engineering sample, not production silicon). Everything
here is scoped to ER0219 (the Microchip/Microsemi PolarFire SoC FPGA Engineering Samples errata
document) or to an ES-only operating limit. This is narrower than `microchip-toolchain-quirks`
(family-general PolarFire SoC toolchain/IP behavior) — check that package first for anything not
listed here; it deliberately does not duplicate die-specific errata.

## How to use
1. Check whether your symptom's domain appears below (SmartDebug read, MPU, eNVM programming, MSS
   clock, SPI-flash boot, DDR/transceiver bring-up).
2. If it does, the workaround below is a known ES erratum, not a design bug — apply it and move on.
3. If it doesn't, this is not necessarily "ruled out" — it may be family-general (check
   `microchip-toolchain-quirks`) or a genuine design bug (escalate to `fpga-ref-verifier` /
   `smartdebug-active-probe`).
4. **Porting note**: every workaround below is ES-specific and is stated by ER0219 to be "fixed in
   production silicon." A design that depends on one of these workarounds is not guaranteed to port
   cleanly to a production MPFS250T — retarget the die, regenerate the MSS configurator + bitstream,
   and re-verify.

Source: Microchip/Microsemi "PolarFire SoC FPGA Engineering Samples" errata, document ER0219 v1.

## ES-only operating limits (ER0219 §2.1/2.2)
- Junction temperature **20 °C to 50 °C** for both programming/erase and operation — tighter than
  the production part's range.
- Core **VDD = 1.0 V ± 0.03 V**; **1.05 V core is NOT supported on ES silicon** (VDDA supports both
  voltages). Do not configure/run the ES part's core rail at 1.05 V.
- Device marking: "ES" appears in the temperature-grade field of the part marking — a way to
  positively identify an ES unit versus production silicon by physical inspection.

## Errata relevant to fabric/DDR/JTAG bring-up

### ER0219 §3.8 — Fabric APB DRI write corrupts a concurrent SmartDebug JTAG/SPI read (read returns ZERO)
A fabric DRI write to a PCIESS APB config block can corrupt a concurrent SmartDebug JTAG/SPI read;
the read comes back as **zero**, not an error. Microchip's documented workaround: **redo the
SmartDebug read until the expected data is received.** In practice: a SmartDebug Active-Probe
reading `0` (or an implausible value) may be this erratum firing, not a real signal value — always
re-read before trusting a zero/suspicious probe result. This is a DIE-SPECIFIC cause of bad
SmartDebug reads, distinct from (and in addition to) the family-general "design database must match
the programmed bitstream" trap in `microchip-toolchain-quirks` — rule out both before trusting a
probe.

### ER0219 §3.2 — AXI Switch Memory Protection Unit (MPU) is not operational
ES silicon has an AXI-bus bug triggered when the MPU rejects an illegal message, so on this
die/board the **MPU is disabled by the startup firmware** and gives no access warnings or
interrupts. Practical implication: do not rely on MPU protection on the data plane on this part —
illegal AXI accesses will not be caught or reported; they may simply wedge the bus. Keep every
fabric AXI master's address range strictly in-bounds by construction.

### ER0219 §3.11 — Auto-program / auto-update of eNVM must NOT be used
Boot-initiated auto-program/auto-update of eNVM **fails** on this ES silicon. Program eNVM via an
explicit tool flow instead (e.g. Microchip's boot-mode programmer utility, boot mode 1) — never rely
on boot-time eNVM auto-update/auto-program on this die.

### ER0219 §3.4 — MSS CPU frequency ceiling: 625 MHz (600 MHz if eMMC/SD is used)
Maximum MSS CPU clock on this ES part is 625 MHz; if the design uses eMMC or SD, the ceiling drops
to 600 MHz, and only a specific tabulated set of frequencies is permitted for eMMC/SD or CAN use.
Relevant any time the MSS PLL/clock configuration changes — keep the MSS CPU clock within the
ER0219-tabulated allowed set for this die, not just "under some round number."

### ER0219 §3.1 — MSS cannot access the System Controller's external SPI flash
The DRI-to-SPI RXFIFO path returns bad data, so the MSS cannot reliably read external SPI flash via
the system-controller SPI-over-DRI path on this die. Only relevant to a design that boots or stores
data from external SPI flash through that path (a design using eNVM + JTAG-loaded DDR instead is not
affected).

### ER0219 §4 — Transceivers + DDR interfaces are not fully validated on ES
ER0219 states the DDR memory interfaces on this part are "reused from PolarFire FPGA, in the process
of being validated" for MPFS250T_ES — i.e. expected to work, but without full validation sign-off
the way production silicon has. Practical read: treat occasional DDR-training flakiness after a
reflash as consistent with this not-fully-validated status (a clean power-cycle is a reasonable
first recovery step) rather than immediately assuming a design bug.

## Other ES errata in ER0219 (cataloged for completeness — not all projects will hit these)
- **§3.3** MSS I2C requires core revision ≥ 2.0.108.
- **§3.5 / §3.6** DRI interrupt line, and DRI Error+Fault maintenance-interrupt, issues.
- **§3.7** MSS GPIO must be reset via the CPU, not the fabric (`soft_reset_select` must not be 0).
- **§3.9** System Controller suspend mode is unsupported on ES.
- **§3.10** GEM (1 Gbps) half-duplex undersize-frame counter issue.
- **§3.12** Auto-update SPI master/slave contention (only relevant if using eNVM auto-update — see
  §3.11 above for why that path should be avoided on ES entirely).

Each of the above is a genuine ES-only erratum per ER0219; consult the errata document directly for
the exact mechanism if your design touches that peripheral.
