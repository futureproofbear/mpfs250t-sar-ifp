"""VALUE-level check (not correlation) of the fabric range-FFT + SCALE_EXP capture + renormalize,
using the on-chip 'SCLE' known input: row0 = DC 8000, row1 = DC 500, rows 2..N = 0.

A DC row of constant V has FFT = (N*V) at bin0, 0 elsewhere -- an ANALYTIC golden. The bit-accurate
model (fft1d_bfp_hw_perrow = exactly what CoreFFT does) predicts each row's mantissa + block exponent;
the firmware global-renormalize then puts both rows on one exponent, so SCRATCH row0/row1 bin0 must be
in the SAME 16:1 ratio as the input AND equal the model's predicted int16 values bit-for-bit.

Broken SCALE_EXP capture (rows read the same/wrong exp) => renorm wrong => ratio != 16:1 and values
!= model. Correlation is BLIND to this (per-row scale-invariant); the VALUES are not.

Run from mpfs/host (after scle_value.gdb dumps scratch_scle.bin + prints sar_row_exp):
  python fabric_scale_value.py [exp0_read exp1_read]
"""
import sys, numpy as np
sys.path.insert(0, "../../src")
import fixedpoint as fx

N = 8192
DUMP = "jtag_stage_small/scratch_scle.bin"   # SCRATCH rows 0,1,2 (3 * 32768 bytes) from scle_value.gdb

# --- build the exact 'SCLE' input rows (only the nonzero ones matter; per-row FFT is independent) ---
rows = np.zeros((3, N), dtype=complex)
rows[0, :] = 8000.0      # row0 DC
rows[1, :] = 500.0       # row1 DC
# row2 stays 0 -> FFT 0, exp 0

# --- bit-accurate per-row BFP FFT (mantissa + per-row exponent) ---
y, exp = fx.fft1d_bfp_hw_perrow(rows, 16, 16, fx._bitrev_perm(N))
emax = int(exp.max())
# firmware global renormalize: row >>= (emax - exp_row)  (arithmetic floor)
def shr(v, s):
    return np.floor(v.real / (2.0**s)) + 1j*np.floor(v.imag / (2.0**s))
model = np.empty_like(y)
for r in range(3):
    model[r] = shr(y[r], emax - int(exp[r]))
model = np.clip(model.real, -32768, 32767) + 1j*np.clip(model.imag, -32768, 32767)

print(f"MODEL (bit-accurate) prediction for the 'SCLE' input:")
print(f"  per-row block exponents: row0={int(exp[0])}  row1={int(exp[1])}  row2={int(exp[2])}  (emax={emax})")
print(f"  expected SCRATCH bin0:  row0={model[0,0]:.0f}   row1={model[1,0]:.0f}   ratio={abs(model[0,0])/max(abs(model[1,0]),1):.2f} (want 16.0)")
print(f"  expected non-bin0:      row0[1..]=0, row1[1..]=0 (DC input -> single spike)")

try:
    raw = np.fromfile(DUMP, dtype=np.uint32)
    if raw.size < 3*N:
        raise SystemExit(f"dump too short ({raw.size} words, need {3*N}); run scle_value.gdb first")
    re = (raw >> 16).astype(np.int16).astype(np.float64)
    im = (raw & 0xFFFF).astype(np.int16).astype(np.float64)
    sil = (re + 1j*im).reshape(3, N)
    print("\nSILICON dumped SCRATCH:")
    print(f"  bin0:  row0={sil[0,0]:.0f}   row1={sil[1,0]:.0f}   ratio={abs(sil[0,0])/max(abs(sil[1,0]),1):.2f}")
    print(f"  row0 max|non-bin0|={np.abs(sil[0,1:]).max():.0f}   row1 max|non-bin0|={np.abs(sil[1,1:]).max():.0f}  (want 0)")
    print(f"  row2 max|.|={np.abs(sil[2]).max():.0f} (zero-input row, want 0)")
    # VALUE diff (complex, element-by-element)
    d = np.abs(sil - model)
    print("\nVALUE DIFF (silicon - model), per row:")
    for r in range(3):
        exact = int((sil[r] == model[r]).sum())
        print(f"  row{r}: exact-match {exact}/{N} bins  max|diff|={d[r].max():.0f}  bin0 diff={abs(sil[r,0]-model[r,0]):.0f}")
    ok = d.max() <= 1
    print(f"\nVERDICT: {'VALUES MATCH model (fabric range-FFT+renorm bit-correct)' if ok else 'VALUES DIVERGE from model -- capture/renorm/data bug at the VALUE level'}")
except FileNotFoundError:
    print(f"\n(no silicon dump yet at {DUMP} -- run scle_value.gdb on the board first)")
