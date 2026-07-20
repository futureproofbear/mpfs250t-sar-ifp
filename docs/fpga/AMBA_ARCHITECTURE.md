# AMBA Architecture & Design Implementation — SAR-on-PolarFire-SoC

Definitive reference for the on-chip AMBA (AXI4 / AXI4-Lite / AXI4-Stream) architecture of the SAR
fabric accelerator (`SAR_TOP` SmartDesign, Libero SoC 2025.2, MPFS250T_ES Icicle Kit). Canonical
wiring source: [`mpfs/fpga/build_sartop.tcl`](../../mpfs/fpga/build_sartop.tcl) (+ the later `ID_FIX`
and AXI4-Lite-target edits — see [dma_fix_plan.md](history/dma_fix_plan.md), [id_restore_integration.md](history/id_restore_integration.md)).

> **Update 2026-07-04:** the `DMA` (`AXIDMA_C0` / CoreAXI4DMAController) documented below as the
> FFT-stream S2MM writeback is **removed** — it deadlocked on the 2nd back-to-back AXI4-Stream S2MM
> transaction (3 firmware/TDEST workarounds failed). It is **replaced by the HLS `fft_unloader` kernel**:
> an AXI4-Stream **slave** input (consumes the gearbox output stream) + a plain AXI4 **write master** to
> DDR (control base `K_FFT_UNLOADER @0x6000_5000`, no descriptors/TLAST) — the same pattern as the other
> HLS kernels, so it sits on the DIC as a data initiator and on the CIC as a control target just like
> `CT/WIN/DET/RES/FEED`. The gearbox (`corefft_stream64_adapter.v`) also gained an **elastic output skid
> FIFO** (64-deep) so it drains CoreFFT unconditionally and backpressures the unloader instead of wedging
> CoreFFT's `read_outp`. Wherever §1–§10 below say "DMA (S2MM)", "AXI4-Lite (1) DMA ctrl", or route the FFT
> stream into a DMA target, read it as the `fft_unloader`. Fabric-level change; firmware unchanged. See
> [`../PROJECT_SOURCE_OF_TRUTH.md`](../PROJECT_SOURCE_OF_TRUTH.md) "CURRENT STATUS".

## 1. Topology overview

```
                         ┌──────────────── PolarFire SoC MSS (5× RISC-V) ────────────────┐
                         │   FIC_0_AXI4_INITIATOR (ctrl master)   FIC_0_AXI4_S (DDR slv) │
                         └──────────┬─────────────────────────────────────▲─────────────┘
            CONTROL PLANE           │ (AXI4-Lite, 32b)                     │ DATA PLANE (AXI4, 64b)
                                    ▼                                      │  ▲ ID_FIX (9↔4 ID restore)
                         ┌──────────────────┐                   ┌─────────┴──┴───────┐
                         │  CIC  AXIIC_CTRL │  1 init / 6 targ  │   DIC   AXIIC_C0   │ 6 init / 1 targ
                         │  CoreAXI4ICon 3.0│                   │  CoreAXI4ICon 3.0  │
                         └─┬─┬─┬─┬─┬─┬──────┘                   └─▲─▲─▲─▲─▲─▲────────┘
              target0..5  │ │ │ │ │ │ (AXI4 ×5 + AXI4-Lite ×1)     │ │ │ │ │ │ initiator0..5 (AXI4)
            0x6000_0000 → │ │ │ │ │ └─ DMA ctrl 0x6000_5000        │ │ │ │ │ └─ DMA  (S2MM writeback)
                          │ │ │ │ └─ FEED 0x6000_4000          CT ─┘ │ │ │ └─ FEED
                          │ │ │ └─ RES 0x6000_3000             WIN ──┘ │ └─ RES
                          │ │ └─ DET 0x6000_2000               DET ────┘ (each kernel: ctrl target
                          │ └─ WIN 0x6000_1000                              on CIC + data initiator
                          └─ CT  0x6000_0000                                on DIC)

      STREAM PATH:  FEED ──AXI4-Stream──► GBX(gearbox) ──native──► CoreFFT ──native──► GBX
                                                                              └──AXI4-Stream──► DMA (stream target)
```

## 2. Components (`SAR_TOP` instances)

| Inst | IP / module | Version | Role |
|------|-------------|---------|------|
| `MSS` | ICICLE_MSS (PolarFire SoC MSS) | — | 5× RISC-V (1×E51 + 4×U54); FIC_0 = fabric bridge (AXI4 initiator for control, AXI4 target for DDR) |
| `CCC` | PF_CCC_C0 (PLL) | — | `OUT0_FABCLK_0`=**62.5 MHz** fabric clock; `OUT1_FABCLK_0`=**7.8125 MHz** (fabric/8) for CoreFFT SLOWCLK (was 125 / 15.625 MHz — lowered to close timing, see §3) |
| `RST` | CORERESET_C0 | — | Synchronous `FABRIC_RESET_N` (active-low), gated on PLL lock + MSS reset |
| `DIC` | AXIIC_C0 (CoreAXI4Interconnect) | 3.0.130 | **Data plane** — 6 initiators → 1 target (DDR) |
| `CIC` | AXIIC_CTRL (CoreAXI4Interconnect) | 3.0.130 | **Control plane** — 1 initiator (MSS) → 6 targets |
| `DMA` | AXIDMA_C0 (CoreAXI4DMAController) | 2.2.107 | FFT-stream → DDR writeback (S2MM); AXI4-Lite control target |
| `FFT` | COREFFT_C0 (CoreFFT) | 8.1.100 | Range/azimuth FFT |
| `GBX` | corefft_stream64_adapter | (HDL) | Gearbox: AXI4-Stream ↔ CoreFFT native handshake |
| `CT/WIN/DET/RES/FEED` | HLS kernels (corner_turn/window/detect/resample/fft_feeder) | (HLS) | SAR pipeline stages; each has an AXI4-Lite **control target** (on CIC) + an AXI4 **data initiator** (on DIC) |
| `ID_FIX` | sar_axi_idconv / sar_id_restore | (HDL) | AXI ID stash/restore on DIC→FIC data path (see §6) |

## 3. Clocking & reset
- **Ref:** board `REF_CLK_50MHz` → `CLKINT` global buffer → `CCC:REF_CLK_0`.
- **Fabric clock** `CCC:OUT0_FABCLK_0` (**62.5 MHz**) drives **everything**: `MSS:FIC_0_ACLK`, `DIC/CIC:ACLK`,
  `DMA:CLOCK`, `FFT:CLK`, `GBX:clk`, all kernel `clk`, `RST:CLK`. **Single synchronous fabric domain.**
- **FFT slow clock** `CCC:OUT1_FABCLK_0` (**7.8125 MHz**) → `FFT:SLOWCLK` only (kept at fabric/8).
- ⚠ **Lowered from 125 / 15.625 MHz (2026-06-30).** The 125 MHz build did **not** meet timing — P&R
  reported 25,847 negative-slack pins (worst −3.7 ns), all on this single fabric clock — which made
  silicon non-deterministic (the M3 FFT-stage hang). The bitstream is being **rebuilt at 62.5 MHz with a
  gated flow that aborts on negative slack**; 62.5 MHz halves fabric/FIC throughput (fine for bring-up).
- **Reset:** `MSS:MSS_RESET_N_M2F` → `RST:EXT_RST_N`; `CCC:PLL_LOCK_0` → `RST:PLL_LOCK`. `RST` emits
  `FABRIC_RESET_N` (active-low, synchronized to the fabric clock) → `FFT:NGRST`, `DMA:RESETN`,
  `DIC/CIC:ARESETN`, `GBX:resetn`. The **5 HLS kernels use active-HIGH reset** → `FABRIC_RESET_N` is
  inverted per-kernel (`sd_invert_pins ${k}:reset`).

## 4. Data plane — DIC (`AXIIC_C0`, AXI4, 64-bit)
6 initiators → 1 target. All ports AXI4 (`TYPE=0`), 64-bit data, 8-bit interconnect ID.

| DIC initiator | Master | DIC target | →
|---|---|---|---|
| 0 | `CT:axi4initiator` | 0 | `ID_FIX:S_AXI` → `ID_FIX:M_AXI` → `MSS:FIC_0_AXI4_S` → **DDR** `0x8000_0000–0xBFFF_FFFF` |
| 1 | `WIN:axi4initiator` | | |
| 2 | `DET:axi4initiator` | | |
| 3 | `RES:axi4initiator` | | |
| 4 | `FEED:axi4initiator` | | |
| 5 | `DMA:AXI4InitiatorDMA_IF` | | |

Each kernel and the DMA read/write DDR buffers through this interconnect. The DDR window is cached
(`0x8000_0000–0xBFFF_FFFF`); key buffers: SIG `0x8800_0000`, SCRATCH `0x9800_0000`, OUT `0xA800_0000`,
TABLES `0xB000_0000` (coeffs `0xB014_8000`), M2 results `0xB005_0000`.

## 5. Control plane — CIC (`AXIIC_CTRL`)
1 initiator (`MSS:FIC_0_AXI4_INITIATOR`) → 6 targets. The bare-metal sequencer on a U54 configures and
starts each block through its register window. Per-target 4 KB; address-decoded by the CIC.

| CIC target | Block | Base addr | Protocol (`TYPE`) | Notes |
|---|---|---|---|---|
| 0 | `CT:axi4target` | `0x6000_0000` | AXI4 (0) | HLS AXI4-Lite-style control |
| 1 | `WIN:axi4target` | `0x6000_1000` | AXI4 (0) | |
| 2 | `DET:axi4target` | `0x6000_2000` | AXI4 (0) | |
| 3 | `RES:axi4target` | `0x6000_3000` | AXI4 (0) | |
| 4 | `FEED:axi4target` | `0x6000_4000` | AXI4 (0) | |
| 5 | `DMA:AXI4TargetCtrl_IF` | `0x6000_5000` | **AXI4-Lite (1)** | 32-bit + 64→32 DWC; addr `[10:0]` sliced. **See §7.** |

## 6. Data-plane ID converter — `ID_FIX`
CoreAXI4Interconnect *widens* a target's AXI ID (prepends `log2(NUM_INITIATORS)` source-routing bits);
it does **not** FIFO-compress. The MSS `FIC_0_AXI4_S` accepts only a **4-bit** ID, so the DIC's 9-bit
target ID was being truncated at the boundary → response-routing corruption → silent data-plane hang.
`ID_FIX` (sar_axi_idconv) sits on `DIC:SLAVE0 ↔ FIC_0_AXI4_S`, **stashes the upper ID bits keyed by the
low 4 bits and restores them on the R/B response**, and zero-extends the address 32→38. This is the
verified data-plane fix (M2 tag 0x30 PASS). Detail: [history/id_restore_integration.md](history/id_restore_integration.md).

## 7. FFT stream path & write-back (AXI4-Stream)

> **Superseded 2026-07-04** — the `DMA` AXI4-Stream target + its descriptors below are replaced by the
> `fft_unloader` HLS kernel. Current path: `GBX:m_axis_t{data,valid,ready}` → `fft_unloader` AXI4-Stream
> **slave**, which then writes DDR via its own AXI4 write master through the DIC (§4). No TLAST/TDEST/
> descriptors; the gearbox output skid FIFO absorbs the unloader's write backpressure. The old-DMA bullets
> below are kept for historical context.

- `FEED:out_var{,_valid,_ready}` → `GBX:s_axis_t{data,valid,ready}` (AXI4-Stream into the gearbox).
- `GBX` ↔ `FFT` **native** CoreFFT handshake: `datai_re/im/valid`, `buf_ready`, `datao_re/im/valid`,
  `outp_ready`, `read_outp`.
- ~~`GBX:m_axis_t{data,valid}` / `DMA:TREADY` → `DMA` AXI4-Stream **target** (the FFT output stream).
  Sideband tie-offs: `TKEEP=TSTRB=VCC` (all-bytes-valid), `TLAST=TID=TDEST=GND`, `STRTDMAOP=GND`
  (software-start). Fixed byte-count S2MM mode → `TLAST=GND` is correct (no packet-boundary dependence).~~
  *(superseded — now `GBX:m_axis_*` → `fft_unloader:s_axis_*`.)*
- ~~The DMA then writes the captured stream to DDR via its DIC initiator (data plane, §4).~~
  The `fft_unloader` writes the stream to DDR via its own DIC data initiator (data plane, §4).

## 8. Protocol-type rule (the AXI4-Lite gotcha)
`CoreAXI4Interconnect TARGET_TYPE`: **0=AXI4, 1=AXI4-Lite, 3=AXI3**. A reduced-AXI4-Lite peripheral
(no `AxID`/`AxBURST`/`AxPROT` — the DMA `AXI4TargetCtrl`) **must** be `TYPE=1`, else the 64→32 DWC tries
full-AXI4 burst/ID conversion and silently black-holes single-beat reads (the DMA-control-hang saga).
The address must be wired with an explicit slice (`sd_create_pin_slices` → `sd_connect_pins`), not a bare
`pin[10:0]`. Full rationale + prevention: [FABRIC_INTERCONNECT_CONVENTIONS.md](FABRIC_INTERCONNECT_CONVENTIONS.md).

## 9. Software contract
The bare-metal sequencer (`sar_sequencer.c`) drives the pipeline via the CIC control windows: configure
each kernel's args (DDR buffer addresses, dims) + START, poll done, advance stage. Slave 5 at
`0x6000_5000` is now `fft_unloader`; the `CoreAXI4DMAController` that formerly occupied it (VER `0x00`,
START `0x04`, INTR `0x10`/`0x18`, descriptors `0x60+`) was removed — see §10.2.
Verification harness + register map: [SAR_BRINGUP_REPORT.md](history/SAR_BRINGUP_REPORT.md),
[dataplane_bringup_vplan.md](history/dataplane_bringup_vplan.md). (Historic host-offload HLS register map
in [../regmap.md](history/regmap.md) describes the *earlier* single-accelerator model, not this multi-kernel fabric.)

## 10. End-to-end data flows & complete address map

The full journey of SAR data and every address it touches. (Interconnect/topology detail: §1–§9.)
Sources: `sar/ddr_sar_layout.h` (DDR map + register offsets), `sar/sar_kernels.h` (control windows),
`sar/sar_sequencer.c` (pipeline buffer flow).

### 10.1 DDR map — cached window `0x8000_0000–0xBFFF_FFFF` (LPDDR4)
| Region | Base | Size | Role |
|---|---|---|---|
| app / heap / stack | `0x8000_0000` | 128 MB | firmware (also copied to L2 scratch `0x0a00_0000`) |
| **`SIG`** | `0x8800_0000` | 256 MB | raw I/Q input **and** reused as transpose scratch mid-run |
| **`SCRATCH`** | `0x9800_0000` | 256 MB | inter-stage working buffer |
| **`OUT`** | `0xA800_0000` | 128 MB | final detected image (`GRID_MAX²×2 B`, GRID_MAX=8192) |
| `M2 results` | `0xB005_0000` | small | bring-up harness result table |
| **`CRC mailbox`** | `0xB005_8000` | 24 B | on-target CRC32 verify (6×u32: +0 cmd, +4 base, +8 len, +C result, +10 status, +14 seq) |
| **`TABLES`** | `0xB000_0000` | — | `KR 0xB000_0000`, `KC …0010000`, `TANPHI …0020000`, `WIN …0030000`, `JOB …0040000` |
| `GEOM` | `0xB010_0000` | — | `F0/DF/PR/TANS/INVORDER` `…0100000–…0120000`; `KRGRID …0128000`, `KCGRID …0130000`; `HAMR …0138000`, `HAMC …0140000` |
| `COEF` banks | `0xB014_8000` | — | per-bank resample `IDX` (int32) + `WQ` (int16) |

### 10.2 Control register map — CIC windows (`0x6000_0000`, 4 KB each)
| Window | Base | CIC slave | Block |
|---|---|---|---|
| `CT` (corner_turn) | `0x6000_0000` | 0 | kernel |
| `WIN` (window) | `0x6000_1000` | 1 | kernel |
| `DET` (detect) | `0x6000_2000` | 2 | kernel |
| `RES` (resample) | `0x6000_3000` | 3 | kernel |
| `FEED` (fft_feeder) | `0x6000_4000` | 4 | kernel |
| `FFT_UNLOADER` (was `DMA` control) | `0x6000_5000` | 5 | **AXI4-Lite** (§8) |

Per-kernel HLS registers (offset from window base): `START 0x08` (write 1 = go, read 0 = done),
`ARG0 0x0C`, `ARG1 0x10`, `ARG2 0x14`, `ARG3 0x18`. `FFT_UNLOADER` is a SmartHLS kernel and uses the
same register layout — the `CoreAXI4DMAController` that formerly owned slave 5 (registers `VER 0x00`,
`START 0x04`, `INTR 0x10/0x18`, descriptors `0x60+`) was removed; there are no descriptors/TLAST.

### 10.3 The five data flows
```
(1) INGRESS  host OpenOCD/GDB ─USB─► FlashPro6(J33) ─JTAG─► Debug Module ─► halted U54
                       └► MSS L2/system bus ─► DDR   (load.gdb: sig→0x88000000, coeffs→0xB01xxxxx, job→0xB0040000)
(2) CONTROL  U54 sar_sequencer.c ─► MSS FIC_0 initiator ─► CIC ─► kernel/DMA windows (set ARGs + START, poll done)
(3) COMPUTE  kernel AXI4 data master ─► DIC ─► ID_FIX ─► FIC_0_AXI4_S ─► DDR  (SIG⇄SCRATCH working set; →OUT)
(4) FFT      FEED ─AXI4-Stream─► GBX ─► CoreFFT ─► GBX ─AXI4-Stream─► fft_unloader ─►(DIC→ID_FIX→FIC)─► DDR
(5) EGRESS   host dump_image 0xA8000000 (OUT) ◄─JTAG◄─ MSS ◄─ DDR     (compare to golden image)
```

JTAG bulk transport is latency-bound by the FlashPro6 USB-HID at a **measured ~84 kbit/s** (~111 s/MB;
97 MB ≈ ~2.7 hr) — slow but reliable run-to-completion. **Integrity is now verified via the on-target
CRC mailbox (§10.1 `0xB005_8000`)**: the host writes cmd=`0x43524333` ('CRC3') + base + len, resumes
hart1, and firmware (`u54_1.c`) computes a zlib-compatible CRC32 (poly `0xEDB88320`) at ~75 MB/s and
writes the result + status `0xC0FFEE03` — seconds, vs the slow `dump_image` readback + host cmp (hours).
Host tool: `mpfs/host/run_crc_verify.sh FILE [BASE_HEX]`.

### 10.4 SAR pipeline buffer flow (`sar_sequencer.c`)
Order verified against the Python golden `mpfs/host/emulate_fabric.py` (**corrected 2026-06-30** — an
earlier version of this table wrongly interleaved the FFTs between the two resamples). Both resamples
complete *before* any FFT; the window sits between resample and FFT; the single 2-D FFT is factored
into range-FFT → corner-turn → azimuth-FFT. Full walk-through: [`SAR_PIPELINE_PROCESS.md`](SAR_PIPELINE_PROCESS.md).

The per-stage table (stage → kernel → implementation) lives in
[`SAR_ARCHITECTURE_REPORT.md`](SAR_ARCHITECTURE_REPORT.md) §2 — read it there rather than duplicating it
here. What this section adds is the buffer-aliasing rule:

`SIG` and `SCRATCH` **ping-pong** as the working set (corner-turn transposes between them); coeffs/geometry/
tables are **read-only** inputs. ⚠ `SIG` is *reused as transpose scratch* once the raw input is consumed —
so a re-run must **reload `SIG`** first. `OUT` holds only the final image and is never an intermediate.

### 10.5 Coherency
All buffers are in the **cached** DDR window, but the fabric reaches DDR over the **non-coherent FIC**.
The firmware must **flush** L2 before `START` (so the fabric sees loaded input / CPU-written args) and
**invalidate** before reading results (so the CPU/host sees fabric output). Bulk host transport is
JTAG-bandwidth-limited (measured ~84 kbit/s, ~111 s/MB) — full-frame `SIG` load is the documented
bottleneck, but viable run-to-completion (see §10.3 EGRESS note).
