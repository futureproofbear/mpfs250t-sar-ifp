#!/usr/bin/env python
"""Is a sinc kernel even WELL-POSED for pass 2? Measure it on the real CPHD.

WHY THIS RUNS BEFORE ANY RTL. Pass 1's 32-tap sinc is exact by construction: the source grid is
    x[j] = x0 + j*dx
i.e. uniformly spaced, so the coefficient for tap n at fractional offset mu is exactly
sinc(n-15-mu) and nothing is approximated.

Pass 2 is NOT that. Its source abscissa is tau[m] = tan(phi_m), which is NON-uniform -- that is the
whole reason pass 2 needs a merge scan instead of a division. A sinc kernel indexed by mu implicitly
assumes the 32 taps under the window are EQUALLY SPACED. They are not. So azimuth sinc is an
approximation whose error depends on how curved tan(phi) is across 32 consecutive pulses.

If tau is locally near-linear the approximation is excellent and the pass-1 core ports across almost
unchanged. If it is not, indexing a sinc by mu is simply the wrong kernel and we would be building a
core that degrades the image while looking correct in every bit-exactness bench (which compares RTL
against the same wrong model).

Also checks the 32-tap EDGE fraction, which matters far more in pass 2 than pass 1: the pass-2 row
is M pulses (705 for NDSU) against pass 1's 8192, so a 31-sample edge region is ~10x more of the row.

Run:  python mpfs/host/check_pass2_sinc_uniformity.py [--cphd PATH] [--deci N]
"""
import argparse
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
import sys
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))
import form_image_pfa as ref                    # noqa: E402
from sar_pipeline import prepare_tables         # noqa: E402

TAPS, LOG2P = 32, 8
PHASES = 1 << LOG2P


def sinc_taps(mu, taps=TAPS):
    """Pass-1 kernel: DC-normalised sinc, tap n at offset n - (taps/2 - 1) - mu."""
    n = np.arange(taps)
    c = np.sinc(n - (taps // 2 - 1) - mu)
    return c / c.sum()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cphd", default="data/umbra_ndsu_20231110/2023-11-10-16-16-44_UMBRA-04_CPHD.cphd")
    ap.add_argument("--deci", type=int, default=1)
    a = ap.parse_args()

    root = HERE.parents[1]
    path = (root / a.cphd) if not Path(a.cphd).is_absolute() else Path(a.cphd)
    print(f"scene: {path.name}  deci={a.deci}")
    reader = ref.open_phase_history(str(path))
    t = prepare_tables(reader, reader.cphd_meta, a.deci, a.deci)
    reader.close()

    m, n = t["dims"]
    tan_phi = np.asarray(t["tan_phi"], dtype=np.float64)
    tau = np.sort(tan_phi)
    M = tau.size
    KC = np.asarray(t["KC"], dtype=np.float64)
    KR = np.asarray(t["KR"], dtype=np.float64)
    print(f"dims: M={m} pulses x N={n} samples;  tau has {M} entries, "
          f"span {tau[0]:.6f} .. {tau[-1]:.6f}\n")

    # ---- 1. how non-uniform is tau, globally and locally? ----
    d = np.diff(tau)
    print("1. SPACING of tau = tan(phi), sorted")
    print(f"   global: min {d.min():.6e}  max {d.max():.6e}  "
          f"max/min = {d.max()/d.min():.4f}")
    # local: within each sliding 32-tap window, how much does the spacing vary?
    W = TAPS
    loc = []
    for k in range(0, M - W):
        dw = d[k:k + W - 1]
        loc.append(dw.max() / dw.min())
    loc = np.array(loc)
    print(f"   within a 32-tap window: max/min spacing  median {np.median(loc):.6f}  "
          f"worst {loc.max():.6f}")
    print("   (1.0 == perfectly uniform under the window, i.e. sinc is exact there)\n")

    # ---- 2. what does that non-uniformity DO to the interpolated value? ----
    # Reconstruct a known band-limited signal on the tau grid, interpolate at a query point with
    # (a) the pass-1 sinc kernel indexed by mu, (b) 2-tap lerp, and compare against truth.
    print("2. RECONSTRUCTION ERROR on a band-limited test signal sampled at tau")
    print("   signal: sum of complex exponentials in the tau variable, band-limited to the")
    print("   Nyquist implied by the MEAN tau spacing; error measured at random query points.")
    rng = np.random.default_rng(0)
    dmean = d.mean()
    fny = 0.5 / dmean                       # Nyquist in cycles per unit tau
    ntone = 24
    for bw_frac in (0.4, 0.6, 0.8):
        freqs = rng.uniform(-bw_frac * fny, bw_frac * fny, ntone)
        phase = rng.uniform(0, 2 * np.pi, ntone)

        def sig(x):
            return np.exp(1j * (2 * np.pi * np.outer(x, freqs) + phase)).sum(axis=1)

        s = sig(tau)
        # query points strictly inside the 32-tap support
        qi = rng.integers(TAPS, M - TAPS, size=4000)
        frac = rng.uniform(0, 1, size=qi.size)
        u = tau[qi] + frac * (tau[qi + 1] - tau[qi])
        truth = sig(u)

        mu = (u - tau[qi]) / (tau[qi + 1] - tau[qi])
        # (a) sinc indexed by mu, taps at qi-15 .. qi+16
        est_s = np.zeros(qi.size, complex)
        for i, (k, mm) in enumerate(zip(qi, mu)):
            c = sinc_taps(mm)
            est_s[i] = c @ s[k - (TAPS // 2 - 1): k + TAPS // 2 + 1]
        # (b) 2-tap lerp
        est_l = (1 - mu) * s[qi] + mu * s[qi + 1]

        def db(e):
            return 20 * np.log10(np.linalg.norm(e) / np.linalg.norm(truth) + 1e-300)
        print(f"   bandwidth {bw_frac:.1f}*Nyquist :  lerp {db(est_l - truth):7.2f} dB   "
              f"sinc(mu) {db(est_s - truth):7.2f} dB   gain {db(est_l-truth)-db(est_s-truth):6.2f} dB")

    # ---- 3. control: the SAME test on a perfectly uniform grid (pass-1 conditions) ----
    print("\n3. CONTROL -- identical test on a UNIFORM grid (what pass 1 sees)")
    tu = np.linspace(tau[0], tau[-1], M)
    du = tu[1] - tu[0]
    fny_u = 0.5 / du
    for bw_frac in (0.4, 0.6, 0.8):
        freqs = rng.uniform(-bw_frac * fny_u, bw_frac * fny_u, ntone)
        phase = rng.uniform(0, 2 * np.pi, ntone)

        def sig(x):
            return np.exp(1j * (2 * np.pi * np.outer(x, freqs) + phase)).sum(axis=1)

        s = sig(tu)
        qi = rng.integers(TAPS, M - TAPS, size=4000)
        frac = rng.uniform(0, 1, size=qi.size)
        u = tu[qi] + frac * du
        truth = sig(u)
        mu = frac
        est_s = np.zeros(qi.size, complex)
        for i, (k, mm) in enumerate(zip(qi, mu)):
            c = sinc_taps(mm)
            est_s[i] = c @ s[k - (TAPS // 2 - 1): k + TAPS // 2 + 1]
        est_l = (1 - mu) * s[qi] + mu * s[qi + 1]

        def db(e):
            return 20 * np.log10(np.linalg.norm(e) / np.linalg.norm(truth) + 1e-300)
        print(f"   bandwidth {bw_frac:.1f}*Nyquist :  lerp {db(est_l - truth):7.2f} dB   "
              f"sinc(mu) {db(est_s - truth):7.2f} dB   gain {db(est_l-truth)-db(est_s-truth):6.2f} dB")

    # ---- 4. how much of a pass-2 row is edge? ----
    print("\n4. EDGE FRACTION (32 taps need idx-15 .. idx+16 in range)")
    print(f"   pass 2 row = {M} pulses -> {31}/{M} = {100*31/M:.2f}% of outputs hit the edge")
    print(f"   pass 1 row = 8192       -> {31}/8192 = {100*31/8192:.2f}%")
    # how many queries actually land out of the 32-tap support, on a real row?
    r = M // 2
    u_all = KC / KR[len(KR) // 2]
    inb = (u_all >= tau[0]) & (u_all < tau[-1])
    k = np.searchsorted(tau, u_all[inb], side="right") - 1
    need = (k - (TAPS // 2 - 1) >= 0) & (k + TAPS // 2 < M)
    print(f"   on a real mid row: {inb.sum()} of {KC.size} queries in range; of those "
          f"{(~need).sum()} ({100*(~need).sum()/max(inb.sum(),1):.2f}%) lack full 32-tap support")


if __name__ == "__main__":
    main()
