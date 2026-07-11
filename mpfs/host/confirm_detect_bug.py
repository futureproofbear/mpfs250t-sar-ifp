"""Confirm the detect kernel is the SOLE remaining bug: compute |SIG| (azimuth-FFT output) CORRECTLY
on the host from sig_band.bin (rows 896..1023) and correlate to golden. If this corr is high (~0.99)
while the fabric OUT corr is ~0, the pipeline data is right and only the fabric detect (unsigned-I
saturation) is wrong -> fixing detect fixes the image."""
import numpy as np

N = 8192
R0, R1 = 896, 1024                        # rows dumped
raw = np.fromfile("jtag_stage_small/sig_band.bin", dtype=np.uint32)
nrows = raw.size // N
re = (raw >> 16).astype(np.int16).astype(np.float64)     # signed I (done RIGHT here)
im = (raw & 0xFFFF).astype(np.int16).astype(np.float64)  # signed Q
mag = np.sqrt(re*re + im*im).reshape(nrows, N)            # correct |SIG|
print(f"host |SIG| band rows {R0}..{R0+nrows-1}: peak={mag.max():.0f} mean={mag.mean():.1f} median={np.median(mag):.0f}")
print(f"  fraction with I<0 (would saturate in fabric detect): {100*(re<0).mean():.1f}%")

G = np.load("jtag_stage_small/golden_small_mag.npy").astype(np.float64)

def corr(a, c):
    a = a.ravel()-a.mean(); c = c.ravel()-c.mean()
    d = np.linalg.norm(a)*np.linalg.norm(c)
    return float(a@c/d) if d else 0.0
def logm(x): return np.log1p(np.abs(x))

# orientation candidates (board = fft2.T per correlate_cpufft.py)
cands = {
    'direct  G[896:1024,:]'   : G[R0:R0+nrows, :],
    'TRANSPOSE G[:,896:1024].T': G[:, R0:R0+nrows].T,
    'T flipud'                : G[:, R0:R0+nrows].T[::-1],
    'T fliplr'                : G[:, R0:R0+nrows].T[:, ::-1],
    'direct flipud'           : G[R0:R0+nrows, :][::-1],
}
print("\n--- log-magnitude correlation of CORRECT host |SIG| vs golden ---")
best=('',-1)
for name,g in cands.items():
    if g.shape != mag.shape: continue
    cc = corr(logm(mag), logm(g))
    if abs(cc)>abs(best[1]): best=(name,cc)
    print(f"  {name:26} corr={cc:.4f}")
print(f"  BEST: {best[0]} = {best[1]:.4f}")
print("\nIf BEST ~0.99 => detect is the SOLE bug (FFT+pipeline data correct). Fixing detect's hi16")
print("sign-extension (rebuild) restores the image. If low => another fault remains upstream.")
