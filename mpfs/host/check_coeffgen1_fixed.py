"""PASS-1 (RANGE) on-fabric coefficient generator -- board-free bit-exactness gate.

Proves that a fabric datapath built from the SAME integer binary32 primitives already used by
sar_coeffgen.v (coeffgen_model.fmul/fadd/fsub/f2i_trunc/emit) reproduces sar_coeffs_pass1_range()
BYTE-IDENTICALLY on real staged geometry. If this passes, moving pass-1 coefficient generation
into fabric cannot move the pipeline CRC -- exactly the argument that made the pass-2 generator
safe to build (check_coeffgen_fixed.py).

WHY PASS 1 IS THE EASY ONE. Pass 2 inverts kc = kr*tan(phi) onto a uniform KC grid, which is a
SEARCH in tan_s (hence the binary search, the sorted tan_s, and three 8192x32 tables). Pass 1
inverts kr(i,j) = 2*pr[i]/C * (f0[i] + j*df[i]) onto the uniform KR grid, and kr is AFFINE in j,
so it is closed form:

    a    = 2*pr[i]/C ;  x0 = a*f0[i] ;  dx = a*df[i] ;  inv = 1/dx
    t(q) = (KR[q] - x0) * inv                       <- ONE subtract, ONE multiply
    out-of-range unless (t >= 0) and (t < N-1)      -> idx = -1, wq = 0
    k    = (int32)t          (t >= 0, so truncation == floor)
    wq   = clamp((int32)((t - k)*32768 + 0.5), 0, 32767)

So the fabric block is the pass-2 datapath MINUS the search, PLUS one KR table: 16 LSRAM instead
of 48, and no multi-cycle search state.

NOTE ON THE ONE DIVIDE. `inv = 1/dx` is per-ROW, not per-output, so it stays on the CPU and is
written to the generator as a scalar -- the same split the pass-2 generator uses for RINV. No
divider in fabric.

Usage:  python mpfs/host/check_coeffgen1_fixed.py [stage_dir]
"""
import pathlib
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import coeffgen_model as M  # noqa: E402


def bits(x):
    """float32 -> its raw 32-bit pattern (the model's operand format)."""
    return int(np.asarray(x, np.float32).view(np.uint32))


def val(b):
    """raw 32-bit pattern -> float32."""
    return np.uint32(b).view(np.float32)

STAGE = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "mpfs/host/jtag_stage_small"

C_LIGHT = np.float32(299792458.0)


def ref_pass1(KR, Np, x0, dx, N):
    """float32 mirror of sar_coeffs_pass1_range() + sar_uniform_coeffs_range() + emit()."""
    idx = np.full(Np, -1, np.int32)
    wq = np.zeros(Np, np.int16)
    if N < 2 or dx == np.float32(0.0):
        return idx, wq
    inv = np.float32(np.float32(1.0) / dx)
    tmax = np.float32(N - 1)
    for q in range(Np):
        t = np.float32((KR[q] - x0) * inv)
        if not (t >= np.float32(0.0)) or t >= tmax:
            continue
        k = np.int32(t)                                    # trunc toward zero == floor for t>=0
        w = np.float32(t - val(bits(np.float32(k))))
        wi = np.int32(np.float32(w * np.float32(32768.0) + np.float32(0.5)))
        wi = max(0, min(32767, int(wi)))
        idx[q], wq[q] = k, np.int16(wi)
    return idx, wq


def dut_pass1(KR, Np, x0, dx, N, fl):
    """Integer binary32 datapath model -- what the RTL would do, using the SAME primitives the
    pass-2 generator's RTL was validated against (GATE 1 of check_coeffgen_fixed.py)."""
    idx = np.full(Np, -1, np.int32)
    wq = np.zeros(Np, np.int16)
    if N < 2 or dx == np.float32(0.0):
        return idx, wq
    inv = bits(np.float32(np.float32(1.0) / dx))         # CPU-supplied scalar (per row)
    x0b = bits(x0)
    tmaxb = bits(np.float32(N - 1))
    for q in range(Np):
        krb = bits(KR[q])
        tb = M.fmul(M.fsub(krb, x0b, fl), inv, fl)         # t = (KR[q] - x0) * inv
        # out-of-range: NOT(t >= 0) OR t >= tmax.  NaN must take the out-of-range branch, which
        # is why this is written as a negated >= and not as t < 0.
        if not M.fle(bits(np.float32(0.0)), tb) or not M.flt(tb, tmaxb):
            continue
        k = M.f2i_trunc(tb)
        wb = M.fsub(tb, bits(val(bits(np.float32(k)))), fl)         # t - (float)k
        idx[q], wq[q] = np.int32(k), np.int16(M.emit(k, wb, fl)[1])
    return idx, wq


def main():
    lay = STAGE / "layout.json"
    if not lay.exists():
        sys.exit(f"no layout.json in {STAGE} -- pass a staged scene dir")
    import json
    L = json.loads(lay.read_text())
    M_, N = L["dims"]["M"], L["dims"]["N"]
    Mp, Np = L["fft_len"]["A"], L["fft_len"]["R"]

    KR = np.fromfile(STAGE / "krgrid.bin", np.float32)
    f0 = np.fromfile(STAGE / "f0.bin", np.float32)
    df = np.fromfile(STAGE / "df.bin", np.float32)
    pr = np.fromfile(STAGE / "pr.bin", np.float32)
    print(f"stage={STAGE.name}  M={M_} N={N}  Mp={Mp} Np={Np}  KR={KR.size}")

    fl = M.Flags()
    # Sample rows across the aperture, including the ends where dx is most extreme.
    rows = sorted(set([0, 1, M_ // 2, M_ - 2, M_ - 1] +
                      list(np.linspace(0, M_ - 1, 32, dtype=int))))
    bad_rows = 0
    tot = inr = 0
    for i in rows:
        a = np.float32(np.float32(2.0) * pr[i] / C_LIGHT)
        x0 = np.float32(a * f0[i])
        dx = np.float32(a * df[i])
        ri, rw = ref_pass1(KR, Np, x0, dx, N)
        di, dw = dut_pass1(KR, Np, x0, dx, N, fl)
        if not (np.array_equal(ri, di) and np.array_equal(rw, dw)):
            bad_rows += 1
            n = int(np.count_nonzero((ri != di) | (rw != dw)))
            print(f"  row {i}: MISMATCH on {n} outputs")
        tot += Np
        inr += int(np.count_nonzero(ri >= 0))

    print(f"rows tested={len(rows)}  outputs={tot}  in-range={inr}  "
          f"mismatching rows={bad_rows}  fmt_err={fl.fmt}  ovf={fl.ovf}")
    if bad_rows or fl.fmt:
        sys.exit("FAIL: the pass-1 fabric datapath is NOT bit-identical to the C reference")
    print("PASS: the pass-1 integer binary32 datapath is BIT-IDENTICAL to\n"
          "      sar_coeffs_pass1_range() on real staged geometry.\n"
          "      -> generating pass-1 coefficients on fabric cannot move the pipeline CRC.")


if __name__ == "__main__":
    main()
