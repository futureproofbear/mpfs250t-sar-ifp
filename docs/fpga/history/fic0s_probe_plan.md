# FIC_0_AXI4_S Boundary Probe Plan — isolate "timing drop vs ID/protocol reject"

Target: the MSS FIC0 Subordinate boundary in `component/work/SAR_TOP/SAR_TOP.v`
(MSS instance port `.FIC_0_AXI4_S_*`). On silicon the resample kernel issues one
read here (coeff bank `0xB0148000`) and hangs — so the boundary sits in a **static
hung state**, which makes this observable with **no waveform/trigger needed**.

- **Sample clock for all these nets:** `CCC_OUT0_FABCLK_0` (the fabric data clock).
- **AXI roles on this port:** master = AXIIC_C0 (fabric) drives the `*VALID`/addr/ID/
  `*READY`-of-responses... ; subordinate = MSS drives `ARREADY/RVALID/RID/RRESP/RLAST`
  and `AWREADY/WREADY/BVALID/BID/BRESP`.

## Complete boundary net list (port -> net to probe)

### AR channel (read address) — fabric issues, MSS accepts
| FIC0_S port | net | driver | width |
|---|---|---|---|
| FIC_0_AXI4_S_ARVALID | `DIC_AXI4mslave0_ARVALID` | fabric | 1 |
| FIC_0_AXI4_S_ARREADY | `DIC_AXI4mslave0_ARREADY` | **MSS** | 1 |
| FIC_0_AXI4_S_ARID    | `DIC_AXI4mslave0_ARID_0`  | fabric | 4 (truncated from 9) |
| FIC_0_AXI4_S_ARADDR  | `DIC_AXI4mslave0_ARADDR_0`| fabric | 38 |
| FIC_0_AXI4_S_ARLEN/SIZE/BURST/QOS/CACHE/PROT/ARLOCK | `DIC_AXI4mslave0_AR*` | fabric | — |

### R channel (read data) — MSS returns
| FIC_0_AXI4_S_RVALID | `DIC_AXI4mslave0_RVALID` | **MSS** | 1 |
| FIC_0_AXI4_S_RREADY | `DIC_AXI4mslave0_RREADY` | fabric | 1 |
| FIC_0_AXI4_S_RID    | `DIC_AXI4mslave0_RID`    | **MSS** | 4 |
| FIC_0_AXI4_S_RRESP  | `DIC_AXI4mslave0_RRESP`  | **MSS** | 2 (00=OKAY,10=SLVERR,11=DECERR) |
| FIC_0_AXI4_S_RLAST  | `DIC_AXI4mslave0_RLAST`  | **MSS** | 1 |
| FIC_0_AXI4_S_RDATA  | `DIC_AXI4mslave0_RDATA`  | **MSS** | 64 |

### AW / W / B channels (writes — for the corner-turn/detect masters later)
AWVALID `DIC_AXI4mslave0_AWVALID` (fab) · AWREADY `..._AWREADY` (MSS) · AWID `..._AWID_0`(4) ·
AWADDR `..._AWADDR_0`(38) · WVALID/WLAST/WDATA/WSTRB `..._W*` (fab) · WREADY `..._WREADY`(MSS) ·
BVALID `..._BVALID`(MSS) · BREADY `..._BREADY`(fab) · BID `..._BID`(MSS,4) · BRESP `..._BRESP`(MSS,2)

## STEP 1 — fastest, NO rebuild: SmartDebug Active/Live Probe of the static hang
The kernel holds the AR asserted while hung, so the levels are stable. In SmartDebug
(device programmed + powered, kernel fired by M2 at boot), read these 4 nets:

`DIC_AXI4mslave0_ARVALID`, `DIC_AXI4mslave0_ARREADY`,
`DIC_AXI4mslave0_RVALID`,  `DIC_AXI4mslave0_RRESP[1:0]`

(Active Probe = read current value directly; if a net isn't active-probe-able because
it's combinational, route it via Live Probe to a probe pin and read on a meter/scope.)

### Decision tree (this is the whole point)
| ARVALID | ARREADY | RVALID | RRESP | Verdict |
|---|---|---|---|---|
| 0 | x | x | x | AR never issued → stall is **upstream** (kernel master ↔ AXIIC_C0); FIC0_S innocent |
| **1 (stuck)** | **0 (stuck)** | 0 | — | **MSS not accepting the AR** → MSS-side reject / FIC0_S subordinate not ready (Suspect 3, MSS) |
| 1→0 (accepted) | pulsed 1 | **0 (stuck)** | — | AR accepted, **response never returns** → ID/response-routing (the `5'h0` RID pad) is the culprit |
| accepted | — | 1 | **11/10** | MSS DECERR/SLVERR → region/decode reject; would *complete*, so a hang here implicates the kernel ignoring RRESP |

The first two rows are the likely ones; they cleanly separate **"MSS won't accept"**
(protocol/region/QoS/ID at the MSS subordinate) from **"accepted but lost on return"**
(the response-ID truncation in SAR_TOP.v:1124-1125).

## STEP 2 — full waveform: Identify/FHB ILA (needs instrument -> synth -> P&R -> bitstream)
Insert an Identify instrumentor (or SmartDebug FHB) sampling on `CCC_OUT0_FABCLK_0`,
capturing the AR + R groups above. **Trigger:** rising edge of `DIC_AXI4mslave0_ARVALID`.
Depth 512 is plenty (single short burst). Watch the exact cycle relationship of
ARVALID/ARREADY and whether RVALID/RLAST ever assert and with what RID/RRESP.

To give the ILA repeated events instead of a one-shot boot transaction, the M2 firmware
can be changed to RE-FIRE the resample start in a loop (re-arm AR every N ms) — ask and
I'll add that hook so triggering is trivial.

## Notes
- These boundary nets are connected to the MSS hard-block instance, so they survive
  synthesis (no `syn_preserve` needed) and are selectable in SmartDebug.
- If STEP 1 shows ARREADY-stuck-0, the next check is the MSS FIC0 subordinate region/QoS
  config and whether the ES silicon services FIC0_S; if it shows accepted-but-no-RVALID,
  regenerate AXIIC_C0 to remove the 9->4 ID truncation and retest.
