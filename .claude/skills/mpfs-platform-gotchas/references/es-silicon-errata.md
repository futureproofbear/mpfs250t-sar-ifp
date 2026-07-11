# MPFS250T_ES engineering-sample errata (ER0219)

Source: `reference/microsemi_polarfire_soc_fpga_egineering_samples_errata_er0219_v1.pdf`
(extracted `.txt` alongside). This board = **MPFS250T, FCVG484EES, ES revision 1**. All items below
are ES-only and are "fixed in production silicon" — so a design that depends on a workaround may not
port cleanly to production (regenerate the MSS configurator + bitstream for the production part).

## Operating limits (ES only — §2.1/2.2)
- Junction temp **20 °C to 50 °C** (program/erase and operation). Tighter than production.
- Core **VDD = 1.0 V ± 0.03 V**; **1.05 V is NOT supported on ES** (VDDA supports both). Don't run the
  ES core at 1.05 V.
- Device ID: "ES" appears in the temperature-grade field of the part marking.

## Errata that MATTER for this project (SAR data-plane, JTAG bring-up)

### §3.8 Fabric APB DRI writes corrupt SmartDebug JTAG/SPI reads → read returns ZERO  ⚠ HIGH RELEVANCE
A fabric DRI write to a PCIESS APB config block can corrupt a concurrent SmartDebug JTAG/SPI read; the
**read returns zero**. Workaround per the errata: **redo the SmartDebug read until the expected data is
received.** Practical implication for us: a SmartDebug Active-Probe that reads 0 / looks wrong may be
this erratum, NOT a real signal value — **read twice (already our habit) and distrust a lone zero**.
This is a SECOND cause of bad SmartDebug reads, on top of the design-DB-mismatch trap (see
`microchip-toolchain-and-ip.md`). Rule out both before trusting a probe.

### §3.2 AXI Switch Memory Protection Unit (MPU) is not operational
ES silicon has an AXI bus bug when the MPU rejects illegal messages, so the **MPU is disabled by the
startup firmware** — no access warnings/interrupts. Implication: don't rely on MPU protection on the
data plane; illegal AXI accesses won't be caught, they may just wedge the bus. Keep the fabric AXI
masters (feeder/unloader read/write) strictly in-range (a bad addr won't SLVERR politely).

### §3.11 Auto-program / auto-update of eNVM must NOT be used  ⚠ RELEVANT
Boot-initiated auto-program/auto-update of eNVM **fails** on ES. We already avoid this — flash via
`mpfsBootmodeProgrammer` (run_program.sh, boot mode 1) / fpgenprog, never boot auto-update.

### §3.4 MSS CPU frequency limited (≤ 600 / 625 MHz)
Max MSS CPU is 625 MHz (600 MHz if eMMC/SD used). Only relevant if changing MSS PLL clocking; the
allowed-frequency lists differ for eMMC/SD and CAN use. Keep MSS CPU within the tabulated set.

### §3.1 MSS cannot access System Controller SPI flash
DRI↔SPI RXFIFO returns bad data → the MSS can't read the external SPI flash via the system-controller
SPI over DRI. Only relevant if we boot/store from external SPI flash (we use eNVM + JTAG DDR load).

## Errata that are NOT relevant to us (noted for completeness)
- §3.3 MSS I2C needs core ≥2.0.108 (we don't use MSS I2C).
- §3.5 / §3.6 DRI interrupt line / DRI Error+Fault maintenance interrupt issues (we don't use DRI ints).
- §3.7 MSS GPIO must reset via CPU not fabric (`soft_reset_select` not 0) — only if using MSS GPIO.
- §3.9 System Controller suspend mode unsupported.
- §3.10 GEM 1Gbps half-duplex undersize-frame counter — no Ethernet data path (JTAG-only bring-up).
- §3.12 auto-update SPI master/slave contention — not using auto-update.

## §4 Transceivers + DDR
DDR memory interfaces are "reused from PolarFire FPGA, in the process of being validated" — expected to
work but not fully validated on ES. Our DDR training occasionally needs a clean power-cycle after
re-flashing the app; treat DDR bring-up as "usually fine, sometimes needs a power-cycle," consistent
with this not-fully-validated status.

## Porting note
Every workaround here is ES-specific. When moving to production silicon: retarget the correct device,
regenerate the MSS configurator + bitstream, and re-verify — an ES design is not guaranteed to port.
