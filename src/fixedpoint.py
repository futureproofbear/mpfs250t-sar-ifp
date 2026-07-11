"""Fixed-point / block-floating-point emulation for the SAR focuser.

Emulates, in NumPy, what the PolarFire fabric would do: quantize the signal and
twiddles to N-bit fixed point and run a block-floating-point (BFP) FFT that
rescales per stage to hold dynamic range in a fixed word width. Used to (a) size
the datapath bit widths, (b) measure the per-stage scale shifting BFP needs, and
(c) quantify the information loss vs the float reference.

Run as a script for the quantization study:
    python src/fixedpoint.py            # uses the scene in config.yaml
"""
import sys
import math
from pathlib import Path

import numpy as np

# ----------------------------- fixed-point core ---------------------------- #
def fit_scale(arr, nbits):
    """Smallest power-of-2 LSB so |arr| fits in signed nbits. Returns (lsb, exp)."""
    M = max(float(np.abs(arr.real).max()), float(np.abs(arr.imag).max()))
    if M == 0.0:
        return 1.0, 0
    full = 2 ** (nbits - 1) - 1
    exp = math.ceil(math.log2(M / full))
    return 2.0 ** exp, exp


def quant(arr, lsb, nbits, mode="trunc"):
    """Quantize complex arr to a signed nbits grid with step `lsb` (saturating).

    mode="trunc": floor toward -inf, i.e. two's-complement LSB truncation as the
    FPGA datapath does (arithmetic shift right) -- used for ALL on-fabric
    quantization here, including the twiddle ROM, to emulate the PolarFire SoC
    datapath faithfully. mode="round" (round to nearest) is retained for callers
    that want the synthesis-time rounded ROM instead."""
    full = 2 ** (nbits - 1) - 1
    step = np.floor if mode == "trunc" else np.round
    re = np.clip(step(arr.real / lsb), -full - 1, full)
    im = np.clip(step(arr.imag / lsb), -full - 1, full)
    return (re + 1j * im) * lsb


def _bitrev_perm(n):
    bits = int(round(math.log2(n)))
    return np.array([int(format(i, f"0{bits}b")[::-1], 2) for i in range(n)])


def fft1d_bfp(x, nbits, nbits_tw, perm):
    """Radix-2 DIT FFT along the last axis with block-floating-point requantize
    after every stage. Vectorized across all other axes (one 'line' per row).
    Returns (transformed, per_stage_exponents)."""
    n = x.shape[-1]
    stages = int(round(math.log2(n)))
    x = x[..., perm]
    lsb, e = fit_scale(x, nbits)
    x = quant(x, lsb, nbits)
    exps = [e]
    lsb_tw = 2.0 ** -(nbits_tw - 1)                 # twiddles in ~[-1, 1)
    for s in range(1, stages + 1):
        m = 1 << s; mh = m >> 1
        # floor (truncate) the twiddles too: emulate the FPGA datapath, where
        # the PolarFire SoC fabric truncates rather than rounds.
        w = quant(np.exp(-2j * np.pi * np.arange(mh) / m), lsb_tw, nbits_tw, mode="trunc").astype(x.dtype, copy=False)
        xr = x.reshape(*x.shape[:-1], n // m, m)
        a = xr[..., :mh]; b = xr[..., mh:]
        t = w * b                                    # complex multiply (grows)
        x = np.concatenate([a + t, a - t], axis=-1).reshape(*x.shape[:-1], n)
        lsb, e = fit_scale(x, nbits)                 # BFP: rescale to word width
        x = quant(x, lsb, nbits)
        exps.append(e)
    return x, exps


def fft2_bfp(x, nbits, nbits_tw=None):
    """2-D BFP FFT (range axis then azimuth axis). Returns (img, (exps_r, exps_a))."""
    nbits_tw = nbits_tw or nbits
    pr = _bitrev_perm(x.shape[-1])
    y, er = fft1d_bfp(x, nbits, nbits_tw, pr)
    pa = _bitrev_perm(x.shape[-2])
    y, ea = fft1d_bfp(np.swapaxes(y, -1, -2), nbits, nbits_tw, pa)
    return np.swapaxes(y, -1, -2), (er, ea)


# ------ UNCONDITIONAL-scaling FFT (emulates the SmartHLS fft_in_place actually --
# on the board): >>1 (arithmetic shift, truncate toward -inf) on BOTH butterfly
# operands EVERY stage => fixed 1/N per FFT, NO block exponent. This is what
# hls_fft.hpp does (x_r = Stage[i] >> 1; x_r_lower = Stage[i_lower] >> 1). Unlike
# fft1d_bfp it never rescales UP, so small values truncate toward zero across the
# stages -- the mechanism that underflows a distributed scene to all-zero uint16.
def _trunc_int(a, nbits):
    full = 2 ** (nbits - 1) - 1
    re = np.clip(np.floor(a.real), -full - 1, full)
    im = np.clip(np.floor(a.imag), -full - 1, full)
    return re + 1j * im


def _shr1(a):                                   # arithmetic >>1 on re & im (floor/2)
    return np.floor(a.real / 2.0) + 1j * np.floor(a.imag / 2.0)


def fft1d_uncond(x, nbits, nbits_tw, perm):
    """Radix-2 DIT FFT, unconditional >>1 per stage, signed-nbits truncation. No BFP."""
    n = x.shape[-1]
    stages = int(round(math.log2(n)))
    x = _trunc_int(x[..., perm], nbits)
    lsb_tw = 2.0 ** -(nbits_tw - 1)
    for s in range(1, stages + 1):
        m = 1 << s; mh = m >> 1
        w = quant(np.exp(-2j * np.pi * np.arange(mh) / m), lsb_tw, nbits_tw, mode="trunc").astype(x.dtype, copy=False)
        xr = x.reshape(*x.shape[:-1], n // m, m)
        a = _shr1(xr[..., :mh])                 # >>1 upper
        b = _shr1(xr[..., mh:])                 # >>1 lower
        t = _trunc_int(w * b, nbits)            # twiddle mult, truncate
        x = np.concatenate([a + t, a - t], axis=-1).reshape(*x.shape[:-1], n)
        x = _trunc_int(x, nbits)                # store back to int (NO rescale up)
    return x


def fft2_uncond(x, nbits, nbits_tw=None):
    """2-D unconditional-scaling FFT (matches the board's HLS fft_kernel)."""
    nbits_tw = nbits_tw or nbits
    y = fft1d_uncond(x, nbits, nbits_tw, _bitrev_perm(x.shape[-1]))
    y = fft1d_uncond(np.swapaxes(y, -1, -2), nbits, nbits_tw, _bitrev_perm(x.shape[-2]))
    return np.swapaxes(y, -1, -2)


# ---- HARDWARE BFP prototype (what a BFP HLS fft_kernel would do) ---------------
# int16 datapath, radix-2 DIT. Per stage: butterfly, then a CONDITIONAL down-shift
# by just enough to keep the whole block inside signed-nbits, tracking ONE block
# exponent for the pass (down-shift only, as real hardware does). Unlike the
# unconditional kernel it shifts only when a stage actually overflows -> for real
# data it shifts FEWER than log2(N) times, so the mantissa stays full-scale and
# dynamic range is preserved. The block exponent per pass = the BFP_SHIFT that
# detect.cpp expects the host to apply for the true dB scale.
def _shr(a, sh):                                # arithmetic >>sh on re & im (truncate)
    d = float(1 << sh)
    return np.floor(a.real / d) + 1j * np.floor(a.imag / d)


def fft1d_bfp_hw(x, nbits, nbits_tw, perm):
    """1-D DIT FFT, global block-floating-point (one block exponent). Returns
    (mantissa int-grid, block_exp)."""
    n = x.shape[-1]
    stages = int(round(math.log2(n)))
    full = 2 ** (nbits - 1) - 1
    x = _trunc_int(x[..., perm], nbits)
    be = 0
    lsb_tw = 2.0 ** -(nbits_tw - 1)
    for s in range(1, stages + 1):
        m = 1 << s; mh = m >> 1
        w = quant(np.exp(-2j * np.pi * np.arange(mh) / m), lsb_tw, nbits_tw, mode="trunc").astype(x.dtype, copy=False)
        xr = x.reshape(*x.shape[:-1], n // m, m)
        a = xr[..., :mh]; b = xr[..., mh:]
        t = _trunc_int(w * b, nbits)            # twiddle mult (|w|<=1), truncate to int
        x = np.concatenate([a + t, a - t], axis=-1).reshape(*x.shape[:-1], n)
        mx = max(float(np.abs(x.real).max()), float(np.abs(x.imag).max()))
        if mx > full:                            # conditional down-shift on overflow
            sh = int(math.ceil(math.log2((mx + 1.0) / full)))
            x = _shr(x, sh); be += sh
        x = _trunc_int(x, nbits)
    return x, be


def fft2_bfp_hw(x, nbits, nbits_tw=None):
    """2-D hardware-BFP FFT. Returns (mantissa img, (block_exp_range, block_exp_az))."""
    nbits_tw = nbits_tw or nbits
    y, er = fft1d_bfp_hw(x, nbits, nbits_tw, _bitrev_perm(x.shape[-1]))
    y, ea = fft1d_bfp_hw(np.swapaxes(y, -1, -2), nbits, nbits_tw, _bitrev_perm(x.shape[-2]))
    return np.swapaxes(y, -1, -2), (er, ea)


def fft1d_fullprec(x, nbits_tw, perm):
    """Radix-2 DIT FFT in a WIDE integer accumulator with NO scaling (Q15 twiddles,
    truncated). Values grow up to N x -- the caller normalizes afterward. This is
    what each row's FFT does in the 2-pass global-BFP kernel (int32 datapath)."""
    n = x.shape[-1]
    stages = int(round(math.log2(n)))
    x = _trunc_int(x[..., perm], 32)
    lsb_tw = 2.0 ** -(nbits_tw - 1)
    for s in range(1, stages + 1):
        m = 1 << s; mh = m >> 1
        w = quant(np.exp(-2j * np.pi * np.arange(mh) / m), lsb_tw, nbits_tw, mode="trunc").astype(x.dtype, copy=False)
        xr = x.reshape(*x.shape[:-1], n // m, m)
        a = xr[..., :mh]; b = xr[..., mh:]
        t = _trunc_int(w * b, 32)               # twiddle mult, truncate (keep wide)
        x = np.concatenate([a + t, a - t], axis=-1).reshape(*x.shape[:-1], n)
    return x


def _global_norm(y, nbits):
    """Shift the whole block down to fit signed nbits; return (int16 mantissa, exp)."""
    full = 2 ** (nbits - 1) - 1
    mx = max(float(np.abs(y.real).max()), float(np.abs(y.imag).max()))
    exp = max(0, int(math.ceil(math.log2((mx + 1.0) / full)))) if mx > full else 0
    return _trunc_int(_shr(y, exp) if exp else y, nbits), exp


def fft2_gbfp_2pass(x, nbits=16, nbits_tw=None):
    """2-PASS GLOBAL BFP -- the exact algorithm the HLS kernel implements: each row
    FFT'd full-precision (int32), then the WHOLE pass normalized to int16 by one
    block exponent. Range pass then azimuth pass. Returns (int16 mantissa img,
    (exp_r, exp_a)). Structurally correct across the frame (single scale per pass)."""
    nbits_tw = nbits_tw or nbits
    yr = fft1d_fullprec(x, nbits_tw, _bitrev_perm(x.shape[-1]))
    yr, er = _global_norm(yr, nbits)                         # range pass normalize
    ya = fft1d_fullprec(np.swapaxes(yr, -1, -2), nbits_tw, _bitrev_perm(x.shape[-2]))
    ya, ea = _global_norm(ya, nbits)                         # azimuth pass normalize
    return np.swapaxes(ya, -1, -2), (er, ea)


# ===========================================================================
# EXACT MIRROR of the on-silicon PolarFire kernel (single-pass + L1 pre-scan BFP).
# Mirrors mpfs/fpga/hls_fft/fft_kernel.cpp + hls::dsp::fft_in_place_bfp:
#   PASS 0 (L1 pre-scan): gmax = max over rows of sum(|re|+|im|); the block exponent
#     is the number of >>1 shifts that bring gmax <= 32767. ONE shared exponent per
#     pass (every row scaled identically -> consistent 2-D image).
#   PASS 1: full-precision (wide int32 datapath) FFT per row, NO per-stage scaling;
#     the output is arithmetic-shifted right by the block exponent and SATURATED to
#     signed int16. Cross-checked bit-for-bit trend vs `shls sw` (corr 0.999997).
# ===========================================================================
def bfp_l1_exp(x):
    """Block exponent from the L1 pre-scan of the input -- exactly fft_kernel.cpp
    PASS 0: gmax = max_row( sum |re| + |im| ), then count >>1 shifts until <= 32767."""
    xr = np.round(x)
    l1 = (np.abs(xr.real) + np.abs(xr.imag)).sum(axis=-1)     # per-row L1 norm
    gmax = int(l1.max())
    exp = 0
    while gmax > 32767:
        gmax >>= 1
        exp += 1
    return exp


def _sat_shift16(y, exp):
    """Arithmetic >>exp then saturate to signed int16 -- mirrors the fft_in_place_bfp
    output stage: int(Stage) >> out_shift, clamped to [-32768, 32767]."""
    d = float(1 << exp)
    re = np.clip(np.floor(y.real / d), -32768, 32767)
    im = np.clip(np.floor(y.imag / d), -32768, 32767)
    return re + 1j * im


def fft_pass_l1bfp(x, nbits_tw=16):
    """One FFT pass exactly as the PolarFire kernel: L1 pre-scan -> full-precision
    per-row FFT -> shared-exponent output shift + int16 saturation.
    Returns (int16 mantissa, block_exp)."""
    exp = bfp_l1_exp(x)
    y = fft1d_fullprec(x, nbits_tw, _bitrev_perm(x.shape[-1]))
    return _sat_shift16(y, exp), exp


def fft2_l1bfp(x, nbits_tw=16):
    """2-D image formation exactly as the board datapath: range-FFT (per row) ->
    corner-turn (plain transpose, NO transpose-back) -> azimuth-FFT (per row).
    Returns (int16 mantissa in BOARD orientation == fft2(x).T, (exp_range, exp_az)).
    The host applies one transpose (+ no fftshift) to match make_small_golden's
    np.fft.fft2 golden. Total block shift = exp_range + exp_az = the BFP_SHIFT that
    detect.cpp hands the host for the absolute dB scale."""
    yr, er = fft_pass_l1bfp(x, nbits_tw)                       # range pass
    yt = np.swapaxes(yr, -1, -2)                              # corner-turn (transpose)
    ya, ea = fft_pass_l1bfp(yt, nbits_tw)                     # azimuth pass (no back-transpose)
    return ya, (er, ea)                                       # board orientation


def fft1d_bfp_hw_perrow(x, nbits, nbits_tw, perm):
    """PER-ROW block-floating-point 1-D FFT: each row (line) keeps its OWN block
    exponent (the natural mode for a kernel that FFTs one row at a time). Returns
    (mantissa, exp_per_row array). Reconstructed value = mantissa * 2**exp[row]."""
    n = x.shape[-1]
    stages = int(round(math.log2(n)))
    full = 2 ** (nbits - 1) - 1
    x = _trunc_int(x[..., perm], nbits)
    be = np.zeros(x.shape[:-1], dtype=np.int32)      # one exponent per row
    lsb_tw = 2.0 ** -(nbits_tw - 1)
    for s in range(1, stages + 1):
        m = 1 << s; mh = m >> 1
        w = quant(np.exp(-2j * np.pi * np.arange(mh) / m), lsb_tw, nbits_tw, mode="trunc").astype(x.dtype, copy=False)
        xr = x.reshape(*x.shape[:-1], n // m, m)
        a = xr[..., :mh]; b = xr[..., mh:]
        t = _trunc_int(w * b, nbits)
        x = np.concatenate([a + t, a - t], axis=-1).reshape(*x.shape[:-1], n)
        mx = np.maximum(np.abs(x.real).max(axis=-1), np.abs(x.imag).max(axis=-1))  # per row
        sh = np.maximum(0, np.ceil(np.log2((mx + 1.0) / full))).astype(np.int32)   # per-row shift
        d = (2.0 ** sh)[..., None]
        x = np.floor(x.real / d) + 1j * np.floor(x.imag / d)
        be += sh
        x = _trunc_int(x, nbits)
    return x, be


# ------------------------------- assessment -------------------------------- #
def dynamic_range_db(mag):
    """Usable dynamic range: brightest target over the speckle/background floor."""
    hi = np.percentile(mag, 99.99)
    lo = np.percentile(mag[mag > 0], 5) if np.any(mag > 0) else 1e-12
    return 20 * np.log10(hi / (lo + 1e-12))


def compare(ref_mag, test_mag):
    """Information-loss metrics between float ref and fixed-point test images."""
    r = ref_mag / (ref_mag.max() + 1e-30)
    t = test_mag / (test_mag.max() + 1e-30)
    err = t - r
    rms_ref = np.sqrt(np.mean(r ** 2))
    rms_err = np.sqrt(np.mean(err ** 2)) + 1e-30
    snr = 20 * np.log10(rms_ref / rms_err)
    return {
        "nrmse": rms_err / rms_ref,
        "snr_db": snr,
        "enob": (snr - 1.76) / 6.02,            # effective number of bits
        "corr": float(np.corrcoef(r.ravel(), t.ravel())[0, 1]),
        "dr_ref_db": dynamic_range_db(ref_mag),
        "dr_test_db": dynamic_range_db(test_mag),
    }


# ----------------------- fixed-point PFA focuser --------------------------- #
def _to_pow2(n):
    return 1 << int(math.ceil(math.log2(n)))


def focus_fixed(sig_win, nbits, nbits_tw=None):
    """Fixed-point focus of an already-resampled+windowed signal: quantize input,
    zero-pad to power-of-2 (as the fabric does), BFP 2-D FFT, detect. Returns
    (detected_magnitude, bfp_exponents)."""
    m2, n2 = _to_pow2(sig_win.shape[0]), _to_pow2(sig_win.shape[1])
    pad = np.zeros((m2, n2), dtype=np.complex64)   # complex64 to halve RAM at full res
    pad[:sig_win.shape[0], :sig_win.shape[1]] = sig_win
    lsb, _ = fit_scale(pad, nbits)
    pad = quant(pad, lsb, nbits)                    # input quantization
    img, exps = fft2_bfp(np.fft.ifftshift(pad), nbits, nbits_tw)
    img = np.fft.fftshift(img)
    return np.abs(img).astype(np.float32), exps


# ------------------------- fixed-point resample ---------------------------- #
# The fabric applies the polar->Cartesian keystone resample BEFORE the FFT, with
# linear interpolation whose weights are quantized to a fixed fractional width
# and whose products land in the 18x18 MACC. fixedpoint.py historically quantized
# only the FFT (the documented "emulator gap"); resample_fixed() closes it so the
# golden oracle can validate the WHOLE offloaded datapath (resample -> window ->
# FFT -> detect). It mirrors form_image_pfa.resample_kspace step for step; the
# only difference is the quantized arithmetic.
def _interp_fixed(query, xp, fp, nbits_w):
    """Linear interpolation with a truncated (fabric-style) fractional weight.

    query : (Q,) target coordinates (uniform grid)
    xp    : (P,) source coordinates, strictly ascending
    fp    : (P,) complex source values
    Out-of-range queries map to 0 (matching np.interp left=0, right=0 here).
    """
    P = xp.shape[0]
    i1 = np.clip(np.searchsorted(xp, query), 1, P - 1)
    i0 = i1 - 1
    span = xp[i1] - xp[i0]
    span[span == 0] = 1.0
    w = (query - xp[i0]) / span                     # ideal weight in [0, 1)
    step = 2.0 ** -(nbits_w - 1)                     # fixed fractional LSB
    wq = np.floor(w / step) * step                   # truncate, as the fabric does
    out = fp[i0] * (1.0 - wq) + fp[i1] * wq
    out[(query < xp[0]) | (query > xp[-1])] = 0
    return out.astype(np.complex64, copy=False)


def resample_fixed(sig, freq, ax, ay, nbits=16, nbits_w=16, window=True):
    """Fixed-point polar->Cartesian keystone resample + window.

    Mirrors form_image_pfa.resample_kspace but (a) quantizes the input signal and
    the per-pass intermediate to nbits BFP and (b) truncates the interpolation
    weights to nbits_w fractional bits. Returns (g2, geo) like the float version,
    so focus_fixed(g2) completes the full fixed-point datapath. C is light-speed.
    """
    C = 299_792_458.0
    m, n = sig.shape
    kmag = 2.0 * freq / C
    dx, dy = ax.mean(), ay.mean()
    dn = math.hypot(dx, dy); dx, dy = dx / dn, dy / dn
    cx, cy = -dy, dx
    pr = ax * dx + ay * dy
    pc = ax * cx + ay * cy
    kr = kmag * pr[:, None]
    tan_phi = pc / pr

    # quantize the raw input signal to nbits BFP (the fabric's input quantizer)
    lsb, _ = fit_scale(sig, nbits)
    sigq = quant(sig, lsb, nbits).astype(np.complex64)

    # --- pass 1: per pulse, resample onto a common uniform range grid KR ------
    kr_lo, kr_hi = kr.max(axis=1).min(), kr.min(axis=1).max()
    if kr_lo > kr_hi:
        kr_lo, kr_hi = kr.min(), kr.max()
    KR = np.linspace(kr_lo, kr_hi, n)
    g1 = np.empty((m, n), dtype=np.complex64)
    for i in range(m):
        xp = kr[i]
        if xp[0] > xp[-1]:
            xp = xp[::-1]; row = sigq[i, ::-1]
        else:
            row = sigq[i]
        g1[i] = _interp_fixed(KR, xp, row, nbits_w)
    lsb, _ = fit_scale(g1, nbits)
    g1 = quant(g1, lsb, nbits).astype(np.complex64)

    # --- pass 2: per range bin, resample across pulses onto uniform cross KC ---
    kc_max = np.abs(KR[:, None] * tan_phi[None, :]).max()
    KC = np.linspace(-kc_max, kc_max, m)
    order = np.argsort(tan_phi)
    tan_s = tan_phi[order]
    g1s = g1[order]
    g2 = np.empty((m, n), dtype=np.complex64)
    for j in range(n):
        src = KR[j] * tan_s
        g2[:, j] = _interp_fixed(KC, src, g1s[:, j], nbits_w)

    if window:
        g2 = g2 * np.outer(np.hamming(m), np.hamming(n)).astype(np.float32)
    dr = 1.0 / (KR[-1] - KR[0]) if KR[-1] != KR[0] else float("nan")
    dc = 1.0 / (KC[-1] - KC[0]) if KC[-1] != KC[0] else float("nan")
    geo = {"dc": dc, "dr": dr, "dhat": (dx, dy), "chat": (cx, cy)}
    return g2, geo


def focus_full_fixed(sig, freq, ax, ay, nbits=16, nbits_tw=None, nbits_w=16):
    """Full fixed-point datapath emulation: resample -> window -> 2-D FFT ->
    detect, all quantized. This is the end-to-end oracle for the FPGA path.
    Returns (detected_magnitude, geo, bfp_exponents)."""
    g2, geo = resample_fixed(sig, freq, ax, ay, nbits=nbits, nbits_w=nbits_w)
    mag, exps = focus_fixed(g2, nbits, nbits_tw)
    return mag, geo, exps


# --------------------------------- study ----------------------------------- #
def run_study(crop=2048, bits=(8, 10, 12, 14, 16, 18), out_dir=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import form_image_pfa as ref

    out_dir = Path(out_dir or ref.OUTPUT_DIR); out_dir.mkdir(parents=True, exist_ok=True)
    rdr = ref.open_phase_history(str(ref.LOCAL_CPHD))
    nv, ns = rdr.get_data_size_as_tuple()[0]
    P = min(crop, _to_pow2(min(nv, ns)) // 2)        # power-of-2 center crop
    r0, c0 = (nv - P) // 2, (ns - P) // 2
    sig = np.asarray(rdr.read_chip((r0, r0 + P, 1), (c0, c0 + P, 1), index=0),
                     dtype=np.complex128)
    rdr.close()
    win = sig * np.outer(np.hamming(P), np.hamming(P))
    print(f"study crop {P}x{P} from {ref.KEY.split('/')[2]}\n")

    # float reference (double precision, same transform)
    ref_mag = np.abs(np.fft.fftshift(np.fft.fft2(np.fft.ifftshift(win))))

    print(f"{'bits':>4} {'SNR dB':>7} {'ENOB':>5} {'corr':>6} {'NRMSE':>7} "
          f"{'DR ref':>7} {'DR fix':>7} {'BFP guard(r/a)':>15}")
    rows = []
    for nb in bits:
        m2, n2 = _to_pow2(P), _to_pow2(P)
        pad = np.zeros((m2, n2), np.complex128); pad[:P, :P] = win
        lsb, _ = fit_scale(pad, nb); padq = quant(pad, lsb, nb)
        fimg, (er, ea) = fft2_bfp(np.fft.ifftshift(padq), nb)
        test_mag = np.abs(np.fft.fftshift(fimg))
        # crop ref to padded grid for fair compare
        rmag = np.abs(np.fft.fftshift(np.fft.fft2(np.fft.ifftshift(pad))))
        c = compare(rmag, test_mag); c["bits"] = nb
        # BFP guard bits = cumulative block-exponent growth across the FFT stages
        c["shift_r"], c["shift_a"] = er[-1] - er[0], ea[-1] - ea[0]
        rows.append(c)
        print(f"{nb:>4} {c['snr_db']:>7.1f} {c['enob']:>5.1f} {c['corr']:>6.3f} "
              f"{c['nrmse']:>7.4f} {c['dr_ref_db']:>6.1f}d {c['dr_test_db']:>6.1f}d "
              f"{c['shift_r']:>7}/{c['shift_a']:<6}")

    # plots
    b = [r["bits"] for r in rows]
    fig, ax = plt.subplots(1, 2, figsize=(12, 4.5))
    ax[0].plot(b, [r["snr_db"] for r in rows], "o-", label="SNR (dB)")
    ax[0].plot(b, [r["dr_test_db"] for r in rows], "s-", label="usable DR (dB)")
    ax[0].axhline(rows[-1]["dr_ref_db"], ls="--", c="k", label="float DR")
    ax[0].set_xlabel("datapath bits"); ax[0].set_ylabel("dB")
    ax[0].set_title("Information loss vs bit width"); ax[0].legend(); ax[0].grid(True)
    ax[1].plot(b, [r["enob"] for r in rows], "o-")
    ax[1].set_xlabel("datapath bits"); ax[1].set_ylabel("ENOB (bits)")
    ax[1].set_title("Effective number of bits"); ax[1].grid(True)
    fig.tight_layout(); fig.savefig(out_dir / "fixedpoint_study.png", dpi=120)
    print(f"\nwrote {out_dir/'fixedpoint_study.png'}")
    return rows


if __name__ == "__main__":
    run_study()
