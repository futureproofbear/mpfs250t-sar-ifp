#!/usr/bin/env python3
"""check_coeff_split.py -- BOARD-FREE gate for splitting coefficient generation across harts.

The multi-hart plan splits each line's Np outputs into contiguous slices, one per hart. That is
only safe if a worker starting cold at output q0 reproduces EXACTLY what the sequential scan in
sar_resample_coeffs.c would have produced there -- bit-for-bit, including the int16 weight.

Pass 1 (sar_uniform_coeffs) is trivially splittable: every output is an independent closed form.

Pass 2 (sar_coeffs_pass2) is the one that needs proving. It carries a moving bracket `k` across
outputs, so it LOOKS order-dependent. The claim this script tests:

    the sequential scan's k at query q is a PURE FUNCTION of q, namely
        k = clamp(  max{ j : SRC(j) <= q } , 0, S-2 )
    because the while-loop advances k until SRC(k+1) > q and never retreats, and KC is
    non-decreasing. So a worker can binary-search its starting k and match exactly.

If that holds bit-exactly on real staged geometry, the split is safe. If it does not, the
multi-hart design must change (e.g. split by LINE instead of by output range).

Usage:  python mpfs/host/check_coeff_split.py [stage_dir]
"""
import sys
import pathlib
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
STAGE = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "mpfs/host/jtag_stage_small"

f32 = np.float32


def emit(k, w):
    """Mirror of emit() in sar_resample_coeffs.c: int32 idx + saturated Q15 weight.
    C: int32_t wi = (int32_t)(w * 32768.0f + 0.5f); clamp [0,32767]."""
    wi = np.int32(f32(w) * f32(32768.0) + f32(0.5))   # C truncates toward zero
    if wi < 0:
        wi = np.int32(0)
    if wi > 32767:
        wi = np.int32(32767)
    return np.int32(k), np.int16(wi)


def pass2_sequential(KC, Mp, tan_s, S, kr, inv_tan):
    """Faithful mirror of sar_coeffs_pass2() -- the moving-bracket scan."""
    idx = np.full(Mp, -1, np.int32)
    wq = np.zeros(Mp, np.int16)
    if S < 2 or kr == 0.0:
        return idx, wq
    r = f32(f32(1.0) / kr)
    asc = (kr >= 0.0)
    rr = r if asc else f32(-r)

    def XA(k):                      # ascending view of tan_s
        return tan_s[k] if asc else tan_s[S - 1 - k]

    def SRC(k):
        return f32(kr * XA(k))

    def INVSPAN(k):
        return f32(inv_tan[k if asc else (S - 2 - k)] * rr)

    xlo, xhi = SRC(0), SRC(S - 1)
    k = 0
    x0 = SRC(0)
    inv = INVSPAN(0)
    for qi in range(Mp):
        q = KC[qi]
        if q < xlo or q >= xhi:
            continue
        while k + 2 < S and SRC(k + 1) <= q:
            k += 1
            x0 = SRC(k)
            inv = INVSPAN(k)
        frac = f32(f32(q - x0) * inv)
        if asc:
            idx[qi], wq[qi] = emit(k, frac)
        else:
            idx[qi], wq[qi] = emit(S - 2 - k, f32(f32(1.0) - frac))
    return idx, wq


def pass2_split(KC, Mp, tan_s, S, kr, inv_tan, nslice):
    """The multi-hart form: nslice independent workers, each cold-starting on its own output
    range and finding its bracket by binary search. This is what the firmware would do."""
    idx = np.full(Mp, -1, np.int32)
    wq = np.zeros(Mp, np.int16)
    if S < 2 or kr == 0.0:
        return idx, wq
    r = f32(f32(1.0) / kr)
    asc = (kr >= 0.0)
    rr = r if asc else f32(-r)

    def XA(k):
        return tan_s[k] if asc else tan_s[S - 1 - k]

    def SRC(k):
        return f32(kr * XA(k))

    def INVSPAN(k):
        return f32(inv_tan[k if asc else (S - 2 - k)] * rr)

    xlo, xhi = SRC(0), SRC(S - 1)
    bounds = [(w * Mp) // nslice for w in range(nslice + 1)]

    for w in range(nslice):
        q0, q1 = bounds[w], bounds[w + 1]
        if q0 >= q1:
            continue
        # cold start: largest j with SRC(j) <= KC[q0], clamped to [0, S-2]  (binary search)
        lo, hi = 0, S - 2
        target = KC[q0]
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if SRC(mid) <= target:
                lo = mid
            else:
                hi = mid - 1
        k = lo
        x0 = SRC(k)
        inv = INVSPAN(k)
        for qi in range(q0, q1):
            q = KC[qi]
            if q < xlo or q >= xhi:
                continue
            while k + 2 < S and SRC(k + 1) <= q:
                k += 1
                x0 = SRC(k)
                inv = INVSPAN(k)
            frac = f32(f32(q - x0) * inv)
            if asc:
                idx[qi], wq[qi] = emit(k, frac)
            else:
                idx[qi], wq[qi] = emit(S - 2 - k, f32(f32(1.0) - frac))
    return idx, wq


def main():
    need = ["kcgrid.bin", "krgrid.bin", "tans.bin"]
    for n in need:
        if not (STAGE / n).exists():
            print(f"FAIL: missing {STAGE / n}")
            return 1
    KC = np.fromfile(STAGE / "kcgrid.bin", np.float32)
    KR = np.fromfile(STAGE / "krgrid.bin", np.float32)
    tan_s = np.fromfile(STAGE / "tans.bin", np.float32)
    Mp, Np, S = KC.size, KR.size, tan_s.size
    print(f"stage={STAGE.name}  Mp={Mp} Np={Np} S(M)={S}")

    # sar_coeffs_init(): inv_tan[k] = 1/(tan_s[k+1]-tan_s[k]), float32, computed once
    inv_tan = np.zeros(S, np.float32)
    for k in range(S - 1):
        d = f32(tan_s[k + 1] - tan_s[k])
        inv_tan[k] = f32(f32(1.0) / d) if d != 0.0 else f32(0.0)

    # Exercise a spread of rows, including sign changes in KR (which flip `asc`) and the
    # zero-fill pad rows, plus the extremes.
    rows = sorted(set([0, 1, 2, Np // 4, Np // 2 - 1, Np // 2, Np // 2 + 1,
                       3 * Np // 4, Np - 2, Np - 1]
                      + list(np.linspace(0, Np - 1, 24).astype(int))))
    nsl_cases = [2, 3, 4, 5, 8]

    # This staged scene happens to have KR >= 0 throughout, so the DESCENDING-source path
    # (asc=false, which carries the documented sign flip in INVSPAN) would never be exercised.
    # Mirror every row with kr negated to cover it -- the firmware must be correct for both.
    cases = [(j, f32(KR[j]), "+") for j in rows] + [(j, f32(-KR[j]), "-") for j in rows]

    bad = 0
    checked = 0
    neg = 0
    for j, kr, sgn in cases:
        if kr < 0:
            neg += 1
        seq_i, seq_w = pass2_sequential(KC, Mp, tan_s, S, kr, inv_tan)
        for nsl in nsl_cases:
            sp_i, sp_w = pass2_split(KC, Mp, tan_s, S, kr, inv_tan, nsl)
            checked += 1
            if not (np.array_equal(seq_i, sp_i) and np.array_equal(seq_w, sp_w)):
                bad += 1
                di = np.flatnonzero(seq_i != sp_i)
                dw = np.flatnonzero(seq_w != sp_w)
                print(f"  MISMATCH row j={j} kr={kr:g} ({sgn}) nslice={nsl}: "
                      f"{di.size} idx diffs, {dw.size} wq diffs; first idx@{di[:3]} wq@{dw[:3]}")

    print(f"cases tested={len(cases)} (kr<0 on {neg}), split checks={checked}, mismatches={bad}")
    if bad == 0:
        print("PASS: range-split is BIT-IDENTICAL to the sequential scan on real geometry.")
        print("      -> splitting a line's outputs across harts is safe.")
        return 0
    print("FAIL: range-split is NOT bit-identical -- do NOT split by output range.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
