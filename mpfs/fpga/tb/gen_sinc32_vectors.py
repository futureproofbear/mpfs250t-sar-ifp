#!/usr/bin/env python
"""Vectors for tb_sar_sinc32.v -- the 32-tap polyphase-sinc gather core.

The DUT is checked against gen_resample_vectors.gather_sinc(), which is the bit-accurate model of
the Q15 contract. Written from the CONTRACT, not from the RTL structure, so a banking-rotation or
pipeline bug shows up as a value difference rather than being reproduced on both sides.

WHAT THIS EXERCISES THAT A SMALL CASE CANNOT
  * the mod-32 banking rotation at EVERY rotation r = (idx-15) mod 32, so the barrel shift is
    covered for all 32 alignments rather than whichever one a short case happens to hit
  * bank-row crossing: windows where baseA and baseA+1 are both read (b < r)
  * the edge-fallback contract at both line ends (core must stay SILENT)
  * a real-geometry line, at the silicon scale the shipped design actually runs

EDGE POLICY: FALLBACK, not extension. The window spans idx-15 .. idx+16, so near the line ends it
reaches outside [0, N-1]. Reading further along DDR is NOT a valid continuation -- for the range
pass the next addresses hold the NEXT PULSE's samples -- so those windows are flagged `edge` and
the core produces NO OUTPUT for them; the caller supplies the 2-tap lerp instead. The bench checks
BOTH halves of that contract: full-tap values where the window fits, and SILENCE where it does
not. A core that quietly emitted a wrong value on an edge request would pass a values-only test.

Emits (gitignored):
    s32_coef.hex   Q15 taps, phase-major/tap-minor, exactly the ct_we load order
    s32_src.hex    the source line, index 0..N-1
    s32_req.hex    one word per request: {edge, wq[14:0], idx[15:0]}
    s32_exp.hex    expected output word, NON-EDGE requests only (edges produce none)
    s32_dims.vh    `defines
"""
import argparse
import json
import math
import pathlib
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gen_resample_vectors as G                                   # noqa: E402
from fractions import Fraction as F                                # noqa: E402


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x >= 0x8000 else x


def build_requests(stage, line, taps):
    """Real-geometry (idx, wq) for one pulse, plus a synthetic sweep that hits every rotation."""
    L = json.loads((stage / "layout.json").read_text())
    n, npg = L["dims"]["N"], L["fft_len"]["R"]
    f0 = np.fromfile(stage / "f0.bin", dtype=np.float32).astype(np.float64)
    df = np.fromfile(stage / "df.bin", dtype=np.float32).astype(np.float64)
    pr = np.fromfile(stage / "pr.bin", dtype=np.float32).astype(np.float64)
    KR = np.fromfile(stage / "krgrid.bin", dtype=np.float32).astype(np.float64)

    ag = F(2) * F(float(pr[line])) / F(299792458)
    x0, dx = ag * F(float(f0[line])), ag * F(float(df[line]))
    real = KR[:n] if n < npg else KR
    kr_off = F(float(real.min()))
    ks = F(1 << 30) / F(float(np.abs(real - float(kr_off)).max()))
    kri = []
    for k in KR:
        t = G.iround((F(float(k)) - kr_off) * ks)
        kri.append(min(max(t, -(1 << 31)), (1 << 31) - 1))
    sh, a = G.pick_sh(F(1 << 24) / (ks * dx), "sinc32")
    b = G.iround((kr_off - x0) * F(1 << 24) / dx)
    idx, wq, _ = G.coeffs_mode0(kri, a, sh, b, n)

    lo_ = taps // 2 - 1
    req = [(i, w, 1 if (i < lo_ or i > n - (taps - lo_)) else 0)
           for i, w in zip(idx, wq) if i >= 0]

    # ROTATION SWEEP: force every r = (idx-15) mod 32 at least once. Real geometry walks idx
    # monotonically, so it does hit all 32, but only by luck of the step size -- assert it, and
    # top up deliberately so this stays true for any future scene.
    seen = {((i - (taps // 2 - 1)) % taps) for i, _, e in req if not e}
    lo = taps // 2 - 1
    for r in range(taps):
        if r not in seen:
            i = lo + r
            if 0 <= i < n:
                req.append((i, 12345, 0))
    return n, npg, req, sh, a, b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", default="../../host/jtag_stage_deci1")
    ap.add_argument("--line", type=int, default=0)
    ap.add_argument("--max-req", type=int, default=0, help="0 = all")
    a = ap.parse_args()

    taps, phases = G.SINC_TAPS, G.SINC_PHASES
    stage = HERE / a.stage if not pathlib.Path(a.stage).is_absolute() else pathlib.Path(a.stage)
    n, npg, req, sh, A, B = build_requests(stage, a.line, taps)
    if a.max_req:
        req = req[: a.max_req]

    # ---- source: the real line; edge windows never read outside it (see edge policy) ----
    raw = np.fromfile(stage / "sig.bin", dtype=np.uint32, count=n,
                      offset=a.line * n * 4).tolist()
    lo = -(taps // 2 - 1)

    def src_at(j):
        # Only ever called for non-edge requests, where the whole window is in range by
        # construction. The bounds check stays as an assertion of that invariant.
        assert 0 <= j < n, "non-edge request reached outside the line"
        return raw[j]

    # ---- expected, straight from the model ----
    tab = G.sinc_table_q15(phases, taps)
    exp = []
    for i, w, e in req:
        if e:
            continue                     # edge: the core must stay SILENT, no expected value
        c = tab[(w * phases) >> 15]
        xs = [src_at(i + lo + t) for t in range(taps)]
        # ROUND-TO-NEAREST, not truncate. A bare >>15 floors, which puts a systematic
        # -0.5 LSB bias on EVERY output -- a DC offset across the whole image. With 32
        # taps that is free to avoid: one add before the shift.
        hi = (sum(ci * s16(x >> 16) for ci, x in zip(c, xs)) + (1 << 14)) >> 15
        lw = (sum(ci * s16(x & 0xFFFF) for ci, x in zip(c, xs)) + (1 << 14)) >> 15
        hi = -32768 if hi < -32768 else (32767 if hi > 32767 else hi)
        lw = -32768 if lw < -32768 else (32767 if lw > 32767 else lw)
        exp.append(((hi & 0xFFFF) << 16) | (lw & 0xFFFF))

    w = lambda f, s: (HERE / f).write_text(s)
    w("s32_coef.hex", "".join(f"{tab[p][t] & 0xFFFF:04x}\n"
                             for p in range(phases) for t in range(taps)))
    w("s32_src.hex", "".join(f"{raw[j] & 0xFFFFFFFF:08x}\n" for j in range(n)))
    w("s32_req.hex", "".join(f"{(e_ & 1) << 31 | (w_ & 0x7FFF) << 16 | (i_ & 0xFFFF):08x}\n"
                             for i_, w_, e_ in req))
    w("s32_exp.hex", "".join(f"{e & 0xFFFFFFFF:08x}\n" for e in exp))
    w("s32_dims.vh",
      f"`define S32_TAPS {taps}\n`define S32_PHASES {phases}\n"
      f"`define S32_N {n}\n`define S32_NREQ {len(req)}\n`define S32_NEXP {len(exp)}\n")

    rots = sorted({((i - (taps // 2 - 1)) % taps) for i, _, e in req if not e})
    edge = sum(1 for _, _, e in req if e)
    print(f"  line {a.line}: N={n} Np={npg} SH={sh} A={A} B={B}")
    print(f"  requests {len(req)} ({len(exp)} full-tap + {edge} edge/silent), "
          f"rotations covered {len(rots)}/{taps}")
    assert len(rots) == taps, "rotation sweep incomplete -- the barrel shift would be undertested"
    assert edge > 0, "no line-end request -- the edge-fallback contract would be untested"
    return 0


if __name__ == "__main__":
    sys.exit(main())
