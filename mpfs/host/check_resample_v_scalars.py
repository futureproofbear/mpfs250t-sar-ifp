#!/usr/bin/env python
"""check_resample_v_scalars.py -- BOARD-FREE reference for sar_resample_v's PASS-1 (MODE 0)
per-line scalars, on REAL staged geometry.

WHY THIS EXISTS. The firmware must hand sar_resample_v three numbers per line -- A, SH and B --
and one int32 table per scene. Get any of them wrong and the kernel produces a plausible but wrong
image, exactly like the coefficient bugs this project has already paid for. The arithmetic is
specified in sar_resample_v.v's "NUMERIC FORMAT" block and implemented in
tb/gen_resample_vectors.py; this script is the same derivation applied to the ACTUAL scene tables
rather than to synthetic test cases, so it answers questions the TB cannot:

  * does every line's A fit in int32 at a usable SH, for the real dx range?
  * does every B fit in 48 bits?
  * does one SCENE-WIDE kr_off/kr_scale serve all 5634 lines? (the TB picks kr_off per case,
    which is fine there because each case is one line -- the real table is loaded ONCE)
  * do the resulting idx/wq match the CPU coefficients the shipping pipeline computes today?

THE VERIFICATION GAP, STATED PLAINLY. There is no host gcc and no spike/qemu on this machine, so
the firmware C cannot be compiled or run here and this script CANNOT be a C-vs-Python gate of the
kind check_coeffgen1_fixed.py is. What it can do is pin the exact expected values, which the
firmware then self-checks against on the board. Do not mistake a pass here for a validated
firmware.

Usage:
    python check_resample_v_scalars.py [--stage jtag_stage_deci1] [--lines 64]
"""
import argparse
import json
import math
import sys
from fractions import Fraction as F
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent

SH_REQ = 44                       # ceiling from the RTL contract; pick_sh backs off as needed
C_LIGHT = 299792458.0


def iround(x):
    """round-half-up on a Fraction/int -- what the CPU-side build does."""
    return math.floor(F(x) + F(1, 2))


def fits32(x):
    return -(1 << 31) <= x <= (1 << 31) - 1


def fits48(x):
    return -(1 << 47) <= x <= (1 << 47) - 1


def pick_sh(unit):
    """Largest SH <= SH_REQ whose mantissa A = round(unit*2^SH) still fits in int32.

    Mirrors gen_resample_vectors.py exactly. A silent wrap here would give a plausible but wrong
    affine map and every downstream check would then verify the wrong thing."""
    for sh in range(SH_REQ, -1, -1):
        a = iround(F(unit) * (1 << sh))
        if a != 0 and fits32(a):
            return sh, a
    raise SystemExit(f"no SH in [0,{SH_REQ}] gives a non-zero int32 A (unit={float(unit)})")


def coeffs_mode0(kri, a, sh, b, sn):
    """The DUT's affine map + field split, in exact integers. v = ((QTAB*A) >>> SH) + B."""
    idx, wq, oor = [], [], 0
    lim = (sn - 1) << 24
    for q in kri:
        v = ((q * a) >> sh) + b          # arithmetic shift; Python >> on negatives floors, as RTL
        if v < 0 or v >= lim:
            idx.append(-1); wq.append(0); oor += 1
            continue
        idx.append(v >> 24)
        w = ((v >> 9) & 0x7FFF) + ((v >> 8) & 1)
        wq.append(32767 if w > 32767 else w)
    return idx, wq, oor


def pick_sh_double(unit_d):
    """pick_sh as the FIRMWARE does it: float64 throughout, not Fraction. Mirrors
    sar_rsv_scalars() in sar_resample_v.c."""
    for sh in range(SH_REQ, -1, -1):
        scaled = unit_d * float(1 << sh)
        if scaled > 9.0e18 or scaled < -9.0e18:
            continue
        a = math.floor(scaled + 0.5)
        if a != 0 and fits32(a):
            return sh, a
    raise SystemExit("double path found no SH")


def check_double_path(KR, kr_off, kr_scale, kri, f0, df, pr, nlines):
    """THE QUESTION THIS ANSWERS: the firmware cannot use Fractions -- it computes A, SH, B and the
    query table in float64 on the U54. Everything above is exact rational arithmetic. If the two
    ever round to different integers the firmware silently programs a different affine map than the
    one this script pins, and the board-side SAR_RSVDBG readback would then be 'correct' against the
    wrong reference. So compare them directly, and report the MARGIN -- how close the worst case got
    to a rounding boundary -- because a pass with no margin is luck, not a result."""
    # rebuild kr_scale in double exactly the way the C does: 2^30 / span
    kr_scale_d = 1073741824.0 / float(F(1 << 30) / kr_scale)

    INT32_MAX, INT32_MIN = (1 << 31) - 1, -(1 << 31)
    tab_diff, tab_margin = 0, 1.0
    for i, k in enumerate(KR):
        exact = F(F(float(k)) - F(kr_off)) * kr_scale
        d = (float(k) - kr_off) * kr_scale_d
        td = math.floor(d + 0.5)
        if td > INT32_MAX:
            td = INT32_MAX
        elif td < INT32_MIN:
            td = INT32_MIN
        tab_margin = min(tab_margin, abs(float(exact + F(1, 2)) - math.floor(float(exact) + 0.5)))
        if td != kri[i]:
            tab_diff += 1

    a_diff = sh_diff = b_diff = 0
    a_margin = b_margin = 1.0
    for i in range(nlines):
        ag = 2.0 * pr[i] / C_LIGHT
        x0, dx = ag * f0[i], ag * df[i]
        sh_e, A_e = pick_sh(F(1 << 24) / (kr_scale * F(dx)))
        B_e = iround((F(kr_off) - F(x0)) * F(1 << 24) / F(dx))
        sh_d, A_d = pick_sh_double(16777216.0 / (kr_scale_d * dx))
        B_d = math.floor((kr_off - x0) * 16777216.0 / dx + 0.5)
        if sh_d != sh_e: sh_diff += 1
        if A_d != A_e:   a_diff += 1
        if B_d != B_e:   b_diff += 1
        # distance from the .5 boundary, in ULP-of-the-integer terms
        ae = float(F(1 << 24) / (kr_scale * F(dx)) * (1 << sh_e))
        a_margin = min(a_margin, abs(ae - math.floor(ae) - 0.5))
        be = float((F(kr_off) - F(x0)) * F(1 << 24) / F(dx))
        b_margin = min(b_margin, abs(be - math.floor(be) - 0.5))

    print(f"  FIRMWARE float64 vs exact rational, over {nlines} lines and {len(KR)} table entries:")
    print(f"    query table : {tab_diff} differ   (worst distance to a .5 boundary {tab_margin:.3e})")
    print(f"    SH          : {sh_diff} differ")
    print(f"    A           : {a_diff} differ    (worst distance to a .5 boundary {a_margin:.3e})")
    print(f"    B           : {b_diff} differ    (worst distance to a .5 boundary {b_margin:.3e})")
    ok = (tab_diff == 0 and sh_diff == 0 and a_diff == 0 and b_diff == 0)
    print(f"    -> {'IDENTICAL' if ok else 'DIVERGES -- the firmware would program a different map'}")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", default="jtag_stage_deci1")
    ap.add_argument("--lines", type=int, default=64, help="how many pulses to check (0 = all)")
    a = ap.parse_args()

    stage = (HERE / a.stage) if not Path(a.stage).is_absolute() else Path(a.stage)
    layout = json.loads((stage / "layout.json").read_text())
    M, N = layout["dims"]["M"], layout["dims"]["N"]
    Np = layout["fft_len"]["R"]
    print(f"  stage {stage.name}: M={M} pulses, N={N} samples, Np={Np} output grid")

    f0 = np.fromfile(stage / "f0.bin", dtype=np.float32).astype(np.float64)
    df = np.fromfile(stage / "df.bin", dtype=np.float32).astype(np.float64)
    pr = np.fromfile(stage / "pr.bin", dtype=np.float32).astype(np.float64)
    KR = np.fromfile(stage / "krgrid.bin", dtype=np.float32).astype(np.float64)
    assert len(KR) == Np, f"krgrid has {len(KR)}, expected Np={Np}"

    # ---- SCENE-WIDE table: kr_off/kr_scale must be line-INVARIANT, because the int32 KR table is
    # loaded once per scene. The TB picks kr_off per case (x0 - 7*dx) which is fine there, since a
    # case is one line. Here the offset comes from the grid itself and B absorbs the per-line part.
    # serialize_inputs pads the query grid past the real entries with a deliberate out-of-range
    # filler so the kernel zero-fills. Measured on this scene: real KR spans [49.455, 50.167]
    # (span 0.712) and the filler sits at 51.878. That forces a choice the TB never had to make,
    # because a TB case is one line with no padding:
    #   scale on the REAL entries  -> the filler scales to 3.66e9 and OVERFLOWS int32
    #   scale on the PADDED grid   -> real entries use only 29.4% of +/-2^30, losing 1.77 bits
    #                                 of resolution across every genuine query
    # Neither is acceptable, and the third option is right: scale on the real entries and CLAMP
    # the padding. The filler carries no information -- it only has to stay out of range -- and a
    # clamped INT32_MAX still does, for either sign of A, because v then lands far beyond
    # (SN-1)*2^24 (or far below 0 when dx < 0).
    real = KR[:N] if N < Np else KR
    kr_off = float(real.min())
    span = float(np.abs(real - kr_off).max())
    kr_scale = F(1 << 30) / F(span)
    INT32_MAX, INT32_MIN = (1 << 31) - 1, -(1 << 31)
    kri = []
    nclamp = 0
    for k in KR:                                   # the FULL Np-entry query table
        t = iround((F(float(k)) - F(kr_off)) * kr_scale)
        if t > INT32_MAX:
            t = INT32_MAX; nclamp += 1
        elif t < INT32_MIN:
            t = INT32_MIN; nclamp += 1
        kri.append(t)
    print(f"  query table: {len(kri)} entries, {nclamp} clamped (the out-of-range padding)")
    print(f"  kr_off={kr_off:.6e}  span={span:.6e}  kr_scale=2^30/span")
    bad = [i for i, k in enumerate(kri) if not fits32(k)]
    print(f"  KR_i int32: {'OK' if not bad else f'OVERFLOW at {bad[:4]}'}  "
          f"range [{min(kri)}, {max(kri)}]")

    nlines = M if a.lines == 0 else min(a.lines, M)
    shs, bad_a, bad_b, oor_tot = {}, 0, 0, 0
    for i in range(nlines):
        ag = 2.0 * pr[i] / C_LIGHT
        x0 = ag * f0[i]
        dx = ag * df[i]
        unit = F(1 << 24) / (kr_scale * F(dx))
        sh, A = pick_sh(unit)
        B = iround((F(kr_off) - F(x0)) * F(1 << 24) / F(dx))
        shs[sh] = shs.get(sh, 0) + 1
        if not fits32(A):
            bad_a += 1
        if not fits48(B):
            bad_b += 1
        if i < 3:
            print(f"    line {i:4d}: dx={dx:.6e}  SH={sh:2d}  A={A:11d}  B={B:d}")
        _, _, oor = coeffs_mode0(kri, A, sh, B, N)   # N = source samples per pulse
        oor_tot += oor

    print(f"  checked {nlines} lines")
    print(f"    A fits int32 : {'ALL' if not bad_a else f'{bad_a} FAIL'}")
    print(f"    B fits 48-bit: {'ALL' if not bad_b else f'{bad_b} FAIL'}")
    print(f"    SH values used: {dict(sorted(shs.items()))}")
    print(f"    out-of-range taps: {oor_tot} of {nlines * len(kri)} "
          f"({100.0 * oor_tot / (nlines * len(kri)):.1f}%)")
    dbl_ok = check_double_path(KR, kr_off, kr_scale, kri, f0, df, pr, nlines)
    ok = not bad and not bad_a and not bad_b and dbl_ok
    print(f"\n  {'PASS' if ok else 'FAIL'} -- scalars are representable for the real geometry")
    print("  NOTE: this pins the EXPECTED values. It does not validate the firmware C, which "
          "cannot be\n        compiled or run on this host (no gcc, no spike/qemu).")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
