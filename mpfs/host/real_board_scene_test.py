"""Reconstruct the EXACT scene the board ran -- from jtag_stage_small/sig.bin + the serialized
geometry (no CPHD) -- mirroring sar_sequencer.c resample_2pass + window, then run the CPU and
FABRIC BFP models on it and correlate against the board's own golden (golden_small_mag.npy).
This is the faithful test of the frame that actually gives corr~0 on silicon."""
import sys, numpy as np
sys.path.insert(0, "../../src"); sys.path.insert(0, ".")
import fixedpoint as fx
from emulate_fabric import interp_coeffs, _apply
from model_fabric_fft import fft2_fabric_perrow_renorm, fft2_fabric_NORENORM, corr

C = 299_792_458.0
d = "jtag_stage_small/"
GRID = 8192
M, N = 705, 540                                   # pulses x samples (from f0/kr sizes)

sig = np.fromfile(d + "sig.bin", dtype=np.int16).astype(np.float32).view()
sig = (sig[0::2] + 1j * sig[1::2]).reshape(M, N)   # complex int16, (I,Q) interleaved
f0 = np.fromfile(d + "f0.bin", dtype=np.float32)
df = np.fromfile(d + "df.bin", dtype=np.float32)
pr = np.fromfile(d + "pr.bin", dtype=np.float32)
tan_s = np.fromfile(d + "tans.bin", dtype=np.float32)               # sorted tan_phi
inv_order = np.fromfile(d + "invorder.bin", dtype=np.int32)
KRp = np.fromfile(d + "krgrid.bin", dtype=np.float32)              # padded to GRID
KCp = np.fromfile(d + "kcgrid.bin", dtype=np.float32)
hamr = np.fromfile(d + "hamr.bin", dtype=np.int16).astype(np.float64) / 32768.0
hamc = np.fromfile(d + "hamc.bin", dtype=np.int16).astype(np.float64) / 32768.0
print(f"loaded board scene sig {sig.shape}, geometry grid {GRID}")

# --- PASS 1 (range) : per pulse -> scratch[inv_order[i]] ---
scratch = np.zeros((GRID, GRID), np.complex64)
for i in range(M):
    kr_i = (2.0 * pr[i] / C) * (f0[i] + np.arange(N) * df[i])
    idx, wq = interp_coeffs(KRp, kr_i)
    scratch[inv_order[i]] = _apply(sig[i], idx, wq)
sig_t = scratch.T.copy(); del scratch
# --- PASS 2 (azimuth) : per range bin ---
g2 = np.zeros((GRID, GRID), np.complex64)
for j in range(GRID):
    src = KRp[j] * tan_s
    idx, wq = interp_coeffs(KCp, src)
    g2[j] = _apply(sig_t[j, :M], idx, wq)
del sig_t
g2w = (g2 * np.outer(hamr, hamc)).astype(np.complex64); del g2

# quantize to int16 codes (fabric input quantizer)
lsb, _ = fx.fit_scale(g2w, 16)
codes = (np.floor(g2w.real / lsb) + 1j * np.floor(g2w.imag / lsb)).astype(np.complex64); del g2w

G = np.load(d + "golden_small_mag.npy").astype(np.float64)         # board's reference
print("running CPU / FABRIC / NO-renorm models on the exact board scene ...")
cpu, _ = fx.fft2_l1bfp(codes)
fab, (emr, ema, er, ea) = fft2_fabric_perrow_renorm(codes)
nrn, (nr, na, ner, nea) = fft2_fabric_NORENORM(codes)
print("\n=== EXACT BOARD SCENE (sig.bin), grid", GRID, "vs golden_small_mag ===")
print(f"  CPU (global BFP)          corr = {corr(G, cpu):.4f}   (board CPU path = 0.9923)")
print(f"  FABRIC (per-row + renorm) corr = {corr(G, fab):.4f}")
print(f"  FABRIC NO-renorm          corr = {corr(G, nrn):.4f}")
print(f"  per-row exp spread: range={int(ner.max()-ner.min())} azimuth={int(nea.max()-nea.min())}")
