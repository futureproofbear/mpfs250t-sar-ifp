# mpfs250t

A Claude Code plugin capturing facts specific to **one exact chip/package/silicon-revision**:
PolarFire SoC **MPFS250T, FCVG484EES, ES revision 1** — an engineering sample, not production
silicon. This is the ER0219 engineering-sample errata catalog (SmartDebug-read corruption, MPU
disabled, eNVM auto-program prohibition, MSS clock ceiling, ES-only operating limits) distilled and
flagged by relevance, plus the note that every workaround here is ES-only and does not necessarily
carry over to production MPFS250T silicon.

None of the content in `microchip-fpga-soc` (tier 2) is duplicated here — that package is
deliberately scoped to behavior true for any PolarFire SoC part on Microchip's toolchain. This
package is the complementary, narrower layer: facts that are true only because of the specific
silicon revision, not the tool or the IP.

## Who this is for

Anyone bringing up or debugging **this exact die**: an MPFS250T_ES engineering sample in an
FCVG484EES package, ES revision 1 (e.g. an Icicle-style board using this specific part). If your
board uses a different PolarFire SoC die — a different MPFS250T revision, MPFS095T, or production
(non-ES) silicon — the errata in this package do not apply as-is; use tiers 1 and 2 only, and consult
that part's own errata sheet if one exists.

## Install

```
claude --plugin-dir /path/to/ai-framework/mpfs250t
```

This tier is meant to be combined with both tiers below it for the full stack on this exact part:

```
claude --plugin-dir /path/to/ai-framework/generic-fpga-soc \
       --plugin-dir /path/to/ai-framework/microchip-fpga-soc \
       --plugin-dir /path/to/ai-framework/mpfs250t
```

## What's in it

### Skills (`skills/`)

- **mpfs250t-es-errata** — the ER0219 (Microchip/Microsemi "PolarFire SoC FPGA Engineering
  Samples" errata) catalog distilled for this die: ES-only operating limits (20-50 degC junction
  temperature, 1.0 V +/- 0.03 V core with no 1.05 V support on ES), the §3.8 SmartDebug JTAG/SPI
  read-returns-zero erratum (fabric DRI writes corrupting a concurrent probe read), §3.2 MPU
  disabled on ES silicon, §3.11 no eNVM boot auto-program/auto-update, §3.4 MSS CPU clock ceiling
  (625 MHz, 600 MHz with eMMC/SD), §3.1 MSS-cannot-reach-external-SPI-flash, and §4's note that DDR/
  transceiver interfaces are not yet fully validated on ES — plus a completeness catalog of the
  remaining ER0219 items less likely to be hit. Every entry states the practical workaround and
  flags that it is ES-specific (may not be needed, or may behave differently, on production
  silicon).

## Three-tier framework

This package is **tier 3** — the narrowest and most specific of a 3-tier system built for FPGA/SoC
AI-assisted engineering work:

- **Tier 1 (`../generic-fpga-soc/`)** — vendor-agnostic methodology (reference-first verification,
  HLS-output distrust, value-level verification, kernel-isolation testing). Take it to any FPGA/SoC
  project regardless of vendor.
- **Tier 2 (`../microchip-fpga-soc/`)** — Microchip-toolchain-specific knowledge (Libero, SmartHLS,
  SmartDebug, FlashPro6/OpenOCD) that applies across the whole PolarFire SoC family, independent of
  exact die revision.
- **Tier 3 (this package, `mpfs250t`)** — facts true only for the exact MPFS250T_ES engineering-
  sample die/package this project runs on: its ER0219 silicon errata and ES-only operating limits.
  Layers on top of tiers 1 and 2; adds nothing that would apply to a different PolarFire SoC part.

A project on a different vendor's FPGA/SoC should take tier 1 only. A project on a different
Microchip PolarFire SoC part (a different die, or production rather than engineering-sample
silicon) should take tiers 1 and 2 only — this package's errata are specific to the ES revision of
MPFS250T and are not guaranteed to apply, and per ER0219 several are explicitly stated to be fixed
in production silicon. A project on the exact same MPFS250T_ES/FCVG484EES board this was extracted
from should take all three tiers together.
