import numpy as np
B = np.fromfile('jtag_stage_small/out_bright.bin', dtype=np.uint16)
print('OUT band: %d samples, nonzero=%.1f%% max=%d mean=%.1f' % (
    B.size, 100*(B != 0).mean(), int(B.max()), B.mean()))
if (B != 0).sum() == 0:
    raise SystemExit('ALL ZERO')
B = B.reshape(256, 8192).astype(np.float64)          # OUT rows 896:1152
G = np.asarray(np.load('jtag_stage_small/golden_small_mag.npy')).astype(np.float64)

def corr(a, c):
    a = a.ravel() - a.mean(); c = c.ravel() - c.mean()
    d = np.linalg.norm(a) * np.linalg.norm(c)
    return float(a @ c / d) if d else 0.0

# board = fft2.T (per orientation analysis) => board rows 896:1152 == golden cols 896:1152 transposed
cands = {
    'direct         golden[896:1152,:]'   : G[896:1152, :],
    'TRANSPOSE      golden[:,896:1152].T'  : G[:, 896:1152].T,
    'T flipud'                             : G[:, 896:1152].T[::-1],
    'T fliplr'                             : G[:, 896:1152].T[:, ::-1],
    'direct flipud'                        : G[896:1152, :][::-1],
}
def logm(x): return np.log1p(np.abs(x))
print('--- raw magnitude correlation ---')
best = ('', -1)
for name, g in cands.items():
    cc = corr(B, g)
    if abs(cc) > abs(best[1]): best = (name, cc)
    print('  %-32s corr=%.4f' % (name, cc))
print('  BEST raw: %s = %.4f' % best)
print('--- log-magnitude correlation (reduces board 65535 saturation bias) ---')
bestl = ('', -1)
for name, g in cands.items():
    cc = corr(logm(B), logm(g))
    if abs(cc) > abs(bestl[1]): bestl = (name, cc)
    print('  %-32s corr=%.4f' % (name, cc))
print('  BEST log: %s = %.4f' % bestl)
