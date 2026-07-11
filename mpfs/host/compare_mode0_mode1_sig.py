"""Isolate the range-amplitude discrepancy: compare the azimuth-output SIG from the CPU-FFT path
(mode 0, known-good) vs the fabric-FFT path (mode 1), same band (rows 1008..1071). And each vs golden.

  fabric==CPU  => fabric FFT is fine; the golden mismatch is a reference/orientation artifact,
                  and the detect sign-bug is the real blocker.
  fabric!=CPU  => the fabric FFT path has a real range-amplitude bug (beyond detect).
"""
import numpy as np
N=8192; R0=1008
def load(p):
    raw=np.fromfile(p,dtype=np.uint32); nr=raw.size//N
    re=(raw>>16).astype(np.int16).astype(np.float64); im=(raw&0xFFFF).astype(np.int16).astype(np.float64)
    return (re+1j*im).reshape(nr,N)
fab=load("jtag_stage_small/sig_point.bin")            # mode 1 fabric
cpu=load("jtag_stage_small/sig_point_cpu.bin")        # mode 0 CPU
G=np.abs(np.load("jtag_stage_small/golden_small_mag.npy").astype(np.float64))[R0:R0+fab.shape[0],:]
mf=np.abs(fab); mc=np.abs(cpu)
def pk(m,name):
    r,c=np.unravel_index(m.argmax(),m.shape); print(f"  {name:12} peak={m.max():.0f} at (row {R0+r}, col {c}) mean={m.mean():.0f} pk/mean={m.max()/max(m.mean(),1):.1f}")
    return c
def lc(a,b):
    a=np.log1p(a).ravel(); b=np.log1p(b).ravel(); a=a-a.mean(); b=b-b.mean()
    d=np.linalg.norm(a)*np.linalg.norm(b); return float(a@b/d) if d else 0.0
print("peak locations (band rows 1008..1071):")
cf=pk(mf,"FABRIC m1"); cc=pk(mc,"CPU m0"); cg=pk(G,"GOLDEN")
print(f"\n  log-mag corr  CPU(m0) vs GOLDEN   = {lc(mc,G):.4f}   (CPU path is the known-good ref)")
print(f"  log-mag corr  FABRIC(m1) vs GOLDEN = {lc(mf,G):.4f}")
print(f"  log-mag corr  FABRIC(m1) vs CPU(m0)= {lc(mf,mc):.4f}   <-- THE isolation metric")
# complex ratio fabric/cpu on strong bins (are they the same image up to a scale?)
strong=mc>0.2*mc.max()
if strong.sum():
    ratio=fab[strong]/np.where(cpu[strong]==0,1,cpu[strong])
    print(f"  |fabric/cpu| on strong CPU bins: median={np.median(np.abs(ratio)):.3f} spread={np.std(np.abs(ratio)):.3f}")
print("\nVERDICT: if FABRIC-vs-CPU corr ~0.99 => fabric FFT fine, golden mismatch was a ref artifact,")
print("detect is the sole real bug. If low => fabric FFT path has a real amplitude/range fault too.")
