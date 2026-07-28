# Glossary

Every term, acronym and magic value this project uses without explanation elsewhere. If you hit
something in a doc, a log or a commit message that you cannot decode, it should be here.

Ordered by what you are most likely to meet first.

---

## 1. The radar problem

| term | meaning |
|---|---|
| **SAR** | Synthetic Aperture Radar. A moving platform's successive pulses are combined to synthesise a much larger virtual antenna, giving fine cross-range resolution. |
| **PFA** | Polar Format Algorithm. The image-formation method used here: resample the polar-sampled phase history onto a rectangular grid, then two FFTs. |
| **CPHD** | Compensated Phase History Data. The input file format — raw pulse data plus per-pulse geometry, **not** an image. |
| **PVP** | Per-Vector Parameters. The per-pulse geometry inside a CPHD (platform position, timing, frequency ramp). |
| **phase history** | The raw pulse × sample complex data before focusing. |
| **focusing** | Turning phase history into an image. The whole job. |
| **range** | Along the radar's line of sight. |
| **azimuth** | Along the platform's direction of travel (cross-range). |
| **keystone resample** | The 2-D interpolation that maps polar samples onto the rectangular grid. |
| **speckle** | The grainy texture in a SAR image. Physical, not noise — a correctly formed image *has* it. |
| **single-look** | No multi-look averaging. Full resolution, maximum speckle. |
| **BFP** | Block Floating Point. One shared exponent for a block of samples (here, per FFT row) with integer mantissas — keeps dynamic range without full floating point in fabric. |
| **taper / Hamming window** | Amplitude weighting applied before an FFT to suppress sidelobes. |

> **The naming trap.** The field names `rangeFFT` and `azFFT` are **inverted** with respect to what
> they do: `rangeFFT` is FFT-1 and transforms the **azimuth** axis; `azFFT` is FFT-2 and transforms
> the **range** axis. Docs use the physical meaning; the identifiers are historical.

---

## 2. Pipeline stages

| term | meaning |
|---|---|
| **FFT-1** | First transform pass. Azimuth. Reads the resampled grid. |
| **FFT-2** | Second transform pass. Range. Produces the image. |
| **CT#1** | The corner-turn *inside* the resample stage (between the two gathers). |
| **CT#2** | The corner-turn between FFT-1 and FFT-2. Strip-pipelined so it hides under FFT-2. |
| **corner-turn** | A full 8192² transpose, so the second FFT reads rows that were columns. Pure data movement. |
| **gather** | An indexed read: `out[i] = lerp(src[idx[i]], src[idx[i]+1], wq[i])`. The resample primitive. |
| **detect** | Magnitude `|z|` of the complex result. The final step; fused into the FFT-2 unloader. |
| **fused** | A stage with no kernel of its own, folded into a neighbour's existing DDR pass. Window is fused into the feeder, detect into the unloader — both cost zero time. |
| **renormalize epilogue** | After each FFT pass, rescale all rows to a common block exponent. Runs on the CPU, split across worker harts. |

---

## 3. Hardware and fabric

| term | meaning |
|---|---|
| **MPFS250T** | The Microchip PolarFire SoC part. RISC-V MSS + FPGA fabric on one die. |
| **MSS** | Microprocessor SubSystem — the hard CPU complex (4× U54 + 1× E51). |
| **U54** | The 64-bit application RISC-V cores. `U54_1` dispatches; `U54_2/3/4` are workers. |
| **fabric** | The FPGA logic. |
| **FIC_0** | Fabric InterConnect port 0 — the 64-bit AXI4 link fabric→MSS→DDR. 100 MHz, ~800 MB/s ceiling. **The shared resource everything contends for.** |
| **DIC** | Data InterConnect. Fabric kernel masters → FIC_0 → DDR. |
| **CIC** | Control InterConnect. MSS → the nine AXI4-Lite kernel control windows. |
| **CoreFFT** | Microchip's hard FFT IP. 8192-point, block floating point, 69,790 cycles/row. |
| **SLOWCLK** | CoreFFT's own clock domain, 12.5 MHz (fabric/8). |
| **gearbox (GBX)** | Rate-matches the 64-bit 100 MHz fabric stream to CoreFFT's stream rate. |
| **feeder (FEED)** | DDR → CoreFFT stream, with the gather and window taper fused in. |
| **unloader (UNLD)** | CoreFFT stream → DDR, with detect fused in. |
| **coeffgen (COEFG)** | On-fabric resample coefficient generator — replaces CPU coefficient computation. |
| **SmartHLS** | Microchip's C++→RTL high-level synthesis. Being retired from the datapath; `RES` is the last one. |
| **LSRAM / µSRAM** | Fabric memory blocks. LSRAM is 20 Kb; µSRAM is small and distributed. |
| **MACC** | Hardened 18×18 multiply-accumulate block. |
| **SASD** | Single-Active-Slave-Domain — an interconnect mode limiting outstanding transactions. |
| **eNVM** | Embedded non-volatile memory. Holds the application binary. |
| **FlashPro6 / FP6** | The JTAG programmer/debug link. ~84 kbit/s and latency-bound. |

---

## 4. Buffers and memory

| term | meaning |
|---|---|
| **SIG** | The raw signal buffer. Also reused mid-pipeline. |
| **SCRATCH** | Intermediate working buffer. |
| **OUT** | The focused uint16 image. |
| **WORK** | A would-be third buffer at `0xC0000000`. **Hard-disabled** — it sits one byte past the fabric's address decode. |
| **ELOD-per-PIPE rule** | A frame **overwrites its own input** (CT#1 writes SIG). A second run without reloading silently processes the previous run's intermediate data. **One ELOD per PIPE run.** |
| **DDR volatility** | A power-cycle wipes DDR — both the scene **and** every runtime knob. |

---

## 5. Mailbox commands

Written to the hart1 mailbox at `0xB005_8000`. The code is the ASCII of its name.

| code | value | what it does |
|---|---|---|
| **ELOD** | `0x454C4F44` | Load scene eMMC → DDR (~81 s) |
| **PIPE** | `0x50495045` | Run the image-formation pipeline |
| **EROI** | `0x45524F49` | Crop a region from the DDR image, and CRC it on-board |
| **EROE** | `0x45524F45` | Same, but read from the persisted image |
| **ESAV** | `0x45534156` | Persist the image DDR → eMMC |
| **EVOU** | `0x45564F55` | Verify the persisted image by full CRC |
| **EPRV** | `0x45505256` | Provision the eMMC INPUT partition |
| **EMMC** | `0x454D4D43` | eMMC self-test |
| **CRC3** | `0x43524333` | CRC32 over an arbitrary DDR range |

Done marker is `status = 0xC0FFEE03`. Verdict 0 = pass.

---

## 6. Runtime knobs

DDR words read at run time. **Fail-safe: an unset or cold-boot word means OFF**, so the shipping
binary is behaviour-neutral until switched — with one deliberate exception, `RSVMODE`, marked below.
**A power-cycle clears every one of them.**

| knob | address | shipping value | effect |
|---|---|---|---|
| `DETMODE` | `0xB0059118` | `3` | detect fused into the unloader |
| `GATHMODE` | `0xB005911C` | `1` | azimuth gather fused into the FFT-1 feeder |
| `OVLMODE` | `0xB0059130` | `1` | CT#2 overlapped with FFT-2 |
| `CGENMODE` | `0xB0059138` | `0x43474E31` (`'CGN1'`) | coefficients generated on fabric |
| `DUALFFT` | `0xB005913C` | `0x44464632` (`'DFF2'`) | second CoreFFT chain |
| `RWRKNW` | `0xB005912C` | `0x52575204` (`'RWR'`\|4) | renormalize split over 4 harts |
| `FFTBLK` | `0xB0059140` | `64` | rows a chain takes before handover |
| `WORKBUF` | `0xB0059144` | *(disabled)* | would route corner-turns via WORK |
| `RSVMODE` | `0xB0059148` | *(leave unset)* | **INVERTED — on by default.** Range gather via `sar_resample_v`, coefficients generated on fabric |

Each magic value is **the only accepted value** — anything else means off. Passed as environment
variables to `run_m3_iso.sh`.

> **`RSVMODE` is the exception to the fail-safe rule, on purpose.** From the 2026-07-28 bitstream
> onward the built netlist contains `sar_resample_v` and *no* SmartHLS resample — the new core took
> the same CIC target rather than sitting beside it, so there is nothing to fall back to. An opt-in
> knob would have made the default case the dangerous one, arming the new core through the old
> register map (`idx` into `OUT_BASE`, the output pointer read as `{SN,QN}`). Only the exact word
> `0x52535630` (`'RSV0'`) forces the legacy path, and that is correct **only** when pairing this
> firmware with a pre-2026-07-28 bitstream. Full reasoning: `mpfs/fpga/resample_v_status.md`.

> A bare `run_m3_iso.sh ... PIPE` with no knobs gives an **unfused single-chain run**, several
> seconds slower and not the configuration any documented baseline was measured with.

---

## 7. Instrumentation and tests

| term | meaning |
|---|---|
| **FICMON** | The FIC_0 bus monitor (`sar_fic0s_mon.v`). Counts active/idle/read-wait cycles and burst lengths. Decode with `decode_ficmon.py`. **Two slots only** — there is no slot 2. |
| **E4** | The FICMON experiment label for the **corner-turn** bus measurement. (E1 was the FFT-1 row group.) |
| **R_DATAWAIT** | Cycles where a read burst is outstanding but the DDR is not returning data. High = latency-bound. |
| **genuine idle** | Cycles where the port is doing nothing at all. High = the *kernel* is not issuing — something off-bus is the limit. |
| **RPROF** | Per-line resample profiling counters. |
| **iso-test** | A test that arms exactly one kernel and reads its output back, isolating it from the pipeline. |
| **mutation testing** | Deliberately breaking the design to prove the testbench notices. A test that cannot fail is worthless. |
| **re-arm** | Starting the same kernel instance again without a reset — what firmware does thousands of times per frame. Benches that reset between runs cannot see re-arm bugs. |
| **crop CRC** | `0x319037b2` — the bit-exactness gate. Computed on-board over a 1024×1024 crop. |
| **golden** | The reference implementation (float, host-side) that silicon is compared against. |

---

## 8. Where things are documented

| document | what it owns |
|---|---|
| `docs/USER_GUIDE.md` | clone → build → program → run. The operating procedure. |
| `docs/ARCHITECTURE.md` | the as-built contract: stages, register maps, DDR map, resources, timing |
| `docs/SAR_IMPLEMENTATION_RECORD.md` | the measured optimisation history and current baseline numbers |
| `docs/fpga/DEV_GUIDE.md` | build/debug runbook, gotchas, methodology lessons |
| `docs/PROJECT_SOURCE_OF_TRUTH.md` | index; what is proven vs open |
| `docs/slides/` | the presentation deck and its editable figures |
