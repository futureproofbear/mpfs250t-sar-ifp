# HLS silicon statistics — the report-vs-silicon ledger

The SmartHLS report is a **behavioural model**. It cannot see the system intricacies
that decide whether the RTL actually works and how fast: DDR latency, AXI
arbitration/backpressure, L2 coherency, FIC/AXI-ID routing, ES silicon errata, and
cross-IP handshakes. This doc is the human rollup of what we **measure** for each of
those, so the gap between "scheduled" and "silicon" is tracked, not rediscovered.

Raw measurements live append-only in
[`hls_silicon_stats.jsonl`](hls_silicon_stats.jsonl); collect and roll them up with
[`mpfs/host/hls_stats.py`](../../mpfs/host/hls_stats.py):

```
python mpfs/host/hls_stats.py report               # everything
python mpfs/host/hls_stats.py report --phenomenon axi_ii_lie
```

**Update discipline:** append a record the same session you take a measurement
(CLAUDE.md runbook rule). Never edit the tables below by hand as the source of
truth — they are a snapshot of the ledger; the JSONL is the truth.

---

## The six phenomena and how each is collected

### 1. `axi_ii_lie` — effective II vs scheduled II  *(DDR latency + AXI backpressure)*
The headline lie. SmartHLS schedules `II=1/2` assuming each AXI-initiator FIFO read
returns in one cycle; the DDR round-trip and AXI backpressure serialise it.

- **Claim side** (cheap, board-free): `hls_report_lint.py` records the scheduled II
  per loop (metric `scheduled_ii`).
- **Reality side** (silicon): kernel busy-cycles ÷ elements processed = effective II.
  The iso-test already reports busy cycles and element count — no new RTL:
  ```
  python mpfs/host/hls_stats.py eff-ii --build <name> \
       --busy-cycles <N> --elements <M> --scheduled <k> --source run_resample_iso
  ```
  `lie_ratio = eff_ii / scheduled` is the magnitude of the lie. Target: ratio → 1.0
  after staging operands into LSRAM (see anti-pattern §4).

### 2. `ddr_latency` — DDR read round-trip (cycles)
The raw contributor behind the II lie. Collect with a fabric AXI-monitor counter
(AR-valid → first R-valid) read over JTAG, or from a SmartDebug capture
(`smartdebug-probe`). Record `metric=ar2r_cycles`.

### 3. `l2_coherency` — cache-flush contract (cost and correctness)
Per-chunk L2 flush cost, and any stale-data miss when the contract is violated.
Cost is measured as a fraction of stage latency (metric `flush_frac`) or cycles.
Correctness failures are recorded with `note` describing the missed flush.

### 4. `fic_axi_id` — FIC0 / AXI-ID routing
Which master ID reaches which slave through FIC0, and any mis-route/ID-collision
observed. Mostly qualitative; record `metric=observation` with the finding and a
pointer to FABRIC_INTERCONNECT_CONVENTIONS.md.

### 5. `es_errata` — MPFS250T_ES errata (ER0219 &c.)
Engineering-sample silicon deviations and their workarounds. Record each time an
erratum is hit or a workaround is validated; `note` carries the erratum id and the
workaround. Cross-ref the `mpfs-platform-gotchas` skill.

### 6. `corefft_rearm` — cross-IP re-arm handshake
CoreFFT (or any hard-IP) re-arm / re-trigger behaviour the golden testbench does NOT
exercise. Record the observed handshake requirement and whether a single-shot TB
would have missed it.

---

## Current snapshot

Regenerate with `python mpfs/host/hls_stats.py report`. Seeded from established
results as of 2026-07-12; silicon `eff_ii` for the LSRAM build is **pending** (see
memory: resample-latency chunked-flush, Step B silicon test outstanding).

| phenomenon | build | metric | value | note |
|---|---|---|---|---|
| axi_ii_lie | resample-ddr | eff_ii | ~20 | scheduled II=2, ~10× lie (DDR read in inner loop) |
| axi_ii_lie | resample-lsram | scheduled_ii | 1 | operands moved to LSRAM; silicon eff_ii pending |
| l2_coherency | resample | flush_frac | 0.02 | per-chunk L2 flush ≈ 2% of latency — not the bottleneck |
| es_errata | mpfs250t_es | observation | — | ER0219; see mpfs-platform-gotchas |
| corefft_rearm | k_fft | observation | — | golden TB ran one transform, never the re-arm path |

See also: HLS_SILICON_STATS drives the batch-confidence gates in
[`SAR_PIPELINE_STATUS.md`](SAR_PIPELINE_STATUS.md) and the
`hls-trust-harness` skill.
