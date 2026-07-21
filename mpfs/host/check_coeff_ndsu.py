#!/usr/bin/env python
"""Validate the resample-coefficient reformulations against a REAL CPHD, not synthetic values.

model_coeff_precision.py used invented pr/f0/df, so its conclusions describe a numeric regime
rather than this radar. This re-runs them on the Umbra NDSU scene (the production target) using
the same derivation serialize_inputs.py feeds the board:
    f0 = freq[:,0]   df = freq[:,1]-freq[:,0]   pr = ax*dx/dn + ay*dy/dn   tan_s = tan_phi[order]

Checks, in order of what could invalidate the plan:
  0. Is freq[i,:] ACTUALLY linear in j? The firmware assumes freq[i,j] = f0[i] + j*df[i] and the
     pass-1 closed form inherits that assumption. If the real chirp grid is not uniform, the
     closed form is exact w.r.t. the firmware but the firmware is already wrong w.r.t. the data.
  1. Pass 1: shipping float32 search vs closed form vs fixed point, scored by effective source
     position (idx + wq/32768) against a float64 reference.
  2. Pass 2: the reformulation that divides the QUERY by KR[j] instead of scaling the source,
     which makes the per-bracket reciprocal line-invariant (precomputable once).

Run:  python mpfs/host/check_coeff_ndsu.py [--cphd PATH] [--deci N]
"""
import argparse
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))
import form_image_pfa as ref            # noqa: E402
from sar_pipeline import prepare_tables  # noqa: E402

GRID = 8192


def pos_err(idx, wq, ridx, rwq):
    both = (ridx >= 0) & (idx >= 0)
    if not both.any():
        return float("nan"), float("nan"), 0
    e = np.abs((idx[both] + wq[both] / 32768.0) - (ridx[both] + rwq[both] / 32768.0))
    return float(e.max()), float(np.sqrt((e ** 2).mean())), int((idx[both] != ridx[both]).sum())


def ref_f64(query, xp):
    """float64 bracket search -- the intent both implementations approximate."""
    idx = np.full(query.shape, -1, np.int64); wq = np.zeros(query.shape, np.int64)
    asc = xp[-1] >= xp[0]
    x = xp if asc else xp[::-1]
    inb = (query >= x[0]) & (query < x[-1])
    k = np.clip(np.searchsorted(x, query[inb], side="right") - 1, 0, len(x) - 2)
    frac = (query[inb] - x[k]) / (x[k + 1] - x[k])
    if asc:
        idx[inb] = k; w = frac
    else:
        idx[inb] = len(x) - 2 - k; w = 1.0 - frac
    wq[inb] = np.clip(np.floor(w * 32768.0 + 0.5), 0, 32767)
    return idx, wq


def search_f32(query, xp32):
    return ref_f64(query.astype(np.float32).astype(np.float64),
                   xp32.astype(np.float64))


def closed_f32(query, x0, dx, S):
    q = query.astype(np.float32)
    t = ((q - np.float32(x0)) * (np.float32(1.0) / np.float32(dx))).astype(np.float32)
    idx = np.full(q.shape, -1, np.int64); wq = np.zeros(q.shape, np.int64)
    inb = (t >= 0) & (t < S - 1)
    k = np.floor(t[inb]).astype(np.int64)
    idx[inb] = k
    wq[inb] = np.clip(np.floor((t[inb] - k).astype(np.float64) * 32768.0 + 0.5), 0, 32767)
    return idx, wq


def closed_fixed(query, x0, dx, S, qbits):
    span = abs(float(dx)) * (S - 1)
    scale = (1 << qbits) / span
    qi = np.floor((query.astype(np.float64) - x0) * scale).astype(np.int64)
    dxi = int(round(float(dx) * scale))
    idx = np.full(query.shape, -1, np.int64); wq = np.zeros(query.shape, np.int64)
    if dxi == 0:
        return idx, wq
    inb = (qi >= 0) & (qi < dxi * (S - 1)) if dxi > 0 else (qi <= 0) & (qi > dxi * (S - 1))
    k = qi[inb] // dxi
    rem = qi[inb] - k * dxi
    idx[inb] = k
    wq[inb] = np.clip((rem * 32768) // dxi, 0, 32767)
    return idx, wq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cphd", default="data/umbra_ndsu_20231110/2023-11-10-16-16-44_UMBRA-04_CPHD.cphd")
    ap.add_argument("--deci", type=int, default=8)
    ap.add_argument("--lines", type=int, default=24, help="sample this many lines per pass")
    a = ap.parse_args()

    root = HERE.parents[1]
    path = (root / a.cphd) if not Path(a.cphd).is_absolute() else Path(a.cphd)
    print(f"scene: {path.name}  deci={a.deci}")
    reader = ref.open_phase_history(str(path))
    t = prepare_tables(reader, reader.cphd_meta, a.deci, a.deci)
    reader.close()

    m, n = t["dims"]
    KR, KC, tan_phi = t["KR"], t["KC"], t["tan_phi"]
    freq, ax, ay = t["freq"], t["ax"], t["ay"]
    print(f"dims: M={m} pulses x N={n} samples   KR={KR.shape} KC={KC.shape}\n")

    # ---- 0. is freq linear in j, as the firmware assumes? ----
    d = np.diff(freq.astype(np.float64), axis=1)
    rel = (d.max(axis=1) - d.min(axis=1)) / np.abs(d.mean(axis=1))
    print("0. freq[i,j] == f0[i] + j*df[i] ?")
    print(f"   per-pulse df spread: max {rel.max():.3e} relative  (0 => exactly uniform chirp)")
    print(f"   => the firmware's linear model is {'EXACT' if rel.max() < 1e-9 else 'an APPROXIMATION'}"
          f" for this scene\n")

    order = np.argsort(tan_phi)
    tan_s = tan_phi[order].astype(np.float32)
    f0 = freq[:, 0].astype(np.float32)
    df = (freq[:, 1] - freq[:, 0]).astype(np.float32)
    dxv, dyv = t["geo"][0] if isinstance(t["geo"], tuple) else (None, None)  # unused; pr below
    pr = t.get("pr")
    if pr is None:                     # derive as serialize_inputs does
        pr = np.linalg.norm(np.stack([ax, ay], -1), axis=-1).astype(np.float32)

    C = 299792458.0
    rng = np.random.default_rng(0)
    rows = rng.choice(m, size=min(a.lines, m), replace=False)

    # ---- 1. PASS 1 ----
    print("1. PASS 1  (source grid a*(f0 + j*df) -- uniform, so a closed form exists)")
    print(f"   {'method':24s} {'pos max':>10s} {'pos rms':>10s} {'idx diff':>9s}")
    acc = {}
    for i in rows:
        aa = 2.0 * float(pr[i]) / C
        x0, dxs = aa * float(f0[i]), aa * float(df[i])
        j = np.arange(n)
        xp64 = aa * (freq[i].astype(np.float64))
        xp32 = (np.float32(aa) * (np.float32(f0[i]) + j.astype(np.float32) * np.float32(df[i]))).astype(np.float32)
        R = ref_f64(KR.astype(np.float64), xp64)
        for name, res in (("shipping f32 search", search_f32(KR, xp32)),
                          ("closed form f32", closed_f32(KR, x0, dxs, n)),
                          ("closed form fixed q32", closed_fixed(KR, x0, dxs, n, 32)),
                          ("closed form fixed q36", closed_fixed(KR, x0, dxs, n, 36))):
            mx, rms, nb = pos_err(*res, *R)
            s = acc.setdefault(name, [0.0, 0.0, 0])
            s[0] = max(s[0], mx); s[1] += rms; s[2] += nb
    for k, v in acc.items():
        print(f"   {k:24s} {v[0]:10.2e} {v[1]/len(rows):10.2e} {v[2]:9d}")

    # ---- 2. PASS 2 ----
    print("\n2. PASS 2  (source KR[j]*tan_s[k] -- NOT uniform; reformulation divides the QUERY)")
    print(f"   {'method':24s} {'pos max':>10s} {'pos rms':>10s} {'idx diff':>9s}")
    acc2 = {}
    jrows = rng.choice(len(KR), size=min(a.lines, len(KR)), replace=False)
    for j in jrows:
        krj = float(KR[j])
        if krj == 0:
            continue
        xp64 = krj * tan_s.astype(np.float64)                     # source as built today
        R = ref_f64(KC.astype(np.float64), xp64)
        ship = search_f32(KC, (np.float32(krj) * tan_s).astype(np.float32))
        # reformulated: scale the QUERY by 1/KR[j]; bracket + weight then use the FIXED tan_s,
        # so 1/(tan_s[k+1]-tan_s[k]) is line-invariant and precomputable once for the whole run
        u = (KC.astype(np.float32) * np.float32(1.0 / krj)).astype(np.float32)
        reform = ref_f64(u.astype(np.float64), tan_s.astype(np.float64))
        for name, res in (("shipping f32 (scale src)", ship),
                          ("reformed (scale query)", reform)):
            mx, rms, nb = pos_err(*res, *R)
            s = acc2.setdefault(name, [0.0, 0.0, 0])
            s[0] = max(s[0], mx); s[1] += rms; s[2] += nb
    for k, v in acc2.items():
        print(f"   {k:24s} {v[0]:10.2e} {v[1]/len(jrows):10.2e} {v[2]:9d}")

    print("\npos err is in SOURCE SAMPLES (idx + wq/32768). The shipping row is the bar:")
    print("anything at or below it is no worse than what silicon validates today.")


if __name__ == "__main__":
    main()
