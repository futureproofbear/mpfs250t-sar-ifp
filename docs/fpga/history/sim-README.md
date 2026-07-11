# M1 CoreFFT co-simulation (QuestaSim)

Runs the FFT verification harness in real RTL: golden vectors from
`mpfs/host/fft_golden.py` → testbench `../corefft_fft_tb.v` → DUT → `rtl_out.hex`
→ `fft_golden.py check`.

## Run it (behavioral stand-in, no online IP needed)

```sh
cd mpfs/fpga/sim
python ../../host/fft_golden.py gen --n 64 --bits 16 --tw-bits 16 --twiddle --out fft_vectors
"$LIBERO/QuestaSim_Pro/win64/vsim.exe" -c -do run_m1.do
python ../../host/fft_golden.py check --expected fft_vectors/random_out.hex \
       --actual rtl_out.hex --corr-min 0.9999 --nrmse-max 0.05
```

Confirmed result (N=64): QuestaSim drives the full CoreFFT handshake
(`BUF_READY`/`DATAI_VALID`/`OUTP_READY`/`READ_OUTP`), captures `SCALE_EXP`, and the
checker reports **corr 1.000000, NRMSE 2.8e-04 → PASS** (scale auto-aligned).

`corefft_behav.v` is a BEHAVIORAL stand-in (true DFT + conditional-BFP output) used
only to prove the flow before the real IP exists. It is not bit-exact, so it is
checked in tolerance mode.

## Swap in the real Microchip CoreFFT

1. In Libero, generate CoreFFT (in-place): `POINTS=8192, WIDTH=16, SCALE=0,
   SCALE_EXP_ON=1` (see `M1_cosim.md`). This is the one step that needs the
   online IP catalog (or a pre-populated vault).
2. In `run_m1.do`, replace `corefft_behav.v` in the `vlog` line with the generated
   CoreFFT sources, and set `-gPOINTS=8192`.
3. Regenerate vectors with `--n 8192` and re-run. Same checker, same pass criteria.
