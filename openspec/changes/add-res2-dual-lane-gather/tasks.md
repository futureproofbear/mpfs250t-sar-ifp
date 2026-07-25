# Tasks: RES2 dual-lane range gather

- [x] Fabric: repurpose DET slot -> RES2 (2nd `resample_top`), add RSLICE_DIC/RSLICE_CIC timing
      regslices + FIC0MON monitor in `sartop_assembly.tcl`.
      **Verification: fabric rebuild TIMING MET.** `create_fresh_project_ffv.tcl` ->
      `build_full_prog_ffv.tcl`, 2026-07-25: authoritative multi-corner SETUP/HOLD reports both
      "No Path" (clean); `TIMING_MET (pre-progdata)`; layout unchanged by progdata;
      `BITSTREAM_DONE` / `FFV_BUILD_DONE`. `SAR_TOP_ffv.job` exported. DONE.
- [x] Firmware: `K_RESAMPLE2` register block + 2-lane double-buffered pass-1 gather in
      `resample_2pass()`, 4 coefficient banks; remove dead `DETMODE==2` path.
      **Verification: builds clean.** DONE.
- [x] Silicon A/B: program `SAR_TOP_ffv.job`, re-flash app, boot-load Centerfield scene from
      eMMC (ELOD verdict 0, CRC match), run PIPE (FFTMODE=1/GATHMODE=1/DETMODE=3/OVLMODE=1),
      compare RPROF[5] range-gather wallclock and FIC0MON slot-0 capture against the established
      single-lane baseline.
      **Verification: silicon iso-test case, this session, 2026-07-25.**
      Result: RPROF[5] 5.78s -> 4.85s (-16%, vs ~1.7-2x projected). Whole-pipeline 37.72s ->
      37.48s (-0.6%, negligible). FIC0MON line-0 capture: two lanes did not cleanly halve
      elapsed time for that window (read-busy 14.7% / write-busy 8.4% / r_datawait 34.8% /
      idle ~42.2%) -- contention ate into the projected win. DONE (result recorded below).
- [x] Correctness: value-level check (not correlation) of a 1024x1024 center-crop ROI against
      the known-good pre-RES2 baseline crop, per `sar-verification-methodology` /
      `docs/USER_GUIDE.md` SS7.4.
      **Verification: `mpfs/host/render_crop.py` + pixel diff vs `crop_100.bin` baseline
      (itself CRC-identical to 3 earlier independently-captured milestone crops).**
      Result: **FAIL.** 1,044,819 / 1,048,576 pixels (99.64%) differ, mean |diff| ~59.5, max
      |diff| 3048. Visual: a wide, heavily-attenuated dark band through the crop's middle third
      (peak magnitude 3069->79, ~13% of crop pixels collapse to exact zero vs 0% in baseline).
      Structured defect on the exact code path this change touched, not measurement noise.
      Evidence files: `mpfs/host/jtag_full/crop_res2.bin`/`.png` vs `crop_100.bin`/`.png`.
- [x] Verdict: **DO NOT COMMIT.** Per this project's standing rule (a faster-but-wrong result is
      not a win), RES2 stays out of the shipping design in its current form. `sartop_assembly.tcl`
      and `sar_sequencer.c`/`sar_kernels.h` RES2 changes remain uncommitted in the working tree.
      Full record: memory `res2-dual-lane-correctness-regression`.

## Reconsideration (not started)

If RES2 is revisited: root-cause the corrupted band first (see design.md candidate causes),
fix, then re-run the exact same 2-step verification above (RPROF[5]/FIC0MON A/B, then the
value-level crop diff) before trusting any new build. Do not skip straight to committing on a
clean timing build + a passing performance number alone -- that is exactly what this attempt did
and it shipped a silent 99.64%-of-pixels-wrong result had it not been caught.
