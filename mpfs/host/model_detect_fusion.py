#!/usr/bin/env python
"""Model the ROUNDING-ORDER question for fusing detect into the FFT unloader.

Detect is the largest structural target left (18.88 s, 23.7% of the 79.79 s pipeline) and the
only stage still on the CPU. Fusing it into the second FFT's unloader would delete a 512 MB
read + 128 MB write. But it REORDERS the fixed-point arithmetic, so the pipeline CRC
(0xd596c9eb) can no longer gate it -- and unlike the window fusion there is no bit-identical
target to aim at. This script answers, BEFORE any RTL is written: how different is the result,
and is the fused order better or worse than what ships today?

  A = SHIPPING order      FFT -> shift by (emax-e) -> saturate int16 -> sqrt(re^2+im^2)
  B = FUSED order         FFT -> sqrt(re^2+im^2) at the row's native exponent -> shift magnitude

B should be MORE accurate: it takes the magnitude at full internal precision and only then
discards bits, whereas A throws away low bits (and saturates) before the sqrt ever runs. The
question is how much, and whether it matters at the exponent spreads this pipeline actually
produces -- so the spread is swept rather than assumed.

Both are compared against a float reference (same FFT, no fixed-point quantization at all),
which is the only way to say which order is *better* rather than merely different.

Run:  python mpfs/host/model_detect_fusion.py
"""
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))
import fixedpoint as fx  # noqa: E402


def _sat16(x):
    return np.clip(np.floor(x + 0.0), -32768, 32767)


def order_A_shipping(y, e):
    """FFT -> global renorm (shift + int16 saturate) -> detect. What silicon does today."""
    emax = int(e.max())
    sh = (emax - e)[..., None]
    yr = np.floor(y.real / (2.0 ** sh))
    yi = np.floor(y.imag / (2.0 ** sh))
    re = _sat16(yr).astype(np.int64)
    im = _sat16(yi).astype(np.int64)
    m = np.floor(np.sqrt((re * re + im * im).astype(np.float64)))
    return np.clip(m, 0, 0xFFFF).astype(np.uint16)


def order_B_fused(y, e):
    """FFT -> detect at the row's native exponent -> shift the MAGNITUDE. The fused proposal.

    The unloader sees CoreFFT's output before any global renormalize, so it must take the
    magnitude first; the (emax - e) shift is then applied to a real uint magnitude instead of
    to the complex pair. Magnitude scales linearly, so this is algebraically equivalent -- it
    differs only in where the truncation happens.
    """
    emax = int(e.max())
    sh = (emax - e)[..., None]
    re = y.real.astype(np.float64)          # full internal precision, no int16 clamp yet
    im = y.imag.astype(np.float64)
    m = np.sqrt(re * re + im * im)
    m = np.floor(m / (2.0 ** sh))
    return np.clip(m, 0, 0xFFFF).astype(np.uint16)


def reference_float(x):
    """No fixed point anywhere: the value both orders are trying to approximate."""
    y = np.fft.fft(x, axis=-1)
    return np.abs(y)


def make_frame(rows, n, spread_bits, rng):
    """Complex int16 frame whose per-row energy spans `spread_bits` powers of two.

    Row-to-row dynamic range drives (emax - e), the variable that decides whether the two
    orders diverge -- a flat frame hides the effect entirely.

    NOTE the ceiling: the input is int16, so a row scaled far enough down quantizes to all
    zeros and its BFP exponent goes degenerate rather than small. Naively sweeping to 2^-16
    therefore produced a FLAT exp spread of 2 and a falsely reassuring result. The top row is
    pinned near full scale and the bottom row is held at >= MIN_PEAK counts so every row
    survives quantization and the requested spread is actually realised.
    """
    MIN_PEAK = 64.0                      # ~6 bits above the LSB; below this a row degenerates
    TOP_PEAK = 8000.0
    max_bits = np.log2(TOP_PEAK / MIN_PEAK)
    eff = min(spread_bits, max_bits)     # what int16 can actually represent
    x = rng.standard_normal((rows, n)) + 1j * rng.standard_normal((rows, n))
    x *= TOP_PEAK / np.abs(x).max()
    scale = 2.0 ** (-eff * np.arange(rows) / max(rows - 1, 1))
    x *= scale[:, None]
    q = _sat16(x.real) + 1j * _sat16(x.imag)
    if (np.abs(q).max(axis=-1) == 0).any():
        raise RuntimeError("a row quantized to all-zero -- MIN_PEAK too low, result would lie")
    return q, eff


def corr(a, b):
    a = a.astype(np.float64).ravel(); b = b.astype(np.float64).ravel()
    a = a - a.mean(); b = b - b.mean()
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return float(a @ b / d) if d else float("nan")


def main():
    rng = np.random.default_rng(20260721)
    rows, n = 64, 256          # small enough to be fast; BFP behaviour is per-row so it scales

    print(f"frame {rows}x{n}, per-row BFP FFT, sweeping row-energy spread\n")
    print(f"{'spread':>7} {'exp sprd':>9} {'A==B %':>8} {'maxdiff':>8} {'rms':>8} "
          f"{'corr(A,B)':>10} {'A vs float':>11} {'B vs float':>11}  verdict")

    for spread_bits in (0, 2, 4, 6, 7):
        x, eff = make_frame(rows, n, spread_bits, rng)
        if eff < spread_bits:
            print(f"  (spread {spread_bits} clipped to {eff:.1f} bits -- int16 input floor)")
        y, e = fx.fft1d_bfp_hw_perrow(x, 16, 16, fx._bitrev_perm(n))

        A = order_A_shipping(y, e)
        B = order_B_fused(y, e)
        R = reference_float(x)

        same = 100.0 * (A == B).mean()
        diff = np.abs(A.astype(np.int64) - B.astype(np.int64))
        cA, cB = corr(A, R), corr(B, R)
        verdict = "B closer" if cB > cA else ("A closer" if cA > cB else "tie")

        print(f"{spread_bits:>7} {int(e.max()-e.min()):>9} {same:>7.2f}% {diff.max():>8} "
              f"{np.sqrt((diff.astype(float)**2).mean()):>8.2f} {corr(A,B):>10.6f} "
              f"{cA:>11.6f} {cB:>11.6f}  {verdict}")

    print("\nReading it: 'A==B %' is how often the two orders agree exactly -- anything below")
    print("100% means the pipeline CRC changes and can no longer gate this gate. The two")
    print("'vs float' columns are the ones that matter for whether the change is an")
    print("IMPROVEMENT: higher is closer to the un-quantized answer.")


if __name__ == "__main__":
    main()
