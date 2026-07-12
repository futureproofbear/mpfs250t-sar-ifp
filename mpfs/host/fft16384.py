"""16384-point FFT built from the 8192-point CoreFFT (hardware maxes at 8192 in-place).

Radix-2 decimation-in-time split: X = FFT_16384(x) is assembled from two 8192-point
sub-FFTs of the even/odd samples, a twiddle multiply, and a butterfly combine:

    xe = x[0::2]; xo = x[1::2]                       # deinterleave (8192 each)
    E  = FFT_8192(xe);  O = FFT_8192(xo)             # reuse the fabric CoreFFT, twice
    T[k] = exp(-j2*pi*k/16384),  k = 0..8191         # the 16384-stage twiddles
    X[k]      = E[k] + T[k]*O[k]                      # butterfly combine
    X[k+8192] = E[k] - T[k]*O[k]

This module (a) proves the decomposition equals a direct 16384-pt FFT in float, then
(b) models the fixed-point / block-floating-point (BFP) hardware path: the two 8192-pt
CoreFFTs each carry their own block exponent, so before the combine the two halves are
aligned to a common exponent; the twiddle multiply truncates (Q15) like the fabric; the
combine grows by up to 1 bit and is requantized to a final block exponent. Validated vs
the float FFT the same way the existing 8192 fabric model is (high correlation).

Reference for the fabric path: src/fixedpoint.fft1d_bfp (radix-2 DIT, BFP, truncated
twiddles) reused at n=8192. See model_fabric_fft.py for the per-row BFP + renorm the
range/azimuth passes apply on top; this file adds the missing 16384 sub-transform.
"""
import sys
import numpy as np

sys.path.insert(0, "../../src")
sys.path.insert(0, ".")
import fixedpoint as fx


# --------------------------------------------------------------------------- #
# (a) FLOAT decomposition -- proves the algebra (2x 8192 + twiddle + combine == 16384-FFT)
# --------------------------------------------------------------------------- #
def fft16384_float(x):
    x = np.asarray(x, np.complex128)
    xe, xo = x[..., 0::2], x[..., 1::2]                # 8192 each
    E = np.fft.fft(xe, axis=-1)
    O = np.fft.fft(xo, axis=-1)
    k = np.arange(xe.shape[-1])
    T = np.exp(-2j * np.pi * k / x.shape[-1])          # W_16384^k
    TO = T * O
    return np.concatenate([E + TO, E - TO], axis=-1)


# --------------------------------------------------------------------------- #
# (b) FIXED-POINT / BFP hardware model -- 8192 CoreFFT (fft1d_bfp) x2 + fabric combine
# --------------------------------------------------------------------------- #
def _align(a, ea, b, eb):
    """Bring two BFP blocks (mantissa, exponent) to a common exponent (the larger),
    arithmetic-shifting the smaller-exponent block down. Truncating shift = fabric."""
    e = max(ea, eb)
    if ea < e:
        a = fx.quant(a * 2.0 ** (ea - e), 1.0, 999)  # placeholder; replaced below
    return a, b, e


def fft16384_bfp(x, nbits=16, nbits_tw=16):
    """16384-pt FFT via 2x 8192-pt BFP CoreFFT + Q15 twiddle + BFP butterfly combine.
    Returns (X_int mantissa, block_exp) with true value X = X_int * 2**block_exp."""
    n = x.shape[-1]
    assert n == 16384, "this decomposition is for 16384-pt"
    half = n // 2                                        # 8192
    perm = fx._bitrev_perm(half)
    E, eE = fx.fft1d_bfp(x[..., 0::2], nbits, nbits_tw, perm)
    O, eO = fx.fft1d_bfp(x[..., 1::2], nbits, nbits_tw, perm)
    eE, eO = eE[-1], eO[-1]                              # final block exponents of each half

    # twiddles for the 16384 stage, truncated to Q(nbits_tw-1) like fft1d_bfp does
    lsb_tw = 2.0 ** -(nbits_tw - 1)
    k = np.arange(half)
    T = fx.quant(np.exp(-2j * np.pi * k / n), lsb_tw, nbits_tw, mode="trunc")

    # align E and O to a common block exponent (shift the smaller-exp half down, truncating)
    e = max(eE, eO)
    Ef = E.astype(np.complex128) * (2.0 ** (eE - e))
    Of = O.astype(np.complex128) * (2.0 ** (eO - e))
    Ef = np.trunc(Ef.real) + 1j * np.trunc(Ef.imag)     # truncate after the down-shift
    Of = np.trunc(Of.real) + 1j * np.trunc(Of.imag)

    TO = T * Of                                          # twiddle multiply (grows), Q15*int
    TO = np.trunc(TO.real / 1.0) + 1j * np.trunc(TO.imag / 1.0)
    # T is in [-1,1) as a float with lsb_tw quantum -> T*Of is int-scaled by 1; combine:
    lo = Ef + TO
    hi = Ef - TO
    X = np.concatenate([lo, hi], axis=-1)
    # requantize the combined block to nbits, folding the growth into a final block exponent
    Xq, de = fx.block_quant(X, nbits) if hasattr(fx, "block_quant") else _block_quant(X, nbits)
    return Xq, e + de


def _block_quant(y, nbits):
    """Shift the whole complex block down to fit signed nbits; return (int mantissa, exp)."""
    mag = np.max(np.abs(np.concatenate([y.real, y.imag], axis=-1)), axis=-1, keepdims=True)
    exp = np.where(mag > 0, np.ceil(np.log2(np.maximum(mag, 1e-30))).astype(int) - (nbits - 1), 0)
    exp = np.maximum(exp, 0)
    e = int(np.max(exp))
    ys = y / (2.0 ** e) if e else y
    return (np.trunc(ys.real) + 1j * np.trunc(ys.imag)), e


def _corr(a, b):
    a = a.ravel(); b = b.ravel()
    a = a - a.mean(); b = b - b.mean()
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return float(np.abs(np.vdot(a, b)) / d) if d else 0.0


if __name__ == "__main__":
    rng = np.random.default_rng(0)
    N = 16384
    fails = 0
    print("=== (a) FLOAT decomposition == direct 16384-pt FFT ===")
    for name, x in [
        ("impulse",  np.eye(1, N, 137)[0].astype(complex)),
        ("tone",     np.exp(2j * np.pi * 900 * np.arange(N) / N)),
        ("random",   rng.standard_normal(N) + 1j * rng.standard_normal(N)),
        ("2 rows",   rng.standard_normal((2, N)) + 1j * rng.standard_normal((2, N))),
    ]:
        got = fft16384_float(x)
        ref = np.fft.fft(x, axis=-1)
        err = np.max(np.abs(got - ref))
        ok = err < 1e-6
        fails += not ok
        print(f"  {name:9} max|decomp - fft| = {err:.2e}  -> {'OK' if ok else 'FAIL'}")

    print("\n=== (b) BFP hardware model (8192 CoreFFT x2 + combine) vs float FFT ===")
    for name, x in [
        ("tone",   np.exp(2j * np.pi * 900 * np.arange(N) / N)),
        ("random", rng.standard_normal(N) + 1j * rng.standard_normal(N)),
    ]:
        Xq, e = fft16384_bfp(x[None, :])
        X = Xq[0] * (2.0 ** e)
        ref = np.fft.fft(x)
        c = _corr(X, ref)
        ok = c > 0.999
        fails += not ok
        print(f"  {name:9} corr(BFP, float) = {c:.6f}  block_exp={e}  -> {'OK' if ok else 'FAIL'}")

    print("\n" + ("ALL PASS" if not fails else f"{fails} FAILED"))
    sys.exit(1 if fails else 0)
