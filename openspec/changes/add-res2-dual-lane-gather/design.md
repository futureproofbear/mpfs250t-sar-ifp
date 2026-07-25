# Design: RES2 dual-lane range gather

## Fabric

- `RES2` = 2nd instance of the `resample_top` HDL+ core, replacing the unused `DET`
  (`detect_top`) SmartDesign slot. Control @ `0x60002000` (the old K_DETECT window, reused).
- `RSLICE_DIC` / `RSLICE_CIC` — one `axi4_regslice` HDL+ core, two instances, inserted as a
  timing fix on the DIC target0<->ID_FIX and MSS-initiator<->CIC links (needed once RES2 added a
  6th/7th target and pushed placement density up).
- `FIC0MON` (`sar_fic0s_mon`) — new 7th CIC target @ `0x60006000` (AXI4-Lite), a FIC_0
  transaction monitor (v2: write channel + intra-burst read-throttle counters) used to produce
  the read-latency-bound diagnosis this change acted on, and to capture the A/B evidence below.
- Built and timing-gated via `create_fresh_project_ffv.tcl` -> `build_full_prog_ffv.tcl` in this
  repo (see `docs/USER_GUIDE.md` SS5).

## Firmware

- `sar_kernels.h`: `K_RESAMPLE2` register block mirroring `K_RESAMPLE`.
- `sar_sequencer.c`: `resample_2pass()`'s pass-1 gather double-buffers across RES/RES2 (even/odd
  lines), with 4 coefficient banks (2 lanes x double-buffer) instead of 2.
- Removed: the dead `DETMODE==2` HLS-detect firmware path (was already known-broken, unused now
  that detect is fabric-fused into the FFT-2 unloader).

## Why this was expected to work

The FIC0MON v2 diagnosis showed the FIC_0 data plane only ~25% occupied during a gather line
(16% read-busy + 9% write-busy), with 40% of the line spent with a read outstanding and DDR not
yet returning data, and 35% genuinely idle. A second lane stalling in parallel, rather than a
second lane's traffic serializing behind the first, was expected to hide most of that 40%+35%
idle/wait time under the first lane's own wait, since neither lane was expected to be
compute-bound.

## Why it did not deliver the projected win, and broke correctness

Silicon result (see tasks.md): only a 16% range-gather speedup (5.78 -> 4.85s) against a ~1.7-2x
projection, AND a correctness regression (a large corrupted band in the output image). The
FIC0MON capture for the very first line-pair showed the two lanes did NOT cleanly halve elapsed
time for that window (read-busy 14.7%, write-busy 8.4%, r_datawait 34.8%, idle ~42.2%) — evidence
that shared-FIC_0 contention/serialization ate into the parallelism gain even before accounting
for the correctness bug, i.e. the "FIC_0 is ~75% idle so two lanes fit for free" assumption
undercounted real contention between the two masters sharing one DDR controller and one
(now 7-target) control interconnect.

The corrupted-image band is a separate, structural defect on the exact code path this change
touched (new 4-bank coefficient indexing in `resample_2pass()`, or the RES2 lane's AXI-ID/write
routing through `DIC`) — not yet root-caused. Candidate causes to check first on any retry:
1. Coefficient bank selection logic for the odd (RES2) lane vs even (RES) lane in
   `resample_2pass()` — verify bank index arithmetic under double-buffering.
2. AXI-ID collision between the two concurrent resample masters through `DIC` — `RES2`'s
   initiator ID may alias `RES`'s under concurrent traffic if the ID-tag allocation was not
   widened/partitioned for a 2nd concurrent master (cf. `sar_axi_idconv.v`'s stash-table width,
   which upstream `RESAMPLE_PARALLELISM_STUDY.md` already flagged as keyed on only the AXI ID's
   low 4 bits as a known N>1 blocker for a *different* IP; verify the same class of issue was not
   reintroduced here for RES2 specifically).
