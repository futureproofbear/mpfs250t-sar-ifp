# SAR accelerator — final SmartDesign wiring guide (Libero GUI)

> **Update 2026-07-04:** CoreFFT→DDR write-back is now the HLS `fft_unloader` (DMA removed) + a
> gearbox output skid FIFO; see [`../PROJECT_SOURCE_OF_TRUTH.md`](../../PROJECT_SOURCE_OF_TRUTH.md)
> "CURRENT STATUS". The `AXIDMA_C0` / `DMA-ctrl @0x6000_5000` and the "CoreFFT streaming path
> (DMA ↔ adapter ↔ CoreFFT)" wiring below are superseded — the DMA was removed and the CoreFFT output
> stream now feeds the `fft_unloader` HLS kernel (its own AXI4 write master to DDR); the gearbox holds
> an output skid FIFO.

> ℹ HISTORICAL — Libero-GUI assembly reference. The current *built* topology differs:
> **5 HLS kernels** (CT/WIN/DET/RES/**FEED**), both interconnects on
> **CoreAXI4Interconnect 3.0.130**, the control plane (CIC) is **1 master / 6 targets**
> with **DMA-ctrl @ `0x6000_5000` (AXI4-Lite, 32-bit + DWC)** added, and the data plane
> (DIC) is **6 masters / 1 DDR target** routed through **`sar_axi_idconv.v`** (AXI ID
> converter) into `FIC_0_AXI4_S`. For the authoritative current architecture see
> docs/fpga/AMBA_ARCHITECTURE.md. The GUI steps below are still useful, but treat the
> 4-kernel / 5-window specifics as superseded.

Everything is generated and configured already (CoreFFT, DMA, AXI interconnect,
5 HLS kernels, stream adapter, MSS — all in `libero_sar/sar_accel.prjx`). This is
the one remaining step: connect the blocks in a top SmartDesign, then build the
bitstream. ~1–2 hours, click-and-drag. After this, synth→P&R→bitstream is headless
again.

Block (instance) names used below match the project; reset polarities:
CoreFFT `NGRST` and DMA `RESETN` are **active-low**; the HLS-kernel `reset` is
**active-high**.

---

## 0. Prerequisites — ALREADY GENERATED (headless)

These are now in the project (`libero_sar`), generated in batch:

1. **`AXIIC_CTRL`** (CIC) — control interconnect, **1 master → 6 targets**
   (CoreAXI4Interconnect 3.0.130). Target windows (each 4 KB): CT `0x6000_0000`,
   WIN `0x6000_1000`, DET `0x6000_2000`, RES `0x6000_3000`, FEED `0x6000_4000`,
   **DMA-ctrl `0x6000_5000`** (AXI4-Lite, 32-bit + DWC). (The data interconnect
   `AXIIC_C0` / DIC is **6 masters → 1 DDR target**, routed via `sar_axi_idconv.v`.)
2. **`CORERESET_C0`** (`CORERESET_PF`) — MSS power-on reset + FIC0 DLL lock → clean
   `FABRIC_RESET_N`.
3. **`CLK_DIV4` + `CLK_DIV2`** (`PF_CLK_DIV`) — cascade for **`SLOWCLK = fabric/8`**
   (single-stage ÷8 isn't a legal PF_CLK_DIV value; ÷4→÷2 is).
4. **`OSCILLATOR_160MHz`** (`PF_OSC`) + **`PF_CCC_C0`** (`PF_CCC`) — the fabric clock
   source. The CCC's `OUT0_FABCLK_0` is **125 MHz** and is THE fabric clock. NOTE:
   `ICICLE_MSS:FIC_0_ACLK` is an **input** (the fabric clocks the MSS's FIC0), so the
   clock comes from the CCC, not the MSS.

Stream width note: the DMA AXI4-Stream is **64-bit** (it follows `AXI_DMA_DWIDTH`;
there is no separate stream-width knob), but the adapter/CoreFFT take **32-bit**
(one complex sample/beat). Three options: (1) a small **64↔32 gearbox** module
(keeps 64-bit DDR bandwidth — recommended; CoreFFT consumes 1 sample/cycle so a
32-bit feed is rate-matched); (2) **regenerate the DMA with `AXI_DMA_DWIDTH:32`**
(simplest, but halves DDR throughput); (3) tie off the upper half (`TDATA[63:32]`,
`TKEEP[7:4]`, `TSTRB[7:4]`) and move 1 sample/beat (half-rate, as the Icicle
reference does for its stream demo).

---

## 1. Create the top SmartDesign

`File → New → SmartDesign` → name it `SAR_TOP`. Drag these from the Design
Hierarchy/Catalog onto the canvas:

`ICICLE_MSS`, `AXIIC_C0`, `AXIIC_CTRL`, `AXIDMA_C0`, `COREFFT_C0`,
`corefft_stream_adapter`, `corner_turn_top`, `window_top`, `detect_top`,
`resample_top`, `CORERESET_C0`, `CLK_DIV4`, `CLK_DIV2`, `OSCILLATOR_160MHz`,
`PF_CCC_C0`.

Tip: connect a whole AXI interface in one go — click the bus-interface pin (the
grouped `AXI4`/`MASTER0`/`axi4initiator` handle, not individual `AW*`/`AR*` pins)
and drag to the matching one; Libero connects all the sub-signals.

---

## 2. Clocks

The fabric clock originates in the CCC (not the MSS — `FIC_0_ACLK` is an MSS input).

| From | To |
|------|----|
| `OSCILLATOR_160MHz:RCOSC_160MHZ_GL` | `PF_CCC_C0:REF_CLK_0` |
| `PF_CCC_C0:OUT0_FABCLK_0` (125 MHz) | `ICICLE_MSS:FIC_0_ACLK` **(MSS input)**, `AXIIC_C0:ACLK`, `AXIIC_CTRL:ACLK`, `AXIDMA_C0:CLOCK`, `COREFFT_C0:CLK`, all four kernels `:clk`, `CLK_DIV4:CLK_IN`, `CORERESET_C0:CLK` |
| `CLK_DIV4:CLK_OUT` | `CLK_DIV2:CLK_IN` |
| `CLK_DIV2:CLK_OUT` (= 125/8 ≈ 15.6 MHz) | `COREFFT_C0:SLOWCLK` |
| `PF_CCC_C0:PLL_POWERDOWN_N_0` | tie `VCC` (or from a reset) |

## 3. Resets (CORERESET_PF)

- Drive `CORERESET_C0` lock/release inputs from `PF_CCC_C0:PLL_LOCK_0`,
  `ICICLE_MSS:FIC_0_DLL_LOCK_M2F`, and the MSS power-on reset — exactly as the
  reference's `CLOCKS_AND_RESETS` does (so the fabric reset releases only after the
  PLL/DLL lock).
- `CORERESET_C0:FABRIC_RESET_N` (active-low) → `COREFFT_C0:NGRST`, `AXIDMA_C0:RESETN`,
  `AXIIC_C0:ARESETN`, `AXIIC_CTRL:ARESETN`.
- Kernels need **active-high** reset: right-click each `*_0:reset` →
  **Invert**, then connect to `FABRIC_RESET_N`.

---

## 4. Data plane (accelerator → DDR)

Connect each AXI **master** to a data-interconnect master port, then the
interconnect's single slave to the MSS DDR path:

| From (master) | To (interconnect) |
|---|---|
| `corner_turn_0:axi4initiator` | `AXIIC_C0:MASTER0` |
| `window_0:axi4initiator` | `AXIIC_C0:MASTER1` |
| `detect_0:axi4initiator` | `AXIIC_C0:MASTER2` |
| `resample_0:axi4initiator` | `AXIIC_C0:MASTER3` |
| `AXIDMA_C0:DMA` (AXI master) | `AXIIC_C0:MASTER4` |
| `AXIIC_C0:SLAVE0` | `sar_axi_idconv` → `ICICLE_MSS:FIC_0_AXI4_S` |

NOTE (current build): the DIC `SLAVE0` reaches DDR through the **`sar_axi_idconv.v`**
AXI ID converter into `FIC_0_AXI4_S` (the on-silicon data-plane fix). The built DIC
is **6 masters → 1 DDR target** (the FEED kernel adds the 6th master).

`AXIIC_C0` SLAVE0 is already mapped to `0x8000_0000–0xBFFF_FFFF` (DDR window).

## 5. Control plane (CPU → registers)

| From | To |
|---|---|
| `ICICLE_MSS:FIC_0_AXI4_INITIATOR` | `AXIIC_CTRL:MASTER0` |
| `AXIIC_CTRL:SLAVE0` (`0x6000_0000`) | `corner_turn_0:axi4target` (CT) |
| `AXIIC_CTRL:SLAVE1` (`0x6000_1000`) | `window_0:axi4target` (WIN) |
| `AXIIC_CTRL:SLAVE2` (`0x6000_2000`) | `detect_0:axi4target` (DET) |
| `AXIIC_CTRL:SLAVE3` (`0x6000_3000`) | `resample_0:axi4target` (RES) |
| `AXIIC_CTRL:SLAVE4` (`0x6000_4000`) | `feed_0:axi4target` (FEED) |
| `AXIIC_CTRL:SLAVE5` (`0x6000_5000`) | `AXIDMA_C0:CTRL` (DMA-ctrl, AXI4-Lite 32-bit + DWC) |

Give each `AXIIC_CTRL` slave a distinct address window (e.g. base
`0x6000_0000 + n*0x1000`); these become the register bases the bare-metal driver
writes (mirror them into `ddr_sar_layout.h`).

Also promote each kernel's `start`/`ready`/`finish` to a small status block or tie
into the DMA/CPU handshake (the driver polls `axi4target` regs).

## 6. CoreFFT streaming path (DMA ↔ adapter ↔ CoreFFT)

| From | To |
|---|---|
| `AXIDMA_C0` AXI4-Stream **master** | `corefft_stream_adapter:s_axis_*` (TDATA[31:0]; tie upper) |
| `corefft_stream_adapter:datai_re/im/valid` | `COREFFT_C0:DATAI_RE/IM/VALID` |
| `COREFFT_C0:BUF_READY` | `corefft_stream_adapter:buf_ready` |
| `COREFFT_C0:DATAO_RE/IM/VALID, OUTP_READY` | `corefft_stream_adapter:datao_*/outp_ready` |
| `corefft_stream_adapter:read_outp` | `COREFFT_C0:READ_OUTP` |
| `corefft_stream_adapter:m_axis_*` | `AXIDMA_C0` AXI4-Stream **slave** |

`COREFFT_C0:SCALE_EXP` → a status register the driver reads (the BFP shift).

---

## 7. Generate & build (headless again from here)

1. Right-click `SAR_TOP` → **Generate Component** (resolve any unconnected-pin
   errors — tie off or promote as flagged).
2. Right-click `SAR_TOP` → **Set as Root**.
3. **Constraints:** import `fic_clocks.sdc` from
   `icicle-kit-reference-design/.../constraint/` (+ any I/O PDC the MSS needs).
4. Design Flow (or Tcl `run_tool`): **Synthesize → Place and Route → Verify Timing
   → Generate Bitstream**, then **Export FlashPro Express job** / **Run PROGRAM
   Action** with the board attached.

These last steps are scriptable:
`run_tool -name {SYNTHESIZE}` / `{PLACEROUTE}` / `{VERIFYTIMING}` /
`{GENERATEPROGRAMMINGDATA}`.

---

## 8. After the bitstream — board bring-up

1. Program the bitstream (FlashPro/JTAG).
2. Build & run the bare-metal driver (extend `mpfs/fpga/libero_sar/softconsole/
   mpfs-hal-ddr-demo/src/sar/sar_accel_driver.c`: program DMA descriptors + each block's `axi4target` regs
   per stage, poll done, read `SCALE_EXP`).
3. Validate: `serialize_inputs.py` → JTAG-load DDR → run → JTAG-dump OUT →
   `dump_output.py readback --golden golden_fixed.npy` (expect correlation → 1.0).
   For a **fast load-integrity check** (seconds vs the slow dump+cmp), use the
   on-target CRC mailbox: `mpfs/host/run_crc_verify.sh FILE [BASE_HEX]` resumes hart1
   to compute a zlib-compatible CRC32 of any JTAG-loaded DDR region.

---

## Sanity: per-component resource budget (already measured)
CoreFFT 4.2k LUT/4 DSP/21 LSRAM · corner-turn 8.3k LUT · window/detect/resample
2–3k LUT each · whole accel ≈ 10 % LUT / 2.5 % DSP / 4 % LSRAM of the MPFS250T —
fits with large margin.
