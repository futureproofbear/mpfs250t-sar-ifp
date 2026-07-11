"""VALUE-level diff (not correlation) of the injected fabric range-FFT (A2). Compares the silicon
SCRATCH dump (rows 0..K-1) against the bit-accurate model fft1d_bfp_hw_perrow + firmware global
renormalize on the SAME injected codes -- element by element (real AND imag).

Run from mpfs/host after inject_fft_value.gdb dumps scratch_inject.bin + prints sar_row_exp:
  python fft_value_compare.py
"""
import numpy as np, sys
sys.path.insert(0, "../../src")
import fixedpoint as fx

N = 8192
d = "jtag_stage_small/"
codes = np.load(d + "inject_codes.npy")          # (K, N) injected known rows
K = codes.shape[0]

# bit-accurate per-row BFP FFT + firmware global renorm (rows K..8191 are zero -> exp 0, so emax is
# the max over the injected rows == what the firmware computes over all rows)
y, exp = fx.fft1d_bfp_hw_perrow(codes, 16, 16, fx._bitrev_perm(N))
emax = int(exp.max())
def shr(v, s): return np.floor(v.real/(2.0**s)) + 1j*np.floor(v.imag/(2.0**s))
model = np.empty_like(y)
for r in range(K):
    model[r] = shr(y[r], emax - int(exp[r]))
model = np.clip(model.real, -32768, 32767) + 1j*np.clip(model.imag, -32768, 32767)

print(f"MODEL per-row exponents: {[int(e) for e in exp]}  (emax={emax})")
print("  -> a HEALTHY capture reads these same values in sar_row_exp[0..%d]; uniform => broken\n" % (K-1))

raw = np.fromfile(d + "scratch_inject.bin", dtype=np.uint32)
if raw.size < K*N:
    raise SystemExit(f"dump has {raw.size} words, need {K*N}; run inject_fft_value.gdb first")
re = (raw[:K*N] >> 16).astype(np.int16).astype(np.float64)
im = (raw[:K*N] & 0xFFFF).astype(np.int16).astype(np.float64)
sil = (re + 1j*im).reshape(K, N)

names = ["DC8000", "DC500", "tone@5", "tone@100+ph", "2tone40dB", "broadband", "tiny-bb", "fullscale"]
print(f"{'row':13} {'exact/8192':>11} {'max|diff|':>9} {'model|peak|':>11} {'sil|peak|':>10}")
worst = 0.0
for r in range(K):
    dd = np.abs(sil[r] - model[r])
    exact = int((sil[r] == model[r]).sum())
    worst = max(worst, dd.max())
    print(f"{names[r] if r<len(names) else 'row%d'%r:13} {exact:>6}/8192 {dd.max():>9.0f} "
          f"{np.abs(model[r]).max():>11.0f} {np.abs(sil[r]).max():>10.0f}")
print(f"\nWORST |diff| across all rows = {worst:.0f}")
print("VERDICT:", "VALUES MATCH model -- fabric range-FFT+renorm is bit-correct at the VALUE level"
      if worst <= 1 else
      "VALUES DIVERGE -- localize: which rows differ, and is sar_row_exp uniform vs the model exps above?")
