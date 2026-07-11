"""Model-first validation of the fabric CoreFFT scaling approach, BEFORE any silicon.

Question this answers: does the on-silicon approach -- CoreFFT per-row block-floating-point
(each 8192-pt row gets its OWN SCALE_EXP) followed by a firmware GLOBAL renormalize
Output[i] >>= (max_exp - exp_i) -- reconstruct the correct focused image as well as the CPU
path (a single global block exponent per pass) does?

If FABRIC corr ~ CPU corr ~ golden  -> the approach is SOUND; any silicon corr~0 is an
   implementation/capture bug (firmware or SCALE_EXP latch), not the algorithm.
If FABRIC corr << CPU corr           -> the per-row-BFP+renormalize APPROACH is flawed and no
   amount of silicon debugging fixes it -- rethink before touching the board again.

Uses the bit-accurate primitives already in src/fixedpoint.py (verified vs CoreFFT at corr 1.0).
Pure NumPy; run:  python model_fabric_fft.py
"""
import sys, math
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
import fixedpoint as fx


# ---- FABRIC model: per-row BFP FFT + GLOBAL renormalize, two passes (range then azimuth) ----
def _sat16(y):
    re = np.clip(np.floor(y.real), -32768, 32767)
    im = np.clip(np.floor(y.imag), -32768, 32767)
    return re + 1j * im


def _shr_perrow(x, sh):                      # arithmetic >> sh (per-row int array), truncate
    d = (2.0 ** sh)[..., None]
    return np.floor(x.real / d) + 1j * np.floor(x.imag / d)


def fft2_fabric_perrow_renorm(x, nbits=16, nbits_tw=16):
    """Exactly the on-silicon fabric path:
       range pass  : CoreFFT per-row BFP  -> per-row exp_i -> firmware renorm >>(emax-exp_i)
       corner-turn : transpose
       azimuth pass: same
    Returns (int16 mantissa, (emax_r, emax_a))."""
    N, M = x.shape[-1], x.shape[-2]
    # range pass
    yr, er = fx.fft1d_bfp_hw_perrow(x, nbits, nbits_tw, fx._bitrev_perm(N))
    emax_r = int(er.max())
    yr = _sat16(_shr_perrow(yr, emax_r - er))                 # firmware global renormalize
    # corner-turn (plain transpose, matches the fabric)
    yt = np.swapaxes(yr, -1, -2)
    # azimuth pass
    ya, ea = fx.fft1d_bfp_hw_perrow(yt, nbits, nbits_tw, fx._bitrev_perm(M))
    emax_a = int(ea.max())
    ya = _sat16(_shr_perrow(ya, emax_a - ea))
    return np.swapaxes(ya, -1, -2), (emax_r, emax_a, er, ea)


def fft2_fabric_NORENORM(x, nbits=16, nbits_tw=16):
    """Same per-row BFP, but WITHOUT the global renormalize -- i.e. what the board actually does
    if the SCALE_EXP capture is broken (reads a constant, so emax-exp_i = 0 for every row -> the
    renormalize is a no-op). Each row stays at its OWN block scale = the per-row inconsistency."""
    N, M = x.shape[-1], x.shape[-2]
    yr, er = fx.fft1d_bfp_hw_perrow(x, nbits, nbits_tw, fx._bitrev_perm(N))
    yr = _sat16(yr)                                   # no renorm
    yt = np.swapaxes(yr, -1, -2)
    ya, ea = fx.fft1d_bfp_hw_perrow(yt, nbits, nbits_tw, fx._bitrev_perm(M))
    return np.swapaxes(_sat16(ya), -1, -2), (int(er.max()), int(ea.max()), er, ea)


def corr(a, b):
    """orientation-tolerant magnitude correlation (best over transpose/flip), log-magnitude."""
    a = np.log1p(np.abs(a).astype(np.float64))
    cands = [b, b.T, b[::-1], b[:, ::-1], b.T[::-1], b.T[:, ::-1]]
    best = -1.0
    for c in cands:
        c = np.log1p(np.abs(c).astype(np.float64))
        if c.shape != a.shape:
            continue
        av, cv = a.ravel() - a.mean(), c.ravel() - c.mean()
        d = np.linalg.norm(av) * np.linalg.norm(cv)
        if d:
            best = max(best, float(av @ cv / d))
    return best


# ------------------------------ synthetic scenes ------------------------------
def scenes(n):
    """k-space inputs (post-resample+window equivalents). Each returns a complex array whose
    fft2 is the 'image' -- designed to stress per-row block-floating-point differently."""
    rng = np.random.default_rng(0)
    r, c = np.mgrid[0:n, 0:n]
    out = {}
    # 1) single point target: image delta -> k-space is a pure 2-D phasor (uniform magnitude)
    out["point"] = np.exp(2j * np.pi * (0.3 * r + 0.17 * c))
    # 2) two points 60 dB apart: strong + weak phasor -> tests dynamic range in the image
    out["two_point_60dB"] = (np.exp(2j * np.pi * (0.3 * r + 0.17 * c))
                             + 1e-3 * np.exp(2j * np.pi * (0.11 * r + 0.42 * c)))
    # 3) several points
    s = np.zeros((n, n), complex)
    for fr, fc, a in [(0.10, 0.20, 1.0), (0.35, 0.05, 0.3), (0.22, 0.44, 0.1), (0.48, 0.30, 0.03)]:
        s += a * np.exp(2j * np.pi * (fr * r + fc * c))
    out["multi_point"] = s
    # 4) distributed speckle (random complex) -> low dynamic range, all rows similar
    out["speckle"] = (rng.standard_normal((n, n)) + 1j * rng.standard_normal((n, n)))
    # 5) ROW-VARYING magnitude: the case that most stresses PER-ROW exponents -- a handful of
    #    bright pulses among many dim ones. This is where per-row BFP diverges from global BFP.
    g = np.full(n, 1e-3); g[n // 3] = 1.0; g[2 * n // 3] = 0.5; g[5] = 0.8
    out["row_varying_hidr"] = (np.exp(2j * np.pi * (0.3 * r + 0.17 * c)) * g[:, None])
    return out


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 512     # power of 2; small = fast, size-independent
    nbits = 16
    print(f"grid {n}x{n}, {nbits}-bit datapath.  corr = log-magnitude, orientation-tolerant.\n")
    print(f"{'scene':18} {'CPU':>7} {'FAB+renorm':>11} {'FAB NO-renorm':>13}  {'exp-spread r/a':>14}")
    for name, x in scenes(n).items():
        x = x.astype(np.complex128)
        # quantize the input to full-scale int16 CODES (the fabric's input quantizer) so the
        # models and the golden all see the SAME integer-grid input.
        lsb, _ = fx.fit_scale(x, nbits)
        codes = np.floor(x.real / lsb) + 1j * np.floor(x.imag / lsb)   # int16 codes, integer-valued
        golden = np.fft.fft2(codes)                             # float reference of the SAME codes
        cpu, _ = fx.fft2_l1bfp(codes)                           # on-silicon CPU kernel (global exp)
        fab, (emr, ema, er, ea) = fft2_fabric_perrow_renorm(codes)      # FABRIC with renorm
        nrn, (nr, na, ner, nea) = fft2_fabric_NORENORM(codes)          # FABRIC if capture broken
        c_cpu = corr(golden, cpu); c_fab = corr(golden, fab); c_nrn = corr(golden, nrn)
        # exp spread = how much the per-row exponents vary within each pass (0 = uniform)
        sp_r = int(ner.max() - ner.min()); sp_a = int(nea.max() - nea.min())
        print(f"{name:18} {c_cpu:7.3f} {c_fab:11.3f} {c_nrn:13.3f}  {sp_r:>6}/{sp_a:<6}")
    print("\nKey: FAB+renorm ~ CPU everywhere -> algorithm sound.")
    print("     FAB NO-renorm (broken capture) << FAB+renorm on high-exp-spread scenes ->")
    print("     if a broken SCALE_EXP capture makes renorm a no-op, THAT is the silicon corr~0.")
    print("     Compare the exp-spread to the board's observed azimuth exps (all==3 -> spread 0).")


if __name__ == "__main__":
    main()
