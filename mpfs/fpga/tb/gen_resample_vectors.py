#!/usr/bin/env python
"""Generate bit-exact reference vectors for tb_sar_resample.v (fused resample gather kernel).

AUTHORITY. The arithmetic reproduced here is the FIXED-POINT contract documented in the header
of mpfs/fpga/sar_resample_v.v ("NUMERIC FORMAT"), which is what the DUT must implement:

    v = ((QTAB[i] * A) >>> SH) + B                                48-bit signed
  MODE=0  v is Q24 in SOURCE SAMPLES
            idx = v[37:24] ; wq = v[23:9] + v[8] (clamp 32767) ; valid iff 0 <= v < (SN-1)*2^24
  MODE=1  v is Q12 in TS_i COUNTS
            merge-scan v against TS_i[k]*2^12 ; idx = k
            wq = ((v - TS_i[k]*2^12) * INV_i[k]) >>> FSH , clamp [0,32767] , FSH = INVQ-3
            valid iff TS_i[0]*2^12 <= v < TS_i[SN-1]*2^12
  out[i]  = lerp(in[idx], in[idx+1], wq) per 16-bit half, exactly as resample.cpp; idx<0 -> 0

It is written from that SPEC, deliberately NOT from the RTL structure, so a scan/pipeline bug in
the RTL shows up as a value diff. Everything is Python int / Fraction: no numpy, no float
accumulation, because the products here are up to 2^62 and an int64 wrap is silent.

  *** SH: THE BRIEF'S SH=44 IS ARITHMETICALLY UNREACHABLE FOR THIS DUT ***
  SH_REQ below is the requested 44. pick_sh() asserts A fits in int32 (never silently wraps) and
  falls back to the largest feasible SH, printing what it had to do. The closed-form reason,
  which no choice of table scale can dodge:

      MODE=0 needs   QTAB[i]*A = t * 2^(SH+24) with t up to SN
      QTAB and A are both int32, so |QTAB*A| <= 2^62 (and pC in the RTL is 64 bits)
      => t <= 2^(38-SH).  At SH=44 that is t <= 2^-6: every query lands in bracket 0.
      MODE=1 needs   QTAB[i]*A = (TS span) * 2^(SH+12), same 2^62 ceiling.

  The feasible window for this datapath is SH ~ 25 (MODE=0) / ~19-25 (MODE=1), i.e. two decades
  below [40,47]. Reaching SH=44 needs a wider QTAB*A product in the RTL, not a rescaled table.
  Flagged for the architectural-critic; the vectors below use the feasible SH so the six
  mandatory cases actually exercise the DUT.

Emits (into this directory, all gitignored):
    rs_mem.hex   64-bit DDR image (source lines + poisoned output regions)
    rs_tab.hex   32-bit on-chip table words, [case][sel 0=KR 1=KC 2=TS 3=INV][MAXTAB]
    rs_cfg.hex   32-bit per-case config, CFGW words per case
    rs_exp.hex   32-bit expected output words, MAXQ per case
    rs_idx.hex   32-bit expected idx (two's complement, -1 = zero fill), MAXQ per case
    rs_wq.hex    32-bit expected wq, MAXQ per case
    rs_dims.vh   `defines + the case-name table
"""
import math
import pathlib
from fractions import Fraction as F

SH_REQ = 44                 # the brief's derived constant; see the docstring
MAXTAB = 64                 # on-chip table depth used by the TB (TAB_AW=6)
MAXQ = 64                   # max QN per case
CFGW = 12                   # config words per case
MEM_BEATS = 2048
MEM_WORDS = MEM_BEATS * 2
POISON_IN = 0xDEADBEEF
POISON_OUT = 0xBAD0BAD0
IN_WORDS_PER_CASE = 256     # 1 KB source slot
OUT_WORD_BASE = 2048
OUT_WORDS_PER_CASE = 128

# ------------------------------------------------------------------ integer helpers
def iround(x):
    """round-half-up on a Fraction/int -- what the CPU-side table build does"""
    return math.floor(F(x) + F(1, 2))


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x >= 0x8000 else x


def fits32(x):
    return -(1 << 31) <= x <= (1 << 31) - 1


def fits48(x):
    return -(1 << 47) <= x <= (1 << 47) - 1


def wrap48(x):
    x &= (1 << 48) - 1
    return x - (1 << 48) if x >= (1 << 47) else x


def u32(x):
    return x & 0xFFFFFFFF


sh_notes = []


def pick_sh(unit, what):
    """Largest SH <= SH_REQ whose mantissa A = round(unit*2^SH) still fits in int32.

    The int32 assertion is the point: silently wrapping A here would produce a plausible but
    wrong affine map, and every downstream value check would then be verifying the wrong thing.
    """
    for sh in range(SH_REQ, -1, -1):
        a = iround(F(unit) * (1 << sh))
        if a != 0 and fits32(a):
            if sh != SH_REQ:
                sh_notes.append(f"  {what:22s} SH={sh:2d} (SH_REQ={SH_REQ} needs "
                                f"A={iround(F(unit) * (1 << SH_REQ)):d}, |A| > 2^31)")
            assert fits32(a), "A does not fit int32"
            return sh, a
    raise SystemExit(f"{what}: no SH in [0,{SH_REQ}] gives a non-zero int32 A (unit={float(unit)})")


# ------------------------------------------------------------------ the DUT's affine map
def affine(q, a, sh, b):
    """v = ((q*A) >>> SH) + B with the RTL's exact widths and overflow flags."""
    p = q * a                      # 64-bit signed product, exact (|q|,|a| <= 2^31)
    ps = p >> sh                   # arithmetic shift == floor, as in Verilog >>>
    sat_sh = not fits48(ps)        # RTL: p_shift[63:48] != sign-extension of bit 47
    vs = wrap48(ps) + b            # RTL truncates p_shift to 48 bits before the add
    sat_add = not fits48(vs)
    return wrap48(vs), (sat_sh or sat_add)


# ------------------------------------------------------------------ coefficient models
def coeffs_mode0(qtab, a, sh, b, sn):
    idx, wq, sat = [], [], []
    tmax = (sn - 1) << 24
    for q in qtab:
        v, st = affine(q, a, sh, b)
        sat.append(st)
        if st or v < 0 or v >= tmax:
            idx.append(-1)
            wq.append(0)
            continue
        raw = ((v >> 9) & 0x7FFF) + ((v >> 8) & 1)      # round-to-nearest, 16-bit sum
        idx.append(v >> 24)
        wq.append(32767 if raw & 0x8000 else raw)
    return idx, wq, sat


def coeffs_mode1(qtab, a, sh, b, ts, inv, fsh, sn):
    idx, wq, sat = [], [], []
    lo = ts[0] << 12
    hi = ts[sn - 1] << 12
    for q in qtab:
        v, st = affine(q, a, sh, b)
        sat.append(st)
        if st or v < lo or v >= hi:
            idx.append(-1)
            wq.append(0)
            continue
        # bracket: largest k <= SN-2 with TS[k]*2^12 <= v  (the merge scan's fixed point)
        k = 0
        while k + 2 < sn and (ts[k + 1] << 12) <= v:
            k += 1
        d = v - (ts[k] << 12)
        if d < 0 or d >= (1 << 32):     # RTL saturates dlt into 32 bits
            d = 0
        f = (d * inv[k]) >> fsh
        idx.append(k)
        wq.append(0 if f < 0 else (32767 if f >= (1 << 15) else f))
    return idx, wq, sat


def gather(src, idx, wq):
    """out = lerp(in[idx], in[idx+1], wq) per half, int16 truncation. idx<0 -> zero fill."""
    out = []
    for k, w in zip(idx, wq):
        if k < 0:
            out.append(0)
            continue
        a, b = src[k], src[k + 1]
        ah, al = s16(a >> 16), s16(a & 0xFFFF)
        bh, bl = s16(b >> 16), s16(b & 0xFFFF)
        rh = ah + (((bh - ah) * w) >> 15)
        rl = al + (((bl - al) * w) >> 15)
        out.append(((rh & 0xFFFF) << 16) | (rl & 0xFFFF))
    return out


def lagrange_taps_q15(w):
    """4-point cubic Lagrange weights at fractional delay mu = w/32768, returned in Q15.

    THE FIXED-POINT CONTRACT the RTL must implement. Taps sit at idx-1, idx, idx+1, idx+2:

        L(-1) = -mu (mu-1)(mu-2) / 6        L(0)  =  (mu+1)(mu-1)(mu-2) / 2
        L(+1) = -(mu+1) mu (mu-2) / 2       L(+2) =  (mu+1) mu (mu-1) / 6

    Exact rational throughout, then ONE rounding to Q15 per tap -- not a chain of roundings --
    so the model is reproducible and the RTL has an unambiguous target. Weights are in about
    [-0.13, 1.13], so Q15 signed holds them with room; the sum is exactly 1.0 in exact
    arithmetic and within a few LSB after rounding, which is what stops a DC gain error.
    """
    mu = F(w, 1 << 15)
    c = (-mu * (mu - 1) * (mu - 2) / 6,
         (mu + 1) * (mu - 1) * (mu - 2) / 2,
         -(mu + 1) * mu * (mu - 2) / 2,
         (mu + 1) * mu * (mu - 1) / 6)
    return [iround(x * (1 << 15)) for x in c]


SINC_TAPS    = 32      # taps at idx-15 .. idx+16. 32 chosen 2026-07-29 from measured
                       # SCALLOPING, the artefact that actually shows in the image: the
                       # shipping 2-tap lerp scallops 29.2 dB at 0.978 Nyquist (the
                       # classic linear-interp null at mu=0.5), 32 taps brings that to
                       # ~3 dB. 16 dual-port banks + 64 MACs/stage.
SINC_PHASES  = 256     # measured: 1024 phases buys only ~0.5 dB, so 256 is enough


def sinc_table_q15(phases=SINC_PHASES, taps=SINC_TAPS):
    """Polyphase truncated-sinc coefficients, Q15, [phase][tap].

    SCENE-INDEPENDENT -- these depend only on the fractional delay, never on geometry, so unlike
    the KR/KC query tables this is a CONSTANT: load once at init or ROM-initialise it. That is
    what makes sinc practical on this FPGA: no coefficient arithmetic in the datapath at all
    (Farrow would need a Horner cascade before the dot product can start), which matters when the
    100 MHz domain has 0.255 ns of setup slack.

    DC-NORMALISED per phase. Raw truncated sinc does not sum to 1, and an un-normalised table puts
    a gain error on every output sample. Measured 2026-07-29 (mpfs/host/interp_kernel_study.py):
    at 0.815 Nyquist an 8-tap sinc reaches about -23 dB complex error against the ideal fractional
    delay, versus -11 dB for an 8-tap Lagrange -- same datapath, same MACs, different table.
    """
    lo = -(taps // 2 - 1)                                  # -3 for 8 taps
    tab = []
    for ph in range(phases):
        mu = F(ph, phases)
        c = [F(1) if (mu - (lo + k)) == 0 else
             F(math.sin(math.pi * float(mu - (lo + k)))) / (F(math.pi) * (mu - (lo + k)))
             for k in range(taps)]
        s = sum(c)
        q = [iround(x / s * (1 << 15)) for x in c]
        # FORCE the sum to exactly 2^15. Rounding each tap independently leaves a residual that
        # grows with tap count -- harmless at 8 taps, but at 24 it left 17 of 256 phases more than
        # 2 LSB off unity, which is a per-phase GAIN RIPPLE, i.e. amplitude modulation across the
        # image that no amount of downstream scaling removes.
        #
        # ...but the residual CANNOT simply go on the largest tap. Q15 unity is 32768, which is
        # already one past the int16 rail, so near mu=0 the centre tap is at or above 32767 and
        # adding to it WRAPS NEGATIVE. That is a real bug this code shipped with: the RTL stores
        # signed [15:0], so phase 251 tap 16 became -32749 instead of 32787 and every query on
        # such a phase came out with the dominant tap inverted (267 of 3621 outputs, 2026-07-29).
        # Spread the residual instead, largest-magnitude tap first, and only as far as each tap's
        # remaining int16 headroom allows.
        lo_i, hi_i = -(1 << 15), (1 << 15) - 1
        q = [min(max(v, lo_i), hi_i) for v in q]
        resid = (1 << 15) - sum(q)
        for i in sorted(range(len(q)), key=lambda j: -abs(q[j])):
            if resid == 0:
                break
            room = (hi_i - q[i]) if resid > 0 else (lo_i - q[i])
            step = resid if abs(resid) <= abs(room) else room
            q[i] += step
            resid -= step
        assert resid == 0, "cannot reach unity gain within int16 -- the kernel needs a wider tap"
        assert all(lo_i <= v <= hi_i for v in q), "coefficient outside int16"
        tab.append(q)
    return tab


def gather_sinc(src, idx, wq, sn, tab=None, taps=SINC_TAPS):
    """out = N-tap polyphase sinc. Phase index = (wq * phases) >> 15.

    EDGE RULE, same principle as gather_cubic: N taps need idx+lo .. idx+lo+N-1, so full width
    is used only where the whole span is in range and the line's first/last few brackets fall back to the 2-tap lerp.
    This keeps the SET OF NON-ZERO OUTPUTS IDENTICAL to the linear path, so an A/B against the
    shipping kernel is a like-for-like value comparison and not a support change."""
    if tab is None:
        tab = sinc_table_q15(taps=taps)
    lo = -(taps // 2 - 1)
    out = []
    for k, w in zip(idx, wq):
        if k < 0:
            out.append(0)
            continue
        if k < -lo or k > sn - (taps + lo) - 1:
            a, b = src[k], src[k + 1]
            ah, al = s16(a >> 16), s16(a & 0xFFFF)
            bh, bl = s16(b >> 16), s16(b & 0xFFFF)
            rh = ah + (((bh - ah) * w) >> 15)
            rl = al + (((bl - al) * w) >> 15)
        else:
            c = tab[(w * len(tab)) >> 15]
            xs = [src[k + lo + j] for j in range(taps)]
            # ROUND-TO-NEAREST, not truncate. A bare >>15 floors, which puts a systematic
            # -0.5 LSB bias on EVERY output -- a DC offset across the whole image. With 32
            # taps that is free to avoid: one add before the shift.
            hi = (sum(ci * s16(x >> 16) for ci, x in zip(c, xs)) + (1 << 14)) >> 15
            loo = (sum(ci * s16(x & 0xFFFF) for ci, x in zip(c, xs)) + (1 << 14)) >> 15
            rh = -32768 if hi < -32768 else (32767 if hi > 32767 else hi)
            rl = -32768 if loo < -32768 else (32767 if loo > 32767 else loo)
        out.append(((rh & 0xFFFF) << 16) | (rl & 0xFFFF))
    return out


def gather_cubic(src, idx, wq, sn):
    """out = 4-tap cubic Lagrange. idx<0 -> zero fill, exactly as linear.

    EDGE RULE, chosen deliberately: cubic needs idx-1 and idx+2, so it is only applied when
    1 <= idx <= sn-3. Outside that -- the first and last bracket of the line -- it falls back to
    the 2-tap lerp. That keeps the SET OF NON-ZERO OUTPUTS IDENTICAL to the linear path, so the
    zero-fill pattern is unchanged and the two interpolators stay directly comparable. Zeroing
    the edges instead would change the support and confound every comparison."""
    out = []
    for k, w in zip(idx, wq):
        if k < 0:
            out.append(0)
            continue
        if k < 1 or k > sn - 3:
            a, b = src[k], src[k + 1]                      # linear fallback at the edges
            ah, al = s16(a >> 16), s16(a & 0xFFFF)
            bh, bl = s16(b >> 16), s16(b & 0xFFFF)
            rh = ah + (((bh - ah) * w) >> 15)
            rl = al + (((bl - al) * w) >> 15)
        else:
            c = lagrange_taps_q15(w)
            xs = [src[k - 1], src[k], src[k + 1], src[k + 2]]
            hi = sum(ci * s16(x >> 16) for ci, x in zip(c, xs)) >> 15
            lo = sum(ci * s16(x & 0xFFFF) for ci, x in zip(c, xs)) >> 15
            rh = -32768 if hi < -32768 else (32767 if hi > 32767 else hi)
            rl = -32768 if lo < -32768 else (32767 if lo > 32767 else lo)
        out.append(((rh & 0xFFFF) << 16) | (rl & 0xFFFF))
    return out


# ------------------------------------------------------------------ source samples
def source_line(cid, sn):
    """Adversarial source: all four sign combinations plus the int16 extremes."""
    src = []
    for j in range(sn):
        i = s16((j * 7919 + cid * 4523 + 13) * 37)
        q = s16((j * 6271 - cid * 2749 - 5) * 53)
        if j % 13 == 0:
            i, q = -32768, 32767
        if j % 17 == 5:
            i, q = 32767, -32768
        src.append(((i & 0xFFFF) << 16) | (q & 0xFFFF))
    return src


# ------------------------------------------------------------------ case builders
CASES = []


def add_case(name, mode, sn, qn, sh, a, b, fsh, qtab, ts, inv, idx, wq, in_odd,
             inject, note=""):
    cid = len(CASES)
    src = source_line(cid, sn)
    exp = gather(src, idx, wq)
    CASES.append(dict(name=name, mode=mode, sn=sn, qn=qn, sh=sh, a=a, b=b, fsh=fsh,
                      qtab=qtab, ts=ts, inv=inv, idx=idx, wq=wq, src=src, exp=exp,
                      in_odd=in_odd, inject=inject, sat=False, note=note))
    return CASES[-1]


def build_mode0(name, sn, qn, x0, dx, t0, tstep, in_odd=False, inject=False,
                b_force=None, a_flip=False, note=""):
    x0, dx = F(x0), F(dx)
    tq = [F(t0) + F(tstep) * i for i in range(qn)]
    kr = [x0 + t * dx for t in tq]
    kr_off = x0 - 7 * dx                       # line-invariant offset, folded into B
    span = max(abs(k - kr_off) for k in kr)
    kr_scale = F(1 << 30) / span               # table spans about +/-2^30
    kri = [iround((k - kr_off) * kr_scale) for k in kr]
    assert all(fits32(k) for k in kri), "KR_i overflows int32"
    unit = F(1 << 24) / (kr_scale * dx)        # = A / 2^SH
    sh, a = pick_sh(unit, name)
    if a_flip:
        a = -a
    b = b_force if b_force is not None else iround((kr_off - x0) * F(1 << 24) / dx)
    assert fits48(b), "B overflows 48 bits"
    idx, wq, sat = coeffs_mode0(kri, a, sh, b, sn)
    c = add_case(name, 0, sn, qn, sh, a, b, 0, kri, [], [], idx, wq, in_odd, inject, note)
    c["sat"] = any(sat)
    c["nsat"] = sum(sat)
    return c


def build_real(name, stage, line=0, in_odd=False, note=""):
    """ONE case at the REAL silicon scale, from the staged scene geometry.

    WHY: every other case here is SN<=64 / QN<=32, while silicon runs SN=4319 / QN=8192 -- about
    128x. On 2026-07-29 the small suite passed 16/16 (and passes at the silicon parameterisation
    too) while the actual scene produced a corr -0.04 image, so scale is a dimension the suite
    could not reach. This mirrors what the FIRMWARE does, not a synthetic analogue:
    sar_resample_v.c's derivation, including the padding CLAMP that the small cases never need
    because a synthetic case has no out-of-range filler."""
    import numpy as np
    st = pathlib.Path(stage)
    lay = __import__("json").loads((st / "layout.json").read_text())
    n, np_grid = lay["dims"]["N"], lay["fft_len"]["R"]
    f0 = np.fromfile(st / "f0.bin", dtype=np.float32).astype(np.float64)
    df = np.fromfile(st / "df.bin", dtype=np.float32).astype(np.float64)
    pr = np.fromfile(st / "pr.bin", dtype=np.float32).astype(np.float64)
    KR = np.fromfile(st / "krgrid.bin", dtype=np.float32).astype(np.float64)

    ag = F(2) * F(float(pr[line])) / F(299792458)
    x0, dx = ag * F(float(f0[line])), ag * F(float(df[line]))

    real = KR[:n] if n < np_grid else KR
    kr_off = F(float(real.min()))
    kr_scale = F(1 << 30) / F(float(np.abs(real - float(kr_off)).max()))
    kri, nclamp = [], 0
    for k in KR:
        t = iround((F(float(k)) - kr_off) * kr_scale)
        if not fits32(t):                       # the deliberate out-of-range padding
            t = (1 << 31) - 1 if t > 0 else -(1 << 31)
            nclamp += 1
        kri.append(t)

    sh, a = pick_sh(F(1 << 24) / (kr_scale * dx), name)
    b = iround((kr_off - x0) * F(1 << 24) / dx)
    assert fits48(b), "B overflows 48 bits"
    idx, wq, sat = coeffs_mode0(kri, a, sh, b, n)
    inr = sum(1 for i in idx if i >= 0)
    assert inr > 1000, (f"real case has only {inr} in-range queries -- too close to vacuous to "
                       f"be worth running")
    c = add_case(name, 0, n, np_grid, sh, a, b, 0, kri, [], [], idx, wq, in_odd, False, note)
    c["sat"] = any(sat)
    c["nsat"] = sum(sat)
    c["real"] = True
    print(f"  real case: SN={n} QN={np_grid} SH={sh} A={a} B={b} "
          f"in-range={inr} clamped-padding={nclamp}")
    return c


def build_mode1(name, sn, qn, kr_line, in_odd=False, inject=False, note=""):
    # source: tan_s ascending and deliberately NON-uniform, so INV_i varies bracket to bracket
    tan = [F(-0.35) + F(7, 10) * k / (sn - 1) + F(9, 10000) * F(math.sin(1.7 * k))
           for k in range(sn)]
    assert all(tan[k + 1] > tan[k] for k in range(sn - 1)), "tan_s must ascend"
    ts_off = tan[sn // 2]
    dmax = max(tan[k + 1] - tan[k] for k in range(sn - 1))
    # scale so the widest bracket is ~2^18 counts: dlt = span*2^12 must stay inside the RTL's
    # 32-bit dlt register (span < 2^19), which is the same regime the 8192-point scene sits in.
    ts_scale = F(1 << 18) / dmax
    ts = [iround((t - ts_off) * ts_scale) for t in tan]
    assert all(fits32(t) for t in ts), "TS_i overflows int32"
    assert all(ts[k + 1] > ts[k] for k in range(sn - 1)), "TS_i must ascend strictly"
    d = [ts[k + 1] - ts[k] for k in range(sn - 1)]
    assert max(d) << 12 < (1 << 31), "bracket span overflows the RTL's 32-bit dlt"
    invq = int(math.floor(math.log2(((1 << 31) - 1) * min(d))))
    inv = [iround(F(1 << invq, dk)) for dk in d] + [0]
    inv[sn - 1] = inv[sn - 2]
    assert all(0 < i <= (1 << 31) - 1 for i in inv[:sn]), "INV_i out of int32"
    fsh = invq - 3
    assert 0 <= fsh <= 63, "FSH does not fit the 6-bit LCFG field"

    # KC is the SCENE's fixed query table; kr_line is the only per-line scalar.
    kr_ref = F(100000)
    kc = [(F(-37, 100) + F(74, 100) * i / (qn - 1)) * kr_ref for i in range(qn)]
    kc_off = kc[qn // 3]
    kc_scale = F(1 << 30) / max(abs(k - kc_off) for k in kc)
    kci = [iround((k - kc_off) * kc_scale) for k in kc]
    assert all(fits32(k) for k in kci), "KC_i overflows int32"

    krl = F(kr_line)
    unit = ts_scale * (1 << 12) / (kc_scale * krl)
    sh, a = pick_sh(unit, name)
    b = iround((kc_off / krl - ts_off) * ts_scale * (1 << 12))
    assert fits48(b), "B overflows 48 bits"

    idx, wq, sat = coeffs_mode1(kci, a, sh, b, ts, inv, fsh, sn)

    # The merge scan REQUIRES v monotonically non-decreasing in the DUT's walk order
    # (ascending i for kr>0, descending i for kr<0). Assert it, so a value diff can only be
    # a DUT bug and not an unfair vector.
    vs = [affine(q, a, sh, b)[0] for q in kci]
    walk = vs if a >= 0 else vs[::-1]
    assert all(walk[i + 1] >= walk[i] for i in range(len(walk) - 1)), "v not monotone in walk order"

    # how many bracket advances land back-to-back (0 advances = pure emit)
    ks = [k for k in (idx if a >= 0 else idx[::-1]) if k >= 0]
    runs = [ks[0]] + [ks[i + 1] - ks[i] for i in range(len(ks) - 1)]
    c = add_case(name, 1, sn, qn, sh, a, b, fsh, kci, ts, inv, idx, wq, in_odd, inject, note)
    c["sat"] = any(sat)
    c["nsat"] = sum(sat)
    c["maxrun"] = max(runs)
    return c


def main():
    global MAXTAB, MAXQ, MEM_BEATS, MEM_WORDS, IN_WORDS_PER_CASE, OUT_WORD_BASE, OUT_WORDS_PER_CASE
    here = pathlib.Path(__file__).resolve().parent

    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--real", metavar="STAGE", nargs="?", const="../../host/jtag_stage_deci1",
                    help="emit ONE full-scale case from a staged scene instead of the small "
                         "suite (SN=4319, QN=8192 -- the geometry silicon actually runs)")
    ap.add_argument("--lines", default="0", help="comma-separated pulse indices, with --real. "
                    "MORE THAN ONE is the point: silicon arms 5634 DIFFERENT lines back-to-back "
                    "against ONE table load, and the bench had only ever re-armed the SAME line")
    a = ap.parse_args()

    if a.real:
        # Full scale needs the arrays to fit the real dims; the small suite's 64-entry tables and
        # 1 KB source slot cannot hold a 4319-sample line or an 8192-entry query grid.
        MAXTAB = MAXQ = 8192
        IN_WORDS_PER_CASE = OUT_WORDS_PER_CASE = 8192
        # +16 words of GUARD past the output region. finish() checks for writes past the line;
        # without room for it the TB reads outside its own array and reports 8 phantom 'wrote
        # past the line (xxxxxxxx)' failures that look like a DUT overrun. Cost real debugging
        # time on 2026-07-29 -- the guard must EXIST for the guard check to mean anything.
        stage = here / a.real if not pathlib.Path(a.real).is_absolute() else pathlib.Path(a.real)
        # BOTH IN_BASE parities. On silicon a pulse row is N*4 = 17276 bytes, and 17276 mod 8 = 4,
        # so every ODD pulse starts 4 bytes into a 64-bit beat and takes the rd_odd path. Testing
        # only the aligned one would cover half the real frame.
        lines = [int(x) for x in a.lines.split(",")]
        for n, ln in enumerate(lines):
            # parity alternates exactly as on silicon: a pulse row is N*4 = 17276 bytes and
            # 17276 mod 8 = 4, so odd pulses start 4 bytes into a beat (the rd_odd path).
            build_real(f"real-L{ln}", stage, ln, in_odd=bool(ln & 1),
                       note=f"REAL line {ln}, silicon scale, "
                            f"{'4-byte-offset' if ln & 1 else 'aligned'} IN_BASE")
        nc = len(lines)
        OUT_WORD_BASE = nc * IN_WORDS_PER_CASE
        MEM_WORDS = OUT_WORD_BASE + nc * (OUT_WORDS_PER_CASE + 16)
        MEM_BEATS = MEM_WORDS // 2
        return finish(here)

    # (a) MODE=0 ascending (dx>0) -- queries walk from below the grid to past its end, so the
    #     idx=-1 zero fill is exercised at BOTH ends (mandatory case c).
    build_mode0("m0-asc", sn=64, qn=32, x0=1.0e8, dx=5000.0, t0=-3.0, tstep=2.2,
                note="dx>0, zero fill both ends")
    # (a) MODE=0 DESCENDING (dx<0). Same t sequence, so the same brackets, but A is negative.
    #     IN_BASE also carries the odd 32-bit word offset that pass 1 really has on silicon.
    build_mode0("m0-desc-odd", sn=64, qn=32, x0=1.0e8, dx=-5000.0, t0=-3.0, tstep=2.2,
                in_odd=True, note="dx<0 + odd IN_BASE word")
    # (b) MODE=1, kr>0 and kr<0. FINE = source coarser than the query step, so the scan never
    #     needs two advances in a row; COARSE = 2-3 advances per query. Splitting them isolates
    #     a sign bug from a multi-advance bug.
    build_mode1("m1-pos-fine", sn=20, qn=32, kr_line=97000.0, note="kr>0, <=1 advance/query")
    build_mode1("m1-pos-coarse", sn=64, qn=32, kr_line=97000.0, note="kr>0, multi-advance")
    build_mode1("m1-neg-fine", sn=20, qn=32, kr_line=-103000.0, note="kr<0, descending source")
    build_mode1("m1-neg-coarse", sn=64, qn=32, kr_line=-103000.0, note="kr<0, multi-advance")
    # (d) stray R beat: identical to m0-asc, plus one extra R beat injected after the first
    #     burst. err_extra must latch AND the line must not shift by a sample.
    build_mode0("m0-stray-R", sn=64, qn=32, x0=1.0e8, dx=5000.0, t0=-3.0, tstep=2.2,
                inject=True, note="stray R beat, must not shift")
    # (e) affine overflow: B parked one hair above the negative 48-bit rail and A negated, so
    #     the +B saturates for most queries. Every output must zero fill, err_sat must latch.
    sat = build_mode0("m0-affine-sat", sn=64, qn=32, x0=1.0e8, dx=5000.0, t0=-3.0, tstep=2.2,
                      b_force=-(1 << 47) + 10 * (1 << 24), a_flip=True,
                      note="48-bit affine overflow")
    assert sat["sat"], "saturation case never saturates -- vacuous"
    assert 0 < sat["nsat"] < sat["qn"], "saturation case must be a MIX of sat/non-sat"
    assert all(k < 0 for k in sat["idx"]), "saturated samples must be forced out of range"

    return finish(here)



def finish(here):
    ncases = len(CASES)

    # ---- memory image ----
    words = [POISON_IN] * MEM_WORDS
    for c, cs in enumerate(CASES):
        base = c * IN_WORDS_PER_CASE + (1 if cs["in_odd"] else 0)
        for j, w in enumerate(cs["src"]):
            words[base + j] = w
        obase = OUT_WORD_BASE + c * (OUT_WORDS_PER_CASE + 16)
        # +16: the "wrote past the line" guard compares against POISON_OUT, so the guard words
        # themselves must carry it. Leaving them at POISON_IN makes an untouched buffer read as
        # a DUT overrun.
        for j in range(OUT_WORDS_PER_CASE + 16):
            if obase + j < MEM_WORDS:
                words[obase + j] = POISON_OUT
        cs["in_base"] = base * 4
        cs["out_base"] = obase * 4
        assert cs["in_base"] % 4 == 0 and cs["out_base"] % 8 == 0

    beats = [(words[2 * b + 1] << 32) | words[2 * b] for b in range(MEM_BEATS)]

    # ---- tables / config / expectations ----
    tab = [0] * (ncases * 4 * MAXTAB)
    cfg = [0] * (ncases * CFGW)
    exp = [0] * (ncases * MAXQ)
    eidx = [0] * (ncases * MAXQ)
    ewq = [0] * (ncases * MAXQ)
    for c, cs in enumerate(CASES):
        sticky = 0                               # the TB resets the DUT before every case, so
                                                 # STATUS2 is per-case, not cumulative
        sel = 1 if cs["mode"] else 0
        for j, w in enumerate(cs["qtab"]):
            tab[(c * 4 + sel) * MAXTAB + j] = u32(w)
        for j, w in enumerate(cs["ts"]):
            tab[(c * 4 + 2) * MAXTAB + j] = u32(w)
        for j, w in enumerate(cs["inv"]):
            tab[(c * 4 + 3) * MAXTAB + j] = u32(w)
        if cs["inject"]:
            sticky |= 0x01                       # err_extra
        if cs["sat"]:
            sticky |= 0x10                       # err_sat
        cfg[c * CFGW + 0] = cs["mode"]
        cfg[c * CFGW + 1] = cs["qn"]
        cfg[c * CFGW + 2] = cs["sn"]
        cfg[c * CFGW + 3] = cs["sh"]
        cfg[c * CFGW + 4] = cs["fsh"]
        cfg[c * CFGW + 5] = u32(cs["a"])
        cfg[c * CFGW + 6] = u32(cs["b"] & 0xFFFFFFFF)
        cfg[c * CFGW + 7] = (cs["b"] >> 32) & 0xFFFF
        cfg[c * CFGW + 8] = cs["in_base"]
        cfg[c * CFGW + 9] = cs["out_base"]
        cfg[c * CFGW + 10] = 1 if cs["inject"] else 0
        cfg[c * CFGW + 11] = sticky
        for j in range(cs["qn"]):
            exp[c * MAXQ + j] = cs["exp"][j]
            eidx[c * MAXQ + j] = u32(cs["idx"][j])
            ewq[c * MAXQ + j] = cs["wq"][j]

    w = lambda n, s: (here / n).write_text(s)
    w("rs_mem.hex", "".join(f"{v:016x}\n" for v in beats))
    w("rs_tab.hex", "".join(f"{v:08x}\n" for v in tab))
    w("rs_cfg.hex", "".join(f"{v:08x}\n" for v in cfg))
    w("rs_exp.hex", "".join(f"{v:08x}\n" for v in exp))
    w("rs_idx.hex", "".join(f"{v:08x}\n" for v in eidx))
    w("rs_wq.hex", "".join(f"{v:08x}\n" for v in ewq))
    names = " \\\n".join(f'    names[{c}] = "{cs["name"]}";' for c, cs in enumerate(CASES))
    w("rs_dims.vh",
      f"`define NCASES {ncases}\n`define MAXQ {MAXQ}\n`define MAXTAB {MAXTAB}\n"
      f"`define CFGW {CFGW}\n`define MEM_BEATS {MEM_BEATS}\n"
      f"`define OUT_POISON 32'h{POISON_OUT:08x}\n"
      f"`define CASE_NAMES \\\n{names}\n")

    # ---- report ----
    if sh_notes:
        print(f"SH: requested {SH_REQ} was INFEASIBLE (A would overflow int32) for:")
        for n in sh_notes:
            print(n)
        print()
    print(f"{'case':16s} {'mode':>4s} {'SN':>4s} {'QN':>3s} {'SH':>3s} {'FSH':>4s} "
          f"{'A':>12s} {'B':>16s} {'zero':>5s} {'sat':>4s} {'run':>4s}  note")
    for cs in CASES:
        nz = sum(1 for k in cs["idx"] if k < 0)
        print(f"{cs['name']:16s} {cs['mode']:4d} {cs['sn']:4d} {cs['qn']:3d} {cs['sh']:3d} "
              f"{cs['fsh']:4d} {cs['a']:12d} {cs['b']:16d} {nz:5d} {cs['nsat']:4d} "
              f"{cs.get('maxrun', 0):4d}  {cs['note']}")
    for cs in CASES:
        if cs["mode"] == 0:
            continue
        if "coarse" in cs["name"]:
            assert cs["maxrun"] >= 2, f"{cs['name']} never needs back-to-back advances"
        if "fine" in cs["name"]:
            assert cs["maxrun"] <= 1, f"{cs['name']} is not single-advance"
    for cs in CASES[:6]:
        if cs.get("real"):
            # The >50% rule is a vacuity guard tuned to SYNTHETIC cases, where the query grid is
            # constructed to straddle the source. A real scene legitimately zero-fills more than
            # half: serialize_inputs pads the 8192-entry query grid past the 4319 real samples
            # with out-of-range filler (3873 entries here), so ~55% zero fill is the CORRECT
            # answer, not a degenerate case. build_real() asserts its own floor instead.
            continue
        # mandatory case (c): the query grid must fall off the source at BOTH ends
        assert cs["idx"][0] < 0 and cs["idx"][-1] < 0, f"{cs['name']} must zero fill at both ends"
        assert sum(1 for k in cs["idx"] if k >= 0) > cs["qn"] // 2, \
            f"{cs['name']} has too few in-range samples"
    print(f"\nwrote {MEM_BEATS} beats, {ncases} cases -> {here}")


if __name__ == "__main__":
    main()
