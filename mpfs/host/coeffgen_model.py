#!/usr/bin/env python3
"""coeffgen_model.py -- bit-exact INTEGER model of the sar_coeffgen fabric datapath.

This is the single authority shared by the board-free gate (check_coeffgen_fixed.py) and the
RTL vector generator (mpfs/fpga/tb/gen_coeffgen_vectors.py). Nothing here uses Python floats
for arithmetic: every operation is a pure integer manipulation of IEEE-754 binary32 BIT
PATTERNS, in exactly the order sar_coeffs_pass2_range() performs them.

WHY THIS SHAPE (the fixed-point decision, stated once, here)
-----------------------------------------------------------
The C reference is float32 and its ROUNDING is load-bearing, not incidental:

  * the bracket test is `SRC(k+1) <= q` where SRC(k+1) = fl32(kr * tan_s[k+1]). Rounding that
    product moves the bracket edge by ~0.5 ulp; a query landing inside that window takes the
    OTHER bracket, i.e. idx differs by 1 and wq flips between ~0 and ~32767.
  * the weight is frac = fl32(fl32(q - x0) * inv) with x0 = fl32(kr*tan_s[k]). A 0.5 ulp error
    in x0 is ~1.7e-8 absolute against a bracket span of ~8.2e-4, i.e. ~0.67 Q15 LSB -- so a
    "close enough" x0 moves wq by +-1 on a large fraction of outputs.

So a fixed-point REFORMULATION (work in tan_s space via u = q/kr, or a common-Q rescale) cannot
be bit-identical: it is a different rounding sequence. Measured divergence for that variant is
reported by check_coeffgen_fixed.py.

What IS both cheap and bit-exact is to keep the float32 VALUES and do them with integer hardware:

  * every multiply here has NORMALIZED operands, so the product of two 24-bit significands lands
    in [2^46, 2^48) -- normalization is a 1-bit shift decided by one bit. No leading-zero count,
    no barrel shifter. A binary32 multiplier collapses to (24x24 multiply + 1-bit shift + RNE).
  * the only DIVIDE in the whole line, 1.0f/kr, is already computed by the CPU today. It stays on
    the CPU and arrives as a register write, so the fabric needs no divider and no reciprocal
    table -- and it uses the SAME float expression the C uses, which is what keeps inv bit-exact.
  * inv_tan[] = 1/(tan_s[k+1]-tan_s[k]) is line-invariant and is already built once by
    sar_coeffs_init(); it is pushed into fabric LSRAM as a table, again preserving the exact
    float32 expression (recomputing it in fabric would round differently -- the same trap
    documented in sar_coeffs_pass2_range()).

Only two operations need a genuine aligner/normalizer: the subtract fl32(q - x0) and the two
small adds in emit(). One shared 3-stage add/sub design covers all of them.

No NaN/Inf/denormal path is implemented. The model FLAGS any such operand (`fmt_err`) and the
RTL latches the same sticky bit, rather than silently producing a wrong answer.
"""

MASK32 = 0xFFFFFFFF


class Flags:
    """Sticky format-violation flags -- mirrors the RTL's err_fmt bit."""

    def __init__(self):
        self.fmt = 0        # NaN / Inf / denormal operand seen
        self.ovf = 0        # exponent overflow/underflow in a multiply or add


def _split(a):
    return (a >> 31) & 1, (a >> 23) & 0xFF, a & 0x7FFFFF


def _chk(a, fl):
    e = (a >> 23) & 0xFF
    m = a & 0x7FFFFF
    if e == 0xFF:
        fl.fmt = 1
    elif e == 0 and m != 0:
        fl.fmt = 1


def fmul(a, b, fl):
    """IEEE-754 binary32 multiply, round-to-nearest-even. Integer only.

    RTL: sar_fp32_mul (2 stages). Operands normalized => product in [2^46,2^48) => the whole
    normalization is `if (P[47]) shift right 1`. That is the reason this is cheap in fabric.
    """
    _chk(a, fl)
    _chk(b, fl)
    sa, ea, ma = _split(a)
    sb, eb, mb = _split(b)
    s = sa ^ sb
    if ea == 0 or eb == 0:                     # zero (denormals flushed, and flagged above)
        return s << 31
    P = ((1 << 23) | ma) * ((1 << 23) | mb)    # 48 bits
    if (P >> 47) & 1:
        e = ea + eb - 127 + 1
        mant = (P >> 24) & 0xFFFFFF
        g = (P >> 23) & 1
        st = 1 if (P & ((1 << 23) - 1)) else 0
    else:
        e = ea + eb - 127
        mant = (P >> 23) & 0xFFFFFF
        g = (P >> 22) & 1
        st = 1 if (P & ((1 << 22) - 1)) else 0
    if g and (st or (mant & 1)):
        mant += 1
        if mant >> 24:
            mant >>= 1
            e += 1
    if e <= 0:
        fl.ovf = 1
        return s << 31
    if e >= 0xFF:
        fl.ovf = 1
        return (s << 31) | (0xFE << 23) | 0x7FFFFF
    return (s << 31) | ((e & 0xFF) << 23) | (mant & 0x7FFFFF)


def fadd(a, b, fl):
    """IEEE-754 binary32 add, round-to-nearest-even. Integer only.

    RTL: sar_fp32_add (3 stages: swap+align / add+lzc / normalize+round).
    """
    _chk(a, fl)
    _chk(b, fl)
    ea, eb = (a >> 23) & 0xFF, (b >> 23) & 0xFF
    if ea == 0 and eb == 0:
        # +-0 + +-0 : IEEE gives -0 only when both are -0 (round-to-nearest)
        return a if (a == b) else 0
    if ea == 0:
        return b
    if eb == 0:
        return a
    if (a & 0x7FFFFFFF) < (b & 0x7FFFFFFF):
        a, b = b, a
    sa, ea, ma = _split(a)
    sb, eb, mb = _split(b)
    A = ((1 << 23) | ma) << 3                  # 24 bits of significand + G,R,S
    B = ((1 << 23) | mb) << 3
    d = ea - eb
    if d > 26:
        st = 1 if B else 0
        B = 0
    else:
        st = 1 if (B & ((1 << d) - 1)) else 0
        B >>= d
    B |= st
    if sa == sb:
        R = A + B
    else:
        R = A - B
    s = sa
    if R == 0:
        return 0
    e = ea
    if R >> 27:                                # carry out of the significand
        st = R & 1
        R = (R >> 1) | st
        e += 1
    else:
        while not ((R >> 26) & 1):
            R <<= 1
            e -= 1
            if e <= 0:
                fl.ovf = 1
                return s << 31
    mant = R >> 3
    g = (R >> 2) & 1
    st = 1 if (R & 3) else 0
    if g and (st or (mant & 1)):
        mant += 1
        if mant >> 24:
            mant >>= 1
            e += 1
    if e >= 0xFF:
        fl.ovf = 1
        return (s << 31) | (0xFE << 23) | 0x7FFFFF
    return (s << 31) | ((e & 0xFF) << 23) | (mant & 0x7FFFFF)


def fsub(a, b, fl):
    return fadd(a, b ^ 0x80000000, fl)


def fneg(a):
    return a ^ 0x80000000


def fscale15(a, fl):
    """a * 32768.0f. Exact for every operand in range: multiplying by a power of two only
    changes the exponent, so RTL does e+15 with no multiplier and no rounding."""
    _chk(a, fl)
    e = (a >> 23) & 0xFF
    if e == 0:
        return a & 0x80000000
    e += 15
    if e >= 0xFF:
        fl.ovf = 1
        return (a & 0x80000000) | (0xFE << 23) | 0x7FFFFF
    return (a & 0x80000000) | (e << 23) | (a & 0x7FFFFF)


def f2i_trunc(a):
    """C's (int32_t)float -- truncate toward zero. Inputs here are bounded well under 2^31."""
    s, e, m = _split(a)
    if e < 127:
        return 0
    sh = e - 127
    sig = (1 << 23) | m
    v = (sig << (sh - 23)) if sh > 23 else (sig >> (23 - sh))
    return -v if s else v


def flt(a, b):
    """float32 `a < b`. Sign-magnitude -> monotone unsigned key. Both zeros map to the same key
    so -0.0 < +0.0 is FALSE, matching C."""
    ka = 0 if (a & 0x7FFFFFFF) == 0 else a
    kb = 0 if (b & 0x7FFFFFFF) == 0 else b
    ka = (~ka & MASK32) if (ka >> 31) else (ka | 0x80000000)
    kb = (~kb & MASK32) if (kb >> 31) else (kb | 0x80000000)
    return ka < kb


def fle(a, b):
    return not flt(b, a)


def emit(k, w, fl):
    """Mirror of emit() in sar_resample_coeffs.c:
         int32_t wi = (int32_t)(w * 32768.0f + 0.5f); clamp [0,32767]"""
    wi = f2i_trunc(fadd(fscale15(w, fl), 0x3F000000, fl))     # 0x3F000000 == 0.5f
    if wi < 0:
        wi = 0
    if wi > 32767:
        wi = 32767
    return k, wi


ONE_F = 0x3F800000


def coeffgen_row(KC, Mp, TAN, ITAN, S, kr, fl=None):
    """Bit-exact integer model of one sar_coeffgen row == sar_coeffs_pass2_range(g,j,...,0,Mp).

    KC, TAN, ITAN, kr are float32 BIT PATTERNS (ints). Returns (idx[], wq[], flags).
    `rinv` is supplied the way the RTL gets it: computed by the CPU as fl32(1.0f/kr) -- modelled
    here by the caller through `rinv_of` so the model never uses a Python float.
    """
    if fl is None:
        fl = Flags()
    idx = [-1] * Mp
    wq = [0] * Mp
    if S < 2 or (kr & 0x7FFFFFFF) == 0:
        return idx, wq, fl
    rinv = rinv_of(kr)                       # the CPU's `const float r = 1.0f / kr;`
    asc = (kr >> 31) == 0                    # kr >= 0  (kr == 0 handled above)
    rr = rinv if asc else fneg(rinv)

    def SRC(kk):
        return fmul(kr, TAN[kk if asc else (S - 1 - kk)], fl)

    def INVSPAN(kk):
        return fmul(ITAN[kk if asc else (S - 2 - kk)], rr, fl)

    xlo, xhi = SRC(0), SRC(S - 1)
    k = 0
    x0 = SRC(0)
    inv = INVSPAN(0)
    for qi in range(Mp):
        q = KC[qi]
        if flt(q, xlo) or not flt(q, xhi):
            continue
        while k + 2 < S and fle(SRC(k + 1), q):
            k += 1
            x0 = SRC(k)
            inv = INVSPAN(k)
        frac = fmul(fsub(q, x0, fl), inv, fl)
        if asc:
            idx[qi], wq[qi] = emit(k, frac, fl)
        else:
            idx[qi], wq[qi] = emit(S - 2 - k, fsub(ONE_F, frac, fl), fl)
    return idx, wq, fl


# ---------------------------------------------------------------------------------------------
# The two float32 values the CPU still produces and writes as registers / tables. numpy is used
# ONLY here (to reproduce the CPU's own float32 rounding of a divide), never in the datapath.
def rinv_of(kr_bits):
    import numpy as np
    kr = np.frombuffer(int(kr_bits).to_bytes(4, "little"), np.float32)[0]
    r = np.float32(np.float32(1.0) / kr)
    return int.from_bytes(r.tobytes(), "little")


def itan_of(tan_bits):
    """sar_coeffs_init(): inv_tan[k] = 1.0f/(tan_s[k+1]-tan_s[k]), float32, 0 if the span is 0."""
    import numpy as np
    t = np.array([int(b) for b in tan_bits], np.uint32).view(np.float32)
    out = []
    for k in range(len(t) - 1):
        d = np.float32(t[k + 1] - t[k])
        v = np.float32(np.float32(1.0) / d) if d != np.float32(0.0) else np.float32(0.0)
        out.append(int.from_bytes(v.tobytes(), "little"))
    return out
