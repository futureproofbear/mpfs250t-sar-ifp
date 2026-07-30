#!/usr/bin/env python
"""Generate bit-exact reference vectors for tb_fft_feeder_gather.v (the FUSED azimuth-resample
GATHER in fft_feeder_v.v).

AUTHORITY -- the fused gather must be BIT-IDENTICAL to the shipping azimuth gather followed by the
2-D Hamming window, so an A/B against a gather-then-window reference validates it and the pipeline
CRC stays a valid gate. Two independent authorities are reproduced here with EXACT Python ints (no
numpy, no wrap):

  lerp  (hls_resample/resample.cpp):   lerp(a,b,w) = (int16)( a + (((int32)(b-a)*w) >> 15) ) , w Q15
       out = { lerp(hi(A),hi(B),w), lerp(lo(A),lo(B),w) } , A=src[idx], B=src[idx+1]
       idx < 0 or idx >= S-1  ->  zero fill (both halves 0)      (== resample.cpp j>=RS_IN-1)
  window(hls_window/window.cpp):       cw = (int16)((hamr*hamc)>>15) ; o = (int16)((sample*cw)>>15)

The fused datapath does gather THEN window per output sample i, with hamr = win_scale (per-row
scalar) and hamc = wtab[i] (the along-row taper, same table the window pass uses). Zero-fill happens
BEFORE the window, so a zero-filled sample stays 0 (window*0 == 0) -- reproduced below.

Emits (into this directory, all gitignored):
    ga_mem.hex   64-bit DDR beats: per case  [source row][idx[]][wq[]]  at 8-byte-aligned bases
    ga_tab.hex   32-bit taper words {hamc[2m+1],hamc[2m]}  (QN/2 words, CONSTANT across cases)
    ga_exp.hex   64-bit expected output beats, MAXOUT per case
    ga_cfg.hex   per-case config, CFGW words per case
    ga_dims.vh   `defines for the testbench

MUTATION CHECKS (state what breaks it; the TB catches each -- see tb header):
  * drop `signed` on the lerp difference (b-a): negative source samples get zero-extended, so
    the interpolation is wrong wherever a sample is negative -> cases 0/1/4 diverge.
  * off-by-one on the idx+1 read (B = src[idx] instead of src[idx+1]): every interior output wrong.
  * drop `signed` on the window multiply: negative hamr/hamc/sample mis-scaled -> cases diverge.
  * lose a stray R beat's err latch, or let it shift a bank: case 3 (stray) catches both.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
# The sinc reference is NOT re-derived here. gen_resample_vectors.py's table and gather are the
# authority the pass-1 sinc core is already validated against, edge rule included; writing a second
# implementation would only prove the two agree with each other.
from gen_resample_vectors import sinc_table_q15, gather_sinc      # noqa: E402

QN     = 32                 # outputs per case (even; tap words = QN/2 = 16)
MAXOUT = QN // 2            # output beats per case
CFGW   = 12                 # +1: sinc enable (GATHER_CTRL[2])
SINC_TAPS   = 32
SINC_PHASES = 256
NEG1_32 = 0xFFFFFFFF        # -1 as u32


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x >= 0x8000 else x


def lerp(a, b, w):          # a,b int16 ; w int16 Q15 (>=0). resample.cpp exact.
    return s16(a + (((b - a) * w) >> 15))


def hi(x):  return s16((x >> 16) & 0xFFFF)
def lo(x):  return s16(x & 0xFFFF)
def pk(i, q): return ((i & 0xFFFF) << 16) | (q & 0xFFFF)


def gather_sample(src, S, idx, w):
    """returns packed uint32 gathered sample, or 0 if idx out of range."""
    if idx < 0 or idx >= S - 1:
        return 0
    A, B = src[idx], src[idx + 1]
    return pk(lerp(hi(A), hi(B), w), lerp(lo(A), lo(B), w))


def window_sample(smp, hamr, hamc):
    cw = s16((hamr * hamc) >> 15)
    return pk(s16((hi(smp) * cw) >> 15), s16((lo(smp) * cw) >> 15))


def src_row(cid, S):
    """adversarial complex int16 source: sign mix + int16 extremes."""
    out = []
    for j in range(S):
        i = s16((j * 7919 + cid * 4523 + 13) * 37)
        q = s16((j * 6271 - cid * 2749 - 5) * 53)
        if j % 11 == 0:
            i, q = -32768, 32767
        if j % 13 == 7:
            i, q = 32767, -32768
        out.append(pk(i, q))
    return out


def q15(v):
    return max(-32768, min(32767, int(v)))


# ---- shared taper: hamc[i] (along-row, QN entries), adversarial like gen_window_vectors ----
hamc = [q15((0.8 - 0.05 * k) * 32768) for k in range(QN)]
hamc[0]  = 0                # zero-pad edge
hamc[-1] = 0
hamc[3]  = -32768           # most-negative Q15
hamc[4]  = 32767
# per-case hamr scalar (win_scale)
HAMR = [q15(0.90 * 32768), q15(-0.31 * 32768), q15(0.77 * 32768),
        q15(0.55 * 32768), q15(-0.62 * 32768), q15(0.40 * 32768)]


SINC_TAB = sinc_table_q15(SINC_PHASES, SINC_TAPS)

# ---------------------------------------------------------------------------- case builders
CASES = []


def add_case(name, gath_en, win_en, S, idx, wq, hamr, nbeats, inject, note, sinc=0):
    CASES.append(dict(name=name, gath_en=gath_en, win_en=win_en, S=S, idx=idx, wq=wq,
                      hamr=hamr, nbeats=nbeats, inject=inject, note=note, sinc=sinc))


def wq_varied(seed):
    w = [((i * 1013 + seed) & 0x7FFF) for i in range(QN)]
    w[1] = 0
    w[2] = 32767
    w[5] = 1
    return w


S_G = 36                    # source samples for the gather cases (idx valid in [0, S-2]=[0,34])

# (a) normal: monotonic idx fully in range, varied wq, window ON
add_case("normal", 1, 1, S_G, [i for i in range(QN)], wq_varied(7), HAMR[0], 0, 0,
         "monotonic idx, varied wq, window on")
# (b) zero-fill BOTH ends: idx = 2i-6 spans -6..56, off the row below 0 and above S-1
add_case("zerofill", 1, 1, S_G, [2 * i - 6 for i in range(QN)], wq_varied(31), HAMR[1], 0, 0,
         "idx off both ends -> zero fill")
# (c) gather DISABLED -> legacy window-only path must be bit-identical (FFT-2 / window path)
add_case("bypass", 0, 1, QN, [], [], HAMR[2], MAXOUT, 0,
         "gather off: window-only legacy path")
# (d) stray R beat during the SOURCE load: err_extra latches, row must NOT shift
add_case("stray", 1, 1, S_G, [i for i in range(QN)], wq_varied(7), HAMR[3], 0, 1,
         "stray R beat, err_extra, no shift")
# (e) descending idx + both edges (idx[0] high edge, idx[-1] low edge)
_desc = [34 - i for i in range(QN)]
_desc[0]  = S_G                    # == S -> >= S-1, high-edge zero fill
_desc[-1] = -2                     # low-edge zero fill
add_case("descend", 1, 1, S_G, _desc, wq_varied(101), HAMR[4], 0, 0,
         "descending idx + edge zero fill")
# bonus: gather with window OFF (proves win_en gating inside gather mode)
add_case("nowin", 1, 0, S_G, [i for i in range(QN)], wq_varied(7), HAMR[5], 0, 0,
         "gather on, window off")

# ---- 32-TAP SINC ARM (GATHER_CTRL[2]) -------------------------------------------------------
# S_S is deliberately large enough to have a real INTERIOR. A 32-tap window needs idx in
# [15, S-17], so at the old S_G=36 only idx 15..19 would qualify and the case would be almost all
# edge-fallback -- it would pass while barely touching the sinc datapath. At S=96 the interior is
# idx 15..79, so the interior case below is 32/32 genuine sinc outputs.
S_S = 96

# (g) sinc INTERIOR: every idx has a full 32-tap window, window ON
add_case("sinc_in", 1, 1, S_S, [15 + i for i in range(QN)], wq_varied(13), HAMR[0], 0, 0,
         "32-tap sinc, all interior", sinc=1)
# (h) sinc EDGES: straddles both ends of the sinc support so the lerp fallback is selected on
# exactly the queries the RTL's s_edge marks -- the two bounds are computed independently
# (Python: k < -lo or k > sn-(taps+lo); RTL: idx < 15 or idx > S-17) and must agree query for query.
_se = [i for i in range(QN)]                 # 0..31: idx 0..14 below the sinc support
_se[QN - 1] = S_S - 16                       # just past the high bound -> fallback
_se[QN - 2] = S_S - 17                       # exactly ON the high bound -> full sinc (the idx=4302 trap)
add_case("sinc_edge", 1, 1, S_S, _se, wq_varied(57), HAMR[1], 0, 0,
         "32-tap sinc across both support bounds", sinc=1)
# (i) sinc with window OFF, so the sinc value reaches the output unscaled
add_case("sinc_nowin", 1, 0, S_S, [20 + i for i in range(QN)], wq_varied(91), HAMR[5], 0, 0,
         "32-tap sinc, window off", sinc=1)


# ------------------------------------------------------------------------------ pack helpers
def pack_src(samps):
    n = (len(samps) + 1) // 2
    out = []
    for b in range(n):
        s0 = samps[2 * b]
        s1 = samps[2 * b + 1] if 2 * b + 1 < len(samps) else 0
        out.append(((s1 & 0xFFFFFFFF) << 32) | (s0 & 0xFFFFFFFF))
    return out


def pack_idx(idx):
    n = (len(idx) + 1) // 2
    out = []
    for k in range(n):
        a = idx[2 * k] & 0xFFFFFFFF
        b = (idx[2 * k + 1] & 0xFFFFFFFF) if 2 * k + 1 < len(idx) else 0
        out.append((b << 32) | a)
    return out


def pack_wq(wq):
    n = (len(wq) + 3) // 4
    out = []
    for k in range(n):
        v = [(wq[4 * k + j] & 0xFFFF) if 4 * k + j < len(wq) else 0 for j in range(4)]
        out.append(v[0] | (v[1] << 16) | (v[2] << 32) | (v[3] << 48))
    return out


def expected(cs):
    """MAXOUT output beats for the case."""
    if not cs["gath_en"]:
        # legacy window-only: window each source sample, taper indexed by output-sample position
        src = cs["src"]
        outs = []
        for i in range(QN):
            outs.append(window_sample(src[i], cs["hamr"], hamc[i]))
        return outs
    src, S, idx, wq = cs["src"], cs["S"], cs["idx"], cs["wq"]
    outs = []
    if cs.get("sinc"):
        # gather_sinc applies the SAME 2-tap fallback outside the 32-tap support that the RTL's
        # s_edge selects, so this is a like-for-like compare across the whole row, edges included.
        gs = gather_sinc(src, idx, wq, S, tab=SINC_TAB, taps=SINC_TAPS)
        for i in range(QN):
            outs.append(window_sample(gs[i], cs["hamr"], hamc[i]) if cs["win_en"] else gs[i])
        return outs
    for i in range(QN):
        g = gather_sample(src, S, idx[i], wq[i])
        outs.append(window_sample(g, cs["hamr"], hamc[i]) if cs["win_en"] else g)
    return outs


def main():
    here = pathlib.Path(__file__).resolve().parent
    mem = []

    def place(beats):
        base = len(mem) * 8
        mem.extend(beats)
        return base

    tab = [((hamc[2 * m + 1] & 0xFFFF) << 16) | (hamc[2 * m] & 0xFFFF) for m in range(QN // 2)]

    cfg, exp = [], []
    for cid, cs in enumerate(CASES):
        S = cs["S"]
        cs["src"] = src_row(cid, S)
        # source row
        src_base = place(pack_src(cs["src"]))
        # idx / wq (gather cases only; bypass leaves them unplaced)
        if cs["gath_en"]:
            idx_base = place(pack_idx(cs["idx"]))
            wq_base  = place(pack_wq(cs["wq"]))
        else:
            idx_base = wq_base = 0
        outs = expected(cs)
        assert len(outs) == QN
        beats_out = [((outs[2 * b + 1] & 0xFFFFFFFF) << 32) | (outs[2 * b] & 0xFFFFFFFF)
                     for b in range(MAXOUT)]
        exp.extend(beats_out)
        err = 0x1 if cs["inject"] else 0x0            # bit0 = err_extra expected
        cfg += [cs["gath_en"], cs["win_en"], cs["hamr"] & 0xFFFF, src_base, idx_base, wq_base,
                S, QN, cs["nbeats"], cs["inject"], err, cs.get("sinc", 0)]

    w = lambda n, s: (here / n).write_text(s)
    w("ga_mem.hex", "".join(f"{v & ((1 << 64) - 1):016x}\n" for v in mem))
    w("ga_tab.hex", "".join(f"{v & 0xFFFFFFFF:08x}\n" for v in tab))
    w("ga_exp.hex", "".join(f"{v & ((1 << 64) - 1):016x}\n" for v in exp))
    w("ga_cfg.hex", "".join(f"{v & 0xFFFFFFFF:08x}\n" for v in cfg))
    # sinc coefficient table, phase-major, one Q15 tap per line -- the order sar_sinc32_gather's
    # ct_we write pointer expects.
    w("ga_sinc.hex", "".join(f"{t & 0xFFFF:04x}\n"
                             for ph in SINC_TAB for t in ph))
    names = " \\\n".join(f'    names[{c}] = "{cs["name"]}";' for c, cs in enumerate(CASES))
    w("ga_dims.vh",
      f"`define NCASES {len(CASES)}\n`define QN {QN}\n`define MAXOUT {MAXOUT}\n"
      f"`define TAB_WORDS {QN // 2}\n`define CFGW {CFGW}\n`define MEM_BEATS {len(mem)}\n"
      f"`define SINC_TAPS {SINC_TAPS}\n`define SINC_PHASES {SINC_PHASES}\n"
      f"`define SINC_WORDS {SINC_TAPS * SINC_PHASES}\n"
      f"`define CASE_NAMES \\\n{names}\n")

    print(f"{'case':10s} {'gath':>4s} {'win':>3s} {'S':>3s} {'QN':>3s} {'src':>5s} {'idx':>5s} "
          f"{'wq':>5s} {'zero':>4s} {'inj':>3s}  note")
    for cid, cs in enumerate(CASES):
        nz = sum(1 for k in cs["idx"] if k < 0 or k >= cs["S"] - 1) if cs["gath_en"] else 0
        b = cid  # placeholder
        print(f"{cs['name']:10s} {cs['gath_en']:4d} {cs['win_en']:3d} {cs['S']:3d} {QN:3d} "
              f"{'-':>5s} {'-':>5s} {'-':>5s} {nz:4d} {cs['inject']:3d}  {cs['note']}")
    # sanity: mandatory zero-fill case really zero-fills at BOTH ends
    zf = CASES[1]
    assert zf["idx"][0] < 0 and zf["idx"][-1] >= zf["S"] - 1, "zerofill case must miss both ends"
    print(f"\nwrote {len(mem)} beats, {len(CASES)} cases -> {here}")


if __name__ == "__main__":
    main()
