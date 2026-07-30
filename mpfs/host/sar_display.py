#!/usr/bin/env python
"""Gaussian (normal-score) contrast stretch for SAR magnitude images.

WHY NOT sqrt / log + percentile clip. SAR magnitude is Rayleigh-ish: a long bright tail over a dense
speckle floor. sqrt and log compress the tail but leave the histogram skewed, so a percentile clip
still spends most of the 8-bit range on a narrow band of speckle and the rest on near-empty tail.
Detail that is present in the data ends up rendered with a handful of grey levels.

The NORMAL SCORE TRANSFORM removes the guesswork: map each pixel to its own rank in the image, then
push that rank through the inverse Gaussian CDF. The output histogram is Gaussian BY CONSTRUCTION,
whatever the input distribution was, so every grey level carries the same number of pixels' worth of
information and the display no longer depends on picking the right clip percentiles.

Done via a 65536-bin histogram CDF, not argsort: an 8192x8192 image is 67M pixels, and sorting it
costs ~0.5 GB of index just to answer a question the CDF already answers exactly for uint16 input.

ZERO-PAD IS EXCLUDED from the mapping. A padded frame (5634 real pulses in an 8192 grid) is ~30%
exact zeros; including them puts a third of the Gaussian's mass on a single value and drags every
real pixel into the upper half of the range.
"""
import numpy as np


def normal_score(img, sigma=3.0, exclude_zero=True):
    """uint16/int magnitude -> uint8 with a Gaussian-distributed histogram.

    sigma: how many standard deviations map to the 0..255 range (3.0 keeps ~99.7% unclipped).
    """
    a = np.asarray(img)
    flat = a.ravel()
    lo, hi = int(flat.min()), int(flat.max())
    nb = hi - lo + 1
    counts = np.bincount((flat - lo).astype(np.int64), minlength=nb).astype(np.float64)
    if exclude_zero and lo <= 0 < lo + nb:
        counts[0 - lo] = 0.0                      # pad/zero-fill must not define the mapping
    tot = counts.sum()
    if tot <= 0:
        return np.zeros(a.shape, np.uint8)

    # midpoint CDF: use the centre of each value's probability mass, so the darkest and brightest
    # real values do not land exactly on 0 and 1 (where the Gaussian quantile is infinite).
    cdf = (np.cumsum(counts) - 0.5 * counts) / tot
    cdf = np.clip(cdf, 1e-9, 1 - 1e-9)

    from math import sqrt
    try:
        from scipy.special import erfinv
        z = sqrt(2.0) * erfinv(2.0 * cdf - 1.0)
    except Exception:                              # no scipy: invert the CDF numerically
        g = np.linspace(-8.0, 8.0, 200001)
        gc = 0.5 * (1.0 + np.vectorize(_erf)(g / sqrt(2.0)))
        z = np.interp(cdf, gc, g)

    lut = np.clip(128.0 + 127.0 * z / sigma, 0, 255).astype(np.uint8)
    if exclude_zero and lo <= 0 < lo + nb:
        lut[0 - lo] = 0                            # keep pad visibly black rather than mid-grey
    return lut[(a - lo).astype(np.int64)]


def multilook(img, n):
    """N x N block MEAN -- the correct way to shrink a SAR image.

    Striding (img[::n, ::n]) keeps 1 pixel in n^2 and throws the rest away. On single-look SAR that
    does not just lose detail, it ALIASES: speckle is full-bandwidth noise, so subsampling folds it
    back on itself and the preview looks noisier and softer than the data really is. Averaging the
    block instead is multilooking -- it reduces speckle standard deviation by sqrt(n^2) = n while
    preserving the underlying scene, which is why every SAR product ships multilooked."""
    a = np.asarray(img, np.float64)
    r, c = (a.shape[0] // n) * n, (a.shape[1] // n) * n
    return a[:r, :c].reshape(r // n, n, c // n, n).mean(axis=(1, 3))


def valid_extent(img, frac=0.25):
    """Rows/cols where the mean is above frac x the median -- i.e. the real scene, not the low-signal
    border a padded frame leaves behind. Returned as (r0, r1, c0, c1), inclusive.

    Cropping BEFORE the stretch matters: the border is ~5% of the frame here but it is the darkest
    5%, so leaving it in hands the bottom of the Gaussian to pixels that carry no scene at all and
    pushes the speckle floor up into mid-grey. That is what made the first render look flat."""
    a = np.asarray(img, np.float64)
    rm, cm = a.mean(axis=1), a.mean(axis=0)
    rok = np.where(rm > frac * np.median(rm))[0]
    cok = np.where(cm > frac * np.median(cm))[0]
    return int(rok.min()), int(rok.max()), int(cok.min()), int(cok.max())


def _erf(x):
    import math
    return math.erf(x)


if __name__ == "__main__":
    import argparse
    from pathlib import Path
    from PIL import Image

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("src", help=".npy magnitude image, or a raw uint16 .bin")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--shape", type=int, nargs=2, default=None, help="rows cols, for a .bin")
    ap.add_argument("--fftshift", action="store_true", help="centre DC before stretching")
    ap.add_argument("--deci", type=int, default=1, help="decimate for a preview")
    ap.add_argument("--look", type=int, default=1,
                    help="N x N multilook (block mean) -- prefer this over --deci for SAR")
    ap.add_argument("--sigma", type=float, default=3.0)
    ap.add_argument("--clip", action="store_true",
                    help="crop the low-signal pad border before stretching")
    a = ap.parse_args()

    p = Path(a.src)
    img = np.load(p) if p.suffix == ".npy" else np.fromfile(p, dtype=np.uint16).reshape(*a.shape)
    if a.fftshift:
        img = np.fft.fftshift(img)
    if a.clip:
        r0, r1, c0, c1 = valid_extent(img)
        print("  clip: rows %d..%d  cols %d..%d  (from %dx%d)" % (r0, r1, c0, c1, *img.shape))
        img = img[r0:r1 + 1, c0:c1 + 1]
    if a.look > 1:
        img = np.rint(multilook(img, a.look)).astype(np.int64)
    if a.deci > 1:
        img = img[::a.deci, ::a.deci]
    out = Path(a.out) if a.out else p.with_suffix(".gauss.png")
    Image.fromarray(normal_score(img, a.sigma)).save(out)
    print("wrote %s  (%dx%d, sigma=%.1f)" % (out, img.shape[0], img.shape[1], a.sigma))
