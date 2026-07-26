#!/usr/bin/env python
"""Generate bit-exact reference vectors for tb_sar_coeffgen.v (mpfs/fpga/sar_coeffgen.v).

AUTHORITY -- the expected idx[]/wq[] here come from mpfs/host/coeffgen_model.py, the pure-integer
model of the fabric datapath, which mpfs/host/check_coeffgen_fixed.py has already proven
BYTE-IDENTICAL to sar_coeffs_pass2_range() (float32 C) over the real staged geometry, both source
orders. So a TB pass chains: RTL == integer model == float32 C reference.

GEOMETRY IS REAL. tan_s / KC / KR come from mpfs/host/jtag_stage_small (M=705, Mp=8192) -- the same
staged scene check_coeff_split.py uses. Two synthetic-KC cases keep the same REAL tan_s but replace
the query grid with one that lands almost entirely INSIDE the source extent, because the staged KC
only puts ~704 of 8192 queries in range and the interesting arithmetic is the in-range path.

Emits (into this directory, all gitignored):
    cg_tab.hex   32-bit table words: per case [tan_s (S)][inv_tan (S-1)][KC (QN)]
    cg_exp.hex   48-bit expected stream entries {idx[31:0], wq[15:0]}, QN per case
    cg_cfg.hex   per-case config, CFGW words per case
    cg_fp.hex    primitive vectors: a, b, fmul(a,b), fadd(a,b)  (4 words each)
    cg_dims.vh   `defines for the testbench

MUTATION CHECKS -- each of these was APPLIED to sar_coeffgen.v and the TB re-run, so this list is
measured, not asserted:
  * drop the INVSPAN sign flip (use r instead of -r when kr<0)  -> desc_real + desc_dense FAIL
    (4800 coefficients): every descending weight goes negative and clamps to 0.
  * use `k` instead of `S-2-k` for the descending emit index    -> desc_* FAIL (4801).
  * truncate instead of round-to-nearest-even in sar_fp32_mul   -> ALL six value cases FAIL
    (3131 coefficients). This is the whole justification for emulating binary32 rather than
    reformulating in fixed point.
  * `q > xhi` instead of `q >= xhi`                             -> `edges` FAILs by exactly 1.
  * drop the alignment sticky bit in sar_fp32_add               -> the GEOMETRY cases do NOT
    catch it (the only wide-exponent add is `w*32768 + 0.5f`, whose 1 ulp lands far below the
    integer truncation). The fp-primitive vectors below DO catch it -- that is why they exist.
  * advance the bracket BEFORE the out-of-range test            -> NOT observable on a
    non-decreasing KC (an out-of-range query can never satisfy the advance test either), so the
    two orderings are equivalent here. Stated rather than claimed as covered.
"""
import pathlib
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "mpfs" / "host"))
from coeffgen_model import Flags, coeffgen_row, fadd, fmul, rinv_of    # noqa: E402

STAGE = ROOT / "mpfs" / "host" / "jtag_stage_small"
CFGW = 12   # +mode, x0, inv, tmax for the PASS-1 (range) cases


def bits(x):
    return int(np.float32(x).view(np.uint32))


def main():
    KC_r = np.fromfile(STAGE / "kcgrid.bin", np.float32)
    KR_r = np.fromfile(STAGE / "krgrid.bin", np.float32)
    tan_r = np.fromfile(STAGE / "tans.bin", np.float32)
    S = tan_r.size
    TAN = [int(v) for v in tan_r.view(np.uint32)]

    # inv_tan[] exactly as sar_coeffs_init() builds it (float32, 0 on a zero span)
    ITAN = []
    for k in range(S - 1):
        d = np.float32(tan_r[k + 1] - tan_r[k])
        v = np.float32(np.float32(1.0) / d) if d != np.float32(0.0) else np.float32(0.0)
        ITAN.append(int(v.view(np.uint32)))

    def dense_kc(kr, n):
        """A query grid that spans the source extent for this kr, so nearly every output is
        in-range -- this is where idx/wq actually get exercised."""
        lo = np.float32(kr * (tan_r[0] if kr >= 0 else tan_r[S - 1]))
        hi = np.float32(kr * (tan_r[S - 1] if kr >= 0 else tan_r[0]))
        g = np.linspace(float(lo), float(hi), n, endpoint=False).astype(np.float32)
        return [int(v) for v in g.view(np.uint32)]

    def edge_kc(kr, n):
        """A query grid that lands EXACTLY on the range-test boundaries. The C's test is
        `q < xlo || q >= xhi`, so q == xlo must be IN range and q == xhi must be OUT -- an
        interpolated grid never hits either exactly, so without this case a `>` / `>=` slip is
        invisible. xlo/xhi are taken from the model's own fl32(kr*tan_s[..]) so they are the same
        bit patterns the RTL computes."""
        fl = Flags()
        lo_b = fmul(bits(kr), TAN[0] if kr >= 0 else TAN[S - 1], fl)
        hi_b = fmul(bits(kr), TAN[S - 1] if kr >= 0 else TAN[0], fl)
        lo = np.uint32(lo_b).view(np.float32)
        hi = np.uint32(hi_b).view(np.float32)
        interior = np.linspace(float(lo), float(hi), n - 3, endpoint=False).astype(np.float32)
        below = np.nextafter(lo, np.float32(-np.inf)).astype(np.float32)
        above = np.nextafter(hi, np.float32(np.inf)).astype(np.float32)
        seq = np.concatenate(([below], interior, [hi], [above])).astype(np.float32)
        assert seq.size == n and np.all(np.diff(seq) > 0)
        assert seq[1] == lo and seq[-2] == hi          # exact boundary hits
        return [int(v) for v in seq.view(np.uint32)]

    KC_real = [int(v) for v in KC_r.view(np.uint32)]
    kr_mid = np.float32(KR_r[KR_r.size // 2])
    kr_lo = np.float32(KR_r[0])

    CASES = [
        # name          kr                  KC table         QN     stutter  degen
        ("asc_real",  bits(kr_lo),          KC_real,         8192,  0,       0),
        ("desc_real", bits(-kr_mid),        KC_real,         8192,  0,       0),
        ("asc_dense", bits(kr_mid),         dense_kc(kr_mid, 4096),  4096, 0, 0),
        ("desc_dense", bits(-kr_lo),        dense_kc(-kr_lo, 4096),  4096, 0, 0),
        ("stutter",   bits(kr_mid),         dense_kc(kr_mid, 2048),  2048, 1, 0),
        ("edges",     bits(kr_mid),         edge_kc(kr_mid, 1024),   1024, 0, 0),
        ("degen_kr0", bits(np.float32(0.0)), KC_real[:1024],  1024,  0,      1),
    ]

    C_LIGHT = np.float32(299792458.0)

    def p1_row(KRq, qn, x0, inv, tmax):
        """PASS-1 reference: t = (KR[q]-x0)*inv ; idx = (int32)t ; wq = q15(t - (float)idx).
        Mirrors sar_coeffs_pass1_range() + emit(); gated bit-exact by check_coeffgen1_fixed.py."""
        idx = [-1]*qn; wq = [0]*qn
        for q in range(qn):
            kr = np.uint32(KRq[q]).view(np.float32)
            t  = np.float32((kr - x0) * inv)
            if not (t >= np.float32(0.0)) or not (t < tmax):
                continue
            k = int(np.int32(t))
            w = np.float32(t - np.float32(np.float32(k)))
            wi = int(np.int32(np.float32(w*np.float32(32768.0) + np.float32(0.5))))
            idx[q], wq[q] = k, max(0, min(32767, wi))
        return idx, wq

    # PASS-1 cases use REAL per-pulse geometry, so the scalars are the ones silicon will see.
    f0_r = np.fromfile(STAGE / "f0.bin", np.float32)
    df_r = np.fromfile(STAGE / "df.bin", np.float32)
    pr_r = np.fromfile(STAGE / "pr.bin", np.float32)
    NREAL = int(np.fromfile(STAGE / "tans.bin", np.float32).size)

    def p1_scalars(i):
        a  = np.float32(np.float32(2.0) * pr_r[i] / C_LIGHT)
        x0 = np.float32(a * f0_r[i])
        dx = np.float32(a * df_r[i])
        inv = np.float32(np.float32(1.0) / dx)
        return x0, inv

    tab, exp, cfg = [], [], []
    report = []
    for name, kr_b, kc, qn, stut, degen in CASES:
        assert len(kc) >= qn
        tab_off = len(tab)
        tab.extend(TAN)
        tab.extend(ITAN)
        tab.extend(kc[:qn])
        exp_off = len(exp)
        idx, wq, fl = coeffgen_row(kc[:qn], qn, TAN, ITAN, S, kr_b)
        assert fl.fmt == 0 and fl.ovf == 0, f"{name}: model flagged a format/range problem"
        for i in range(qn):
            exp.append(((idx[i] & 0xFFFFFFFF) << 16) | (wq[i] & 0xFFFF))
        rinv_b = rinv_of(kr_b) if (kr_b & 0x7FFFFFFF) else 0
        cfg += [S, qn, kr_b, rinv_b, tab_off, exp_off, stut, degen, 0, 0, 0, 0]
        nin = sum(1 for v in idx if v >= 0)
        nmid = sum(1 for i in range(qn) if idx[i] >= 0 and 64 < wq[i] < 32704)
        report.append((name, qn, nin, nmid, min(wq), max(wq)))

    # ---- PASS-1 (range) cases ---------------------------------------------------------------
    # Same machinery: the KR query grid goes in the kcmem slot (pass 1 reuses that table), and the
    # tan/itan words are still written but never read in this mode. Rows are chosen at the ENDS of
    # the aperture as well as the middle, because dx -- and therefore inv -- is most extreme there.
    P1_ROWS = [0, NREAL // 2, NREAL - 1]
    KR_full = [int(v) for v in KR_r.view(np.uint32)]
    for ri, row in enumerate(P1_ROWS):
        x0, inv = p1_scalars(row)
        tmax = np.float32(NREAL - 1)
        qn = 4096
        name = f"p1_row{ri}"
        tab_off = len(tab)
        tab.extend(TAN); tab.extend(ITAN); tab.extend(KR_full[:qn])
        exp_off = len(exp)
        idx, wq = p1_row(KR_full[:qn], qn, x0, inv, tmax)
        for i in range(qn):
            exp.append(((idx[i] & 0xFFFFFFFF) << 16) | (wq[i] & 0xFFFF))
        cfg += [S, qn, 0, 0, tab_off, exp_off, 0, 0,
                1, bits(x0), bits(inv), bits(tmax)]
        CASES.append((name, 0, KR_full[:qn], qn, 0, 0))
        nin = sum(1 for v in idx if v >= 0)
        nmid = sum(1 for i in range(qn) if idx[i] >= 0 and 64 < wq[i] < 32704)
        report.append((name, qn, nin, nmid, min(wq), max(wq)))

    # DENSE pass-1: query grid spanning t in [0, N-1), so ~every output is in-range and the
    # idx/wq datapath is actually exercised -- the real-KR cases only land ~N of QN in range.
    x0d, invd = p1_scalars(NREAL // 2)
    dxd = np.float32(np.float32(1.0) / invd)
    tmaxd = np.float32(NREAL - 1)
    qn = 4096
    grid = [bits(np.float32(x0d + np.float32(dxd * np.float32(t))))
            for t in np.linspace(0.0, float(NREAL - 1), qn, endpoint=False).astype(np.float32)]
    tab_off = len(tab); tab.extend(TAN); tab.extend(ITAN); tab.extend(grid)
    exp_off = len(exp)
    idx, wq = p1_row(grid, qn, x0d, invd, tmaxd)
    for i in range(qn):
        exp.append(((idx[i] & 0xFFFFFFFF) << 16) | (wq[i] & 0xFFFF))
    cfg += [S, qn, 0, 0, tab_off, exp_off, 0, 0, 1, bits(x0d), bits(invd), bits(tmaxd)]
    CASES.append(("p1_dense", 0, grid, qn, 0, 0))
    report.append(("p1_dense", qn, sum(1 for v in idx if v >= 0),
                   sum(1 for i in range(qn) if idx[i] >= 0 and 64 < wq[i] < 32704),
                   min(wq), max(wq)))

    # A pass-1 case that is entirely OUT of range (tmax = 0 <=> N < 2), which is how the C's
    # degenerate path presents. Every output must be idx=-1 / wq=0.
    x0, inv = p1_scalars(0)
    qn = 1024
    tab_off = len(tab); tab.extend(TAN); tab.extend(ITAN); tab.extend(KR_full[:qn])
    exp_off = len(exp)
    for i in range(qn):
        exp.append(((0xFFFFFFFF) << 16) | 0)
    cfg += [S, qn, 0, 0, tab_off, exp_off, 0, 0, 1, bits(x0), bits(inv), bits(np.float32(0.0))]
    CASES.append(("p1_degen", 0, KR_full[:qn], qn, 0, 0))
    report.append(("p1_degen", qn, 0, 0, 0, 0))

    # ---- fp32 primitive vectors ------------------------------------------------------------
    # The geometry cases cannot reach every corner of the rounding logic (see the header: the
    # alignment sticky bit is invisible to them). These drive sar_fp32_mul / sar_fp32_add
    # directly, weighted toward round-to-nearest-even ties and wide alignments.
    rng = np.random.default_rng(20260725)
    fp = []
    struct = [1.0, -1.0, 0.5, 2.0, 3.0, 32768.0, 1.0 / 3.0, 49.455215, -51.876793,
              0.0057499614, -0.0057682157, 61300.0, 8.2e-4, 16777215.0, 8388609.0, 1.0000001]
    for a in struct:
        for b in struct:
            fp.append((bits(a), bits(b)))
    for _ in range(1200):                      # wide alignment -> exercises align + sticky
        e = int(rng.integers(-30, 30))
        d = int(rng.integers(0, 30))
        a = np.float32(rng.standard_normal() * (2.0 ** e))
        b = np.float32(rng.standard_normal() * (2.0 ** (e - d)))
        if a == 0 or b == 0:
            continue
        fp.append((bits(a), bits(b)))
    for _ in range(1200):                      # heavy cancellation -> exercises LZC + normalize
        a = np.float32(rng.standard_normal() * (2.0 ** int(rng.integers(-12, 4))))
        if a == 0:
            continue
        b = np.float32(a * (np.float32(1.0) + np.float32(rng.standard_normal() * 1e-4)))
        if b == 0:
            continue
        fp.append((bits(a), bits(-b)))
    fpv = []
    flp = Flags()
    for a_b, b_b in fp:
        fpv += [a_b, b_b, fmul(a_b, b_b, flp), fadd(a_b, b_b, flp)]
    assert flp.fmt == 0 and flp.ovf == 0, "fp primitive vectors hit a format/range corner"

    def w(n, s):
        (HERE / n).write_text(s)

    w("cg_fp.hex", "".join(f"{v & 0xFFFFFFFF:08x}\n" for v in fpv))
    w("cg_tab.hex", "".join(f"{v & 0xFFFFFFFF:08x}\n" for v in tab))
    w("cg_exp.hex", "".join(f"{v & ((1 << 48) - 1):012x}\n" for v in exp))
    w("cg_cfg.hex", "".join(f"{v & 0xFFFFFFFF:08x}\n" for v in cfg))
    names = " \\\n".join(f'    names[{c}] = "{cs[0]}";' for c, cs in enumerate(CASES))
    w("cg_dims.vh",
      f"`define NCASES {len(CASES)}\n`define SMAX {S}\n`define QNMAX {max(c[3] for c in CASES)}\n"
      f"`define CFGW {CFGW}\n`define TAB_WORDS {len(tab)}\n`define EXP_WORDS {len(exp)}\n"
      f"`define FP_VECS {len(fpv) // 4}\n"
      f"`define CASE_NAMES \\\n{names}\n")

    print(f"S(M)={S}  cases={len(CASES)}  table words={len(tab)}  expected entries={len(exp)}")
    print(f"{'case':12s} {'QN':>5s} {'in-range':>9s} {'non-trivial wq':>15s} {'wq min':>7s} "
          f"{'wq max':>7s}")
    for name, qn, nin, nmid, wmin, wmax in report:
        print(f"{name:12s} {qn:5d} {nin:9d} {nmid:15d} {wmin:7d} {wmax:7d}")
    # A payload-free TB proves nothing (see tb_sar_axi_idconv.v). Refuse to emit vectors that
    # would let the TB pass on handshakes alone.
    live = [r for r in report if r[0] not in ("degen_kr0", "p1_degen")]
    for r in live:
        # Real-KR pass-1 rows only intersect the pulse's own extent (~N of QN), so they are held
        # to a lower but still non-hollow bar; everything else must be densely in-range.
        floor = 200 if r[0].startswith("p1_row") else 500
        assert r[2] > floor, f"{r[0]}: too few in-range outputs ({r[2]} <= {floor})"
        assert r[3] > floor // 2, f"{r[0]}: too few non-trivial weights ({r[3]})"
    assert all(r[3] > 200 for r in live), "a value case has too few non-saturated weights"
    print(f"\nwrote -> {HERE}")


if __name__ == "__main__":
    main()
