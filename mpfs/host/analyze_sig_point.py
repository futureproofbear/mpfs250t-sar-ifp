"""Does the fabric focused point (host-|SIG|, rows 1008..1071) land where golden's point is
(row 1039, col 7152)? Correlate to golden in all orientations and report the fabric peak location.
Settles whether the azimuth/corner-turn output is geometrically correct (=> detect is the sole bug)
or displaced (=> an upstream fault too)."""
import numpy as np
N=8192; R0=1008
raw=np.fromfile("jtag_stage_small/sig_point.bin",dtype=np.uint32)
nr=raw.size//N
re=(raw>>16).astype(np.int16).astype(np.float64); im=(raw&0xFFFF).astype(np.int16).astype(np.float64)
m=np.sqrt(re*re+im*im).reshape(nr,N)
pr,pc=np.unravel_index(m.argmax(),m.shape)
print(f"fabric |SIG| band rows {R0}..{R0+nr-1}: peak={m.max():.0f} at row {R0+pr}, col {pc}; mean={m.mean():.0f} peak/mean={m.max()/max(m.mean(),1):.1f}")
print(f"golden focused point is at row 1039, col 7152.  fabric point col={pc} ({'MATCH col~7152' if abs(pc-7152)<64 else 'DIFFERENT col'})")
G=np.load("jtag_stage_small/golden_small_mag.npy").astype(np.float64)
def corr(a,c):
    a=np.log1p(a).ravel(); c=np.log1p(np.abs(c)).ravel(); a=a-a.mean(); c=c-c.mean()
    d=np.linalg.norm(a)*np.linalg.norm(c); return float(a@c/d) if d else 0.0
cands={'direct G[1008:1072,:]':G[R0:R0+nr,:], 'flipud':G[R0:R0+nr,:][::-1],
       'fliplr':G[R0:R0+nr,:][:,::-1], 'TRANSPOSE G[:,1008:1072].T':G[:,R0:R0+nr].T}
print("--- log-mag corr host|SIG| vs golden (energy region) ---")
best=(-9,'')
for k,g in cands.items():
    if g.shape!=m.shape:
        print(f"  {k:26} (shape {g.shape} != {m.shape}, skip)"); continue
    c=corr(m,g);
    if c>best[0]: best=(c,k)
    print(f"  {k:26} corr={c:.4f}")
print(f"  BEST direct-comparable = {best[0]:.4f} [{best[1]}]")
print("\n~0.9 => fabric image geometrically correct => detect is the sole bug (fix+rebuild).")
print("low + point at wrong col => azimuth/corner-turn also wrong => more than detect.")
