#!/usr/bin/env python
"""Transliterate the NEW sar_resample_coeffs.c line-for-line and check it against the OLD one.

The rewrite (closed form for pass 1, hoisted line-invariant reciprocals for pass 2) is not
bit-identical to the search it replaces, so the pipeline CRC cannot gate it. This is the
substitute gate: reproduce both implementations exactly -- including the ascending-view macro,
the truncation, and the Q15 rounding -- and compare them against a float64 reference.

Particular attention to the DESCENDING pass-2 branch (KR[j] < 0). The ascending view walks
tan_s backwards there, so the invariant reciprocal picks up a sign flip as well as an index
reversal; using r instead of -r would put a negative weight on every descending line. Real KR
may be all-positive, in which case that branch never runs in production -- but it is exercised
here by flipping the sign explicitly, because "probably unreachable" is not a test.

Run:  python mpfs/host/verify_coeff_rewrite.py
"""
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))

F32 = np.float32


def _emit(k, w):
    """C: wi = (int32)(w*32768+0.5); clamp 0..32767"""
    wi = np.int32(F32(w) * F32(32768.0) + F32(0.5))
    return int(k), int(min(max(int(wi), 0), 32767))


def old_interp(query, xp):
    """OLD sar_interp_coeffs -- generic bracket search with a per-bracket divide."""
    Q, S = len(query), len(xp)
    idx = np.full(Q, -1, np.int64); wq = np.zeros(Q, np.int64)
    if S < 2:
        return idx, wq
    asc = xp[S - 1] >= xp[0]
    xa = (lambda k: xp[k]) if asc else (lambda k: xp[S - 1 - k])
    xlo, xhi = xa(0), xa(S - 1)
    k = 0
    x0, x1 = xa(0), xa(1)
    inv = F32(1.0) / (x1 - x0) if x1 != x0 else F32(0.0)
    for qi in range(Q):
        q = query[qi]
        if q < xlo or q >= xhi:
            continue
        while k + 2 < S and xa(k + 1) <= q:
            k += 1
            x0, x1 = xa(k), xa(k + 1)
            inv = F32(1.0) / (x1 - x0) if x1 != x0 else F32(0.0)
        frac = F32(q - x0) * inv
        idx[qi], wq[qi] = _emit(k, frac) if asc else _emit(S - 2 - k, F32(1.0) - frac)
    return idx, wq


def new_uniform(query, x0, dx, S):
    """NEW sar_uniform_coeffs -- pass-1 closed form."""
    Q = len(query)
    idx = np.full(Q, -1, np.int64); wq = np.zeros(Q, np.int64)
    if S < 2 or dx == 0.0:
        return idx, wq
    inv, tmax = F32(1.0) / F32(dx), F32(S - 1)
    for qi in range(Q):
        t = F32(query[qi] - F32(x0)) * inv
        if not (t >= F32(0.0)) or t >= tmax:
            continue
        k = np.int32(t)                       # t >= 0 so truncation == floor
        idx[qi], wq[qi] = _emit(int(k), t - F32(k))
    return idx, wq


def new_pass2(KC, Mp, tan_s, S, kr, inv_tan):
    """NEW sar_coeffs_pass2 -- hoisted invariant reciprocals, source compared on the fly."""
    idx = np.full(Mp, -1, np.int64); wq = np.zeros(Mp, np.int64)
    if S < 2 or kr == 0.0:
        return idx, wq
    r = F32(1.0) / F32(kr)
    asc = kr >= 0.0
    rr = r if asc else F32(-r)                      # <-- the sign flip under test
    ts = (lambda k: tan_s[k]) if asc else (lambda k: tan_s[S - 1 - k])
    SRC = lambda k: F32(kr) * ts(k)                                        # noqa: E731
    INVSPAN = lambda k: F32(inv_tan[k if asc else S - 2 - k]) * rr         # noqa: E731
    xlo, xhi = SRC(0), SRC(S - 1)
    k = 0
    x0, inv = SRC(0), INVSPAN(0)
    for qi in range(Mp):
        q = KC[qi]
        if q < xlo or q >= xhi:
            continue
        while k + 2 < S and SRC(k + 1) <= q:
            k += 1
            x0, inv = SRC(k), INVSPAN(k)
        frac = F32(q - x0) * inv
        idx[qi], wq[qi] = _emit(k, frac) if asc else _emit(S - 2 - k, F32(1.0) - frac)
    return idx, wq


def ref_f64(query, xp):
    Q, S = len(query), len(xp)
    idx = np.full(Q, -1, np.int64); wq = np.zeros(Q, np.int64)
    asc = xp[-1] >= xp[0]
    x = xp.astype(np.float64) if asc else xp.astype(np.float64)[::-1]
    inb = (query >= x[0]) & (query < x[-1])
    k = np.clip(np.searchsorted(x, query[inb], side="right") - 1, 0, S - 2)
    frac = (query[inb] - x[k]) / (x[k + 1] - x[k])
    idx[inb] = k if asc else S - 2 - k
    w = frac if asc else 1.0 - frac
    wq[inb] = np.clip(np.floor(w * 32768.0 + 0.5), 0, 32767)
    return idx, wq


def score(tag, a, b, ref):
    def pe(i, w):
        m = (ref[0] >= 0) & (i >= 0)
        if not m.any():
            return float("nan")
        return np.abs((i[m] + w[m] / 32768.0) - (ref[0][m] + ref[1][m] / 32768.0)).max()
    print(f"  {tag:34s} old {pe(*a):.3e}   new {pe(*b):.3e}   "
          f"{'NEW BETTER' if pe(*b) <= pe(*a) else '*** NEW WORSE ***'}")


def main():
    rng = np.random.default_rng(3)
    # --- pass 1: uniform grid, both directions ---
    print("PASS 1 (closed form) vs OLD search, float64 reference:")
    for sign, tag in ((+1.0, "ascending  dx>0"), (-1.0, "descending dx<0")):
        N, Q = 601, 1024
        x0, dx = 4.68e7, sign * 5852.0
        xp = (F32(x0) + np.arange(N, dtype=F32) * F32(dx)).astype(F32)
        lo, hi = (min(xp[0], xp[-1]), max(xp[0], xp[-1]))
        query = np.sort(rng.uniform(lo, hi, Q)).astype(F32)
        score(tag, old_interp(query, xp), new_uniform(query, x0, dx, N),
              ref_f64(query.astype(np.float64), xp.astype(np.float64)))

    # --- pass 2: non-uniform tan_s, both KR signs ---
    print("\nPASS 2 (hoisted reciprocals) vs OLD search, float64 reference:")
    S, Mp = 501, 1024
    tan_s = np.sort(rng.uniform(-0.35, 0.35, S)).astype(F32)
    inv_tan = np.array([F32(1.0) / (tan_s[k + 1] - tan_s[k]) if tan_s[k + 1] != tan_s[k] else F32(0.0)
                        for k in range(S - 1)], dtype=F32)
    for kr, tag in ((3.1e6, "KR>0 (source ascends)"), (-3.1e6, "KR<0 (source descends)")):
        src = (F32(kr) * tan_s).astype(F32)
        lo, hi = min(src[0], src[-1]), max(src[0], src[-1])
        KC = np.sort(rng.uniform(lo, hi, Mp)).astype(F32)
        score(tag, old_interp(KC, src), new_pass2(KC, Mp, tan_s, S, kr, inv_tan),
              ref_f64(KC.astype(np.float64), src.astype(np.float64)))

    print("\nBoth branches of each pass must be at least as accurate as OLD.")
    print("The descending rows are the ones that catch a wrong reciprocal sign.")


if __name__ == "__main__":
    main()
