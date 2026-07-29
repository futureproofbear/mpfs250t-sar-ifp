#!/usr/bin/env python
"""interp_kernel_study.py -- which interpolation kernel is worth building, measured.

WHY THIS EXISTS. resample_v_status.md proposed a Farrow/Lagrange cubic as the upgrade path from
the shipping 2-tap lerp. Measured on 2026-07-29, that recommendation is WRONG in two ways, and
both only show up if you measure the right thing:

 1. MEASURE COMPLEX ERROR, NOT MAGNITUDE. A magnitude-only comparison made 2-tap windowed sinc
    look +3.03 dB better than linear; on complex error the two are identical (-4.2 vs -4.3 dB).
    It had flat |H| and the wrong delay. For SAR that is a phase error, i.e. defocus. This is the
    project's own "correlation lies, test by value" rule showing up in the frequency domain.

 2. LAGRANGE IS THE WRONG FAMILY. It is maximally flat at DC, so it spends its accuracy where a
    SAR phase history has least energy. At the shipping operating point (~97.8% of Nyquist,
    sinc_resample_study.py) going 2 -> 16 taps buys under 1 dB, for ANY family -- that is the
    information-theoretic wall near Nyquist, where half-sample values are barely determined.
    At 1.2x oversample (0.815 Nyquist) taps start paying, and there Lagrange still SATURATES at
    -16 dB while sinc reaches -33 dB.

THE RESULT THAT MATTERS. At 4 taps -- the same datapath, banking and MAC count a cubic needs --
DC-normalised truncated sinc beats Lagrange by ~8 dB, and at 8 taps raw sinc beats it by ~12 dB.
So the upgrade is a COEFFICIENT TABLE change, not a different architecture.

CAVEAT, do not skip: raw truncated sinc is NON-MONOTONIC in tap count (8 taps beats 12) because
hard truncation rings. Always measure the exact tap count you intend to build.

Usage:  python interp_kernel_study.py [--fn 0.978] [--taps 2,4,8,16]
"""
import argparse

import numpy as np

MU = np.arange(1, 32768, 509) / 32768.0     # fractional delays, excluding the trivial mu=0


def _pos(n):
    """Tap positions, centred so mu in [0,1) sits between taps 0 and 1."""
    lo = -((n // 2) - 1)
    return np.arange(lo, lo + n)


def k_lagrange(n, mu):
    p = _pos(n)
    c = np.ones(n)
    for i in range(n):
        for j in range(n):
            if i != j:
                c[i] *= (mu - p[j]) / (p[i] - p[j])
    return c, p


def k_sinc_raw(n, mu):
    p = _pos(n)
    return np.sinc(mu - p), p


def k_sinc_norm(n, mu):
    c, p = k_sinc_raw(n, mu)
    return c / np.sum(c), p          # unity DC gain, else a gain error rides on every sample


def k_sinc_hamming(n, mu):
    p = _pos(n)
    x = mu - p
    c = np.sinc(x) * (0.54 + 0.46 * np.cos(2 * np.pi * x / n))
    return c / np.sum(c), p


KERNELS = [("Lagrange", k_lagrange), ("sinc raw", k_sinc_raw),
           ("sinc norm", k_sinc_norm), ("sinc+Ham", k_sinc_hamming)]


def complex_error_db(kernel, n, fn):
    """Mean |H(w) - e^{-j w mu}| over mu, in dB. Captures PHASE and magnitude together."""
    w = np.pi * fn
    e = [abs(np.sum(c * np.exp(-1j * w * p)) - np.exp(-1j * w * mu))
         for mu, (c, p) in ((m, kernel(n, m)) for m in MU)]
    return 20.0 * np.log10(np.mean(e))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fn", default="0.815,0.978",
                    help="band edge as a fraction of Nyquist. 0.978 = the shipping scene; "
                         "0.815 = the same content at 1.2x oversample")
    ap.add_argument("--taps", default="2,4,6,8,12,16")
    a = ap.parse_args()

    taps = [int(x) for x in a.taps.split(",")]
    for fn in (float(x) for x in a.fn.split(",")):
        print(f"\n  complex error (dB) at {fn:.3f} Nyquist   -- lower is better")
        print("  taps | " + " ".join(f"{name:>9s}" for name, _ in KERNELS))
        for n in taps:
            row = [complex_error_db(k, n, fn) for _, k in KERNELS]
            best = min(range(len(row)), key=lambda i: row[i])
            # marker SUFFIXED, not prefixed: a leading "*" reads as belonging to the
            # column on its left, which is exactly the kind of misread this study exists to avoid
            cells = " ".join(f"{v:8.1f}" + ("*" if i == best else " ") for i, v in enumerate(row))
            print(f"   {n:2d}  |{cells}")
        print("        (* = best at that tap count)")
    print("\n  Reading it: at the tap counts worth building (4-8), truncated sinc beats Lagrange")
    print("  by 8-12 dB for IDENTICAL hardware. Near Nyquist (0.978) no kernel of any order")
    print("  helps -- fix the operating point, not the kernel.")


if __name__ == "__main__":
    main()
