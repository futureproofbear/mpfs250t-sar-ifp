#!/usr/bin/env python
"""How accurate must resample coefficient generation be? Closed-form and fixed-point vs the
float32 search that ships today.

WHY: silicon profiling (2026-07-21) showed resample is 96% CPU-bound on sar_coeffs_* --
19.94 s of the 20.78 s gather time, against 6.1 ms in the fabric kernel. So the coefficient
math, not the AXI path, is the pipeline's largest remaining cost. Two ways to attack it, both
of which change the arithmetic and therefore need their error bounded BEFORE any build:

  1. CLOSED FORM. sar_coeffs_pass1 builds its source grid as scratch[j] = a*(f0 + j*df) --
     which is (a*f0) + (a*df)*j, i.e. UNIFORMLY SPACED. The shipping code then runs an O(S)
     bracket search with S-1 float divides over it. For a uniform grid the bracket is a closed
     form: k = floor((q-x0)/dx), frac = the remainder. One divide per LINE instead of 4318.
  2. FIXED POINT. Replaces the float compare/subtract/multiply with integer ops, which is what
     makes an II=1 fabric implementation cheap (no soft FPU, no float divider).

The output contract is already coarse -- int32 idx + Q15 wq -- so the question is not "is it
bit-identical" (it will not be) but "does idx ever land in the wrong bracket, and how far does
wq move". An idx error is a REAL error: the gather reads the wrong sample. A wq error of a few
LSB is a sub-quantisation-step interpolation shift.

Run:  python mpfs/host/model_coeff_precision.py
"""
import numpy as np

C_LIGHT = 299792458.0


def ref_search_f64(query, xp):
    """The shipping algorithm's INTENT, in float64: bracket search + linear weight."""
    idx = np.full(query.shape, -1, np.int64)
    wq = np.zeros(query.shape, np.int64)
    inb = (query >= xp[0]) & (query < xp[-1])
    k = np.searchsorted(xp, query[inb], side="right") - 1
    k = np.clip(k, 0, len(xp) - 2)
    frac = (query[inb] - xp[k]) / (xp[k + 1] - xp[k])
    idx[inb] = k
    wq[inb] = np.clip(np.floor(frac * 32768.0 + 0.5), 0, 32767)
    return idx, wq


def shipping_f32(query, xp32):
    """What silicon does today: the same search, but over the FLOAT32 grid the CPU built,
    with a float32 reciprocal per bracket (the hoisted 1/(x1-x0))."""
    q = query.astype(np.float32)
    idx = np.full(q.shape, -1, np.int64)
    wq = np.zeros(q.shape, np.int64)
    inb = (q >= xp32[0]) & (q < xp32[-1])
    k = np.searchsorted(xp32, q[inb], side="right") - 1
    k = np.clip(k, 0, len(xp32) - 2)
    inv = (np.float32(1.0) / (xp32[k + 1] - xp32[k])).astype(np.float32)
    frac = ((q[inb] - xp32[k]) * inv).astype(np.float32)
    idx[inb] = k
    wq[inb] = np.clip(np.floor(frac.astype(np.float64) * 32768.0 + 0.5), 0, 32767)
    return idx, wq


def closed_form_f32(query, x0, dx, S):
    """Uniform-grid closed form in float32: no search, ONE reciprocal per line."""
    q = query.astype(np.float32)
    inv = np.float32(1.0) / np.float32(dx)
    t = ((q - np.float32(x0)) * inv).astype(np.float32)
    idx = np.full(q.shape, -1, np.int64)
    wq = np.zeros(q.shape, np.int64)
    inb = (t >= 0) & (t < S - 1)
    k = np.floor(t[inb]).astype(np.int64)
    frac = t[inb] - k
    idx[inb] = k
    wq[inb] = np.clip(np.floor(frac.astype(np.float64) * 32768.0 + 0.5), 0, 32767)
    return idx, wq


def closed_form_fixed(query, x0, dx, S, qbits):
    """Uniform-grid closed form in FIXED POINT. Models what fabric would do: scale the query
    range into an integer with `qbits` of fraction, then one integer reciprocal-multiply."""
    span = float(dx) * (S - 1)
    scale = (1 << qbits) / span                     # map the whole grid span into qbits
    qi = np.floor((query.astype(np.float64) - x0) * scale).astype(np.int64)
    dxi = int(round(float(dx) * scale))             # integer grid step
    if dxi <= 0:
        raise RuntimeError("qbits too small: grid step underflows to 0")
    idx = np.full(query.shape, -1, np.int64)
    wq = np.zeros(query.shape, np.int64)
    inb = (qi >= 0) & (qi < dxi * (S - 1))
    k = qi[inb] // dxi
    rem = qi[inb] - k * dxi
    idx[inb] = k
    wq[inb] = np.clip((rem * 32768) // dxi, 0, 32767)
    return idx, wq


def compare(name, idx, wq, ridx, rwq):
    """Score by EFFECTIVE SOURCE POSITION, pos = idx + wq/32768, in units of source samples.

    Scoring idx and wq separately is misleading: an off-by-one idx whose wq sits near a
    bracket edge wraps 32767 <-> 0, which looks like a catastrophic weight error while
    describing very nearly the SAME physical tap. Position error is what the gather actually
    interpolates at, so it is the quantity that maps to image quality.
    """
    both = (ridx >= 0) & (idx >= 0)
    dom = int((idx >= 0).sum() - (ridx >= 0).sum())
    pos = idx[both] + wq[both] / 32768.0
    rpos = ridx[both] + rwq[both] / 32768.0
    e = np.abs(pos - rpos)
    idx_bad = int((idx[both] != ridx[both]).sum())
    print(f"  {name:22s} pos err: max {e.max():9.2e}  rms {np.sqrt((e**2).mean()):9.2e} samples"
          f"   (idx differs {idx_bad:5d}, in-band delta {dom:+d})")
    return float(e.max()), float(np.sqrt((e ** 2).mean()))


def main():
    # Representative pass-1 geometry (Centerfield-class X-band):
    #   scratch[j] = a*(f0 + j*df),  a = 2*pr/c
    N, Np = 4319, 8192
    pr, f0, df = 7.31e5, 9.6e9, 1.2e6
    a = 2.0 * pr / C_LIGHT

    j = np.arange(N)
    xp64 = a * (f0 + j * df)                                    # exact
    xp32 = (np.float32(a) * (np.float32(f0) + j.astype(np.float32) * np.float32(df))).astype(np.float32)
    x0, dx = a * f0, a * df

    # KR: the uniform output k-space grid the queries come from, spanning the source extent
    KR = np.linspace(xp64[0], xp64[-1], Np, endpoint=False)

    ridx, rwq = ref_search_f64(KR, xp64)
    print(f"pass-1 geometry: N={N} source, Np={Np} queries, grid step dx={dx:.1f}")
    print(f"reference = float64 bracket search over the exact grid\n")

    compare("shipping f32 search", *shipping_f32(KR, xp32), ridx, rwq)
    compare("closed form f32", *closed_form_f32(KR, x0, dx, N), ridx, rwq)
    for qb in (24, 28, 32, 36):
        compare(f"closed form fixed q{qb}", *closed_form_fixed(KR, x0, dx, N, qb), ridx, rwq)

    print("\nidx wrong = the gather would read a DIFFERENT source sample (a real error).")
    print("wq maxerr = interpolation weight shift, out of 32768 full scale.")
    print("The shipping f32 row is the bar to beat: anything at or below it is no worse than")
    print("what silicon already produces and validates at corr 0.9923.")


if __name__ == "__main__":
    main()
