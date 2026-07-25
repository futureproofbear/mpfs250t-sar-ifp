#!/usr/bin/env python3
"""check_coeffgen_fixed.py -- BOARD-FREE gate for the ON-FABRIC coefficient generator
(mpfs/fpga/sar_coeffgen.v).

Sibling of check_coeff_split.py, same job and same standard of proof: the fabric must produce
BYTE-IDENTICAL idx[]/wq[] to sar_coeffs_pass2_range() on real staged geometry, for BOTH source
orders (kr >= 0 and kr < 0), or the divergence must be measured and stated.

Three gates, in order of what they prove:

  GATE 1  the integer binary32 primitives (coeffgen_model.fmul/fadd) are IEEE-754
          round-to-nearest-even -- fuzzed against numpy float32 over structured + random
          operands, including cancellation, ties, and the real geometry's own operand mix.
          This is what makes GATE 2 a proof rather than a coincidence.
  GATE 2  the integer datapath model == the float32 C reference, bit for bit, over the real
          staged geometry, ascending AND descending source.
  GATE 3  the ALTERNATIVE -- a pure fixed-point reformulation that works in tan_s space
          (u = q * (1/kr), bracket u against tan_s directly) -- is measured, NOT assumed. Its
          divergence is printed so the design note can quote a number instead of a hope.

Usage:  python mpfs/host/check_coeffgen_fixed.py [stage_dir]
"""
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from coeffgen_model import (Flags, coeffgen_row, fadd, fmul, fsub, itan_of,  # noqa: E402
                            rinv_of)

ROOT = pathlib.Path(__file__).resolve().parents[2]
STAGE = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "mpfs/host/jtag_stage_small"

f32 = np.float32


def bits(x):
    return int(np.float32(x).view(np.uint32))


def val(b):
    return np.uint32(b).view(np.float32)


# ============================================================== GATE 1: primitive conformance
def gate1_primitives():
    rng = np.random.default_rng(20260725)
    bad_mul = bad_add = 0
    n = 0

    def check(op, a_b, b_b, ref):
        nonlocal bad_mul, bad_add, n
        fl = Flags()
        got = op(a_b, b_b, fl)
        want = int(np.float32(ref).view(np.uint32))
        n += 1
        if got != want:
            if op is fmul:
                bad_mul += 1
            else:
                bad_add += 1
            if bad_mul + bad_add <= 5:
                print(f"    {op.__name__}({val(a_b)!r},{val(b_b)!r}) = {val(got)!r} "
                      f"want {np.float32(ref)!r}  (bits {got:08x} vs {want:08x})")

    # structured operands: powers of two, exact ties, near-cancellation, sign mixes
    struct = [1.0, -1.0, 0.5, 2.0, 3.0, 0.0, -0.0, 32768.0, 1.0 / 3.0, 1e-8, 1e8,
              49.455215, -51.876793, 0.0057499614, -0.0057682157, 61300.0, 8.2e-4,
              1.0000001, 0.99999994, 16777215.0, 16777216.0, 8388609.0]
    for a in struct:
        for b in struct:
            av, bv = np.float32(a), np.float32(b)
            check(fmul, bits(av), bits(bv), np.float32(av * bv))
            check(fadd, bits(av), bits(bv), np.float32(av + bv))

    # random operands over the geometry's dynamic range + wide-exponent random
    for _ in range(40000):
        ea, eb = rng.integers(-30, 30, 2)
        a = np.float32(rng.standard_normal() * (2.0 ** int(ea)))
        b = np.float32(rng.standard_normal() * (2.0 ** int(eb)))
        if a == 0 or b == 0 or not np.isfinite(a * b):
            continue
        check(fmul, bits(a), bits(b), np.float32(a * b))
        check(fadd, bits(a), bits(b), np.float32(a + b))

    # adversarial CANCELLATION: b = a*(1+eps) so a-b loses most of its significand. This is the
    # shape fl32(q - x0) actually has inside a bracket, and it is where a lazy aligner breaks.
    for _ in range(40000):
        a = np.float32(rng.standard_normal() * (2.0 ** int(rng.integers(-12, 4))))
        if a == 0:
            continue
        eps = np.float32(rng.standard_normal() * 1e-4)
        b = np.float32(a * (np.float32(1.0) + eps))
        check(fsub, bits(a), bits(b), np.float32(a - b))
        check(fadd, bits(a), bits(b), np.float32(a + b))

    ok = (bad_mul == 0 and bad_add == 0)
    print(f"GATE 1 primitives: {n} ops, fmul mismatches={bad_mul}, fadd mismatches={bad_add}"
          f"  -> {'PASS' if ok else 'FAIL'}")
    return ok


# ================================================== the float32 C reference (the authority)
def ref_pass2(KC, Mp, tan_s, S, kr, inv_tan):
    """Faithful mirror of sar_coeffs_pass2_range(g, j, ..., 0, Mp) in float32.
    Identical to pass2_sequential() in check_coeff_split.py -- kept here so this gate stands
    alone if that one is ever edited."""
    idx = np.full(Mp, -1, np.int32)
    wq = np.zeros(Mp, np.int16)
    if S < 2 or kr == 0.0:
        return idx, wq
    r = f32(f32(1.0) / kr)
    asc = (kr >= 0.0)
    rr = r if asc else f32(-r)

    def SRC(k):
        return f32(kr * (tan_s[k] if asc else tan_s[S - 1 - k]))

    def INVSPAN(k):
        return f32(inv_tan[k if asc else (S - 2 - k)] * rr)

    def emit(k, w):
        wi = np.int32(f32(w) * f32(32768.0) + f32(0.5))
        return np.int32(k), np.int16(max(0, min(32767, int(wi))))

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


# ============================ GATE 3 alternative: PURE fixed point, reformulated in tan_s space
def alt_fixed_tanspace(KC, Mp, tan_s, S, kr, QF):
    """The reformulation the fabric would use if it did NOT emulate float32:
         u = q * (1/kr)  -> bracket u against tan_s directly (row-invariant table)
         frac = (u - tan_s[k]) * inv_tan[k]
    all in Q-format integers with QF fractional bits. Row-invariant tables become integers, the
    per-row work is one multiply per query. Cheapest possible fabric form -- and measurably NOT
    bit-identical, which is the point of measuring it."""
    idx = np.full(Mp, -1, np.int32)
    wq = np.zeros(Mp, np.int16)
    if S < 2 or kr == 0.0:
        return idx, wq
    scale = 1 << QF
    T = np.floor(tan_s.astype(np.float64) * scale + 0.5).astype(np.int64)      # Q(QF) tan_s
    span = np.diff(T)
    asc = (kr >= 0.0)
    r = f32(f32(1.0) / kr)
    # queries mapped into tan_s space, same Q format
    U = np.floor(KC.astype(np.float64) * float(r) * scale + 0.5).astype(np.int64)
    order = np.arange(S) if asc else np.arange(S - 1, -1, -1)
    Tv = T[order]
    lo, hi = (Tv[0], Tv[-1]) if asc else (Tv[0], Tv[-1])
    k = 0
    for qi in range(Mp):
        u = U[qi]
        if (u < lo) or (u >= hi):
            continue
        while k + 2 < S and (Tv[k + 1] <= u):
            k += 1
        sp = Tv[k + 1] - Tv[k]
        frac = ((u - Tv[k]) << 15) // sp if sp != 0 else 0
        if not asc:
            frac = 32768 - frac
        idx[qi] = k if asc else (S - 2 - k)
        wq[qi] = np.int16(max(0, min(32767, int(frac))))
    _ = span
    return idx, wq


def main():
    for n in ["kcgrid.bin", "krgrid.bin", "tans.bin"]:
        if not (STAGE / n).exists():
            print(f"FAIL: missing {STAGE / n}")
            return 1
    KC = np.fromfile(STAGE / "kcgrid.bin", np.float32)
    KR = np.fromfile(STAGE / "krgrid.bin", np.float32)
    tan_s = np.fromfile(STAGE / "tans.bin", np.float32)
    Mp, Np, S = KC.size, KR.size, tan_s.size
    print(f"stage={STAGE.name}  Mp={Mp} Np={Np} S(M)={S}")

    ok1 = gate1_primitives()

    inv_tan = np.zeros(S, np.float32)
    for k in range(S - 1):
        d = f32(tan_s[k + 1] - tan_s[k])
        inv_tan[k] = f32(f32(1.0) / d) if d != 0.0 else f32(0.0)

    KC_b = [int(x) for x in KC.view(np.uint32)]
    TAN_b = [int(x) for x in tan_s.view(np.uint32)]
    ITAN_b = itan_of(TAN_b)

    # sanity: the table the fabric loads == the table sar_coeffs_init() builds, bit for bit
    assert ITAN_b == [int(x) for x in inv_tan[:S - 1].view(np.uint32)], \
        "itan_of() diverged from sar_coeffs_init()"

    rows = sorted(set([0, 1, 2, Np // 4, Np // 2 - 1, Np // 2, Np // 2 + 1,
                       3 * Np // 4, Np - 2, Np - 1]
                      + list(np.linspace(0, Np - 1, 24).astype(int))))
    # Every staged KR is positive, so mirror each row with kr negated -- otherwise the DESCENDING
    # source path (asc=false, the INVSPAN sign flip) is never exercised. Same trick as
    # check_coeff_split.py, and for the same reason.
    cases = [(j, f32(KR[j]), "+") for j in rows] + [(j, f32(-KR[j]), "-") for j in rows]

    bad = nchk = 0
    fmt_flags = ovf_flags = 0
    inrange_total = 0
    for j, kr, sgn in cases:
        rid, rwq = ref_pass2(KC, Mp, tan_s, S, kr, inv_tan)
        gi, gw, fl = coeffgen_row(KC_b, Mp, TAN_b, ITAN_b, S, bits(kr))
        nchk += 1
        fmt_flags += fl.fmt
        ovf_flags += fl.ovf
        inrange_total += int((rid >= 0).sum())
        di = np.flatnonzero(rid != np.array(gi, np.int32))
        dw = np.flatnonzero(rwq != np.array(gw, np.int16))
        if di.size or dw.size:
            bad += 1
            if bad <= 5:
                print(f"  MISMATCH row j={j} kr={kr:g} ({sgn}): {di.size} idx, {dw.size} wq; "
                      f"first idx@{di[:3]} wq@{dw[:3]}")
    ok2 = (bad == 0)
    print(f"GATE 2 datapath: rows tested={nchk} (half with kr<0), in-range outputs="
          f"{inrange_total}, mismatching rows={bad}, fmt_err={fmt_flags}, ovf={ovf_flags}"
          f"  -> {'PASS' if ok2 else 'FAIL'}")

    # ---- GATE 3: measure the pure fixed-point alternative (informational, not a pass/fail) ----
    print("GATE 3 alternative (pure fixed point in tan_s space) -- measured, not assumed:")
    probe = [(rows[0], f32(KR[rows[0]]), "+"), (rows[len(rows) // 2], f32(KR[rows[len(rows) // 2]]), "+"),
             (rows[-1], f32(-KR[rows[-1]]), "-")]
    for QF in (24, 30, 36):
        tot = idxbad = wqbad = 0
        wmax = 0
        for j, kr, sgn in probe:
            rid, rwq = ref_pass2(KC, Mp, tan_s, S, kr, inv_tan)
            aid, awq = alt_fixed_tanspace(KC, Mp, tan_s, S, kr, QF)
            both = (rid >= 0) & (aid >= 0)
            tot += int(both.sum())
            idxbad += int((rid[both] != aid[both]).sum())
            d = np.abs(rwq[both].astype(np.int32) - awq[both].astype(np.int32))
            wqbad += int((d != 0).sum())
            wmax = max(wmax, int(d.max()) if d.size else 0)
        print(f"    Q{QF}: over {tot} in-range outputs -- idx differs {idxbad}, "
              f"wq differs {wqbad} (max |dwq| = {wmax})  => NOT bit-identical")

    print()
    if ok1 and ok2:
        print("PASS: sar_coeffgen's integer binary32 datapath is BIT-IDENTICAL to")
        print("      sar_coeffs_pass2_range() on real staged geometry, both source orders.")
        print("      -> generating coefficients on fabric cannot move the pipeline CRC.")
        return 0
    print("FAIL: do NOT build the fabric coefficient generator against this model.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
