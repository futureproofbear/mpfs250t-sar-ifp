import numpy as np, matplotlib
matplotlib.use('Agg'); import matplotlib.pyplot as plt
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
import os
# repo root, derived from this file's location (mpfs/host/show_cf.py -> ../..)
base = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
det = np.asarray(Image.open(base + r"\output\2023-10-10-16-57-44_UMBRA-04_detected.tif")).astype(np.float64)
gec = np.asarray(Image.open(base + r"\data\sar-data\tasks\Centerfield, Utah\c0dbd830-e863-42c5-97d0-2cfd291bcb2a\2023-10-10-16-57-44_UMBRA-04\2023-10-10-16-57-44_UMBRA-04_GEC.tif")).astype(np.float64)
print('our detected:', det.shape, 'range', det.min(), det.max())
print('vendor GEC  :', gec.shape, 'range', gec.min(), gec.max())

def disp(a):
    a = np.log1p(np.abs(a)); lo, hi = np.percentile(a, [30, 99.5]); return np.clip((a - lo) / (hi - lo + 1e-9), 0, 1)

d = np.fft.fftshift(det)[::16, ::16]
g = gec[::8, ::8]
fig, ax = plt.subplots(1, 2, figsize=(14, 7))
ax[0].imshow(disp(d), cmap='gray'); ax[0].set_title('OUR focused Centerfield (8192^2, fftshift)')
ax[1].imshow(disp(g), cmap='gray'); ax[1].set_title('VENDOR GEC reference (4060^2)')
for a in ax: a.axis('off')
plt.tight_layout(); plt.savefig(base + r"\mpfs\host\centerfield_compare.png", dpi=95)
print('saved centerfield_compare.png')
