# Resample: parallel fabric paths — design study

Resample is the largest pipeline stage (26.92 s of 58.12 s -- 46.3%, after window and detect were
fused away). NOTE this study predates the root-cause finding: the gather runs ~880 us/line against a
361 us II=1 schedule (2.44x AXI stall on a CORRECT schedule -- an earlier burst-inference claim was
a stale-report error), so localising the stall with the FIC_0 monitor comes before the parallelism
options below. This study asks what it would take to
parallelise it in fabric, and concludes that the answer differs sharply across its three parts.

Status: **study only.** Nothing here is built. The one prerequisite — measuring the three parts
separately — is now instrumented in firmware and needs a single reflash to produce numbers.

Companion: [`SAR_PIPELINE_STATUS.md`](SAR_PIPELINE_STATUS.md) latency roadmap,
[`../SAR_DESIGN.md`](../SAR_DESIGN.md) §2.1, `hls-trust-harness` skill.

## 1. Resample is three workloads, not one

`sar_stage_ts` reports resample as a single number, which has hidden the structure. Inside
`resample_2pass()`:

| # | Part | Shape | Parallel across lines? |
|---|---|---|---|
| 1 | Range gather | 5,634 pulse lines, each producing Np=8192 outputs | yes — fully independent |
| 2 | Corner-turn | one global transpose of the 256 MiB frame | **no** — global data movement |
| 3 | Azimuth gather | 8,192 range-bin lines, each producing Mp=8192 outputs | yes — fully independent |

The independence of 1 and 3 is provable from the host reference, not assumed: `resample_coeffs` is
`for i in range(m): interp_coeffs(KR, kr[i])` and `apply1` is a pure per-row map. There is no
loop-carried dependency in either gather. The dependency chain between the parts is strict, though:
the corner-turn needs all of the range output, and azimuth needs all of the corner-turn output.

### Current split — MEASURED on silicon 2026-07-21

From `sar_resample_ts[0..3]`, read with `bash mpfs/host/run_stage_timing.sh` (no pipeline re-run
needed). Scene: deci-1 Centerfield, M=5634, N=4319, 8192² grid.

| Part | Measured | Share | Per line |
|---|---:|---:|---|
| Range gather | **8.31 s** | 28.5% | 1.475 ms × 5,634 lines |
| Corner-turn | **7.33 s** | 25.1% | one global transpose |
| Azimuth gather | **13.53 s** | 46.4% | 1.652 ms × 8,192 lines |
| **Total** | **29.17 s** | | |

Two observations the estimates had wrong. The corner-turn inference was exact — predicting it from
the *separate* stage-4 corner-turn (same kernel, same frame) gave 7.3 s against 7.33 s measured. But
the estimate had range slower per line than azimuth; the truth is the reverse (1.475 vs 1.652 ms).
Azimuth reads Mp=8192 per line against range's N=4319, so more reading costing more time is the
intuitive direction — the inverted claim was an artifact of apportioning a total rather than
measuring it.

Azimuth being the single largest part (46%) also means a parallelism effort that treats the two
gathers as interchangeable is mis-weighted: azimuth is worth roughly 1.6× range.

## 1b. Hard prerequisite — ID_FIX cannot route responses for two CONCURRENT kernels

Found 2026-07-21 while wiring a second resample instance. It is a blocker for *any* N>1 plan, and it
is invisible to synthesis and to timing closure — the design builds and closes cleanly, then
mis-routes on silicon.

The SmartHLS `axi_initiator` ports carry **no ID signals at all** (check `resample_top`: there is no
`axi4initiator_aw_id`), so every kernel presents initiator-ID 0. `CoreAXI4Interconnect` forms its
11-bit target ID as `{master_number[2:0], master_id[7:0]}`, so all six kernels differ only in the
**high** bits: CT `0x000`, WIN `0x100`, RES `0x300`, a 7th initiator `0x600`.

`sar_axi_idconv` (ID_FIX) narrows that to FIC0's 4-bit ID by forwarding `S_AXI_AWID[3:0]` and
stashing the upper 7 bits in a **table keyed by those same low 4 bits**:
```verilog
if (S_AXI_AWVALID & S_AXI_AWREADY) aw_tab[S_AXI_AWID[3:0]] <= S_AXI_AWID[10:4];
assign S_AXI_BID = { aw_tab[M_AXI_BID[3:0]], M_AXI_BID[3:0] };
```
Since every kernel's low 4 bits are `0`, **all initiators collide on `aw_tab[0]`**. The module's own
header states the assumption that makes this safe — "≤1 outstanding txn per distinct low-4 tag
(sequential kernels)" — which holds today only because the stages run strictly one at a time.

Run RES and RES2 concurrently and the sequence `RES AW` (stash←0x30), `RES2 AW` (stash←0x60),
`RES B` reconstructs `0x600` and the interconnect routes RES's write response to **RES2**. Both
kernels then hang or corrupt. This is the same failure mode as the "M2 tag 0x30" write-hang saga the
ID_FIX header was written to fix.

Fix before building any N>1 variant: key the stash on the **full 11-bit** ID (or at least include the
`master_number` bits), i.e. widen the FIC0-side tag or carry the master number through a side
channel. This is an RTL change to `sar_axi_idconv.v` only — no HLS work.

## 2. What parallelism buys

Assuming N independent gather instances and an unchanged corner-turn:

| Instances | Range | Corner-turn | Azimuth | Resample | Pipeline |
|---:|---:|---:|---:|---:|---:|
| 1 (baseline at time of study) | 8.31 | 7.33 | 13.53 | **29.17 s** | **88.04 s** |
| 2 | 4.16 | 7.33 | 6.77 | 18.26 s | 77.1 s |
| 4 | 2.08 | 7.33 | 3.38 | 12.79 s | 71.7 s |
| 8 | 1.04 | 7.33 | 1.69 | 10.06 s | 68.9 s |

All of these are worthwhile absolute results — N=8 is 2.9× on the stage and ~19 s off the pipeline.
The Amdahl point is narrower: going 4→8 costs double the fabric for 2.7 s, because at N=4 the
corner-turn is already 57% of resample. So the corner-turn should be attacked *alongside*
parallelism, not after it.

With the corner-turn also halved (see §3), N=4 lands near 9 s and N=8 near 6.4 s — pipeline ~65 s.

### The coefficient floor

The MSS generates coefficients per line (~0.42 ms) and currently hides that behind a slower kernel.
One hart sustains roughly 1 line / 0.42 ms, so **one hart can feed about 4 gather instances** before
coefficient generation becomes the limit. Beyond N=4, multi-hart coefficient generation is required —
splitting across the 4 U54s is firmware-only and the lines are independent.

This is an Amdahl reversal to plan for, not discover: the coefficient work that is "dead by Amdahl"
today becomes the binding constraint the moment the gather gets fast.

## 3. The corner-turn is the sleeper problem

7.3 s to move 256 MiB in and 256 MiB out is **~70 MB/s**. That is drastically below what LPDDR4
should sustain, and worse in relative terms than the gather's ~39 MB/s. A tiled transpose with a
poorly chosen tile size thrashes DDR row activations — reading one useful word per activation — and
that is the most likely explanation.

Two consequences:

1. Tile-size and locality work on the corner-turn may return more than replicating gather instances,
   and it is a smaller change.
2. It pays **twice**. The pipeline runs two corner-turns — one inside resample, one between the FFT
   passes (stage 4, also 7.3 s) — totalling ~14.6 s, about 25% of the 58.12 s pipeline. Both
   use the same kernel, so one fix improves both.

Whether the transpose can be avoided rather than optimised is a separate question. Having azimuth
read columns directly would eliminate it, but a column of a row-major DDR array is a strided access
with terrible locality — which is precisely why the corner-turn exists. Whether a layout choice could
eliminate *one* of the two transposes is worth tracing carefully against the documented `T.rot180`
orientation contract; it is not obvious either way and should not be assumed.

## 4. Constraints on N

**Interconnect is the binding risk, not resources.**

- **FIC_0 AXI-ID truncation to 4 bits.** N gather instances means N more DDR masters on FIC_0, and
  this project has an ID_FIX/ID_RESTORE history there. This is the primary reason to prefer fewer,
  better instances over many. Investigate FIC_1 (dual-FIC) before replicating masters onto FIC_0.
- **Resources are ample.** Current usage is 4LUT 11.75%, LSRAM 15.64% (127/812), MACC 1.66%,
  DFF 9.94%. Even N=4 fits comfortably.
- **LSRAM per instance is a design variable, not a fixed cost.** Today each instance stages
  `in`(32 KB) + `idx`(32 KB) + `wq`(16 KB) = 80 KB. Because `idx` is provably monotonic the input
  needs only a sliding window, which drops per-instance LSRAM to ~16 KB and makes replication cheap.
  Do the streaming restructure first and N becomes much less expensive.
- **DDR bandwidth is not a constraint.** 4× resample is ~156 MB/s, far from limits. The problem
  throughout is latency and access pattern, not throughput.

## 5. What is already ruled out

Two AXI request-management knobs have been falsified by silicon measurement, so a parallelism design
should not assume either is available headroom:

| Knob | Change | Result |
|---|---|---|
| `max_burst_len` | 64 → 256 (2026-07-12) | zero gain |
| `max_outstanding_reads` | 1 → 8 (2026-07-20, FIFO depth change confirmed in RTL) | zero gain |

The kernel runs ~3.1× slower than its scheduled cycle count, and that gap is therefore **not** in AXI
request scheduling — it is internal to the kernel's dataflow. That is what makes the streaming
restructure the lever, and it is also why per-instance throughput should be fixed before multiplying
instances: replicating a kernel that is 3.1× off its own schedule multiplies the inefficiency.

## 6. Recommended sequence

1. **Measure the three parts.** Firmware instrumentation is in place; one reflash. Everything below
   depends on which part actually dominates.
2. **Measure effective II** on the gather (`hls_stats.py eff-ii`, busy-cycles ÷ elements) to localise
   the 3.1× — the Class-B ledger's `axi_ii_lie` phenomenon is exactly this.
3. **Streaming restructure of the gather** — delete `buf[RS_IN]` staging, bound the loop to the
   contiguous `[lo,hi]` valid span. Improves the single instance and cuts per-instance LSRAM 5×.
4. **Corner-turn locality** — tile sizing against DDR row structure. Pays twice.
5. **Then parallelise**, N=2 first to validate the interconnect story before committing to 4.
6. **Multi-hart coefficient generation** once N ≥ 4 exposes the ~5.8 s floor.

Steps 1–2 are measurement, 3–4 are single-instance work that makes step 5 cheaper and more effective.
Nothing here requires a new fabric master until step 5.
